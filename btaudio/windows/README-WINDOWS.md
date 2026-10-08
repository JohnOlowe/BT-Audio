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
| APK | `btaudio.apk` (release) or `btaudio-debug.apk` (unshrunk fallback) |

The APK is signed with the project's stable key, so a new build installs *over*
an old one instead of failing with a signature mismatch.

Install it however you like: `adb install btaudio.apk`, or copy the file to the
phone and open it.

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

Three harnesses live next to the script and run on Linux. They exist because the
layers fail differently, and only the last one can catch what a user hears.

| File | What it proves |
|---|---|
| `cscheck.sh [script]` | Lifts the C# out of the `Add-Type` here-string and compiles it with Roslyn against the **real .NET Framework 4.8 reference assemblies** at `/langversion:5` - the exact compiler Windows PowerShell 5.1 uses. Catches `CS0031`, `CS0199`, and any C# 6+ syntax that 5.1 would reject. |
| `mkstub.py TARGET OUT` | Writes a copy of the sender with the WASAPI class replaced by one that reads a WAV and hands it out 10 ms at a time, so the **streaming** branch can be exercised off Windows. |
| `pscheck.sh [script] [test]` | Runs everything: `cscheck.sh`, a real PowerShell parse, then 15 test groups that execute the script for real over a `socat` pty pair standing in for the Bluetooth COM port. The bytes are decoded by the *same* `Proto`/`Adpcm` classes that ship in the APK, then compared against the WAV that was fed in. |

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

Setup is self-healing - `cscheck.sh` re-fetches the SDK and reference assemblies
(URLs in its header) and `pscheck.sh` installs PowerShell 7.4.6 as a pinned
global tool (unpinned installs of that tool are currently broken upstream).
`socat`, `python3` and a JDK must already be present.

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
