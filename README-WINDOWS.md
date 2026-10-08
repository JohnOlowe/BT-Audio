# The GUI app - BTAudioSender.exe (use this one)

`BTAudioSender.exe` is the same engine as the PowerShell script, but it fixes the
thing that made every buffer preset skip, and it has the knobs the script lacks.
It is a plain .NET Framework 4.8 WinForms program: no installer, no runtime
download (Windows 10 already has 4.8), no DLLs beside it. Double-click it.

## Why the script skipped even at "Very tolerant"

The phone allocates a buffer of `chunkMs x preset` - 320 ms at Very tolerant with
20 ms chunks - but the app calls `play()` on an **empty** buffer, and the script
once it had sent every chunk the PC produced. Nothing ever filled that buffer, so
the phone had nothing to ride out a hiccup with, and a hiccup becomes a skip
regardless of which preset is chosen. That is why the setting seemed to do
nothing.

The new app fills it, in three ways the script does not:

1. **Prebuffer.** It holds back the first `PrebufferMs` of audio and then sends it
   as one burst. The phone now permanently holds about that much audio, and that
   depth is what absorbs link jitter and CPU hiccups.
2. **Silence fill on the device's clock.** WASAPI hands over *nothing* while the
   PC is quiet - there is no silence packet - so a naive sender goes quiet too and
   the phone drains. The app reads the endpoint's own stream position and makes up
   any gap with silence, so the phone's buffer keeps draining against a moving
   timeline and the next sound does not skip. (It asks the *device*, not the wall
   clock: using the wall clock treats any hiccup in the sender as a gap and
   splices silence into the middle of real audio. The test suite catches exactly
   that mistake.)
3. **Prebuffer above the phone's capacity is clamped.** Past `chunkMs x preset`
   the phone's own `write()` blocks, which stalls the link instead of absorbing
   anything, so the app refuses to ask for more.

Start with **Balanced (recommended)**: 44.1 kHz stereo ADPCM, 20 ms chunks,
260 ms prebuffer. If it still skips, use **Robust** (22.05 kHz mono, 88 kbit/s) -
that is roughly a quarter of the traffic. If it *still* skips, turn on
**Auto quality** and let it walk down on its own.

## The window, top to bottom

| Control | What it is for |
|---|---|
| **Phone port** | The outgoing Bluetooth COM port for the phone ("Standard Serial over Bluetooth link"). Refresh after pairing. |
| **Laptop output** | Which render device to tap. Leave on "(system default)", or pick a virtual cable - see below. |
| **WAV file** | Optional. With a path here the app plays that file to the phone instead of tapping the laptop. |
| **Preset** | Balanced / Robust / Maximum stability / Low latency / Studio PCM. Fills in the controls below. |
| **Prebuffer ms** | The single most important knob. Audio held in the phone. Higher = fewer skips, more delay. Must stay under the phone's capacity, which the app shows you. |
| **Auto quality** | Watches how long each write takes. A blocking write means the phone stopped draining, so it steps the bitrate down and reconnects - 44.1k stereo to 44.1k mono to 32k to 22.05k to 16k mono. |
| **Silence the laptop** | See below. |
| **Latency panel** | The number to type into your video player. See below. |
| **Live** | Wire bitrate, chunks, how much the sender is holding, and how long each write takes. "Link is struggling" means auto quality is about to act. |

## Silencing the laptop while it plays

A loopback tap is passive: the audio still comes out of the laptop's speakers.

* **Setting the volume to zero** (the first option) usually keeps the capture
  alive, because the digital tap sits *ahead* of the volume control on most
  drivers.
* **Muting the device** (the second option) also silences the capture on some
  drivers - notably Realtek with Microsoft's generic driver - which would send
  silence to the phone.

You do not have to guess: the app watches the capture level. If audio was clearly
flowing and then goes silent after the mute, it undoes the mute, says so, and
tells you to use a cable instead. It also reports whether the driver does volume
in hardware, which is the case where the tap tends to die.

**The bulletproof answer is a virtual cable** (VB-CABLE, free). Install it, set it
as the default playback device, and pick "CABLE Input" in **Laptop output**. Then
Windows sends everything to the cable, the phone gets it, and the real speakers
never see it at all. The same trick keeps a meeting's audio off your speakers
while your phone carries it.

## Latency: the number to put in your player

`Total = PrebufferMs + ChunkMs/2 + 25 ms (laptop to phone) + headphones`

The 25 ms covers the WASAPI packet, RFCOMM and the phone's decode. The headphone
term is whatever sits between the phone and your ears: 0 ms wired, roughly 90 ms
for aptX, 160 ms for AAC, 200 ms for SBC, 250 ms for LDAC. The app computes the
sum and has a **Copy this number** button.

For the default preset with wired headphones that is about **295 ms**; with SBC
Bluetooth headphones about **495 ms**. Put that figure into the player's audio
delay (or LagSync). It is a constant, not something that drifts: the prebuffer
fix is what makes it constant, because the phone's queue no longer drains and
refills behind your back.

If you would rather trade delay for stability, raise `PrebufferMs` - each extra
100 ms is 100 ms more delay and 100 ms more resilience. The phone's capacity at
the chosen preset is the hard ceiling and the app will not let you pass it.

## Verified how

`btaudio/windows/pscheck.sh` and `pscheck/guicheck.sh` compile this app, then run the
*same engine* on Linux over a virtual serial port and decode the bytes with the
very same `Proto`/`Adpcm` classes that ship inside the APK. PCM has to come back
bit-exact, ADPCM within 1%, the ladder has to walk down under induced congestion -
and every one of those tests has caught a real bug, which is why they exist.

# BT Audio In — Windows side

Laptop audio on your Android phone over **Bluetooth only**. No Wi-Fi, no router,
no internet, no USB cable, and — importantly — **no network at all**, so nothing
here can ever touch your mobile data. The phone is not a hotspot and not a PAN
access point; it is a Bluetooth *serial device*, the same category as a
keyboard or a barcode scanner. Windows gives it a COM port and the sender writes
bytes into it.

Nothing in this document shares, bridges, or tunnels an internet connection.

## What you need

| | |
|---|---|
| Windows | 10 (1703+) or 11, with working Bluetooth |
| PowerShell | 5.1, which ships with Windows — no install |
| Phone | Android 7.0+ (the APK declares minSdk 24), Bluetooth on |
| APK | `btaudio/build/btaudio.apk` (release) or `btaudio/build/btaudio-debug.apk` (debug) |

The APK is signed with the project's stable key, so a new build installs *over*
an old one instead of failing with a signature mismatch.

Install the release build with `adb install -r btaudio/build/btaudio.apk`, or copy that
APK to the phone and open it.

## One-time setup

1. **Pair.** On the phone, open BT Audio In and tap *Make discoverable*. On
   Windows, pair with the phone from Bluetooth settings.

2. **Start the listener.** On the phone, tap *Start listening*. Grant the
   Bluetooth permission it asks for. The notification stays up while it
   listens.

   The listener **must already be running** for the next step. Windows finds the
   port by sending an SDP query to the phone; a service that is not open cannot
   be listed. This ordering is the single most common failure.

3. **Create the COM port.** On Windows:
   *Settings → Devices → Bluetooth & other devices → More Bluetooth options →
   COM Ports tab → Add → Outgoing*.
   Pick the phone, then pick the service named **PC Audio In**. Windows will
   show you a COM number — write it down. This is a one-time mapping; the port
   persists across reboots and reconnects.

   (Older builds: *Control Panel → Hardware and Sound → Devices and Printers*,
   right-click the phone, *Properties → Services*, tick *PC Audio In*.)

4. **Send.**

   ```
   .\bt-audio-send.bat COM8
   ```

   Whatever the PC is playing now comes out of the phone. Ctrl+C to stop.

   The `.bat` is a thin wrapper that exists only because Windows ships
   PowerShell with `ExecutionPolicy=Restricted`, which refuses to run *any*
   `.ps1` file; the wrapper passes `-ExecutionPolicy Bypass` for that one
   process, changing nothing system-wide. If you prefer calling the script
   directly:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\bt-audio-send.ps1 -Port COM8
   ```

   or, once per user, permanently and without admin rights:

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

## Validating the link before trusting it

Send a WAV first. This exercises the whole path — serial port, framing, codec,
AudioTrack — without depending on your capture device:

```powershell
.\bt-audio-send.ps1 -Port COM7 -Mode File -File some-song.wav
```

If the WAV plays correctly but loopback does not, the problem is WASAPI capture,
not the Bluetooth link.

## Knobs

| Flag | Default | Use it when |
|---|---|---|
| `-Codec Adpcm\|Pcm` | Adpcm | Pcm (~1.4 Mbit/s) only to rule the codec out; it usually exceeds what RFCOMM sustains |
| `-Channels 1\|2` | 2 | Mono halves the bitrate |
| `-Rate` | 44100 | 22050 halves it again |
| `-ChunkMs` | 20 | Lower = less delay, more overhead. Rounded up to a whole number of 4 frames, which is what keeps mono ADPCM legal on the wire |

Bitrates: ADPCM stereo 44.1 k ≈ **353 kbit/s**; ADPCM mono 44.1 k ≈ 176 kbit/s;
ADPCM stereo 22.05 k ≈ 176 kbit/s. Real RFCOMM throughput is typically
0.7–1.5 Mbit/s, so ADPCM stereo 44.1 k has headroom and raw PCM usually does
not.

On the phone, the *Buffer* setting trades latency against dropouts: raise it if
the app log shows `link stalls`, lower it if the delay bothers you.

## What latency to expect

Roughly 150–400 ms end to end (20 ms chunk + Bluetooth scheduling + the phone's
playback buffer). Fine for music, video and calls-in-progress; not fine for
twitch gaming or playing an instrument along with the PC.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| COM port missing from the list | Listener not running when you queried. Start it on the phone, then look again. |
| `Could not open COM7` | Another program holds the port, or the phone app is not listening. Close the other program; restart the listener. |
| Chunks send, silence on phone | Phone log says `bad magic` → something other than this sender connected. Says `Closed before sending a handshake` → the port opened but the sender died early; re-run and read its error. |
| Audio is noise | Codec divergence between sender and app. Run the Android unit tests (`bash toolchain/test.sh btaudio`); they pin the tables on both ends. |
| Stutters, app log shows stalls | Link is saturated: `-Channels 1` or `-Rate 22050`, or raise the phone's Buffer setting. |
| `GetDefaultAudioEndpoint failed` | No default playback device is set on Windows. Set one in Sound settings. |
| `Initialize(loopback) failed: 0x88890008` | Another loopback capture is running (some recording tools). Close it. |
| Audio plays from phone speaker, not headphones | Expected: output follows the phone's normal routing. Plug headphones into the phone. |
| `No such WAV file: ...` | Only with `-Mode File`. Check the path; quoted paths with spaces work. |
| `Write to COM8 timed out - the phone stopped taking data.` | The phone stopped reading: BT Audio In was closed, or the Bluetooth link dropped. Restart listening on the phone, then run the sender again. |
| `Could not open COM8: Access to the port ... is denied.` | Something else holds the port - a second copy of the sender, or a terminal program. Close it. If it persists, remove and re-add the outgoing COM port in Bluetooth settings. |
| Port vanishes after sleep | Bluetooth power management. Device Manager → Bluetooth adapter → Power Management → untick *Allow the computer to turn off this device*. |

## If you want the phone's in-app log

The app keeps the last 60 events and *Copy log* puts them on the clipboard. When
something goes wrong, that text is worth more than any amount of guessing: it
names the stage that failed (accept, handshake, format, track, stall) rather
than leaving you with silence.

## How this is verified without a Windows machine

The harnesses live in `btaudio/windows/` (with GUI integration helpers in
`pscheck/`) and run on Linux. They exist because the layers fail differently,
and only the last one can catch what a user hears.

| File | What it proves |
|---|---|
| `btaudio/windows/cscheck.sh [script]` | Lifts the C# out of the `Add-Type` here-string and compiles it with Roslyn against the **real .NET Framework 4.8 reference assemblies** at `/langversion:5` - the exact compiler Windows PowerShell 5.1 uses. Catches `CS0031`, `CS0199`, and any C# 6+ syntax that 5.1 would reject. |
| `btaudio/windows/mkstub.py TARGET OUT` | Writes a copy of the sender with the WASAPI class replaced by one that reads a WAV and hands it out 10 ms at a time, so the **streaming** branch can be exercised off Windows. |
| `btaudio/windows/pscheck.sh [script] [test]` | Runs everything: `cscheck.sh`, a real PowerShell parse, then 15 test groups that execute the script for real over a `socat` pty pair standing in for the Bluetooth COM port. The bytes are decoded by the *same* `Proto`/`Adpcm` classes that ship in the APK, then compared against the WAV that was fed in. |

What `pscheck.sh` covers:

* **`-Mode File`** - ADPCM and PCM, mono and stereo, a stereo-to-mono downmix, an
  upsampling path, and a deliberately awkward 15 ms chunk size.
* **`-Mode Loopback`** - the streaming path, against the stubbed WASAPI class:
  stereo PCM, stereo ADPCM, mono downmix, and a 44.1 kHz to 22.05 kHz
  downsample.
* **Negative cases** - a missing WAV and an unopenable port must both exit
  non-zero with a readable message and must never leak a raw .NET exception.

PCM must decode **bit-exactly** (it does, including through the streaming path,
which is what proves the fractional resampler cursor and the carry buffers lose
nothing). ADPCM is held to a 2% error ratio and a 2000-count steady-state peak,
with the first 50 ms exempt because IMA ADPCM always climbs from predictor 0 -
that warm-up peaks at frame 6 on both channels of the test signal and is inherent
to the codec, not a defect.

Bootstrap and cleanup are explicit, and the same setup is invoked by the harnesses:

```bash
bash btaudio/windows/prepare-tools.sh ensure
bash btaudio/windows/pscheck.sh
bash pscheck/guicheck.sh
bash btaudio/windows/prepare-tools.sh clean
```

The setup provisions a JRE plus Eclipse ECJ from PyPI/npm when `javac` or a Java
runtime is unavailable; this Java-only route does not fetch Android build tools. It then reuses
.NET SDK 8.0.425 if installed, or downloads the pinned SDK and verifies its SHA-512
before extraction. It fetches the .NET Framework 4.8 reference assemblies and, only
when needed, installs pinned PowerShell 7.4.6 into the external cache. `clean` removes
that cache plus ignored harness outputs, not source or checked-in binaries. `socat` and
`python3` must already be present.

Bugs these harnesses caught that reading the code would not have:

* `New-LeBytes` returned `object[]` of `Int32`; `[Array]::Copy` refuses to narrow
  that into a `byte[]`, which killed the handshake before a single byte reached
  the phone.
* A mono ADPCM chunk at 44.1 kHz / 20 ms is 441 bytes - odd - and the phone's
  `Proto` treats an odd audio payload as a desync and drops the stream. Fixed by
  rounding the chunk up to a multiple of 4 frames.
* `Conv.Resample` mapped mono output to source channel 0, so `-Channels 1` - the
  setting recommended whenever the link saturates - silently discarded the right
  channel instead of mixing. It now averages.
