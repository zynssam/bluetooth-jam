#!/usr/bin/env bash
# =====================================================================
#  tests/run_tests.sh — tests the whole jam without real hardware.
#  It creates fake "bluetoothctl", "pactl" and "paplay" commands that
#  behave like a PipeWire system with Bluetooth speakers, then drives
#  the library functions and the real menu.
#  Run:  ./tests/run_tests.sh
# =====================================================================

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export MOCK_DIR="$WORK/mock" BTJAM_STATE_DIR="$WORK/state" BTJAM_SCAN_SECS=1 BTJAM_NO_CLEAR=1 NO_COLOR=1
mkdir -p "$MOCK_DIR" "$WORK/bin"
export PATH="$WORK/bin:$PATH"

PASS=0 FAIL=0
check() {   # check "description" command...
  if "${@:2}"; then PASS=$((PASS + 1)); printf '  ✔ %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  ✖ %s\n' "$1"; fi
}

# ---------------------------------------------------------------------
# Fake world
# ---------------------------------------------------------------------
reset_world() {
  rm -rf "${MOCK_DIR:?}"/* "${BTJAM_STATE_DIR:?}"
  mkdir -p "$BTJAM_STATE_DIR"
  echo 100 >"$MOCK_DIR/next"
  echo yes >"$MOCK_DIR/powered"
  # MAC|Name|audio|paired|connected|in-range
  cat >"$MOCK_DIR/devices" <<'EOF'
AA:AA:AA:00:00:01|JBL Flip 5|1|no|no|1
AA:AA:AA:00:00:02|Sony XB13|1|yes|no|1
11:22:33:44:55:66|Logitech Mouse|0|yes|yes|1
AA:AA:AA:00:00:03|Anker Soundcore|1|no|no|1
AA:AA:AA:00:00:04|Old Party Box|1|yes|no|0
EOF
  # sinks: idx|name|owner-module|volume|mute
  echo "50|alsa_output.pci-0000_00_1f.3.analog-stereo|3|100|no" >"$MOCK_DIR/sinks"
  : >"$MOCK_DIR/modules"
  # inputs: idx|sink-name|client|kind|label   (a music app already playing)
  echo "70|alsa_output.pci-0000_00_1f.3.analog-stereo|42|user|Spotify" >"$MOCK_DIR/inputs"
  echo "alsa_output.pci-0000_00_1f.3.analog-stereo" >"$MOCK_DIR/default"
  : >"$MOCK_DIR/offsets"; : >"$MOCK_DIR/played"; : >"$MOCK_DIR/errors"
}

cat >"$WORK/bin/pactl" <<'MOCK'
#!/usr/bin/env bash
D=$MOCK_DIR
next() { local n; n=$(cat "$D/next"); echo $((n + 1)) >"$D/next"; echo "$n"; }
sidx() { awk -F'|' -v n="$1" '$2==n{print $1}' "$D/sinks"; }
exists() { awk -F'|' -v n="$1" '$2==n{f=1} END{exit !f}' "$D/sinks"; }
upd_sink() { awk -F'|' -v OFS='|' -v n="$1" -v c="$2" -v v="$3" '$2==n{$c=v} 1' "$D/sinks" >"$D/t" && mv "$D/t" "$D/sinks"; }
case "$1" in
  info) echo "Server Name: PulseAudio (on PipeWire 1.0.5)"; echo "Default Sink: $(cat "$D/default")" ;;
  get-default-sink) cat "$D/default" ;;
  list)
    if [[ $2 == short ]]; then
      case $3 in
        sinks) awk -F'|' '{printf "%s\t%s\tPipeWire\ts16le 2ch 48000Hz\tRUNNING\n",$1,$2}' "$D/sinks" ;;
        modules) awk -F'|' '{printf "%s\t%s\t%s\n",$1,$2,$3}' "$D/modules" ;;
        cards) awk -F'|' '$2 ~ /^bluez_output/ {n=$2; sub(/^bluez_output\./,"bluez_card.",n); sub(/\.1$/,"",n); printf "%d\t%s\tmodule-bluez5-device.c\n",$1+500,n}' "$D/sinks" ;;
        sink-inputs) while IFS='|' read -r i s c k l; do printf '%s\t%s\t%s\tPipeWire\ts16le\n' "$i" "$(sidx "$s")" "$c"; done <"$D/inputs" ;;
      esac
    else
      case $2 in
        sinks) awk -F'|' '{printf "Sink #%s\n\tState: RUNNING\n\tName: %s\n\tDescription: x\n\tDriver: PipeWire\n\tOwner Module: %s\n\tMute: %s\n\tVolume: front-left: 1 / %3s%% / 0.00 dB,   front-right: 1 / %3s%% / 0.00 dB\n\n",$1,$2,$3,$5,$4,$4}' "$D/sinks" ;;
        sink-inputs)
          while IFS='|' read -r i s c k l; do
            echo "Sink Input #$i"
            if [[ $k == internal ]]; then
              printf '\tDriver: PipeWire\n\tOwner Module: n/a\n\tClient: 3\n\tSink: %s\n\tProperties:\n\t\tnode.name = "%s"\n\t\tcombine.mode = "sink"\n' "$(sidx "$s")" "$l"
            else
              printf '\tDriver: PipeWire\n\tOwner Module: n/a\n\tClient: %s\n\tSink: %s\n\tProperties:\n\t\tmedia.name = "%s"\n\t\ttarget.object = "bt_jam_a"\n' "$c" "$(sidx "$s")" "$l"
            fi
            echo
          done <"$D/inputs" ;;
        cards)
          awk -F'|' '$2 ~ /^bluez_output/ {print $1"|"$2}' "$D/sinks" | while IFS='|' read -r i n; do
            card=${n/bluez_output./bluez_card.}; card=${card%.1}
            off=$(awk -F'|' -v c="$card" '$1==c{v=$3} END{print v+0}' "$D/offsets")
            printf 'Card #%d\n\tName: %s\n\tDriver: module-bluez5-device.c\n\tProfiles:\n\t\ta2dp-sink: High Fidelity Playback (sinks: 1, sources: 0, priority: 40, available: yes)\n\tActive Profile: a2dp-sink\n\tPorts:\n\t\theadset-output: Headset (type: Headset, priority: 0, latency offset: %d usec, availability unknown)\n\t\t\tPart of profile(s): a2dp-sink\n\t\theadset-input: Headset (type: Headset, priority: 0, latency offset: 0 usec, not available)\n\n' $((i + 500)) "$card" "$off"
          done ;;
      esac
    fi ;;
  load-module)
    [[ $2 == module-combine-sink ]] || exit 1
    shift 2; name='' slaves=''
    for a in "$@"; do case $a in sink_name=*) name=${a#*=} ;; slaves=*) slaves=${a#*=} ;; esac; done
    exists "$name" && { echo "Failure: sink exists" >&2; exit 1; }
    IFS=, read -ra sl <<<"$slaves"
    for s in "${sl[@]}"; do exists "$s" || { echo "Failure: Module initialization failed" >&2; exit 1; }; done
    mod=$(next); si=$(next)
    echo "$mod|module-combine-sink|sink_name=$name slaves=$slaves" >>"$D/modules"
    echo "$si|$name|$mod|100|no" >>"$D/sinks"
    for s in "${sl[@]}"; do echo "$(next)|$s|3|internal|combine_output.$name.$s" >>"$D/inputs"; done
    echo "$mod" ;;
  unload-module)
    line=$(awk -F'|' -v m="$2" '$1==m' "$D/modules"); [[ -z $line ]] && exit 1
    name=$(sed 's/.*sink_name=\([^ ]*\).*/\1/' <<<"$line")
    awk -F'|' -v m="$2" '$1!=m' "$D/modules" >"$D/t" && mv "$D/t" "$D/modules"
    awk -F'|' -v n="$name" '$2!=n' "$D/sinks" >"$D/t" && mv "$D/t" "$D/sinks"
    awk -F'|' -v n="combine_output.$name." 'index($5,n)!=1' "$D/inputs" >"$D/t" && mv "$D/t" "$D/inputs"
    # app streams left on a removed sink are "lost" -> test failure marker
    awk -F'|' -v OFS='|' -v n="$name" '$2==n{$2="LOST"} 1' "$D/inputs" >"$D/t" && mv "$D/t" "$D/inputs" ;;
  set-default-sink) exists "$2" || exit 1; echo "$2" >"$D/default" ;;
  move-sink-input)
    exists "$3" || exit 1
    kind=$(awk -F'|' -v i="$2" '$1==i{print $4}' "$D/inputs")
    [[ $kind == internal ]] && echo "moved internal stream $2 to $3 (feedback loop!)" >>"$D/errors"
    awk -F'|' -v OFS='|' -v i="$2" -v s="$3" '$1==i{$2=s} 1' "$D/inputs" >"$D/t" && mv "$D/t" "$D/inputs" ;;
  set-sink-volume) exists "$2" || exit 1; upd_sink "$2" 4 "${3%\%}" ;;
  set-sink-mute)
    exists "$2" || exit 1
    cur=$(awk -F'|' -v n="$2" '$2==n{print $5}' "$D/sinks")
    case $3 in 1|yes|true) v=yes ;; 0|no|false) v=no ;; toggle) [[ $cur == yes ]] && v=no || v=yes ;; esac
    upd_sink "$2" 5 "$v" ;;
  set-card-profile) exit 0 ;;
  set-port-latency-offset)
    awk -F'|' -v c="$2" '$1!=c' "$D/offsets" >"$D/t"; echo "$2|$3|$4" >>"$D/t"; mv "$D/t" "$D/offsets" ;;
  *) echo "mock pactl: unsupported $*" >>"$D/errors"; exit 1 ;;
esac
MOCK

cat >"$WORK/bin/bluetoothctl" <<'MOCK'
#!/usr/bin/env bash
D=$MOCK_DIR
field() { awk -F'|' -v m="$1" -v c="$2" 'toupper($1)==toupper(m){print $c}' "$D/devices"; }
setf()  { awk -F'|' -v OFS='|' -v m="$1" -v c="$2" -v v="$3" 'toupper($1)==toupper(m){$c=v} 1' "$D/devices" >"$D/t" && mv "$D/t" "$D/devices"; }
sinkname() { local m=${1^^}; echo "bluez_output.${m//:/_}.1"; }
[[ $1 == --timeout ]] && shift 2
case "$1" in
  --help) echo "  --timeout secs   Timeout in seconds for non-interactive mode" ;;
  show) echo "Controller 00:1A:7D:DA:71:13 (public)"; echo "	Powered: $(cat "$D/powered")" ;;
  power) echo yes >"$D/powered" ;;
  scan) exit 0 ;;
  devices) awk -F'|' '{print "Device "$1" "$2}' "$D/devices" ;;
  info)
    [[ -z $(field "$2" 1) ]] && { echo "Device $2 not available"; exit 1; }
    echo "Device $2 (public)"; echo "	Name: $(field "$2" 2)"; echo "	Alias: $(field "$2" 2)"
    [[ $(field "$2" 3) == 1 ]] && echo "	Icon: audio-card" || echo "	Icon: input-mouse"
    echo "	Paired: $(field "$2" 4)"; echo "	Trusted: yes"; echo "	Connected: $(field "$2" 5)" ;;
  pair) [[ $(field "$2" 6) == 1 ]] || { echo "Failed to pair"; exit 1; }; setf "$2" 4 yes; echo "Pairing successful" ;;
  trust) echo "Trust succeeded" ;;
  connect)
    [[ $(field "$2" 6) == 1 ]] || { echo "Failed to connect"; exit 1; }
    setf "$2" 5 yes
    if [[ $(field "$2" 3) == 1 ]]; then
      n=$(cat "$D/next"); echo $((n + 1)) >"$D/next"
      echo "$n|$(sinkname "$2")|20|100|no" >>"$D/sinks"
    fi
    echo "Connection successful" ;;
  disconnect)
    setf "$2" 5 no
    s=$(sinkname "$2")
    awk -F'|' -v n="$s" '$2!=n' "$D/sinks" >"$D/t" && mv "$D/t" "$D/sinks"
    awk -F'|' -v n="$s" '!($2==n && $4=="internal")' "$D/inputs" >"$D/t" && mv "$D/t" "$D/inputs"
    echo "Successful disconnected" ;;
  remove) awk -F'|' -v m="$2" 'toupper($1)!=toupper(m)' "$D/devices" >"$D/t" && mv "$D/t" "$D/devices" ;;
  *) exit 0 ;;
esac
MOCK

cat >"$WORK/bin/paplay" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"$MOCK_DIR/played"
MOCK
cat >"$WORK/bin/mpv" <<'MOCK'
#!/usr/bin/env bash
sleep 30
MOCK
chmod +x "$WORK/bin/"*

# Helpers to inspect the fake world
default_sink() { cat "$MOCK_DIR/default"; }
stream_sink()  { awk -F'|' '$1==70{print $2}' "$MOCK_DIR/inputs"; }
no_errors()    { [[ ! -s $MOCK_DIR/errors ]]; }
no_lost()      { ! grep -q '|LOST|' "$MOCK_DIR/inputs"; }
jam_count()    { grep -c '^.*|bt_jam_' "$MOCK_DIR/sinks"; }
slaves_of()    { grep -o 'slaves=[^ ]*' "$MOCK_DIR/modules"; }

A=AA:AA:AA:00:00:01 B=AA:AA:AA:00:00:02 C=AA:AA:AA:00:00:03 D=AA:AA:AA:00:00:04

# ---------------------------------------------------------------------
echo "== Syntax"
for f in "$ROOT"/*.sh "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do
  check "bash -n $(basename "$f")" bash -n "$f"
done

# ---------------------------------------------------------------------
echo "== Library: discovery & connecting"
reset_world
JAM_HOME=$ROOT
for l in common bluetooth audio session menus; do source "$ROOT/lib/$l.sh"; done

check "adapter detected"             eval "bt_check >/dev/null"
check "lists 4 speakers, not mouse"  test "$(bt_list_speakers | wc -l)" -eq 4
check "'all' also lists the mouse"   test "$(bt_list_speakers all | wc -l)" -eq 5
check "connect JBL"                  eval "bt_connect $A >/dev/null"
check "connect Sony"                 eval "bt_connect $B >/dev/null"
check "JBL has a sound output"       test -n "$(audio_sink_for_mac $A)"
check "out-of-range speaker fails"   eval '! bt_connect $D >/dev/null 2>&1'
check "two BT outputs found"         test "$(audio_bt_macs | wc -l)" -eq 2

echo "== Library: jam"
check "start jam with 2 speakers"    jam_build $A $B
check "jam output exists"            jam_active
check "jam is the default output"    test "$(default_sink)" = bt_jam_a
check "playing app moved to jam"     test "$(stream_sink)" = bt_jam_a
check "previous output remembered"   grep -q analog-stereo "$PREV_SINK_FILE"
check "both speakers are members"    test "$(jam_members | wc -l)" -eq 2
check "internal streams untouched"   no_errors

jam_set_volume 70
check "volume set to 70%"            test "$(jam_volume)" = 70
jam_change_volume 10
check "volume up -> 80%"             test "$(jam_volume)" = 80
jam_toggle_mute
check "mute on"                      jam_muted
check "user stream filter skips combine streams" test "$(audio_user_streams)" = 70

echo "== Library: add / remove / swap while playing"
bt_connect $C >/dev/null
check "add Anker mid-jam"            jam_add $C
check "jam rebuilt as bt_jam_b"      test "$(jam_sink)" = bt_jam_b
check "only one jam output exists"   test "$(jam_count)" -eq 1
check "3 speakers in jam"            test "$(jam_members | wc -l)" -eq 3
check "music followed the rebuild"   test "$(stream_sink)" = bt_jam_b
check "volume carried over (80%)"    test "$(jam_volume)" = 80
check "mute carried over"            jam_muted
check "no stream was lost"           no_lost

check "remove Sony"                  jam_remove $B
check "2 speakers left"              test "$(jam_members | wc -l)" -eq 2
check "Sony not in combine"          eval '! slaves_of | grep -q 00_00_02'
check "music still on jam"           test "$(stream_sink)" = "$(jam_sink)"

bt_connect $B >/dev/null
check "swap JBL -> Sony"             jam_swap $A $B
check "JBL out, Sony in"             eval 'jam_members | grep -qx $B && ! jam_members | grep -qx $A'
check "music still on jam"           test "$(stream_sink)" = "$(jam_sink)"

echo "== Library: speaker drops out"
bluetoothctl disconnect $C >/dev/null
check "dropped speaker detected"     test "$(jam_dropped)" = $C
check "reconnect + rebuild"          eval 'bt_connect $C >/dev/null && jam_build $(jam_members)'
check "nothing dropped now"          test -z "$(jam_dropped)"

echo "== Library: sync & beep"
check "set 120 ms delay on Sony"     audio_set_offset_ms $B 120
check "delay reads back 120"         test "$(audio_get_offset_ms $B)" = 120
audio_make_tone "$WORK/t.wav"
check "beep is a valid WAV"          eval 'head -c 4 "$WORK/t.wav" | grep -q RIFF && test "$(stat -c %s "$WORK/t.wav")" -gt 3000'
if command -v file >/dev/null; then
  check "file(1) agrees it's WAV"    eval 'file "$WORK/t.wav" | grep -q "WAVE audio"'
fi
check "beep plays on jam"            eval 'audio_beep "$(jam_sink)" && grep -q bt_jam "$MOCK_DIR/played"'

echo "== Library: music player"
mkdir -p "$WORK/music"; : >"$WORK/music/song.mp3"
player_start "$WORK/music" >/dev/null
sleep 0.5
check "player running"               player_running
pid=$(cat "$PLAYER_PID_FILE")
player_stop
sleep 0.3
check "player and its children stopped" eval '! ps -o stat= -g "$pid" 2>/dev/null | grep -qv "^Z"'

echo "== Library: stop"
check "stop jam"                     jam_stop
check "no jam output left"           test "$(jam_count)" -eq 0
check "default output restored"      test "$(default_sink)" = alsa_output.pci-0000_00_1f.3.analog-stereo
check "music back on laptop"         test "$(stream_sink)" = alsa_output.pci-0000_00_1f.3.analog-stereo
check "no lost streams, no loops"    eval 'no_lost && no_errors'

# ---------------------------------------------------------------------
echo "== Menu: Quick Jam end-to-end (as a user would type it)"
reset_world
# 1=Quick Jam, Enter=ready, "1 2"=pick JBL+Sony, n=no beep, Enter, 0=quit, n=keep jam
out=$(printf '1\n\n1 2\nn\n\n0\nn\n' | "$ROOT/jam.sh" 2>&1)
check "menu reports jam live"        grep -q 'JAM IS LIVE on 2' <<<"$out"
check "jam left running after quit"  test "$(jam_count)" -eq 1
check "music app moved to jam"       test "$(stream_sink)" = bt_jam_a

echo "== Menu: volume, add, mute, stop"
# 4=controls 1=vol up 4=mute 0=back | 5=manage 1=add Enter "a"=all remaining ... 0=back | 0 quit y=stop
out=$(printf '4\n2\n4\n0\n5\n1\n\na\n\n0\n0\ny\n' | "$ROOT/jam.sh" 2>&1)
check "volume down worked (90%)"     grep -q 'volume 90%' <<<"$out"
check "mute shown"                   grep -q MUTED <<<"$out"
check "added speaker message"        grep -q 'Added to the jam' <<<"$out"
check "out-of-range speaker reported" grep -q "Couldn't connect to Old Party Box" <<<"$out"
check "jam stopped on quit"          test "$(jam_count)" -eq 0
check "music back on laptop"         test "$(stream_sink)" = alsa_output.pci-0000_00_1f.3.analog-stereo
check "no lost streams, no loops"    eval 'no_lost && no_errors'

echo "== CLI flags"
check "--help works"                 eval '"$ROOT/jam.sh" --help | grep -q Usage\\\|jam.sh'
check "--stop with no jam is fine"   eval '"$ROOT/jam.sh" --stop | grep -q "No jam"'
check "--status works"               eval '"$ROOT/jam.sh" --status | grep -q "Sound system"'

echo
echo "Passed: $PASS   Failed: $FAIL"
((FAIL == 0))
