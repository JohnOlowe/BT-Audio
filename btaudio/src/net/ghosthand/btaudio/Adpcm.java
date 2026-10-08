package net.ghosthand.btaudio;

/**
 * IMA ADPCM decoder, one instance per channel.
 *
 * <p>This is the standard DVI/IMA adaptive algorithm: a 4-bit code carries a
 * difference against a predictor, scaled by a step that grows when the signal
 * is changing fast and shrinks when it is not. 4:1 compression, so 44.1 kHz
 * stereo lands at ~353 kbit/s - comfortably inside what an RFCOMM link holds,
 * which is the whole reason this codec is here rather than raw PCM.
 *
 * <p>Both tables are the ones in the IMA reference implementation. They are
 * duplicated verbatim in windows/bt-audio-send.ps1's encoder, and
 * AdpcmTest round-trips the two against each other so a typo in either shows
 * up as a test failure rather than as noise in someone's ears.
 *
 * <p>Not thread-safe and deliberately so: each channel gets its own instance on
 * the single reader thread.
 */
public final class Adpcm {

    /** Step size for each of the 89 index values. */
    public static final int[] STEP_TABLE = {
          7,     8,     9,    10,    11,    12,    13,    14,    16,    17,
         19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
         50,    55,    60,    66,    73,    80,    88,    97,   107,   118,
        130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
        337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
        876,   965,  1065,  1175,  1297,  1432,  1580,  1743,  1925,  2126,
       2349,  2596,  2868,  3168,  3499,  3864,  4268,  4715,  5209,  5755,
       6358,  7024,  7759,  8569,  9462, 10447, 11533, 12729, 14047, 15497,
      17089, 18843, 20769, 22878, 25188, 27729, 30518, 33741, 37267
    };

    /**
     * How each nibble moves the step index: codes 0-3 and 8-11 shrink it,
     * 4-7 and 12-15 grow it by an amount proportional to how big the code's
     * magnitude bits are. The growing entries are 2,4,6,8 - NOT a flat 2 -
     * because a code that needed the full step must make the step grow hard,
     * or the predictor can never catch up to a loud signal and trails it by
     * tens of thousands of counts. This was wrong once, and the sine round-trip
     * test caught it as a 11753-count error on a signal peaking at 12000.
     */
    public static final int[] INDEX_TABLE = {
        -1, -1, -1, -1,  2,  4,  6,  8,
        -1, -1, -1, -1,  2,  4,  6,  8
    };

    public static final int MAX_INDEX = 88;

    private int predictor;
    private int stepIndex;

    public Adpcm() { reset(); }

    /**
     * Return to the initial state. Called on stream start and on every resync
     * chunk. The PC encoder does the same at the same moments; that agreement
     * is what keeps the two ends in step.
     */
    public void reset() {
        predictor = 0;
        stepIndex = 0;
    }

    public int predictor() { return predictor; }

    public int stepIndex() { return stepIndex; }

    /**
     * Decode one nibble and advance the adaptive state.
     *
     * <p>Note the ordering: the difference is accumulated from the most
     * significant contribution down, and the sign bit (0x8) is applied last by
     * negating the sum. Getting this order wrong produces audio that is
     * recognisably the right shape at the wrong amplitude, which is the
     * classic symptom of a broken ADPCM implementation.
     */
    private short decodeNibble(int nib) {
        int step = STEP_TABLE[stepIndex];
        int diff = step >> 3;
        if ((nib & 4) != 0) diff += step;
        if ((nib & 2) != 0) diff += step >> 1;
        if ((nib & 1) != 0) diff += step >> 2;
        if ((nib & 8) != 0) diff = -diff;

        int p = predictor + diff;
        if (p > 32767) p = 32767;
        else if (p < -32768) p = -32768;
        predictor = p;

        stepIndex += INDEX_TABLE[nib];
        if (stepIndex < 0) stepIndex = 0;
        else if (stepIndex > MAX_INDEX) stepIndex = MAX_INDEX;

        return (short) predictor;
    }

    /**
     * Decode {@code len} bytes of nibbles into {@code len * 2} 16-bit samples.
     * The low nibble of each byte is the earlier of its two samples.
     *
     * @param out must have room for at least {@code outOff + len * 2} shorts
     * @return the number of samples written, i.e. {@code len * 2}
     */
    public int decode(byte[] in, int inOff, int len, short[] out, int outOff) {
        int n = 0;
        for (int i = 0; i < len; i++) {
            int b = in[inOff + i] & 0xFF;
            out[outOff + n++] = decodeNibble(b & 0x0F);
            out[outOff + n++] = decodeNibble(b >>> 4);
        }
        return n;
    }

    /**
     * Encode {@code sampleCount} 16-bit samples into {@code sampleCount / 2}
     * bytes. Present so the JVM unit test can round-trip through the exact same
     * arithmetic the PC encoder uses, rather than trusting a transcription.
     * An odd sample count encodes the last sample with a zero pad nibble, which
     * is why the wire format requires even counts per channel.
     */
    public int encode(short[] in, int inOff, int sampleCount, byte[] out, int outOff) {
        int written = 0;
        for (int i = 0; i < sampleCount; i += 2) {
            int lo = encodeNibble(in[inOff + i]);
            int hi = (i + 1 < sampleCount) ? encodeNibble(in[inOff + i + 1]) : 0;
            out[outOff + written++] = (byte) ((lo & 0x0F) | ((hi & 0x0F) << 4));
        }
        return written;
    }

    private int encodeNibble(int sample) {
        int step = STEP_TABLE[stepIndex];
        int diff = sample - predictor;
        int code = 0;
        if (diff < 0) { code = 8; diff = -diff; }
        if (diff >= step)      { code |= 4; diff -= step; }
        if (diff >= (step >> 1)) { code |= 2; diff -= step >> 1; }
        if (diff >= (step >> 2)) { code |= 1; }
        // The encoder must advance its state by REPLAYING the code it just
        // produced, not by using the original sample. Otherwise the decoder -
        // which only ever sees the code - diverges immediately.
        decodeNibble(code);
        return code;
    }
}
