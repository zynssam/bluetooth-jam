#!/usr/bin/env bash
# =====================================================================
#  check_deps.sh — checks everything the jam needs and explains how to
#  install anything missing.
# =====================================================================

JAM_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
source "$JAM_HOME/lib/common.sh"

problems=0
pass() { ok "$1"; }
fail() { err "$1"; problems=$((problems + 1)); }

# Which package manager?
if command -v apt >/dev/null 2>&1; then PM="sudo apt install"
  PK_BT="bluez" PK_PA="pulseaudio-utils" PK_PLAY="mpv"
elif command -v dnf >/dev/null 2>&1; then PM="sudo dnf install"
  PK_BT="bluez" PK_PA="pulseaudio-utils" PK_PLAY="mpv"
elif command -v pacman >/dev/null 2>&1; then PM="sudo pacman -S"
  PK_BT="bluez bluez-utils" PK_PA="libpulse" PK_PLAY="mpv"
elif command -v zypper >/dev/null 2>&1; then PM="sudo zypper install"
  PK_BT="bluez" PK_PA="pulseaudio-utils" PK_PLAY="mpv"
else PM="(your package manager) install"
  PK_BT="bluez" PK_PA="pulseaudio-utils" PK_PLAY="mpv"
fi

header "Checking your system"

echo "  ${C_BOLD}Required${C_RESET}"
if command -v bluetoothctl >/dev/null 2>&1; then pass "bluetoothctl (Bluetooth control)"
else fail "bluetoothctl missing  →  $PM $PK_BT"; fi

if command -v pactl >/dev/null 2>&1; then pass "pactl (sound control)"
else fail "pactl missing  →  $PM $PK_PA"; fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet bluetooth 2>/dev/null; then pass "Bluetooth service is running"
  else fail "Bluetooth service not running  →  sudo systemctl enable --now bluetooth"; fi
fi

if command -v bluetoothctl >/dev/null 2>&1; then
  if LC_ALL=C bluetoothctl show 2>/dev/null | grep -q '^Controller'; then pass "Bluetooth adapter found"
  else fail "No Bluetooth adapter detected (plug in a USB Bluetooth dongle?)"; fi
fi

if command -v pactl >/dev/null 2>&1 && LC_ALL=C pactl info >/dev/null 2>&1; then
  server=$(LC_ALL=C pactl info | sed -n 's/^Server Name: //p')
  pass "Sound server running: $server"
  if [[ $server == *PipeWire* ]]; then
    if pactl list short modules 2>/dev/null | grep -q module-bluez5 || LC_ALL=C pactl list short cards 2>/dev/null | grep -q bluez \
       || ls /usr/share/spa-0.2/bluez5 >/dev/null 2>&1 || ls /usr/lib*/spa-0.2/bluez5 >/dev/null 2>&1 \
       || ls /usr/lib/*/spa-0.2/bluez5 >/dev/null 2>&1; then
      pass "PipeWire Bluetooth support"
    else
      warn "Can't confirm PipeWire Bluetooth support  →  $PM libspa-0.2-bluetooth  (Debian/Ubuntu name)"
    fi
  else
    if LC_ALL=C pactl list short modules 2>/dev/null | grep -q bluetooth; then pass "PulseAudio Bluetooth module loaded"
    else warn "PulseAudio Bluetooth module not loaded  →  $PM pulseaudio-module-bluetooth  (then log out/in)"; fi
  fi
else
  fail "Sound server not reachable (run as your normal user, not sudo)"
fi

echo; echo "  ${C_BOLD}Optional${C_RESET}"
if command -v paplay >/dev/null 2>&1 || command -v pw-play >/dev/null 2>&1; then pass "Test beeps (paplay / pw-play)"
else warn "No paplay/pw-play — test beeps won't work  →  $PM $PK_PA"; fi

player=$("$JAM_HOME/lib/player.sh" --check 2>/dev/null)
if [[ -n $player ]]; then pass "Built-in music playback ($player)"
else warn "No command-line music player — 'Play music' won't work (other apps still do)  →  $PM $PK_PLAY"; fi

if command -v rfkill >/dev/null 2>&1; then pass "rfkill (auto-unblocks Bluetooth)"
else info "rfkill not found (optional)"; fi

echo; line
if ((problems == 0)); then
  ok "${C_BOLD}All set! Run ./jam.sh to start.${C_RESET}"
else
  err "${C_BOLD}$problems thing(s) to fix above, then run this check again.${C_RESET}"
fi
echo
exit $((problems > 0))
