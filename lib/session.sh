#!/usr/bin/env bash
# =====================================================================
#  lib/session.sh — the jam itself: one "combined" output that feeds
#  every speaker at once (module-combine-sink), rebuilt on the fly.
# =====================================================================

jam_sink()   { pa list short sinks 2>/dev/null | awk '$2 ~ /^bt_jam_/ {print $2; exit}'; }
jam_active() { [[ -n $(jam_sink) ]]; }

# MACs that belong to the running jam (including ones that dropped out)
jam_members() { jam_active && [[ -f $MEMBERS_FILE ]] && grep -v '^$' "$MEMBERS_FILE"; }

jam_is_member() { jam_members | grep -qxiF "$1"; }

# Members whose speaker is currently missing (out of range / switched off)
jam_dropped() {
  local m
  for m in $(jam_members); do [[ -z $(audio_sink_for_mac "$m") ]] && echo "$m"; done
}

jam_module_for() {               # SINK -> module index
  local m
  m=$(audio_sink_owner_module "$1")
  [[ -z $m || $m == n/a ]] && m=$(pa list short modules 2>/dev/null |
    awk -v n="sink_name=$1" '/module-combine-sink/ && index($0, n) {print $1; exit}')
  printf '%s' "$m"
}

# Build (or rebuild) the jam with these speaker MACs.
# Rebuilding creates the new combined output FIRST, moves the music over,
# and only then removes the old one — so the music never stops.
jam_build() {
  local mac s old new mod vol='' muted='' cur slaves
  local sinks=() macs=()
  for mac in "$@"; do
    mac=${mac^^}
    [[ " ${macs[*]} " == *" $mac "* ]] && continue
    s=$(audio_sink_for_mac "$mac")
    if [[ -n $s ]]; then sinks+=("$s"); macs+=("$mac")
    else warn "$(name_of "$mac") isn't connected right now — leaving it out."
    fi
  done
  ((${#sinks[@]})) || { err "None of those speakers is connected, so there's nothing to jam with."; return 1; }

  old=$(jam_sink)
  new="${JAM_SINK_PREFIX}a"
  [[ $old == "$new" ]] && new="${JAM_SINK_PREFIX}b"

  if [[ -n $old ]]; then
    vol=$(audio_get_volume "$old")
    muted=$(audio_get_mute "$old")
  else
    cur=$(audio_default_sink)
    [[ -n $cur && $cur != "$JAM_SINK_PREFIX"* ]] && printf '%s\n' "$cur" >"$PREV_SINK_FILE"
  fi

  slaves=$(IFS=,; printf '%s' "${sinks[*]}")
  mod=$(pa load-module module-combine-sink "sink_name=$new" "slaves=$slaves" \
        "sink_properties=device.description=$JAM_DESC" 2>>"$LOG_FILE")
  if [[ -z $mod ]] || ! audio_wait_for_named_sink "$new" 5; then
    err "The sound system refused to combine the speakers (details in $LOG_FILE)."
    [[ -n $mod ]] && pa unload-module "$mod" >>"$LOG_FILE" 2>&1
    return 1
  fi

  [[ -n $vol ]] && audio_set_volume "$new" "$vol"
  [[ $muted == yes ]] && audio_set_mute "$new" 1
  pa set-default-sink "$new" >>"$LOG_FILE" 2>&1    # new apps play to the jam
  audio_move_user_streams "$new"                     # already-playing apps move over

  if [[ -n $old ]]; then
    local om; om=$(jam_module_for "$old")
    [[ -n $om ]] && pa unload-module "$om" >>"$LOG_FILE" 2>&1
  fi
  printf '%s\n' "${macs[@]}" >"$MEMBERS_FILE"
  log "jam $new <- $slaves"
  return 0
}

# Stop the jam and send audio back to wherever it was playing before.
jam_stop() {
  local sink target om
  sink=$(jam_sink)
  [[ -z $sink ]] && return 0
  target=$(cat "$PREV_SINK_FILE" 2>/dev/null)
  if [[ -z $target ]] || ! audio_sink_exists "$target"; then
    target=$(pa list short sinks 2>/dev/null | awk '$2 !~ /^bt_jam_/ {print $2; exit}')
  fi
  if [[ -n $target ]]; then
    pa set-default-sink "$target" >>"$LOG_FILE" 2>&1
    audio_move_user_streams "$target"
  fi
  om=$(jam_module_for "$sink")
  [[ -n $om ]] && pa unload-module "$om" >>"$LOG_FILE" 2>&1
  rm -f "$PREV_SINK_FILE" "$MEMBERS_FILE"
  log "jam stopped (audio back on ${target:-nothing})"
}

jam_add() {                      # MAC… (already connected)
  local current; mapfile -t current < <(jam_members)
  jam_build "${current[@]}" "$@"
}

jam_remove() {                   # MAC  — rebuild without it (music keeps going)
  local m rest=()
  for m in $(jam_members); do [[ ${m^^} != "${1^^}" ]] && rest+=("$m"); done
  if ((${#rest[@]} == 0)); then jam_stop; return 0; fi
  jam_build "${rest[@]}"
}

jam_swap() {                     # OLD_MAC NEW_MAC (new must be connected)
  local m list=()
  for m in $(jam_members); do [[ ${m^^} != "${1^^}" ]] && list+=("$m"); done
  list+=("$2")
  jam_build "${list[@]}"
}

# ---------- volume -----------------------------------------------------
jam_volume() { audio_get_volume "$(jam_sink)"; }
jam_set_volume() { audio_set_volume "$(jam_sink)" "$1"; }
jam_change_volume() {
  local v; v=$(jam_volume); v=${v:-100}
  jam_set_volume $((v + $1))
}
jam_toggle_mute() { audio_set_mute "$(jam_sink)" toggle; }
jam_muted() { [[ $(audio_get_mute "$(jam_sink)") == yes ]]; }
