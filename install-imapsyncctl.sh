#!/usr/bin/env bash
set -Eeuo pipefail

# =======================
# Bootstrap Installer for imapsyncctl
# Repo: https://github.com/IT-Onkel/imapsyncctl
# =======================

OWNER="IT-Onkel"
REPO="imapsyncctl"

# Optional: override via env, e.g. IMAPSYNCCTL_REF=v1.0.0
REF="${IMAPSYNCCTL_REF:-main}"

# Raw GitHub base (downloads only needed files; no clone)
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO}/${REF}"

# Paths in repo
REMOTE_BIN_PATH="bin/imapsyncctl"

# Install targets
DST_BIN="/usr/local/bin/imapsyncctl"

ETC_DIR="/etc/imapsyncctl"
LIB_DIR="/var/lib/imapsyncctl"
LOG_DIR="/var/log/imapsyncctl"

GLOBAL_CFG="${ETC_DIR}/config.conf"
PROFILES_DIR="${ETC_DIR}/profiles"
SECRETS_DIR="${LIB_DIR}/secrets"
STATE_DIR="${LIB_DIR}/state"
RUNS_DIR="${LOG_DIR}/runs"

die(){ echo "FEHLER: $*" >&2; exit 1; }
log(){ echo "==> $*"; }

have(){ command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if have sudo; then exec sudo -E bash "$0" "$@"; fi
    die "Bitte als root ausführen (oder sudo installieren)."
  fi
}

detect_pm() {
  if have apt-get; then echo "apt"; return; fi
  if have dnf; then echo "dnf"; return; fi
  if have yum; then echo "yum"; return; fi
  if have pacman; then echo "pacman"; return; fi
  if have apk; then echo "apk"; return; fi
  echo ""
}

pm_install() {
  local pm="$1"; shift
  local -a pkgs=( "$@" )
  [[ "${#pkgs[@]}" -gt 0 ]] || return 0

  case "$pm" in
    apt)
      log "Installiere Pakete via apt: ${pkgs[*]}"
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      log "Installiere Pakete via dnf: ${pkgs[*]}"
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      log "Installiere Pakete via yum: ${pkgs[*]}"
      yum install -y "${pkgs[@]}"
      ;;
    pacman)
      log "Installiere Pakete via pacman: ${pkgs[*]}"
      pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    apk)
      log "Installiere Pakete via apk: ${pkgs[*]}"
      apk add --no-cache "${pkgs[@]}"
      ;;
    *)
      die "Kein unterstützter Paketmanager gefunden. Bitte manuell installieren: ${pkgs[*]}"
      ;;
  esac
}

ensure_deps() {
  local pm; pm="$(detect_pm)"

  # runtime + bootstrap deps:
  # - curl/wget for download
  # - ca-certificates for https
  # - imapsync, screen, flock
  # - dns tool for MX detection (dig/host/nslookup) - at least one
  # - connectivity check: nc OR timeout OR openssl - at least one
  local missing_cmd=()

  (have curl || have wget) || missing_cmd+=( "curl" )
  have imapsync || missing_cmd+=( "imapsync" )
  have screen   || missing_cmd+=( "screen" )
  have flock    || missing_cmd+=( "flock" )

  if ! have dig && ! have host && ! have nslookup; then
    missing_cmd+=( "dig" )
  fi
  if ! have nc && ! have timeout && ! have openssl; then
    missing_cmd+=( "nc" )
  fi

  [[ "${#missing_cmd[@]}" -eq 0 ]] && return 0

  log "Fehlende Commands erkannt: ${missing_cmd[*]}"
  [[ -n "$pm" ]] || die "Kein Paketmanager erkannt. Bitte manuell installieren: ${missing_cmd[*]}"

  local -a pkgs=()
  for cmd in "${missing_cmd[@]}"; do
    case "$pm" in
      apt)
        case "$cmd" in
          curl)     pkgs+=( "curl" "ca-certificates" ) ;;
          imapsync) pkgs+=( "imapsync" ) ;;
          screen)   pkgs+=( "screen" ) ;;
          flock)    pkgs+=( "util-linux" ) ;;
          dig)      pkgs+=( "dnsutils" ) ;;
          nc)       pkgs+=( "netcat-openbsd" ) ;;
        esac
        ;;
      dnf|yum)
        case "$cmd" in
          curl)     pkgs+=( "curl" "ca-certificates" ) ;;
          imapsync) pkgs+=( "imapsync" ) ;;
          screen)   pkgs+=( "screen" ) ;;
          flock)    pkgs+=( "util-linux" ) ;;
          dig)      pkgs+=( "bind-utils" ) ;;
          nc)       pkgs+=( "nmap-ncat" ) ;;
        esac
        ;;
      pacman)
        case "$cmd" in
          curl)     pkgs+=( "curl" "ca-certificates" ) ;;
          imapsync) pkgs+=( "imapsync" ) ;;
          screen)   pkgs+=( "screen" ) ;;
          flock)    pkgs+=( "util-linux" ) ;;
          dig)      pkgs+=( "bind" ) ;;
          nc)       pkgs+=( "gnu-netcat" ) ;;
        esac
        ;;
      apk)
        case "$cmd" in
          curl)     pkgs+=( "curl" "ca-certificates" ) ;;
          imapsync) pkgs+=( "imapsync" ) ;;
          screen)   pkgs+=( "screen" ) ;;
          flock)    pkgs+=( "util-linux" ) ;;
          dig)      pkgs+=( "bind-tools" ) ;;
          nc)       pkgs+=( "netcat-openbsd" ) ;;
        esac
        ;;
    esac
  done

  # dedupe
  local -a uniq=()
  local p
  for p in "${pkgs[@]}"; do
    [[ " ${uniq[*]} " == *" $p "* ]] || uniq+=( "$p" )
  done

  pm_install "$pm" "${uniq[@]}"
}

download() {
  local url="$1" out="$2"
  if have curl; then
    curl -fsSL "$url" -o "$out"
  elif have wget; then
    wget -qO "$out" "$url"
  else
    die "Weder curl noch wget vorhanden."
  fi
}

create_dirs() {
  log "Lege Verzeichnisse an"
  mkdir -p \
    "$ETC_DIR" "$PROFILES_DIR" \
    "$LIB_DIR" "$SECRETS_DIR" "$STATE_DIR" \
    "$LOG_DIR" "$RUNS_DIR"

  chmod 0755 "$ETC_DIR" "$PROFILES_DIR" "$LOG_DIR" "$RUNS_DIR" || true
  chmod 0700 "$LIB_DIR" "$SECRETS_DIR" "$STATE_DIR" || true
}

write_default_config_if_missing() {
  if [[ -f "$GLOBAL_CFG" ]]; then
    log "config.conf existiert -> wird nicht überschrieben: $GLOBAL_CFG"
    return 0
  fi

  log "Schreibe Default config.conf: $GLOBAL_CFG"
  cat > "$GLOBAL_CFG" <<'EOF'
# imapsyncctl global defaults (key=value)
# 1=true 0=false
ssl1=1
ssl2=1
tls1=0
tls2=0

usecache=1
automap=1
syncinternaldates=1

delete1=0
delete2=0
delete2duplicates=0
delete2folders=0

errorsmax=
timeout1=
timeout2=

retries=3
retry_delay=10

debug=0
debugimap1=0
debugimap2=0

extra_args=
EOF
  chmod 0644 "$GLOBAL_CFG" || true
}

install_binary() {
  local url="${RAW_BASE}/${REMOTE_BIN_PATH}"
  local tmp; tmp="$(mktemp)"
  chmod 600 "$tmp"

  log "Lade imapsyncctl von: $url"
  download "$url" "$tmp"

  # Minimal sanity check: shebang vorhanden?
  head -n 1 "$tmp" | grep -q '^#!' || die "Download sieht nicht wie ein Script aus (kein shebang). URL korrekt?"

  install -m 0755 "$tmp" "$DST_BIN"
  rm -f "$tmp"

  log "Installiert: $DST_BIN"
}

post_install() {
  log "Kurztest: imapsyncctl --help"
  "$DST_BIN" --help >/dev/null 2>&1 || die "imapsyncctl konnte nicht ausgeführt werden."

  echo
  echo "✅ Fertig. Du kannst jetzt:"
  echo "  imapsyncctl new"
  echo "  imapsyncctl run <Profil>"
  echo "  imapsyncctl status"
  echo
  echo "Pfade:"
  echo "  Binary:   $DST_BIN"
  echo "  Config:   $GLOBAL_CFG"
  echo "  Profiles: $PROFILES_DIR"
  echo "  Secrets:  $SECRETS_DIR"
  echo "  State:    $STATE_DIR"
  echo "  Runs:     $RUNS_DIR"
  echo
  echo "Version pinning (optional):"
  echo "  IMAPSYNCCTL_REF=v1.0.0 bash <installer>"
}

main() {
  need_root "$@"
  ensure_deps
  create_dirs
  write_default_config_if_missing
  install_binary
  post_install
}

main "$@"
