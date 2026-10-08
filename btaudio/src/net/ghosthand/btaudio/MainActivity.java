package net.ghosthand.btaudio;

import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;

/**
 * Status and the two settings that matter. Deliberately thin: the service owns
 * every decision, and this activity only reads {@link ListenerService#state()}
 * on a timer, so there is no state here to fall out of step with it.
 *
 * <p>Framework widgets only - no AndroidX. Nothing in this app needs a Material
 * component, and staying off AndroidX is what keeps the build a single command
 * with no library fetching.
 */
public final class MainActivity extends Activity {

    private static final int REQ_PERMISSIONS = 1001;
    private static final int REQ_DISCOVERABLE = 1002;
    private static final int REQ_ENABLE_BT = 1003;

    /** Buffer presets as multipliers of the framework minimum. The labels name
     *  the trade-off rather than the number, because "x2" tells a user nothing
     *  and "cuts out less, lags less" does. */
    private static final int[] BUFFER_MULTS = { 2, 4, 8, 16 };
    private static final String[] BUFFER_LABELS = {
        "Low latency (cuts out more)",
        "Balanced (default)",
        "Tolerant (more delay)",
        "Very tolerant (noticeable delay)"
    };

    private final Handler handler = new Handler(Looper.getMainLooper());

    private TextView status;
    private TextView detail;
    private TextView error;
    private TextView logView;
    private ScrollView logScroll;
    private Button startStop;
    private Spinner bufferSpinner;
    private CheckBox insecure;

    private SharedPreferences prefs;

    /** Last log text we painted, so an unchanged log is never re-set (a setText
     *  on identical text still invalidates layout and nudges the scroll). */
    private String lastLogText;

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            render();
            handler.postDelayed(this, 300);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        prefs = getSharedPreferences(ListenerService.PREFS, MODE_PRIVATE);

        status = (TextView) findViewById(R.id.status);
        detail = (TextView) findViewById(R.id.detail);
        error = (TextView) findViewById(R.id.error);
        logView = (TextView) findViewById(R.id.log);
        logScroll = (ScrollView) findViewById(R.id.log_scroll);
        startStop = (Button) findViewById(R.id.start_stop);
        bufferSpinner = (Spinner) findViewById(R.id.buffer);
        insecure = (CheckBox) findViewById(R.id.insecure);

        ArrayAdapter<String> adapter = new ArrayAdapter<String>(
                this, android.R.layout.simple_spinner_item, BUFFER_LABELS);
        adapter.setDropDownViewResource(
                android.R.layout.simple_spinner_dropdown_item);
        bufferSpinner.setAdapter(adapter);
        bufferSpinner.setSelection(indexOfMult(prefs.getInt(
                ListenerService.PREF_BUFFER, 4)));
        bufferSpinner.setEnabled(!ListenerService.isRunning());

        insecure.setChecked(prefs.getBoolean(ListenerService.PREF_INSECURE, false));
        insecure.setEnabled(!ListenerService.isRunning());
        insecure.setOnCheckedChangeListener(
                new CompoundButton.OnCheckedChangeListener() {
                    @Override
                    public void onCheckedChanged(CompoundButton v, boolean on) {
                        prefs.edit()
                             .putBoolean(ListenerService.PREF_INSECURE, on)
                             .apply();
                    }
                });

        startStop.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (ListenerService.isRunning()) stopListening();
                else startListening();
            }
        });

        findViewById(R.id.discoverable).setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) { makeDiscoverable(); }
                });

        findViewById(R.id.copy_log).setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View v) { copyLog(); }
                });

        // The how-to is marked up in strings.xml rather than built from spans
        // here: it is the one block of prose in the app, and keeping it in
        // resources means it is translatable and diffable. minSdk is 24, so the
        // two-arg fromHtml (and its explicit compact mode) is always available.
        TextView howto = (TextView) findViewById(R.id.howto);
        howto.setText(android.text.Html.fromHtml(getString(R.string.howto),
                android.text.Html.FROM_HTML_MODE_COMPACT));
    }

    private static int indexOfMult(int mult) {
        for (int i = 0; i < BUFFER_MULTS.length; i++) {
            if (BUFFER_MULTS[i] == mult) return i;
        }
        return 1;
    }

    @Override
    protected void onResume() {
        super.onResume();
        render();
        handler.postDelayed(poll, 300);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(poll);
        super.onPause();
    }

    // --- actions ----------------------------------------------------------

    private void startListening() {
        prefs.edit()
             .putInt(ListenerService.PREF_BUFFER,
                     BUFFER_MULTS[bufferSpinner.getSelectedItemPosition()])
             .apply();

        if (!ensurePermissions()) return;

        BluetoothManager bm =
                (BluetoothManager) getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter adapter = bm == null ? null : bm.getAdapter();
        if (adapter == null) {
            toast("This device has no Bluetooth.");
            return;
        }
        if (!adapter.isEnabled()) {
            // Ask the system to turn it on rather than telling the user to go
            // find the switch: this is the one time a dialog is shorter than
            // the explanation.
            startActivityForResult(
                    new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                    REQ_ENABLE_BT);
            return;
        }

        Intent i = new Intent(this, ListenerService.class);
        i.setAction(ListenerService.ACTION_START);
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i);
        else startService(i);

        startStop.setText(R.string.stop);
        bufferSpinner.setEnabled(false);
        insecure.setEnabled(false);
    }

    private void stopListening() {
        Intent i = new Intent(this, ListenerService.class);
        i.setAction(ListenerService.ACTION_STOP);
        startService(i);
        startStop.setText(R.string.start);
        bufferSpinner.setEnabled(true);
        insecure.setEnabled(true);
    }

    private void makeDiscoverable() {
        Intent i = new Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE);
        i.putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300);
        try {
            startActivityForResult(i, REQ_DISCOVERABLE);
        } catch (android.content.ActivityNotFoundException e) {
            toast("This device does not offer a discoverable dialog.");
        }
    }

    private void copyLog() {
        String[] lines = ListenerService.logSnapshot();
        StringBuilder sb = new StringBuilder();
        for (String l : lines) sb.append(l).append('\n');
        android.content.ClipboardManager cm =
                (android.content.ClipboardManager)
                        getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm != null) {
            cm.setPrimaryClip(android.content.ClipData.newPlainText(
                    "bt-audio log", sb.toString()));
            toast("Log copied (" + lines.length + " lines).");
        }
    }

    /**
     * BLUETOOTH_CONNECT arrived in API 31 and POST_NOTIFICATIONS in 33; below
     * that the manifest declaration is enough. Asking for a permission that
     * does not exist on this platform is harmless - requestPermissions filters
     * it - but guarding means the dialog never shows a line the user cannot
     * act on.
     */
    private boolean ensurePermissions() {
        List<String> need = new ArrayList<String>();
        if (Build.VERSION.SDK_INT >= 31
                && checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT)
                        != PackageManager.PERMISSION_GRANTED) {
            need.add(android.Manifest.permission.BLUETOOTH_CONNECT);
        }
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                        != PackageManager.PERMISSION_GRANTED) {
            need.add(android.Manifest.permission.POST_NOTIFICATIONS);
        }
        if (need.isEmpty()) return true;

        requestPermissions(need.toArray(new String[need.size()]), REQ_PERMISSIONS);
        toast("Grant Bluetooth access, then press Start again.");
        return false;
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions,
                                           int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode != REQ_PERMISSIONS) return;
        for (int i = 0; i < permissions.length; i++) {
            if (permissions[i].endsWith("BLUETOOTH_CONNECT")
                    && results[i] != PackageManager.PERMISSION_GRANTED) {
                error.setText(R.string.err_no_bt_permission);
                error.setVisibility(View.VISIBLE);
                return;
            }
        }
        startListening();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_ENABLE_BT) {
            if (resultCode == RESULT_OK) startListening();
            else toast("Bluetooth stayed off, so there is nothing to listen on.");
        } else if (requestCode == REQ_DISCOVERABLE) {
            toast(resultCode > 0
                    ? "Discoverable for " + resultCode + " s - pair from the PC now."
                    : "Discoverability was cancelled.");
        }
    }

    // --- rendering --------------------------------------------------------

    private void render() {
        ListenerService.State s = ListenerService.state();
        boolean running = ListenerService.isRunning();

        startStop.setText(running ? R.string.stop : R.string.start);
        bufferSpinner.setEnabled(!running);
        insecure.setEnabled(!running);

        String head;
        if (s.peer != null) head = getString(R.string.state_connected);
        else if (s.listening || running) head = getString(R.string.state_listening);
        else head = getString(R.string.state_idle);
        status.setText(head);

        StringBuilder d = new StringBuilder();
        if (s.peer != null) d.append(s.peer).append('\n');
        if (s.format != null) d.append(s.format).append('\n');
        if (s.stats != null) d.append(s.stats).append('\n');
        d.append("SDP name: ").append(ListenerService.SDP_NAME);
        detail.setText(d.toString().trim());

        if (s.error != null) {
            error.setText(s.error);
            error.setVisibility(View.VISIBLE);
        } else if (!running
                && checkSelfPermissionSafe(
                        android.Manifest.permission.BLUETOOTH_CONNECT)
                        == PackageManager.PERMISSION_DENIED) {
            error.setText(R.string.err_no_bt_permission);
            error.setVisibility(View.VISIBLE);
        } else {
            error.setVisibility(View.GONE);
        }

        renderLog();
    }

    /**
     * Repaint the log WITHOUT stealing the reader's position.
     *
     * <p>The first version pinned the log to its newest line on every poll,
     * which made reading back through it futile: the next 300 ms tick yanked it
     * to the bottom again, mid-swipe. This uses the convention every terminal
     * and chat app uses - sticky scroll. New lines are followed only while the
     * reader is already at the bottom; scroll up and the log stays exactly
     * where you left it until you come back down yourself.
     *
     * <p>It also skips the work entirely when nothing changed, because
     * setText() on an unchanged string still invalidates the layout and that
     * alone is enough to disturb a scroll in progress.
     */
    private void renderLog() {
        String[] lines = ListenerService.logSnapshot();
        StringBuilder sb = new StringBuilder();
        for (String l : lines) sb.append(l).append('\n');
        final String text = sb.length() == 0
                ? getString(R.string.log_empty) : sb.toString().trim();
        if (text.equals(lastLogText)) return;
        lastLogText = text;

        final boolean atBottom = !logScroll.canScrollVertically(1);
        final int userY = logScroll.getScrollY();
        logView.setText(text);

        // post, because the new height only exists after the next layout pass
        logScroll.post(new Runnable() {
            @Override
            public void run() {
                if (atBottom) {
                    logScroll.fullScroll(View.FOCUS_DOWN);
                } else {
                    // lines are only ever appended, so offsets above the end
                    // are unchanged by the re-layout and the reader's position
                    // is still meaningful
                    logScroll.scrollTo(0, userY);
                }
            }
        });
    }

    /** checkSelfPermission is API 23 and minSdk is 24, so the direct call is
     *  safe; this wrapper exists only to keep render() readable. */
    private int checkSelfPermissionSafe(String permission) {
        if (Build.VERSION.SDK_INT < 31) return PackageManager.PERMISSION_GRANTED;
        try {
            return checkSelfPermission(permission);
        } catch (RuntimeException e) {
            return PackageManager.PERMISSION_GRANTED;
        }
    }

    private void toast(String msg) {
        Toast.makeText(this, msg, Toast.LENGTH_LONG).show();
    }
}
