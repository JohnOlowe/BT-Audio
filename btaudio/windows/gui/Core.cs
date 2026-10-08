// ---------------------------------------------------------------------------
// BtAudioSender - portable core.
//
// Shared by the Windows GUI and by the Linux test harness. Contains no Windows
// and no UI types, so the exact code that runs on the user's machine can be
// executed and checked against the phone's own decoder before shipping.
//
// The wire format and the ADPCM arithmetic here are byte-identical to the
// PowerShell sender's, which was itself validated end to end against the
// Proto/Adpcm classes that ship inside the APK.
// ---------------------------------------------------------------------------
using System;
using System.IO;

namespace BtAudio
{
    public enum Codec { Pcm16 = 0, Adpcm = 1 }

    // -----------------------------------------------------------------------
    // Resampling / channel mapping
    // -----------------------------------------------------------------------
    public static class Conv
    {
        /// <summary>
        /// Resamples and remixes source frames into s16 at the target layout.
        /// `pos` is the fractional source-frame index to start at; newPos is
        /// where it stopped, so the caller can carry the remainder and the
        /// stream stays continuous across calls. Linear interpolation is
        /// audibly fine here: the link is 4-bit ADPCM, nowhere near as lossy.
        /// </summary>
        public static int Resample(byte[] src, int srcFrames, int srcChannels,
                                   bool srcFloat, int srcRate,
                                   short[] dst, int dstChannels, int dstRate,
                                   double pos, out double newPos)
        {
            int produced = 0;
            double step = (double)srcRate / dstRate;
            int capacity = dst.Length / dstChannels;
            double p = pos;
            while (produced < capacity)
            {
                int i0 = (int)p;
                if (i0 + 1 >= srcFrames) break;
                double frac = p - i0;
                for (int c = 0; c < dstChannels; c++)
                {
                    double v;
                    if (dstChannels == 1 && srcChannels > 1)
                    {
                        // Downmix by averaging every source channel. Taking
                        // source channel 0 instead silently discards the right
                        // side of a stereo mix, and mono is what we fall back to
                        // when the link saturates.
                        v = 0;
                        for (int sc = 0; sc < srcChannels; sc++)
                            v += Interp(src, i0, frac, sc, srcChannels, srcFloat);
                        v /= srcChannels;
                    }
                    else
                    {
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

        static double Interp(byte[] src, int i0, double frac, int sc, int channels, bool isFloat)
        {
            double a = Sample(src, i0, sc, channels, isFloat);
            double b = Sample(src, i0 + 1, sc, channels, isFloat);
            return a + (b - a) * frac;
        }

        static double Sample(byte[] src, int frame, int ch, int channels, bool isFloat)
        {
            int idx = frame * channels + ch;
            if (isFloat) return BitConverter.ToSingle(src, idx * 4) * 32768.0;
            int b = idx * 2;
            return (short)(src[b] | (src[b + 1] << 8));
        }
    }

    // -----------------------------------------------------------------------
    // IMA ADPCM encoder (the decoder lives in the APK; these tables are
    // byte-identical to Adpcm.java's, verified mechanically)
    // -----------------------------------------------------------------------
    public sealed class AdpcmEncoder
    {
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

        public AdpcmEncoder(int channels) { pred = new int[channels]; sidx = new int[channels]; }
        public void Reset() { Array.Clear(pred, 0, pred.Length); Array.Clear(sidx, 0, sidx.Length); }

        int Nibble(int c, int sample)
        {
            int step = STEP[sidx[c]];
            int diff = sample - pred[c];
            int code = 0;
            if (diff < 0) { code = 8; diff = -diff; }
            if (diff >= step) { code |= 4; diff -= step; }
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

        /// <summary>Planar output: channel 0's nibbles first, then channel 1's,
        /// matching the Android decoder, which halves the payload before decoding.</summary>
        public void Encode(short[] interleaved, int frames, int ch, byte[] dst)
        {
            int half = frames / 2;
            for (int c = 0; c < ch; c++)
            {
                int o = c * half;
                for (int f = 0; f < frames; f += 2)
                {
                    int lo = Nibble(c, interleaved[f * ch + c]);
                    int hi = Nibble(c, interleaved[(f + 1) * ch + c]);
                    dst[o + f / 2] = (byte)((lo & 0x0F) | ((hi & 0x0F) << 4));
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Wire framing
    // -----------------------------------------------------------------------
    public sealed class Framer
    {
        public const int HandshakeLen = 16;
        public const int ChunkHeaderLen = 8;
        public const int ChunkAudio = 1, ChunkResync = 2, ChunkEnd = 3;
        public const int MaxPayload = 1 << 18;

        readonly int codecByte, channels, rate, chunkMs;

        public Framer(Codec codec, int channels, int rate, int chunkMs)
        {
            this.codecByte = (int)codec;
            this.channels = channels;
            this.rate = rate;
            this.chunkMs = chunkMs;
        }

        public byte[] Handshake()
        {
            byte[] b = new byte[HandshakeLen];
            b[0] = 0x42; b[1] = 0x54; b[2] = 0x41; b[3] = 0x31;   // "BTA1"
            b[4] = (byte)codecByte;
            b[5] = (byte)channels;
            PutLe(b, 8, rate);
            PutLe(b, 12, chunkMs);
            return b;
        }

        /// <summary>Header plus payload, in one buffer, so a chunk reaches the
        /// link as a single write - fewer radio round trips on a slow link.</summary>
        public int BuildChunk(byte[] payload, int payloadLen, byte[] dst, int type)
        {
            dst[0] = (byte)type;
            dst[1] = 0; dst[2] = 0; dst[3] = 0;
            PutLe(dst, 4, payloadLen);
            int n = ChunkHeaderLen;
            if (payloadLen > 0 && payload != null)
            {
                Buffer.BlockCopy(payload, 0, dst, n, payloadLen);
                n += payloadLen;
            }
            return n;
        }

        static void PutLe(byte[] b, int off, int v)
        {
            b[off] = (byte)(v & 0xFF);
            b[off + 1] = (byte)((v >> 8) & 0xFF);
            b[off + 2] = (byte)((v >> 16) & 0xFF);
            b[off + 3] = (byte)((v >> 24) & 0xFF);
        }

        /// <summary>Frames per chunk. Rounded up to a multiple of 4: ADPCM packs
        /// two samples per byte and the payload is planar, so a MONO chunk of
        /// 882 frames is 441 bytes - odd - and the phone rejects an odd audio
        /// payload as a desync. A multiple of 4 is always legal.</summary>
        public static int ChunkFrames(int rate, int chunkMs)
        {
            int frames = (int)Math.Round((double)rate * chunkMs / 1000.0);
            if (frames < 4) frames = 4;
            if (frames % 4 != 0) frames += 4 - (frames % 4);
            return frames;
        }

        public static int PayloadLen(Codec codec, int frames, int channels)
        {
            return codec == Codec.Adpcm ? (frames / 2) * channels : frames * channels * 2;
        }
    }

    // -----------------------------------------------------------------------
    // Quality presets and the automatic ladder
    // -----------------------------------------------------------------------
    public sealed class Preset
    {
        public readonly string Name, Note;
        public readonly Codec Codec;
        public readonly int Channels, Rate, ChunkMs, PrebufferMs;
        public int KbitPerSec { get { return Rate * Channels * (Codec == Codec.Adpcm ? 4 : 16) / 1000; } }

        public Preset(string name, Codec codec, int channels, int rate, int chunkMs,
                      int prebufferMs, string note)
        {
            Name = name; Codec = codec; Channels = channels; Rate = rate;
            ChunkMs = chunkMs; PrebufferMs = prebufferMs; Note = note;
        }

        public override string ToString() { return Name; }
    }

    public static class Presets
    {
        public static readonly Preset[] All = {
            // The default. 320 ms of prebuffer is what the phone can actually
            // hold at "Very tolerant", so nothing is wasted and stalls up to
            // that long are absorbed instead of becoming skips.
            new Preset("Balanced (recommended)", Codec.Adpcm, 2, 44100, 20, 260,
                       "44.1 kHz stereo ADPCM, 353 kbit/s. The everyday setting."),
            new Preset("Robust (weak link or weak phone)", Codec.Adpcm, 1, 22050, 30, 300,
                       "22.05 kHz mono, 88 kbit/s. Use when it skips."),
            new Preset("Maximum stability", Codec.Adpcm, 1, 16000, 40, 360,
                       "16 kHz mono, 64 kbit/s. Speech-grade, hardest to break."),
            new Preset("Low latency", Codec.Adpcm, 2, 44100, 10, 90,
                       "10 ms chunks, 90 ms prebuffer. Snappier, cuts out sooner."),
            new Preset("Studio (PCM, high risk)", Codec.Pcm16, 2, 44100, 20, 200,
                       "1411 kbit/s - above what RFCOMM normally sustains. Only to prove a point."),
        };

        /// <summary>Rungs the auto-quality controller walks down. ADPCM only:
        /// PCM cannot fit in the link at any of these rates.</summary>
        public static readonly Preset[] Ladder = {
            new Preset("44.1k stereo", Codec.Adpcm, 2, 44100, 20, 260, ""),
            new Preset("44.1k mono",   Codec.Adpcm, 1, 44100, 20, 300, ""),
            new Preset("32k mono",     Codec.Adpcm, 1, 32000, 25, 320, ""),
            new Preset("22.05k mono",  Codec.Adpcm, 1, 22050, 30, 340, ""),
            new Preset("16k mono",     Codec.Adpcm, 1, 16000, 40, 360, ""),
        };
    }

    // -----------------------------------------------------------------------
    // Latency model
    // -----------------------------------------------------------------------
    public static class DelayModel
    {
        /// <summary>Phone-side jitter buffer capacity, in ms, from the app's own
        /// numbers: AudioEngine allocates
        ///   bufSize = min(max(minBuf*mult, chunkBytes*mult), max(minBuf, rate*ch))
        /// and the chunk term is what dominates. Beyond this the phone's
        /// AudioTrack write() blocks, so priming more than this just wastes
        /// link time instead of absorbing jitter.</summary>
        public static int PhoneCapacityMs(int chunkMs, int bufferMult)
        {
            return chunkMs * bufferMult;
        }

        /// <summary>
        /// Everything the audio passes through on its way to the phone's own
        /// output, excluding the headphones. The prebuffer is the dominant and
        /// the only tunable term.
        /// </summary>
        public static int ToPhoneMs(int prebufferMs, int chunkMs)
        {
            // prebuffer            - audio held in the phone's jitter buffer
            // chunkMs / 2          - half a chunk in flight on average
            // ~10 ms               - WASAPI loopback packet granularity
            // ~15 ms               - RFCOMM + Java decode + AudioTrack start
            return prebufferMs + chunkMs / 2 + 25;
        }

        /// <summary>Typical extra delay of the phone's own output stage.
        /// Bluetooth headphones add a whole second codec + stack on top; wired
        /// is essentially zero.</summary>
        public static readonly string[] HeadphoneChoices = {
            "Wired headphones / earbuds (0 ms)",
            "Bluetooth - aptX / aptX HD (~90 ms)",
            "Bluetooth - AAC (~160 ms)",
            "Bluetooth - SBC / AAC default (~200 ms)",
            "Bluetooth - LDAC (~250 ms)",
            "Phone speaker directly (~0 ms)",
            "Custom (type the number)",
        };

        public static int HeadphoneMs(int choice)
        {
            switch (choice)
            {
                case 0: return 0;
                case 1: return 90;
                case 2: return 160;
                case 3: return 200;
                case 4: return 250;
                case 5: return 0;
                default: return 0;
            }
        }
    }
}
