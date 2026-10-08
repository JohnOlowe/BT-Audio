#!/usr/bin/env bash
# cscheck.sh -- compile the C# embedded in bt-audio-send.ps1 the way the TARGET
# machine will, without needing a Windows box.
#
#   bash cscheck.sh [path/to/bt-audio-send.ps1]
#
# PowerShell 5.1 on Windows compiles Add-Type -TypeDefinition with the .NET
# Framework compiler at C# 5 against the .NET Framework 4.x reference
# assemblies. That exact combination is reproduced here with:
#   - Roslyn csc.dll from a Linux .NET SDK        (the compiler)
#   - Microsoft.NETFramework.ReferenceAssemblies.net48 from NuGet  (the types)
#   - /langversion:5 and /nostdlib                (the language level + no modern corelib leaking in)
# It catches the whole class of bug that otherwise only surfaces on the user's
# machine one round trip at a time: constant overflow, ref/out on readonly
# fields, missing types, wrong arity, C#6+ syntax.
#
# Tool bootstrap is in prepare-tools.sh. An installed SDK 8.0.425 is reused;
# otherwise the pinned SDK and .NET Framework 4.8 reference pack are cached
# outside the checkout. `prepare-tools.sh clean` removes that cache and fixtures.
# Verified: reproduces CS0031 (const overflow), CS0199 (ref/out on static
# readonly) and CS8026 (C#6+ syntax) identically to Windows PowerShell 5.1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1="${1:-$HERE/bt-audio-send.ps1}"
CACHE="${BTAUDIO_WINDOWS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/btaudio/windows}"
SDK_VERSION="8.0.425"
SDK_URL="https://builds.dotnet.microsoft.com/dotnet/Sdk/$SDK_VERSION/dotnet-sdk-$SDK_VERSION-linux-x64.tar.gz"
SDK_SHA512="934b8060a7190e5909ad1fd0785db542f487b3bbf6cdd14826b02095fdd0d0394298b1634085eff302928fccc33f7c1a7253e9b87df555fc36fce819bcd2e798"
REFS_URL="https://api.nuget.org/v3-flatcontainer/microsoft.netframework.referenceassemblies.net48/1.0.3/microsoft.netframework.referenceassemblies.net48.1.0.3.nupkg"
mkdir -p "$CACHE"

# Prefer a machine/CI-provisioned pinned SDK. Mirror its directory layout into
# our external cache so every harness has one stable path and `clean` never
# removes a system installation.
SYSTEM_DOTNET="${BTAUDIO_DOTNET:-$(command -v dotnet || true)}"
if [ ! -x "$CACHE/dotnet" ] && [ -n "$SYSTEM_DOTNET" ] && [ -x "$SYSTEM_DOTNET" ]; then
    SDK_BASE="$("$SYSTEM_DOTNET" --list-sdks 2>/dev/null \
        | sed -n "s/^$SDK_VERSION \[\(.*\)\]$/\1/p" | head -1)"
    if [ -n "$SDK_BASE" ] && [ -s "$SDK_BASE/$SDK_VERSION/Roslyn/bincore/csc.dll" ]; then
        SYSTEM_DOTNET_REAL="$(readlink -f "$SYSTEM_DOTNET")"
        SYSTEM_ROOT="$(dirname "$SYSTEM_DOTNET_REAL")"
        ln -s "$SYSTEM_DOTNET_REAL" "$CACHE/dotnet"
        for entry in host sdk shared packs sdk-manifests metadata; do
            if [ -e "$SYSTEM_ROOT/$entry" ] && [ ! -e "$CACHE/$entry" ] && [ ! -L "$CACHE/$entry" ]; then
                ln -s "$SYSTEM_ROOT/$entry" "$CACHE/$entry"
            fi
        done
        echo "==> reusing .NET SDK $SDK_VERSION from $SYSTEM_ROOT"
    fi
fi

# The pinned compiler and reference assemblies are cached outside the checkout;
# they are build tools, not source files. Set BTAUDIO_WINDOWS_CACHE to relocate.
if [ ! -x "$CACHE/dotnet" ] || [ ! -d "$CACHE/host/fxr" ]; then
    echo "==> fetching .NET SDK $SDK_VERSION into $CACHE"
    curl -fsSL -m 900 -o "$CACHE/sdk.tar.gz.part" "$SDK_URL"
    echo "$SDK_SHA512  $CACHE/sdk.tar.gz.part" | sha512sum --check --status || {
        rm -f "$CACHE/sdk.tar.gz.part"
        echo "error: .NET SDK checksum mismatch" >&2
        exit 1
    }
    mv "$CACHE/sdk.tar.gz.part" "$CACHE/sdk.tar.gz"
    tar xzf "$CACHE/sdk.tar.gz" -C "$CACHE"
    rm -f "$CACHE/sdk.tar.gz"
    chmod +x "$CACHE/dotnet"
fi
if [ ! -f "$CACHE/refs/build/.NETFramework/v4.8/mscorlib.dll" ]; then
    echo "==> fetching .NET Framework 4.8 reference assemblies into $CACHE"
    curl -fsSL -m 300 -o "$CACHE/refs.nupkg" "$REFS_URL"
    unzip -q -o "$CACHE/refs.nupkg" -d "$CACHE/refs"
fi

export DOTNET_ROOT="$CACHE"
export DOTNET_CLI_HOME="$CACHE/dotnet-cli"
export NUGET_PACKAGES="$CACHE/nuget"
export PATH="$CACHE:$PATH"
[ "${1:-}" = "bootstrap" ] && { echo "bootstrap complete"; exit 0; }
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
CSC="$CACHE/sdk/$SDK_VERSION/Roslyn/bincore/csc.dll"
REFS="$CACHE/refs/build/.NETFramework/v4.8"
OUT="$CACHE/out"
mkdir -p "$OUT"

python3 - "$PS1" "$OUT/wasapi.cs" <<'PY'
import sys
s = open(sys.argv[1], encoding='utf-8').read()
cs = s.split("@'", 1)[1].split("'@", 1)[0]
open(sys.argv[2], 'w', encoding='utf-8').write(cs)
print("extracted %d chars of C# from %s" % (len(cs), sys.argv[1]))
PY

"$CACHE/dotnet" exec "$CSC" /nologo /noconfig /nostdlib /target:library \
    /langversion:5 /out:"$OUT/wasapi.dll" \
    /r:"$REFS/mscorlib.dll" /r:"$REFS/System.dll" /r:"$REFS/System.Core.dll" \
    "$OUT/wasapi.cs"
echo "CS COMPILE OK (net48 refs, C# 5)"
