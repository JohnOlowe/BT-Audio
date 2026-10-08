package com.example.axsample;

import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.lifecycle.ViewModel;
import androidx.lifecycle.ViewModelProvider;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import com.google.android.material.button.MaterialButton;
import com.google.android.material.snackbar.Snackbar;

/**
 * One activity touching the whole AndroidX surface the toolchain links:
 * AppCompatActivity + Material widgets + RecyclerView + lifecycle ViewModel +
 * resources merged out of the AARs by aapt2.
 */
public class MainActivity extends AppCompatActivity {

    private Counter counter;
    private ListModel model;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        counter = new ViewModelProvider(this).get(Counter.class);
        model = ListModel.defaultLibraries();

        RecyclerView list = findViewById(R.id.list);
        list.setLayoutManager(new LinearLayoutManager(this));
        list.setAdapter(new NamesAdapter(model));

        MaterialButton tap = findViewById(R.id.tap);
        tap.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                Snackbar.make(v, "taps = " + counter.tap(), Snackbar.LENGTH_SHORT).show();
            }
        });
    }

    /** Stored in a ViewModel so the count survives rotation. */
    public static class Counter extends ViewModel {
        private int taps;

        public int tap() {
            return ++taps;
        }
    }

    /** RecyclerView.Adapter over the pure-Java ListModel. */
    static class NamesAdapter extends RecyclerView.Adapter<NamesAdapter.Holder> {

        private final ListModel model;

        NamesAdapter(ListModel model) {
            this.model = model;
        }

        @NonNull
        @Override
        public Holder onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            TextView text = new TextView(parent.getContext());
            text.setLayoutParams(new ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            return new Holder(text);
        }

        @Override
        public void onBindViewHolder(@NonNull Holder holder, int position) {
            holder.text.setText(model.get(position));
        }

        @Override
        public int getItemCount() {
            return model.size();
        }

        static class Holder extends RecyclerView.ViewHolder {
            final TextView text;

            Holder(TextView view) {
                super(view);
                this.text = view;
            }
        }
    }
}
