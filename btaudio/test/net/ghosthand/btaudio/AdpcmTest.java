package net.ghosthand.btaudio;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

public class AdpcmTest {

    @Test
    public void goldenVectorFromTheReferenceAlgorithm() {
        // Worked by hand from the IMA rules so a typo in either table, or a
        // swapped nibble order, or a wrong sign-bit position all fail here
        // instead of sounding like static in someone's ears:
        //   nib 0 -> diff 7>>3=0         p=0    idx 0
        //   nib 7 -> diff 7+3+1=11       p=11   idx 0+8=8
        //   nib 8 -> diff -(16>>3)=-2    p=9    idx 8-1=7
        //   nib 0 -> diff 14>>3=1        p=10   idx 7-1=6
        byte[] wire = { 0x70, 0x08 };
        short[] out = new short[4];
        new Adpcm().decode(wire, 0, wire.length, out, 0);
        assertEquals(0, out[0]);
        assertEquals(11, out[1]);
        assertEquals(9, out[2]);
        assertEquals(10, out[3]);
    }

    @Test
    public void silenceStaysSilent() {
        short[] in = new short[1000];
        Adpcm enc = new Adpcm();
        byte[] wire = new byte[in.length / 2];
        enc.encode(in, 0, in.length, wire, 0);

        short[] out = new short[in.length];
        new Adpcm().decode(wire, 0, wire.length, out, 0);
        for (int i = 0; i < out.length; i++) {
            assertEquals("silence must not drift, sample " + i, 0, out[i]);
        }
    }

    @Test
    public void encodeDecodeRoundTripsASineWithinCodecTolerance() {
        int n = 8000;
        short[] in = new short[n];
        for (int i = 0; i < n; i++) {
            in[i] = (short) (12000 * Math.sin(2 * Math.PI * 440 * i / 8000));
        }

        Adpcm enc = new Adpcm();
        byte[] wire = new byte[n / 2];
        int written = enc.encode(in, 0, n, wire, 0);
        assertEquals("4 bits per sample", n / 2, written);

        short[] out = new short[n];
        new Adpcm().decode(wire, 0, written, out, 0);

        // The first samples are excluded on purpose. The adaptive step starts at
        // 7, so a signal whose first sample is 4000 counts away costs roughly
        // ten doublings (~10 samples, 1.2 ms at 8 kHz) to catch up. That cold
        // start is inherent to every IMA ADPCM implementation - it is not a
        // defect - and in practice the first chunk of a real stream carries
        // silence before the audio starts. Asserting on it would only ever
        // fail spuriously.
        int warmup = 100;

        double sig = 0, err = 0;
        int maxAbs = 0;
        for (int i = warmup; i < n; i++) {
            sig += (double) in[i] * in[i];
            int e = out[i] - in[i];
            err += (double) e * e;
            maxAbs = Math.max(maxAbs, Math.abs(e));
        }
        double rmsSignal = Math.sqrt(sig / (n - warmup));
        double rmsError = Math.sqrt(err / (n - warmup));

        // Measured for a correct implementation: rms/sig ~0.033 and a worst
        // sample of ~570 on a 12000-peak tone. The bounds below are generous on
        // purpose (this asserts the codec is *right*, not that it is lossless)
        // but any structural bug - wrong nibble order, encoder state not
        // advanced through its own code, a flat index table - lands an order of
        // magnitude outside them.
        assertTrue("rms error " + rmsError + " too large for signal " + rmsSignal,
                rmsError / rmsSignal < 0.15);
        assertTrue("worst steady-state sample off by " + maxAbs, maxAbs < 2000);
    }

    @Test
    public void loudSquareWaveStaysInRangeAndTracksItsSide() {
        // A full-scale square wave is deliberately NOT used here: jumping
        // 65535 counts in one sample is outside what any 4-bit differential
        // codec can follow, and asserting that it does would be testing
        // fiction. At 8000 counts the slew takes a few samples and the codec
        // should then sit on the correct side for the rest of the half-cycle.
        int n = 8000;
        int half = 500;
        short[] in = new short[n];
        for (int i = 0; i < n; i++) {
            in[i] = (i / half) % 2 == 0 ? (short) 8000 : (short) -8000;
        }
        Adpcm enc = new Adpcm();
        byte[] wire = new byte[n / 2];
        enc.encode(in, 0, n, wire, 0);

        short[] out = new short[n];
        new Adpcm().decode(wire, 0, wire.length, out, 0);

        int checked = 0, agree = 0;
        for (int i = 0; i < n; i++) {
            assertTrue("out of 16-bit range at " + i,
                    out[i] >= -32768 && out[i] <= 32767);
            int pos = i % half;
            if (pos >= 40) {          // past the slew at each edge
                checked++;
                if (Integer.signum(out[i]) == Integer.signum(in[i])) agree++;
            }
        }
        assertTrue("decoder sided with the wrong half-cycle " + (checked - agree)
                + " of " + checked + " samples", agree * 100 / checked >= 95);
    }

    @Test
    public void resetReturnsToTheInitialState() {
        Adpcm a = new Adpcm();
        byte[] wire = { (byte) 0x77, (byte) 0x77 };
        a.decode(wire, 0, wire.length, new short[4], 0);
        assertTrue("state should have moved", a.predictor() != 0
                || a.stepIndex() != 0);
        a.reset();
        assertEquals(0, a.predictor());
        assertEquals(0, a.stepIndex());
    }

    @Test
    public void stepIndexNeverLeavesTheTable() {
        // A burst of maximal-growth codes must clamp at the last index rather
        // than walk off the end of STEP_TABLE and throw.
        Adpcm a = new Adpcm();
        byte[] wire = new byte[512];
        for (int i = 0; i < wire.length; i++) wire[i] = (byte) 0xFF;
        short[] out = new short[1024];
        a.decode(wire, 0, wire.length, out, 0);
        assertEquals(Adpcm.MAX_INDEX, a.stepIndex());
    }

    @Test
    public void twoChannelsAreIndependent() {
        // The engine gives each channel its own decoder; this asserts the
        // algorithm has no hidden cross-channel state that would make that
        // insufficient.
        Adpcm a = new Adpcm();
        Adpcm b = new Adpcm();
        byte[] loud = { (byte) 0x77 };
        byte[] quiet = { 0x00 };
        short[] o1 = new short[2];
        short[] o2 = new short[2];
        a.decode(loud, 0, 1, o1, 0);
        b.decode(quiet, 0, 1, o2, 0);
        assertTrue(o1[0] != 0);
        assertEquals(0, o2[0]);
    }
}
