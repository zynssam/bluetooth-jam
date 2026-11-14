#!/usr/bin/env bash
# =====================================================================
#  lib/bluetooth.sh — discovery, pairing, connecting (via bluetoothctl)
# =====================================================================

# Make sure there is an adapter and it is switched on.
bt_check() {
  command -v bluetoothctl >/dev/null 2>&1 || {
    err "bluetoothctl is not installed. Run ./check_deps.sh for install help."
    return 1
  }
  if command -v rfkill >/dev/null 2>&1 && rfkill list bluetooth 2>/dev/null | grep -qi 'soft blocked: yes'; then
    info "Bluetooth is switched off in software — unblocking it…"
    rfkill unblock bluetooth 2>/dev/null
    sleep 1
  fi
  local show
  show=$(btctl show 2>&1)
  if ! grep -q '^Controller' <<<"$show"; then
    err "No Bluetooth adapter found."
    info "Try:  sudo systemctl enable --now bluetooth   (then run this again)"
    return 1
  fi
  if ! grep -q 'Powered: yes' <<<"$show"; then
    info "Switching Bluetooth on…"
    btctl power on >>"$LOG_FILE" 2>&1
    sleep 1
    btctl show 2>/dev/null | grep -q 'Powered: yes' || { err "Couldn't switch the Bluetooth adapter on."; return 1; }
  fi
  return 0
}

# Scan for SECONDS while showing a progress bar.
bt_scan() {
  local secs=${1:-$SCAN_SECS} pid
  if btctl --help 2>&1 | grep -q -- '--timeout'; then
    btctl --timeout "$secs" scan on >>"$LOG_FILE" 2>&1 &
  else  # older bluez: drive the interactive shell through a pipe
    { echo 'scan on'; sleep "$secs"; echo 'scan off'; echo 'quit'; } | btctl >>"$LOG_FILE" 2>&1 &
  fi
  pid=$!
  progress_bar "$secs" "Looking for speakers"
  wait "$pid" 2>/dev/null
  return 0
}

bt_info()      { btctl info "$1" 2>/dev/null; }
bt_connected() { bt_info "$1" | grep -q 'Connected: yes'; }
bt_paired()    { bt_info "$1" | grep -q 'Paired: yes'; }

# Is this device something that plays sound?
bt_is_audio() {
  bt_info "$1" | grep -Eqi 'Icon: audio-|UUID: (Audio Sink|Advanced Audio|Headset|Handsfree)|0000110b-'
}

# Print "MAC|Name" for every known audio device ("all" = every device).
bt_list_speakers() {
  local line mac name
  while IFS= read -r line; do
    [[ $line =~ ^Device[[:space:]]+([0-9A-Fa-f:]{17})[[:space:]]*(.*)$ ]] || continue
    mac=${BASH_REMATCH[1]^^}
    name=${BASH_REMATCH[2]}
    [[ -z $name || ${name^^} == "${mac//:/-}" ]] && name="Unnamed device ($mac)"
    if [[ ${1:-} == all ]] || bt_is_audio "$mac"; then
      printf '%s|%s\n' "$mac" "$name"
    fi
  done < <(btctl devices 2>/dev/null)
}

# Pair (if needed), trust, connect and wait until its audio output exists.
bt_connect() {
  local mac=${1^^} name attempt sink
  name=$(name_of "$mac")
  if bt_connected "$mac"; then
    info "$name is already connected."
  else
    if ! bt_paired "$mac"; then
      info "Pairing with $name…"
      with_timeout 25 bluetoothctl pair "$mac" >>"$LOG_FILE" 2>&1 \
        || info "(pairing didn't confirm — trying to connect anyway)"
    fi
    btctl trust "$mac" >>"$LOG_FILE" 2>&1
    for attempt in 1 2 3; do
      info "Connecting to $name… (try $attempt of 3)"
      with_timeout 15 bluetoothctl connect "$mac" >>"$LOG_FILE" 2>&1
      bt_connected "$mac" && break
      sleep 2
    done
    if ! bt_connected "$mac"; then
      err "Couldn't connect to $name."
      info "Check it's switched on, close by, and not connected to a phone."
      return 1
    fi
  fi
  sink=$(audio_wait_for_sink "$mac" 10)
  if [[ -z $sink ]]; then
    audio_force_a2dp "$mac"
    sink=$(audio_wait_for_sink "$mac" 6)
  fi
  if [[ -z $sink ]]; then
    err "$name connected, but no sound output appeared for it."
    info "Try turning the speaker off and on, then connect again."
    return 1
  fi
  ok "$name is ready 🔊"
  log "connected $mac ($name) -> $sink"
  return 0
}

bt_disconnect() {
  local mac=${1^^}
  btctl disconnect "$mac" >>"$LOG_FILE" 2>&1
  log "disconnected $mac"
}

bt_forget() {
  local mac=${1^^}
  btctl remove "$mac" >>"$LOG_FILE" 2>&1
  grep -viF "$mac|" "$NAMES_FILE" >"$NAMES_FILE.tmp" 2>/dev/null; mv "$NAMES_FILE.tmp" "$NAMES_FILE"
  log "forgot $mac"
}
