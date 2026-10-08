package net.ghosthand.btaudio;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;

/**
 * The wire format, shared byte-for-byte with the PC sender
 * (windows/bt-audio-send.ps1). Everything is little-endian.
 *
 * <p>The PC connects to the phone's RFCOMM service and immediately writes a
 * 16-byte handshake describing the stream, then a sequence of chunks: an
 * 8-byte header followed by that many payload bytes.
 *
 * <pre>
 * HANDSHAKE (16 bytes)
 *   0  u32  magic       'B','T','A','1'
 *   4  u8   codec       0 = PCM s16le, 1 = IMA ADPCM
 *   5  u8   channels    1 or 2
 *   6  u16  reserved    ignored, send 0
 *   8  u32  sampleRate  Hz
 *  12  u32  chunkMs     nominal milliseconds of audio per chunk (informational)
 *
 * CHUNK HEADER (8 bytes)
 *   0  u8   type        1 = audio, 2 = resync, 3 = end of stream
 *   1  u8   reserved
 *   2  u16  reserved
 *   4  u32  length      payload bytes that follow
 * </pre>
 *
 * <p>ADPCM payloads are <b>planar</b>: in a stereo chunk the first half of the
 * payload holds channel 0's nibbles and the second half holds channel 1's, each
 * with its own predictor and step index. Both halves are therefore always the
 * same size, and each half carries {@code (length / channels) * 2} samples. The
 * low nibble of each byte is the earlier sample.
 *
 * <p>A resync chunk (type 2) carries no payload and tells the decoder to reset
 * its adaptive state. It exists because IMA ADPCM is differential: if the two
 * ends ever disagree about the state, every later sample is wrong until
 * something resets it. RFCOMM is reliable, so this should never be needed, but
 * a chunk boundary is the only safe place to recover.
 *
 * <p>This class is deliberately free of android.* so it can be unit-tested on
 * the JVM.
 */
public final class Proto {

    /** 'B','T','A','1' read as a little-endian u32. */
    public static final int MAGIC = 0x31415442;

    public static final int CODEC_PCM16 = 0;
    public static final int CODEC_ADPCM = 1;

    public static final int CHUNK_AUDIO = 1;
    public static final int CHUNK_RESYNC = 2;
    public static final int CHUNK_END = 3;

    public static final int HANDSHAKE_LEN = 16;
    public static final int CHUNK_HEADER_LEN = 8;

    /** Reject anything bigger than this before allocating: a corrupt length
     *  field must not be able to make us allocate a gigabyte. 256 KiB is about
     *  1.5 s of the heaviest stream we accept, and roughly a hundred times the
     *  ~20 ms chunk the PC sender actually emits - so this only ever fires on a
     *  desynced stream, never on a legitimate one. */
    public static final int MAX_PAYLOAD = 1 << 18;

    /** Hard ceiling on what we will accept as a sample rate. AudioTrack itself
     *  rejects out-of-range rates, but failing here gives a better message. */
    public static final int MIN_RATE = 4000;
    public static final int MAX_RATE = 192000;

    private Proto() { }

    /** What the handshake said. Immutable once parsed. */
    public static final class Format {
        public final int codec;
        public final int channels;
        public final int sampleRate;
        public final int chunkMs;

        Format(int codec, int channels, int sampleRate, int chunkMs) {
            this.codec = codec;
            this.channels = channels;
            this.sampleRate = sampleRate;
            this.chunkMs = chunkMs;
        }

        public boolean isAdpcm() { return codec == CODEC_ADPCM; }

        /**
         * Bytes per second of wire data, which is what the Bluetooth link has
         * to carry. Useful for telling the user why a stream stutters.
         * PCM16 costs 2 bytes per sample per channel; ADPCM costs half a byte
         * (4 bits), which is the entire reason the codec is here.
         */
        public long wireBytesPerSecond() {
            long samples = (long) sampleRate * channels;
            return isAdpcm() ? samples / 2 : samples * 2;
        }

        public String describe() {
            String c = codec == CODEC_ADPCM ? "IMA-ADPCM"
                     : codec == CODEC_PCM16 ? "PCM16"
                     : "codec " + codec;
            return sampleRate + " Hz, " + channels + " ch, " + c;
        }

        /** A human-facing note when the requested rate is likely to outrun an
         *  RFCOMM link. Purely advisory; we still try to play it. */
        public String bandwidthWarning() {
            long kbps = wireBytesPerSecond() * 8 / 1000;
            if (kbps > 900) {
                return kbps + " kbit/s: above what Bluetooth RFCOMM usually "
                     + "sustains (~1 Mbit/s). Expect dropouts; use ADPCM or "
                     + "a lower sample rate.";
            }
            if (kbps > 450) {
                return kbps + " kbit/s: near the practical RFCOMM ceiling.";
            }
            return null;
        }
    }

    /** A chunk header. */
    public static final class Chunk {
        public final int type;
        public final int length;

        Chunk(int type, int length) { this.type = type; this.length = length; }
    }

    // --- little-endian readers -------------------------------------------

    public static int u8(byte[] b, int off) { return b[off] & 0xFF; }

    public static int u16(byte[] b, int off) {
        return (b[off] & 0xFF) | ((b[off + 1] & 0xFF) << 8);
    }

    public static int u32(byte[] b, int off) {
        return (b[off] & 0xFF)
             | ((b[off + 1] & 0xFF) << 8)
             | ((b[off + 2] & 0xFF) << 16)
             | ((b[off + 3] & 0xFF) << 24);
    }

    /**
     * Read exactly {@code len} bytes or die trying. InputStream.read() is
     * allowed to return short, and treating a short read as end-of-stream is
     * the single most common bug in this kind of code: it turns a split TCP
     * segment into a silent corruption.
     */
    public static void readFully(InputStream in, byte[] buf, int off, int len)
            throws IOException {
        int done = 0;
        while (done < len) {
            int n = in.read(buf, off + done, len - done);
            if (n < 0) {
                throw new EOFException("stream ended after " + done + " of "
                        + len + " bytes");
            }
            done += n;
        }
    }

    /**
     * Parse a handshake.
     *
     * @throws IllegalArgumentException if the magic is wrong or the declared
     *         format is one we cannot play. The message is shown to the user,
     *         so it names the field that was bad.
     */
    public static Format parseHandshake(byte[] h) {
        if (h.length < HANDSHAKE_LEN) {
            throw new IllegalArgumentException("handshake too short: " + h.length);
        }
        int magic = u32(h, 0);
        if (magic != MAGIC) {
            throw new IllegalArgumentException(String.format(
                    "bad magic 0x%08X (expected 0x%08X 'BTA1'). Whatever "
                    + "connected is not the PC sender.", magic, MAGIC));
        }
        int codec = u8(h, 4);
        if (codec != CODEC_PCM16 && codec != CODEC_ADPCM) {
            throw new IllegalArgumentException("unknown codec " + codec);
        }
        int channels = u8(h, 5);
        if (channels < 1 || channels > 2) {
            throw new IllegalArgumentException(
                    "channels must be 1 or 2, got " + channels);
        }
        int rate = u32(h, 8);
        if (rate < MIN_RATE || rate > MAX_RATE) {
            throw new IllegalArgumentException(
                    "sample rate " + rate + " Hz out of range "
                    + MIN_RATE + ".." + MAX_RATE);
        }
        int chunkMs = u32(h, 12);
        return new Format(codec, channels, rate, chunkMs);
    }

    /** Parse a chunk header, validating the length before anyone allocates. */
    public static Chunk parseChunkHeader(byte[] h) {
        if (h.length < CHUNK_HEADER_LEN) {
            throw new IllegalArgumentException("chunk header too short");
        }
        int type = u8(h, 0);
        int length = u32(h, 4);
        if (length < 0 || length > MAX_PAYLOAD) {
            throw new IllegalArgumentException(
                    "absurd payload length " + length + " - stream desynced");
        }
        if (type == CHUNK_AUDIO && (length & 1) != 0) {
            // Planar ADPCM needs an even split; PCM16 needs an even byte count.
            // Both make an odd length impossible, so this is always a desync.
            throw new IllegalArgumentException(
                    "odd payload length " + length + " - stream desynced");
        }
        return new Chunk(type, length);
    }

    /**
     * Samples per channel in an audio payload.
     * PCM16 is 2 bytes/sample; ADPCM is 2 samples/byte. Planar, so divide by
     * the channel count first.
     */
    public static int samplesPerChannel(Format f, int payloadLen) {
        int perChannel = payloadLen / f.channels;
        return f.isAdpcm() ? perChannel * 2 : perChannel / 2;
    }
}
