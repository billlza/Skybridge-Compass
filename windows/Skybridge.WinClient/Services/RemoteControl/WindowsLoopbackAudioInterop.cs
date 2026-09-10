using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Threading;

namespace Skybridge.WinClient.Services.RemoteControl;

internal sealed class WindowsAudioOutputUnavailableException : IOException
{
    internal const int EndpointNotFound = unchecked((int)0x80070490);

    internal WindowsAudioOutputUnavailableException()
        : base("This computer has no default system audio output (HRESULT 0x80070490).",
            Marshal.GetExceptionForHR(EndpointNotFound))
    {
        HResult = EndpointNotFound;
    }
}

internal interface IWindowsLoopbackCapture
{
    void Run(Action<WindowsPcmAudioFrame> onFrame, Action onReady, CancellationToken cancellationToken);
}

internal sealed class WindowsWasapiLoopbackCapture : IWindowsLoopbackCapture
{
    private const uint ClsctxAll = 0x17;
    private const uint StreamFlags = 0x00020000 | 0x00040000 | 0x80000000 | 0x08000000;
    private const uint DataDiscontinuity = 0x1;
    private const uint Silent = 0x2;
    private const int BufferEmpty = 0x08890001;
    private const int MaxCaptureFrames = 48_000;
    private static readonly Guid EnumeratorClass = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    private static readonly Guid EnumeratorInterface = new("A95664D2-9614-4F35-A746-DE8DB63617E6");
    private static readonly Guid AudioClientInterface = new("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
    private static readonly Guid CaptureClientInterface = new("C8ADBD64-E71E-48A0-A4DE-185C395CD317");

    public void Run(Action<WindowsPcmAudioFrame> onFrame, Action onReady, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(onFrame);
        ArgumentNullException.ThrowIfNull(onReady);
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            throw new PlatformNotSupportedException("System audio capture requires Windows 10 version 2004 or later.");
        }

        RunWindows(onFrame, onReady, cancellationToken);
    }

    [SupportedOSPlatform("windows10.0.19041")]
    private static void RunWindows(Action<WindowsPcmAudioFrame> onFrame, Action onReady, CancellationToken cancellationToken)
    {
        RequireSuccess(CoInitializeEx(IntPtr.Zero, 0), "initialize capture COM apartment");
        IMMDeviceEnumerator? enumerator = null;
        IMMDevice? device = null;
        IAudioClient? audio = null;
        IAudioCaptureClient? capture = null;
        var started = false;
        Exception? operationError = null;
        var cleanupErrors = new List<Exception>();
        using var available = new AutoResetEvent(false);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var classId = EnumeratorClass;
            var interfaceId = EnumeratorInterface;
            RequireSuccess(CoCreateInstance(ref classId, IntPtr.Zero, ClsctxAll, ref interfaceId, out enumerator), "create audio endpoint enumerator");
            RequireDefaultAudioOutput(enumerator.GetDefaultAudioEndpoint(0, 1, out device));
            interfaceId = AudioClientInterface;
            RequireSuccess(device.Activate(ref interfaceId, ClsctxAll, IntPtr.Zero, out var audioObject), "activate loopback audio client");
            audio = (IAudioClient)audioObject;

            // Shared-mode conversion is explicit: the audio engine converts its
            // mix to exactly the PCM format consumed by the Opus packetizer.
            var format = new WaveFormatEx
            {
                FormatTag = 1,
                Channels = WindowsOpusAudioEncoder.Channels,
                SamplesPerSecond = WindowsOpusAudioEncoder.SampleRate,
                AverageBytesPerSecond = WindowsOpusAudioEncoder.SampleRate * WindowsOpusAudioEncoder.Channels * sizeof(short),
                BlockAlign = WindowsOpusAudioEncoder.Channels * sizeof(short),
                BitsPerSample = 16,
                ExtraSize = 0
            };
            RequireSuccess(audio.Initialize(0, StreamFlags, 0, 0, ref format, IntPtr.Zero), "initialize 48 kHz stereo loopback stream");
            RequireSuccess(audio.SetEventHandle(available.SafeWaitHandle.DangerousGetHandle()), "set loopback audio event");
            interfaceId = CaptureClientInterface;
            RequireSuccess(audio.GetService(ref interfaceId, out var captureObject), "open loopback capture service");
            capture = (IAudioCaptureClient)captureObject;
            RequireSuccess(audio.Start(), "start loopback capture");
            started = true;
            onReady();

            var packetizer = new WindowsPcmAudioPacketizer();
            var waits = new WaitHandle[] { cancellationToken.WaitHandle, available };
            while (!cancellationToken.IsCancellationRequested)
            {
                // A quiet render endpoint may produce no packets. Silence is
                // never invented to make a capture look active.
                if (WaitHandle.WaitAny(waits, 1000) == 0)
                {
                    break;
                }

                Drain(capture, packetizer, onFrame, cancellationToken);
            }
        }
        catch (Exception error)
        {
            operationError = error;
        }
        finally
        {
            if (started && audio is not null)
            {
                var result = audio.Stop();
                if (result < 0)
                {
                    cleanupErrors.Add(CreateError(result, "stop loopback capture"));
                }
            }

            Release(capture, cleanupErrors);
            Release(audio, cleanupErrors);
            Release(device, cleanupErrors);
            Release(enumerator, cleanupErrors);
            CoUninitialize();
        }

        if (cleanupErrors.Count > 0)
        {
            if (operationError is not null)
            {
                cleanupErrors.Insert(0, operationError);
            }

            throw new AggregateException("Loopback capture shutdown reported errors.", cleanupErrors);
        }

        if (operationError is not null)
        {
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(operationError).Throw();
        }
    }

    private static void Drain(
        IAudioCaptureClient capture,
        WindowsPcmAudioPacketizer packetizer,
        Action<WindowsPcmAudioFrame> onFrame,
        CancellationToken cancellationToken)
    {
        RequireSuccess(capture.GetNextPacketSize(out var nextFrames), "read loopback packet size");
        while (nextFrames > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = capture.GetBuffer(out var data, out var frames, out var flags, out _, out _);
            if (result == BufferEmpty)
            {
                return;
            }

            RequireSuccess(result, "read loopback audio buffer");
            try
            {
                if (frames is 0 or > MaxCaptureFrames)
                {
                    throw new InvalidDataException("The loopback capture packet has an invalid frame count.");
                }

                var samples = new short[checked((int)frames * WindowsOpusAudioEncoder.Channels)];
                if ((flags & Silent) == 0)
                {
                    if (data == IntPtr.Zero)
                    {
                        throw new InvalidDataException("The loopback capture buffer is missing non-silent PCM data.");
                    }

                    Marshal.Copy(data, samples, 0, samples.Length);
                }

                packetizer.Append(samples, (flags & DataDiscontinuity) != 0, onFrame);
            }
            finally
            {
                RequireSuccess(capture.ReleaseBuffer(frames), "release loopback audio buffer");
            }

            RequireSuccess(capture.GetNextPacketSize(out nextFrames), "read next loopback packet size");
        }
    }

    internal static void RequireDefaultAudioOutput(int result)
    {
        if (result == WindowsAudioOutputUnavailableException.EndpointNotFound)
        {
            throw new WindowsAudioOutputUnavailableException();
        }

        RequireSuccess(result, "resolve default multimedia output");
    }

    private static void RequireSuccess(int result, string operation)
    {
        if (result < 0)
        {
            throw CreateError(result, operation);
        }
    }

    private static IOException CreateError(int result, string operation) =>
        new($"Unable to {operation} (HRESULT 0x{result:X8}).", Marshal.GetExceptionForHR(result));

    [SupportedOSPlatform("windows")]
    private static void Release(object? value, ICollection<Exception> errors)
    {
        if (value is null)
        {
            return;
        }

        try
        {
            Marshal.ReleaseComObject(value);
        }
        catch (InvalidComObjectException error)
        {
            errors.Add(error);
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct WaveFormatEx
    {
        public ushort FormatTag;
        public ushort Channels;
        public uint SamplesPerSecond;
        public uint AverageBytesPerSecond;
        public ushort BlockAlign;
        public ushort BitsPerSample;
        public ushort ExtraSize;
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, uint stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr callback);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr callback);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr activationParameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        [PreserveSig] int OpenPropertyStore(uint access, out IntPtr properties);
        [PreserveSig] int GetId(out IntPtr id);
        [PreserveSig] int GetState(out uint state);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, uint flags, long bufferDuration, long periodicity, ref WaveFormatEx format, IntPtr sessionId);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint frames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closestFormat);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong performanceCounterPosition);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoInitializeEx(IntPtr reserved, uint concurrencyModel);

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern void CoUninitialize();

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(ref Guid classId, IntPtr outer, uint context, ref Guid iid, out IMMDeviceEnumerator enumerator);
}
