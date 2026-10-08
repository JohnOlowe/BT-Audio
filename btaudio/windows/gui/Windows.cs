// ---------------------------------------------------------------------------
// BtAudioSender - Windows-specific parts.
//
// Every COM GUID, every vtable member and its order was read verbatim from
// NAudio's CoreAudioApi declarations rather than typed from memory: COM binds
// methods by vtable position, so one missing member silently calls the wrong
// function. If you change anything here, check it against NAudio first.
//
// Only compiled into the Windows .exe. The portable core stays testable.
// ---------------------------------------------------------------------------
using System;
using System.Collections.Generic;
using System.IO.Ports;
using System.Runtime.InteropServices;

namespace BtAudio
{
    // ---------------------------------------------------------------- COM types
    internal static class CA
    {
        public const int CLSCTX_ALL = 0x17;
        public const int STGM_READ = 0;
        public const int DEVICE_STATE_ACTIVE = 0x1;
        public const int eRender = 0, eCapture = 1, eAll = 2;
        public const int eConsole = 0;
        public const int SHARE_SHARED = 0;
        public const int AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;
        public const uint AUDCLNT_BUFFERFLAGS_SILENT = 0x2;
        public const int REFTIMES_PER_SEC = 10000000;
        public const ushort WAVE_FORMAT_PCM = 1, WAVE_FORMAT_IEEE_FLOAT = 3, WAVE_FORMAT_EXTENSIBLE = 0xFFFE;
        public const ushort VT_LPWSTR = 31;

        public static readonly Guid CLSID_MMDeviceEnumerator =
            new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        public static readonly Guid IID_IMMDeviceEnumerator =
            new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
        public static readonly Guid IID_IMMDevice =
            new Guid("D666063F-1587-4E43-81F1-B948E807363F");
        public static readonly Guid IID_IAudioClient =
            new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
        public static readonly Guid IID_IAudioCaptureClient =
            new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");
        public static readonly Guid IID_IAudioEndpointVolume =
            new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");

        public static readonly Guid PKEY_Device_FriendlyName =
            new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");
        public static readonly Guid PKEY_Device_DeviceDesc =
            new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");
        public static readonly int PID_FriendlyName = 14;
        public static readonly int PID_DeviceDesc = 2;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct PropertyKey { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct WaveFormatEx
    {
        public ushort wFormatTag, nChannels;
        public int nSamplesPerSec, nAvgBytesPerSec;
        public ushort nBlockAlign, wBitsPerSample, cbSize;
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IntPtr endpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection
    {
        int GetCount(out int numDevices);
        int Item(int deviceNumber, out IntPtr device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        int Activate(ref Guid id, int clsCtx, IntPtr activationParams, out IntPtr interfacePointer);
        int OpenPropertyStore(int stgmAccess, out IntPtr properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        int GetCount(out int propCount);
        int GetAt(int property, out PropertyKey key);
        int GetValue(ref PropertyKey key, IntPtr propVariantBuffer);
        int SetValue(ref PropertyKey key, IntPtr propVariantBuffer);
        int Commit();
    }

    // Full vtable, in order. Declaring a subset would shift the indices.
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioEndpointVolume
    {
        int RegisterControlChangeNotify(IntPtr pNotify);
        int UnregisterControlChangeNotify(IntPtr pNotify);
        int GetChannelCount(out int pnChannelCount);
        int SetMasterVolumeLevel(float fLevelDB, ref Guid pguidEventContext);
        int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
        int GetMasterVolumeLevel(out float pfLevelDB);
        int GetMasterVolumeLevelScalar(out float pfLevel);
        int SetChannelVolumeLevel(uint nChannel, float fLevelDB, ref Guid pguidEventContext);
        int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, ref Guid pguidEventContext);
        int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
        int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid pguidEventContext);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
        int GetVolumeStepInfo(out int pnStep, out int pnStepCount);
        int VolumeStepUp(ref Guid pguidEventContext);
        int VolumeStepDown(ref Guid pguidEventContext);
        int QueryHardwareSupport(out uint pdwHardwareSupportMask);
        int GetVolumeRange(out float pflVolumeMindB, out float pflVolumeMaxdB, out float pflVolumeIncrementdB);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioClient
    {
        int Initialize(int shareMode, int streamFlags, long hnsBufferDuration,
                       long hnsPeriodicity, IntPtr pFormat, ref Guid audioSessionGuid);
        int GetBufferSize(out uint numBufferFrames);
        int GetStreamLatency(out long latency);
        int GetCurrentPadding(out uint numPaddingFrames);
        int IsFormatSupported(int shareMode, IntPtr pFormat, out IntPtr closestMatch);
        int GetMixFormat(out IntPtr deviceFormat);
        int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr eventHandle);
        int GetService(ref Guid riid, out IntPtr ppv);
    }

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioCaptureClient
    {
        int GetBuffer(out IntPtr data, out int numFrames,
                      out uint flags, out long devicePosition, out long qpcPosition);
        int ReleaseBuffer(int numFramesRead);
        int GetNextPacketSize(out int numFramesInNextPacket);
    }

    // ------------------------------------------------------------- loopback tap
    /// <summary>WASAPI loopback capture of a render endpoint. This is what makes
    /// "record what the laptop is playing" possible without a cable, and it is a
    /// passive tap: the audio keeps playing locally too.</summary>
    public sealed class WasapiSource : IAudioSource
    {
        readonly string deviceId;                 // null = system default
        IAudioClient client;
        IAudioCaptureClient capture;
        IntPtr fmtPtr = IntPtr.Zero;
        byte[] poke = new byte[4096];

        public int Rate { get; private set; }
        public int Channels { get; private set; }
        public bool IsFloat { get; private set; }
        public int FrameBytes { get { return Channels * (IsFloat ? 4 : 2); } }
        public int LastPeak { get; private set; }
        public bool Exhausted { get { return false; } }   // a live tap is never done
        public string DeviceName;

        long framesRead;        // frames actually handed over
        long gapFrames;         // frames the device skipped, inferred from timestamps
        long lastQpc = -1;      // qpcPosition of the previous packet
        public long PositionFrames { get { return framesRead + gapFrames; } }

        public WasapiSource(string id) { deviceId = id; }

        public void Open()
        {
            if (client != null) return;                  // idempotent
            object o = Activator.CreateInstance(Type.GetTypeFromCLSID(CA.CLSID_MMDeviceEnumerator));
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)o;

            IntPtr devPtr;
            int hr;
            if (deviceId == null)
            {
                // eRender + the loopback flag = "record what you hear". eCapture
                // would be the microphone, the opposite of what this is for.
                hr = en.GetDefaultAudioEndpoint(CA.eRender, CA.eConsole, out devPtr);
            }
            else
            {
                hr = en.GetDevice(deviceId, out devPtr);
            }
            Check(hr, "GetAudioEndpoint");
            IMMDevice dev = (IMMDevice)Marshal.GetObjectForIUnknown(devPtr);

            Guid iidClient = CA.IID_IAudioClient;
            Guid iidCapture = CA.IID_IAudioCaptureClient;

            IntPtr cliPtr;
            Check(dev.Activate(ref iidClient, CA.CLSCTX_ALL, IntPtr.Zero, out cliPtr), "Activate");
            client = (IAudioClient)Marshal.GetObjectForIUnknown(cliPtr);

            Check(client.GetMixFormat(out fmtPtr), "GetMixFormat");
            WaveFormatEx fmt = (WaveFormatEx)Marshal.PtrToStructure(fmtPtr, typeof(WaveFormatEx));
            Rate = fmt.nSamplesPerSec;
            Channels = fmt.nChannels;
            IsFloat = IsFloatFormat(fmt, fmtPtr);

            Check(client.Initialize(CA.SHARE_SHARED, CA.AUDCLNT_STREAMFLAGS_LOOPBACK,
                                   200 * CA.REFTIMES_PER_SEC / 1000, 0, fmtPtr, ref iidClient),
                  "Initialize(loopback)");
            Check(client.GetService(ref iidCapture, out cliPtr), "GetService(IAudioCaptureClient)");
            capture = (IAudioCaptureClient)Marshal.GetObjectForIUnknown(cliPtr);
            Check(client.Start(), "Start");
        }

        static bool IsFloatFormat(WaveFormatEx f, IntPtr p)
        {
            if (f.wFormatTag == CA.WAVE_FORMAT_IEEE_FLOAT) return true;
            if (f.wFormatTag != CA.WAVE_FORMAT_EXTENSIBLE) return false;
            // WAVEFORMATEXTENSIBLE: the SubFormat GUID's first dword is the tag
            return (uint)Marshal.ReadInt32(new IntPtr(p.ToInt64() + 24)) == CA.WAVE_FORMAT_IEEE_FLOAT;
        }

        public int Poll(byte[] dst, int maxFrames)
        {
            int total = 0;
            int peak = 0;
            while (true)
            {
                int avail;
                if (capture.GetNextPacketSize(out avail) != 0 || avail == 0) break;

                IntPtr data;
                int frames;
                uint flags;
                long devPos, qpcPos;
                Check(capture.GetBuffer(out data, out frames, out flags, out devPos, out qpcPos), "GetBuffer");

                // qpcPosition is the device's own timestamp for the first frame
                // of this packet. Consecutive packets are one buffer apart while
                // something is playing; a bigger jump means the endpoint went
                // quiet in between, and the difference is what has to be filled
                // with silence.
                if (lastQpc >= 0)
                {
                    long delta = qpcPos - lastQpc;
                    long covered = (long)frames * 10000000L / Rate;
                    if (delta > covered && delta < 60L * 10000000L)
                        gapFrames += (delta - covered) * Rate / 10000000L;
                }
                lastQpc = qpcPos;

                int room = maxFrames - total;
                if (frames > room) frames = room;
                int bytes = frames * FrameBytes;
                if (flags == CA.AUDCLNT_BUFFERFLAGS_SILENT || data == IntPtr.Zero)
                {
                    Array.Clear(dst, total * FrameBytes, bytes);
                }
                else
                {
                    Marshal.Copy(data, dst, total * FrameBytes, bytes);
                    peak = Peak(dst, total * FrameBytes, bytes);
                }
                capture.ReleaseBuffer(frames);
                framesRead += frames;
                total += frames;

                // Sounding returns zero bytes during bidirectional Bluetooth audio
                // and after a device change. Handing the caller a zero-frame read
                // is correct here: the engine's clock fills the gap with silence,
                // so the stream stays continuous instead of stalling.
                if (total >= maxFrames) break;
            }
            LastPeak = peak;
            return total;
        }

        static int Peak(byte[] b, int off, int len)
        {
            // Cheap level check on the first part of the buffer; only used to
            // tell "audio is flowing" from "the tap went silent".
            int n = Math.Min(len, 4096);
            int peak = 0;
            for (int i = 0; i + 1 < n; i += 2)
            {
                int v = (short)(b[off + i] | (b[off + i + 1] << 8));
                if (v < 0) v = -v;
                if (v > peak) peak = v;
            }
            return peak;
        }

        public void Close()
        {
            try { if (client != null) client.Stop(); } catch { }
            if (capture != null) { Marshal.ReleaseComObject(capture); capture = null; }
            if (client != null) { Marshal.ReleaseComObject(client); client = null; }
            if (fmtPtr != IntPtr.Zero) { Marshal.FreeCoTaskMem(fmtPtr); fmtPtr = IntPtr.Zero; }
        }

        static void Check(int hr, string what)
        {
            if (hr < 0) throw new InvalidOperationException(
                what + " failed: 0x" + ((uint)hr).ToString("X8") + " " + Describe(hr));
        }

        static string Describe(int hr)
        {
            switch ((uint)hr)
            {
                case 0x88890008: return "(device in use - is another loopback recorder running?)";
                case 0x88890007: return "(device not found)";
                case 0x80070005: return "(access denied)";
                default: return "";
            }
        }
    }

    // ------------------------------------------------------------------- output
    /// <summary>The Bluetooth virtual COM port. Baud rate is ignored by the
    /// driver; hardware handshaking is what matters, and it must be off - with
    /// DTR/RTS asserted some drivers wait forever for a flow-control edge that
    /// never comes.</summary>
    public sealed class SerialSink : IByteSink
    {
        readonly string port;
        SerialPort sp;

        public SerialSink(string port) { this.port = port; }
        public string Describe { get { return port; } }

        public void Open()
        {
            if (sp != null) return;
            sp = new SerialPort(port, 115200, Parity.None, 8, StopBits.One);
            sp.Handshake = Handshake.None;
            sp.DtrEnable = false;
            sp.RtsEnable = false;
            sp.WriteTimeout = 8000;
            sp.Open();
        }

        public void Write(byte[] buf, int off, int len)
        {
            if (len <= 0) return;
            sp.Write(buf, off, len);
        }

        public void Close()
        {
            if (sp == null) return;
            try { if (sp.IsOpen) sp.Close(); } catch { }
            try { sp.Dispose(); } catch { }
            sp = null;
        }

        public static string[] Ports()
        {
            try { return SerialPort.GetPortNames(); } catch { return new string[0]; }
        }
    }

    // ------------------------------------------------------- endpoint management
    public sealed class EndpointInfo
    {
        public string Id, Name;
        public override string ToString() { return Name; }
    }

    /// <summary>Render-endpoint enumeration and the "silence this laptop" switch.</summary>
    public static class Endpoints
    {
        public static List<EndpointInfo> ListRender()
        {
            List<EndpointInfo> list = new List<EndpointInfo>();
            object o = Activator.CreateInstance(Type.GetTypeFromCLSID(CA.CLSID_MMDeviceEnumerator));
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)o;
            IntPtr colPtr;
            if (en.EnumAudioEndpoints(CA.eRender, CA.DEVICE_STATE_ACTIVE, out colPtr) < 0) return list;
            IMMDeviceCollection col = (IMMDeviceCollection)Marshal.GetObjectForIUnknown(colPtr);
            int n;
            col.GetCount(out n);
            for (int i = 0; i < n; i++)
            {
                IntPtr devPtr;
                if (col.Item(i, out devPtr) < 0) continue;
                IMMDevice dev = (IMMDevice)Marshal.GetObjectForIUnknown(devPtr);
                EndpointInfo info = new EndpointInfo();
                dev.GetId(out info.Id);
                info.Name = FriendlyName(dev, CA.PID_FriendlyName);
                if (string.IsNullOrEmpty(info.Name)) info.Name = FriendlyName(dev, CA.PID_DeviceDesc);
                if (string.IsNullOrEmpty(info.Name)) info.Name = info.Id;
                list.Add(info);
                Marshal.ReleaseComObject(dev);
            }
            Marshal.ReleaseComObject(col);
            return list;
        }

        static string FriendlyName(IMMDevice dev, int pid)
        {
            IntPtr storePtr;
            if (dev.OpenPropertyStore(CA.STGM_READ, out storePtr) < 0) return null;
            IPropertyStore store = (IPropertyStore)Marshal.GetObjectForIUnknown(storePtr);
            PropertyKey key = new PropertyKey();
            key.fmtid = pid == CA.PID_FriendlyName ? CA.PKEY_Device_FriendlyName : CA.PKEY_Device_DeviceDesc;
            key.pid = pid;
            string result = null;
            IntPtr pv = Marshal.AllocCoTaskMem(32);
            try
            {
                if (store.GetValue(ref key, pv) == 0)
                {
                    ushort vt = (ushort)Marshal.ReadInt16(pv);
                    if (vt == CA.VT_LPWSTR)
                    {
                        IntPtr s = Marshal.ReadIntPtr(pv, 8);
                        if (s != IntPtr.Zero)
                        {
                            result = Marshal.PtrToStringUni(s);
                            Marshal.FreeCoTaskMem(s);       // PropVariantClear's job for VT_LPWSTR
                        }
                    }
                }
            }
            finally { Marshal.FreeCoTaskMem(pv); }
            Marshal.ReleaseComObject(store);
            return result;
        }

        internal static IAudioEndpointVolume Volume(string deviceId)
        {
            object o = Activator.CreateInstance(Type.GetTypeFromCLSID(CA.CLSID_MMDeviceEnumerator));
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)o;
            IntPtr devPtr;
            int hr = deviceId == null
                ? en.GetDefaultAudioEndpoint(CA.eRender, CA.eConsole, out devPtr)
                : en.GetDevice(deviceId, out devPtr);
            if (hr < 0) return null;
            IMMDevice dev = (IMMDevice)Marshal.GetObjectForIUnknown(devPtr);
            Guid iid = CA.IID_IAudioEndpointVolume;
            IntPtr volPtr;
            if (dev.Activate(ref iid, CA.CLSCTX_ALL, IntPtr.Zero, out volPtr) < 0) return null;
            return (IAudioEndpointVolume)Marshal.GetObjectForIUnknown(volPtr);
        }
    }

    /// <summary>
    /// "Silence this laptop while sending."
    ///
    /// Loopback is a passive tap: audio keeps playing on the laptop speakers
    /// too. Muting the endpoint fixes that on MOST machines, because the tap
    /// sits ahead of the volume control - but on some drivers, notably Realtek
    /// with Microsoft's generic driver, the mute is implemented after the tap
    /// and muting also silences the CAPTURE. That is why this is not automatic:
    /// the caller turns it on, checks whether the tap survived (by watching the
    /// source's peak level), and puts it back if it did not.
    /// </summary>
    public sealed class Silencer : IDisposable
    {
        readonly IAudioEndpointVolume vol;
        bool savedMute;
        float savedLevel;
        bool active;

        public bool VolumeWasUsed { get; private set; }
        public uint HardwareMask { get; private set; }

        public Silencer(string deviceId)
        {
            vol = Endpoints.Volume(deviceId);
            if (vol == null) throw new InvalidOperationException("no audio endpoint volume interface");
            uint mask;
            if (vol.QueryHardwareSupport(out mask) == 0) HardwareMask = mask;
            vol.GetMute(out savedMute);
            vol.GetMasterVolumeLevelScalar(out savedLevel);
        }

        /// <summary>True if this driver implements volume/mute in hardware, which
        /// is the case where muting is most likely to silence the tap as well.</summary>
        public bool HardwareVolume { get { return (HardwareMask & 0x1) != 0; } }

        /// <summary>Sets the master volume to zero rather than muting. Volume
        /// scaling is applied after the tap on more drivers than mute is, so
        /// this is the option that more often keeps the capture alive.</summary>
        public void Silence(bool useVolumeInsteadOfMute)
        {
            Guid ctx = Guid.Empty;
            if (useVolumeInsteadOfMute)
            {
                VolumeWasUsed = true;
                vol.SetMasterVolumeLevelScalar(0f, ref ctx);
            }
            else
            {
                VolumeWasUsed = false;
                vol.SetMute(true, ref ctx);
            }
            active = true;
        }

        public void Restore()
        {
            if (!active) return;
            Guid ctx = Guid.Empty;
            try
            {
                if (VolumeWasUsed) vol.SetMasterVolumeLevelScalar(savedLevel, ref ctx);
                else vol.SetMute(savedMute, ref ctx);
            }
            catch { }
            active = false;
        }

        public void Dispose() { Restore(); }
    }
}
