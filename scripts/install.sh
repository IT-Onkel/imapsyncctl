#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="imapsyncctl"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC_BIN="${REPO_ROOT}/bin/imapsyncctl"
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

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    fi
    die "Bitte als root ausführen (oder sudo installieren)."
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

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
      die "Kein unterstützter Paketmanager gefunden. Bitte Dependencies manuell installieren: ${pkgs[*]}"
      ;;
  esac
}

ensure_deps() {
  local pm; pm="$(detect_pm)"

  # Muss:
  # - imapsync
  # - screen
  # - flock (util-linux)
  # - tee (coreutils; normalerweise da)
  # - bash
  #
  # Für Autodetect:
  # - nc ODER timeout ODER openssl (mind. eins davon, besser nc)
  # - dig ODER host ODER nslookup

  local missing=()

  # imapsync
  have imapsync || missing+=( "imapsync" )
  # screen
  have screen || missing+=( "screen" )
  # flock
  have flock || missing+=( "flock" )
  # bash/tee sind i.d.R. vorhanden – trotzdem prüfen:
  have bash || missing+=( "bash" )
  have tee  || missing+=( "tee" )

  # Connectivity checker: prefer nc, else timeout, else openssl
  if ! have nc && ! have timeout && ! have openssl; then
    # wir installieren nc als best practice
    missing+=( "nc" )
  fi

  # DNS tools: need at least one of dig/host/nslookup
  if ! have dig && ! have host && ! have nslookup; then
    missing+=( "dig" )
  fi

  [[ "${#missing[@]}" -eq 0 ]] && return 0

  log "Fehlende Commands erkannt: ${missing[*]}"
  [[ -n "$pm" ]] || die "Kein Paketmanager erkannt. Bitte manuell installieren: ${missing[*]}"

  # Mapping: command -> package (pro PM)
  local -a pkgs=()

  for cmd in "${missing[@]}"; do
    case "$pm" in
      apt)
        case "$cmd" in
          imapsync) pkgs+=( "imapsync" ) ;;
          screen)   pkgs+=( "screen" ) ;;
          flock)    pkgs+=( "util-linux" ) ;;
          bash)     pkgs+=( "bash" ) ;;
          tee)      pkgs+=( "coreutils" ) ;;
          nc)       pkgs+=( "netcat-openbsd" ) ;;
          dig)      pkgs+=( "dnsutils" ) ;;
        esac
        ;;
      dnf|yum)
        case "$cmd" in
          imapsync) pkgs+=( "imapsync" ) ;;
          screen)   pkgs+=( "screen" ) ;;
          flock)    pkgs+=( "util-linux" ) ;;
          bash)     pkgs+=( "bash" ) ;;
          tee)      pkgs+=( "coreutils" ) ;;
          nc)       pkgs+=( "nmap-ncat" ) ;;   # oder nc; nmap-ncat ist verbreitet
          dig)      pkgs+=( "bind-utils" ) ;;
        esac
        ;;
      pacman)
        case "$cmd" in
          imapsync) pkgs+=( "imapsync" ) ;;
          screen)   pkgs+=( "screen" ) ;;
          flock)    pkgs+=( "util-linux" ) ;;
          bash)     pkgs+=( "bash" ) ;;
          tee)      pkgs+=( "coreutils" ) ;;
          nc)       pkgs+=( "gnu-netcat" ) ;;
          dig)      pkgs+=( "bind" ) ;;
        esac
        ;;
      apk)
        case "$cmd" in
          imapsync) pkgs+=( "imapsync" ) ;;
          screen)   pkgs+=( "screen" ) ;;
          flock)    pkgs+=( "util-linux" ) ;;
          bash)     pkgs+=( "bash" ) ;;
          tee)      pkgs+=( "coreutils" ) ;;
          nc)       pkgs+=( "netcat-openbsd" ) ;;
          dig)      pkgs+=( "bind-tools" ) ;;
        esac
        ;;
    esac
  done

  # Duplikate entfernen
  local -a uniq=()
  local p
  for p in "${pkgs[@]}"; do
    [[ " ${uniq[*]} " == *" $p "* ]] || uniq+=( "$p" )
  done

  pm_install "$pm" "${uniq[@]}"
}

install_binary() {
  [[ -f "$SRC_BIN" ]] || die "Nicht gefunden: $SRC_BIN (bin/imapsyncctl fehlt)."

  log "Installiere $APP_NAME nach $DST_BIN"
  install -m 0755 "$SRC_BIN" "$DST_BIN"
}

create_dirs() {
  log "Lege Verzeichnisse an"
  mkdir -p \
    "$ETC_DIR" "$PROFILES_DIR" \
    "$LIB_DIR" "$SECRETS_DIR" "$STATE_DIR" \
    "$LOG_DIR" "$RUNS_DIR"

  # Permissions: secrets/state privat
  chmod 0755 "$ETC_DIR" "$PROFILES_DIR" "$LOG_DIR" "$RUNS_DIR" || true
  chmod 0700 "$LIB_DIR" "$SECRETS_DIR" "$STATE_DIR" || true
}

write_default_config_if_missing() {
  if [[ -f "$GLOBAL_CFG" ]]; then
    log "config.conf existiert bereits -> wird nicht überschrieben: $GLOBAL_CFG"
    return 0
  fi

  log "Schreibe Default config.conf: $GLOBAL_CFG"
  cat > "$GLOBAL_CFG" <<'EOF'
# imapsyncctl global defaults (key=value)
#
# 1=true 0=false
#
# Tipp:
# - wiederholbare Optionen kannst du mehrfach angeben:
#   folder=INBOX
#   exclude=Trash|Junk
#   f1f2=Sent=Gesendet
#
# SSL/TLS
ssl1=1
ssl2=1
tls1=0
tls2=0

# Typical behavior
usecache=1
automap=1
syncinternaldates=1

# Safety
delete1=0
delete2=0
delete2duplicates=0
delete2folders=0

# Robustness
errorsmax=
timeout1=
timeout2=

# imapsyncctl retry logic (per source)
retries=3
retry_delay=10

# Debug
debug=0
debugimap1=0
debugimap2=0

# Extra args (free-form; be careful with quoting)
extra_args=
EOF
  chmod 0644 "$GLOBAL_CFG" || true
}

post_install_checks() {
  log "Kurztest: imapsyncctl --help"
  "$DST_BIN" --help >/dev/null 2>&1 || die "imapsyncctl konnte nicht ausgeführt werden."

  log "Installationspfade:"
  echo "  Binary:   $DST_BIN"
  echo "  Config:   $GLOBAL_CFG"
  echo "  Profiles: $PROFILES_DIR"
  echo "  Secrets:  $SECRETS_DIR"
  echo "  State:    $STATE_DIR"
  echo "  Runs:     $RUNS_DIR"
  echo
  echo "Beispiele:"
  echo "  imapsyncctl new"
  echo "  imapsyncctl run <Profil>"
  echo "  imapsyncctl status"
  echo "  imapsyncctl reconfigure <Profil>"
}

main() {
  need_root "$@"
  ensure_deps
  create_dirs
  write_default_config_if_missing
  install_binary
  post_install_checks
  log "Fertig."
}

main "$@"
