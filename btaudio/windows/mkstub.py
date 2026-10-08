#!/usr/bin/env python3
"""mkstub.py TARGET OUT

Writes a copy of the BT-audio sender in which the WASAPI loopback class is
replaced by a stub that reads a WAV file named by the BTAUDIO_FAKE_WAV
environment variable and hands it out 10 ms at a time, exactly like a real
capture client does.

Everything else in the script is untouched, so this exercises the *streaming*
branch - the fractional resampler cursor, the unconsumed-tail carry, the chunk
accumulator and the real emit path - which `-Mode File` never reaches. That
branch is what runs on the user's machine, and it is the part with the most
bookkeeping to get subtly wrong.

The stub keeps the real class's public surface byte-for-byte:
    SrcRate, SrcChannels, SrcIsFloat, FrameBytes, Open(), Poll(dst, dstOffFrames,
    maxFrames) -> frames appended, Dispose()
"""
import re
import sys

START = "    public sealed class Wasapi : IDisposable {"
END = "    public static class Conv {"

STUB = r'''    // TEST STUB - stands in for WASAPI loopback so the streaming branch can be
    // exercised on a machine with no Windows audio stack. Same public surface as
    // the real class, so nothing else in the script knows the difference.
    public sealed class Wasapi : IDisposable {
        public int SrcRate, SrcChannels;
        public bool SrcIsFloat;
        public int FrameBytes { get { return SrcChannels * (SrcIsFloat ? 4 : 2); } }

        byte[] data;
        int dataOff, dataLen, pos, perPoll;

        public void Open() {
            string path = Environment.GetEnvironmentVariable("BTAUDIO_FAKE_WAV");
            if (path == null || path.Length == 0)
                throw new InvalidOperationException("BTAUDIO_FAKE_WAV is not set");
            byte[] raw = File.ReadAllBytes(path);
            if (raw.Length < 44) throw new InvalidOperationException("WAV too short");
            int o = 12, bits = 0, tag = 0;
            dataOff = 0; dataLen = 0;
            while (o + 8 <= raw.Length) {
                string id = Encoding.ASCII.GetString(raw, o, 4);
                int len = BitConverter.ToInt32(raw, o + 4);
                if (id == "fmt ") {
                    tag = BitConverter.ToUInt16(raw, o + 8);
                    SrcChannels = BitConverter.ToUInt16(raw, o + 10);
                    SrcRate = BitConverter.ToInt32(raw, o + 12);
                    bits = BitConverter.ToUInt16(raw, o + 22);
                } else if (id == "data") {
                    dataOff = o + 8;
                    dataLen = len;
                }
                o += 8 + len + (len % 2);
            }
            if (dataLen == 0) throw new InvalidOperationException("no data chunk");
            SrcIsFloat = tag == 3 || bits == 32;
            pos = 0;
            perPoll = SrcRate / 100;                     // 10 ms per wake-up
            if (perPoll < 1) perPoll = 1;
            data = raw;
        }

        /// Frames appended, like the real capture client. Sleeps the length of
        /// the audio it returns so the sender's own pacing is what's under test.
        public int Poll(byte[] dst, int dstOffFrames, int maxFrames) {
            int avail = (dataLen / FrameBytes) - pos;
            if (avail <= 0) return 0;
            int n = Math.Min(Math.Min(avail, maxFrames), perPoll);
            if (n <= 0) return 0;
            Array.Copy(data, dataOff + pos * FrameBytes, dst, dstOffFrames * FrameBytes,
                       n * FrameBytes);
            pos += n;
            System.Threading.Thread.Sleep(n * 1000 / SrcRate);
            return n;
        }

        public void Dispose() { }
    }

'''


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: mkstub.py TARGET OUT")
    src, out = sys.argv[1], sys.argv[2]
    s = open(src, encoding="utf-8").read()
    if s.count(START) != 1 or s.count(END) != 1:
        sys.exit("markers not found exactly once - the script's layout changed; "
                 "fix mkstub.py rather than guessing")
    i, j = s.index(START), s.index(END)
    if not i < j:
        sys.exit("markers in unexpected order")
    s = s[:i] + STUB + s[j:]

    # the stub needs these, and only these, extra usings
    if "using System.IO;" not in s:
        s = re.sub(r"(using System;\n)", r"\1using System.IO;\n", s, count=1)
    if "using System.Text;" not in s:
        s = re.sub(r"(using System;\n)", r"\1using System.Text;\n", s, count=1)

    open(out, "w", encoding="utf-8").write(s)
    print("wrote %s (%d chars, Wasapi stubbed)" % (out, len(s)))


if __name__ == "__main__":
    main()
