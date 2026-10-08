# How to test-compile Java **and XML for Android** in a locked-down sandbox

A recipe you can hand to another model. Everything here was executed in a Debian 12
sandbox with **no root, no apt, no Android SDK manager, no Gradle, no Maven**, and
no network access except a small egress allowlist.

Working implementation lives in [`toolchain/`](toolchain/) — `setup.sh`, `check.sh`,
`build.sh`, `test.sh`, `xmlcheck.py`, `zipalign.py` — plus a runnable
[`sample/`](sample/) app and an AndroidX one, [`sample-androidx/`](sample-androidx/).
Timings from the sandbox: **setup 10 s, check 2 s, unit tests 2 s, APK build 6 s;
AndroidX fetch + fuse 35 s (one-off), AndroidX APK build 50 s (Debug) / 39 s (R8).**

---

## 0. What you end up with

| Capability | Tool | Where it came from |
|---|---|---|
| Run Java (no root) | Temurin **JRE 25** | PyPI `jdk4py` |
| Compile Java (`javac`) | Eclipse **ECJ 3.45** batch compiler | npm `@vscjava/java-language-server` |
| Compile **XML / resources / manifest** | **aapt2 2.19** Linux binary | PyPI `aapt2` |
| Android platform API (bootclasspath) | **android.jar** API 34 (and 30–37) | npm `@drxiaozhi/minapk`, GitHub `Sable/android-platforms` |
| Java bytecode → `classes.dex` | **D8 8.2.2** (+ R8 for release) | npm `@drxiaozhi/minapk` |
| Sign the APK | **apksigner** + debug keystore | npm `@drxiaozhi/minapk` |
| Align the APK | **zipalign** — reimplemented in Python | this repo, `toolchain/zipalign.py` |
| Disassemble/verify an APK | **apktool 2.4.1** | npm `apktool-jar` |
| Run unit tests on the JVM | **JUnit 4.13.2 + Hamcrest** | npm `@vscjava/java-language-server` |
| Android XML lint before compiling | `xmlcheck.py` | this repo (stdlib only) |
| **AndroidX** (appcompat, material, recyclerview, …) | **69 real AARs → one classpath jar + compiled resources + R classes** | a committed Gradle cache on GitHub (section 9) |

`bash toolchain/setup.sh` fetches all of it (~170 MB, 10 s), verifies every tool by
running it, and writes `toolchain/env.sh`.

---

## 1. Map the egress allowlist first

Probe before planning. `curl -s -o /dev/null -w '%{http_code}' --max-time 6 <url>`:

```
200 https://pypi.org/simple/          <- Java runtime, aapt2 (NOT the Android SDK)
200 https://registry.npmjs.org/       <- ECJ, D8, R8, apksigner, android.jar, apktool, JUnit
200 https://github.com/               <- plus codeload.github.com: real git clone works
000 https://deb.debian.org/           <- apt dead
000 https://api.adoptium.net/         <- no JDK downloads
000 https://download.java.net/        <- no JDK downloads
000 https://repo1.maven.org/maven2/   <- Maven Central dead
000 https://dl.google.com/            <- no SDK, no build-tools, no platform zips
000 https://maven.google.com/         <- dead: no AGP, no R8 from Google
000 https://services.gradle.org/      <- dead: no Gradle wrapper
000 https://raw.githubusercontent.com/ <- dead, but *clone* and the GitHub API work
000 https://objects.githubusercontent.com/  <- so GitHub *releases* are unusable
```

Two consequences worth internalising:

* **The allowlist varies per sandbox.** The first pass at this recipe saw only
  PyPI + npm. This one also has GitHub, which adds a second, independent source for
  `android.jar` and for tool-tarball repos. Probe every time; never assume.
* **GitHub *release* assets are unreachable** (`objects.githubusercontent.com` is
  dead) while `git clone` and `api.github.com` are alive. So you fetch **files
  committed into repos**, never release attachments:
  `git clone --depth 1 --filter=blob:none --no-checkout <repo>` + `git checkout HEAD -- path`
  pulls a single blob — that is how `Sable/android-platforms` gives you an
  `android.jar` for *any* API level (30…37), 27 MB in ~2 s.
  (`gh api /repos/O/R/contents/PATH --jq .content | base64 -d` works too, for files < 1 MB.)

## 2. Get a Java runtime from PyPI — `jdk4py`

`pip download --no-deps --only-binary :all: jdk4py` gives a wheel with a full
Temurin **JRE** at `jdk4py/java-runtime`. Unzip it, `chmod +x bin/*`, done — no
installer, no root. It is a JRE: `java`, `keytool`, `jfr` exist, **`javac`, `jar`,
`jlink` do not**. It runs cleanly (`ldd` shows no missing libs) and includes
`java.desktop` (so AWT/Swing/headless rendering still work for GUI tests).

## 3. Get a compiler from npm — Eclipse **ECJ**, not javac

The trick from last time still holds and is still the key insight: **toolchains hide
inside packages whose *purpose* is to bundle them.** `@vscjava/java-language-server`
(VS Code's Java language server, ~51 MB) is JDT, and JDT ships the Eclipse batch
compiler:

```
package/server/plugins/org.eclipse.jdt.core.compiler.batch_3.45.0.v20260224-0835.jar
```

ECJ is pure Java, runs on any modern JRE, and takes javac-shaped flags. The same
tarball also contains **`org.junit_4.13.2`** and **`org.hamcrest_3.0.0`**, which is
how you get *runnable* unit tests with no Maven in sight.

**Android specifics that matter:**

```bash
# source ≤ 8: full Android fidelity. android.jar IS the bootclasspath, so
# java.* resolves to Android's stubs and a Java API Android lacks is an error.
java -jar ecj.jar -source 8 -target 8 -encoding UTF-8 -proc:none \
     -bootclasspath android.jar -classpath android.jar \
     -d out $(find src -name '*.java') gen/com/example/R.java
```

* **You must generate `R.java` first** (see step 5) or every `R.string.x` is a
  compile error.
* **Above source 8 ECJ refuses `-bootclasspath`** ("option -bootclasspath not
  supported at compliance level 9 and above"), and putting android.jar on the
  *classpath* at 9+ fails with *"The package java.util is accessible from more than
  one module: `<unnamed>`, java.base"* (100 errors from the platform alone).
  `--patch-module java.base=android.jar` does **not** fix it — it merges rather than
  replaces, so the JRE's extra APIs leak through. The workaround that does work:
  hand ECJ an android.jar with the JRE-owned packages stripped
  (`java/ javax/ jdk/ sun/ com/sun/ org/w3c/ org/xml/ org/ietf/ org/omg/`) — see
  `toolchain/filter_android_jar.py`. Then `android.*` comes from Android and
  `java.*` from the JRE.
* Consequence to be honest about: at **source 17** records, sealed types, `var`,
  text blocks, pattern matching and `Stream.toList()` all compile and dex fine, but
  Java *API* checking is loosened (a Java-17-only API Android lacks will compile).
  Default to **source 8** when you want API-accurate checking; use 17 when you need
  language features. Both modes are exercised in `toolchain/check.sh`.

Dead ends from experience: JDK 8's `tools.jar` on npm (`dataslope-tools-jar`) dies on
a modern JRE (wants a Java 8 `rt.jar` bootclasspath); TeaVM-javac (WASM, in
`@tracecode/tracejvm`) compiles on node but has no `-target`, so its bytecode is
always current-version and unusable as Android dex input.

## 4. Get the Android tooling from npm, as jars

`@drxiaozhi/minapk` (40 MB) is an APK-builder package whose `tools/` folder is the
whole Android half of the pipeline: **`d8.jar` (D8 *and* R8 8.2.2), `apksigner.jar`,
`android.jar` (API 34, 26 MB), `ecj-3.45.0.jar`, `debug.keystore`**. All plain JVM
bytecode, so they run on the jdk4py JRE:

```bash
java -cp d8.jar com.android.tools.r8.D8 --version   # D8 8.2.2-dev
java -cp d8.jar com.android.tools.r8.R8 --version   # R8 8.2.2-dev
java -jar apksigner.jar verify --print-certs app.apk
```

Trap worth knowing: the npm package **`d8-termux` also ships a file called
`d8.jar`, but it is a DEX container** (`classes.dex`, `classes2.dex`, …) meant to run
under Android's `app_process`. `com.android.tools.r8.D8` does not exist there. Check
for a `META-INF/MANIFEST.MF` and real `.class` entries before believing a jar.

## 5. Compile XML with **aapt2** from PyPI

`pip download aapt2` is a 5.6 MB wheel containing three prebuilt binaries
(`aapt2/bin/{Darwin,Linux,Windows}/`). The Linux one is a normal glibc executable
and prints `Android Asset Packaging Tool (aapt) 2.19-7832930`. That single binary is
your XML compiler, resource compiler, manifest validator, R.java generator and, with
`dump xmltree` / `dump badging`, binary-XML inspector:

```bash
aapt2 compile --dir res -o res.zip                    # every res XML -> .flat (+ validates it)
aapt2 link -o app-unsigned.apk -I android.jar \
     --manifest AndroidManifest.xml -R res.zip \
     --java gen --auto-add-overlay \
     --min-sdk-version 24 --target-sdk-version 34 \
     --version-code 1 --version-name 1.0
```

* `--auto-add-overlay` is required when you pass `-R res.zip`, otherwise you get
  *"resource string/app_name does not override an existing resource"*.
* If you build with the support-library vector path, add `--no-version-vectors`.
  Otherwise aapt2 applies "resource versioning" to every `<vector>` when
  `--min-sdk-version` is below 21: API-21 attributes move to `res/drawable-v21/` and
  the base file ships as a gutted `<vector>`. Pre-L devices inflate the base first and
  die with `Resources$NotFoundException` ("invalid drawable tag vector") - AppCompat's
  `VdcInflateDelegate` fails the parse, and the platform fallback has never heard of
  `<vector>`. The flag's help text says to use it "only when building with vector
  drawable support library", which is precisely this situation. Keep legitimate
  attribute-level versioning (`res/xml-v22/` for an API-22 attribute) - it is a
  different mechanism and the flag does not touch it.
* aapt2 reads the manifest **and** every resource: undefined `@string`, `@color`,
  `@style`, bad attribute names, malformed XML and API-31+ `android:exported`
  problems are all link-time errors. It is the authoritative XML check.
* `aapt2` has **no `-f`**; for a different API level fetch another android.jar
  (step 1) and pass `-I`. Newer aapt2 (2.20) is also inside npm `aaptjs3`
  (`package/bin/x64/linux/aapt2`) if you want two independent sources.
* Add `xmlcheck.py` (stdlib-only) *in front of* aapt2 for fast, specific
  diagnostics: well-formedness with line numbers, manifest structure, duplicate
  `<string>` names, unescaped apostrophes, and `@type/name` references that do not
  resolve (`@string/app_nam` typos) — aapt2 fails on the first error, this reports
  them all at once.

## 6. `javac`-free dexing and signing, then alignment

```bash
java -cp d8.jar com.android.tools.r8.D8 --min-api 24 --lib android.jar \
     --output build/dex $(find build/classes -name '*.class')
java -cp d8.jar com.android.tools.r8.R8 --release --dex --min-api 24 \
     --lib android.jar --pg-conf proguard.pro --output build/dex <classes>
```

* D8/R8 **desugar**: Java 17 class files (major 61) dex fine at `--min-api 24`, so
  language features survive the round trip.
* Get `classes.dex` into the APK without the `jar` tool: Python's `zipfile` appends
  it (`z.write('build/dex/classes.dex', 'classes.dex')`). Remember that a runnable
  jar would need `META-INF/MANIFEST.MF` with **CRLF** line endings and a trailing
  blank line (`Main-Class: movies.Main`) — same trick as before, just for dex it is
  the APK itself that is the zip.
* **`zipalign` is the one build-tools binary PyPI and npm do not have.** The Linux
  `zipalign`s you find on GitHub are Android/bionic ELFs (`Nanolx/NanoDroid`
  `Full/zipalign.x86` fails with *"cannot execute: required file not found"* —
  missing `/system/bin/linker`), and real `zipalign` is glibc-only from build-tools.
  It is ~40 lines of `struct.pack` to reimplement: rewrite the zip so every entry's
  data offset is 4-byte aligned (4096 for `.so` with `-p`), padding via a 0xD935
  extra field, recomputing local-header offsets and the central directory. Then
  **align before signing** — v2 signing preserves layout, and if you enable v1 (only
  needed below minSdk 24) apksigner writes `META-INF/*` *after* alignment, so a
  post-sign check has to ignore `^META-INF/` (real zipalign has the same ordering).
* Verify, don't hope: `apksigner verify --print-certs` (v2 block present) +
  `aapt2 dump badging` (`package:`, `launchable-activity:`) + `apktool d`
  (independent decode of your own APK back to smali + resources).

## 7. Test *behaviour*, not just compilation

* **JUnit on the JVM**: compile the app's pure-Java classes (no `android.*` calls at
  runtime — the stubs in android.jar throw `Stub!`) together with `src/test/java`
  and run `org.junit.runner.JUnitCore`. The JUnit + Hamcrest jars come from the same
  language-server tarball as ECJ, so this costs nothing extra. `toolchain/test.sh`
  does exactly this and prints `OK (4 tests)`.
* **GUI without X11**: the JRE has `java.desktop`, so building Swing/Compose-style
  panels headlessly and painting a `JComponent` into a `BufferedImage` still works
  with `-Djava.awt.headless=true`; only top-level `JFrame` window screenshots need a
  real X server (Xvfb is unavailable when apt is blocked).
* **Anything Android runtime**: impossible without a device/emulator — you have no
  `adb`, no ART. Compilation, dex validity, APK structure and pure-Java logic are the
  honest limits here, and they cover the great majority of "does this build?" work.

## 8. How to find more packages like these

`curl https://pypi.org/simple/` is a ~45 MB index of every package name (grep it),
`https://registry.npmjs.org/-/v1/search?text=...` searches npm, and
`gh api /search/code -f q='filename:r8.jar'` searches GitHub code. The heuristic
that keeps paying off: **look for packages whose purpose is bundling** — language
servers, playground/runner images, "build APK without Android Studio" tools, JRE
shims — not packages named after the tool you want. `aapt2` on PyPI, `apktool-jar` on
npm, `d8.jar` inside an APK-builder, `junit.jar` inside a language server, and the
whole Android platform jar inside a Bun-to-APK package were all found that way.

---

## 9. AndroidX without Maven (appcompat, material, recyclerview, …)

Maven is dead here. `maven.google.com`, `repo.maven.apache.org`, `jitpack.io`,
`search.maven.org`, `central.sonatype.com`, Aliyun/Huawei/Tencent mirrors,
`cdn.jsdelivr.net`, `unpkg.com`, `dl.google.com/dl/android/maven2`,
`storage.googleapis.com`, `repo.gradle.org`, `android.googlesource.com`,
`gitlab.com` and `bitbucket.org` **all answer 000**. AndroidX normally arrives from
one of those hosts, so it has to be found somewhere else entirely.

### 9.1 Where the bytes actually are

GitHub *is* reachable, and people commit their resolved Gradle cache to their repos.
Search for a Maven filename that only exists inside a cache:

```bash
gh api -f q='filename:appcompat-1.6.1.pom' /search/code --jq '.items[]|.repository.full_name' | sort -u
```

One hit is the source of record: **`AuntiSaha/weather_app`** — 616 committed files
that are literal `~/.gradle/caches/modules-2/files-2.1/...` contents, **69 AARs and
10 jars, real blobs, no Git-LFS**. Fetch only what you need with a blobless clone:

```bash
git clone --depth 1 --filter=blob:none --no-checkout https://github.com/AuntiSaha/weather_app.git src
cd src && git checkout HEAD -- '*.aar'      # 34 s, 11 MB of working tree -> 69 AARs
```

Dead ends worth not repeating: repos that store their AARs with **Git-LFS** are
useless (the batch API returns 200 and a download URL, but the media host answers
000 — same for `media.githubusercontent.com`); the AOSP *prebuilts/maven_repo*
mirrors committed to git (`TinkerBoard-Android`, `msft-mirror-aosp`, …) stop at
AndroidX `1.0.0-alpha/beta01`; Chaquopy's AndroidX wheels are `.pyi` type stubs only;
ROM app repos vendor camera/coil/material AARs, never a general closure.

### 9.2 Turn AARs into something ECJ/aapt2/D8 understand

An AAR is a zip of `classes.jar`, `res/`, `R.txt`, `AndroidManifest.xml`. AGP's job
— mostly undocumented — is to (a) put every `classes.jar` on the classpath (b) compile
every `res/` and merge the tables and (c) **give each library its `R` class**, because
AndroidX AARs ship `R.txt` with `0x0` placeholders and *no `R.class` at all*.

```bash
python3 toolchain/extract_aar.py  src  vendor/androidx/aar          # explode (adds manifest package + R.txt)
python3 toolchain/androidx_assemble.py --stage vendor/androidx/aar \
        --jars src --out vendor/androidx --aapt2 toolchain/vendor/aapt2
```

`androidx_assemble.py` produces:

| output | what it is | who consumes it |
|---|---|---|
| `androidx.jar` | all `classes.jar` merged into one fat jar | ECJ `-classpath`, D8/R8 **program input** |
| `res/*.zip` | one `aapt2 compile` zip per library | `aapt2 link -R …` per library |
| `packages.txt` | the 46 library package names | `aapt2 link --extra-packages …` |

`--extra-packages` is the trick that matters: aapt2 then emits a **correct `R.java`
per library** (`androidx/appcompat/R.java`, `com/google/android/material/R.java`, …,
45 000 lines for appcompat) *including populated `styleable` arrays* — the thing a
hand-written R stub gets wrong. Material's own code compiles against it unmodified.

### 9.3 The last brick: `core-lambda-stubs.jar`

`-source 8` + any lambda dies on `java.lang.invoke.LambdaMetafactory`, which
`android.jar` does not contain (AOSP ships it separately; AGP injects
`core-lambda-stubs.jar` from build-tools). It is a signature-only stub, so compile it
locally with ECJ and put it on the bootclasspath:

```bash
java -jar ecj.jar -source 8 -target 8 -proc:none -bootclasspath android.jar \
     -d stubs toolchain/lambda-stubs/java/lang/invoke/LambdaMetafactory.java
# check.sh / build.sh then pass:  -bootclasspath android.jar:stubs
```

### 9.4 What it buys you

`sample-androidx/` uses `AppCompatActivity`, `MaterialToolbar`, `MaterialButton`,
`Snackbar`, `RecyclerView`, `ConstraintLayout`, a lifecycle `ViewModel` and a
Material 3 theme — one layout referencing resources from four different AARs:

```bash
bash toolchain/androidx.sh                    # fetch + assemble, 35 s, 33 MB in vendor/
bash toolchain/check.sh  sample-androidx      #  17 s  CHECK PASSED   (R classes + ECJ)
bash toolchain/test.sh   sample-androidx      #   7 s  OK (3 tests)   (JUnit on the JRE)
bash toolchain/build.sh  sample-androidx --verify            # 50 s -> 5.4 MB APK, 6 dex, 50 168 methods
bash toolchain/build.sh  sample-androidx --release --verify  # 39 s -> 1.6 MB APK after R8 shrinking
```

Every claim above is checked by a different tool: `aapt2 dump badging`, `apksigner
verify`, `zipalign -c`, and `apktool d` decoding 5 467 `.smali` files back out of the
APK — including `smali/androidx/appcompat/**`. AndroidX is applied automatically when
a project mentions `androidx.`, `Theme.AppCompat`, `Theme.Material3`,
`MaterialComponents` or `com.google.android.material` (so the plain `sample/` stays a
2 s, 8 KB-dex build); `--no-androidx` / `GH_ANDROIDX=off` opts out.

Known limits: library `<provider>`/`<receiver>` entries are not manifest-merged
(androidx.startup, emoji2 and profileinstaller auto-init therefore do not run — no
crash, they simply stay dormant), resources are merged non-namespaced with
`--auto-add-overlay`, and dependency versions are whatever the harvested cache
contains.

---

### The one runtime dependency you cannot skip: Kotlin

Harvesting the AARs is only half of it. Google compiles a large part of AndroidX from
Kotlin, so `androidx.fragment.app.FragmentActivity` - the superclass of every
`AppCompatActivity` - calls `kotlin.jvm.internal.Intrinsics` in its constructor. An APK
built from these AARs with no Kotlin runtime therefore dies at launch with
`ClassNotFoundException: kotlin.jvm.internal.Intrinsics`, and *the build does not fail*:
R8 treats a missing class as a warning unless you ask it not to, and a `-dontwarn` line
will silence it for good measure.

There is no stdlib-only package on PyPI (checked: `kotlin-stdlib`, `kotlin-jvm` -> 404) and
none on npm under that name (the package called `kotlin` is the Kotlin/JS stdlib - `kotlin.js`
and `.kjsm` metadata, useless for an APK). What does exist is `kotlin-compiler` on npm: the
official Kotlin distribution, which ships `lib/kotlin-stdlib.jar` (1.7 MB) and
`lib/annotations-13.0.jar` (20 KB) next to the compiler. `toolchain/setup.sh` pulls the 87 MB
tarball once, extracts those two files, deletes the tarball, and verifies the jars contain
`kotlin/jvm/internal/Intrinsics.class` and `org/jetbrains/annotations/NotNull.class`.

Version 1.9.25 is pinned deliberately: it matches the AndroidX generation vendored here
(appcompat 1.6.1 / material 1.10.0 / activity 1.8.0), and the 2.x stdlib raises its own
minimum Android level. The stdlib goes on the compile classpath *and* into the dexers as a
program input; the annotations jar goes in as a `--lib` input only - `@NotNull`/`@Nullable`
are CLASS-retention metadata that a device never loads.

The lesson worth keeping: a `-dontwarn` on a package you do not ship is a claim that the
code never runs, and it is a claim nobody checks. `packaging-allowlist.txt` and the
self-containment check in `verify_apk.py` replace that claim with an audit of the finished
APK.

## Appendix: end-to-end, copy-pasteable

```bash
git clone <this repo> && cd GhostHand
bash toolchain/setup.sh                 # ~10 s, PyPI + npm + GitHub only

bash toolchain/check.sh  sample          # 2 s: XML lint -> aapt2 -> ECJ -> D8
bash toolchain/test.sh   sample          # 2 s: JUnit 4 on the bundled JRE
bash toolchain/build.sh  sample --verify # 6 s: signed, aligned, verified APK

# AndroidX (one-off fetch, then it is automatic for every project that uses it):
bash toolchain/androidx.sh               # 35 s
bash toolchain/check.sh  sample-androidx
bash toolchain/build.sh  sample-androidx --release --verify

# a real project (flat or Gradle layout), another API level, Java 17 language mode:
bash toolchain/setup.sh --api 35    --vendor /tmp/tc
bash toolchain/build.sh  ~/myapp --api 35 --min-api 24 --source 17 --release --verify
```
