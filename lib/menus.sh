#!/usr/bin/env bash
# =====================================================================
#  lib/menus.sh — the friendly numbered menus
# =====================================================================

# ---------- small display helpers --------------------------------------
status_tag() {
  local mac=$1
  if jam_is_member "$mac"; then
    if [[ -n $(audio_sink_for_mac "$mac") ]]; then printf '%s🎵 in the jam%s' "$C_GREEN" "$C_RESET"
    else printf '%s⚠ dropped out%s' "$C_YELLOW" "$C_RESET"; fi
  elif [[ -n $(audio_sink_for_mac "$mac") ]]; then printf '%s● connected%s' "$C_CYAN" "$C_RESET"
  elif bt_paired "$mac"; then printf '%s○ paired before%s' "$C_DIM" "$C_RESET"
  else printf '%s✚ new%s' "$C_BLUE" "$C_RESET"
  fi
}

SPK_MACS=() SPK_NAMES=()
load_speakers() {               # [all] [exclude-jam]
  local mac name
  SPK_MACS=() SPK_NAMES=()
  while IFS='|' read -r mac name; do
    [[ ${2:-} == exclude-jam ]] && jam_is_member "$mac" && continue
    SPK_MACS+=("$mac"); SPK_NAMES+=("$name")
    name_remember "$mac" "$name"
  done < <(bt_list_speakers "${1:-}")
}

show_speakers() {
  local i
  for i in "${!SPK_MACS[@]}"; do
    printf '   %s%2d)%s %-30s %s\n' "$C_BOLD" $((i + 1)) "$C_RESET" "${SPK_NAMES[i]:0:30}" "$(status_tag "${SPK_MACS[i]}")"
  done
}

# Load the list of a set of MACs into SPK_* (for picking members etc.)
load_macs() {
  local m
  SPK_MACS=() SPK_NAMES=()
  for m in "$@"; do SPK_MACS+=("$m"); SPK_NAMES+=("$(name_of "$m")"); done
}

status_banner() {
  local js n vol live=0 total=0 m
  js=$(jam_sink)
  if [[ -n $js ]]; then
    vol=$(audio_get_volume "$js")
    for m in $(jam_members); do
      ((total += 1))
      [[ -n $(audio_sink_for_mac "$m") ]] && ((live += 1))
    done
    printf '  %s● JAM IS LIVE%s on %d speaker(s)   volume %s%%' "$C_GREEN$C_BOLD" "$C_RESET" "$live" "${vol:-?}"
    jam_muted && printf '   %s🔇 MUTED%s' "$C_RED$C_BOLD" "$C_RESET"
    echo
    ((live < total)) && printf '  %s⚠ %d speaker(s) dropped out — fix it in "Manage speakers".%s\n' "$C_YELLOW" $((total - live)) "$C_RESET"
  else
    n=$(audio_bt_macs | grep -c .)
    printf '  %s○ No jam running%s   %d Bluetooth speaker(s) connected\n' "$C_DIM" "$C_RESET" "$n"
  fi
  player_running && printf '  ♫ Playing: %s\n' "$(basename "$(cat "$PLAYER_NOW_FILE" 2>/dev/null)")"
  line
}

# ---------- scanning + picking ------------------------------------------
# scan_and_pick [exclude-jam]  -> PICKED_MACS
scan_and_pick() {
  local i
  PICKED_MACS=()
  echo
  echo "  ${C_BOLD}Get your speakers ready:${C_RESET}"
  echo "   1. Switch them ON."
  echo "   2. Put them in pairing mode (usually hold the Bluetooth button"
  echo "      until the light flashes). Already-paired speakers just need to be on."
  echo "   3. Disconnect them from any phone."
  pause
  bt_scan "$SCAN_SECS"
  load_speakers "" "${1:-}"
  if ((${#SPK_MACS[@]} == 0)); then
    warn "No speakers found."
    if confirm "Show ALL Bluetooth devices instead (some speakers don't say they're speakers)?" y; then
      load_speakers all "${1:-}"
    fi
  fi
  if ((${#SPK_MACS[@]} == 0)); then
    err "Still nothing found. Make sure the speakers are on and flashing, then try again."
    return 1
  fi
  echo
  echo "  ${C_BOLD}Speakers found:${C_RESET}"
  show_speakers
  pick_many "${#SPK_MACS[@]}" || return 1
  for i in "${PICKED[@]}"; do PICKED_MACS+=("${SPK_MACS[i]}"); done
}

# connect_macs MAC… -> CONNECTED_MACS (the ones that worked)
connect_macs() {
  local m i=0
  CONNECTED_MACS=()
  for m in "$@"; do
    ((i += 1))
    printf '\n  %s[%d/%d] %s%s\n' "$C_BOLD" "$i" "$#" "$(name_of "$m")" "$C_RESET"
    bt_connect "$m" && CONNECTED_MACS+=("$m")
  done
  echo
  ((${#CONNECTED_MACS[@]})) && ok "${#CONNECTED_MACS[@]} of $# speaker(s) connected."
}

celebrate() {
  local n; n=$(jam_members | grep -c .)
  echo
  printf '  %s🎉  JAM IS LIVE on %d speaker(s)!%s\n' "$C_GREEN$C_BOLD" "$n" "$C_RESET"
  echo "  Play music from ANY app — Spotify, YouTube in your browser, VLC…"
  echo "  It all goes to every speaker. (Or use 'Play music' in the main menu.)"
  if confirm "Play a quick test beep on all speakers now?" y; then
    audio_beep "$(jam_sink)" && ok "Beep sent — you should hear it from every speaker."
  fi
}

# ---------- 1. Quick Jam ------------------------------------------------
quick_jam() {
  header "⚡ Quick Jam — pick speakers, press go"
  if jam_active; then
    warn "A jam is already live. Use 'Manage speakers' to add more."
    pause; return
  fi
  scan_and_pick || { pause; return; }
  connect_macs "${PICKED_MACS[@]}"
  if ((${#CONNECTED_MACS[@]} == 0)); then
    err "No speakers could be connected, so the jam can't start."
    pause; return
  fi
  ((${#CONNECTED_MACS[@]} == 1)) && warn "Only one speaker is connected — starting with it. You can add more any time."
  info "Linking the speakers together…"
  jam_build "${CONNECTED_MACS[@]}" && celebrate
  pause
}

# ---------- 2. Scan & connect --------------------------------------------
menu_connect() {
  header "🔍 Find & connect speakers"
  scan_and_pick exclude-jam || { pause; return; }
  connect_macs "${PICKED_MACS[@]}"
  if ((${#CONNECTED_MACS[@]})) && jam_active; then
    confirm "Add them to the running jam now?" y && jam_add "${CONNECTED_MACS[@]}" && ok "Added — the music never stopped."
  elif ((${#CONNECTED_MACS[@]})); then
    info "Next: choose 'Start the jam' from the main menu."
  fi
  pause
}

# ---------- 3. Start jam --------------------------------------------------
menu_start_jam() {
  header "▶ Start the jam"
  if jam_active; then warn "The jam is already live."; pause; return; fi
  local macs i
  mapfile -t macs < <(audio_bt_macs)
  if ((${#macs[@]} == 0)); then
    warn "No Bluetooth speakers are connected yet."
    confirm "Find and connect some now?" y && { quick_jam; return; }
    pause; return
  fi
  load_macs "${macs[@]}"
  echo "  ${C_BOLD}Connected speakers:${C_RESET}"
  show_speakers
  local chosen=()
  if ((${#macs[@]} == 1)); then
    warn "Only one speaker is connected. The jam will start with it; add more later."
    chosen=("${macs[@]}")
  elif confirm "Use all ${#macs[@]} speakers?" y; then
    chosen=("${macs[@]}")
  else
    pick_many "${#macs[@]}" || { pause; return; }
    for i in "${PICKED[@]}"; do chosen+=("${macs[i]}"); done
  fi
  info "Linking the speakers together…"
  jam_build "${chosen[@]}" && celebrate
  pause
}

# ---------- 4. Session controls ------------------------------------------
pick_member() {                  # -> PICKED_MAC
  local members; mapfile -t members < <(jam_members)
  ((${#members[@]})) || { warn "No speakers in the jam."; return 1; }
  load_macs "${members[@]}"
  show_speakers
  pick_one "${#members[@]}" "${1:-Which speaker?}" || return 1
  PICKED_MAC=${members[PICKED_ONE]}
}

speaker_level() {
  local s
  pick_member "Which speaker's level?" || return
  s=$(audio_sink_for_mac "$PICKED_MAC")
  [[ -z $s ]] && { warn "That speaker isn't connected right now."; return; }
  info "$(name_of "$PICKED_MAC") is at $(audio_get_volume "$s")% (its own level, on top of the jam volume)."
  ask_percent "New level for this speaker" || return
  audio_set_volume "$s" "$PERCENT" && ok "Set to $PERCENT%."
}

speaker_delay() {
  local cur
  echo "  If you hear an echo between speakers, one is playing a little early."
  echo "  Add a small delay (e.g. 50–200 ms) to the speaker that sounds ${C_BOLD}ahead${C_RESET}."
  pick_member "Which speaker is ahead?" || return
  cur=$(audio_get_offset_ms "$PICKED_MAC")
  if [[ -z $cur ]]; then warn "This speaker doesn't support delay adjustment on your system."; return; fi
  info "Current extra delay: ${cur} ms"
  ask "New delay in ms (0-1000):" || return
  [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER <= 1000)) || { warn "Please type a number from 0 to 1000."; return; }
  audio_set_offset_ms "$PICKED_MAC" "$((10#$ANSWER))" && ok "Delay set to $((10#$ANSWER)) ms. Listen, and adjust again if needed."
}

stop_jam_flow() {
  confirm "Stop the jam? (music goes back to your normal output)" y || return 1
  player_running && confirm "Also stop the music player?" y && player_stop
  local members; mapfile -t members < <(jam_members)
  jam_stop && ok "Jam stopped."
  if ((${#members[@]})) && confirm "Disconnect the Bluetooth speakers too?" n; then
    local m; for m in "${members[@]}"; do bt_disconnect "$m"; done
    ok "Speakers disconnected."
  fi
  return 0
}

menu_controls() {
  while true; do
    header "🎚  Session controls"
    if ! jam_active; then warn "No jam is running. Start one first."; pause; return; fi
    status_banner
    cat <<EOF
   ${C_BOLD}1)${C_RESET} 🔊 Volume up   (+10%)
   ${C_BOLD}2)${C_RESET} 🔉 Volume down (−10%)
   ${C_BOLD}3)${C_RESET} 🎯 Set an exact volume
   ${C_BOLD}4)${C_RESET} 🔇 Mute / unmute everything
   ${C_BOLD}5)${C_RESET} ⚖  Balance: set one speaker louder/quieter
   ${C_BOLD}6)${C_RESET} ⏱  Fix echo: delay one speaker (advanced)
   ${C_BOLD}7)${C_RESET} ⏹  Stop the jam
   ${C_BOLD}0)${C_RESET} ↩  Back
EOF
    ask "Choose:" || return
    case $ANSWER in
      1) jam_change_volume 10 ;;
      2) jam_change_volume -10 ;;
      3) ask_percent "Volume for all speakers" && jam_set_volume "$PERCENT" ;;
      4) jam_toggle_mute; if jam_muted; then ok "Everything muted."; else ok "Sound is back."; fi; sleep 0.6 ;;
      5) speaker_level; pause ;;
      6) speaker_delay; pause ;;
      7) stop_jam_flow && { pause; return; } ;;
      0 | '') return ;;
      *) warn "Please type a number from the menu."; sleep 0.8 ;;
    esac
  done
}

# ---------- 5. Manage speakers --------------------------------------------
add_speaker() {
  scan_and_pick exclude-jam || return
  connect_macs "${PICKED_MACS[@]}"
  ((${#CONNECTED_MACS[@]})) || return
  if jam_active; then
    jam_add "${CONNECTED_MACS[@]}" && ok "Added to the jam — the music kept playing."
  else
    local all; mapfile -t all < <(audio_bt_macs)
    confirm "Start a jam with all connected speakers now?" y && jam_build "${all[@]}" && celebrate
  fi
}

remove_speaker() {
  pick_member "Which speaker should leave the jam?" || return
  local mac=$PICKED_MAC name; name=$(name_of "$mac")
  [[ $(jam_members | grep -c .) -eq 1 ]] && warn "That's the last speaker — removing it ends the jam."
  jam_remove "$mac" && ok "$name left the jam."
  confirm "Disconnect $name from Bluetooth as well?" y && bt_disconnect "$mac" && ok "$name disconnected."
}

swap_speaker() {
  echo "  ${C_BOLD}Step 1:${C_RESET} which speaker do you want to swap OUT?"
  pick_member "Swap out" || return
  local old=$PICKED_MAC
  echo; echo "  ${C_BOLD}Step 2:${C_RESET} find the speaker to swap IN."
  scan_and_pick exclude-jam || return
  local new=${PICKED_MACS[0]}
  ((${#PICKED_MACS[@]} > 1)) && info "Using the first one you picked: $(name_of "$new")"
  connect_macs "$new"
  if ((${#CONNECTED_MACS[@]} == 0)); then
    warn "Couldn't connect the new speaker, so nothing was swapped — $(name_of "$old") keeps playing."
    return
  fi
  jam_swap "$old" "$new" || return
  ok "Swapped: $(name_of "$new") is in, $(name_of "$old") is out. Music never stopped."
  confirm "Disconnect $(name_of "$old") from Bluetooth?" y && bt_disconnect "$old"
}

reconnect_dropped() {
  local dropped; mapfile -t dropped < <(jam_dropped)
  if ((${#dropped[@]} == 0)); then ok "Every speaker in the jam is connected."; return; fi
  info "Reconnecting ${#dropped[@]} speaker(s)…"
  connect_macs "${dropped[@]}"
  local members; mapfile -t members < <(jam_members)
  if ((${#CONNECTED_MACS[@]})); then
    jam_build "${members[@]}" && ok "Back in the jam."
  else
    warn "Couldn't reach them. Are they on and in range?"
    if confirm "Remove them from the jam list?" n; then jam_build "${members[@]}"; fi
  fi
}

identify_speaker() {
  local macs; mapfile -t macs < <(audio_bt_macs)
  ((${#macs[@]})) || { warn "No speakers connected."; return; }
  load_macs "${macs[@]}"
  show_speakers
  pick_one "${#macs[@]}" "Which one should beep?" || return
  audio_beep "$(audio_sink_for_mac "${macs[PICKED_ONE]}")" 880 && ok "Beep! That was ${SPK_NAMES[PICKED_ONE]}."
}

forget_speaker() {
  load_speakers ""
  ((${#SPK_MACS[@]})) || { warn "No known speakers."; return; }
  show_speakers
  pick_one "${#SPK_MACS[@]}" "Which speaker should be forgotten (unpaired)?" || return
  local mac=${SPK_MACS[PICKED_ONE]}
  jam_is_member "$mac" && jam_remove "$mac"
  bt_forget "$mac" && ok "Forgotten. It will need pairing mode next time."
}

menu_manage() {
  while true; do
    header "🔧 Manage speakers (works while music plays)"
    status_banner
    if jam_active; then
      echo "  ${C_BOLD}In this jam:${C_RESET}"
      local mem; mapfile -t mem < <(jam_members)
      load_macs "${mem[@]}"; show_speakers; line
    fi
    cat <<EOF
   ${C_BOLD}1)${C_RESET} ➕ Add a speaker
   ${C_BOLD}2)${C_RESET} ➖ Remove a speaker
   ${C_BOLD}3)${C_RESET} 🔁 Swap one speaker for another
   ${C_BOLD}4)${C_RESET} 🔌 Reconnect speakers that dropped out
   ${C_BOLD}5)${C_RESET} 🔔 Which speaker is which? (beep one)
   ${C_BOLD}6)${C_RESET} 🗑  Forget (unpair) a speaker
   ${C_BOLD}0)${C_RESET} ↩  Back
EOF
    ask "Choose:" || return
    case $ANSWER in
      1) add_speaker; pause ;;
      2) if jam_active; then remove_speaker; else warn "No jam running."; fi; pause ;;
      3) if jam_active; then swap_speaker; else warn "No jam running."; fi; pause ;;
      4) if jam_active; then reconnect_dropped; else warn "No jam running."; fi; pause ;;
      5) identify_speaker; pause ;;
      6) forget_speaker; pause ;;
      0 | '') return ;;
      *) warn "Please type a number from the menu."; sleep 0.8 ;;
    esac
  done
}

# ---------- 6. Music --------------------------------------------------------
player_running() { [[ -f $PLAYER_PID_FILE ]] && kill -0 "$(cat "$PLAYER_PID_FILE")" 2>/dev/null; }

player_stop() {
  local pid
  pid=$(cat "$PLAYER_PID_FILE" 2>/dev/null)
  if [[ -n $pid ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  fi
  rm -f "$PLAYER_PID_FILE" "$PLAYER_NOW_FILE"
}

player_start() {
  local p=$1
  p=${p#[\'\"]}; p=${p%[\'\"]}          # strip quotes from drag-and-drop
  p=${p/#\~/$HOME}
  [[ -e $p ]] || { err "Can't find: $p"; return 1; }
  "$JAM_HOME/lib/player.sh" --check >/dev/null || {
    err "No music player found. Install one:  sudo apt install mpv   (or ffmpeg / vlc)"
    return 1
  }
  player_running && player_stop
  if command -v setsid >/dev/null 2>&1; then
    setsid "$JAM_HOME/lib/player.sh" "$p" "$(jam_sink)" >>"$LOG_FILE" 2>&1 </dev/null &
  else
    "$JAM_HOME/lib/player.sh" "$p" "$(jam_sink)" >>"$LOG_FILE" 2>&1 </dev/null &
  fi
  echo $! >"$PLAYER_PID_FILE"
  printf '%s\n' "$p" >"$PLAYER_NOW_FILE"
  ok "Playing $(basename "$p")"
}

menu_play() {
  while true; do
    header "🎵 Play music / test sound"
    jam_active || warn "No jam running — sound will go to your normal output."
    status_banner
    cat <<EOF
   ${C_BOLD}1)${C_RESET} ▶  Play a song or a whole music folder
   ${C_BOLD}2)${C_RESET} ⏹  Stop the music
   ${C_BOLD}3)${C_RESET} 🔔 Test beep on all speakers
   ${C_BOLD}4)${C_RESET} 🔔 Beep one speaker (find which is which)
   ${C_BOLD}0)${C_RESET} ↩  Back

  ${C_DIM}Tip: you don't need this menu — Spotify, your browser, VLC… all play
  to the jam automatically while it's live.${C_RESET}
EOF
    ask "Choose:" || return
    case $ANSWER in
      1) ask "Type or drag-and-drop a music file or folder (e.g. ~/Music):" && [[ -n $ANSWER ]] && player_start "$ANSWER"; pause ;;
      2) if player_running; then player_stop; ok "Music stopped."; else info "Nothing is playing from here."; fi; pause ;;
      3) local s; s=$(jam_sink); s=${s:-$(audio_default_sink)}; audio_beep "$s" && ok "Beep sent."; pause ;;
      4) identify_speaker; pause ;;
      0 | '') return ;;
      *) warn "Please type a number from the menu."; sleep 0.8 ;;
    esac
  done
}

# ---------- 7. Status ---------------------------------------------------------
show_status() {
  header "📋 Status"
  local js m s off
  printf '  %-18s %s\n' "Sound system:" "$(audio_server)"
  printf '  %-18s %s\n' "Bluetooth:" "$(btctl show 2>/dev/null | grep -q 'Powered: yes' && echo on || echo off)"
  js=$(jam_sink)
  if [[ -n $js ]]; then
    printf '  %-18s %s (volume %s%%, muted: %s)\n' "Jam:" "${C_GREEN}LIVE${C_RESET}" "$(audio_get_volume "$js")" "$(audio_get_mute "$js")"
    echo; echo "  ${C_BOLD}Speakers in the jam:${C_RESET}"
    for m in $(jam_members); do
      s=$(audio_sink_for_mac "$m")
      if [[ -n $s ]]; then
        off=$(audio_get_offset_ms "$m")
        printf '   • %-28s level %4s%%   delay %s ms\n' "$(name_of "$m")" "$(audio_get_volume "$s")" "${off:-–}"
      else
        printf '   • %-28s %s\n' "$(name_of "$m")" "${C_YELLOW}dropped out${C_RESET}"
      fi
    done
  else
    printf '  %-18s %s\n' "Jam:" "not running"
  fi
  local others=()
  for m in $(audio_bt_macs); do jam_is_member "$m" || others+=("$(name_of "$m")"); done
  ((${#others[@]})) && { echo; echo "  ${C_BOLD}Connected but not in the jam:${C_RESET}"; printf '   • %s\n' "${others[@]}"; }
  echo
  if player_running; then printf '  %-18s %s\n' "Music:" "$(cat "$PLAYER_NOW_FILE")"; fi
  printf '  %-18s %s\n' "Log file:" "$LOG_FILE"
  pause
}

# ---------- 8. Help -------------------------------------------------------------
show_help() {
  header "❓ Help"
  cat <<EOF
  ${C_BOLD}The fastest way:${C_RESET} choose ${C_BOLD}1) Quick Jam${C_RESET}, switch your speakers on,
  pick them from the list (type ${C_BOLD}a${C_RESET} for all) — done. Then play music
  from any app.

  ${C_BOLD}How it works:${C_RESET} the tool creates one virtual speaker called
  "$JAM_DESC" that copies sound to every real speaker, and makes it
  your computer's default output. Adding or removing a speaker swaps in
  a new virtual speaker without stopping the music.

  ${C_BOLD}Good to know${C_RESET}
   • Most Bluetooth adapters handle 2–4 speakers at once. A cheap USB
     Bluetooth dongle can add more.
   • Bluetooth speakers have small built-in delays. In the same room you
     may hear a slight echo: use Session controls → "Fix echo".
     In different rooms you won't notice.
   • Speaker not found? Disconnect it from your phone and hold its
     Bluetooth button until it flashes, then scan again.
   • Choppy sound? Move speakers closer, or use fewer at once.
   • Closing this menu leaves the jam playing.
     Stop it any time with:  ./jam.sh --stop

  ${C_BOLD}Command line:${C_RESET}  ./jam.sh --status | --stop | --help
EOF
  pause
}

# ---------- main menu ----------------------------------------------------------
main_menu() {
  while true; do
    header
    status_banner
    cat <<EOF
   ${C_BOLD}1)${C_RESET} ⚡ ${C_BOLD}Quick Jam${C_RESET} — find speakers & start playing
   ${C_BOLD}2)${C_RESET} 🔍 Find & connect speakers
   ${C_BOLD}3)${C_RESET} ▶  Start the jam (with connected speakers)
   ${C_BOLD}4)${C_RESET} 🎚  Session controls — volume, mute, stop
   ${C_BOLD}5)${C_RESET} 🔧 Manage speakers — add, remove, swap
   ${C_BOLD}6)${C_RESET} 🎵 Play music / test sound
   ${C_BOLD}7)${C_RESET} 📋 Status
   ${C_BOLD}8)${C_RESET} ❓ Help
   ${C_BOLD}0)${C_RESET} 🚪 Quit
EOF
    ask "Choose:" || { quit_flow eof; return; }
    case $ANSWER in
      1) quick_jam ;;
      2) menu_connect ;;
      3) menu_start_jam ;;
      4) menu_controls ;;
      5) menu_manage ;;
      6) menu_play ;;
      7) show_status ;;
      8 | h | help | '?') show_help ;;
      0 | q | quit | exit) quit_flow; return ;;
      '') ;;
      *) warn "Please type a number from 0 to 8."; sleep 0.8 ;;
    esac
  done
}

quit_flow() {
  if [[ ${1:-} != eof ]] && jam_active; then
    if confirm "The jam keeps playing after you quit. Stop it now?" n; then
      player_running && player_stop
      jam_stop && ok "Jam stopped."
    else
      info "Jam left running. Stop it later with:  ./jam.sh --stop"
    fi
  fi
  echo; echo "  Bye! 🎶"; echo
}
