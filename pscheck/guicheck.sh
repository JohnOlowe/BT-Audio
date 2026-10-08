#!/usr/bin/env bash
# guicheck.sh [gui-dir]
#
# Tests the WinForms sender's audio engine. The window itself cannot run here
# (no display, and the .exe is Windows-only), but everything that decides
# whether audio arrives correctly - resampling, ADPCM, framing, the prebuffer
# prime, the silence-filled timeline, and the automatic quality ladder - is in
# the portable Core/Engine and is exercised here for real:
#
#   * the SAME sources are compiled twice, once for Windows (net48, so the
#     shipped .exe and this test are built from identical text) and once for
#     Linux (net8.0), where it can actually run;
#   * the Linux build streams into a socat pty pair standing in for the phone's
#     Bluetooth COM port;
#   * the bytes are read by the phone's own Proto/Adpcm classes, lifted straight
#     out of the APK's source, and compared against the WAV that was fed in.
#
# Layers:
#   1. compile the real Windows exe (catches any Windows-only API mistake)
#   2. wire test: PCM must decode BIT-EXACT through the streaming path
#   3. wire test: ADPCM within budget, channels not swapped
#   4. ladder test: a stalled link must trip auto quality and reconnect lower
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUI="${1:-$ROOT/btaudio/windows/gui}"
FILTER="${2:-}"          # optional: run only the test with this name
CSCHECK="$ROOT/btaudio/windows/cscheck.sh"
CS="${BTAUDIO_WINDOWS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/btaudio/windows}"
SRC="$ROOT/btaudio/src/net/ghosthand/btaudio"
FIX="$HERE/build/fixtures"
CLASSES="$HERE/build/classes"
GUI_OUT="$HERE/build/gui-out"
TOOLCHAIN="$ROOT/toolchain/vendor"
case "$CS" in /*) ;; *) CS="$PWD/$CS" ;; esac
JAVA=""
ECJ=""
export BTAUDIO_WINDOWS_CACHE="$CS"
export DOTNET_ROOT="$CS"
export DOTNET_CLI_HOME="$CS/dotnet-cli"
export NUGET_PACKAGES="$CS/nuget"
export PATH="$CS/pwsh:$CS:$PATH"
CSC="$CS/sdk/8.0.425/Roslyn/bincore/csc.dll"

fails=0
step() { printf '\n=== %s ===\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

[ -f "$CSCHECK" ] || { echo "cscheck.sh missing: $CSCHECK"; exit 2; }
# Provision only JRE + ECJ when javac is absent; the Android SDK is not needed.
bash "$ROOT/btaudio/windows/prepare-tools.sh" ensure || {
    echo "could not provision Windows test tools" >&2
    exit 2
}
if [ -x "$CS/java/jre/bin/java" ] && [ -s "$CS/java/ecj.jar" ]; then
    JAVA="$CS/java/jre/bin/java"; ECJ="$CS/java/ecj.jar"
elif [ -x "$TOOLCHAIN/jre/bin/java" ] && [ -s "$TOOLCHAIN/ecj.jar" ]; then
    JAVA="$TOOLCHAIN/jre/bin/java"; ECJ="$TOOLCHAIN/ecj.jar"
else
    JAVA="$(command -v java || true)"
fi
[ -n "$JAVA" ] || { echo "a Java runtime is required" >&2; exit 2; }
if ! command -v javac >/dev/null 2>&1; then
    [ -x "$JAVA" ] && [ -s "$ECJ" ] || {
        echo "need javac or JRE + Eclipse ECJ (prepare-tools.sh ensure)" >&2
        exit 2
    }
fi
mkdir -p "$FIX" "$CLASSES" "$GUI_OUT"

# ------------------------------------------------------- layer 1: build for Windows
step "layer 1: compile the Windows .exe (net48, C# 7.3, WinForms)"
REFS="$CS/refs/build/.NETFramework/v4.8"
out=$("$CS/dotnet" exec "$CSC" /nologo /noconfig /nostdlib /target:winexe /langversion:7.3 \
      /out:"$GUI_OUT/BTAudioSender.exe" \
      /r:"$REFS/mscorlib.dll" /r:"$REFS/System.dll" /r:"$REFS/System.Core.dll" \
      /r:"$REFS/System.Drawing.dll" /r:"$REFS/System.Windows.Forms.dll" \
      "$GUI/Core.cs" "$GUI/Engine.cs" "$GUI/Windows.cs" "$GUI/MainForm.cs" "$GUI/Program.cs" 2>&1)
if [ -n "$out" ]; then echo "$out" | head -20; bad "the Windows exe does not compile"; fi
[ -f "$GUI_OUT/BTAudioSender.exe" ] && echo "BTAudioSender.exe built ($(stat -c%s "$GUI_OUT/BTAudioSender.exe") bytes)"

# ------------------------------------------------------------ layer 2: Linux build
step "layer 2: compile the same engine for Linux so it can be run"
REFDIR=$(ls -d "$CS"/packs/Microsoft.NETCore.App.Ref/*/ref/net8.0 | head -1)
REFLIST=""
for f in "$REFDIR"/*.dll; do REFLIST="$REFLIST /r:$f"; done
out=$("$CS/dotnet" exec "$CSC" /nologo /noconfig /nostdlib /target:exe /langversion:7.3 \
      /out:"$GUI_OUT/harness.dll" $REFLIST "$GUI/Core.cs" "$GUI/Engine.cs" "$GUI/TestMain.cs" 2>&1)
if [ -n "$out" ]; then echo "$out" | head -20; bad "the engine does not compile for Linux"; fi
cat > "$GUI_OUT/harness.runtimeconfig.json" <<'EOF'
{ "runtimeOptions": { "tfm": "net8.0",
  "framework": { "name": "Microsoft.NETCore.App", "version": "8.0.0" } } }
EOF
echo "harness.dll built"

# ------------------------------------------------------------------- fixtures
step "fixtures and the phone-side decoder"
python3 - "$FIX" <<'PY'
import math, struct, sys, wave
out = sys.argv[1]
def tone(path, chans, secs=1.0, rate=44100):
    w = wave.open(path, 'w'); w.setnchannels(chans); w.setsampwidth(2); w.setframerate(rate)
    for i in range(int(secs * rate)):
        fr = [int(12000 * math.sin(2 * math.pi * (440 if c == 0 else 660) * i / rate)) for c in range(chans)]
        w.writeframes(struct.pack('<%dh' % chans, *fr))
    w.close()
tone(out + '/stereo44k.wav', 2)
tone(out + '/mono44k.wav', 1)
print('fixtures written')
PY
if command -v javac >/dev/null 2>&1; then
    javac -nowarn -d "$CLASSES" "$HERE/TimedIn.java" "$HERE/WireSink.java" "$HERE/LadderCheck.java" \
          "$SRC/Proto.java" "$SRC/Adpcm.java" || bad "could not compile the phone-side decoder"
else
    "$JAVA" -jar "$ECJ" -source 8 -target 8 -proc:none -nowarn -d "$CLASSES" \
        "$HERE/TimedIn.java" "$HERE/WireSink.java" "$HERE/LadderCheck.java" \
        "$SRC/Proto.java" "$SRC/Adpcm.java" || bad "ECJ could not compile the phone-side decoder"
fi

# --------------------------------------------------------------- engine harness
# run NAME WAV MODE EXACT CODEC CHANNELS RATE CHUNKMS PREBUFFER SECONDS
run() {
    local name="$1" wav="$2" mode="$3" exact="$4" codec="$5" chans="$6" rate="$7" chunk="$8" pre="$9" secs="${10}"
    if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then return 0; fi
    local a=/tmp/guicheck-a-$$ b=/tmp/guicheck-b-$$
    step "wire test: $name (${mode}, $chans ch, $rate Hz, $chunk ms chunks, ${pre} ms prebuffer)"
    socat -d -d "pty,raw,echo=0,link=$a" "pty,raw,echo=0,link=$b" >/dev/null 2>&1 &
    local sp=$!
    sleep 0.6
    local rc=0
    if [ "$mode" = "ladder" ]; then
        timeout 90 "$JAVA" -cp "$CLASSES" LadderCheck "$b" "$secs" >"$FIX/$name.sink" 2>&1 &
    else
        timeout 90 "$JAVA" -cp "$CLASSES" WireSink "$b" "$codec" "$chans" "$rate" "$chunk" \
            "$wav" "$mode" 0 >"$FIX/$name.sink" 2>&1 &
    fi
    local jp=$!
    sleep 1.5
    timeout 90 "$CS/dotnet" exec "$GUI_OUT/harness.dll" "$a" "$wav" "$codec" "$chans" \
        "$rate" "$chunk" "$pre" "$secs" "${11:-0}" >"$FIX/$name.ps" 2>&1
    rc=$?
    wait $jp; local jrc=$?
    kill $sp 2>/dev/null; rm -f "$a" "$b"

    sed 's/^/  | /' "$FIX/$name.ps" | head -8
    grep -v '^  ok   ' "$FIX/$name.sink" | sed 's/^/  | /' | head -24
    grep -c '^  ok   ' "$FIX/$name.sink" 2>/dev/null | sed 's/^/  | checks passed: /'
    [ $rc -eq 0 ] || bad "$name: sender exited $rc"
    [ $jrc -eq 0 ] || bad "$name: phone-side decoder reported failures"
}

run "live-pcm-stereo"  "$FIX/stereo44k.wav" exact   1 0 2 44100 20 260 6
run "live-adpcm-stereo" "$FIX/stereo44k.wav" lossy  0 1 2 44100 20 260 6
run "live-adpcm-mono"  "$FIX/mono44k.wav"   lossy   0 1 1 44100 20 300 6
run "live-pcm-mono"    "$FIX/stereo44k.wav" downmix 1 0 1 44100 20 300 6
# automatic quality: every write made slow, so the sender must notice and walk down
run "ladder"           "$FIX/stereo44k.wav" ladder  0 1 2 44100 20 260 60 30

step "summary"
if [ "$fails" -eq 0 ]; then
    echo "GUICHECK OK - the shipped .exe compiles, and the engine it contains"
    echo "              decodes correctly on the phone's own decoder"
    exit 0
else
    echo "GUICHECK FAILURES: $fails"
    exit 1
fi
