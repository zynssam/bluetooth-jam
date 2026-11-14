#!/usr/bin/env bash
# =====================================================================
#  lib/player.sh — plays a song or a whole folder through the jam.
#  Usage:  player.sh FILE_OR_FOLDER [SINK]      (runs in the background)
#          player.sh --check                    (prints the player it'd use)
#  Uses whichever command-line player is installed: mpv, ffplay, cvlc,
#  pw-play or paplay.
# =====================================================================

find_player() {
  local p
  for p in mpv ffplay cvlc pw-play paplay; do
    command -v "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
  done
  return 1
}

if [[ ${1:-} == --check ]]; then find_player; exit; fi

target=$1 sink=${2:-}
player=$(find_player) || { echo "player.sh: no audio player found" >&2; exit 1; }
[[ -n $sink ]] && export PULSE_SINK=$sink   # PulseAudio clients honour this

files=()
if [[ -d $target ]]; then
  while IFS= read -r f; do files+=("$f"); done < <(
    find "$target" -maxdepth 3 -type f \
      \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.ogg' -o -iname '*.oga' -o -iname '*.opus' \
         -o -iname '*.wav' -o -iname '*.m4a' -o -iname '*.aac' \) | sort)
else
  files=("$target")
fi
((${#files[@]})) || { echo "player.sh: no music files in $target" >&2; exit 1; }

for f in "${files[@]}"; do
  echo "Now playing: $f"
  case $player in
    mpv)     mpv --no-video --really-quiet "$f" ;;
    ffplay)  ffplay -nodisp -autoexit -loglevel quiet "$f" ;;
    cvlc)    cvlc --play-and-exit --quiet "$f" ;;
    pw-play) pw-play ${sink:+--target "$sink"} "$f" ;;
    paplay)  paplay ${sink:+--device="$sink"} "$f" ;;
  esac
done
