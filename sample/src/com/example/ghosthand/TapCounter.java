package com.example.ghosthand;

/** Pure-Java logic: no android.* here, so it is unit-testable on the JVM. */
public final class TapCounter {

    private int taps;

    public int tap() {
        return ++taps;
    }

    public int count() {
        return taps;
    }

    public void reset() {
        taps = 0;
    }

    public static String describe(int taps) {
        if (taps <= 0) return "fresh";
        if (taps == 1) return "tapped once";
        return "tapped " + taps + " times";
    }
}
