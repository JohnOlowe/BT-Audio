# toolchain/ — Android Java + XML builds with no SDK, no Gradle, no Maven

Everything in here runs with **no root, no apt and no Android SDK**: the tools come
from PyPI, npm and GitHub. See [`../RECIPE.md`](../RECIPE.md) for the full write-up
and the reasoning behind each choice (section 9 covers AndroidX).

```bash
bash toolchain/setup.sh                     # fetch + verify everything (~10 s, ~170 MB)
                                            #   --api 35          another platform level
                                            #   --vendor /tmp/tc  keep it out of the repo
                                            #   KEEP_TMP=1        keep the download cache

bash toolchain/check.sh  sample              # fast test-compile (XML + Java + D8)
bash toolchain/test.sh   sample              # compile AND run JUnit 4 unit tests
bash toolchain/build.sh  sample --verify     # signed, aligned, verified APK

# AndroidX: once, from a committed Gradle cache on GitHub (no Maven, ~35 s)
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

```
bash build.sh                       # runs both, after building
python3 verify_apk.py  app/build/app.apk     # R8 kept what the framework looks up
python3 check_api.py   app/build/stage/classes --min-api 19 \
                       --android-jar toolchain/vendor/android-19.jar --apk app/build/app.apk
```

`verify_apk.py` (repo root) is about shrinking and packaging: required classes and call
strings in the dex, required resources in the compiled XML, and the dex count against the
manifest's own `minSdkVersion` - because Dalvik loads one dex file and a `minSdk < 21` APK
with a second one is broken on exactly the phones it claims to support. It also understands
that aapt2 version-qualifies a resource when a newer attribute is involved - and fails the
build when that versioning gutted a vector's base copy (see the caveats below).

`packaging-allowlist.txt` (repo root) is about the *finished APK*: every type the dex
names under `androidx.*`, `com.google.*`, `kotlin.*`, `kotlinx.*` or the app's own package
must be defined in that APK or declared there with a reason. This is the check that
catches a library compiled against something the build never linked - the failure mode
that shipped once already, as a `ClassNotFoundException` on launch (`-dontwarn kotlin.**`
had been hiding R8's report that the Kotlin runtime was missing). Entries are scoped
`both`/`release`/`debug` so an entry needed only by the unshrunk build is not reported
stale when the release one is verified.

`toolchain/aar_floor.py` is about the floor the *libraries* ask for: it reads each vendored
AAR's own `minSdkVersion` and fails the build if one needs a newer platform than the app
claims. Gradle would have caught this while merging manifests; here the link step sees only
the app manifest, so it is checked explicitly.

`check_api.py` (repo root) is about API levels: it parses each class file's constant pool
and checks every `android.*` and `java.*` reference against a real `android.jar` of the
minimum level, resolving inherited methods the way the JVM does. Anything that genuinely
needs a newer platform must be declared in `api-levels.txt` with its level and a reason;
an exemption that stops being used is reported as stale. It also reads the dex to confirm
the lambdas were desugared (`invoke-custom` must not survive below API 26).

Both are run by the root `build.sh`, after the APK is signed and before anything can be
published.

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

## Artwork: generated resources, not hand-edited files

Two drawings in `design/` are the source of truth for everything visual: the launcher mark
and the splash hand. `design/make_assets.py` turns them into every density of launcher icon,
the adaptive icon XML, the notification silhouette and the splash bitmap, and `--check` fails
if the committed resources are stale. The reason to generate rather than edit: the same mark
has to exist at five densities in three forms (legacy square, legacy round, adaptive
foreground) plus a silhouette, and a hand-edited set is guaranteed to drift.

Two things in it are worth remembering. The generated art arrives as a rounded tile on a
white field, so a naive bounding box finds the white corners - `flatten_tile()` flood-fills
the field away first (and swallows the tile's antialiased edge, which is invisible on a teal
icon but becomes an outline once alpha is used as a shape). And the notification icon is
derived from the launcher mark's alpha channel, because Android tints a notification icon and
throws its colours away.

`design/splash_preview.py` renders the splash animation off-device, reading its constants out
of `SplashChoreography.java` so the preview cannot drift from the real thing. It is a
replica, not proof - but it is how a hand that tapped upwards through the glass was caught.

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
  `keystore/damjay_debug.keystore` if it finds one. That is what keeps every GhostHand
  build signed with one stable key, so a new APK installs over the previous one.
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
