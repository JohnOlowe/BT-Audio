package com.example.axsample;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Pure-Java model, deliberately free of framework calls so it is unit-testable
 * on a plain JVM (see ListModelTest). MainActivity is the AndroidX part.
 */
public final class ListModel {

    private final List<String> items = new ArrayList<>();

    public ListModel(String... names) {
        Collections.addAll(items, names);
    }

    public int size() {
        return items.size();
    }

    public String get(int index) {
        return items.get(index);
    }

    /** Library list the sample shows, longest name first. */
    public static ListModel defaultLibraries() {
        ListModel model = new ListModel(
                "appcompat-1.6.1",
                "material-1.10.0",
                "core-1.10.1",
                "constraintlayout-2.1.4",
                "recyclerview-1.1.0");
        model.items.sort((a, b) -> b.length() - a.length());
        return model;
    }
}
