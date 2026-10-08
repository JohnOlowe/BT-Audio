# GhostHand

**One phone becomes the screen. The other becomes the hands.**

GhostHand streams one Android phone's screen to another over WiFi - no cables, no
cloud, no accounts. Two phones on the same network, one APK, two roles:

| | | |
|---|---|---|
| **Host** | Captures its own screen (`MediaProjection`), encodes it to H.264 (`MediaCodec`) and serves it over TCP. | Android 5.0+ |
| **Guest** | Finds the host with mDNS (or an IP you type), decodes the H.264 and draws it full screen. | Android 4.4+ |
| **Touch** | The guest's taps and drags are injected into the host through an `AccessibilityService`. | host needs Android 7.0+ |

The version floors are not arbitrary, and they are what make an old phone useful rather
than useless: a 4.4 phone cannot be *controlled* (synthesising input needs
`dispatchGesture`, added in Android 7.0) and cannot *capture its own screen*
(`MediaProjection`, added in 5.0) - but as the **controller** it needs nothing newer than
4.4. So the oldest device on your desk can drive the newest one. See
[Android 4.4 and the version floors](#android-44-and-the-version-floors).

**Milestones 1 and 2 (this build): mirroring *and* touch.** The guest already sent touch
events; the host now actually injects them, so dragging on the guest moves the real cursor
on the host's screen. The last hop needs a permission an ordinary app cannot have, and the
whole mechanism is explained in [Touch injection](#touch-injection) - including the R8
keep-rule trap that silently deleted it from the release APK.

Package `damjay.control.ghosthand` · **minSdk 19 (Android 4.4)** · targetSdk 34 · Java, no Kotlin · **AndroidX + Material 3**

---

## Quick start

```bash
git clone https://github.com/JohnOlowe/GhostHand.git
cd GhostHand
bash build.sh                 # setup + AndroidX + 118 unit tests + signed APK (~2.5 min cold)
```

`build.sh` installs the toolchain into `toolchain/vendor` (JRE, Eclipse compiler, aapt2,
D8/R8, apksigner) and harvests AndroidX into `toolchain/vendor/androidx`, then produces a
**signed, zip-aligned, R8-shrunk APK** at `app/build/app.apk` (2.5 MB, Android 4.4+).
Want both configurations - the shrunk one and the unobfuscated one - in one go?

```bash
bash build.sh --both          # + app/build/app-debug.apk (5.8 MB, debuggable, Android 5.0+)

adb install -r app/build/app.apk     # on BOTH phones
```

Then: open GhostHand on phone A -> **Host** -> *Start mirroring* -> allow screen capture.
On phone B -> **Guest** -> tap the host in the list (or type the IP shown on phone A) ->
watch.

---

## Where the APK lives (and why it is not in `main`)

The APK is a few megabytes and different on every build. Committing it to `main` would add
a new, non-delta-compressible blob to history on every push, so `git clone` would
eventually drag along every APK ever built.

So the APKs live on their own branch, and **each publish replaces that branch with a single
parentless commit**:

```
 apk:  *                                     <- always exactly 1 commit, both APKs
 main: *---*---*---*---*---*---*             <- source history, never a binary
```

**Two builds, both in that one commit:**

| | file | runs on | what it is |
|---|---|---|---|
| **2.5 MB** | `GhostHand.apk` | **Android 4.4+** | the **release** build - R8 shrunk, renamed and inlined, one dex file. What to install. |
| **5.8 MB** | `GhostHand-debug.apk` | Android 5.0+ | the **debug** build - nothing shrunk or renamed, genuinely `android:debuggable`, six dex files. |

Both are the *same app*: same package, same versionCode, same key, same signature scheme -
so **either one installs straight over the other, in either order**, keeping your data.
Whichever downloads more reliably for you is the right one to take - and on Android 4.4 it
has to be the release build, because the debug one needs the platform's multi-dex loading.

```bash
# get the current builds: one fetch, both files
git fetch origin apk
git show FETCH_HEAD:GhostHand.apk > GhostHand.apk                 # smaller
git show FETCH_HEAD:GhostHand-debug.apk > GhostHand-debug.apk     # bigger, unobfuscated

# publish a new pair (force-pushes one orphan commit over the last)
bash build.sh --publish
```

`publish-apk.sh` builds the commit with git plumbing (`hash-object` -> `mktree` ->
`commit-tree`, pushed with `--force`), so nothing in your working tree is touched and the
branch can never grow a second commit. It refuses to publish an APK that fails the structural
check, or one whose signature does not verify, and it **refuses the pair outright if the two
would not be installable over each other** - it compares the package name, the versionCode
and the signing certificate before writing anything, because a mismatch there is
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` on the phone, which is a bad place to discover it. It
writes both SHA-256s into the branch's README.

Every APK - from any branch, any machine - is signed with the same key
(`keystore/damjay_debug.keystore`, the PalmPay-Clone stable key), so a new build **installs
straight over the previous one**. No uninstall, no `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.

---

## How to build and test (no Android SDK anywhere)

There is no Gradle wrapper here and no SDK install step, because the build environment
cannot reach `dl.google.com`, Maven Central or `maven.google.com`. Instead `toolchain/`
assembles a working Android toolchain from PyPI, npm and GitHub:

| step | tool | from |
|---|---|---|
| run Java | Temurin **JRE** (no `javac`) | PyPI `jdk4py` |
| compile Java | Eclipse **ECJ** batch compiler | npm `@vscjava/java-language-server` |
| compile XML / resources / manifest | **aapt2** | PyPI `aapt2` |
| Android platform API | **android.jar** (API 34) | npm `@drxiaozhi/minapk` |
| **AndroidX** (appcompat, Material 3, RecyclerView, ConstraintLayout, lifecycle) | **69 AARs → one classpath jar + compiled resources + per-library `R` classes** | a Gradle cache committed to a GitHub repo |
| lambda support at `-source 8` | **core-lambda-stubs.jar** | compiled locally from a 37-line stub |
| bytecode → dex | **D8** (debug) / **R8** (release) | npm `@drxiaozhi/minapk` |
| sign | **apksigner** | npm `@drxiaozhi/minapk` |
| align | **zipalign** (reimplemented in Python) | `toolchain/zipalign.py` |
| run unit tests | **JUnit 4.13.2** | npm `@vscjava/java-language-server` |

```bash
bash toolchain/setup.sh              # once: verifies every tool by running it
bash toolchain/androidx.sh           # once: fetches + assembles AndroidX (~35 s, in vendor/)
bash toolchain/check.sh  app         # fast "does it compile?" loop (~20 s)
bash toolchain/test.sh   app         # JUnit unit tests (~2 s, no device needed)
bash toolchain/build.sh  app --release --verify
python3 verify_apk.py    app/build/app.apk   # did R8 keep what the app needs?
python3 check_api.py app/build/stage/classes --min-api 19 \
        --android-jar toolchain/vendor/android-19.jar --apk app/build/app.apk
bash build.sh --both                         # release + debug APKs
```

Two things AGP would have done for you are done explicitly here, because there is no AGP:
`app/proguard.pro` carries the keep rules R8 needs
([why](#r8-and-the-keep-rules-nobody-generated-for-us)), and a non-release build passes
`--debug-mode` to `aapt2` so the "debug" APK really is `android:debuggable="true"`. Without
that flag it is only *unshrunk* - no attachable debugger, no `run-as`, nothing in logcat
saying it is debuggable - which is a trap when the whole point of the file is being able to
see what it is doing.

`toolchain/README.md` documents each script; `RECIPE.md` explains where the tools come from
and which routes are dead ends. This is the supported build path - it runs identically on a
laptop and in CI, and there is no GitHub Actions workflow to wait on.

---

## The AndroidX port

The first build of this app was framework-only (`android.app.Activity`, `findViewById`,
`Notification.Builder`, `@android:style/Theme.Material`), because AndroidX cannot be
resolved without Maven. It now uses AndroidX and Material 3 - the interesting part is
*how* AndroidX arrives, and what is still missing.

### Where AndroidX comes from, and what has to be done to it

An AAR is a zip of `classes.jar`, `res/`, `R.txt` and a manifest. The Android Gradle Plugin
earns its keep by: putting every `classes.jar` on the classpath, compiling every `res/` and
merging the tables, and **generating each library's `R` class** (AndroidX AARs ship `R.txt`
with `0x0` placeholders and no `R.class` at all). `toolchain/androidx.sh` does all three:

| output | what it is | who consumes it |
|---|---|---|
| `vendor/androidx/androidx.jar` | 56 jars merged flat (4 318 classes) | ECJ `-classpath`, and **program input** to D8/R8 |
| `vendor/androidx/res/*.zip` | one `aapt2 compile` zip per library | `aapt2 link -R …` |
| `vendor/androidx/packages.txt` | 46 library package names | `aapt2 link --extra-packages …` |

That last row is the trick worth knowing: `--extra-packages` makes aapt2 emit a **correct
`R.java` per library** - including populated `styleable` arrays - which is exactly the input
Material's own code compiles against. Without it, `Theme.Material3.*` and every
`MaterialCardView` attribute would fail to resolve.

### What each AndroidX piece replaced

| before (framework-only) | now | why it matters here |
|---|---|---|
| `android.app.Activity` | `AppCompatActivity` | AppCompat's view inflater builds every widget from the layout, which is what lets the Material 3 theme reach views the platform would otherwise render plain. |
| `startActivityForResult` + `onActivityResult` + hand-rolled request codes | `registerForActivityResult(new ActivityResultContracts.RequestPermission())` and `…StartActivityForResult()` | the MediaProjection consent dialog and the Android 13 notification grant get typed callbacks that survive process recreation; request codes and `onActivityResult` branching disappear. |
| `Switch` | `com.google.android.material.materialswitch.MaterialSwitch` | Material 3 switch styling, still a `CompoundButton` so the listener code is unchanged. |
| `Spinner` | `TextInputLayout` (`ExposedDropdownMenu`) + `MaterialAutoCompleteTextView` | the Material 3 dropdown; `setSimpleItems(R.array.host_resolution_options)` feeds it the string-array directly. |
| `EditText` (IP field) | `TextInputLayout` + `TextInputEditText` | hints, focus and errors are drawn by the component: `boxHost.setError(...)` replaces hand-written validation text. |
| `LinearLayout` + inflating rows by hand | `RecyclerView` + a real adapter | discovered hosts are recycled, and rows are updated by `notifyDataSetChanged()` instead of tearing the list down on every mDNS update. |
| `Toast` | `Snackbar` | anchored to a view, dismissible, themed. |
| `setSystemUiVisibility(FLAG_FULLSCREEN …)` | `WindowCompat` + `WindowInsetsControllerCompat` | **on API 30+ the old flags are ignored**, so a framework-only build silently stayed windowed on a modern phone. The compat controller uses `WindowInsetsController` where it exists and the legacy flags below 30. |
| `Notification.Builder` | `NotificationCompat.Builder` | small-icon masking and action behaviour normalised across API levels. |
| `@android:style/Theme.Material.NoActionBar` | `Theme.Material3.DayNight.NoActionBar` | full Material 3 palette: colours are Material *roles* (`colorPrimary`, `colorSurface`, `colorOnSurfaceVariant`) declared once in the theme, with `values/colors.xml` + `values-night/colors.xml` supplying light and dark. No per-widget styling. |

### What is still *not* available: view binding

`androidx.viewbinding` is generated code: the Android Gradle Plugin reads the layouts at
build time and writes `ActivityHostBinding.java`. Nothing in this toolchain generates Java
from XML (aapt2 emits `R.java` and nothing else), so the views are still found with
`findViewById`. The ids in the layouts remain the contract between XML and Java, and
`toolchain/xmlcheck.py` is what keeps that contract honest - it resolves every
`@style`, `@string` and `@drawable` reference against both the project and the AndroidX
resources *before* aapt2 ever runs.

### R8 and the keep rules nobody generated for us

The release build is shrunk and optimised by R8 (5.8 MB debug -> **2.5 MB** release, and six
dex files down to one). With
AGP, the "keep the manifest components" rules are generated automatically; here there is no
AGP, so `app/proguard.pro` carries them by hand. Without those few lines R8 would rename or
strip the very classes Android instantiates from the manifest and the app would die with
`ClassNotFoundException` on launch. The file also keeps the names of all `View` subclasses,
because `AppCompatViewInflater` resolves widget classes **by name from the XML**.

Three rules in there are load-bearing and easy to get wrong:

* `-keepattributes InnerClasses` **requires** `EnclosingMethod` in the same directive, or R8
  refuses the build outright (`Attribute InnerClasses requires EnclosingMethod attribute`);
* `-keepnames class damjay.control.ghosthand.**` protects the classes the platform looks up
  by name (`android:name=".HostActivity"`, the service, saved-state keys);
* the `InjectionAccessibilityService` keep pair - without it R8 deletes the entire touch
  feature from the release APK while the debug APK keeps working. That story is told in full
  under [the keep rule that saved the release build](#the-keep-rule-that-saved-the-release-build-a-genuinely-nasty-one),
  and it is now enforced by a check rather than by vigilance.

The published APK is verified structurally after shrinking, in two ways: `apktool` decodes it
back to smali and resources to confirm the components are there **under their original names**,
and `verify_apk.py` asserts the classes, the framework call strings and the accessibility
resource are still in the artifact (`build.sh` runs it; `publish-apk.sh` refuses to publish
without it).

---

## The map: which file does what

```
app/src/main/java/damjay/control/ghosthand/
├── MainActivity.java            pick a role; the launcher activity
├── HostActivity.java            host dashboard: permission flow, stats, touch switch
├── GuestActivity.java           guest screen: discovery, video surface, touch capture
│
├── net/                         the wire protocol - NO android.* imports, unit-tested
│   ├── GhostProtocol.java       constants + sizing maths (16-byte header, port, fit)
│   ├── Frame.java               one parsed message (type, flags, pts, payload)
│   ├── Record.java              hand-rolled TLV key/value payload bag
│   └── FrameCodec.java          Frame <-> bytes, streaming and blocking
│
├── host/                        everything that runs on the phone being watched
│   ├── ScreenCaptureService.java  foreground service; owns projection, display, hub
│   ├── ScreenEncoder.java         MediaCodec H.264 encoder fed by a Surface
│   ├── ClientHub.java             TCP server; one ClientConnection per guest
│   ├── ClientConnection.java      per-guest queue + writer thread + reader thread
│   ├── HostController.java        mDNS advertise + "my IP addresses" listing
│   ├── TouchInjector.java         gesture planner: guest points -> one stroke - NO android.*
│   └── InjectionAccessibilityService.java  the only thing allowed to inject input
│                                   (every API-24 type is in its nested Api24 class)
│
├── SplashActivity.java            the launcher entry point: two taps, then the app
├── SplashView.java                draws the tap animation (gradient, glass, ripples, hand)
│
├── util/
│   ├── ApiLevels.java             which role each Android version can run - NO android.*
│   ├── CodecCompat.java           the one place MediaCodec's buffer API differs by version
│   └── SplashChoreography.java    the splash timeline as arithmetic - NO android.*
│
└── guest/                       everything that runs on the phone doing the watching
    ├── GuestController.java       mDNS discovery + socket + frame dispatch
    └── VideoDecoder.java          MediaCodec H.264 decoder + frame pacing
```

Read it in this order and the whole system falls out: `net/` (the language the two phones
speak) -> `host/` (one side of the conversation) -> `guest/` (the other side) -> the three
activities (the humans).

### How the pieces are wired

```
 HOST PHONE                                          GUEST PHONE
 ───────────                                         ───────────
 HostActivity
   │ ContextCompat.startForegroundService(ACTION_START, token)
   ▼
 ScreenCaptureService ── MediaProjection ──► VirtualDisplay
   │                                              │ renders into
   │                                              ▼
   │                                         ScreenEncoder
   │                                              │ pushes encoded frames
   │                                              ▼
   │ mDNS advert "_ghosthand._tcp"          ClientHub (ServerSocket :47811)
   │                                              │  one queue per guest
   │                                              ▼
   │                                        ClientConnection.writer ─┐
   │                                                                 │ TCP
   └── (activity listens for ACTION_STATE/ACTION_STATS)              │
                                                                     ▼
                                                          GuestController.reader
                                                            │                │
                                          VIDEO (reader thread)      control frames
                                                            ▼                ▼
                                                     VideoDecoder     GuestActivity
                                                            │           (main thread)
                                                            ▼
                                                     SurfaceView
```

* **Host -> guest** runs one way and continuously: `VIDEO` frames plus occasional
  `VIDEO_CONFIG`, `GEOMETRY`, `STATS`, `PONG`, `BYE`.
* **Guest -> host** carries `HELLO`, `PING` and `TOUCH`.
* The service and the activity never touch each other's objects - commands go in by
  `startForegroundService(intent)`, state comes back by **package-private broadcast**, which
  is why Home-ing out of `HostActivity` does not interrupt the stream.

---

## The wire protocol

Every message is one 16-byte header plus a payload. Big-endian throughout, which is exactly
what `DataInputStream` and `ByteBuffer` do by default.

```
 byte  0        1         2        3        4..11                12..15
      +--------+---------+--------+--------+-------------------+----------------+
      | MAGIC  | VERSION |  TYPE  | FLAGS  | PRESENTATION TIME | PAYLOAD LENGTH |
      |  0x47  |  0x01   |        |        |   int64, µs       |     int32      |
      +--------+---------+--------+--------+-------------------+----------------+
      |                        PAYLOAD (0..8 MiB)                              |
      +------------------------------------------------------------------------+
```

| # | type | direction | payload |
|---|---|---|---|
| 1 | `HELLO` | guest -> host | `Record{device, version, w, h}` |
| 2 | `TOUCH` | guest -> host | `Record{action, x, y, pointer, timeMs}` |
| 3 | `PING` | guest -> host | 8-byte token |
| 4 | `WELCOME` | host -> guest | `Record{device, w, h, fps, version, mode}` |
| 5 | `PONG` | host -> guest | the same token |
| 6 | `VIDEO_CONFIG` | host -> guest | `Record{w, h, csd0, csd1}` - raw SPS/PPS, no start codes |
| 7 | `VIDEO` | host -> guest | one H.264 access unit; `FLAGS` bit 0 = key frame |
| 8 | `GEOMETRY` | host -> guest | `Record{w, h, rotation}` after a rotate/resize |
| 9 | `STATS` | host -> guest | `Record{fps, kbps, dropped, clients, uptimeMs}` |
| 10 | `BYE` | either | UTF-8 reason |
| 11 | `GLOBAL_ACTION` | guest -> host | `Record{action}` - 1 back, 2 home, 3 recents, 4 notification shade: the host's navigation bar as four buttons. Codes **100+** are GhostHand's own commands, outside AccessibilityService's 1..5 (5 there = quick settings) so they can never be handed to `performGlobalAction` by accident: **100** rotate, **101** volume up, **102** volume down, **103** play/pause |
| 12 | `CLIPBOARD_GET` | either | empty payload - "give me your clipboard"; answered with one `CLIPBOARD_SET` |
| 13 | `CLIPBOARD_SET` | either | `Record{text, ok}` - `ok = 0` means "I could not read mine" and must never overwrite the receiver's copy; `text` is UTF-8 capped at 64 KB (`clipText()` truncates on a character boundary) |
| 14 | `HOST_TEXT` | host -> guest | `Record{text}` - a short status line: the answer to a volume/media command ("volume 63%", "play/pause sent", or an honest "play/pause needs Shizuku"). The guest flashes it as a HUD and appends it to the session log |

Design notes that matter:

* **One header for everything.** Video, pings and touches share a socket, so there is one
  connection to lose, one place to detect a dead peer, and no ordering surprises between
  "the picture" and "the finger".
* **`Record` is a hand-rolled TLV bag**, not JSON or Java serialisation: no reflection, no
  class names on the wire, no schema to keep in sync between two APK versions. Unknown keys
  are simply ignored, which is what makes a version skew survivable.
* **PTS is 8 bytes** because `MediaCodec` hands out microseconds as a `long`; truncating to
  4 bytes wraps after ~71 minutes.
* **Framing is strict, not self-resynchronising.** A bad magic byte or a payload length over
  8 MiB marks the stream broken and drops the connection. Hunting for the next `0x47` in an
  arbitrary byte stream is how you decode half a video frame as a touch event.

---

## How the host works

### 1. Permission, then a foreground service

Screen capture is not a normal runtime permission.
`MediaProjectionManager.createScreenCaptureIntent()` shows a system dialog, and the
`resultCode` + `Intent` you get back is a **single-use token for one projection**.
`HostActivity` runs the dialog through an `ActivityResultLauncher` and forwards the token to
the service:

```java
projectionLauncher.launch(manager.createScreenCaptureIntent());
// … on RESULT_OK:
intent.putExtra(ScreenCaptureService.EXTRA_RESULT_DATA, result.getData());
ContextCompat.startForegroundService(this, intent);
```

The capture has to live in a foreground service for two reasons: Android 10+ kills background
apps that hold a projection, and it has to keep streaming when you press Home. Order matters
on Android 14:

```java
startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
projection = manager.getMediaProjection(resultCode, data);   // only now
```

Calling `getMediaProjection` first throws `SecurityException` on API 34+.

### 2. VirtualDisplay -> encoder

```
screen ──► VirtualDisplay ──(input Surface)──► MediaCodec encoder ──► H.264 NAL units
```

A `VirtualDisplay` is the system's own compositor output: everything on the physical screen
is drawn into a `Surface` instead. Hand that Surface to `MediaCodec` as an **input** surface
and the encoder consumes frames without a single pixel crossing into Java heap.

```java
encoder = new ScreenEncoder(w, h, bitrate, 30, this);
encoder.start();
projection.createVirtualDisplay("GhostHand", w, h, densityDpi,
        DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, encoder.getInputSurface(), null, null);
```

* `AUTO_MIRROR` is what makes the system *distrust* secure windows (banking apps draw black).
  The host UI can switch to `PUBLIC` at runtime - the flag is a property of the display, not
  of the encoder, so the stream keeps running either way. Below Android 14 only the
  `VirtualDisplay` is recreated. **Android 14+ grants exactly one capture per consent**: the
  system marks the grant used the moment its first display exists
  (`MediaProjectionManagerService$MediaProjection.isValid()` → `mVirtualDisplayId != -1`,
  permanent - releasing the display does not reset it) and every later `createVirtualDisplay`
  throws `SecurityException`. So on 14+ a mode change re-opens the system confirmation dialog
  and `swapProjection()` puts the fresh grant under the same encoder and the same guest
  sockets - and the rotation path never recreates the display at all, it `resize()`s the
  surviving one and points it at the new encoder surface.
* Sizing goes through `GhostProtocol.fitCaptureSize(w, h, maxSide)`: scale so the longest side
  matches the chosen preset, then round **down to a multiple of 16**. H.264 works in 16x16
  macroblocks, and an odd size gets padded and smears the right and bottom edges.
* Bitrate comes from `suggestedBitrate(w, h, fps)` - roughly 0.1 bit per pixel per frame,
  clamped to 0.8-16 Mbps. 720p30 lands near 2.8 Mbps, which any decent WiFi link carries with
  room to spare.
* Frame rate is a **host-UI choice**: 15 / 20 / 30, defaulting to **20**. Lower fps means
  fewer bits into the same WiFi pipe, so queues drain instead of growing - the honest cure
  for "it lags". `suggestedBitrate()` scales with fps too, so 20 fps also lowers the bitrate
  automatically. Set once per session from the capture settings dropdown (`EXTRA_FPS`).
* The encoder is configured with `KEY_I_FRAME_INTERVAL = 1` (a key frame every second, so
  a guest that connects mid-stream syncs quickly and a dropped frame freezes for at most
  one second - the keyframe interval *is* the glitch clock) and `KEY_LATENCY = 1` (no B-frames, no
  reordering: latency beats compression for interactive use).

### 3. Rotation is a restart, not a resize

Encoders cannot change their output size after `configure()` - the only parameters that can
change live are bitrate, sync-frame requests, suspend and low-latency mode. So when the host
rotates, `onConfigurationChanged` releases the `VirtualDisplay` and the encoder and builds
fresh ones at the new size. The `MediaProjection`, the `ServerSocket` and every guest socket
survive, so the viewer sees a brief pause, then a new `VIDEO_CONFIG` and a key frame - not a
disconnect.

### 4. One queue per guest, and dropping the right thing

`ClientHub` accepts sockets and gives each guest a `ClientConnection` with two threads: a
**reader** (drains `HELLO`/`PING`/`TOUCH`, answers `PING` from the reader itself so latency is
measured without a thread hop) and a **writer** (blocks on a `BlockingQueue`).

The queue is bounded at 120 frames. When a guest's link is slower than 30 fps, the writer
cannot keep up, and something has to give:

* **`VIDEO` frames are dropped** - in fact the hub drops video to make room rather than
  blocking the capture thread, because a mirroring host must never stall the encoder waiting
  for the slowest viewer.
* **Control frames (`VIDEO_CONFIG`, `GEOMETRY`, `STATS`, `PONG`, `BYE`) are never dropped.**
  Losing a `VIDEO_CONFIG` would leave that guest unable to decode anything until the next key
  frame. Losing a `GEOMETRY` would leave it permanently letterboxed wrong.
* The guest has a matching recovery path: when `VideoDecoder` drops a frame it "re-arms" a
  gate and waits for the next IDR before rendering again, so a dropped P-frame can never
  produce a permanently corrupt picture.
* **The network side needed the same gate, and for a while did not have it** - the bug the
  screenshots in `screenshots/` caught during rapid scrolling. The protocol has no sequence
  numbers, so a guest cannot detect that a frame went missing on the way; it just feeds the
  next P-frame to a decoder whose reference picture never arrived, and gets green block
  corruption until the next key frame. `ClientConnection` now runs a `FrameGate`: on any
  drop for a guest (queue overflow, or a control frame evicting a video one) it purges that
  guest's queued video and suppresses every non-key video frame until the next key frame.
  The guest freezes on its last good picture for at most one key-frame interval - the
  glitch clock doing its job - instead of rendering garbage.

---

## How the guest works

### 1. Finding the host

Two ways in, because mDNS does not survive every router (AP isolation, client isolation,
corporate WiFi):

1. **mDNS/NSD.** The host advertises `_ghosthand._tcp.` on port 47811. `GuestController` uses
   `NsdManager.discoverServices`, and resolves hosts through a **serial queue** - NSD refuses
   to run many resolves at once, and a parallel fan-out fails with `FAILURE_ALREADY_ACTIVE` on
   most devices. Results are handed to a `RecyclerView` adapter.
2. **Manual IP.** The host screen shows its addresses (`HostController` enumerates
   `NetworkInterface` IPv4 addresses, preferring site-local 192.168.x.x/10.x.x.x). Type one in
   and connect. This is the fallback that always works when both phones are on the same subnet.

### 2. Decoding

`VideoDecoder` is a two-thread design: a **decoder thread** that blocks in
`dequeueOutputBuffer` and renders with a manually-pinned PTS, and the reader thread that feeds
input buffers. `MediaCodec` is not thread-safe, so only the decoder thread touches it while
the reader thread only ever calls `offerVideo(...)`, which puts the frame into a small
array-deque and returns. Two details that decide whether the picture looks right:

* **The output Surface is only valid between `surfaceCreated` and `surfaceDestroyed`.**
  Rendering into a released surface throws, so the decoder is started and stopped by those
  callbacks, and it needs *both* a live surface and the host's SPS/PPS before it can start at
  all - hence `startDecoderIfNeeded()` on both paths.
* **The decoder renders straight to the Surface.** `releaseOutputBuffer(index, true)` pushes
  the decoded frame to the display; the guest never sees a Bitmap.
* **`csd-0`/`csd-1` are Annex-B, start code and all.** The wire carries bare SPS/PPS NAL
  units (`VIDEO_CONFIG`), but `MediaFormat` gets `00 00 00 01`-prefixed bytes, because
  KitKat's `MediaCodec` feeds `csd-*` **verbatim** into codec-config input buffers with no
  parsing - a start-code-less SPS reaches the decoder as gibberish and the screen shows
  grey (nothing decoded) or green (uninitialized output). `VideoDecoder.withStartCode()`
  re-adds the prefix, idempotently, at `configure()` time.

`GuestActivity` then letterboxes the picture: it sizes `videoContainer` to the stream's aspect
ratio inside the window and matches the device orientation to the stream's, so a portrait
phone mirrored onto a portrait phone fills the screen exactly. Full-screen mode goes through
`WindowInsetsControllerCompat`, which is also what makes it work on Android 11+, where the old
`SYSTEM_UI_FLAG_*` bits are ignored.

### 3. Latency and liveness

Every 3 seconds the guest sends a `PING` (the host echoes it as `PONG` with the same token),
and the round-trip time is shown in the UI. The socket is set to a 1-second read timeout so
the reader thread wakes up regularly: if **20 seconds** pass with no traffic in either
direction, the guest declares the link dead and closes it, rather than showing a frozen last
frame forever.

### 4. Controls: the three-state bar, navigation, media and the clipboard bridge

While connected the guest shows a **three-state control bar** - the pure rules
(state walk, per-state selections, dock modes, volume maths) live in
`ControlsConfig` so they can be unit-tested without a device:

* **Unexpanded** - only a small "▲" handle in the corner; nothing else covers
  the picture. Tap it to open the one-line row.
* **One line** - the buttons chosen for the one-line row, between "×" (fold
  away) and "▲" (expand to full). One row, always.
* **Full buttons** - every button chosen for the expanded panel, wrapping into
  rows, plus the structural row: "▼" (back to one line), *Settings*, *Full
  screen*.

Both visible states independently choose how they meet the video: **float**
(the draggable pill, anywhere over the picture) or **dock** - the bar takes a
strip at the bottom and the letterbox maths shrink the video into what is
left, so the picture genuinely pushes up. The two choices are stored
separately, and the settings page (the *Settings* button in the expanded
panel) is where each one is picked, next to a **checkbox per button per
state**: eleven buttons exist, which subset shows in which row is the user's
call. Everything persists in the `guest_controls` prefs.

Buttons:

* **Back / Home / Recents / Shade** - each sends `GLOBAL_ACTION` with the matching
  `AccessibilityService.GLOBAL_ACTION_*` number; the host's service calls
  `performGlobalAction()`, which exists since API 16 and does **not** need `dispatchGesture`.
  The accessibility service must be granted (the dashboard's "touch control" switch), and
  every ignored press says so in the host log.
* **Rotate** - sends the GhostHand command `GLOBAL_ROTATE = 100`. There is no API that turns
  the display itself and `GLOBAL_ACTION` has no rotate constant, so the service logs the
  request and broadcasts it to `HostActivity`, which flips its own window with
  `setRequestedOrientation(portrait <-> landscape)`. Two honest limits: it only takes effect
  **while GhostHand's window is in front** (it is - only the window showing the stream can
  receive the guest's command at all), and it overrides the system rotation lock for that
  window only, which is why the in-app "mirror" switch keeps auto-rotation unlocked.
  **With Shizuku granted** the service instead runs `settings put system user_rotation`
  as the shell user: a system-wide flip that works even when GhostHand is backgrounded
  (permission is requested once, at the first rotate, and the user's original
  auto-rotate/lock settings are put back when the session stops). Shizuku needs
  Android 7+ and adb (USB, or Android 11+ wireless debugging) to start - a KitKat
  phone can do neither - so it is never a requirement: every path falls back to the
  window flip. A status row in the host's touch-control card states all of this in
  plain words (not installed / not running / tap Grant / granted) with one button
  that always does the next useful thing - and it means it: the row re-reads
  itself at 1 Hz while the screen is up **and** on Shizuku's own
  binder-received/binder-dead events, so starting Shizuku in another app (or
  over adb) flips it live, every button press appends what it did to the host
  log, and "Grant" answers with either "permission requested - approve the
  dialog" or a reason it could not ask.

  The same grant also unlocks **live touch** (next section). The
  encoder then restarts at the new size (section 3 above), `GEOMETRY` flies out, and the
  guest's panel turns with the host - mid-stream rotation, exactly like the host rotating on
  its own. If the host activity happens to be stopped, the broadcast is missed but the
  service's log line still records the request.
* **To host / From host** (guest) and **To guest / From guest** (host, in the capture
  settings card; both need a live session) - the clipboard bridge. Push = read my clipboard,
  send `CLIPBOARD_SET`, the peer copies it automatically (toast on arrival). Pull = send
  `CLIPBOARD_GET`, the peer answers with its own `CLIPBOARD_SET`. Guards: an empty clipboard
  is never sent, and an `ok = 0` answer never overwrites the local copy - on **Android 10+
  the OS blocks clipboard reads for background apps**, so a pull answered while GhostHand is
  on the other phone fails honestly instead of pasting nothing over what you had. Text is
  capped at 64 KB, truncated on a UTF-8 character boundary so the other phone never sees a
  replacement character at the cut.
* **Compose** - the *Compose* button (guest pill) and *Type & send text...* (host card)
  open a text box prefilled from the local clipboard: edit what you copied, type
  something new, then Send - the peer copies it automatically, same as a push. A real
  edit survives closing the dialog; an untouched prefill does not, so the next copied
  text is never shadowed by a stale draft. Send stays disabled while the box is empty.
* **Move the bar** - while a bar floats, it can be dragged anywhere over the video
  (press and drag on it; the buttons still work, a drag only starts past the system
  touch slop). The spot is stored as screen fractions, so it survives app restarts
  and rotation. A docked bar is pinned by definition and refuses to be dragged.
* **Vol+ / Vol-** - the host applies `AudioManager.adjustStreamVolume` on the music
  stream: only the normal `MODIFY_AUDIO_SETTINGS` permission, so it works on every
  supported host - KitKat included, accessibility off, Shizuku absent. The host
  answers with the real level (`HOST_TEXT`), which the guest flashes as a HUD
  ("volume 63%") and appends to the log: only the host knows the number, so it
  has to say it.
* **Play/Pause** - command 103; the host injects `KEYCODE_MEDIA_PLAY_PAUSE` through
  the Shizuku shell (`input keyevent 85`), because injecting a key needs
  `INJECT_EVENTS` - the shell user's privilege. With the grant the answer is
  "play/pause sent"; without it, "play/pause needs Shizuku - grant it on the
  host". The button always explains itself, never nothing.
* **Full screen** - one tap for a clean view: re-hides any bars an edge swipe
  brought back, folds the bar down to the corner handle, fades the status pill.
  The handle stays, so there is always a way back (expand, then *Windowed*).
* **The status pill fades** - it used to sit on the video for the whole session
  ("the green dot covers the screen"). Now it is fully visible for four seconds
  after connecting (and whenever touched), then fades out completely; a tap on
  it brings it back or sends it away. alpha 0 still receives taps, which is what
  makes the faded state a reveal gesture instead of a dead zone.

---

## The icon and the splash animation

Both come from two drawings that live in `design/`, and everything the app ships is
generated from them by `design/make_assets.py` - so changing the mark means replacing one
PNG and re-running one script, not editing twenty files.

**The icon** is a hand and its reflection either side of a thin glass line: the solid half is
this phone, the translucent half is the screen it appears on. It ships as:

| | |
|---|---|
| `mipmap-*/ic_launcher.webp` | the legacy square icon, 48-192 px - what Android 4.4-7.x uses |
| `mipmap-*/ic_launcher_round.webp` | the same, circle-masked |
| `mipmap-*/ic_launcher_foreground.webp` | the adaptive foreground (API 26+), art inside the 72 dp safe zone |
| `values/ic_launcher_background.xml` | the adaptive background colour, `#00695C` |
| `drawable-*/ic_stat_mirror.png` | the notification silhouette, white on transparency at 24-96 px |

Two details that are worth knowing because they were bugs first. The generated artwork is a
rounded tile on a **white field**, so "the bounding box of everything that is not the
background" finds the four white corners and calls *those* the icon - `flatten_tile()` flood
fills from the corners and swallows the antialiased tile edge, which otherwise becomes a
visible outline the moment the alpha channel is used as a shape. And the notification icon
is derived from the mark's own alpha rather than drawn separately: Android tints a
notification icon and discards its colours, so the only thing that survives is the shape -
and the mark's logic (solid here, ghost there) is already *in* the alpha.

**The splash** is a hand tapping a sheet of glass: down, contact, ripples spread along the
surface, up, pause, again - forever, or until you tap the screen. Two taps' worth is shown
before the role picker appears.

It is drawn, not played back. `SplashChoreography` owns the timeline as plain arithmetic -
when the hand is where, when each ripple is born, how fast it fades - and is unit-tested
without a screen. `SplashView` asks it one question per frame and draws the answer: a
gradient, a glass line bent by a travelling wave, up to three ellipse ripples, a mirror copy
of the hand below the glass, and one small bitmap for the hand itself. One number crosses
between frames (the elapsed time), so the animation cannot drift.

That split paid for itself immediately. `design/splash_preview.py` renders the same loop
off-device, on the same numbers, read out of the Java source - and looking at its filmstrip
is how the hand **tapping upwards through the glass** got caught. `handOffset()` is positive
when the hand is raised, screen Y grows downwards, and the drawing code added instead of
subtracting. On a phone it would have looked like a hand sinking into a screen and then
bouncing up to touch it from below. No unit test would have said a word.

```bash
python3 design/make_assets.py --check   # are the shipped resources up to date?
python3 design/splash_preview.py        # render the loop as a filmstrip
```

## Android 4.4 and the version floors

Supporting a 2013 phone is mostly a story about what *did not exist yet*, and about how
easy it is to ship code that only fails on the device you cannot debug. Four separate
things had to be handled.

### 1. The roles have different floors

| feature | needs | why |
|---|---|---|
| Guest / controller | **API 19** | `MediaCodec` (16), `SurfaceView` (1), `NsdManager` (16), sockets (1). Nothing modern. |
| Host, mirroring | **API 21** | `MediaProjection` arrived in Android 5.0. Before that no app could capture the screen without root. |
| Host, touch injection | **API 24** | `AccessibilityService.dispatchGesture()` arrived in Android 7.0. |

`util/ApiLevels` holds those three numbers and is **pure Java** - it takes the SDK level as
an `int` instead of reading `Build.VERSION.SDK_INT`, so the whole policy is testable on a
plain JVM (`ApiLevelsTest`, six cases across the boundaries 9/19/21/23/24/35). The gates
are then applied in three places: `MainActivity` dims the host card below 21 and explains
itself, `HostActivity` finishes immediately in `onCreate` if it is opened anyway, and
`ScreenCaptureService` re-checks in `onStartCommand` because Android may restart a service
from an old intent. A 4.4 phone is therefore never inside the host code, by policy and at
three independent points.

### 2. The buffer APIs changed in 5.0

```java
codec.getInputBuffer(index)      // API 21+
codec.getInputBuffers()[index]   // API 16-20, deprecated in 21
```

The guest decoder is the one that matters: it runs on the old phone. `util/CodecCompat`
picks the right form from `SDK_INT`, and every call site goes through it. This is the
AndroidX `Api21Impl` pattern - the class deliberately contains a call that does not exist
on API 19, and the `SDK_INT` check guarantees it never executes there - and it is the only
place in the app allowed to do that (see the checker below).

### 3. `dispatchGesture` must not even be *loaded* on old platforms

An `AccessibilityService` is instantiated by the framework, not by us: if the user opens
Settings > Accessibility on a 4.4 phone, the system will construct that class. So every
API-24 mention lives in a nested `Api24` class, which the platform only loads when a
gesture is actually dispatched, and `inject()` returns before that on anything below
Android 7.0. The outer class stays clean and loadable everywhere.

### 4. Dalvik loads exactly one dex file

This one is not about a missing API but about the runtime. Below Android 5.0 the class
loader reads `classes.dex` and ignores every other one - real multi-dex loading arrived
with ART in 5.0. An unshrunk build of this app is **six** dex files (AndroidX is large);
the R8-shrunk release build is **one**. So:

* the **release** APK is a single dex and genuinely runs on 4.4,
* the **debug** APK is six dex files and declares **minSdk 21**, because claiming 19 would
  install on KitKat and then die with `NoClassDefFoundError` the first time it touched
  anything in the second file.

`verify_apk.py` enforces the rule rather than trusting it: it reads the APK's own
`minSdkVersion` back out of the built binary manifest and fails the build if a
`minSdk < 21` APK ships more than one dex file. (R8 and D8 both refuse to emit that
combination anyway - "Cannot fit requested classes in a single dex file" - so the failure
mode is a hard error rather than a silent one. Belt and braces.)

### 5. The libraries have to agree with the floor too

The app is not the only thing with a `minSdkVersion`: every AAR has one, and Gradle merges
all of them into the app's manifest, so a library built for 21 would raise the whole app's
floor. This toolchain has no Gradle and links only the app manifest, so nothing would have
noticed - the APK would keep claiming 4.4 while shipping code that was never tested there.
`toolchain/aar_floor.py` closes that hole: it reads the 46 vendored AAR manifests and fails
the build if any asks for more than `MIN_API`. All 46 declare **14**, so this app's floor is
its own, not inherited.

Related: **v1 (JAR) signing is mandatory below Android 7.0**. The APKs here are signed with
the v2/v3 schemes, which a 4.4 device cannot read at all - it would refuse installation
with `INSTALL_PARSE_FAILED_NO_CERTIFICATES`. `toolchain/lib.sh` switches v1 signing on
automatically whenever `min-api < 24`, so this is handled, but it is the kind of thing that
looks like a corrupt download when you hit it.

### The checks that make this trustworthy

There is no emulator here, so "works on API 19" had to become something checkable. Three
tools do it, and all three are wired into `build.sh`.

**`check_api.py`** reads the constant pool of every compiled class, keeps the references
into `android.*` and `java.*`, and asks a real **API 19 `android.jar`** whether each one
exists. Method and field lookups walk the superclass chain, exactly like the JVM's own
resolution, and a call through one of our subclasses (`service.dispatchGesture(...)`) is
followed into the framework superclass where it actually resolves. The same walk covers
references recorded against **library** types (the shape ECJ emits when a call's static
receiver is an AppCompat widget): the tool reads the library's own class file, and only a
member it *declares* counts as the library's promise - anything it merely inherits from the
framework is walked on and checked against the API 19 jar, because `androidx/` in the
constant pool never proved a method exists below API 21 (vc12's crash: `setButtonTintList`).
Whatever genuinely needs
a newer platform must be *declared* in `api-levels.txt` with the level and the reason - and
an exemption that stops being referenced is reported as stale, so the list cannot quietly
rot.

It found two real bugs the moment it ran:

| found | consequence if shipped |
|---|---|
| `NotificationChannel` (API 26) constructed in `onCreate` with no version guard | every host on **Android 5.0-7.1** crashed the moment it started capturing |
| `InjectionAccessibilityService$1.class`, an anonymous callback left behind by a refactor | stale bytecode in the APK - and the toolchain never cleaned the class directory, so it would have kept happening |

The second one was not an API bug at all, but the tool could see it because the class
extends a type that does not exist below API 24. The fix was in `toolchain/lib.sh`: the
compile step now starts from an empty directory, like javac and AGP do.

**`verify_apk.py`** checks the artifact instead of the source: the classes the framework
looks up by name, the call strings that must survive shrinking, the resources, the dex
count against the declared minSdk - and it understands that aapt2 may *version-qualify* a
resource behind your back (it split the accessibility config into `res/xml/` and
`res/xml-v22/` the moment minSdk dropped below 22, keeping `canPerformGestures` only in the
copy a modern device loads, which is correct and looked like a bug for ten minutes).

The same trick it applies correctly to attributes, though, it applies destructively to
whole vector drawables: with minSdk 19 it moves a vector's API-21 elements (`viewportWidth`,
`fillColor`, `pathData`) into `res/drawable-v21/` and leaves the base file as a gutted
`<vector>`. Android 4.4 loads the base - AppCompat's pre-L `VdcInflateDelegate` fails on it,
the platform fallback has never heard of `<vector>` - and the app dies at launch with
`Resources$NotFoundException` naming the first vector it touched. That shipped as
versionCode 3: 59 of 74 drawable pairs, including this app's own icons, were stripped. The
build now passes `--no-version-vectors` to aapt2 link (the flag's own help text says to use
it "when building with vector drawable support library", which is what we are), and
`verify_apk.py` fails any APK where some `res/<qualifier>/x.xml` variant still contains
`viewportWidth` but the unqualified base does not - so the bug cannot come back silently.

And it checks every component the manifest declares. **R8 never reads
`AndroidManifest.xml`** - it shrinks from the classes it is told about, so an activity or
service that only the framework will instantiate by name looks like an unused class and gets
deleted. The build handles that with `toolchain/manifest_keep.py`, which generates the keep
rules AGP would have generated and passes them to R8 as a second `--pg-conf`; `verify_apk.py`
then re-derives the component list from the manifest and fails if any of them is absent from
the finished dex. Both use the same parser, so they cannot drift apart.

That check exists because its predecessor was a hand-written block in `proguard.pro` that
opened with *"keep them in sync with the manifest."* The splash activity went into the
manifest and not onto the list, R8 deleted it, and the published release APK could not
launch - `ClassNotFoundException` at the first frame. The debug APK was unshrunk and worked
fine, which is how it survived one device before anyone noticed. The lesson is the same one
`api-levels.txt` and `packaging-allowlist.txt` already teach: a list someone must remember to
update is a bug with a delay fuse, so make the list derive from the thing it describes and
fail the build when they disagree.

It also proves the APK is **self-contained**. Every type the dex names under `androidx.*`,
`com.google.*`, `kotlin.*`, `kotlinx.*` or our own package must be defined *in that APK*,
or listed in `packaging-allowlist.txt` with a reason - and an entry that stops suppressing
something fails the build, exactly like a stale `api-levels.txt` entry. That check exists
because the first published build shipped without it and died on the first launch:

| | |
|---|---|
| **the bug** | `AppCompatActivity`'s constructor calls `FragmentActivity`'s, which calls `kotlin.jvm.internal.Intrinsics` - Google compiles much of AndroidX from Kotlin, so the Kotlin runtime is a real dependency. The APK did not contain it. |
| **why the build was green** | `app/proguard.pro` had `-dontwarn kotlin.**` with a comment saying those references were "never called on the paths we use". They were on the very first path. R8 reported the missing class; the rule threw the report away. |
| **the fix** | the real `kotlin-stdlib.jar` (1.9.25, the generation the vendored AndroidX was built with) is now vendored by `toolchain/setup.sh` and linked like any other dependency; the `-dontwarn` line is gone, and the four remaining exception families in `proguard.pro` name the exact method that references each one. |
| **the guard** | the self-containment check above. Pointed at that broken APK it names 48 missing types, `kotlin/jvm/internal/Intrinsics` among them. |

The same audit removed a whole category of risk: `androidx.navigation` (four artifacts),
`androidx.slidingpanelayout` and `androidx.window` were in the harvest but referenced by
nothing in this app - navigation by nothing at all, slidingpanelayout only by navigation,
window only by slidingpanelayout. Dropping them took the number of dangling references from
19 to 2 in the release build and shrank the debug APK by ~1 MB. The two that remain are
declared, with the method that references each.

```
$ bash build.sh --release
    ok  APK VERIFY PASSED  (15 classes, 14 call strings, 5 resources present)
    minSdkVersion 19, 1 dex file(s) - loadable on any supported device
    ok  API CHECK PASSED  (every framework reference exists on API 19; 15 newer symbols
        exempted in api-levels.txt, 36 lambda/desugaring references ignored)
```

**What is still unverified:** how it *feels*. `dispatchGesture` on a real 2013 phone, the
decoder's behaviour on that phone's particular H.264 hardware, and Android 4.4's mDNS
quirks (if discovery finds nothing, type the IP - the manual path exists for exactly
this) are all device questions. The static checks cover the crash class, not the feel.

---

## Touch injection

The guest converts every touch to **normalised** coordinates and sends them; the host turns
them back into a real gesture and hands it to Android. Both halves have a subtlety worth
knowing about.

### The guest half: normalised, not pixels

```java
float nx = event.getX() / (float) view.getWidth();    // 0.0 .. 1.0
controller.sendTouch(0 /*down*/, nx, ny, uptimeMs);   // x10000 on the wire
```

Normalised, not pixels, because the two phones almost never share a resolution and the
letterbox offsets must not leak into the coordinates. `ACTION_MOVE` is throttled (dropped if
the finger moved less than 0.4% of the view, or less than 16 ms has passed): 60 Hz of drag
events would otherwise compete with the video for a WiFi link that is already saturated.

### The host half: `dispatchGesture` needs a permission app code cannot get

Writing into another app's input stream is exactly the thing Android is built to prevent. The
only no-root, no-adb door is an **`AccessibilityService`** with
`android:canPerformGestures="true"`, which can post a `GestureDescription` to the input system:

```java
GestureDescription.StrokeDescription stroke =
        new GestureDescription.StrokeDescription(path, startMs, durationMs);
service.dispatchGesture(new GestureDescription.Builder().addStroke(stroke).build(),
                        callback, null /* handler: dispatch on the calling thread */);
```

That is a big capability, so the user has to switch it on by hand in Settings > Accessibility.
Three things follow from that, and all three are handled in code:

* **The service may not be running.** `InjectionAccessibilityService.isEnabled(context)`
  reads `Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES` - reliable *before* the service has
  even bound - and `HostActivity` re-checks it in `onResume()` so the card is correct the
  moment you come back from Settings. The button deep-links to
  `Settings.ACTION_ACCESSIBILITY_SETTINGS`.
* **The service must be findable from a static context.** The framework instantiates it, so it
  cannot be created by our code; it publishes itself as `static instance()` from
  `onServiceConnected` and clears that in `onUnbind`/`onDestroy`.
* **Nothing may leak across a teardown.** If the guest lifts its finger while the stream is
  dying, a half-finished drag could be injected into whatever app is on top afterwards.
  `stopEverything()` calls `touchInjector.reset()`, which can only produce a `CANCEL`.

Two manifest attributes carry the whole feature and neither is optional:
`android:exported="true"` (the *system* is a different process and has to reach the service)
and `android.permission.BIND_ACCESSIBILITY_SERVICE` (the security boundary - it means only
the system may bind, which is why `exported="true"` is not a hole).

### Streaming with Shizuku: scrolling that follows the finger

`dispatchGesture` cannot stream - a `StrokeDescription` is a *complete* path, and
there is no "extend the running gesture" call - so the no-grant path necessarily
replays a drag when the finger lifts (documented at the top of `TouchInjector`).
The shell user, however, holds `android.permission.INJECT_EVENTS`: with Shizuku
granted, `ShellTouch` parcels each guest event into a `MotionEvent` and calls
`IInputManager.injectInputEvent` as it arrives, through the Shizuku binder, on the
guest's own reader thread (ordered, sub-millisecond per event).

Two version-sensitive details, both pinned by tests or verified:

* The parcel layout matches the platform's generated proxy byte-for-byte
  (`writeInt(1)` + `writeToParcel(event)`, mode `0` = async, reply = `readException`
  + int) - taken from a decompiled AOSP `IInputManager$Stub$Proxy`.
* The **transaction code is positional** in this classic AIDL and moves between
  releases: 5 up to Android 7.1, 8 through 12L, 9 on 13, 12 on 14, 11 on 15/16.
  `InputCodes` holds that table (each value counted from the version's LineageOS
  tag) and answers -1 for anything uncounted - and -1 means *do not guess*: the
  caller falls back to `dispatchGesture` for good. Any refusal, unknown code or
  dead binder sets the same sticky fallback, so the worst case is the behaviour
  we already shipped, never a crash. Guest event timestamps are remapped onto the
  host's clock (monotonically) so VelocityTracker still reads the flick's real
  speed and flings land correctly.

### `TouchInjector`: the part that is pure Java, and therefore testable

Everything above needs a phone. The *decision* of what gesture to send does not, so it lives
in a class that imports no `android.*` at all and is covered by unit tests:

```
DOWN(x0,y0)  MOVE(x1,y1)  MOVE(x2,y2)  UP(x2,y2)
                  |
                  v   TouchInjector.plan()
        Gesture { xs[], ys[], offsetsMs[], durationMs }
                  |
                  v   InjectionAccessibilityService.inject()
        GestureDescription -> dispatchGesture()
```

The rules it enforces, each born from a bug that happened in practice:

| rule | why |
|---|---|
| A **tap is a one-point stroke** held for the real press duration. | `dispatchGesture` has no "click"; a stroke of one point whose length is the press is the only faithful translation. |
| MOVE points closer than **6 px** are merged. | A slow finger emits hundreds of nearly identical points; each one would become a `Path` segment and a slop-sensitive jitter. |
| ...but a move under **12 px** does **not** move the tap. | Otherwise a shaky press walks the tap across the screen and its duration collapses to 0. The press **anchor** is tracked separately from the trailing point for exactly this reason. |
| Points are capped at **64** per gesture, evenly sampled. | `dispatchGesture` rejects enormous `Path`s, and a drop is cheaper than a rejection. |
| Duration is clamped to **40 ms .. 30 s**. | Below the floor a stroke is a mis-tap; above the ceiling the input system refuses it. |
| Back / home / recents / shade are **buttons**, not swipes (`GLOBAL_ACTION`, type 11). | A letterboxed video almost never reaches the host screen's true edge, so edge gestures cannot be expressed as touches at all - and `performGlobalAction()` is exact where a synthetic swipe is a guess. It needs the same accessibility grant as touch, but not the API-24 gesture path: the buttons work on hosts as old as the service can bind. |

A drag is dispatched on finger **lift**, not continuously. `dispatchGesture` posts a completed
gesture, so a *live* drag (the host screen following your finger in real time) is not possible
without streaming each segment - which would mean many small gestures and a visible stutter.
This is the honest limitation of the *no-grant* path; the granted path (`ShellTouch`, next
section) streams every event as it arrives, and the UI says which one is active.

### The keep rule that saved the release build (a genuinely nasty one)

The finished feature worked perfectly in the debug APK and did **nothing** in the release APK -
no crash, no error, just a service that reported success and moved nothing. The reason is worth
internalising:

```
R8 cannot see Android.                                    release APK, before the keep rule:
  ...so nothing instantiates the AccessibilityService.     InjectionAccessibilityService:
  ...so its onServiceConnected() looks like dead code.       static instance()   -> always null
  ...so `instance` is provably null at every read.           onServiceConnected  -> DELETED
  ...so every reader, and dispatchGesture() behind it,       dispatchGesture     -> DELETED
     is provably dead and gets deleted.                     displaySize         -> DELETED
```

Every step is locally correct and the *build still succeeds*, which is why this class of bug is
so expensive: the compiler, `apksigner` and a structurally-valid dex all tell you the APK is
fine. The fix is two keep rules in `app/proguard.pro`:

```proguard
-keep class damjay.control.ghosthand.host.InjectionAccessibilityService { *; }
-keep class damjay.control.ghosthand.host.InjectionAccessibilityService$* { *; }
```

The second line matters too: `GestureResultCallback` is an inner class the framework calls back
into, and a keep rule on the outer class does not cover it.

**And then the lesson was turned into a test.** Trusting a keep rule is how this happened in the
first place, so `verify_apk.py` checks the *artifact* on every build - `build.sh` runs it, and
`publish-apk.sh` refuses to publish without it:

```bash
python3 verify_apk.py app/build/app.apk
# ok  APK VERIFY PASSED  (15 classes, 14 call strings, 5 resources present)
```

It asserts three things that a compiler cannot: the framework-facing **classes** are present
under their original names (the manifest looks them up by string), the **call strings** the app
depends on are still in the dex (`dispatchGesture`, `onServiceConnected`, `displaySize`, ...),
and the **resources** survived linking (`canPerformGestures` in the compiled XML, the service
entry in the binary manifest). Deliberately deleting the two keep rules above makes it fail
with exactly the three methods R8 removed - the regression is reproducible and now caught
before anything is signed or shipped.

---

## Tests

`net/`, `host/TouchInjector`, `guest/ControlsConfig` and `util/ApiLevels` deliberately
import nothing from `android.*`, so the wire format, the gesture planner, the control-bar
rules **and the version policy** can be tested on a plain JVM - no device, no emulator:

```bash
bash toolchain/test.sh app --source 8
# JUnit version 4.13.2
# ...............................................................................
# OK (118 tests)
```

What is covered:

* `FrameCodecTest` - round-trip of every header field, negative and large PTS, empty payloads,
  **a frame delivered one byte at a time**, three frames coalesced into a single read, a frame
  split inside the header, foreign bytes on the port, an unsupported version, an absurd payload
  length, truncated input, `reset()`, plus the clipboard frames - an empty `CLIPBOARD_GET`
  and a `CLIPBOARD_SET` carrying a full 64 KB record - arriving byte-perfect.
* `RecordTest` - every value type, nested records, missing keys, wrong-type lookups, full `long`
  range, **byte arrays with embedded zeros and 0xFF** (SPS/PPS are full of both), UTF-8 beyond
  ASCII, truncated blobs.
* `GhostProtocolTest` - sizing maths (16-alignment for any screen/preset combination, aspect
  preservation, no upscaling, encoder minimums), bitrate clamp, and that header size, port,
  service type and type numbers stay sane and distinct (including the new
  `HOST_TEXT`); that `GLOBAL_ROTATE` and the media commands (101-103) sit outside
  AccessibilityService's 1..5 range; and that `clipText()` passes ordinary text through,
  truncates ASCII exactly at the cap, and never splits a multi-byte character (the raw cut
  lands inside a 3-byte `EUR` - the boundary back-off is what keeps U+FFFD off the other
  phone's clipboard).
* `TouchInjectorTest` (23 tests) - tap and drag planning, the slop rules (a sub-12 px wobble
  during a press must **not** move the tap or shorten its duration - a real bug this caught),
  the 40 ms/30 s duration clamps, monotonic non-decreasing offsets, point reduction past 64,
  a MOVE arriving with no DOWN, `reset()` producing a CANCEL, coordinate clamping at the
  screen edges, and a full scroll round trip from one normalised `MOVE` to one stroke.
* `ApiLevelsTest` (6 tests) - the version policy at every boundary: 9 is unsupported, 19
  and 20 are guest-only, 21-23 mirror without being controllable, 24 is the first that does
  everything, 24 through 35 all can.
* `InputCodesTest` (4 tests) - the per-version binder transaction codes for
  `IInputManager.injectInputEvent`, pinned value by value (a wrong number would
  aim our parcel at a different input-service method) plus "unknown versions
  answer -1 instead of guessing".
* `ControlsConfigTest` (6 tests) - the control bar's pure rules: the expand/collapse
  walk (with its floors and ceilings), per-state button selection in canonical order,
  settings CSV round-trips that drop unknown ids and deduplicate, first-run defaults
  where the one-line row must be a subset of the expanded panel, unique registry ids,
  and the HUD's volume percentage (rounded, clamped, and safe against a bogus max).
* `ShizukuWiringTest` (3 tests) - parses `AndroidManifest.xml` and pins the Shizuku
  client identity: the `API_V23` uses-permission (the server's `BinderSender` pushes
  the binder only to packages that request it - miss it and Shizuku is silently,
  permanently dead), the `V3_SUPPORT` meta-data (Shizuku's UI filters on it), and the
  provider entry exactly as the official snippet writes it. Both identity lines come
  from the provider AAR's own manifest, which a classes-only jar cannot carry - the
  test exists because losing them did.
* `FrameGateTest` (5 tests) - the freeze-vs-corruption switch on the host: after a drop
  only the next key frame gets through, control frames always pass, repeated drops stay
  closed, and a dropped key frame cannot "open" the gate by being dropped.
* `SplashChoreographyTest` (10 tests) - the splash timeline, which is arithmetic rather than
  art: the hand descends monotonically and never dips below the glass except during the
  press, every ripple is born after contact and is finished before the hand is back up,
  ripples only ever widen and fade, the newest is always inside the oldest, the loop is
  seamless by construction (`t` and `t + LOOP_MS` produce identical frames), and the
  travelling wave is still before the tap and quiet at the far edge.

**What cannot be tested here:** anything that needs the Android runtime (ART) - and that now
includes `dispatchGesture` itself. There is no emulator in this environment, so
`MediaProjection`, `MediaCodec`, `dispatchGesture`, the activities and the AndroidX widgets are
verified by compilation, dexing (D8 and R8 both accept the bytecode, R8 with the keep rules
above), and structurally: `apktool` decodes the APK back to smali and resources, `verify_apk.py`
asserts the injection classes and call strings survived shrinking, and every
`findViewById(R.id.x)` is cross-checked against the layouts. On-device behaviour still needs two
phones.

---

## Troubleshooting

| symptom | cause |
|---|---|
| Guest list is empty | mDNS blocked (AP isolation) - type the IP shown on the host instead. Both phones must be on the *same* network, and "guest WiFi" networks usually isolate clients from each other. |
| "that does not look like an IP address" | the guest needs `192.168.x.x`, not a hostname. |
| Black screen in a secure app | expected: `AUTO_MIRROR` is distrusted by the system for banking/DRM windows. Switch the host to `PUBLIC` mode. On Android 14+ the system asks you to confirm screen capture once more when the mode changes mid-session - that is the OS's one-capture-per-consent rule, not a malfunction. |
| Picture freezes and then recovers | the decoder dropped a frame and is waiting for the next key frame (2 s). `dropped` in the guest's stats tells you it happened. |
| Guest screen is grey or green, but touch works | the decoder never got the SPS/PPS in a form it can parse: `MediaFormat` csd must be Annex-B (start-code prefixed) - see the decoder notes above. Was vc6 (0.2.5). Green = uninitialized output buffers being rendered; grey = nothing decoded at all. |
| `INSTALL_PARSE_FAILED_NO_CERTIFICATES` on an old phone | the APK has no v1 (JAR) signature, which is all Android 6.0 and older understand. `toolchain/lib.sh` enables it automatically when `min-api < 24`; a build made with a higher `--min-api` will not install there. |
| `ClassNotFoundException` for one of your own activities at launch | the release build shrank away a class the manifest declares. The keep rules are generated from the manifest at dex time (`toolchain/manifest_keep.py`) and `verify_apk.py` fails a build missing any component - if you see this, something regenerated one without the other. Debug APK unaffected: it is never shrunk. |
| The launcher icon still shows the green robot | the build is serving a cached resource table - `rm -rf app/build` and rebuild, or the icon resources were replaced without rebuilding. `python3 design/make_assets.py --check` says whether the files on disk match the design. |
| The splash shows glass and ripples but no hand | the hand bitmap was recycled while the animation was still on screen (paused and released are different things - see `SplashView.pause()` / `release()`). Only reproducible by leaving and returning to the splash mid-animation. |
| `INSTALL_FAILED_OLDER_SDK` on Android 4.4 | you are installing the **debug** APK, which declares minSdk 21 (six dex files, and Dalvik loads one). Use the release APK. |
| `NoClassDefFoundError` right after installing | usually the multi-dex trap: a `minSdk < 21` APK with a `classes2.dex` is broken on Dalvik. `verify_apk.py` fails the build for exactly this. |
| Touch does nothing, host is Android 5.0-6.x | `dispatchGesture` needs Android 7.0. The host dashboard says so instead of offering the switch - unless Shizuku is granted, whose live path injects input events directly and works from Android 5.0 up. |
| Scrolling only reacts after I lift my finger | the no-grant path must: `dispatchGesture` takes a complete stroke, not a stream. Grant Shizuku (touch-control card) and touches stream live while you scroll. |
| The Back/Home/Recents/Shade buttons do nothing | the host has not granted the accessibility service - the same "touch control" switch, shown in the host log for every ignored press. |
| The Rotate button does nothing | GhostHand must be the window in front on the host (the command arrives with the stream, so it normally is), and if the activity was stopped the request only shows up in the host log. Rotation lock is overridden only for GhostHand's own window - the in-app mirror switch keeps auto-rotation unlocked for the session. |
| "Clipboard unavailable (Android 10+ blocks background reads)" | the host answered a pull while its window was in the background - that is the OS policy, and GhostHand fails honestly instead of overwriting your copy. Tap "From host"/"From guest" while the other phone has GhostHand open, or use push ("To host"/"To guest"), which always works. |
| The video lags behind the action | lower the host's frame rate (capture settings: 20, or 15 on a bad link). Fewer frames per second into the same pipe = shallower queues = less end-to-end delay. |
| Green blocks / shredded picture while scrolling fast (see `screenshots/`) | was vc8: a network drop left the guest decoding P-frames against a reference it never received. Fixed by the host-side `FrameGate` (freeze up to one key-frame interval instead of corruption). If it returns, check the host's `dropped` counter - and try the 480p preset, because a 2013 guest decoder can also struggle on high-motion 720p. |
| The host's Shizuku row stays on "not running" although Shizuku IS running | was vc9-vc11: the manifest was missing `<uses-permission android:name="moe.shizuku.manager.permission.API_V23"/>`. That name is how the Shizuku server recognises a client at all - its `BinderSender` pushes the binder only to packages that request it, and the push is the single way a client ever gets one. Gradle merges this line from the provider AAR automatically; this toolchain vendors the jar (classes only), so it had to be declared by hand - vc12 does, plus the `V3_SUPPORT` meta-data that puts the app in Shizuku's own lists, both pinned by `ShizukuWiringTest`. **Install the vc12 APK (an update is enough) and the row goes live.** |
| The host's Shizuku row did not change after I started Shizuku | the refresh side (vc11): the row re-reads at 1 Hz and on Shizuku's binder-received/binder-dead events, every button press logs its outcome, and Grant answers "permission requested" or why it could not ask. If the row never leaves "not running", see the row above - that is the delivery, not the refresh. |
| The guest's Settings page is unreadable (dark text on dark) | was vc11: the panel hard-coded a translucent black background while the text came from the light theme - and KitKat has no dark-mode switch at all, so it is permanently in the light scheme. vc12 gives the panel the themed surface colour (white in light mode) and pins the pill surfaces (status, control bar, HUD) to a constant light `pill_text`, because the pills are dark in BOTH schemes. |
| The docked bar floats above the bottom of the screen | was vc11: the floating bar's 10dp layout margin survived the dock, so the reserved strip included a 10dp gap under the bar. Docking now zeroes the margins (and float mode puts them back). |
| Opening settings force-closes the guest (vc12: `NoSuchMethodError: setButtonTintList`) | vc12 tinted the choice rows with `setButtonTintList`, a framework API that first appears in API 21. It compiled happily (the android.jar is API 34) and only exploded at runtime on KitKat, because the static receiver type was the AppCompat widget - which made the reference look like an androidx one that "cannot" fail, and the API checker trusted that shape blindly. vc13 tints through `setSupportButtonTintList` (declared by AppCompat itself, so it exists on every API), and `check_api` now parses the library class file and follows such references down to their real declaring class, validating framework members against `android-19.jar`. **Install vc13.** |
| "Dock below the video" leaves the bar ON the picture with an empty strip below it (vc13) | FrameLayout pins a gravity=bottom child to the INSIDE of its padding box, so reserving the bar's height as root padding shrunk the video while the bar stayed in the content box - drawn over the picture's bottom edge with the whole strip empty underneath (and any inset dispatch wiped the padding outright). vc14 reserves the band in the letterbox math itself: the video's available height stops above the bar's measured height and top-anchors when docked, while the bar keeps gravity BOTTOM on a padding-free root - picture on top, bar filling exactly its own height below it. |
| The settings radio highlights the OTHER option when I pick one (vc13) | `RadioGroup` excludes its siblings through a listener dance (addView hook, `CheckedStateTracker`, `setCheckedId`) that is keyed on ids and attachment order; the panel builds its radios programmatically, and on the field build the DOT landed on the option you did not tap while the SAVED value was the one you did. vc14 drops the group: two plain radio buttons whose checked state the code writes from the field after every tap - one source of truth, no platform dance. |
| Swipes only take effect after I lift my finger, although Shizuku is granted | the streaming path (raw `injectInputEvent` per move) picks its binder transaction code per SDK - and the same SDK has DIFFERENT codes on stock AOSP and LineageOS. The table carried the Lineage-21 count (12) for API 34, where stock Android 14 has 10; on a stock host the parcel landed on `verifyInputEvent`, the call "succeeded", and streaming was silently dead while every swipe fell back to lift-off replay. vc14 tries stock first (Lineage first on Lineage builds), remembers the code that works, and the host log now says `live touch ON (inject code N)` - or `live touch OFF - <reason>` instead of silence. The log also auto-scrolls. |
| Pinch-to-zoom does nothing / two fingers never reach the host | was a single-finger protocol ("multi-touch is a later milestone"). vc14 carries both fingers: wire actions 4/5/6 (both-down / both-move / multi-ended) with the second pointer's normalised coordinates. The live path injects a two-slot `MotionEvent` as your fingers move; the no-grant path replays them as two concurrent strokes of one `dispatchGesture` gesture at lift-off. **Both phones must run vc14+** - an older host ignores the new actions (safe, just no zoom), an older guest never sends them. |
| Rotate has never done anything | two bugs, both fixed: (1) Shizuku never worked (row above), so the system-wide path was unreachable and the fallback only flips GhostHand's OWN window - invisible while the host mirrors another app; (2) the first permission ask was gated "once ever", and asking while the binder was missing was a silent no-op that disabled the dialog for good. vc12 re-asks every 30 s and the guest now gets an honest `HOST_TEXT` answer for every outcome: "rotated system-wide", "approve Shizuku on the host", or "only rotates GhostHand's own window". |
| Play/Pause does nothing | it needs Shizuku: injecting a media key is shell work (`INJECT_EVENTS`). The host answers the press either way - "play/pause sent" or "needs Shizuku". Volume needs nothing of the sort: it is an `AudioManager` call and always works. |
| Volume buttons do nothing on the host | the media stream may already be at its end (the HUD shows the level the host reports). If the HUD never appears, the session is not live - check the guest log for the `HOST_TEXT` answer. |
| Guest Rotate does nothing while another app is in front | expected without Shizuku: the window-level flip only works with GhostHand in front. On Android 7+, install Shizuku, start it (wireless debugging on Android 11+, else USB adb - KitKat cannot run Shizuku at all), and grant the dialog GhostHand shows on the first rotate: rotation then becomes system-wide. |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | you are installing an APK signed with a different key. Every build here uses `keystore/damjay_debug.keystore`; delete the old app once and carry on. |
| Notification missing on Android 13+ | `POST_NOTIFICATIONS` was denied. The stream still works; only the notification is hidden. |
| `LambdaMetafactory cannot be resolved` | `toolchain/vendor/core-lambda-stubs.jar` is missing - re-run `bash toolchain/setup.sh`. |
| `no AARs found` / AndroidX errors | re-run `bash toolchain/androidx.sh` (it needs GitHub reachable for the ~11 MB blobless clone). |
| Dragging on the guest does nothing, host log shows touches arriving | the accessibility service is off. Host dashboard > **Touch control** > *Open settings* > enable "GhostHand touch control". |
| Touch worked in the debug APK, not the release one | R8 deleted the injection path - the `InjectionAccessibilityService` keep pair is missing from `app/proguard.pro`. `python3 verify_apk.py` catches this in one second. |
| R8 fails with an `InnerClasses`/`EnclosingMethod` message | `app/proguard.pro` lost that pair from `-keepattributes`; they must stay together. |
| Release build crashes on launch with `ClassNotFoundException` | a manifest component was shrunk or renamed: check the `-keep` lines at the top of `app/proguard.pro`. |

---

## Repository layout

```
app/                        the Android application
  src/main/AndroidManifest.xml
  src/main/java/...         4 packages: net, host, guest + 3 activities
  src/main/res/             layouts (Material 3), drawables, values + values-night
  src/main/res/xml/         accessibility_service_config.xml (canPerformGestures=true)
  src/test/java/...         JUnit tests for the wire protocol + the gesture planner
  proguard.pro              keep rules for the R8 release build (no AGP to generate them)
toolchain/                  the Android build system (no SDK, no Gradle) - see its README
keystore/                   the stable debug key every build is signed with
gradle.properties           signing credentials (single source of truth)
build.sh                    one command: setup -> AndroidX -> tests -> signed APK -> verify it
verify_apk.py               assert R8 kept the classes/calls/resources the app needs
check_api.py                assert every framework call exists on minSdk (API 19)
api-levels.txt              the declared exemptions, each with a level and a reason
packaging-allowlist.txt     classes the APK references and does not contain, with reasons
                            (manifest components are NOT listed anywhere by hand - they are
                            generated from AndroidManifest.xml by manifest_keep.py)
design/                     the icon and splash artwork, and the scripts that cut it up
  variant-b1-half-hand-mirror.png   the launcher mark (source of truth)
  splash-hand.png                   the splash hand, black on white for clean keying
  make_assets.py                    generates every icon/splash resource from those two
  splash_preview.py                 renders the splash loop off-device, as a filmstrip
publish-apk.sh              push the APK to the single-commit `apk` branch
RECIPE.md                   how the SDK-less toolchain was assembled, and what fails
sample/                     toy framework-only project used as a toolchain smoke test
sample-androidx/            toy AndroidX project: AppCompat + Material 3 + RecyclerView
```

## Roadmap

1. **Mirroring** - done, from Android 5.0 on the host side.
2. **Controller support down to Android 4.4** - done: the guest half uses nothing newer
   than API 19, and `check_api.py` proves it holds (no exemptions are attributed to
   `guest/*` or `net/*`). Hosting is 5.0+, injection is 7.0+, and the UI says so.
3. **Touch injection** - done: single-finger taps and drags through
   `AccessibilityService.dispatchGesture()`. A drag is dispatched on lift (see
   [Touch injection](#touch-injection)); live streaming of a drag needs a root or adb helper.
4. **Multi-touch, pressure and hardware keys** - the `TOUCH` record already reserves a
   `pointer` field, and `GestureDescription` supports several strokes at once, so pinch/zoom is
   a `TouchInjector` change plus a guest-side pointer-id map.
5. **Audio** - `AudioPlaybackCapture` on the host (API 29+), `AudioTrack` on the guest, same
   `ClientHub` fan-out.
6. **On-device verification** - there is no emulator in this environment, so the pieces only a
   real phone can settle are still open: how a `dispatchGesture` drag feels, whether a 2013
   decoder likes the stream we produce, and 4.4's flaky mDNS.
7. **Hardening** - the protocol is plaintext and unauthenticated on a trusted LAN; a pairing
   step and TLS would be the next step before this is used anywhere else. Touch injection
   raises the stakes: an unauthenticated guest can now drive the host.
