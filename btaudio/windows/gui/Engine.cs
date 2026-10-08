// ---------------------------------------------------------------------------
// BtAudioSender - streaming engine.
//
// This is where the skipping gets fixed, and the reasoning is worth writing
// down because the obvious implementation is wrong.
//
// The phone's AudioTrack is created and play()ed with an EMPTY buffer. Its
// capacity is chunkMs x <buffer preset> - 320 ms at "Very tolerant" with 20 ms
// chunks - but capacity only becomes useful latency if somebody puts audio in
// it. A sender that just forwards each chunk as the PC produces it keeps that
// buffer near empty, so the phone has nothing to ride out a link hiccup with,
// and it skips no matter which preset is chosen. That is exactly the symptom
// being reported: every preset sounds the same because none of them is filled.
//
// So the engine does three things a naive sender does not:
//
//   1. PRIMING. It holds back the first `PrebufferMs` of audio and then sends
//      it as one burst, which pushes the phone's buffer up to that depth. From
//      then on the phone holds ~PrebufferMs of audio permanently, and that is
//      what absorbs jitter and CPU hiccups.
//
//   2. A CONTINUOUS TIMELINE. WASAPI loopback only hands over packets while
//      something is actually playing, but the clock keeps running. If the
//      sender goes quiet whenever the PC does, the phone drains its buffer and
//      every silence becomes a skip when audio resumes. So the engine fills
//      every gap with SILENCE at the wall clock's rate, keeping the timeline
//      continuous and the phone's buffer full.
//
//   3. AUTO QUALITY. It watches how long each write actually takes. A write
//      that blocks means the phone stopped draining, which means the radio or
//      the phone cannot keep up with the bitrate - so it drops a rung and
//      reconnects. No guessing about "the CPU is weak": this measures the thing
//      that actually decides whether audio arrives.
//
// Nothing here touches Windows APIs, so this exact code is what the Linux test
// harness runs against the phone's real decoder.
// ---------------------------------------------------------------------------
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

namespace BtAudio
{
    /// <summary>Where framed audio goes. Windows uses a SerialPort; the test
    /// harness uses a FileStream on a pty.</summary>
    public interface IByteSink
    {
        void Open();
        void Write(byte[] buf, int off, int len);
        void Close();
        string Describe { get; }
    }

    /// <summary>Where PCM comes from. Windows uses WASAPI loopback; the test
    /// harness uses a WAV on disk.</summary>
    public interface IAudioSource
    {
        int Rate { get; }
        int Channels { get; }
        bool IsFloat { get; }
        int FrameBytes { get; }
        void Open();
        /// <summary>Append up to maxFrames frames at dst[0]. Returns the frame
        /// count, which may be 0 - that is normal between bursts.</summary>
        int Poll(byte[] dst, int maxFrames);
        /// <summary>Peak level of the most recent data, 0..32767. Used to tell
        /// whether a driver's mute silenced the capture tap itself.</summary>
        int LastPeak { get; }
        /// <summary>True once no more data will ever arrive (a file that has
        /// been read to the end). A live capture is never exhausted: silence is
        /// a valid state and the clock keeps running.</summary>
        bool Exhausted { get; }
        /// <summary>How many frames this source has ever produced, counted from
        /// Open(), INCLUDING any stretch during which the device had nothing to
        /// hand over. This is the device's own clock, not the wall clock.
        ///
        /// It exists because WASAPI loopback simply stops delivering packets
        /// while the PC is silent - there is no "silence packet" - so the only
        /// correct way to keep the phone's timeline going through a quiet patch
        /// is to ask the device where it has got to and make up the difference
        /// with silence. A file has no gaps, so its position is just the frames
        /// it has handed over.</summary>
        long PositionFrames { get; }
        void Close();
    }

    public sealed class SenderSettings
    {
        public Codec Codec = Codec.Adpcm;
        public int Channels = 2;
        public int Rate = 44100;
        public int ChunkMs = 20;
        /// <summary>Audio held in the phone's buffer. Must stay under the
        /// phone's capacity (chunkMs x the app's buffer preset) or its write()
        /// blocks - which stalls the link instead of absorbing jitter.</summary>
        public int PrebufferMs = 260;
        public bool AutoQuality = true;
        public int PhoneBufferMult = 16;
        public bool FileMode = false;
        /// <summary>Loopback only: stop after this much audio was sent. 0 = run
        /// until cancelled.</summary>
        public int MaxAudioMs = 0;

        public int ChunkFrames { get { return Framer.ChunkFrames(Rate, ChunkMs); } }
        public int FrameBytes { get { return Channels * 2; } }
        public int PayloadLen { get { return Framer.PayloadLen(Codec, ChunkFrames, Channels); } }
        public int WireBytesPerSecond
        {
            get { return (int)((long)(Framer.ChunkHeaderLen + PayloadLen) * Rate / ChunkFrames); }
        }

        public SenderSettings Clone() { return (SenderSettings)MemberwiseClone(); }
    }

    /// <summary>Plays a WAV file as the source. 16-bit PCM and 32-bit float, one
    /// or two channels; anything else is refused with a sentence rather than a
    /// mangled stream.</summary>
    public sealed class WavFileSource : IAudioSource
    {
        readonly string path;
        byte[] data;
        int dataOff, dataLen, pos;

        public int Rate { get; private set; }
        public int Channels { get; private set; }
        public bool IsFloat { get; private set; }
        public int FrameBytes { get { return Channels * (IsFloat ? 4 : 2); } }
        public int LastPeak { get; private set; }
        public bool Exhausted { get { return pos >= dataLen / FrameBytes; } }
        public long PositionFrames { get { return pos; } }        // no gaps in a file

        public WavFileSource(string path) { this.path = path; }

        public void Open()
        {
            if (data != null) return;                    // idempotent
            byte[] raw = System.IO.File.ReadAllBytes(path);
            if (raw.Length < 44 || raw[0] != 'R' || raw[1] != 'I' || raw[2] != 'F' || raw[3] != 'F')
                throw new InvalidOperationException("not a RIFF/WAV file: " + path);
            int o = 12, bits = 0, tag = 0;
            dataOff = 0; dataLen = 0;
            while (o + 8 <= raw.Length)
            {
                string id = System.Text.Encoding.ASCII.GetString(raw, o, 4);
                int len = BitConverter.ToInt32(raw, o + 4);
                if (id == "fmt ")
                {
                    tag = BitConverter.ToUInt16(raw, o + 8);
                    Channels = BitConverter.ToUInt16(raw, o + 10);
                    Rate = BitConverter.ToInt32(raw, o + 12);
                    bits = BitConverter.ToUInt16(raw, o + 22);
                }
                else if (id == "data") { dataOff = o + 8; dataLen = len; }
                o += 8 + len + (len % 2);
            }
            if (dataLen == 0) throw new InvalidOperationException("no data chunk in " + path);
            if (bits != 16 && bits != 32) throw new InvalidOperationException(
                "unsupported WAV bit depth " + bits + " (need 16-bit PCM or 32-bit float)");
            IsFloat = tag == 3 || bits == 32;
            if (!IsFloat && tag != 1 && tag != 0xFFFE)
                throw new InvalidOperationException("unsupported WAV format tag " + tag);
            data = raw;
            pos = 0;
        }

        public int Poll(byte[] dst, int maxFrames)
        {
            int totalFrames = dataLen / FrameBytes;
            if (pos >= totalFrames) return 0;
            int n = totalFrames - pos;
            if (n > maxFrames) n = maxFrames;
            Buffer.BlockCopy(data, dataOff + pos * FrameBytes, dst, 0, n * FrameBytes);
            pos += n;
            LastPeak = Peak(dst, 0, n * FrameBytes);
            return n;
        }

        static int Peak(byte[] b, int off, int len)
        {
            int n = Math.Min(len, 8192), peak = 0;
            for (int i = 0; i + 1 < n; i += 2)
            {
                int v = (short)(b[off + i] | (b[off + i + 1] << 8));
                if (v < 0) v = -v;
                if (v > peak) peak = v;
            }
            return peak;
        }

        /// <summary>Drops the file so a later Open() re-reads it from the start.
        /// Without this the idempotent Open() leaves the source exhausted
        /// forever, and a reconnect would have nothing to send.</summary>
        public void Close() { data = null; pos = 0; }
    }

    public sealed class SenderStats
    {
        public long ChunksSent;
        public double SentMs, ElapsedMs, BacklogMs;
        public double WriteMsMedian, BlockedFraction;
        public int Rung;
        public string RungName = "";
        public double KbitsPerSec;
        public bool Primed;
        public int SourcePeak;
    }

    public sealed class Sender
    {
        readonly IAudioSource src;
        readonly IByteSink sink;
        readonly SenderSettings set;
        readonly Action<string> log;
        readonly Action<SenderStats> onStats;

        public Sender(IAudioSource src, IByteSink sink, SenderSettings set,
                      Action<string> log, Action<SenderStats> onStats)
        {
            this.src = src; this.sink = sink; this.set = set;
            this.log = log ?? delegate { };
            this.onStats = onStats ?? delegate { };
        }

        public int CurrentRung { get; private set; }

        const int SrcBufFrames = 192000;      // ~4 s at 48 kHz
        const int WriteWindow = 120;
        const double CongestWriteMs = 22.0;   // a write this slow means backpressure
        const double CongestHoldMs = 8000;    // sustained this long before acting
        const double BacklogFactor = 1.6;     // sender-side backlog vs prebuffer

        /// <summary>Runs until cancelled (or EOF in file mode), walking down the
        /// quality ladder while the link stays congested.</summary>
        public void Run(CancellationToken cancel)
        {
            int rung = 0;
            CurrentRung = 0;
            if (set.AutoQuality) ApplyRung(0);

            while (!cancel.IsCancellationRequested)
            {
                bool downgrade;
                try
                {
                    downgrade = RunOneSession(cancel);
                }
                catch (Exception e)
                {
                    if (cancel.IsCancellationRequested) return;
                    log("session ended: " + Innermost(e).Message);
                    downgrade = set.AutoQuality;
                }

                if (cancel.IsCancellationRequested || !downgrade) return;

                rung++;
                if (rung >= Presets.Ladder.Length)
                {
                    log("already at the most robust setting and it is still congested - "
                        + "move the phone nearer, or raise the phone's buffer preset");
                    return;
                }
                CurrentRung = rung;
                ApplyRung(rung);
                log("dropping to " + set.Rate + " Hz " + set.Channels + " ch ("
                    + (set.Rate * set.Channels * 4 / 1000) + " kbit/s) and reconnecting");
                SleepUnlessCancelled(1200, cancel);
                Quietly(src.Close);
                Quietly(sink.Close);
            }
        }

        void ApplyRung(int rung)
        {
            Preset p = Presets.Ladder[rung];
            set.Codec = p.Codec;
            set.Channels = p.Channels;
            set.Rate = p.Rate;
            set.ChunkMs = p.ChunkMs;
            set.PrebufferMs = ClampPrebuffer(p.PrebufferMs);
        }

        int ClampPrebuffer(int want)
        {
            int cap = DelayModel.PhoneCapacityMs(set.ChunkMs, set.PhoneBufferMult);
            int use = want > cap ? cap : want;
            int floor = set.ChunkMs * 2;
            if (use < floor) use = floor;
            return use;
        }

        /// <summary>Runs one connection. True means the session ended because the
        /// link is congested and a lower rung should be tried.</summary>
        bool RunOneSession(CancellationToken cancel)
        {
            // Open the source first: its rate, channel count and sample format
            // are only known once it is open, and the engine sizes every buffer
            // from those. Open() is idempotent, so a reconnect re-opens both
            // ends and the format is re-read rather than assumed.
            src.Open();
            sink.Open();

            Framer framer = new Framer(set.Codec, set.Channels, set.Rate, set.ChunkMs);
            int chunkFrames = set.ChunkFrames;
            int payloadLen = set.PayloadLen;
            int prebufferFrames = (int)((long)set.PrebufferMs * set.Rate / 1000);
            int maxFrames = set.MaxAudioMs > 0 ? (int)((long)set.MaxAudioMs * set.Rate / 1000) : 0;

            byte[] outBuf = new byte[Framer.ChunkHeaderLen + Math.Max(payloadLen, 1)];
            byte[] payload = new byte[Math.Max(payloadLen, 1)];
            short[] pcmChunk = new short[chunkFrames * set.Channels];
            byte[] empty = new byte[0];
            AdpcmEncoder enc = new AdpcmEncoder(set.Channels);

            byte[] hs = framer.Handshake();
            sink.Write(hs, 0, hs.Length);
            // a resync chunk: both ends start from a known adaptive state
            sink.Write(outBuf, 0, framer.BuildChunk(empty, 0, outBuf, Framer.ChunkResync));

            log("connected to " + sink.Describe + ": " + set.Channels + " ch, " + set.Rate
                + " Hz, " + set.ChunkMs + " ms chunks, " + set.PrebufferMs + " ms prebuffer");

            byte[] raw = new byte[src.FrameBytes * SrcBufFrames];
            byte[] rawLeft = new byte[0];
            double srcPos = 0.0;

            short[] buf = new short[4096];
            int bufLen = 0;                        // samples valid in buf
            int bufOff = 0;                        // samples already sent from the front

            long timelineFrames = 0;               // frames ever produced into the pipeline
            long sentFrames = 0;                   // frames ever written to the link
            long rawFramesIn = 0;
            bool primed = false, eof = false;

            Stopwatch clock = Stopwatch.StartNew();
            Stopwatch wclock = new Stopwatch();
            Queue<double> writeMs = new Queue<double>();
            double winBlockedMs = 0;        // time spent inside Write this window
            double winStartMs = 0;          // when this window began
            double blockedFrac = 0;         // last measured value
            double congestSince = -1;
            long prevSentFrames = 0;
            double prevStatsMs = 0;

            try
            {

            while (true)
            {
                if (cancel.IsCancellationRequested) break;

                // ------------------------------------------------------------ input
                int got = 0;
                if (!eof)
                {
                    int roomFrames = SrcBufFrames - rawLeft.Length / src.FrameBytes;
                    if (roomFrames > 0) got = src.Poll(raw, roomFrames);

                    if (got > 0)
                    {
                        byte[] all = new byte[rawLeft.Length + got * src.FrameBytes];
                        Buffer.BlockCopy(rawLeft, 0, all, 0, rawLeft.Length);
                        Buffer.BlockCopy(raw, 0, all, rawLeft.Length, got * src.FrameBytes);
                        rawLeft = all;
                        rawFramesIn += got;
                    }
                    else if (set.FileMode && src.Exhausted && rawLeft.Length < src.FrameBytes * 4)
                    {
                        eof = true;                       // file drained
                    }
                }

                // ---------------------------------------------------------- convert
                int availFrames = rawLeft.Length / src.FrameBytes;
                if (availFrames >= 2)
                {
                    int cap = (int)((double)availFrames * set.Rate / src.Rate) + 8;
                    short[] dst = new short[cap * set.Channels];
                    double newPos;
                    int n = Conv.Resample(rawLeft, availFrames, src.Channels, src.IsFloat,
                                          src.Rate, dst, set.Channels, set.Rate, srcPos, out newPos);
                    if (n > 0)
                    {
                        int whole = (int)Math.Floor(newPos);
                        if (whole > availFrames - 1) whole = availFrames - 1;
                        srcPos = newPos - whole;

                        Ensure(ref buf, bufLen + n * set.Channels);
                        Buffer.BlockCopy(dst, 0, buf, bufLen * 2, n * set.Channels * 2);
                        bufLen += n * set.Channels;
                        timelineFrames += n;

                        int keepFrom = whole * src.FrameBytes;
                        byte[] kept = new byte[rawLeft.Length - keepFrom];
                        Buffer.BlockCopy(rawLeft, keepFrom, kept, 0, kept.Length);
                        rawLeft = kept;
                    }
                }

                // -------------------------------------------------- continuous clock
                // The device's position advances even when it has nothing to hand
                // over (a quiet PC produces no loopback packets at all). Insert
                // silence for whatever it skipped, so the phone's buffer keeps
                // draining against a moving timeline instead of running dry and
                // turning every silence into a skip when the sound comes back.
                //
                // Padding from the WALL clock instead would be wrong, and the
                // tests below prove it: any hiccup in this loop - a slow resample,
                // a GC pause - would look like a device gap and get filled with
                // silence spliced into the middle of real audio.
                if (!set.FileMode)
                {
                    long deviceFrames = src.PositionFrames;
                    long gap = deviceFrames - timelineFrames;
                    if (gap > 0)
                    {
                        // A long quiet stretch is capped rather than poured in: the
                        // phone cannot accept more than its buffer anyway, and the
                        // rest is silence nobody was listening to.
                        long cap = (long)set.Rate;                     // 1 s
                        if (gap > cap) { gap = cap; }
                        int padFrames = (int)gap;
                        Ensure(ref buf, bufLen + padFrames * set.Channels);
                        Array.Clear(buf, bufLen, padFrames * set.Channels);
                        bufLen += padFrames * set.Channels;
                        timelineFrames += padFrames;
                    }
                }

                // ------------------------------------------------------- pacing gate
                long allowed;
                if (set.FileMode)
                {
                    long elapsedFrames = (long)(clock.Elapsed.TotalMilliseconds * set.Rate / 1000.0);
                    allowed = elapsedFrames + prebufferFrames;
                    if (maxFrames > 0 && allowed > maxFrames) allowed = maxFrames;
                    if (eof && rawLeft.Length < src.FrameBytes) allowed = long.MaxValue;  // flush the tail
                }
                else
                {
                    long elapsedFrames = (long)(clock.Elapsed.TotalMilliseconds * set.Rate / 1000.0);
                    if (!primed)
                    {
                        if (timelineFrames >= prebufferFrames)
                        {
                            primed = true;
                            log("phone buffer primed to " + set.PrebufferMs + " ms");
                        }
                    }
                    // Never run more than PrebufferMs ahead of the wall clock.
                    // Live audio arrives at real time anyway, so this only
                    // matters after a burst or a stall - exactly when letting it
                    // through would push the phone's buffer deeper and add
                    // latency that never comes back.
                    allowed = primed ? Math.Min(timelineFrames, elapsedFrames + prebufferFrames) : 0;
                }

                // ----------------------------------------------------------- emit
                while (bufLen - bufOff >= chunkFrames * set.Channels
                       && sentFrames + chunkFrames <= allowed)
                {
                    // count is in BYTES: pcmChunk is short[]
                    Buffer.BlockCopy(buf, bufOff * 2, pcmChunk, 0, pcmChunk.Length * 2);
                    if (set.Codec == Codec.Adpcm)
                    {
                        enc.Encode(pcmChunk, chunkFrames, set.Channels, payload);
                    }
                    else
                    {
                        Buffer.BlockCopy(pcmChunk, 0, payload, 0, payloadLen);
                    }
                    int total = framer.BuildChunk(payload, payloadLen, outBuf, Framer.ChunkAudio);

                    wclock.Restart();
                    sink.Write(outBuf, 0, total);
                    double ms = wclock.Elapsed.TotalMilliseconds;
                    winBlockedMs += ms;
                    writeMs.Enqueue(ms);
                    while (writeMs.Count > WriteWindow) writeMs.Dequeue();

                    bufOff += chunkFrames * set.Channels;
                    sentFrames += chunkFrames;
                }

                if (bufOff > 0 && (bufOff >= bufLen || bufOff > 65536))
                {
                    int keep = bufLen - bufOff;
                    if (keep > 0) Buffer.BlockCopy(buf, bufOff * 2, buf, 0, keep * 2);
                    bufLen = keep;
                    bufOff = 0;
                }

                // -------------------------------------------------------- stopping
                if (set.FileMode && eof && bufLen - bufOff == 0 && rawLeft.Length < src.FrameBytes * 4)
                {
                    break;
                }
                if (set.FileMode && maxFrames > 0 && sentFrames >= maxFrames
                    && bufLen - bufOff == 0)
                {
                    break;
                }

                // ----------------------------------------------------------- pacing
                if (set.FileMode)
                {
                    double aheadMs = (sentFrames - prebufferFrames) * 1000.0 / set.Rate
                                     - clock.Elapsed.TotalMilliseconds;
                    if (aheadMs > 3) SleepUnlessCancelled((int)(aheadMs - 2), cancel);
                    else if (aheadMs > 0) SleepUnlessCancelled(1, cancel);
                }
                else if (got == 0)
                {
                    SleepUnlessCancelled(4, cancel);
                }

                // --------------------------------------------------------- health
                double nowMs = clock.Elapsed.TotalMilliseconds;
                double backlogMs = (bufLen - bufOff) * 1000.0 / set.Channels / set.Rate;
                if (nowMs - winStartMs >= 500)
                {
                    blockedFrac = (nowMs - winStartMs) > 0
                        ? winBlockedMs / (nowMs - winStartMs) : 0;
                    winBlockedMs = 0;
                    winStartMs = nowMs;

                    SenderStats st = new SenderStats();
                    st.ChunksSent = sentFrames / chunkFrames;
                    st.SentMs = sentFrames * 1000.0 / set.Rate;
                    st.ElapsedMs = nowMs;
                    st.BacklogMs = backlogMs;
                    st.WriteMsMedian = Median(writeMs);
                    st.BlockedFraction = blockedFrac;
                    st.Rung = CurrentRung;
                    st.RungName = set.Rate + " Hz " + (set.Channels == 1 ? "mono" : "stereo");
                    double dt = nowMs - prevStatsMs;
                    st.KbitsPerSec = dt > 0
                        ? (sentFrames - prevSentFrames) / (double)Math.Max(chunkFrames, 1)
                          * (Framer.ChunkHeaderLen + payloadLen) * 8.0 / (dt / 1000.0) / 1000.0
                        : 0;
                    st.Primed = primed;
                    st.SourcePeak = src.LastPeak;
                    onStats(st);
                    prevSentFrames = sentFrames;
                    prevStatsMs = nowMs;
                }

                if (set.AutoQuality)
                {
                    bool congested = Median(writeMs) > CongestWriteMs
                                     || (nowMs > 3000 && blockedFrac > 0.20)
                                     || (!set.FileMode && primed && got > 0
                                         && backlogMs > set.PrebufferMs * BacklogFactor);
                    if (congested)
                    {
                        if (congestSince < 0) congestSince = nowMs;
                        else if (nowMs - congestSince > CongestHoldMs)
                        {
                            log("link congested: " + Median(writeMs).ToString("0")
                                + " ms per write, backlog " + backlogMs.ToString("0")
                                + " ms - stepping down");
                            return true;
                        }
                    }
                    else congestSince = -1;
                }
            }

            }
            catch (OperationCanceledException) { }      // fall through and close cleanly

            // -------------------------------------------------------------- shutdown
            try { sink.Write(outBuf, 0, framer.BuildChunk(empty, 0, outBuf, Framer.ChunkEnd)); }
            catch { }
            Quietly(sink.Close);
            log("stopped: " + (sentFrames / Math.Max(chunkFrames, 1)) + " chunks, "
                + (sentFrames * 1000.0 / set.Rate / 1000.0).ToString("0.0") + " s of audio");
            return false;
        }

        static void Ensure(ref short[] buf, int needSamples)
        {
            if (buf.Length >= needSamples) return;
            int cap = buf.Length;
            while (cap < needSamples) cap *= 2;
            short[] bigger = new short[cap];
            Buffer.BlockCopy(buf, 0, bigger, 0, buf.Length * 2);
            buf = bigger;
        }

        static double Median(Queue<double> q)
        {
            if (q.Count == 0) return 0;
            double[] a = q.ToArray();
            Array.Sort(a);
            return a[a.Length / 2];
        }

        static void SleepUnlessCancelled(int ms, CancellationToken cancel)
        {
            if (ms <= 0) return;
            if (cancel.WaitHandle.WaitOne(ms)) throw new OperationCanceledException(cancel);
        }

        static void Quietly(Action a) { try { a(); } catch { } }

        static Exception Innermost(Exception e)
        {
            while (e.InnerException != null) e = e.InnerException;
            return e;
        }
    }
}
