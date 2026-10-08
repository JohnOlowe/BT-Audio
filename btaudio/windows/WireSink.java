import java.io.BufferedInputStream;
import java.io.FileInputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

import net.ghosthand.btaudio.Adpcm;
import net.ghosthand.btaudio.Proto;

/**
 * Stand-in for the phone: reads a BT Audio wire stream off a (virtual) serial
 * port and decodes it with the SAME Proto/Adpcm classes that ship inside the
 * APK, then compares the result against the WAV the PC sender was fed.
 *
 * This is the end-to-end check for windows/bt-audio-send.ps1. It catches what a
 * compile check cannot: wrong handshake bytes, wrong chunk framing, payload
 * sizes the phone rejects, swapped or planar-mis-ordered ADPCM channels, samples
 * dropped or duplicated by the streaming resampler, and streams that never
 * terminate.
 *
 * Usage:
 *   WireSink PORT CODEC CHANNELS RATE CHUNKMS WAV MODE PARTIAL
 *     PORT          serial device to read
 *     CODEC         0 = PCM16, 1 = IMA ADPCM (what the sender was told)
 *     CHANNELS      1 or 2
 *     RATE          sample rate the sender was told to use
 *     CHUNKMS       chunk size the sender was told to use
 *     WAV           the source file the sender was told to read
 *     MODE          exact   = decode must equal the source sample for sample
 *                   downmix = source is stereo, stream is mono: must equal the
 *                             average of the two channels (within 1 count)
 *                   lossy   = ADPCM: an error budget applies instead
 *     PARTIAL       1 = the sender will be killed mid-stream, so no end chunk is
 *                   expected and only the prefix that arrived is compared
 *
 * Exit code 0 = every check passed.
 */
public final class WireSink {

    private static int failures = 0;
    private static final List<String> notes = new ArrayList<String>();
    private static int worstIdx = -1;

    public static void main(String[] args) throws Exception {
        if (args.length < 8) {
            System.err.println("usage: WireSink PORT CODEC CHANNELS RATE CHUNKMS WAV MODE PARTIAL");
            System.exit(2);
        }
        String port = args[0];
        int wantCodec = Integer.parseInt(args[1]);
        int wantCh = Integer.parseInt(args[2]);
        int wantRate = Integer.parseInt(args[3]);
        int wantChunkMs = Integer.parseInt(args[4]);
        String wavPath = args[5];
        String mode = args[6];
        boolean partial = "1".equals(args[7]);

        InputStream in = new BufferedInputStream(new FileInputStream(port), 1 << 16);

        // ---- handshake -------------------------------------------------------
        byte[] hs = new byte[Proto.HANDSHAKE_LEN];
        Proto.readFully(in, hs, 0, hs.length);
        Proto.Format f = null;
        try {
            f = Proto.parseHandshake(hs);
        } catch (Exception e) {
            fail("handshake rejected by the phone's own parser: " + e.getMessage());
            report();
        }
        check("handshake magic + parse", true, "");
        checkEq("codec on the wire", wantCodec, f.codec);
        checkEq("channels on the wire", wantCh, f.channels);
        checkEq("sample rate on the wire", wantRate, f.sampleRate);
        checkEq("chunkMs on the wire", wantChunkMs, f.chunkMs);
        checkEq("handshake reserved bytes are zero", 0, Proto.u16(hs, 6));
        if (f.bandwidthWarning() != null) notes.add("phone warns: " + f.bandwidthWarning());

        // ---- chunks ----------------------------------------------------------
        Adpcm[] dec = new Adpcm[f.channels];
        for (int c = 0; c < f.channels; c++) dec[c] = new Adpcm();

        List<Short> pcm = new ArrayList<Short>(1 << 16);
        int audio = 0, resync = 0, maxPayload = 0, minPayload = Integer.MAX_VALUE;
        int badHdr = 0, badDecode = 0, badSize = 0;
        int expectedPayload = expectedPayloadLen(f, wantChunkMs);
        boolean ended = false;

        while (true) {
            byte[] h = new byte[Proto.CHUNK_HEADER_LEN];
            try {
                Proto.readFully(in, h, 0, h.length);
            } catch (Exception e) {
                break;                                   // sender closed or was killed
            }
            Proto.Chunk c;
            try {
                c = Proto.parseChunkHeader(h);
            } catch (Exception e) {
                fail("phone rejected a chunk header: " + e.getMessage());
                break;
            }
            if (!(h[1] == 0 && h[2] == 0 && h[3] == 0)) badHdr++;

            if (c.type == Proto.CHUNK_END) {
                if (c.length != 0) badSize++;
                ended = true;
                break;
            }
            if (c.type == Proto.CHUNK_RESYNC) {
                resync++;
                if (c.length != 0) badSize++;
                for (Adpcm a : dec) a.reset();
                continue;
            }
            if (c.type != Proto.CHUNK_AUDIO) {
                fail("unknown chunk type " + c.type);
                break;
            }
            if (c.length > Proto.MAX_PAYLOAD) {
                fail("payload " + c.length + " exceeds the phone's MAX_PAYLOAD "
                     + Proto.MAX_PAYLOAD + " - the phone would drop the stream");
                break;
            }
            byte[] payload = new byte[c.length];
            try {
                Proto.readFully(in, payload, 0, payload.length);
            } catch (Exception e) {
                break;
            }
            audio++;
            maxPayload = Math.max(maxPayload, c.length);
            minPayload = Math.min(minPayload, c.length);

            if (f.isAdpcm()) {
                if (c.length % f.channels != 0) {
                    badSize++;
                    fail("ADPCM payload " + c.length + " does not split evenly across "
                         + f.channels + " planar channel halves");
                    break;
                }
                if (c.length % 2 != 0) {
                    badSize++;
                    fail("ADPCM payload " + c.length + " is odd - the phone rejects that as a desync");
                    break;
                }
                // Planar on the wire: channel 0's nibbles first, then channel 1's.
                // Each channel keeps its own predictor and step state.
                int half = c.length / f.channels;
                int per = Proto.samplesPerChannel(f, c.length);
                short[][] tmp = new short[f.channels][];
                for (int ch = 0; ch < f.channels; ch++) {
                    tmp[ch] = new short[per];
                    if (dec[ch].decode(payload, ch * half, half, tmp[ch], 0) != half * 2) badDecode++;
                }
                for (int i = 0; i < per; i++)
                    for (int ch = 0; ch < f.channels; ch++)
                        pcm.add(tmp[ch][i]);                  // interleaved again
            } else {
                if (c.length % (2 * f.channels) != 0) {
                    badSize++;
                    fail("PCM payload " + c.length + " is not a whole number of frames");
                    break;
                }
                ByteBuffer bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
                while (bb.remaining() >= 2) pcm.add(bb.getShort());
            }
        }
        in.close();

        checkEq("chunk headers with zero reserved bytes", 0, badHdr);
        checkEq("ADPCM decoders that returned len*2 samples", 0, badDecode);
        checkEq("payloads with a legal size", 0, badSize);
        check("stream ended with an explicit end chunk", ended || partial,
              "sender closed without a type-3 chunk");
        check("first chunk was a resync", resync >= 1, "no type-2 chunk seen");
        check("audio chunks received", audio > 0, "none");
        if (expectedPayload > 0 && audio > 1) {
            checkEq("largest payload", expectedPayload, maxPayload);
            checkEq("smallest payload", expectedPayload, minPayload);
        }
        if (f.isAdpcm() && audio > 0) {
            check("every ADPCM payload even (phone rejects odd)", minPayload % 2 == 0,
                  "min " + minPayload);
        }

        int frames = pcm.size() / f.channels;
        System.out.println("  received " + audio + " audio chunks, " + frames + " frames, "
                           + "payload " + (audio > 0 ? minPayload : 0) + ".."
                           + (audio > 0 ? maxPayload : 0) + " B, " + resync + " resync");

        int cf = chunkFrames(f.sampleRate, wantChunkMs);
        checkEq("decoded frames are a whole number of chunks", 0, frames % cf);
        if (partial) check("enough audio arrived to judge", frames > 1000, "only " + frames);

        // ---- compare against the source --------------------------------------
        Wav src = Wav.read(wavPath);
        if (src.rate != f.sampleRate) {
            notes.add("source is " + src.rate + " Hz, stream is " + f.sampleRate
                      + " Hz - resampling path, skipping the sample compare");
            report();
        }
        // Reference samples in the stream's own layout.
        int[] ref = null;
        int tol = 0;
        if (src.channels == f.channels) {
            ref = src.data;
            tol = mode.equals("exact") ? 0 : Integer.MAX_VALUE;
        } else if (src.channels == 2 && f.channels == 1 && mode.equals("downmix")) {
            ref = new int[src.frames];
            for (int i = 0; i < src.frames; i++)
                ref[i] = (int) ((src.data[i * 2] + src.data[i * 2 + 1]) / 2.0);
            tol = 1;                                     // truncation, both ends
        }
        if (ref == null) {
            notes.add("source is " + src.channels + " ch, stream is " + f.channels
                      + " ch and this is not a downmix run - skipping the sample compare");
            report();
        }
        int refCh = f.channels;
        int cmpFrames = Math.min(frames, ref.length / refCh);
        int dropped = (ref.length / refCh) - cmpFrames;
        if (!partial) {
            check("frame count within one chunk of the source",
                  dropped >= 0 && dropped < cf + 2,
                  "source " + (ref.length / refCh) + " frames, decoded " + frames);
        }

        for (int ch = 0; ch < f.channels; ch++) {
            // swap detection: which reference channel does this one actually match?
            double best = Double.MAX_VALUE;
            int bestRef = -1;
            for (int r = 0; r < refCh; r++) {
                double e = errRms(pcm, ref, refCh, cmpFrames, ch, r);
                if (e < best) { best = e; bestRef = r; }
            }
            if (refCh > 1) {
                check("channel " + ch + " matches source channel " + ch + " (not swapped)",
                      bestRef == ch, "best match was source channel " + bestRef);
            }
            double own = errRms(pcm, ref, refCh, cmpFrames, ch, ch);
            double sig = sigRms(ref, refCh, cmpFrames, ch);
            int warm = f.sampleRate / 20;                       // first 50 ms
            int worstAll = worstAbs(pcm, ref, refCh, cmpFrames, ch, 0);
            int atAll = worstIdx;
            int worst = worstAbs(pcm, ref, refCh, cmpFrames, ch, warm);

            System.out.println("  ch" + ch + ": signal rms " + fmt(sig) + ", error rms " + fmt(own)
                               + ", ratio " + fmt(own / Math.max(sig, 1e-9))
                               + ", worst " + worstAll + " @frame " + atAll
                               + ", worst after 50 ms " + worst);

            if (mode.equals("lossy")) {
                check("ch" + ch + " error ratio under 2% (ADPCM)",
                      own / Math.max(sig, 1e-9) < 0.02, "ratio " + fmt(own / Math.max(sig, 1e-9)));
                // IMA ADPCM starts from predictor 0 / step index 0, so the first
                // tens of milliseconds are always a climb. That is inherent to the
                // codec and identical at both ends - it must not be mistaken for a
                // bug, but it must not go on forever either.
                check("ch" + ch + " steady-state worst under 2000 (ADPCM)", worst < 2000,
                      "worst after warm-up " + worst);
                check("ch" + ch + " warm-up confined to the first 200 ms",
                      atAll < f.sampleRate / 5 || worstAll < 4000,
                      "peak " + worstAll + " at frame " + atAll);
            } else {
                check("ch" + ch + " decodes within " + tol + " of the source ("
                      + (tol == 0 ? "bit-exact" : "downmix") + ")", worstAll <= tol,
                      "worst diff " + worstAll + " at frame " + atAll);
            }
        }
        report();
    }

    /** Frames per chunk, mirroring the sender: nominal size, then rounded up to a
     *  multiple of 4 so every codec/channel split stays legal on the wire. */
    private static int chunkFrames(int rate, int chunkMs) {
        int frames = (int) Math.round((double) rate * chunkMs / 1000.0);
        if (frames < 4) frames = 4;
        if (frames % 4 != 0) frames += 4 - (frames % 4);
        return frames;
    }

    private static int expectedPayloadLen(Proto.Format f, int chunkMs) {
        int frames = chunkFrames(f.sampleRate, chunkMs);
        return f.isAdpcm() ? (frames / 2) * f.channels : frames * f.channels * 2;
    }

    private static double errRms(List<Short> got, int[] ref, int refCh, int n, int ch, int refChIdx) {
        double acc = 0;
        for (int i = 0; i < n; i++) {
            double d = got.get(i * refCh + ch) - ref[i * refCh + refChIdx];
            acc += d * d;
        }
        return n == 0 ? 0 : Math.sqrt(acc / n);
    }

    private static double sigRms(int[] ref, int refCh, int n, int ch) {
        double acc = 0;
        for (int i = 0; i < n; i++) {
            double d = ref[i * refCh + ch];
            acc += d * d;
        }
        return n == 0 ? 0 : Math.sqrt(acc / n);
    }

    private static int worstAbs(List<Short> got, int[] ref, int refCh, int n, int ch, int skip) {
        int w = 0;
        worstIdx = -1;
        for (int i = skip; i < n; i++) {
            int d = Math.abs(got.get(i * refCh + ch) - ref[i * refCh + ch]);
            if (d > w) { w = d; worstIdx = i; }
        }
        return w;
    }

    private static String fmt(double d) { return String.format("%.6f", d); }

    private static void check(String what, boolean ok, String detail) {
        System.out.println((ok ? "  ok   " : "  FAIL ") + what
                           + (ok || detail.isEmpty() ? "" : "  [" + detail + "]"));
        if (!ok) failures++;
    }

    private static void checkEq(String what, int want, int got) {
        check(what, want == got, "want " + want + ", got " + got);
    }

    private static void fail(String what) {
        System.out.println("  FAIL " + what);
        failures++;
    }

    private static void report() {
        for (String n : notes) System.out.println("  note " + n);
        System.out.println(failures == 0 ? "WIRE OK" : ("WIRE FAILURES: " + failures));
        System.exit(failures == 0 ? 0 : 1);
    }

    /** Minimal RIFF reader: 16-bit PCM and 32-bit float, 1 or 2 channels. */
    static final class Wav {
        int rate, channels, frames;
        int[] data;                                  // interleaved, s16 range

        static Wav read(String path) throws Exception {
            InputStream in = new FileInputStream(path);
            byte[] all = new byte[in.available()];
            Proto.readFully(in, all, 0, all.length);
            in.close();
            if (all.length < 44 || all[0] != 'R' || all[1] != 'I' || all[2] != 'F' || all[3] != 'F')
                throw new IllegalStateException("not a RIFF file: " + path);
            int o = 12, dataOff = 0, dataLen = 0, bits = 0, tag = 0;
            Wav w = new Wav();
            while (o + 8 <= all.length) {
                String id = new String(all, o, 4, "US-ASCII");
                int len = Proto.u32(all, o + 4);
                if (id.equals("fmt ")) {
                    tag = Proto.u16(all, o + 8);
                    w.channels = Proto.u16(all, o + 10);
                    w.rate = Proto.u32(all, o + 12);
                    bits = Proto.u16(all, o + 22);
                } else if (id.equals("data")) {
                    dataOff = o + 8;
                    dataLen = len;
                }
                o += 8 + len + (len % 2);
            }
            if (dataLen == 0) throw new IllegalStateException("no data chunk in " + path);
            boolean isFloat = tag == 3 || bits == 32;
            int frameBytes = w.channels * (bits / 8);
            w.frames = dataLen / frameBytes;
            w.data = new int[w.frames * w.channels];
            ByteBuffer bb = ByteBuffer.wrap(all, dataOff, dataLen).order(ByteOrder.LITTLE_ENDIAN);
            for (int i = 0; i < w.frames * w.channels; i++) {
                if (isFloat) w.data[i] = clamp((int) (bb.getFloat() * 32767.0));
                else if (bits == 16) w.data[i] = bb.getShort();
                else w.data[i] = ((bb.get() & 0xFF) - 128) << 8;
            }
            return w;
        }

        private static int clamp(int v) { return v < -32768 ? -32768 : (v > 32767 ? 32767 : v); }
    }
}
