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

A2DP_SINK_UUID="0000110b-0000-1000-8000-00805f9b34fb"   # "play music to me" channel

# Ask BlueZ to open the music (A2DP) channel to a device. A plain "connect"
# sometimes links the device without it, especially when another speaker is
# already streaming.
bt_open_music_channel() {
  local id h path hcis=()
  id=$(mac_id "$1")
  for h in /sys/class/bluetooth/hci*; do
    h=${h##*/}
    [[ $h == hci* && $h != *:* ]] && hcis+=("$h")
  done
  ((${#hcis[@]})) || hcis=(hci0)
  for h in "${hcis[@]}"; do
    path="/org/bluez/$h/dev_$id"
    if command -v busctl >/dev/null 2>&1; then
      with_timeout 20 busctl call org.bluez "$path" org.bluez.Device1 ConnectProfile s "$A2DP_SINK_UUID" >>"$LOG_FILE" 2>&1 && return 0
    elif command -v dbus-send >/dev/null 2>&1; then
      with_timeout 20 dbus-send --system --print-reply --dest=org.bluez "$path" \
        org.bluez.Device1.ConnectProfile "string:$A2DP_SINK_UUID" >>"$LOG_FILE" 2>&1 && return 0
    fi
  done
  return 1
}

# Make sure a connected device has a sound output. Sets BT_SINK.
bt_ensure_sink() {
  local mac=$1 name=$2 prof
  BT_SINK=$(audio_wait_for_sink "$mac" 8) && return 0
  # No sound card at all -> the music channel never opened. Open it explicitly.
  if [[ -z $(audio_card_for_mac "$mac") ]]; then
    info "Opening the music channel to $name…"
    bt_open_music_channel "$mac" || log "ConnectProfile failed for $mac"
    BT_SINK=$(audio_wait_for_sink "$mac" 8) && return 0
  fi
  # Sound card exists but no output -> it's switched to "off" or a mode with no output.
  if [[ -n $(audio_card_for_mac "$mac") ]]; then
    info "Switching $name to music mode…"
    prof=$(audio_force_a2dp "$mac")
    if BT_SINK=$(audio_wait_for_sink "$mac" 6); then
      [[ -n $prof && $prof != *a2dp* ]] &&
        warn "$name only works in phone-call mode here — it will play, but sound quality is lower."
      return 0
    fi
  fi
  return 1
}

bt_explain_no_sink() {
  local mac=$1 name=$2
  err "$name connected, but Linux never got a sound output for it."
  if [[ -z $(audio_card_for_mac "$mac") ]]; then
    info "It linked up, but its music channel wouldn't open. Usually this means:"
    info "  – your Bluetooth adapter can't stream to one more device at once"
    info "    (common with built-in adapters; a cheap USB Bluetooth dongle fixes it), or"
    info "  – pairing didn't fully finish: use Manage speakers → Forget, then add it again."
  else
    info "Its sound modes ($(audio_output_profiles "$(audio_card_for_mac "$mac")" | tr '\n' ' ')) wouldn't switch on."
  fi
  info "Run ${C_BOLD}./diagnose.sh${C_RESET} and share the output if this keeps happening."
}

# Pair (if needed), trust, connect and make sure its audio output exists.
bt_connect() {
  local mac=${1^^} name attempt agent=()
  name=$(name_of "$mac")
  if bt_connected "$mac"; then
    info "$name is already connected."
  else
    if ! bt_paired "$mac"; then
      info "Pairing with $name…"
      # Speakers have no keypad: pair as "no input, no output" so it can't stall on a PIN prompt.
      btctl --help 2>&1 | grep -q -- '--agent' && agent=(--agent NoInputNoOutput)
      with_timeout 25 bluetoothctl "${agent[@]}" pair "$mac" >>"$LOG_FILE" 2>&1
      bt_paired "$mac" || warn "Pairing didn't confirm — trying to connect anyway."
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
  if ! bt_ensure_sink "$mac" "$name"; then
    info "Reconnecting $name once more…"
    btctl disconnect "$mac" >>"$LOG_FILE" 2>&1
    sleep 2
    with_timeout 15 bluetoothctl connect "$mac" >>"$LOG_FILE" 2>&1
    if ! bt_ensure_sink "$mac" "$name"; then
      bt_explain_no_sink "$mac" "$name"
      log "no sink for $mac. info: $(bt_info "$mac" | tr '\n' ' ')"
      return 1
    fi
  fi
  ok "$name is ready 🔊"
  log "connected $mac ($name) -> $BT_SINK"
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
