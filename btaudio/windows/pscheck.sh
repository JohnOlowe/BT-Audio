#!/usr/bin/env bash
# pscheck.sh [path/to/bt-audio-send.ps1] [only-this-test-name]
#
# Checks the Windows BT-audio sender without needing Windows. Three layers,
# each catching what the layer below cannot:
#
#   1. The C# inside Add-Type -> compiled by Roslyn against the real .NET
#      Framework 4.8 reference assemblies at /langversion:5, i.e. exactly the
#      compiler Windows PowerShell 5.1 uses. (delegates to cscheck.sh)
#   2. The PowerShell itself -> parsed by a real PowerShell runtime, so syntax
#      errors and bad parameter blocks surface before a user sees them.
#   3. The whole program, running -> it streams audio over a virtual COM port (a
#      socat pty pair stands in for the Bluetooth SPP port) into the very same
#      Proto/Adpcm classes that ship inside the APK, which compare the decoded
#      audio against what was fed in.
#
# Layer 3 runs both of the script's paths:
#   * -Mode File     reads a WAV directly.
#   * -Mode Loopback runs against a stubbed WASAPI class (see mkstub.py) that
#     feeds a WAV in 10 ms packets like a real capture client. This is the path
#     that runs on the user's machine, and the one with the fractional
#     resampler cursor and carry buffers that are easiest to get subtly wrong.
#
# Setup is self-healing; all three caches are re-fetched when absent:
#   .NET SDK 8.0.425   https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.425/dotnet-sdk-8.0.425-linux-x64.tar.gz
#   net48 ref asms     https://api.nuget.org/v3-flatcontainer/microsoft.netframework.referenceassemblies.net48/1.0.3/microsoft.netframework.referenceassemblies.net48.1.0.3.nupkg
#   PowerShell 7.4.6   dotnet tool install --global PowerShell --version 7.4.6
#                      (the shim needs dotnet on PATH; unpinned installs of that
#                       global tool are currently broken upstream)
#   also needs: socat, python3, a JDK
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TARGET="${1:-$HERE/bt-audio-send.ps1}"
FILTER="${2:-}"          # optional: run only the test with this name
CSCHECK="$HERE/cscheck.sh"
CS="${BTAUDIO_WINDOWS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/btaudio/windows}"
SRC="$ROOT/btaudio/src/net/ghosthand/btaudio"
FIX="$HERE/build/pscheck/fixtures"
CLASSES="$HERE/build/pscheck/classes"
STUB="$FIX/loopback-stub.ps1"
TOOLCHAIN="$ROOT/toolchain/vendor"
case "$CS" in /*) ;; *) CS="$PWD/$CS" ;; esac
JAVA=""
ECJ=""
export BTAUDIO_WINDOWS_CACHE="$CS"
export DOTNET_ROOT="$CS"
export DOTNET_CLI_HOME="$CS/dotnet-cli"
export NUGET_PACKAGES="$CS/nuget"
export PATH="$CS/pwsh:$CS:$HOME/.dotnet/tools:$PATH"

fails=0
step() { printf '\n=== %s ===\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
want() { [ -n "$FILTER" ] && [ "$1" != "$FILTER" ] && return 1; return 0; }

[ -f "$TARGET" ] || { echo "no such file: $TARGET"; exit 2; }

# ---------------------------------------------------------------- dependencies
step "dependencies"
for t in socat python3; do
    command -v "$t" >/dev/null || { echo "$t is required"; exit 2; }
done
[ -f "$CSCHECK" ] || { echo "cscheck.sh missing: $CSCHECK"; exit 2; }
# Reuse installed tools; prepare-tools adds only JRE + ECJ when a Java
# compiler/runtime is missing, then provisions Windows test dependencies.
bash "$HERE/prepare-tools.sh" ensure || {
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
command -v pwsh >/dev/null 2>&1 \
    && echo "pwsh $(pwsh -NoProfile -c '$PSVersionTable.PSVersion.ToString()' 2>/dev/null)" \
    || bad "could not obtain a PowerShell runtime"

# ------------------------------------------------------------- layer 1: the C#
step "layer 1: C# under Add-Type, compiled as PS 5.1 would (net48 refs, C# 5)"
out="$(bash "$CSCHECK" "$TARGET" 2>&1 | tail -4)"
echo "$out"
grep -q "CS COMPILE OK" <<<"$out" || bad "C# does not compile"

# ----------------------------------------------------- layer 2: PowerShell AST
step "layer 2: PowerShell parse check"
pwsh -NoProfile -c "
\$tok = \$null; \$err = \$null
\$ast = [System.Management.Automation.Language.Parser]::ParseFile('$TARGET', [ref]\$tok, [ref]\$err)
if (\$err -and \$err.Count) { \$err | ForEach-Object { 'PARSE ' + \$_.Extent.StartLineNumber + ': ' + \$_.Message }; exit 1 }
'parsed clean: ' + \$ast.FindAll({ \$true }, \$true).Count + ' AST nodes, ' + \$tok.Count + ' tokens'
" || bad "PowerShell parse errors"

# --------------------------------------------------- layer 3: run it for real
step "layer 3: fixtures, the WASAPI stub, and the phone-side decoder"
mkdir -p "$FIX" "$CLASSES"
python3 - "$FIX" <<'PY'
import math, struct, sys, wave
out = sys.argv[1]
def tone(path, chans, secs=1.0, rate=44100):
    # distinct frequency per channel, so a swapped pair is unmistakable
    w = wave.open(path, 'w'); w.setnchannels(chans); w.setsampwidth(2); w.setframerate(rate)
    for i in range(int(secs * rate)):
        fr = [int(12000 * math.sin(2 * math.pi * (440 if c == 0 else 660) * i / rate)) for c in range(chans)]
        w.writeframes(struct.pack('<%dh' % chans, *fr))
    w.close()
tone(out + '/stereo44k.wav', 2)
tone(out + '/mono44k.wav', 1)
tone(out + '/mono22k.wav', 1, secs=0.5, rate=22050)
print('fixtures written')
PY

python3 "$HERE/mkstub.py" "$TARGET" "$STUB" || bad "could not build the WASAPI stub"
if [ -f "$STUB" ]; then
    out="$(bash "$CSCHECK" "$STUB" 2>&1 | tail -2)"
    echo "$out" | tail -1
    grep -q "CS COMPILE OK" <<<"$out" || bad "the stubbed script's C# does not compile"
fi

if command -v javac >/dev/null 2>&1; then
    javac -nowarn -d "$CLASSES" "$HERE/WireSink.java" "$SRC/Proto.java" "$SRC/Adpcm.java" \
        || bad "could not compile the phone-side decoder"
else
    "$JAVA" -jar "$ECJ" -source 8 -target 8 -proc:none -nowarn -d "$CLASSES" \
        "$HERE/WireSink.java" "$SRC/Proto.java" "$SRC/Adpcm.java" \
        || bad "ECJ could not compile the phone-side decoder"
fi

# ------------------------------------------------------------------ test bodies

# negative tests: the failures a user is most likely to hit in the field. Both
# must give a readable message and a non-zero exit, never a raw .NET dump.
#   neg NAME EXPECTED_TEXT ARGS...
neg() {
    local name="$1" want="$2"; shift 2
    want "$name" || return 0
    step "negative test: $name"
    timeout 60 pwsh -NoProfile -ExecutionPolicy Bypass -File "$TARGET" "$@" >"$FIX/$name.ps" 2>&1
    local rc=$?
    sed 's/^/  | /' "$FIX/$name.ps" | head -6
    [ $rc -ne 0 ] || bad "$name: expected a non-zero exit, got 0"
    grep -qi "$want" "$FIX/$name.ps" || bad "$name: expected a message matching '$want'"
    if grep -qi 'Exception calling\|FullyQualifiedErrorId\|At line:' "$FIX/$name.ps"; then
        bad "$name: leaked a raw PowerShell/.NET exception at the user"
    fi
}

#   wire NAME WAV MODE PARTIAL CODEC CHANNELS RATE CHUNKMS
wire() {
    local name="$1" wav="$2" mode="$3" partial="$4" codec="$5" chans="$6" rate="$7" chunkms="$8"
    want "$name" || return 0
    local cname=Adpcm; [ "$codec" = "0" ] && cname=Pcm
    local a=/tmp/pscheck-a-$$ b=/tmp/pscheck-b-$$

    step "wire test: $name ($cname, $chans ch, $rate Hz, $chunkms ms, $mode)"
    socat -d -d "pty,raw,echo=0,link=$a" "pty,raw,echo=0,link=$b" >/dev/null 2>&1 &
    local sp=$!
    sleep 0.6
    timeout 120 "$JAVA" -cp "$CLASSES" WireSink "$b" "$codec" "$chans" "$rate" "$chunkms" \
        "$wav" "$mode" "$partial" >"$FIX/$name.sink" 2>&1 &
    local jp=$!
    sleep 0.4
    timeout 120 pwsh -NoProfile -ExecutionPolicy Bypass -File "$TARGET" \
        -Port "$a" -Mode File -File "$wav" -Codec "$cname" -Channels "$chans" \
        -Rate "$rate" -ChunkMs "$chunkms" >"$FIX/$name.ps" 2>&1
    local rc=$?
    wait $jp; local jrc=$?
    kill $sp 2>/dev/null; rm -f "$a" "$b"

    sed 's/^/  | /' "$FIX/$name.ps" | head -8
    grep -v '^  ok   ' "$FIX/$name.sink" | sed 's/^/  | /'
    grep -c '^  ok   ' "$FIX/$name.sink" | sed 's/^/  | checks passed: /'
    [ $rc -eq 0 ] || bad "$name: sender exited $rc"
    [ $jrc -eq 0 ] || bad "$name: phone-side decoder reported failures"
}

# Same, but through the stubbed WASAPI class, so the streaming branch runs.
# The sender is killed by `timeout` because a loopback stream has no end.
#   loopw NAME WAV MODE CODEC CHANNELS RATE CHUNKMS SECONDS
loopw() {
    local name="$1" wav="$2" mode="$3" codec="$4" chans="$5" rate="$6" chunkms="$7" secs="$8"
    want "$name" || return 0
    local cname=Adpcm; [ "$codec" = "0" ] && cname=Pcm
    local a=/tmp/pscheck-a-$$ b=/tmp/pscheck-b-$$

    step "loopback test: $name ($cname, $chans ch, $rate Hz, $chunkms ms, $mode)"
    socat -d -d "pty,raw,echo=0,link=$a" "pty,raw,echo=0,link=$b" >/dev/null 2>&1 &
    local sp=$!
    sleep 0.6
    timeout 180 "$JAVA" -cp "$CLASSES" WireSink "$b" "$codec" "$chans" "$rate" "$chunkms" \
        "$wav" "$mode" 1 >"$FIX/$name.sink" 2>&1 &
    local jp=$!
    sleep 0.4
    BTAUDIO_FAKE_WAV="$wav" timeout "$secs" pwsh -NoProfile -ExecutionPolicy Bypass \
        -File "$STUB" -Port "$a" -Mode Loopback -Codec "$cname" -Channels "$chans" \
        -Rate "$rate" -ChunkMs "$chunkms" >"$FIX/$name.ps" 2>&1
    local rc=$?
    kill $sp 2>/dev/null            # EOF frees the sink to compare what arrived
    wait $jp; local jrc=$?
    rm -f "$a" "$b"

    sed 's/^/  | /' "$FIX/$name.ps" | head -8
    grep -v '^  ok   ' "$FIX/$name.sink" | sed 's/^/  | /'
    grep -c '^  ok   ' "$FIX/$name.sink" | sed 's/^/  | checks passed: /'
    [ $rc -eq 124 ] || bad "$name: sender exited $rc, expected 124 (timeout ends a loopback run)"
    [ $jrc -eq 0 ] || bad "$name: phone-side decoder reported failures"
}

# ---- negative ---------------------------------------------------------------
neg "missing-wav" "No such WAV file" -Port /tmp/does-not-matter -Mode File -File "$FIX/nope.wav"
neg "bad-port"    "Could not open"   -Port /tmp/definitely-not-a-port-xyz -Mode File -File "$FIX/mono44k.wav"

# ---- -Mode File -------------------------------------------------------------
wire "adpcm-stereo"  "$FIX/stereo44k.wav" lossy   0 1 2 44100 20
wire "pcm-stereo"    "$FIX/stereo44k.wav" exact   0 0 2 44100 20
wire "adpcm-mono"    "$FIX/mono44k.wav"   lossy   0 1 1 44100 20
wire "pcm-mono"      "$FIX/mono44k.wav"   exact   0 0 1 44100 20
wire "pcm-downmix"   "$FIX/stereo44k.wav" downmix 0 0 1 44100 20
wire "pcm-upsample"  "$FIX/mono22k.wav"   exact   0 0 1 44100 20   # framing only
wire "adpcm-oddms"   "$FIX/stereo44k.wav" lossy   0 1 2 44100 15   # non-round chunk size

# ---- -Mode Loopback (streaming branch, WASAPI stubbed) ----------------------
loopw "loop-pcm-stereo"   "$FIX/stereo44k.wav" exact   0 2 44100 20 6
loopw "loop-adpcm-stereo" "$FIX/stereo44k.wav" lossy   1 2 44100 20 6
loopw "loop-pcm-downmix"  "$FIX/stereo44k.wav" downmix 0 1 44100 20 6
loopw "loop-pcm-22k"      "$FIX/stereo44k.wav" exact   0 2 22050 20 6   # downsampling

step "summary"
if [ "$fails" -eq 0 ]; then
    echo "PSCHECK OK - C# compiles, PowerShell parses, and both the File and"
    echo "           Loopback paths decode correctly on the phone's own decoder"
    exit 0
else
    echo "PSCHECK FAILURES: $fails"
    exit 1
fi
