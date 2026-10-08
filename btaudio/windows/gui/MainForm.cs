// ---------------------------------------------------------------------------
// BtAudioSender - the window.
//
// Built entirely in code: no designer file and no .resx, so the whole program
// is three source files that compile with csc and nothing else.
// ---------------------------------------------------------------------------
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace BtAudio
{
    public sealed class MainForm : Form
    {
        // source
        ComboBox cbPort, cbDevice, cbFile;
        Button btnRefreshPorts, btnRefreshDevices;
        // audio
        ComboBox cbPreset, cbCodec, cbChannels, cbRate;
        NumericUpDown numChunk, numPrebuffer;
        // options
        CheckBox chkAuto, chkSilence;
        ComboBox cbSilenceMode;
        Label lblSilenceState;
        // run
        Button btnStart;
        // delay
        ComboBox cbPhoneBuffer, cbHeadphone;
        NumericUpDown numCustomHp;
        Label lblTotal;
        Button btnCopyDelay;
        // stats + log
        Label lblStats, lblBacklog, lblCongestion;
        TextBox txtLog;

        Sender sender;
        Thread worker;
        CancellationTokenSource cancel;
        IAudioSource liveSource;
        Silencer silencer;
        string silenceDeviceId;
        int peakBeforeSilence = -1;
        double silenceToggledAt = -1;
        System.Windows.Forms.Timer silenceWatch;
        SenderStats last;

        public MainForm()
        {
            Text = "BT Audio Sender";
            ClientSize = new Size(800, 690);
            MinimumSize = new Size(820, 730);
            Font = new Font("Segoe UI", 8.5f);
            StartPosition = FormStartPosition.CenterScreen;

            BuildSourceGroup();
            BuildAudioGroup();
            BuildOptionsGroup();
            BuildRunGroup();
            BuildDelayGroup();
            BuildStatsGroup();
            BuildLog();

            PopulatePresets();
            RefreshPorts();
            RefreshDevices();
            RecountDelay();

            FormClosing += OnClosing;
        }

        // ------------------------------------------------------------------ layout
        GroupBox Box(string title, int x, int y, int w, int h)
        {
            GroupBox g = new GroupBox();
            g.Text = title;
            g.SetBounds(x, y, w, h);
            Controls.Add(g);
            return g;
        }

        static Label Lbl(Control parent, string text, int x, int y)
        {
            Label l = new Label();
            l.Text = text;
            l.SetBounds(x, y, 110, 18);
            parent.Controls.Add(l);
            return l;
        }

        void BuildSourceGroup()
        {
            GroupBox g = Box("1. Where the audio comes from", 10, 8, 390, 148);

            Lbl(g, "Phone port", 10, 22);
            cbPort = new ComboBox();
            cbPort.DropDownStyle = ComboBoxStyle.DropDown;
            cbPort.SetBounds(96, 19, 200, 22);
            g.Controls.Add(cbPort);
            btnRefreshPorts = new Button();
            btnRefreshPorts.Text = "Refresh";
            btnRefreshPorts.SetBounds(302, 18, 78, 24);
            btnRefreshPorts.Click += delegate { RefreshPorts(); };
            g.Controls.Add(btnRefreshPorts);

            Lbl(g, "Laptop output", 10, 54);
            cbDevice = new ComboBox();
            cbDevice.DropDownStyle = ComboBoxStyle.DropDownList;
            cbDevice.SetBounds(96, 51, 284, 22);
            g.Controls.Add(cbDevice);
            btnRefreshDevices = new Button();
            btnRefreshDevices.Text = "Refresh";
            btnRefreshDevices.SetBounds(302, 78, 78, 24);
            btnRefreshDevices.Click += delegate { RefreshDevices(); };
            g.Controls.Add(btnRefreshDevices);

            Label hint = new Label();
            hint.Text = "Pick a virtual cable here (e.g. \"CABLE Input\") to send audio\n"
                      + "without hearing it on the laptop at all.";
            hint.ForeColor = Color.FromArgb(90, 90, 90);
            hint.SetBounds(96, 80, 210, 30);
            g.Controls.Add(hint);

            Lbl(g, "WAV file", 10, 116);
            cbFile = new ComboBox();
            cbFile.SetBounds(96, 113, 220, 22);
            g.Controls.Add(cbFile);
            Button b = new Button();
            b.Text = "...";
            b.SetBounds(320, 112, 26, 24);
            b.Click += delegate
            {
                OpenFileDialog d = new OpenFileDialog();
                d.Filter = "WAV files (*.wav)|*.wav|All files (*.*)|*.*";
                if (d.ShowDialog() == DialogResult.OK) cbFile.Text = d.FileName;
            };
            g.Controls.Add(b);
            Button play = new Button();
            play.Text = "Play file to phone";
            play.SetBounds(348, 112, 34, 24);
            play.Visible = false;
            g.Controls.Add(play);
        }

        void BuildAudioGroup()
        {
            GroupBox g = Box("2. Quality", 10, 162, 390, 152);

            Lbl(g, "Preset", 10, 24);
            cbPreset = new ComboBox();
            cbPreset.DropDownStyle = ComboBoxStyle.DropDownList;
            cbPreset.SetBounds(96, 21, 284, 22);
            cbPreset.SelectedIndexChanged += delegate { ApplyPreset(); };
            g.Controls.Add(cbPreset);

            Lbl(g, "Codec", 10, 52);
            cbCodec = new ComboBox();
            cbCodec.DropDownStyle = ComboBoxStyle.DropDownList;
            cbCodec.Items.AddRange(new object[] { "ADPCM (4-bit, recommended)", "PCM (raw 16-bit)" });
            cbCodec.SelectedIndex = 0;
            cbCodec.SetBounds(96, 49, 130, 22);
            g.Controls.Add(cbCodec);

            Lbl(g, "Channels", 236, 52);
            cbChannels = new ComboBox();
            cbChannels.DropDownStyle = ComboBoxStyle.DropDownList;
            cbChannels.Items.AddRange(new object[] { "2 (stereo)", "1 (mono)" });
            cbChannels.SelectedIndex = 0;
            cbChannels.SetBounds(300, 49, 80, 22);
            g.Controls.Add(cbChannels);

            Lbl(g, "Sample rate", 10, 80);
            cbRate = new ComboBox();
            cbRate.DropDownStyle = ComboBoxStyle.DropDownList;
            cbRate.Items.AddRange(new object[] { "8000", "16000", "22050", "32000", "44100", "48000" });
            cbRate.SelectedIndex = 4;
            cbRate.SetBounds(96, 77, 80, 22);
            g.Controls.Add(cbRate);

            Lbl(g, "Chunk ms", 186, 80);
            numChunk = new NumericUpDown();
            numChunk.Minimum = 5; numChunk.Maximum = 200; numChunk.Value = 20;
            numChunk.SetBounds(256, 77, 60, 22);
            numChunk.ValueChanged += delegate { RecountDelay(); };
            g.Controls.Add(numChunk);

            Lbl(g, "Prebuffer ms", 10, 110);
            numPrebuffer = new NumericUpDown();
            numPrebuffer.Minimum = 0; numPrebuffer.Maximum = 2000; numPrebuffer.Increment = 10;
            numPrebuffer.Value = 260;
            numPrebuffer.SetBounds(96, 107, 70, 22);
            numPrebuffer.ValueChanged += delegate { RecountDelay(); };
            g.Controls.Add(numPrebuffer);

            Label hint = new Label();
            hint.Text = "Prebuffer is the audio held in the phone to ride out hiccups.\n"
                      + "This is the knob that stops it skipping - 200-300 ms is plenty.";
            hint.ForeColor = Color.FromArgb(90, 90, 90);
            hint.SetBounds(174, 100, 210, 34);
            g.Controls.Add(hint);
        }

        void BuildOptionsGroup()
        {
            GroupBox g = Box("3. Options", 10, 320, 390, 132);

            chkAuto = new CheckBox();
            chkAuto.Text = "Auto quality: step down the bitrate if the link cannot keep up";
            chkAuto.Checked = true;
            chkAuto.SetBounds(12, 22, 370, 20);
            g.Controls.Add(chkAuto);

            chkSilence = new CheckBox();
            chkSilence.Text = "Silence the laptop while sending";
            chkSilence.SetBounds(12, 48, 370, 20);
            chkSilence.CheckedChanged += delegate { OnSilenceToggled(); };
            g.Controls.Add(chkSilence);

            cbSilenceMode = new ComboBox();
            cbSilenceMode.DropDownStyle = ComboBoxStyle.DropDownList;
            cbSilenceMode.Items.AddRange(new object[] {
                "Set volume to zero (keeps the capture alive on more drivers)",
                "Mute the device (some drivers mute the capture too)" });
            cbSilenceMode.SelectedIndex = 0;
            cbSilenceMode.SetBounds(34, 70, 348, 22);
            g.Controls.Add(cbSilenceMode);

            lblSilenceState = new Label();
            lblSilenceState.SetBounds(12, 96, 370, 30);
            lblSilenceState.ForeColor = Color.FromArgb(90, 90, 90);
            lblSilenceState.Text = "Untested on this machine.";
            g.Controls.Add(lblSilenceState);
        }

        void BuildRunGroup()
        {
            btnStart = new Button();
            btnStart.Text = "Start sending";
            btnStart.SetBounds(10, 458, 390, 34);
            btnStart.Click += delegate { Toggle(); };
            Controls.Add(btnStart);
        }

        void BuildDelayGroup()
        {
            GroupBox g = Box("4. Latency to dial into your player", 408, 8, 382, 186);

            Lbl(g, "Phone buffer", 10, 24);
            cbPhoneBuffer = new ComboBox();
            cbPhoneBuffer.DropDownStyle = ComboBoxStyle.DropDownList;
            cbPhoneBuffer.Items.AddRange(new object[] {
                "Low latency (x2)", "Balanced (x4)", "Tolerant (x8)",
                "Very tolerant (x16) - recommended" });
            cbPhoneBuffer.SelectedIndex = 3;
            cbPhoneBuffer.SetBounds(110, 21, 258, 22);
            cbPhoneBuffer.SelectedIndexChanged += delegate { RecountDelay(); };
            g.Controls.Add(cbPhoneBuffer);

            Lbl(g, "Headphone", 10, 52);
            cbHeadphone = new ComboBox();
            cbHeadphone.DropDownStyle = ComboBoxStyle.DropDownList;
            cbHeadphone.Items.AddRange(DelayModel.HeadphoneChoices);
            cbHeadphone.SelectedIndex = 0;
            cbHeadphone.SetBounds(110, 49, 258, 22);
            cbHeadphone.SelectedIndexChanged += delegate { RecountDelay(); };
            g.Controls.Add(cbHeadphone);

            Lbl(g, "Custom ms", 10, 80);
            numCustomHp = new NumericUpDown();
            numCustomHp.Minimum = 0; numCustomHp.Maximum = 3000; numCustomHp.Increment = 10;
            numCustomHp.SetBounds(110, 77, 70, 22);
            numCustomHp.ValueChanged += delegate { RecountDelay(); };
            g.Controls.Add(numCustomHp);

            lblTotal = new Label();
            lblTotal.Font = new Font("Segoe UI", 10.5f, FontStyle.Bold);
            lblTotal.SetBounds(12, 108, 356, 44);
            g.Controls.Add(lblTotal);

            btnCopyDelay = new Button();
            btnCopyDelay.Text = "Copy this number";
            btnCopyDelay.SetBounds(12, 154, 130, 24);
            btnCopyDelay.Click += delegate
            {
                try { Clipboard.SetText(TotalDelay().ToString() + " ms"); } catch { }
            };
            g.Controls.Add(btnCopyDelay);

            Label hint = new Label();
            hint.Text = "Use it as the audio delay in your video player / LagSync.";
            hint.ForeColor = Color.FromArgb(90, 90, 90);
            hint.SetBounds(150, 158, 218, 18);
            g.Controls.Add(hint);
        }

        void BuildStatsGroup()
        {
            GroupBox g = Box("5. Live", 408, 202, 382, 112);
            lblStats = new Label();
            lblStats.SetBounds(12, 22, 358, 20);
            g.Controls.Add(lblStats);
            lblBacklog = new Label();
            lblBacklog.SetBounds(12, 44, 358, 20);
            g.Controls.Add(lblBacklog);
            lblCongestion = new Label();
            lblCongestion.SetBounds(12, 66, 358, 34);
            g.Controls.Add(lblCongestion);
        }

        void BuildLog()
        {
            GroupBox g = Box("Log", 408, 320, 382, 212);
            txtLog = new TextBox();
            txtLog.Multiline = true;
            txtLog.ReadOnly = true;
            txtLog.ScrollBars = ScrollBars.Vertical;
            txtLog.WordWrap = false;
            txtLog.SetBounds(12, 22, 358, 178);
            txtLog.BackColor = Color.White;
            g.Controls.Add(txtLog);
        }

        // --------------------------------------------------------------- helpers
        void Log(string line)
        {
            if (InvokeRequired) { BeginInvoke(new Action<string>(Log), line); return; }
            txtLog.AppendText(DateTime.Now.ToString("HH:mm:ss") + "  " + line + "\r\n");
        }

        void RefreshPorts()
        {
            string keep = cbPort.Text;
            cbPort.Items.Clear();
            string[] ports = SerialSink.Ports();
            cbPort.Items.AddRange(ports);
            if (keep.Length > 0) cbPort.Text = keep;
            else if (ports.Length > 0)
            {
                // the phone's port is named after it; prefer anything that is not COM1
                foreach (string p in ports) if (!p.Equals("COM1", StringComparison.OrdinalIgnoreCase)) { cbPort.Text = p; break; }
            }
        }

        void RefreshDevices()
        {
            cbDevice.Items.Clear();
            cbDevice.Items.Add("(system default)");
            try
            {
                List<EndpointInfo> list = Endpoints.ListRender();
                foreach (EndpointInfo e in list) cbDevice.Items.Add(e);
            }
            catch (Exception ex) { Log("could not list audio devices: " + ex.Message); }
            cbDevice.SelectedIndex = 0;
        }

        void PopulatePresets()
        {
            foreach (Preset p in Presets.All) cbPreset.Items.Add(p);
            cbPreset.SelectedIndex = 0;
        }

        void ApplyPreset()
        {
            Preset p = cbPreset.SelectedItem as Preset;
            if (p == null) return;
            cbCodec.SelectedIndex = p.Codec == Codec.Adpcm ? 0 : 1;
            cbChannels.SelectedIndex = p.Channels == 1 ? 1 : 0;
            for (int i = 0; i < cbRate.Items.Count; i++)
                if (cbRate.Items[i].ToString() == p.Rate.ToString()) cbRate.SelectedIndex = i;
            numChunk.Value = p.ChunkMs;
            numPrebuffer.Value = p.PrebufferMs;
            RecountDelay();
        }

        SenderSettings Collect()
        {
            SenderSettings s = new SenderSettings();
            s.Codec = cbCodec.SelectedIndex == 0 ? Codec.Adpcm : Codec.Pcm16;
            s.Channels = cbChannels.SelectedIndex == 0 ? 2 : 1;
            s.Rate = int.Parse(cbRate.SelectedItem.ToString());
            s.ChunkMs = (int)numChunk.Value;
            s.PrebufferMs = (int)numPrebuffer.Value;
            s.AutoQuality = chkAuto.Checked;
            s.PhoneBufferMult = 2 << cbPhoneBuffer.SelectedIndex;   // x2, x4, x8, x16
            s.FileMode = false;
            return s;
        }

        int TotalDelay()
        {
            int hp = HeadphoneMs();
            return DelayModel.ToPhoneMs((int)numPrebuffer.Value, (int)numChunk.Value) + hp;
        }

        int HeadphoneMs()
        {
            if (cbHeadphone.SelectedIndex == DelayModel.HeadphoneChoices.Length - 1)
                return (int)numCustomHp.Value;
            return DelayModel.HeadphoneMs(cbHeadphone.SelectedIndex);
        }

        void RecountDelay()
        {
            int toPhone = DelayModel.ToPhoneMs((int)numPrebuffer.Value, (int)numChunk.Value);
            int total = toPhone + HeadphoneMs();

            int cap = DelayModel.PhoneCapacityMs((int)numChunk.Value, 2 << cbPhoneBuffer.SelectedIndex);
            bool over = (int)numPrebuffer.Value > cap;

            lblTotal.Text = "Total: about " + total + " ms\r\n"
                          + "laptop to phone ~" + toPhone + " ms, headphones +" + HeadphoneMs() + " ms"
                          + (over ? "\r\n! prebuffer above the phone's " + cap + " ms buffer" : "");
            lblTotal.ForeColor = over ? Color.Firebrick : Color.FromArgb(20, 90, 40);
        }

        // ------------------------------------------------------------- silence
        void OnSilenceToggled()
        {
            if (sender == null)
            {
                lblSilenceState.Text = chkSilence.Checked
                    ? "Will silence the laptop once sending starts."
                    : "Laptop will keep playing through its own speakers.";
                return;
            }
            if (chkSilence.Checked) ApplySilence();
            else UndoSilence("Laptop audio restored.");
        }

        void ApplySilence()
        {
            try
            {
                if (silencer == null)
                {
                    silencer = new Silencer(silenceDeviceId);
                    lblSilenceState.Text = silencer.HardwareVolume
                        ? "Driver does volume in hardware - the capture may go silent too. Watching..."
                        : "Driver does volume in software - good sign. Watching...";
                }
                peakBeforeSilence = last != null ? last.SourcePeak : -1;
                silencer.Silence(cbSilenceMode.SelectedIndex == 0);
                silenceToggledAt = Environment.TickCount;
            }
            catch (Exception ex)
            {
                chkSilence.Checked = false;
                lblSilenceState.Text = "Could not silence: " + ex.Message;
            }
        }

        void UndoSilence(string why)
        {
            if (silencer != null) silencer.Restore();
            lblSilenceState.Text = why;
            silenceToggledAt = -1;
        }

        /// <summary>
        /// Watches whether the mute killed the capture tap. If audio was clearly
        /// flowing before and the tap goes silent after, the driver applies the
        /// mute after the tap, and keeping it on would send silence to the
        /// phone - so it is undone automatically.
        /// </summary>
        void SilenceTick(object o, EventArgs e)
        {
            if (!chkSilence.Checked || silencer == null || last == null) return;
            if (silenceToggledAt < 0 || Environment.TickCount - silenceToggledAt < 2500) return;

            if (peakBeforeSilence > 300 && last.SourcePeak < 60 && last.SentMs > 3000)
            {
                chkSilence.Checked = false;
                UndoSilence("This driver mutes the capture too, so the phone would have got silence. "
                            + "Undone. Use a virtual cable device instead (see the tip above).");
            }
            else if (peakBeforeSilence <= 300)
            {
                // nothing was playing to begin with; re-arm and keep watching
                peakBeforeSilence = last.SourcePeak > 300 ? -1 : peakBeforeSilence;
            }
        }

        // ------------------------------------------------------------------ run
        void Toggle()
        {
            if (sender != null) { Stop(); return; }
            Start();
        }

        void Start()
        {
            SenderSettings s = Collect();
            bool fileMode = cbFile.Text.Length > 0 && File.Exists(cbFile.Text);
            s.FileMode = fileMode;
            if (fileMode) Log("file mode: " + cbFile.Text);

            IAudioSource source;
            IByteSink sink;
            try
            {
                if (fileMode) source = new WavFileSource(cbFile.Text);
                else
                {
                    EndpointInfo dev = cbDevice.SelectedItem as EndpointInfo;
                    silenceDeviceId = dev != null ? dev.Id : null;
                    WasapiSource w = new WasapiSource(silenceDeviceId);
                    w.Open();
                    Log("capturing " + w.Rate + " Hz, " + w.Channels + " ch, "
                        + (w.IsFloat ? "float32" : "s16"));
                    source = w;
                }
                sink = new SerialSink(cbPort.Text.Trim());
            }
            catch (Exception ex)
            {
                Log("could not start: " + Innermost(ex).Message);
                return;
            }

            liveSource = source;
            // Never ask for more than the phone can hold.
            int cap = DelayModel.PhoneCapacityMs(s.ChunkMs, s.PhoneBufferMult);
            if (s.PrebufferMs > cap)
            {
                Log("prebuffer reduced to " + cap + " ms: that is the phone's buffer at this chunk size");
                s.PrebufferMs = cap;
                numPrebuffer.Value = cap;
            }

            cancel = new CancellationTokenSource();
            Sender sd = new Sender(source, sink, s, Log, OnStats);
            sender = sd;
            worker = new Thread(delegate ()
            {
                try { sd.Run(cancel.Token); }
                catch (OperationCanceledException) { }
                catch (Exception ex) { Log("stopped: " + Innermost(ex).Message); }
                BeginInvoke(new Action(Stopped));
            });
            worker.IsBackground = true;
            worker.Start();

            btnStart.Text = "Stop";
            if (chkSilence.Checked) ApplySilence();
            silenceWatch = new System.Windows.Forms.Timer();
            silenceWatch.Interval = 1000;
            silenceWatch.Tick += SilenceTick;
            silenceWatch.Start();
        }

        void Stop()
        {
            if (cancel != null) cancel.Cancel();
            if (silencer != null) UndoSilence("Laptop audio restored.");
            if (silenceWatch != null) { silenceWatch.Stop(); silenceWatch = null; }
        }

        void Stopped()
        {
            if (silenceWatch != null) { silenceWatch.Stop(); silenceWatch = null; }
            if (silencer != null) UndoSilence("Laptop audio restored.");
            sender = null;
            worker = null;
            btnStart.Text = "Start sending";
        }

        void OnStats(SenderStats st)
        {
            last = st;
            if (IsDisposed || !IsHandleCreated) return;
            try
            {
                BeginInvoke(new Action<SenderStats>(ShowStats), st);
            }
            catch { }
        }

        void ShowStats(SenderStats st)
        {
            lblStats.Text = st.RungName + "   " + st.KbitsPerSec.ToString("0") + " kbit/s wire"
                          + "   " + st.ChunksSent + " chunks   "
                          + (st.Primed ? "primed" : "priming...");
            lblBacklog.Text = "sent " + (st.SentMs / 1000).ToString("0.0") + " s   "
                            + "held in sender " + st.BacklogMs.ToString("0") + " ms   "
                            + "write " + st.WriteMsMedian.ToString("0.0") + " ms ("
                            + (st.BlockedFraction * 100).ToString("0") + "% blocked)";
            if (st.BlockedFraction > 0.2 || st.BacklogMs > 800)
                lblCongestion.Text = "Link is struggling. Auto quality will step the bitrate down.";
            else if (st.BacklogMs > 250)
                lblCongestion.Text = "Buffering a little - this is the link catching up, not a fault.";
            else
                lblCongestion.Text = "";
        }

        void OnClosing(object o, FormClosingEventArgs e)
        {
            Stop();
            if (worker != null) worker.Join(1500);
            if (liveSource != null) { try { liveSource.Close(); } catch { } }
        }

        static Exception Innermost(Exception e)
        {
            while (e.InnerException != null) e = e.InnerException;
            return e;
        }
    }
}
