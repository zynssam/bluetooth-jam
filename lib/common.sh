#!/usr/bin/env bash
# =====================================================================
#  lib/common.sh — shared helpers: colours, prompts, state, logging
# =====================================================================

JAM_SINK_PREFIX="bt_jam_"                 # our combined sink is bt_jam_a or bt_jam_b
JAM_DESC="Bluetooth_Jam_Session"          # what audio apps see as the output name

STATE_DIR="${BTJAM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/bt-jam}"
NAMES_FILE="$STATE_DIR/names"             # MAC|Friendly name (remembered speakers)
MEMBERS_FILE="$STATE_DIR/members"         # MACs currently in the jam
PREV_SINK_FILE="$STATE_DIR/prev_default_sink"
PLAYER_PID_FILE="$STATE_DIR/player.pid"
PLAYER_NOW_FILE="$STATE_DIR/player.now"
LOG_FILE="$STATE_DIR/jam.log"
SCAN_SECS="${BTJAM_SCAN_SECS:-12}"

mkdir -p "$STATE_DIR" 2>/dev/null
: >>"$NAMES_FILE"

# ---------- colours (disabled when not a terminal or NO_COLOR set) ----
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m' C_MAGENTA=$'\e[35m' C_CYAN=$'\e[36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN=''
fi

# ---------- tool wrappers (force English output so parsing works) -----
pa()    { LC_ALL=C pactl "$@"; }
btctl() { LC_ALL=C bluetoothctl "$@"; }
with_timeout() {            # with_timeout SECS cmd...
  if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi
}

# ---------- messages --------------------------------------------------
log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
info() { printf '  %s•%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '  %s✖%s %s\n' "$C_RED" "$C_RESET" "$*"; log "ERROR: $*"; }

rep() { local s='' i; for ((i = 0; i < $2; i++)); do s+=$1; done; printf '%s' "$s"; }
line() { printf '  %s%s%s\n' "$C_DIM" "$(rep '─' 56)" "$C_RESET"; }

clear_screen() { [[ -t 1 && -z ${BTJAM_NO_CLEAR:-} ]] && clear; }

header() {
  clear_screen
  printf '\n  %s%s♪ ♫  BLUETOOTH JAM SESSION  ♫ ♪%s\n' "$C_MAGENTA" "$C_BOLD" "$C_RESET"
  printf '  %smake all your speakers play together%s\n' "$C_DIM" "$C_RESET"
  line
  [[ -n ${1:-} ]] && { printf '  %s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; line; }
}

# ---------- prompts ---------------------------------------------------
# ask "Prompt"  -> answer in $ANSWER (trimmed). Returns 1 on end-of-input.
ask() {
  printf '\n  %s➜%s %s ' "$C_BOLD$C_CYAN" "$C_RESET" "$1"
  IFS= read -r ANSWER || { echo; ANSWER=''; return 1; }
  ANSWER="${ANSWER#"${ANSWER%%[![:space:]]*}"}"
  ANSWER="${ANSWER%"${ANSWER##*[![:space:]]}"}"
  return 0
}

# confirm "Question" [y|n default]  -> 0 for yes
confirm() {
  local def=${2:-y} hint='[Y/n]'
  [[ $def == n ]] && hint='[y/N]'
  ask "$1 $hint" || return 1
  [[ -z $ANSWER ]] && ANSWER=$def
  [[ ${ANSWER,,} == y* ]]
}

pause() { printf '\n  %sPress Enter to continue…%s' "$C_DIM" "$C_RESET"; read -r _ || true; }

# pick_many COUNT -> fills PICKED with 0-based indexes.
# Accepts "1 3", "1,3", "2-4", "a"/"all".
pick_many() {
  local n=$1 tok a b i
  PICKED=()
  ask "Choose speakers (e.g. ${C_BOLD}1 3${C_RESET}, ${C_BOLD}1-3${C_RESET}, or ${C_BOLD}a${C_RESET} for all — Enter to cancel):" || return 1
  [[ -z $ANSWER ]] && return 1
  if [[ ${ANSWER,,} == a || ${ANSWER,,} == all ]]; then
    for ((i = 0; i < n; i++)); do PICKED+=("$i"); done
    return 0
  fi
  for tok in ${ANSWER//,/ }; do
    if [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
    elif [[ $tok =~ ^[0-9]+$ ]]; then a=$((10#$tok)) b=$a
    else warn "Ignoring '$tok' (not a number)"; continue
    fi
    for ((i = a; i <= b; i++)); do
      if ((i >= 1 && i <= n)) && [[ " ${PICKED[*]} " != *" $((i - 1)) "* ]]; then
        PICKED+=("$((i - 1))")
      fi
    done
  done
  ((${#PICKED[@]} > 0)) || { warn "No valid numbers picked."; return 1; }
}

# pick_one COUNT "prompt" -> PICKED_ONE (0-based)
pick_one() {
  local n=$1
  ask "${2:-Choose a number} (1-$n, Enter to cancel):" || return 1
  [[ $ANSWER =~ ^[0-9]+$ ]] || return 1
  PICKED_ONE=$((10#$ANSWER - 1))
  ((PICKED_ONE >= 0 && PICKED_ONE < n)) || { warn "That number isn't on the list."; return 1; }
}

# ask_percent "prompt" -> PERCENT (0-150)
ask_percent() {
  ask "$1 (0-150):" || return 1
  [[ $ANSWER =~ ^[0-9]+%?$ ]] || { warn "Please type a number like 60."; return 1; }
  PERCENT=$((10#${ANSWER%\%}))
  ((PERCENT > 150)) && PERCENT=150
  return 0
}

# ---------- remembered speaker names ----------------------------------
name_remember() {
  local mac=${1^^} name=$2
  [[ -z $name ]] && return 0
  grep -qxF "$mac|$name" "$NAMES_FILE" 2>/dev/null && return 0
  grep -viF "$mac|" "$NAMES_FILE" >"$NAMES_FILE.tmp" 2>/dev/null
  printf '%s|%s\n' "$mac" "$name" >>"$NAMES_FILE.tmp"
  mv "$NAMES_FILE.tmp" "$NAMES_FILE"
}

name_of() {
  local mac=${1^^} n
  n=$(grep -iF "$mac|" "$NAMES_FILE" 2>/dev/null | head -1 | cut -d'|' -f2-)
  if [[ -z $n ]] && command -v bluetoothctl >/dev/null 2>&1; then
    n=$(btctl info "$mac" 2>/dev/null | sed -n 's/^[[:space:]]*Alias: //p' | head -1)
  fi
  printf '%s' "${n:-$mac}"
}

progress_bar() {             # progress_bar SECONDS LABEL
  local secs=$1 label=$2 i w=30 f
  ((secs < 1)) && secs=1
  for ((i = 0; i <= secs; i++)); do
    f=$((i * w / secs))
    printf '\r  %s %s%s%s%s %2ds ' "$label" "$C_CYAN" "$(rep '█' "$f")" "$(rep '░' $((w - f)))" "$C_RESET" $((secs - i))
    ((i < secs)) && sleep 1
  done
  echo
}
