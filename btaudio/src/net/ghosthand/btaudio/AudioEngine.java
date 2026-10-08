package net.ghosthand.btaudio;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.util.Log;

/**
 * Owns the AudioTrack and the jitter measurement around it.
 *
 * <p>There are two different failure modes on a link like this and they need
 * different fixes, so this class keeps them apart rather than reporting one
 * number:
 *
 * <ul>
 *   <li><b>Underrun</b> - AudioTrack ran out of samples to play. Sounds like a
 *       stutter or a buzz. Fixed by a bigger buffer, which costs latency.</li>
 *   <li><b>Stall</b> - a chunk arrived much later than the one before it. The
 *       buffer absorbed it, so you heard nothing, but it means the radio is
 *       struggling and a bigger stall will eventually be audible.</li>
 * </ul>
 *
 * <p>Stalls are measured from chunk arrival times, which is the only signal
 * available without root: AudioTrack does not expose an underrun counter, and
 * {@code write()} blocking is itself invisible. A gap of more than twice the
 * nominal chunk duration is counted. That threshold is deliberately loose so a
 * single scheduler hiccup on the PC does not light up the display.
 *
 * <p>All methods are called from the single service reader thread except
 * {@link #snapshot()}, which the UI thread polls.
 */
final class AudioEngine {

    private static final String TAG = "BtAudio";

    private final Proto.Format format;
    private final int bufferMultiplier;

    private AudioTrack track;
    private final short[] pcm;          // interleaved decode target
    private final short[] left;         // per-channel ADPCM decode targets
    private final short[] right;
    private final Adpcm[] decoders;

    private long framesWritten;
    private long bytesReceived;
    private long stalls;
    private long underrunGuesses;
    private long lastArrivalNanos;
    private boolean primed;

    /**
     * @param bufferMultiplier how many times the framework minimum to allocate.
     *        2 = low latency, 8 = tolerant. The product is what absorbs link
     *        jitter, and it is also exactly what you hear as delay.
     */
    AudioEngine(Proto.Format format, int bufferMultiplier) {
        this.format = format;
        this.bufferMultiplier = Math.max(1, bufferMultiplier);

        // Worst case we ever decode in one go: the maximum payload, as ADPCM,
        // is 2 samples per byte, times 2 channels. Allocating once here rather
        // than per chunk keeps the reader thread free of garbage, which matters
        // because a GC pause at this layer is an audible dropout. Sized from
        // MAX_PAYLOAD (256 KiB), so the whole engine is ~2 MB.
        int maxSamplesPerChannel = Proto.MAX_PAYLOAD / 2 * 2;
        this.pcm = new short[Math.min(maxSamplesPerChannel * format.channels,
                                      1 << 21)];
        this.left = new short[maxSamplesPerChannel];
        this.right = format.channels == 2 ? new short[maxSamplesPerChannel] : null;

        this.decoders = new Adpcm[format.channels];
        for (int i = 0; i < format.channels; i++) decoders[i] = new Adpcm();
    }

    /**
     * Create and start the AudioTrack.
     *
     * @throws IllegalStateException if the device will not give us a track for
     *         this format. The message carries the buffer size we asked for,
     *         because "requested N bytes, got error" is the only way to tell a
     *         bad rate from a too-small buffer.
     */
    void start() {
        int mask = format.channels == 1
                ? AudioFormat.CHANNEL_OUT_MONO
                : AudioFormat.CHANNEL_OUT_STEREO;

        int minBuf = AudioTrack.getMinBufferSize(
                format.sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT);
        if (minBuf <= 0) {
            throw new IllegalStateException(
                    "AudioTrack rejects " + format.describe()
                    + " (getMinBufferSize=" + minBuf + "). This device cannot "
                    + "play that rate/channel combination.");
        }

        // Floor the buffer at the nominal chunk duration times the multiplier.
        // getMinBufferSize is a hardware minimum that is often only a few
        // milliseconds, which is far too shallow to ride out Bluetooth jitter
        // even at multiplier 8.
        int chunkBytes = Math.max(1, format.chunkMs) * format.sampleRate
                * format.channels * 2 / 1000;
        int wanted = Math.max(minBuf * bufferMultiplier,
                              chunkBytes * bufferMultiplier);
        // AudioTrack rounds up internally, and asking for an absurd size makes
        // it fail rather than clamp, so cap it at something sane (~0.5 s).
        int maxBuf = format.sampleRate * format.channels * 2 / 2;
        int bufSize = Math.min(wanted, Math.max(minBuf, maxBuf));

        track = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                .setAudioFormat(new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(format.sampleRate)
                        .setChannelMask(mask)
                        .build())
                .setBufferSizeInBytes(bufSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build();

        int state = track.getState();
        if (state != AudioTrack.STATE_INITIALIZED) {
            track.release();
            track = null;
            throw new IllegalStateException(
                    "AudioTrack failed to initialise for " + format.describe()
                    + " with a " + bufSize + "-byte buffer (state=" + state + ")");
        }

        track.play();
        Log.i(TAG, "AudioTrack up: " + format.describe()
                + ", buffer " + bufSize + " B (min " + minBuf + ", x"
                + bufferMultiplier + ")");
    }

    /** Forget any adaptive state, so a resync chunk starts both ends clean. */
    void resetDecoders() {
        for (Adpcm d : decoders) d.reset();
    }

    /**
     * Decode one audio payload and hand it to AudioTrack. Blocks while the
     * track's buffer is full, which is the backpressure that keeps us from
     * growing without bound if the PC ever runs ahead.
     *
     * @return frames (samples per channel) written
     */
    int feed(byte[] payload, int len) {
        bytesReceived += len;
        measureArrival();

        int frames;
        if (format.isAdpcm()) {
            frames = decodeAdpcm(payload, len);
        } else {
            frames = copyPcm(payload, len);
        }
        if (frames <= 0) return 0;

        int written = track.write(pcm, 0, frames * format.channels);
        if (written < 0) {
            underrunGuesses++;
            Log.w(TAG, "AudioTrack.write failed: " + written);
            return 0;
        }
        framesWritten += written / format.channels;
        return frames;
    }

    private int decodeAdpcm(byte[] payload, int len) {
        int perChannelBytes = len / format.channels;
        int samples = perChannelBytes * 2;
        if (samples > left.length) samples = left.length;

        decoders[0].decode(payload, 0, samples / 2, left, 0);
        if (format.channels == 2) {
            decoders[1].decode(payload, perChannelBytes, samples / 2, right, 0);
            int n = 0;
            for (int i = 0; i < samples; i++) {
                pcm[n++] = left[i];
                pcm[n++] = right[i];
            }
        } else {
            System.arraycopy(left, 0, pcm, 0, samples);
        }
        return samples;
    }

    private int copyPcm(byte[] payload, int len) {
        int samples = len / 2;
        if (samples > pcm.length) samples = pcm.length;
        for (int i = 0; i < samples; i++) {
            int lo = payload[i * 2] & 0xFF;
            int hi = payload[i * 2 + 1];
            pcm[i] = (short) (lo | (hi << 8));
        }
        // len is interleaved bytes, so frames = samples / channels
        return samples / format.channels;
    }

    /**
     * Record when this chunk arrived and compare with the last one. Called
     * before decoding so the measurement reflects the link, not our own work.
     */
    private void measureArrival() {
        long now = System.nanoTime();
        if (primed) {
            long gapMs = (now - lastArrivalNanos) / 1000000L;
            int nominal = Math.max(1, format.chunkMs);
            if (gapMs > nominal * 2L + 20L) {
                stalls++;
                Log.w(TAG, "stall: " + gapMs + " ms gap (nominal " + nominal
                        + " ms) - the link could not keep up");
            }
        } else {
            primed = true;
        }
        lastArrivalNanos = now;
    }

    /** Drop everything queued. Used when the PC asks for a resync. */
    void flush() {
        if (track == null) return;
        try {
            track.pause();
            track.flush();
            track.play();
        } catch (IllegalStateException e) {
            Log.w(TAG, "flush failed", e);
        }
    }

    void stop() {
        if (track == null) return;
        try {
            track.stop();
        } catch (IllegalStateException ignored) {
            // already stopped, or never started: nothing to do
        }
        track.release();
        track = null;
    }

    long framesWritten()   { return framesWritten; }
    long bytesReceived()   { return bytesReceived; }
    long stalls()          { return stalls; }
    long underrunGuesses() { return underrunGuesses; }

    /** Seconds of audio delivered, which is the number a person can sanity
     *  check against how long they have been playing something. */
    double secondsPlayed() {
        return format.sampleRate == 0 ? 0
                : (double) framesWritten / format.sampleRate;
    }

    String snapshot() {
        return format.describe()
                + "\nplayed " + String.format(java.util.Locale.US, "%.1f", secondsPlayed()) + " s"
                + "  |  in " + (bytesReceived / 1024) + " KiB"
                + "  |  link stalls " + stalls
                + (underrunGuesses > 0 ? "  |  write errors " + underrunGuesses : "");
    }
}
