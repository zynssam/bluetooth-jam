#!/usr/bin/env bash
# =====================================================================
#  lib/audio.sh — sound-server helpers (PulseAudio or PipeWire, via pactl)
# =====================================================================

audio_check() {
  command -v pactl >/dev/null 2>&1 || {
    err "pactl is not installed. Run ./check_deps.sh for install help."
    return 1
  }
  pa info >/dev/null 2>&1 || {
    err "Can't reach the sound server (PulseAudio / PipeWire)."
    info "Run this as your normal user (not with sudo), inside your desktop session."
    return 1
  }
}

audio_server() { pa info 2>/dev/null | sed -n 's/^Server Name: //p'; }

# AA:BB:CC:DD:EE:FF -> AA_BB_CC_DD_EE_FF (how sinks are named)
mac_id() { local m=${1^^}; printf '%s' "${m//:/_}"; }

audio_sink_exists() { pa list short sinks 2>/dev/null | awk -v n="$1" '$2 == n {f = 1} END {exit !f}'; }

# Sink of a Bluetooth device, e.g. bluez_output.AA_BB_….1 / bluez_sink.AA_BB_….a2dp_sink
audio_sink_for_mac() {
  local id; id=$(mac_id "$1")
  pa list short sinks 2>/dev/null |
    awk -v id="$id" '$2 !~ /^bt_jam_/ && index(toupper($2), id) {print $2; exit}'
}

audio_card_for_mac() {
  local id; id=$(mac_id "$1")
  pa list short cards 2>/dev/null | awk -v id="$id" 'index(toupper($2), id) {print $2; exit}'
}

# MACs of every Bluetooth speaker that currently has a sound output
audio_bt_macs() {
  pa list short sinks 2>/dev/null | awk '$2 ~ /^bluez/ {print $2}' |
    grep -oE '([0-9A-Fa-f]{2}_){5}[0-9A-Fa-f]{2}' | tr '_abcdef' ':ABCDEF' | awk '!seen[$0]++'
}

audio_wait_for_sink() {          # MAC SECONDS -> prints sink name
  local i s
  for ((i = 0; i < $2 * 2; i++)); do
    s=$(audio_sink_for_mac "$1")
    [[ -n $s ]] && { printf '%s\n' "$s"; return 0; }
    sleep 0.5
  done
  return 1
}

audio_wait_for_named_sink() {    # NAME SECONDS
  local i
  for ((i = 0; i < $2 * 2; i++)); do
    audio_sink_exists "$1" && return 0
    sleep 0.5
  done
  return 1
}

# Some speakers connect in "headset/phone call" mode; switch to music (A2DP) mode.
audio_force_a2dp() {
  local card p
  card=$(audio_card_for_mac "$1")
  [[ -z $card ]] && return 1
  for p in a2dp-sink a2dp_sink a2dp-sink-sbc a2dp-sink-aac; do
    pa set-card-profile "$card" "$p" >>"$LOG_FILE" 2>&1 && { log "profile $card -> $p"; return 0; }
  done
  return 1
}

audio_default_sink() {
  local s
  s=$(pa get-default-sink 2>/dev/null)
  [[ -z $s ]] && s=$(pa info 2>/dev/null | sed -n 's/^Default Sink: //p')
  printf '%s' "$s"
}

# Reads a value from the long "pactl list sinks" block of one sink.
_sink_field() {
  pa list sinks 2>/dev/null | awk -v s="$1" -v f="$2" '
    /^Sink #/ { ins = 0 }
    $1 == "Name:" { ins = ($2 == s) }
    ins && f == "volume" && $1 == "Volume:" { if (match($0, /[0-9]+%/)) { print substr($0, RSTART, RLENGTH - 1); exit } }
    ins && f == "mute"   && $1 == "Mute:"   { print $2; exit }
    ins && f == "owner"  && $1 == "Owner" && $2 == "Module:" { print $3; exit }'
}
audio_get_volume() { _sink_field "$1" volume; }
audio_get_mute()   { _sink_field "$1" mute; }
audio_sink_owner_module() { _sink_field "$1" owner; }

audio_set_volume() {             # SINK PERCENT
  local v=$2
  ((v < 0)) && v=0
  ((v > 150)) && v=150
  pa set-sink-volume "$1" "${v}%" >>"$LOG_FILE" 2>&1
}
audio_set_mute() { pa set-sink-mute "$1" "$2" >>"$LOG_FILE" 2>&1; }

# Index list of *application* streams (music players, browsers…), skipping the
# internal streams the combine module uses to feed each speaker.
audio_user_streams() {
  pa list sink-inputs 2>/dev/null | awk '
    function flush() { if (idx != "" && !skip && client) print idx }
    /^Sink Input #/ { flush(); idx = substr($3, 2); skip = 0; client = 0; next }
    /[Cc]ombine/ { skip = 1 }
    /(node|media)\.name = ".*bt_jam_/ { skip = 1 }
    /^[ \t]+Client: [0-9]+/ { client = 1 }
    END { flush() }'
}

audio_move_user_streams() {      # TARGET_SINK
  local i
  for i in $(audio_user_streams); do
    pa move-sink-input "$i" "$1" >>"$LOG_FILE" 2>&1
  done
}

# ---------- sync fine-tuning (latency offset per speaker) -------------
audio_port_for_card() {
  pa list cards 2>/dev/null | awk -v c="$1" '
    $1 == "Name:" { inc = ($2 == c); inports = 0 }
    inc && /^\tPorts:/ { inports = 1; next }
    inc && inports && /^\t[^\t]/ { inports = 0 }
    inc && inports && /^\t\t[^\t]/ { p = $1; sub(/:$/, "", p); if (p ~ /output/) { print p; exit } }'
}

audio_get_offset_ms() {          # MAC -> current extra delay in ms
  local card port
  card=$(audio_card_for_mac "$1"); [[ -z $card ]] && return 1
  port=$(audio_port_for_card "$card"); [[ -z $port ]] && return 1
  pa list cards 2>/dev/null | awk -v c="$card" -v p="$port" '
    $1 == "Name:" { inc = ($2 == c) }
    inc && index($0, p ":") && match($0, /latency offset: -?[0-9]+/) {
      v = substr($0, RSTART + 16, RLENGTH - 16); printf "%d\n", v / 1000; exit }'
}

audio_set_offset_ms() {          # MAC MS
  local card port
  card=$(audio_card_for_mac "$1"); [[ -z $card ]] && return 1
  port=$(audio_port_for_card "$card"); [[ -z $port ]] && return 1
  pa set-port-latency-offset "$card" "$port" "$(($2 * 1000))" >>"$LOG_FILE" 2>&1
}

# ---------- test tone, generated in pure shell -------------------------
_le16() { printf '\\x%02x\\x%02x' $(($1 & 255)) $((($1 >> 8) & 255)); }
_le32() { printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255)); }

# Writes a short "beep-beep" as an 8-bit mono WAV file.
audio_make_tone() {
  local file=$1 freq=${2:-660} rate=8000 half body period beep gap size
  half=$((rate / freq / 2)); ((half < 1)) && half=1
  period="$(rep '\xb0' "$half")$(rep '\x50' "$half")"
  beep=$(rep "$period" $((rate * 25 / 100 / (half * 2))))   # ~0.25 s of tone
  gap=$(rep '\x80' $((rate * 12 / 100)))                      # ~0.12 s of silence
  body="$beep$gap$beep$gap"
  size=$(( (${#beep} + ${#gap}) * 2 / 4 ))                    # 4 chars per "\xNN" byte
  {
    printf 'RIFF'; printf "$(_le32 $((36 + size)))"; printf 'WAVEfmt '
    printf "$(_le32 16)$(_le16 1)$(_le16 1)$(_le32 $rate)$(_le32 $rate)$(_le16 1)$(_le16 8)"
    printf 'data'; printf "$(_le32 "$size")"; printf "$body"
  } >"$file"
}

audio_play_file_on() {           # SINK FILE
  if command -v paplay >/dev/null 2>&1; then paplay --device="$1" "$2"
  elif command -v pw-play >/dev/null 2>&1; then pw-play --target "$1" "$2"
  else return 1
  fi
}

audio_beep() {                   # SINK [FREQ]
  local tone="$STATE_DIR/beep_${2:-660}.wav"
  [[ -s $tone ]] || audio_make_tone "$tone" "${2:-660}"
  audio_play_file_on "$1" "$tone" >>"$LOG_FILE" 2>&1 || {
    warn "Couldn't play a test sound (install 'paplay' from pulseaudio-utils)."
    return 1
  }
}
