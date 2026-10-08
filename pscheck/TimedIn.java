import java.io.IOException;
import java.io.InputStream;

/**
 * A stream that gives up if nothing arrives for a while.
 *
 * A socket or pty stays open forever after the far end stops sending, so a test
 * reader that blocks on read() waits for a timeout that never comes. This turns
 * silence into EOF, which is what "the sender finished" actually looks like.
 */
public final class TimedIn extends InputStream {
    private final InputStream in;
    private final long quietMs;

    public TimedIn(InputStream in, long quietMs) { this.in = in; this.quietMs = quietMs; }

    private void waitForData() throws IOException {
        long deadline = System.currentTimeMillis() + quietMs;
        try {
            while (in.available() == 0) {
                if (System.currentTimeMillis() > deadline)
                    throw new IOException("no data for " + quietMs + " ms - sender finished");
                Thread.sleep(5);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted");
        }
    }

    @Override public int read() throws IOException {
        waitForData();
        return in.read();
    }

    @Override public int read(byte[] b, int off, int len) throws IOException {
        waitForData();
        return in.read(b, off, Math.min(len, in.available()));
    }

    @Override public int available() throws IOException { return in.available(); }
    @Override public void close() throws IOException { in.close(); }
}
