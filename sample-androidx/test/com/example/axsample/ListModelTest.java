package com.example.axsample;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/**
 * Runs on the bundled JRE through toolchain/test.sh -- no device, no emulator.
 * Tests only the pure-Java model; anything touching androidx.* would need a
 * real Android runtime.
 */
public class ListModelTest {

    @Test
    public void countsItems() {
        assertEquals(3, new ListModel("a", "b", "c").size());
    }

    @Test
    public void returnsItemsInOrder() {
        ListModel model = new ListModel("first", "second");
        assertEquals("first", model.get(0));
        assertEquals("second", model.get(1));
    }

    @Test
    public void defaultModelIsSortedByLengthDescending() {
        ListModel model = ListModel.defaultLibraries();
        assertTrue("expected several libraries", model.size() >= 5);
        for (int i = 1; i < model.size(); i++) {
            assertTrue(model.get(i - 1).length() >= model.get(i).length());
        }
    }
}
