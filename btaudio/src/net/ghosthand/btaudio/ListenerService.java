package net.ghosthand.btaudio;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothServerSocket;
import android.bluetooth.BluetoothSocket;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.UUID;

/**
 * Listens for the PC on an RFCOMM channel and plays what arrives.
 *
 * <p>The service, not the activity, holds the socket: an RFCOMM listener only
 * exists while something is listening, and the PC creates its COM port by
 * running an SDP query against this record. If the listener died with the
 * activity, Windows would find no service to map and the user would be left
 * staring at an empty COM-port dialog with no explanation.
 *
 * <p>Standard SPP UUID, so Windows treats it as a serial port. That is the
 * whole reason for using SPP rather than a private UUID: a private one has no
 * built-in Windows mapping and would need a custom driver.
 */
public final class ListenerService extends Service {

    private static final String TAG = "BtAudio";

    /** The SDP service name. This string is what appears in the Windows
     *  Bluetooth COM-port picker, so it is user-facing documentation. */
    public static final String SDP_NAME = "PC Audio In";

    /** Standard Serial Port Profile UUID. */
    public static final UUID SPP_UUID =
            UUID.fromString("00001101-0000-1000-8000-00805F9B34FB");

    public static final String ACTION_START = "net.ghosthand.btaudio.START";
    public static final String ACTION_STOP = "net.ghosthand.btaudio.STOP";

    public static final String PREFS = "btaudio";
    public static final String PREF_BUFFER = "buffer_mult";
    public static final String PREF_INSECURE = "insecure_rfcomm";

    private static final int NOTIF_ID = 1;
    private static final int LOG_LINES = 60;

    /**
     * Everything the UI shows, in one immutable snapshot the reader thread
     * publishes and the activity polls. A static volatile reference rather than
     * broadcasts: same process, and this way there is no exported receiver and
     * no permission surface for a status string.
     */
    public static final class State {
        public final boolean listening;
        public final String peer;
        public final String format;
        public final String stats;
        public final String error;

        State(boolean listening, String peer, String format, String stats,
              String error) {
            this.listening = listening;
            this.peer = peer;
            this.format = format;
            this.stats = stats;
            this.error = error;
        }
    }

    private static volatile State sState =
            new State(false, null, null, null, null);
    private static volatile boolean sRunning;

    private final Deque<String> logLines = new ArrayDeque<String>();

    private Thread acceptThread;
    private BluetoothServerSocket serverSocket;
    private AudioEngine engine;
    private PowerManager.WakeLock wakeLock;
    private AudioManager audioManager;
    // Keep API-26-only types out of this class so Android 7 can load it.
    private Object focusRequest;
    private volatile boolean stopRequested;

    public static State state() { return sState; }

    public static boolean isRunning() { return sRunning; }

    /** Recent events, newest last. The in-app log exists because reproducing
     *  a Bluetooth interop problem needs the failure text at the moment it
     *  happened, and getting logcat off an unrooted phone mid-problem is the
     *  hard part. */
    public static String[] logSnapshot() { return sLogSnapshot; }

    private static volatile String[] sLogSnapshot = new String[0];

    /** One listener for both focus APIs, so the legacy and modern paths behave
     *  identically rather than one of them being a no-op placeholder. */
    private final AudioManager.OnAudioFocusChangeListener focusListener =
            new AudioManager.OnAudioFocusChangeListener() {
                @Override
                public void onAudioFocusChange(int change) {
                    if (change == AudioManager.AUDIOFOCUS_LOSS) {
                        log("lost audio focus");
                    }
                }
            };

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            stopSelf();
            return START_NOT_STICKY;
        }

        BluetoothManager bm = (BluetoothManager) getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter adapter = bm == null ? null : bm.getAdapter();
        if (adapter == null) {
            publish(false, null, null, null, "This device has no Bluetooth.");
            stopSelf();
            return START_NOT_STICKY;
        }
        if (!adapter.isEnabled()) {
            publish(false, null, null, null,
                    "Bluetooth is off. Turn it on and press Start again.");
            stopSelf();
            return START_NOT_STICKY;
        }

        startInForeground(adapter);

        stopRequested = false;
        sRunning = true;
        acceptThread = new Thread(new AcceptLoop(adapter), "bt-audio-accept");
        acceptThread.start();

        // Not START_STICKY on purpose: if the system kills us, silently
        // restarting a Bluetooth listener the user did not ask for again is
        // worse than staying dead.
        return START_NOT_STICKY;
    }

    private void startInForeground(BluetoothAdapter adapter) {
        NotificationManager nm =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26) {
            Api26Compat.ensureNotificationChannel(nm);
        }

        Intent open = new Intent(this, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        int piFlags = Build.VERSION.SDK_INT >= 23
                ? PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
                : PendingIntent.FLAG_UPDATE_CURRENT;
        PendingIntent pi = PendingIntent.getActivity(this, 0, open, piFlags);

        Notification.Builder b = Build.VERSION.SDK_INT >= 26
                ? Api26Compat.notificationBuilder(this)
                : new Notification.Builder(this);
        Notification n = b.setContentTitle("Listening for PC audio")
                .setContentText(SDP_NAME + " - waiting for a connection")
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentIntent(pi)
                .setOngoing(true)
                .build();

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, n,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
        } else {
            startForeground(NOTIF_ID, n);
        }

        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm != null) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,
                    "btaudio:stream");
            wakeLock.setReferenceCounted(false);
        }
        audioManager = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
    }

    // --- the listening thread --------------------------------------------

    private final class AcceptLoop implements Runnable {
        private final BluetoothAdapter adapter;

        AcceptLoop(BluetoothAdapter adapter) { this.adapter = adapter; }

        @Override
        public void run() {
            SharedPreferences p = getSharedPreferences(PREFS, MODE_PRIVATE);
            boolean insecure = p.getBoolean(PREF_INSECURE, false);

            try {
                serverSocket = insecure
                        ? adapter.listenUsingInsecureRfcommWithServiceRecord(
                                SDP_NAME, SPP_UUID)
                        : adapter.listenUsingRfcommWithServiceRecord(
                                SDP_NAME, SPP_UUID);
            } catch (SecurityException e) {
                publish(false, null, null, null,
                        "Missing the Bluetooth permission. Reopen the app and "
                        + "grant it.");
                shutdown();
                return;
            } catch (IOException e) {
                publish(false, null, null, null,
                        "Could not open the RFCOMM channel: " + e.getMessage()
                        + (insecure ? "" : "  Try \"Insecure RFCOMM\" below."));
                shutdown();
                return;
            }

            log("listening on " + SDP_NAME + " ("
                    + (insecure ? "insecure" : "secure") + " RFCOMM)");
            publish(true, null, null, null, null);

            while (!stopRequested) {
                BluetoothSocket sock = null;
                try {
                    // Blocks. accept() throws when Bluetooth goes away or when
                    // close() is called from onDestroy, which is how stopping
                    // works.
                    sock = serverSocket.accept();
                } catch (IOException e) {
                    if (!stopRequested) {
                        log("accept failed: " + e.getMessage());
                        publish(true, null, null, null,
                                "Listener dropped (" + e.getMessage()
                                + "). Bluetooth may have turned off.");
                    }
                    break;
                }
                if (sock == null) continue;

                String peer = describePeer(sock);
                log("connected: " + peer);
                if (wakeLock != null) wakeLock.acquire();
                requestAudioFocus();
                try {
                    serve(sock, peer, p);
                } finally {
                    abandonAudioFocus();
                    if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
                    try { sock.close(); } catch (IOException ignored) { }
                    if (engine != null) { engine.stop(); engine = null; }
                    if (!stopRequested) {
                        log("disconnected");
                        publish(true, null, null, null, null);
                    }
                }
            }
            closeServerSocket();
        }
    }

    private String describePeer(BluetoothSocket sock) {
        try {
            String name = sock.getRemoteDevice().getName();
            return (name == null ? "unknown device" : name)
                    + " " + sock.getRemoteDevice().getAddress();
        } catch (SecurityException e) {
            return "unknown device";
        }
    }

    /** Read one connection to its end. Returns when the PC disconnects. */
    private void serve(BluetoothSocket sock, String peer, SharedPreferences p) {
        InputStream in;
        try {
            in = sock.getInputStream();
        } catch (IOException e) {
            publish(true, peer, null, null, "No input stream: " + e.getMessage());
            return;
        }

        byte[] hs = new byte[Proto.HANDSHAKE_LEN];
        Proto.Format format;
        try {
            Proto.readFully(in, hs, 0, hs.length);
            format = Proto.parseHandshake(hs);
        } catch (IOException e) {
            publish(true, peer, null, null,
                    "Closed before sending a handshake. If this was the PC "
                    + "sender, it never got as far as writing.");
            return;
        } catch (IllegalArgumentException e) {
            publish(true, peer, null, null, e.getMessage());
            return;
        }

        log("stream: " + format.describe());
        String warn = format.bandwidthWarning();
        if (warn != null) log("warning: " + warn);

        int mult = p.getInt(PREF_BUFFER, 4);
        engine = new AudioEngine(format, mult);
        try {
            engine.start();
        } catch (IllegalStateException e) {
            publish(true, peer, format.describe(), null, e.getMessage());
            return;
        }

        publish(true, peer, format.describe(), engine.snapshot(), warn);

        byte[] hdr = new byte[Proto.CHUNK_HEADER_LEN];
        byte[] payload = new byte[4096];
        long sinceUi = System.currentTimeMillis();

        while (!stopRequested) {
            Proto.Chunk chunk;
            try {
                Proto.readFully(in, hdr, 0, hdr.length);
                chunk = Proto.parseChunkHeader(hdr);
            } catch (IOException e) {
                return; // clean disconnect
            } catch (IllegalArgumentException e) {
                publish(true, peer, format.describe(), engine.snapshot(),
                        e.getMessage());
                return;
            }

            if (chunk.type == Proto.CHUNK_END) { log("PC ended the stream"); return; }

            if (chunk.length > payload.length) payload = new byte[chunk.length];
            if (chunk.length > 0) {
                try {
                    Proto.readFully(in, payload, 0, chunk.length);
                } catch (IOException e) {
                    return;
                }
            }

            if (chunk.type == Proto.CHUNK_RESYNC) {
                engine.resetDecoders();
                engine.flush();
                log("resync");
                continue;
            }
            if (chunk.type != Proto.CHUNK_AUDIO) continue;

            engine.feed(payload, chunk.length);

            // Throttle UI republishing to 4/s. Doing it per chunk would burn
            // more CPU building strings than decoding audio.
            long now = System.currentTimeMillis();
            if (now - sinceUi > 250) {
                sinceUi = now;
                publish(true, peer, format.describe(), engine.snapshot(), null);
            }
        }
    }

    // --- audio focus ------------------------------------------------------

    /**
     * Take focus so the phone's own music gets out of the way. Without this
     * both play at once, which sounds like a bug even though it is exactly
     * what was asked for.
     */
    @SuppressWarnings("deprecation") // legacy path below API 26
    private void requestAudioFocus() {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                focusRequest = Api26Compat.requestAudioFocus(audioManager, focusListener);
            } else {
                audioManager.requestAudioFocus(focusListener,
                        AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "audio focus unavailable", e);
        }
    }

    @SuppressWarnings("deprecation") // legacy path below API 26
    private void abandonAudioFocus() {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26 && focusRequest != null) {
                Api26Compat.abandonAudioFocus(audioManager, focusRequest);
                focusRequest = null;
            } else {
                audioManager.abandonAudioFocus(focusListener);
            }
        } catch (RuntimeException ignored) { }
    }

    // --- state publishing -------------------------------------------------

    private void publish(boolean listening, String peer, String format,
                         String stats, String error) {
        sState = new State(listening, peer, format, stats, error);
    }

    private synchronized void log(String line) {
        String stamped = String.format(java.util.Locale.US, "%tT  %s",
                System.currentTimeMillis(), line);
        logLines.addLast(stamped);
        while (logLines.size() > LOG_LINES) logLines.removeFirst();
        sLogSnapshot = logLines.toArray(new String[logLines.size()]);
        Log.i(TAG, line);
    }

    private void closeServerSocket() {
        BluetoothServerSocket s = serverSocket;
        serverSocket = null;
        if (s != null) {
            try { s.close(); } catch (IOException ignored) { }
        }
    }

    private void shutdown() {
        stopRequested = true;
        sRunning = false;
        closeServerSocket();
        if (engine != null) { engine.stop(); engine = null; }
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        abandonAudioFocus();
        stopSelf();
    }

    @Override
    public void onDestroy() {
        log("service stopped");
        shutdown();
        super.onDestroy();
    }
}
