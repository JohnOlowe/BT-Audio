package com.example.ghosthand;

import org.junit.Test;
import org.junit.Before;

import static org.junit.Assert.assertEquals;

public class TapCounterTest {

    private TapCounter counter;

    @Before
    public void setUp() {
        counter = new TapCounter();
    }

    @Test
    public void startsAtZero() {
        assertEquals(0, counter.count());
    }

    @Test
    public void countsTaps() {
        counter.tap();
        counter.tap();
        assertEquals(2, counter.count());
    }

    @Test
    public void resets() {
        counter.tap();
        counter.reset();
        assertEquals(0, counter.count());
    }

    @Test
    public void describes() {
        assertEquals("fresh", TapCounter.describe(0));
        assertEquals("tapped once", TapCounter.describe(1));
        assertEquals("tapped 4 times", TapCounter.describe(4));
    }
}
