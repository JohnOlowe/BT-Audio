package com.example.ghosthand;

import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/** Small but realistic activity: resources, listeners, generics, a nested class. */
public class MainActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        final TextView hello = findViewById(R.id.hello);
        final TapCounter counter = new TapCounter();
        Button tap = findViewById(R.id.tap);
        tap.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                hello.setText(TapCounter.describe(counter.tap()));
            }
        });

        List<String> names = new ArrayList<>();
        names.add("ghost");
        names.add("hand");
        hello.setText(String.join(" + ", names));
    }

    static class Helper {
        static String tag() { return "[main]"; }
    }
}
