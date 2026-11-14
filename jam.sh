#!/usr/bin/env bash
# =====================================================================
#  jam.sh — Multi-Speaker Bluetooth Jam Session
#  Play the same audio through several Bluetooth speakers at once.
#
#  Usage:  ./jam.sh            open the menu
#          ./jam.sh --status   show what's playing where
#          ./jam.sh --stop     stop the jam (audio returns to normal)
#          ./jam.sh --help
# =====================================================================

JAM_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

for _lib in common bluetooth audio session menus; do
  # shellcheck source=/dev/null
  source "$JAM_HOME/lib/$_lib.sh" || { echo "Missing lib/$_lib.sh — is the project folder complete?" >&2; exit 1; }
done
unset _lib

usage() {
  cat <<EOF
Bluetooth Jam Session — make all your speakers play together.

  ./jam.sh            open the menu (start here)
  ./jam.sh --status   show the jam and its speakers
  ./jam.sh --stop     stop the jam and send audio back to normal
  ./jam.sh --help     this text

First time? Run ./check_deps.sh to make sure everything is installed.
EOF
}

case ${1:-} in
  -h | --help) usage; exit 0 ;;
  --status)
    audio_check || exit 1
    BTJAM_NO_CLEAR=1 show_status </dev/null
    exit 0 ;;
  --stop)
    audio_check || exit 1
    if jam_active; then
      player_running && player_stop
      jam_stop && ok "Jam stopped."
    else
      info "No jam is running."
    fi
    exit 0 ;;
  '') ;;
  *) usage; exit 1 ;;
esac

trap 'echo; info "Interrupted. Any running jam keeps playing — stop it with ./jam.sh --stop"; exit 130' INT

header "Getting ready…"
audio_check || { pause; exit 1; }
bt_check || { pause; exit 1; }
main_menu
