#!/usr/bin/env bash
# =====================================================================
#  diagnose.sh — collects everything needed to work out why a speaker
#  won't play. Prints a report and saves it to bt-jam-report.txt.
#  Usage:  ./diagnose.sh              (all known audio devices)
#          ./diagnose.sh AA:BB:CC:DD:EE:FF
# =====================================================================

JAM_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
for _lib in common bluetooth audio; do
  # shellcheck source=/dev/null
  source "$JAM_HOME/lib/$_lib.sh"
done
REPORT="$PWD/bt-jam-report.txt"

section() { printf '\n===== %s =====\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1; }

report() {
  section "System"
  sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"'
  uname -r
  run bluetoothctl --version
  pactl --version 2>/dev/null | head -2
  command -v pipewire >/dev/null && pipewire --version 2>/dev/null | tail -1
  command -v wireplumber >/dev/null && wireplumber --version 2>/dev/null | tail -1
  LC_ALL=C pactl info 2>/dev/null | grep -E '^(Server Name|Server Version|Default Sink)'

  section "Bluetooth adapter(s)"
  for h in /sys/class/bluetooth/hci*; do [[ -e $h && $h != *:* ]] && echo "${h##*/}"; done
  LC_ALL=C bluetoothctl show 2>&1 | grep -E 'Controller|Name:|Powered|Roles|UUID: Audio|UUID: Advanced'
  command -v lsusb >/dev/null && lsusb 2>/dev/null | grep -i -E 'bluetooth|wireless|intel|realtek|broadcom|qualcomm|mediatek' | head -5

  local macs=("$@") m c
  if ((${#macs[@]} == 0)); then
    mapfile -t macs < <(bt_list_speakers | cut -d'|' -f1)
  fi
  for m in "${macs[@]}"; do
    m=${m^^}
    section "Device $m ($(name_of "$m"))"
    LC_ALL=C bluetoothctl info "$m" 2>&1 | grep -E 'Name|Icon|Paired|Bonded|Trusted|Blocked|Connected|UUID'
    printf 'Sound output: %s\n' "$(audio_sink_for_mac "$m")"
    c=$(audio_card_for_mac "$m")
    printf 'Sound card:   %s\n' "${c:-(none — the music channel is not open)}"
    if [[ -n $c ]]; then
      printf 'Active mode:  %s\n' "$(audio_active_profile "$c")"
      echo "Modes that can play sound (best first):"
      audio_output_profiles "$c" | sed 's/^/  /'
      echo "Full card profile list:"
      LC_ALL=C pactl list cards 2>/dev/null | awk -v c="$c" '
        $1 == "Name:" { inc = ($2 == c) }
        inc && /^\tProfiles:/ { p = 1; next }
        inc && p && /^\t[^\t]/ { p = 0 }
        inc && p { print }'
    fi
  done

  section "All sound outputs"
  LC_ALL=C pactl list short sinks 2>&1
  section "All sound cards"
  LC_ALL=C pactl list short cards 2>&1
  section "Jam modules"
  LC_ALL=C pactl list short modules 2>&1 | grep -E 'combine|bluetooth|bluez' || echo "(none)"

  section "Bluetooth service log (last 40 lines)"
  journalctl -b -u bluetooth --no-pager -n 40 2>&1 | cut -c1-220
  section "Sound server log, Bluetooth lines (last 40)"
  journalctl --user -b -u wireplumber -u pipewire -u pipewire-pulse -u pulseaudio --no-pager -n 400 2>&1 |
    grep -i -E 'bluez|a2dp|bluetooth|spa\.bluez|profile' | tail -40 | cut -c1-220
  section "bt-jam log (last 40 lines)"
  tail -40 "$LOG_FILE" 2>/dev/null
}

echo "Collecting information… (this takes a few seconds)"
report "$@" >"$REPORT" 2>&1
cat "$REPORT"
echo
echo "Saved to: $REPORT"
echo "It contains device names and Bluetooth addresses — nothing else personal."
