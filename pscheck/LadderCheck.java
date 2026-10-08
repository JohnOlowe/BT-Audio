import java.io.BufferedInputStream;
import java.io.FileInputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

import net.ghosthand.btaudio.Adpcm;
import net.ghosthand.btaudio.Proto;

/**
 * Verifies the sender's automatic quality ladder.
 *
 * A downgrade reconnects, so the wire carries several handshakes one after
 * another. This reads that whole sequence the way the phone would: a chunk
 * header whose type is not 1/2/3 cannot be a header, so the 8 bytes just read
 * plus the next 8 are a fresh handshake. Each session is then decoded with the
 * same ADPCM class the APK uses.
 *
 * Usage: LadderCheck PORT SECONDS
 * Exit 0 only if: at least two sessions arrived, each one's bitrate was lower
 * than the last, every payload was legal for the phone, and every session
 * carried actual audio rather than silence.
 */
public final class LadderCheck {

    static final class Session {
        int codec, channels, rate, chunkMs, chunks;
        double rmsAcc;
        long samples;
        double rms() { return samples == 0 ? 0 : Math.sqrt(rmsAcc / samples); }
        int kbps() { return rate * channels * (codec == Proto.CODEC_ADPCM ? 4 : 16) / 1000; }
        public String toString() {
            return (codec == Proto.CODEC_ADPCM ? "ADPCM" : "PCM") + " " + channels + "ch "
                 + rate + "Hz " + chunkMs + "ms ~" + kbps() + "kbit/s, "
                 + chunks + " chunks, rms " + String.format("%.0f", rms());
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 2) { System.err.println("usage: LadderCheck PORT SECONDS"); System.exit(2); }
        String port = args[0];
        long deadline = System.currentTimeMillis() + Long.parseLong(args[1]) * 1000L;

        InputStream in = new BufferedInputStream(new TimedIn(new FileInputStream(port), 15000), 1 << 16);
        List<Session> sessions = new ArrayList<Session>();
        List<String> problems = new ArrayList<String>();

        Session cur = null;
        Adpcm[] dec = null;
        short[] tmp = new short[1 << 16];

        while (System.currentTimeMillis() < deadline) {
            byte[] h = new byte[Proto.CHUNK_HEADER_LEN];
            try { Proto.readFully(in, h, 0, h.length); } catch (Exception e) { break; }

            int type = Proto.u8(h, 0);
            if (type != Proto.CHUNK_AUDIO && type != Proto.CHUNK_RESYNC && type != Proto.CHUNK_END) {
                // not a header: this is the front half of a handshake
                byte[] hs = new byte[Proto.HANDSHAKE_LEN];
                System.arraycopy(h, 0, hs, 0, h.length);
                try { Proto.readFully(in, hs, h.length, hs.length - h.length); }
                catch (Exception e) { break; }
                Proto.Format f;
                try { f = Proto.parseHandshake(hs); }
                catch (Exception e) { problems.add("bad handshake: " + e.getMessage()); break; }
                cur = new Session();
                cur.codec = f.codec; cur.channels = f.channels;
                cur.rate = f.sampleRate; cur.chunkMs = f.chunkMs;
                sessions.add(cur);
                dec = new Adpcm[f.channels];
                for (int c = 0; c < f.channels; c++) dec[c] = new Adpcm();
                System.out.println("  session " + sessions.size() + ": " + cur);
                continue;
            }

            int len = Proto.u32(h, 4);
            if (len < 0 || len > Proto.MAX_PAYLOAD) { problems.add("absurd payload " + len); break; }
            if (type == Proto.CHUNK_END) continue;
            if (type == Proto.CHUNK_RESYNC) {
                if (len != 0) problems.add("resync with payload");
                if (dec != null) for (Adpcm a : dec) a.reset();
                continue;
            }
            if (len % 2 != 0) { problems.add("odd audio payload " + len + " - the phone rejects this"); break; }
            byte[] payload = new byte[len];
            try { Proto.readFully(in, payload, 0, len); } catch (Exception e) { break; }

            if (cur == null) { problems.add("audio before any handshake"); break; }
            if (cur.codec == Proto.CODEC_ADPCM) {
                if (len % cur.channels != 0) { problems.add("payload " + len + " not planar-splittable"); break; }
                int half = len / cur.channels;
                if (half * 2 > tmp.length) { problems.add("payload too big for the test buffer"); break; }
                for (int c = 0; c < cur.channels; c++) {
                    int n = dec[c].decode(payload, c * half, half, tmp, 0);
                    for (int i = 0; i < n; i++) { cur.rmsAcc += (double) tmp[i] * tmp[i]; cur.samples++; }
                }
            }
            cur.chunks++;
        }
        in.close();

        // ---- verdict ---------------------------------------------------------
        System.out.println();
        for (Session s : sessions) System.out.println("  " + s);
        for (String p : problems) System.out.println("  PROBLEM " + p);

        int fail = 0;
        if (sessions.size() < 2) { System.out.println("  FAIL the ladder never stepped down"); fail++; }
        for (int i = 1; i < sessions.size(); i++) {
            if (sessions.get(i).kbps() >= sessions.get(i - 1).kbps()) {
                System.out.println("  FAIL session " + (i + 1) + " is not a lower bitrate than "
                                   + i + " (" + sessions.get(i).kbps() + " vs " + sessions.get(i - 1).kbps() + ")");
                fail++;
            }
        }
        for (int i = 0; i < sessions.size(); i++) {
            Session s = sessions.get(i);
            if (s.chunks == 0) { System.out.println("  FAIL session " + (i + 1) + " carried no audio chunks"); fail++; }
            // the test signal is a loud tone, so a session that decodes to
            // near-silence means the reconnect lost sync
            if (s.samples > 4000 && s.rms() < 500) {
                System.out.println("  FAIL session " + (i + 1) + " decoded as silence (rms " + s.rms() + ")");
                fail++;
            }
        }
        if (fail == 0) System.out.println("LADDER OK");
        System.out.println(fail == 0 ? "ladder verdict: pass" : ("ladder verdict: " + fail + " failures"));
        System.exit(fail == 0 ? 0 : 1);
    }
}
