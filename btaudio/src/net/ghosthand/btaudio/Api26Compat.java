package net.ghosthand.btaudio;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;

/**
 * API-26-only calls, kept out of ListenerService's fields and method signatures.
 * The service reaches this class only after checking SDK_INT >= 26, so Android
 * 7.x can load the service without resolving Oreo-only types.
 */
final class Api26Compat {
    private static final String CHANNEL_ID = "btaudio";

    private Api26Compat() { }

    static void ensureNotificationChannel(NotificationManager manager) {
        if (manager == null) return;
        NotificationChannel channel = new NotificationChannel(CHANNEL_ID,
                "Bluetooth audio receiver", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Shows while the phone is listening for PC audio.");
        channel.setShowBadge(false);
        manager.createNotificationChannel(channel);
    }

    static Notification.Builder notificationBuilder(Context context) {
        return new Notification.Builder(context, CHANNEL_ID);
    }

    static Object requestAudioFocus(AudioManager manager,
                                    AudioManager.OnAudioFocusChangeListener listener) {
        AudioFocusRequest request = new AudioFocusRequest.Builder(
                AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                .setOnAudioFocusChangeListener(listener)
                .build();
        manager.requestAudioFocus(request);
        return request;
    }

    static void abandonAudioFocus(AudioManager manager, Object request) {
        if (request != null) {
            manager.abandonAudioFocusRequest((AudioFocusRequest) request);
        }
    }
}
