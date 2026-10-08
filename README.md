# BT Audio

BT Audio sends PC audio to an Android phone over Bluetooth. The phone runs the
RFCOMM/SPP receiver; the Windows sender captures or reads audio, encodes it, and
writes the stream to the phone's outgoing Bluetooth COM port.

## Build

This repository uses the small Android toolchain in `toolchain/` rather than
Gradle or an installed Android SDK. It downloads its pinned compiler/runtime
artifacts from PyPI, npm, and GitHub into the ignored `toolchain/vendor/`
directory.

```bash
# Main BT Audio receiver: unit tests + signed, verified release APK
bash build.sh

# Produce both the shrunk release and an unshrunk/debuggable APK
bash build.sh --both

# Compile, test, package, and verify all Android projects in this repository
bash build-all.sh

# Also run the Windows sender's C#/PowerShell and wire-protocol checks
bash build-all.sh --windows
```

The main APK is written to `btaudio/build/btaudio.apk`; `--both` also writes
`btaudio/build/btaudio-debug.apk`. Install the release build with:

```bash
adb install -r btaudio/build/btaudio.apk
```

The app's `minSdkVersion` (API 24) and version are read from
`btaudio/AndroidManifest.xml`. `build.sh --min-api N` and the version flags are
available for intentional overrides. Every release APK is checked for manifest
components, missing app/dependency classes, dex compatibility, alignment,
signing, and framework API references against the declared minimum platform.

### Repository projects

| Path | Purpose | Build output |
|---|---|---|
| `btaudio/` | The BT Audio Android receiver (Java, resources, tests) | `btaudio/build/btaudio.apk` |
| `btaudio/windows/` | Windows PowerShell sender and WinForms sender sources | `output/BTAudioSender.exe` is the checked-in Windows binary |
| `sample/` | Small framework-only Android toolchain fixture | `sample/build/sample.apk` |
| `sample-androidx/` | AndroidX/Material toolchain fixture | `sample-androidx/build/sample-androidx.apk` |
| `toolchain/` | Download/setup, compile, test, package, and verify scripts | `toolchain/vendor/` is generated and ignored |
| `pscheck/` | Windows GUI sender integration-test helpers | Generated files stay under ignored build/cache directories |

Android projects use the toolchain's flat layout:

```text
PROJECT/AndroidManifest.xml
PROJECT/res/
PROJECT/src/
PROJECT/test/
```

The previous wrapper and some inherited docs referred to a nonexistent `app/`
directory and to checkout-specific `/home/user/ghosthand/...` paths. The actual
application is under `btaudio/`; build scripts now resolve project/source paths
from their own locations, so they work from a fresh clone and from any current
working directory.

`build-all.sh` includes both samples because they exercise the compiler and
AndroidX resource/link path. The optional Windows tests need a .NET SDK with
.NET Framework 4.8 reference assemblies, PowerShell, and `socat`. In auto mode
they are skipped with a note when those host tools are absent; `--windows`
requests them explicitly.

For user-facing Windows setup and sender controls, see [README-WINDOWS.md](README-WINDOWS.md).
For individual compiler stages and toolchain provenance, see
[`toolchain/README.md`](toolchain/README.md) and [`RECIPE.md`](RECIPE.md).
