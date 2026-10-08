#Requires -Version 5.1
<#
.SYNOPSIS
    Sends this PC's audio (or a WAV file) to an Android phone over a Bluetooth
    RFCOMM serial port, for the "BT Audio In" app.

.DESCRIPTION
    No Wi-Fi, no router, no internet, no cable. The phone is not a network at
    all: it exposes a standard Bluetooth Serial Port Profile service, Windows
    maps it to a COM port, and this script writes a framed audio stream into
    that COM port.

    Wire format (little-endian), matched byte-for-byte by the Android app's
    Proto.java:
      handshake  16 bytes: 'B','T','A','1' | codec | channels | u16 0 | u32 rate | u32 chunkMs
      chunk      8 bytes : type | 0 | u16 0 | u32 length, then `length` payload bytes
    ADPCM payloads are planar: channel 0's nibbles, then channel 1's.

    The IMA ADPCM tables and the encoder's state-update rule are transcribed
    from Adpcm.java and are kept honest by AdpcmTest on the Android side. If
    audio ever sounds wrong, suspect a divergence between the two and run that
    test first.

.PARAMETER Port
    The COM port Windows created for the phone's "PC Audio In" service.
    Find it: Bluetooth settings -> More Bluetooth options -> COM Ports.

.PARAMETER Mode
    Loopback = capture whatever this PC is playing (default).
    File     = stream a WAV file instead; the fastest way to validate the link.

.PARAMETER File
    WAV path, required with -Mode File. 16-bit or float, any rate/channels.

.PARAMETER Codec
    Adpcm (default, ~353 kbit/s at 44.1 kHz stereo) or Pcm (~1.4 Mbit/s, above
    what RFCOMM usually sustains). Use Pcm only to rule the codec out.

.PARAMETER Channels
    2 (default) or 1. Mono halves the bitrate.

.PARAMETER Rate
    Target sample rate, default 44100. 22050 halves the bitrate again.

.PARAMETER ChunkMs
    Milliseconds of audio per chunk, default 20. Smaller = lower latency and
    more per-chunk overhead.

.EXAMPLE
    .\bt-audio-send.ps1 -Port COM7
    .\bt-audio-send.ps1 -Port COM7 -Mode File -File test.wav
    .\bt-audio-send.ps1 -Port COM7 -Channels 1 -Rate 22050
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [ValidateSet('Loopback', 'File')][string]$Mode = 'Loopback',
    [string]$File = '',
    [ValidateSet('Adpcm', 'Pcm')][string]$Codec = 'Adpcm',
    [ValidateSet(1, 2)][int]$Channels = 2,
    [ValidateSet(8000, 16000, 22050, 32000, 44100, 48000)][int]$Rate = 44100,
    [int]$ChunkMs = 20
)

$ErrorActionPreference = 'Stop'

# SerialPort resolution differs between the two PowerShells, and getting this
# wrong is a hard stop before anything else runs:
#   Windows PowerShell 5.1  - SerialPort is inside System.dll, which is already
#                             loaded; there is NO assembly called System.IO.Ports
#                             and asking for one fails with ASSEMBLY_NOT_FOUND.
#   PowerShell 7+         - it moved out into its own System.IO.Ports assembly.
# So: use the type if it already resolves, load the assembly only if it does
# not, and say so plainly if neither works.
if (-not ('System.IO.Ports.SerialPort' -as [type])) {
    try { # PS 5.1: SerialPort lives in System.dll and is already loaded, so only 7.x
# needs the NuGet System.IO.Ports assembly. Resolve the type first, add the
# assembly only if it is genuinely missing - `Add-Type -AssemblyName
# System.IO.Ports` is a hard error on stock Windows PowerShell 5.1.
if (-not ('System.IO.Ports.SerialPort' -as [type])) {
    Add-Type -AssemblyName System.IO.Ports -ErrorAction Stop
} -ErrorAction Stop } catch { }
}
if (-not ('System.IO.Ports.SerialPort' -as [type])) {
    throw 'System.IO.Ports.SerialPort is unavailable in this PowerShell install.'
}

# The per-sample work is C# because PowerShell is an order of magnitude too slow
# to run a codec loop in real time, and because WASAPI needs real COM interop.
# Everything else stays in PowerShell so the whole sender is one readable file.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace BtAudio {

    // ---- WASAPI ------------------------------------------------------------
    // GUIDs and vtable orders transcribed from NAudio's mirror of the Microsoft
    // headers (audioclient.h, mmdeviceapi.h). C# COM interop binds by POSITION,
    // so a method out of order calls the wrong slot and fails as a random
    // HRESULT. That is why each interface is spelled out in full here.

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, uint stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IntPtr endpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice {
        int Activate(ref Guid id, uint clsCtx, IntPtr activationParams, out IntPtr iface);
        int OpenPropertyStore(uint stgm, out IntPtr props);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out uint state);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioClient {
        int Initialize(int shareMode, int streamFlags, long bufferDuration,
                       long periodicity, IntPtr pFormat, ref Guid sessionGuid);
        int GetBufferSize(out uint bufferSize);
        int GetStreamLatency(out long latency);
        int GetCurrentPadding(out int padding);
        int IsFormatSupported(int shareMode, IntPtr pFormat, out IntPtr closest);
        int GetMixFormat(out IntPtr fmt);
        int GetDevicePeriod(out long def, out long min);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr h);
        int GetService(ref Guid iid, out IntPtr iface);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioCaptureClient {
        int GetBuffer(out IntPtr data, out int frames, out uint flags,
                      out long devPos, out long qpc);
        int ReleaseBuffer(int frames);
        int GetNextPacketSize(out int frames);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WaveFormatEx {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint   nSamplesPerSec;
        public uint   nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    public sealed class Wasapi : IDisposable {
        const int   CLSCTX_ALL      = 0x17;
        const int   SHARE_SHARED    = 0;
        const int   FLAG_LOOPBACK   = 0x00020000;
        const uint  BUFFER_SILENT   = 0x2;
        // WAVE format tags are unsigned 16-bit values; 0xFFFE (WAVE_FORMAT_
        // EXTENSIBLE) is 65534 and does not fit a signed short, which the C#
        // compiler rejects as a constant conversion. ushort, not short.
        const ushort WAVE_FLOAT      = 3;
        const ushort WAVE_EXTENSIBLE = 0xFFFE;
        static readonly Guid IID_IAudioClient =
            new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
        static readonly Guid IID_IAudioCaptureClient =
            new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");

        IAudioClient client;
        IAudioCaptureClient capture;
        public int SrcRate, SrcChannels;
        public bool SrcIsFloat;
        public int FrameBytes { get { return SrcChannels * (SrcIsFloat ? 4 : 2); } }

        public void Open() {
            var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            IntPtr devPtr;
            // eRender + the loopback flag = "record what you hear". eCapture
            // would be the microphone, the opposite of what this is for.
            HR(en.GetDefaultAudioEndpoint(0, 0, out devPtr), "GetDefaultAudioEndpoint");
            var dev = (IMMDevice)Marshal.GetObjectForIUnknown(devPtr);

            // CS0199: a static readonly field can never be passed by ref/out,
            // so copy the interface GUIDs into locals first.
            Guid iidClient = IID_IAudioClient;
            Guid iidCapture = IID_IAudioCaptureClient;

            IntPtr cliPtr;
            HR(dev.Activate(ref iidClient, CLSCTX_ALL, IntPtr.Zero, out cliPtr), "Activate");
            client = (IAudioClient)Marshal.GetObjectForIUnknown(cliPtr);

            IntPtr fmtPtr;
            HR(client.GetMixFormat(out fmtPtr), "GetMixFormat");
            var fmt = (WaveFormatEx)Marshal.PtrToStructure(fmtPtr, typeof(WaveFormatEx));
            SrcRate = (int)fmt.nSamplesPerSec;
            SrcChannels = fmt.nChannels;
            SrcIsFloat = IsFloat(fmt, fmtPtr);

            // 200 ms engine buffer. Larger only guards against a busy CPU; our
            // own chunking is what decides the latency the phone sees.
            HR(client.Initialize(SHARE_SHARED, FLAG_LOOPBACK, 2000000L, 0, fmtPtr,
                                 ref iidClient), "Initialize(loopback)");
            HR(client.GetService(ref iidCapture, out cliPtr), "GetService");
            capture = (IAudioCaptureClient)Marshal.GetObjectForIUnknown(cliPtr);
            HR(client.Start(), "Start");
        }

        static bool IsFloat(WaveFormatEx f, IntPtr p) {
            if (f.wFormatTag == WAVE_FLOAT) return true;
            if (f.wFormatTag != WAVE_EXTENSIBLE) return false;
            // SubFormat GUID begins 24 bytes into WAVEFORMATEXTENSIBLE; the first
            // dword of WAVE_FORMAT_IEEE_FLOAT's GUID is 3.
            return (uint)Marshal.ReadInt32(new IntPtr(p.ToInt64() + 24)) == 3;
        }

        /// Appends every available packet to dst at dstOff (in frames) and
        /// returns the frames appended. Zero packets is normal between bursts.
        public int Poll(byte[] dst, int dstOffFrames, int maxFrames) {
            int total = 0;
            int packet;
            while (capture.GetNextPacketSize(out packet) == 0 && packet > 0
                   && total < maxFrames) {
                IntPtr data; int frames; uint flags; long dp, qp;
                if (capture.GetBuffer(out data, out frames, out flags, out dp, out qp) != 0) break;
                if (frames > 0) {
                    int want = Math.Min(frames, maxFrames - total);
                    int off = (dstOffFrames + total) * FrameBytes;
                    if ((flags & BUFFER_SILENT) != 0) Array.Clear(dst, off, want * FrameBytes);
                    else Marshal.Copy(data, dst, off, want * FrameBytes);
                    total += want;
                }
                capture.ReleaseBuffer(frames);
            }
            return total;
        }

        public void Dispose() {
            try { if (client != null) client.Stop(); } catch { }
        }

        static void HR(int hr, string what) {
            if (hr != 0) throw new InvalidOperationException(
                what + " failed: 0x" + hr.ToString("X8"));
        }
    }

    // ---- conversion ---------------------------------------------------------

    public static class Conv {
        /// Resamples and remixes source frames into s16 at the target layout.
        /// `pos` is the fractional source-frame index to start at; newPos is
        /// where it stopped, so the caller can carry the remainder and the
        /// stream stays continuous across calls. Linear interpolation is
        /// audibly fine here: the link is 4-bit ADPCM, nowhere near as lossy.
        public static int Resample(byte[] src, int srcFrames, int srcChannels,
                                   bool srcFloat, int srcRate,
                                   short[] dst, int dstChannels, int dstRate,
                                   double pos, out double newPos) {
            int produced = 0;
            double step = (double)srcRate / dstRate;
            int capacity = dst.Length / dstChannels;
            double p = pos;
            while (produced < capacity) {
                int i0 = (int)p;
                if (i0 + 1 >= srcFrames) break;
                double frac = p - i0;
                for (int c = 0; c < dstChannels; c++) {
                    double v;
                    if (dstChannels == 1 && srcChannels > 1) {
                        // Downmix by averaging every source channel. Taking
                        // source channel 0 instead - what Math.Min(c, ...) did -
                        // silently discards the right side of a stereo mix, and
                        // -Channels 1 is exactly what we tell people to use when
                        // the link saturates.
                        v = 0;
                        for (int sc = 0; sc < srcChannels; sc++)
                            v += Interp(src, i0, frac, sc, srcChannels, srcFloat);
                        v /= srcChannels;
                    } else {
                        int sc = srcChannels == 1 ? 0 : Math.Min(c, srcChannels - 1);
                        v = Interp(src, i0, frac, sc, srcChannels, srcFloat);
                    }
                    if (v > 32767) v = 32767; else if (v < -32768) v = -32768;
                    dst[produced * dstChannels + c] = (short)v;
                }
                produced++;
                p += step;
            }
            newPos = p;
            return produced;
        }

        /// Linear interpolation between source frames i0 and i0+1 on one channel.
        static double Interp(byte[] src, int i0, double frac, int sc, int channels, bool isFloat) {
            double a = Sample(src, i0, sc, channels, isFloat);
            double b = Sample(src, i0 + 1, sc, channels, isFloat);
            return a + (b - a) * frac;
        }

        static double Sample(byte[] src, int frame, int ch, int channels, bool isFloat) {
            int idx = frame * channels + ch;
            if (isFloat) return BitConverter.ToSingle(src, idx * 4) * 32768.0;
            int b = idx * 2;
            return (short)(src[b] | (src[b + 1] << 8));
        }
    }

    // ---- IMA ADPCM encoder ---------------------------------------------------

    public sealed class Adpcm {
        static readonly int[] STEP = {
              7,     8,     9,    10,    11,    12,    13,    14,    16,    17,
             19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
             50,    55,    60,    66,    73,    80,    88,    97,   107,   118,
            130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
            337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
            876,   965,  1065,  1175,  1297,  1432,  1580,  1743,  1925,  2126,
           2349,  2596,  2868,  3168,  3499,  3864,  4268,  4715,  5209,  5755,
           6358,  7024,  7759,  8569,  9462, 10447, 11533, 12729, 14047, 15497,
          17089, 18843, 20769, 22878, 25188, 27729, 30518, 33741, 37267 };
        static readonly int[] IDX = {
            -1, -1, -1, -1,  2,  4,  6,  8,
            -1, -1, -1, -1,  2,  4,  6,  8 };
        readonly int[] pred, sidx;

        public Adpcm(int channels) { pred = new int[channels]; sidx = new int[channels]; }
        public void Reset() { Array.Clear(pred, 0, pred.Length); Array.Clear(sidx, 0, sidx.Length); }

        int Nibble(int c, int sample) {
            int step = STEP[sidx[c]];
            int diff = sample - pred[c];
            int code = 0;
            if (diff < 0) { code = 8; diff = -diff; }
            if (diff >= step)        { code |= 4; diff -= step; }
            if (diff >= (step >> 1)) { code |= 2; diff -= step >> 1; }
            if (diff >= (step >> 2)) { code |= 1; }
            // Advance by REPLAYING our own code, exactly as the decoder will.
            // Using the original sample here instead is the classic mistake and
            // makes the two ends diverge on the very first nibble.
            int d = step >> 3;
            if ((code & 4) != 0) d += step;
            if ((code & 2) != 0) d += step >> 1;
            if ((code & 1) != 0) d += step >> 2;
            if ((code & 8) != 0) d = -d;
            int p = pred[c] + d;
            pred[c] = p < -32768 ? -32768 : (p > 32767 ? 32767 : p);
            int i = sidx[c] + IDX[code];
            sidx[c] = i < 0 ? 0 : (i > 88 ? 88 : i);
            return code;
        }

        /// Planar output: channel 0's bytes then channel 1's, matching the
        /// Android decoder, which halves the payload before decoding.
        public void Encode(short[] interleaved, int frames, int ch, byte[] dst) {
            int half = frames / 2;
            for (int c = 0; c < ch; c++) {
                int o = c * half;
                for (int f = 0; f < frames; f += 2) {
                    int lo = Nibble(c, interleaved[f * ch + c]);
                    int hi = Nibble(c, interleaved[(f + 1) * ch + c]);
                    dst[o + f / 2] = (byte)((lo & 0x0F) | ((hi & 0x0F) << 4));
                }
            }
        }
    }
}
'@

# --- framing helpers ----------------------------------------------------------

function New-LeBytes([int]$v) {
    # Must come back as a real System.Byte[]: an @( ... ) literal is object[] of
    # Int32, and [Array]::Copy refuses to narrow Int32 into a byte[] ("at least
    # one element in the source array could not be cast down"), which kills the
    # handshake before a single byte reaches the phone. The leading comma keeps
    # PowerShell from unrolling the array into four separate pipeline objects.
    $b = New-Object 'System.Byte[]' 4
    $b[0] = [byte]($v -band 0xFF)
    $b[1] = [byte](($v -shr 8) -band 0xFF)
    $b[2] = [byte](($v -shr 16) -band 0xFF)
    $b[3] = [byte](($v -shr 24) -band 0xFF)
    , $b
}

function Write-Handshake($sp, [int]$codec, [int]$channels, [int]$rate, [int]$chunkMs) {
    $b = New-Object 'System.Byte[]' 16
    [Array]::Copy([byte[]]@(0x42, 0x54, 0x41, 0x31), 0, $b, 0, 4)   # "BTA1"
    $b[4] = $codec
    $b[5] = $channels
    [Array]::Copy((New-LeBytes $rate), 0, $b, 8, 4)
    [Array]::Copy((New-LeBytes $chunkMs), 0, $b, 12, 4)
    $sp.Write($b, 0, 16)
}

function Write-Chunk($sp, [int]$type, [byte[]]$payload) {
    $h = New-Object 'System.Byte[]' 8
    $h[0] = $type
    [Array]::Copy((New-LeBytes $payload.Length), 0, $h, 4, 4)
    $sp.Write($h, 0, 8)
    if ($payload.Length -gt 0) { $sp.Write($payload, 0, $payload.Length) }
}

function Read-Wav([string]$path) {
    $raw = [System.IO.File]::ReadAllBytes($path)
    if ($raw.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($raw, 0, 4) -ne 'RIFF') {
        throw "not a RIFF/WAV file: $path"
    }
    $o = 12; $fmt = $null; $dataOff = 0; $dataLen = 0
    while ($o + 8 -le $raw.Length) {
        $id = [Text.Encoding]::ASCII.GetString($raw, $o, 4)
        $len = [BitConverter]::ToInt32($raw, $o + 4)
        if ($id -eq 'fmt ') {
            $tag  = [BitConverter]::ToUInt16($raw, $o + 8)
            $bits = [BitConverter]::ToUInt16($raw, $o + 22)
            $isFloat = ($tag -eq 3) -or ($bits -eq 32)
            if (-not $isFloat -and $tag -ne 1 -and $tag -ne 0xFFFE) {
                throw "unsupported WAV format tag $tag (need PCM or float)"
            }
            if ($bits -ne 16 -and $bits -ne 32) { throw "unsupported WAV bit depth $bits" }
            $fmt = @{
                Channels = [int][BitConverter]::ToUInt16($raw, $o + 10)
                Rate     = [BitConverter]::ToInt32($raw, $o + 12)
                Bits     = [int]$bits
                Float    = $isFloat
            }
        } elseif ($id -eq 'data') { $dataOff = $o + 8; $dataLen = $len; break }
        $o += 8 + $len + ($len % 2)
    }
    if ($null -eq $fmt -or $dataOff -eq 0) { throw "no fmt/data chunk in $path" }
    $frameBytes = $fmt.Channels * ($fmt.Bits / 8)
    $frames = [int]($dataLen / $frameBytes)
    $pcm = New-Object 'System.Byte[]' ($frames * $frameBytes)
    [Array]::Copy($raw, $dataOff, $pcm, 0, $pcm.Length)
    return @{ Pcm = $pcm; Frames = $frames; Channels = $fmt.Channels;
              Rate = $fmt.Rate; Float = $fmt.Float }
}



# --- run -----------------------------------------------------------------------

$codecByte = if ($Codec -eq 'Adpcm') { 1 } else { 0 }
# Chunk length must be a multiple of 4 frames, not merely even.
# ADPCM packs two samples per byte and the payload is planar, so a MONO chunk
# carries chunkFrames/2 bytes. At 44.1 kHz / 20 ms that is 882/2 = 441 bytes -
# odd - and the phone's Proto rejects an odd audio payload as a desync and drops
# the stream. Rounding up to a multiple of 4 keeps every codec/channel
# combination legal without changing the wire format the installed APK expects.
$chunkFrames = [int][Math]::Max(4, [Math]::Round($Rate * $ChunkMs / 1000.0))
if ($chunkFrames % 4 -ne 0) { $chunkFrames += 4 - ($chunkFrames % 4) }

Write-Host 'BT Audio sender'
Write-Host ("  {0}  codec {1}  {2} ch  {3} Hz  {4} ms chunks (~{5} kbit/s)" -f `
    $Port, $Codec, $Channels, $Rate, $ChunkMs,
    [int]($Rate * $Channels * $(if ($Codec -eq 'Adpcm') { 4 } else { 16 }) / 1000))

if ($Mode -eq 'File' -and -not (Test-Path -LiteralPath $File)) {
    Write-Host "No such WAV file: $File" -ForegroundColor Red
    exit 1
}

$sp = New-Object System.IO.Ports.SerialPort($Port, 115200, 'None', 8, 'One')
# Bluetooth virtual COM ports ignore the baud rate but NOT hardware handshaking:
# with DTR/RTS asserted some drivers stall forever on a flow-control edge that
# never comes. Both off, handshake none.
$sp.Handshake   = 'None'
$sp.DtrEnable   = $false
$sp.RtsEnable   = $false
$sp.WriteTimeout = 5000
try { $sp.Open() } catch {
    # PowerShell wraps .NET failures in a MethodInvocationException whose text
    # is "Exception calling Open with 0 argument(s): ...". The reason the user
    # can actually act on is the innermost message, so dig it out.
    $reason = $_.Exception
    while ($reason.InnerException) { $reason = $reason.InnerException }
    Write-Host "Could not open ${Port}: $($reason.Message)" -ForegroundColor Red
    Write-Host 'Check the phone app is running, the COM port exists in Bluetooth settings, and nothing else holds it.' -ForegroundColor Yellow
    exit 1
}

$adpcm = New-Object BtAudio.Adpcm($Channels)
$pcmChunk = New-Object 'System.Int16[]' ($chunkFrames * $Channels)
$sent = 0

function Emit-Chunk([int]$frames) {
    if ($Codec -eq 'Adpcm') {
        $payload = New-Object 'System.Byte[]' ([int]($frames / 2) * $Channels)
        $adpcm.Encode($pcmChunk, $frames, $Channels, $payload)
    } else {
        $payload = New-Object 'System.Byte[]' ($frames * $Channels * 2)
        [Buffer]::BlockCopy($pcmChunk, 0, $payload, 0, $payload.Length)
    }
    Write-Chunk $sp 1 $payload
    $script:sent++
    if ($script:sent % 500 -eq 0) {
        Write-Host ("  {0,7} chunks, {1:N0} KiB sent" -f $script:sent, ($script:sent * $payload.Length / 1024))
    }
}

$script:failed = $false

try {
    Write-Handshake $sp $codecByte $Channels $Rate $ChunkMs
    Write-Chunk $sp 2 @()          # resync: both codecs start from a known state
    Write-Host 'Handshake sent. Streaming - Ctrl+C to stop.' -ForegroundColor Green

    if ($Mode -eq 'File') {
        # Convert the whole file once, then pace the chunks out in real time.
        # Simpler than streaming the decode, and a WAV is small enough that the
        # memory is irrelevant next to the clarity it buys.
        $w = Read-Wav $File
        Write-Host ("WAV: {0} Hz, {1} ch, {2}" -f $w.Rate, $w.Channels,
                    $(if ($w.Float) { 'float32' } else { 's16' }))
        $np = 0.0
        # size for the TARGET rate: upsampling a low-rate WAV produces more
        # frames than the file contains, and Resample() stops at the buffer edge
        $capacity = [int]($w.Frames * $Rate / $w.Rate * 1.05) + 64
        $all = New-Object 'System.Int16[]' ($capacity * $Channels)
        $n = [BtAudio.Conv]::Resample($w.Pcm, $w.Frames, $w.Channels, $w.Float,
                                      $w.Rate, $all, $Channels, $Rate, 0.0, [ref]$np)
        Write-Host ("converted to {0} frames at {1} Hz" -f $n, $Rate)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $off = 0
        while ($off + $chunkFrames -le $n) {
            [Array]::Copy($all, $off * $Channels, $pcmChunk, 0, $chunkFrames * $Channels)
            Emit-Chunk $chunkFrames
            $off += $chunkFrames
            $wantMs = $off * 1000.0 / $Rate
            $gap = $wantMs - $sw.Elapsed.TotalMilliseconds
            if ($gap -gt 1) { Start-Sleep -Milliseconds ([int]$gap) }
        }
        Write-Chunk $sp 3 @()
        Write-Host 'File finished.'
    }
    else {
        $was = New-Object BtAudio.Wasapi
        $was.Open()
        Write-Host ("capturing default playback: {0} Hz, {1} ch, {2}" -f `
            $was.SrcRate, $was.SrcChannels,
            $(if ($was.SrcIsFloat) { 'float32' } else { 's16' }))

        $srcBuf  = New-Object 'System.Byte[]' ($was.FrameBytes * 192000)
        $left    = New-Object 'System.Byte[]' 0      # unconsumed source bytes
        $carry   = New-Object 'System.Int16[]' 0     # converted samples awaiting a chunk
        $srcPos  = 0.0                      # fractional index into $left

        while ($true) {
            $room = [int](($srcBuf.Length - $left.Length) / $was.FrameBytes)
            $got = 0
            if ($room -gt 0) {
                $got = $was.Poll($srcBuf, 0, $room)
            }
            if ($got -le 0 -and $left.Length -eq 0) { Start-Sleep -Milliseconds 5; continue }

            # join leftover source with the fresh poll
            $all = New-Object 'System.Byte[]' ($left.Length + $got * $was.FrameBytes)
            [Array]::Copy($left, 0, $all, 0, $left.Length)
            if ($got -gt 0) { [Array]::Copy($srcBuf, 0, $all, $left.Length, $got * $was.FrameBytes) }
            $frames = [int]($all.Length / $was.FrameBytes)

            $conv = New-Object 'System.Int16[]' (($frames + 2) * $Channels)
            $np = 0.0
            $n = [BtAudio.Conv]::Resample($all, $frames, $was.SrcChannels, $was.SrcIsFloat,
                                          $was.SrcRate, $conv, $Channels, $Rate,
                                          $srcPos, [ref]$np)
            $used = [int][Math]::Floor($np)
            $srcPos = $np - $used

            # keep the unconsumed tail (including the frame we interpolate from)
            $keepFrom = [Math]::Max(0, $used)
            $keepBytes = $all.Length - $keepFrom * $was.FrameBytes
            $left = New-Object 'System.Byte[]' $keepBytes
            [Array]::Copy($all, $keepFrom * $was.FrameBytes, $left, 0, $keepBytes)

            if ($n -gt 0) {
                $acc = New-Object 'System.Int16[]' ($carry.Length + $n * $Channels)
                [Array]::Copy($carry, 0, $acc, 0, $carry.Length)
                [Array]::Copy($conv, 0, $acc, $carry.Length, $n * $Channels)
                $off = 0
                while ($acc.Length - $off -ge $chunkFrames * $Channels) {
                    [Array]::Copy($acc, $off, $pcmChunk, 0, $chunkFrames * $Channels)
                    Emit-Chunk $chunkFrames
                    $off += $chunkFrames * $Channels
                }
                $carry = New-Object 'System.Int16[]' ($acc.Length - $off)
                [Array]::Copy($acc, $off, $carry, 0, $carry.Length)
            }
        }
    }
}
catch [System.TimeoutException] {
    Write-Host ("Write to {0} timed out - the phone stopped taking data." -f $Port) -ForegroundColor Red
    Write-Host 'Is BT Audio In still connected and in the foreground? Nothing else can hold the port while this runs.' -ForegroundColor Yellow
    $script:failed = $true
}
catch [System.IO.IOException] {
    Write-Host ("I/O error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'For a WAV: check the path and that the file is 16-bit PCM or 32-bit float. For the port: check the phone is still listening and nothing else opened it.' -ForegroundColor Yellow
    $script:failed = $true
}
finally {
    try { Write-Chunk $sp 3 @() } catch { }
    try { $sp.Close() } catch { }
    Write-Host ("stopped after {0} chunks" -f $sent)
}
if ($script:failed) { exit 1 }
