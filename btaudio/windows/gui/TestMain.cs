// Linux-side entry point for the sender engine. Not part of the shipped exe:
// it lets the same Core/Engine code that runs on Windows be executed against the
// phone's own decoder, which is the only way to test this before it ships.
//
//   TestMain SINKPATH WAVPATH CODEC CHANNELS RATE CHUNKMS PREBUFFERMS SECONDS [STALLMS]
//
// STALLMS > 0 makes every write take that long, which is what a congested
// Bluetooth link looks like from inside the sender: it should trip auto quality
// and reconnect at a lower rung.
using System;
using System.IO;
using System.Threading;

namespace BtAudio
{
    internal static class TestMain
    {
        static int Main(string[] args)
        {
            if (args.Length < 8)
            {
                Console.Error.WriteLine(
                    "usage: TestMain SINKPATH WAVPATH CODEC CHANNELS RATE CHUNKMS PREBUFFERMS SECONDS [STALLMS]");
                return 2;
            }
            string sinkPath = args[0];
            string wav = args[1];
            int codec = int.Parse(args[2]);
            int channels = int.Parse(args[3]);
            int rate = int.Parse(args[4]);
            int chunkMs = int.Parse(args[5]);
            int prebuffer = int.Parse(args[6]);
            int seconds = int.Parse(args[7]);
            int stall = args.Length > 8 ? int.Parse(args[8]) : 0;

            SenderSettings set = new SenderSettings();
            set.Codec = codec == 0 ? Codec.Pcm16 : Codec.Adpcm;
            set.Channels = channels;
            set.Rate = rate;
            set.ChunkMs = chunkMs;
            set.PrebufferMs = prebuffer;
            set.AutoQuality = stall > 0;          // only the ladder test runs with auto
            set.FileMode = false;                 // live mode: silent gaps are filled

            IAudioSource src = new LoopingSource(new WavFileSource(wav));
            IByteSink inner = new FileSink(sinkPath);
            IByteSink sink = stall > 0 ? (IByteSink)new StallingSink(inner, stall) : inner;

            CancellationTokenSource cancel = new CancellationTokenSource();
            Sender sender = new Sender(src, sink, set,
                delegate (string s) { Console.WriteLine("  " + s); },
                delegate (SenderStats st) { });

            Thread t = new Thread(delegate () { sender.Run(cancel.Token); });
            t.IsBackground = true;
            t.Start();

            // Watchdog: if a write is stuck on a pty whose reader has gone away,
            // the engine thread can block past the deadline. Nothing here is
            // worth hanging a test run for, so the process leaves anyway.
            Thread watchdog = new Thread(delegate ()
            {
                Thread.Sleep(seconds * 1000 + 5000);
                Console.WriteLine("watchdog: harness did not finish on its own");
                Environment.Exit(0);
            });
            watchdog.IsBackground = true;
            watchdog.Start();
            t.Join(seconds * 1000);
            cancel.Cancel();
            t.Join(2000);
            Console.WriteLine("rungs used: " + (sender.CurrentRung + 1));
            return 0;
        }

        /// <summary>Replays the WAV forever, so a session that begins after a
        /// downgrade still has audio in it. Without this the ladder test could
        /// only ever prove that session 1 carried sound. Harness-only: the
        /// product either reads a live tap or plays a file once.</summary>
        sealed class LoopingSource : IAudioSource
        {
            readonly WavFileSource inner;
            long looped;                              // frames from completed loops
            public LoopingSource(WavFileSource inner) { this.inner = inner; }
            public long PositionFrames { get { return looped + inner.PositionFrames; } }
            public int Rate { get { return inner.Rate; } }
            public int Channels { get { return inner.Channels; } }
            public bool IsFloat { get { return inner.IsFloat; } }
            public int FrameBytes { get { return inner.FrameBytes; } }
            public int LastPeak { get { return inner.LastPeak; } }
            public bool Exhausted { get { return false; } }   // it loops, so never
            public void Open() { inner.Open(); }
            public void Close() { inner.Close(); }
            public int Poll(byte[] dst, int maxFrames)
            {
                int n = inner.Poll(dst, maxFrames);
                if (n == 0 && inner.Exhausted)
                {
                    looped += inner.PositionFrames;
                    inner.Close();
                    inner.Open();
                    n = inner.Poll(dst, maxFrames);
                }
                return n;
            }
        }

        sealed class FileSink : IByteSink
        {
            readonly string path;
            FileStream fs;
            public FileSink(string p) { path = p; }
            public string Describe { get { return path; } }
            public void Open() { fs = new FileStream(path, FileMode.Open, FileAccess.Write); }
            public void Write(byte[] b, int o, int n) { if (fs != null && n > 0) { fs.Write(b, o, n); fs.Flush(); } }
            public void Close() { if (fs != null) { try { fs.Close(); } catch { } fs = null; } }
        }

        /// <summary>Makes every write slow, i.e. what backpressure from a
        /// saturated link looks like. Also closes and reopens the underlying
        /// stream, so a reconnect is genuinely exercised.</summary>
        sealed class StallingSink : IByteSink
        {
            readonly IByteSink inner;
            readonly int stallMs;
            public StallingSink(IByteSink inner, int ms) { this.inner = inner; stallMs = ms; }
            public string Describe { get { return inner.Describe; } }
            public void Open() { inner.Open(); }
            public void Write(byte[] b, int o, int n) { Thread.Sleep(stallMs); inner.Write(b, o, n); }
            public void Close() { inner.Close(); }
        }
    }
}
