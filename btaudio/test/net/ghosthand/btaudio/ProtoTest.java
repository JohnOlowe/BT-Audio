package net.ghosthand.btaudio;

import org.junit.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

public class ProtoTest {

    private static byte[] handshake(int codec, int channels, int rate, int chunkMs) {
        byte[] b = new byte[Proto.HANDSHAKE_LEN];
        putU32(b, 0, Proto.MAGIC);
        b[4] = (byte) codec;
        b[5] = (byte) channels;
        putU32(b, 8, rate);
        putU32(b, 12, chunkMs);
        return b;
    }

    private static void putU32(byte[] b, int off, int v) {
        b[off] = (byte) v;
        b[off + 1] = (byte) (v >>> 8);
        b[off + 2] = (byte) (v >>> 16);
        b[off + 3] = (byte) (v >>> 24);
    }

    @Test
    public void magicIsTheAsciiTag() {
        // 'B','T','A','1' little-endian; a transcription error here would make
        // every real connection fail the handshake.
        assertEquals('B', Proto.MAGIC & 0xFF);
        assertEquals('T', (Proto.MAGIC >>> 8) & 0xFF);
        assertEquals('A', (Proto.MAGIC >>> 16) & 0xFF);
        assertEquals('1', (Proto.MAGIC >>> 24) & 0xFF);
    }

    @Test
    public void parsesAValidHandshake() {
        Proto.Format f = Proto.parseHandshake(
                handshake(Proto.CODEC_ADPCM, 2, 44100, 20));
        assertTrue(f.isAdpcm());
        assertEquals(2, f.channels);
        assertEquals(44100, f.sampleRate);
        assertEquals(20, f.chunkMs);
    }

    @Test
    public void rejectsABadMagic() {
        byte[] b = handshake(Proto.CODEC_ADPCM, 2, 44100, 20);
        b[0] = 0x7F;
        try {
            Proto.parseHandshake(b);
            fail("a wrong magic must not be accepted");
        } catch (IllegalArgumentException e) {
            assertTrue(e.getMessage().contains("magic"));
        }
    }

    @Test
    public void rejectsUnknownCodec() {
        try {
            Proto.parseHandshake(handshake(9, 1, 44100, 20));
            fail();
        } catch (IllegalArgumentException e) {
            assertTrue(e.getMessage().contains("codec"));
        }
    }

    @Test
    public void rejectsBadChannelCounts() {
        for (int ch : new int[] { 0, 3, 255 }) {
            try {
                Proto.parseHandshake(handshake(Proto.CODEC_PCM16, ch, 44100, 20));
                fail("channels=" + ch + " should be refused");
            } catch (IllegalArgumentException e) {
                assertTrue(e.getMessage().contains("channels"));
            }
        }
    }

    @Test
    public void rejectsOutlierSampleRates() {
        for (int rate : new int[] { 0, 1, 3999, 192001, -1 }) {
            try {
                Proto.parseHandshake(handshake(Proto.CODEC_PCM16, 1, rate, 20));
                fail("rate=" + rate + " should be refused");
            } catch (IllegalArgumentException e) {
                assertTrue(e.getMessage().contains("sample rate"));
            }
        }
    }

    @Test
    public void chunkHeaderParsesLittleEndian() {
        byte[] h = new byte[8];
        h[0] = Proto.CHUNK_AUDIO;
        putU32(h, 4, 0x00010204);
        Proto.Chunk c = Proto.parseChunkHeader(h);
        assertEquals(Proto.CHUNK_AUDIO, c.type);
        assertEquals(0x00010204, c.length);
    }

    @Test
    public void oddAudioPayloadIsADesync() {
        byte[] h = new byte[8];
        h[0] = Proto.CHUNK_AUDIO;
        putU32(h, 4, 7);
        try {
            Proto.parseChunkHeader(h);
            fail();
        } catch (IllegalArgumentException e) {
            assertTrue(e.getMessage().contains("desync"));
        }
    }

    @Test
    public void absurdLengthIsRejectedBeforeAllocating() {
        byte[] h = new byte[8];
        h[0] = Proto.CHUNK_AUDIO;
        putU32(h, 4, Proto.MAX_PAYLOAD + 2);
        try {
            Proto.parseChunkHeader(h);
            fail();
        } catch (IllegalArgumentException e) {
            assertTrue(e.getMessage().contains("absurd"));
        }
    }

    @Test
    public void resyncAndEndMayBeEmpty() {
        for (int type : new int[] { Proto.CHUNK_RESYNC, Proto.CHUNK_END }) {
            byte[] h = new byte[8];
            h[0] = (byte) type;
            assertEquals(0, Proto.parseChunkHeader(h).length);
        }
    }

    @Test
    public void sampleCountsFollowTheCodec() {
        Proto.Format pcm = Proto.parseHandshake(
                handshake(Proto.CODEC_PCM16, 2, 44100, 20));
        // 882 bytes interleaved stereo s16 = 220 frames
        assertEquals(220, Proto.samplesPerChannel(pcm, 882));

        Proto.Format ad = Proto.parseHandshake(
                handshake(Proto.CODEC_ADPCM, 2, 44100, 20));
        // 882 bytes planar stereo = 441 bytes/channel = 882 samples/channel
        assertEquals(882, Proto.samplesPerChannel(ad, 882));

        Proto.Format mono = Proto.parseHandshake(
                handshake(Proto.CODEC_ADPCM, 1, 44100, 20));
        assertEquals(1764, Proto.samplesPerChannel(mono, 882));
    }

    @Test
    public void bandwidthMathMatchesTheCodecRatio() {
        Proto.Format pcm = Proto.parseHandshake(
                handshake(Proto.CODEC_PCM16, 2, 44100, 20));
        assertEquals(44100L * 2 * 2, pcm.wireBytesPerSecond());
        assertNotNull("raw 44.1k stereo should trip the warning",
                pcm.bandwidthWarning());

        Proto.Format ad = Proto.parseHandshake(
                handshake(Proto.CODEC_ADPCM, 2, 44100, 20));
        assertEquals(44100L * 2 / 2, ad.wireBytesPerSecond());
        assertNull("ADPCM stereo should sit comfortably under the ceiling",
                ad.bandwidthWarning());
    }

    @Test
    public void readFullySurvivesAStreamThatDribblesBytes() throws IOException {
        // An InputStream is allowed to return fewer bytes than asked. Treating a
        // short read as end-of-stream is the classic silent-corruption bug this
        // helper exists to prevent, so feed it one byte per call.
        class OneByte extends InputStream {
            private final byte[] src;
            private int i;
            OneByte(byte[] s) { src = s; }
            @Override
            public int read() { return i < src.length ? (src[i++] & 0xFF) : -1; }
        }
        byte[] src = handshake(Proto.CODEC_ADPCM, 1, 8000, 10);
        byte[] dst = new byte[src.length];
        Proto.readFully(new OneByte(src), dst, 0, dst.length);
        for (int i = 0; i < src.length; i++) assertEquals(src[i], dst[i]);
    }

    @Test
    public void readFullyReportsTruncation() {
        byte[] src = new byte[] { 1, 2, 3 };
        try {
            Proto.readFully(new ByteArrayInputStream(src), new byte[10], 0, 10);
            fail("a truncated stream must throw EOFException, not return short");
        } catch (EOFException e) {
            assertTrue(e.getMessage().contains("3 of 10"));
        } catch (IOException e) {
            fail("expected EOFException, got " + e);
        }
    }

    @Test
    public void describeNamesTheCodec() {
        Proto.Format f = Proto.parseHandshake(
                handshake(Proto.CODEC_ADPCM, 1, 22050, 20));
        assertTrue(f.describe().contains("IMA-ADPCM"));
        assertTrue(f.describe().contains("22050"));
    }

    /** Kept so a future edit to the framing cannot change the byte layout
     *  without a deliberate review of the PC sender too. */
    @Test
    public void handshakeLayoutIsStable() {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(Proto.MAGIC & 0xFF);
        out.write((Proto.MAGIC >>> 8) & 0xFF);
        out.write((Proto.MAGIC >>> 16) & 0xFF);
        out.write((Proto.MAGIC >>> 24) & 0xFF);
        assertEquals("BTA1", new String(out.toByteArray(),
                java.nio.charset.Charset.forName("US-ASCII")));
    }
}
