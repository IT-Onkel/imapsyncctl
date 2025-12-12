#!/usr/bin/env bash
set -Eeuo pipefail

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
CMD_NAME="${CMD_NAME:-imapsyncctl}"

ETC_DIR="${ETC_DIR:-/etc/imapsyncctl}"
LIB_DIR="${LIB_DIR:-/var/lib/imapsyncctl}"
LOG_DIR="${LOG_DIR:-/var/log/imapsyncctl}"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Bitte als root ausführen: sudo $0"
    exit 1
  fi
}

main() {
  need_root

  rm -f "$BIN_DIR/$CMD_NAME"

  echo "🗑️  Binary entfernt: $BIN_DIR/$CMD_NAME"
  echo "Hinweis: Konfig/Secrets/Logs bleiben absichtlich erhalten:"
  echo "  - $ETC_DIR"
  echo "  - $LIB_DIR"
  echo "  - $LOG_DIR"
  echo
  echo "Wenn du wirklich alles löschen willst:"
  echo "  sudo rm -rf $ETC_DIR $LIB_DIR $LOG_DIR"
}

main "$@"
