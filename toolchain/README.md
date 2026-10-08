# toolchain/ — Android Java + XML builds with no SDK, no Gradle, no Maven

Everything in here runs with **no root, no apt and no Android SDK**: the tools come
from PyPI, npm and GitHub. See [`../RECIPE.md`](../RECIPE.md) for the full write-up
and the reasoning behind each choice (section 9 covers AndroidX).

```bash
bash toolchain/setup.sh                     # fetch + verify the Android tools
                                            #   --api 35          another compile platform
                                            #   --ref-api 24      platform used by the API audit
                                            #   --vendor /tmp/tc  keep tools out of the repo

bash toolchain/check.sh  btaudio             # fast XML + Java + D8 compile check
bash toolchain/test.sh   btaudio             # run the BT Audio JVM unit tests
bash toolchain/build.sh  btaudio --release --verify

# One command for every Android project, including the AndroidX fixture:
bash build-all.sh

# AndroidX is fetched/assembled by build-all.sh (or explicitly, once):
bash toolchain/androidx.sh
bash toolchain/check.sh  sample-androidx
bash toolchain/build.sh  sample-androidx --release --verify
```

All three accept a flat project (`AndroidManifest.xml`, `res/`, `src/`) or the
Gradle layout (`src/main/AndroidManifest.xml`, `src/main/res`, `src/main/java`).

| file | what it is |
|---|---|
| `setup.sh` | downloads JRE, ECJ, JUnit, D8/R8, apksigner, android.jar, aapt2, apktool, lambda stubs; runs each one to prove it works; writes `env.sh` |
| `env.sh` | generated; `source` it to get `JAVA_HOME`, `ECJ_JAR`, `D8_JAR`, `AAPT2`, … |
| `lib.sh` | shared build helpers (layout detection, aapt2/ECJ/dex wrappers, AndroidX wiring) |
| `check.sh` | XML lint → aapt2 compile/link → ECJ → D8. The "does it compile?" loop, ~2 s |
| `test.sh` | adds `test/` (or `src/test/java`) sources and runs JUnit 4 on the JRE |
| `build.sh` | the full pipeline: resources, manifest, R.java, Java, dex, zipalign, sign, verify |
| `xmlcheck.py` | stdlib-only Android XML/manifest linter (runs before aapt2) |
| `zipalign.py` | pure-Python zipalign (rewrite + `-c` check), since build-tools is unreachable |
| `filter_android_jar.py` | strips JRE-owned packages from android.jar for `-source 11/17` |
| `lambda-stubs/` | the one class `android.jar` lacks (`LambdaMetafactory`); `setup.sh` compiles it into `vendor/core-lambda-stubs.jar` |
| `androidx.sh` | fetches AndroidX and assembles `vendor/androidx/` (one-off, needs the network) |
| `ecj_compile` (in `lib.sh`) | wipes its output directory first, so a class whose source was refactored away cannot linger on disk and be dexed into the APK |
| `resolve_signing` (in `lib.sh`) | picks the keystore to sign with: `SIGN_KEYSTORE`/`SIGN_*` env vars first, then the project's `gradle.properties` + `keystore/`, then the bundled debug key |
| `androidx_fetch.py` | blobless clone of the source repo + fetch of the selected AARs/jars |
| `select_androidx.py` | picks the highest version of each wanted artifact, skips `-sources`/`-javadoc`/KTX/test-only |
| `extract_aar.py` | explodes AARs (classes.jar, res/, R.txt, AndroidManifest.xml, libs/, assets/) |
| `androidx_assemble.py` | merges the jars, compiles every library `res/`, writes `packages.txt` |

## Options

```
build.sh DIR [--api N] [--min-api N] [--source 8|11|17|21|25] [--release]
             [--out FILE] [--verify] [--no-androidx]
setup.sh [--api N] [--ref-api N] [--vendor DIR]
check.sh DIR [--api N] [--min-api N] [--source N] [--no-dex] [--no-xml-lint]
             [--no-androidx] [--full-dex]
test.sh  DIR [--source N] [--filter SomeTest] [--no-androidx]
```

`--api` is the platform you *compile* against and does not constrain what you may call;
`--min-api` is the promise the APK makes about where it will run. Only `setup.sh --ref-api`
(or the root `build.sh`, which runs it) fetches the matching reference `android.jar` for
`check_api.py`, which is what actually verifies that promise - the compiler cannot, because
it only ever sees the newest platform.

Without `--release` the build is a debug build in both senses: D8 instead of R8, **and**
`android:debuggable="true"` — `aapt2 link --debug-mode` sets that, which is what AGP does
for a debug variant. Leave it out and you get an APK that is merely unshrunk: no attachable
debugger, no `run-as`, and nothing in logcat indicating it is debuggable.

## Checking what the artifact promises

```bash
python3 verify_apk.py btaudio/build/btaudio.apk --project btaudio --min-api 24
python3 check_api.py btaudio/build/stage/classes --min-api 24 \
  --android-jar toolchain/vendor/android-24.jar --apk btaudio/build/btaudio.apk
```

`verify_apk.py` checks the built artifact: source/APK package and minSdk agreement,
manifest components (so R8 cannot silently delete an activity or service), dex count
against the declared floor, vector base resources, and self-containment of the project
and AndroidX/Kotlin dependency types referenced by dex. `toolchain/manifest_keep.py`
generates manifest-derived keep rules during release builds.

Optional packaging exceptions live beside the project in
`PROJECT/packaging-allowlist.txt`; this keeps an AndroidX fixture's optional runtime types
from affecting unrelated APKs. Entries may be scoped `both`, `release`, or `debug`, and
an unused entry fails verification for that build configuration.

`check_api.py` checks framework references against an `android.jar` for the app's minimum
API, including inherited methods. Any guarded newer-API symbols must be declared in the
root `api-levels.txt` with their introduction level and a reason; unused entries fail as
stale.

## Keeping the manifest's classes alive

R8 never reads `AndroidManifest.xml`. The activities and services Android instantiates by
name look to it like unused classes, so without help it deletes them and the app dies at
launch with `ClassNotFoundException`. AGP generates keep rules from the merged manifest;
`toolchain/manifest_keep.py` does the same here: `lib.sh` runs it during the release dex
step and passes the result to R8 as a second `--pg-conf`.

The rule for anything in this toolchain that must stay in sync with a source file: derive it
from the source and fail when they disagree. This script used to be a comment in
`proguard.pro` saying "keep them in sync with the manifest", and the splash activity's
absence from that list shipped a release APK that could not start. `verify_apk.py` now
re-parses the manifest with the same function and fails any APK missing a declared
component, so even bypassing the generator is caught.

## Design assets are separate from the BT Audio project

The `design/` directory is retained as upstream toolchain/design material and is not
consumed by `btaudio/`. The BT Audio launcher resources are checked into
`btaudio/res/mipmap-*`; do not run `design/make_assets.py` as part of an Android build.

## The Kotlin runtime, and why a Java-only app has one

`toolchain/setup.sh` step 6c vendors `kotlin-stdlib.jar` and `kotlin-annotations.jar` from
the official Kotlin distribution on npm (`kotlin-compiler`, version pinned to 1.9.25 - the
generation the vendored AndroidX was built against; the 2.x stdlib raises its own Android
floor). The app's own source is 100% Java and stays that way, but Google compiles much of
AndroidX from Kotlin, so classes we call - `AppCompatActivity` and everything under it -
call `kotlin.jvm.internal.Intrinsics` on ordinary paths. Gradle adds the stdlib as a
transitive dependency; here it has to be appended to the classpath by hand in
`toolchain/lib.sh`, and the annotations jar goes in as a *library* input to the dexers
(CLASS-retention metadata, never loaded on a device, so it does not ship).

Without it the build still succeeded - R8 only reports a missing class - and the APK died
at launch on a real phone. That is what the packaging check above now makes impossible.

## Which AndroidX artifacts to harvest

`toolchain/select_androidx.py` holds an explicit WANT list, and shorter is better: an
artifact that is not there cannot contribute dangling references, cannot leak resources
into the APK, and cannot be loaded by accident. `androidx.navigation` was dropped because
nothing outside navigation referenced it; `slidingpanelayout` and `window` followed,
because only navigation referenced the first and only slidingpanelayout referenced the
second. `lifecycle-viewmodel-savedstate` stayed, because R8 fails the build without it:
`ComponentActivity`'s constructor calls `SavedStateHandleSupport.enableSavedStateHandles()`.

## AndroidX (optional, automatic once installed)

`toolchain/androidx.sh` builds `vendor/androidx/`:

| path | what it is | how it is used |
|---|---|---|
| `androidx.jar` | every library's `classes.jar` + the plain jars (annotation, collection, lifecycle-common, …) merged | ECJ `-classpath`, D8/R8 program input |
| `res/*.zip` | `aapt2 compile` output per library | `aapt2 link -R` per library |
| `packages.txt` | the 46 library packages | `aapt2 link --extra-packages` → a correct `R.java` per library, styleables included |
| `aar/`, `src/` | exploded AARs, downloaded artifacts | rebuild inputs (`--force`) |

A project gets AndroidX automatically when it mentions `androidx.`,
`Theme.AppCompat`, `Theme.Material3`, `MaterialComponents` or
`com.google.android.material` anywhere in `src/`, `res/` or the manifest — the plain
`sample/` therefore keeps building in 2 s with an 8 KB dex. Force it either way with
`GH_ANDROIDX=on|off` (or `--no-androidx`).

Not done (deliberately, and documented): library `<provider>`/`<receiver>` entries are
not manifest-merged, resources are merged non-namespaced with `--auto-add-overlay`,
and dependency versions are whatever the harvested cache contains.

## Source levels

| `--source` | Behaviour |
|---|---|
| `8` (default) | `android.jar` is the **bootclasspath**: `java.*` resolves to Android's stubs, so a Java API Android does not have is a real error. API-accurate. Lambdas work via the locally built `core-lambda-stubs.jar`. |
| `11`+ | Records, sealed types, `var`, text blocks, pattern matching, `Stream.toList()` all compile and dex. `java.*` comes from the JRE instead, so **API checking is loosened** (the module system forbids `-bootclasspath` at 9+). |

## Caveats worth knowing

* The platform classes in `android.jar` are stubs that throw `Stub!` at runtime — JVM
  unit tests must exercise framework-free logic (which is where the value is anyway).
* `android.jar` is API 34 by default; `--api 30…37` fetches another level from GitHub
  only when you run `setup.sh --api N` (the jar then lives in your vendor dir).
* Signing: by default the APK is signed with the bundled **debug** keystore (alias
  `androiddebugkey`, password `android`) — fine for installing/testing, not for
  publishing. A project that commits its own key wins instead: `resolve_signing()`
  reads `GHOSTHAND_STORE_FILE` / `_PASSWORD` / `KEY_ALIAS` / `KEY_PASSWORD` from the
  project's or the repo root's `gradle.properties`, and falls back to
  `keystore/damjay_debug.keystore` if it finds one. That is what keeps project builds signed with one stable key, so a new APK installs over the previous one.
  PKCS12 has no separate key password (keytool says so and ignores the difference), so a
  key password shorter than the store password is treated as a typo and replaced by the
  store password.
* `vendor/` is gitignored and reproducible: deleting it and re-running `setup.sh`
  takes ~10 s, and `androidx.sh` rebuilds the AndroidX part in ~35 s.
* aapt2 "versions" vector drawables when `--min-sdk-version` is below 21: it moves the
  API-21 attributes (`viewportWidth`, `viewportHeight`, `fillColor`, `pathData`) into
  `res/drawable-v21/` and leaves the base file as an empty `<vector>`. On a pre-21 phone
  that base is what gets inflated - AppCompat's `VdcInflateDelegate` fails, the platform
  fallback does not know `<vector>` either, and the app crashes at launch
  (`Resources$NotFoundException` on the first vector probed, `abc_vector_test`). This
  shipped as versionCode 3 with 59 of 74 drawable pairs stripped; `aapt2_link()` now
  always passes `--no-version-vectors` (its help: "Use this only when building with
  vector drawable support library" - which is exactly this build), and `verify_apk.py`
  fails an APK whose base copy lacks `viewportWidth` while some versioned variant of the
  same name still has it. AAR-shipped `drawable-v21/` variants and the `xml`/`xml-v22`
  attribute split are unaffected.
