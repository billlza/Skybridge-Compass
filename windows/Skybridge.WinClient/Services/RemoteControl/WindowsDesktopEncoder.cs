using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using SharpGen.Runtime;
using Vortice.MediaFoundation;

namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>Media Foundation resize/NV12 conversion and low-latency system H.264 encoding.</summary>
[SupportedOSPlatform("windows10.0.19041")]
internal sealed class WindowsDesktopEncoder : IWindowsDesktopEncoder
{
    private readonly BlockingCollection<EncoderRequest> _requests = new(1);
    private readonly TaskCompletionSource<Exception?> _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource<Exception?> _stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object _gate = new();
    private readonly Thread _thread;
    private WindowsDesktopEncodingOptions _options;
    private bool _disposed;

    public WindowsDesktopEncoder(WindowsDesktopEncodingOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        options.RequireValid();
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Media Foundation desktop encoding requires Windows.");
        _options = options;
        _thread = new Thread(Run) { IsBackground = true, Name = "SkyBridge desktop encoder" };
        _thread.Start();
        var failure = _ready.Task.GetAwaiter().GetResult();
        if (failure is not null)
        {
            _thread.Join();
            _requests.Dispose();
            throw new WindowsDesktopException(WindowsDesktopFailure.EncoderUnavailable, "The Windows Media Foundation desktop encoder could not start.",
                _stopped.Task.GetAwaiter().GetResult() ?? failure);
        }
    }

    public WindowsDesktopEncodingOptions Options => Volatile.Read(ref _options);
    public bool IsHardwareAccelerated => false;

    public IReadOnlyList<WindowsDesktopEncodedFrame> Encode(WindowsDesktopFrame frame, bool forceKeyFrame = false)
    {
        ArgumentNullException.ThrowIfNull(frame);
        lock (_gate) { return Invoke(encoder => encoder.Encode(frame, forceKeyFrame)); }
    }

    public void UpdateBitrate(int bitrateBitsPerSecond)
    {
        lock (_gate)
        {
            var options = _options with { BitrateBitsPerSecond = bitrateBitsPerSecond };
            options.RequireValid();
            Invoke(encoder => { encoder.UpdateBitrate(bitrateBitsPerSecond); return true; });
            Volatile.Write(ref _options, options);
        }
    }

    public void RequestKeyFrame()
    {
        lock (_gate) { Invoke(encoder => { encoder.RequestKeyFrame(); return true; }); }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _requests.CompleteAdding();
            _thread.Join();
            _requests.Dispose();
            var failure = _stopped.Task.GetAwaiter().GetResult();
            if (failure is not null)
                throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "Media Foundation encoder cleanup failed.", failure);
        }
    }

    private T Invoke<T>(Func<NativeEncoder, T> action)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_requests.TryAdd(new(encoder => completion.TrySetResult(action(encoder)), error => completion.TrySetException(error))))
            throw new InvalidOperationException("The desktop encoder already has a pending operation.");
        return completion.Task.GetAwaiter().GetResult();
    }

    private void Run()
    {
        NativeEncoder? encoder = null;
        var apartmentReady = false;
        var foundationReady = false;
        Exception? cleanupFailure = null;
        try
        {
            WindowsMediaFoundationInterop.InitializeApartment();
            apartmentReady = true;
            MediaFactory.MFStartup().CheckError();
            foundationReady = true;
            encoder = new NativeEncoder(_options);
            _ready.TrySetResult(null);
            Exception? operationFailure = null;
            foreach (var request in _requests.GetConsumingEnumerable())
            {
                if (operationFailure is not null) { request.Fail(operationFailure); continue; }
                try { request.Execute(encoder); }
                catch (Exception error)
                {
                    operationFailure = error is WindowsDesktopException ? error : new WindowsDesktopException(
                        WindowsDesktopFailure.EncodingFailed, "The Media Foundation desktop encoding operation failed.", error);
                    request.Fail(operationFailure);
                }
            }
        }
        catch (Exception failure) { _ready.TrySetResult(failure); cleanupFailure = failure; }
        finally
        {
            try { encoder?.Dispose(); }
            catch (Exception failure) { cleanupFailure = Combine(cleanupFailure, failure); }
            if (foundationReady)
            {
                var result = MediaFactory.MFShutdown();
                if (result.Failure) cleanupFailure = Combine(cleanupFailure, new SharpGenException(result));
            }
            if (apartmentReady) WindowsMediaFoundationInterop.UninitializeApartment();
            _stopped.TrySetResult(cleanupFailure);
        }
    }

    private static Exception Combine(Exception? first, Exception second) => first is null ? second : new AggregateException(first, second);
    private sealed record EncoderRequest(Action<NativeEncoder> Execute, Action<Exception> Fail);

    private sealed class NativeEncoder : IDisposable
    {
        private const int NeedMoreInput = unchecked((int)0xc00d6d72);
        private const int AttributeNotFound = unchecked((int)0xc00d36e6);
        private const int MaximumPendingFrames = 8;
        private readonly WindowsDesktopEncodingOptions _options;
        private readonly IMFTransform _encoder;
        private readonly Dictionary<long, FrameTimestamp> _timestamps = new();
        private IMFTransform? _processor;
        private int _sourceWidth, _sourceHeight;
        private long? _firstTimestamp;
        private long _lastSampleTime = -1;
        private bool _forceNext = true;
        private bool _encoderAcceptedInput;
        private bool _processorAcceptedInput;
        private byte[] _sequenceHeader = [];

        internal NativeEncoder(WindowsDesktopEncodingOptions options)
        {
            _options = options;
            _encoder = WindowsMediaFoundationInterop.CreateTransform(WindowsMediaFoundationInterop.H264EncoderClass);
            try
            {
                WindowsMediaFoundationInterop.SetCodecValue(_encoder, WindowsMediaFoundationInterop.LowLatency, true);
                WindowsMediaFoundationInterop.SetCodecValue(_encoder, WindowsMediaFoundationInterop.BPictureCount, 0u);
                WindowsMediaFoundationInterop.SetCodecValue(_encoder, WindowsMediaFoundationInterop.RateControlMode, 0u); // CBR
                WindowsMediaFoundationInterop.SetCodecValue(_encoder, WindowsMediaFoundationInterop.GopSize, (uint)Math.Max(1, options.FramesPerSecond * 2));
                using var output = VideoType(VideoFormatGuids.H264, options.Width, options.Height);
                output.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)options.BitrateBitsPerSecond).CheckError();
                output.Set(MediaTypeAttributeKeys.Mpeg2Profile, 66u).CheckError(); // Baseline, no reordered pictures
                _encoder.SetOutputType(0, output, 0);
                using var input = VideoType(VideoFormatGuids.NV12, options.Width, options.Height);
                _encoder.SetInputType(0, input, 0);
                StartStreaming(_encoder);
                ReadSequenceHeader();
            }
            catch { _encoder.Dispose(); throw; }
        }

        internal IReadOnlyList<WindowsDesktopEncodedFrame> Encode(WindowsDesktopFrame frame, bool forceKeyFrame)
        {
            var pixels = frame.BgraPixels;
            if (!double.IsFinite(frame.TimestampUnixSeconds) || frame.TimestampUnixSeconds <= 0)
                throw new ArgumentException("Desktop frames require a finite UTC Unix timestamp.", nameof(frame));
            var processor = EnsureProcessor(frame.Width, frame.Height);
            if (_timestamps.Count >= MaximumPendingFrames)
                throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "The H.264 encoder exceeded its pending-frame budget.");
            _firstTimestamp ??= frame.TimestampTicks;
            var sampleTime = checked((long)((frame.TimestampTicks - _firstTimestamp.Value) * (double)TimeSpan.TicksPerSecond / Stopwatch.Frequency));
            if (sampleTime <= _lastSampleTime)
                throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "Desktop frame timestamps must advance monotonically.");
            var requireKeyFrame = forceKeyFrame || _forceNext;
            using var input = CreateInputSample(pixels, sampleTime);
            processor.ProcessInput(0, input, 0);
            _processorAcceptedInput = true;
            using var converted = ReadOutput(processor, "desktop color conversion") ??
                throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "The video processor buffered a frame despite disabled frame-rate conversion.");
            converted.SampleTime = sampleTime;
            converted.SampleDuration = TimeSpan.TicksPerSecond / _options.FramesPerSecond;
            if (requireKeyFrame)
                WindowsMediaFoundationInterop.SetCodecValue(_encoder, WindowsMediaFoundationInterop.ForceKeyFrame, 1u);
            _timestamps.Add(sampleTime, new(frame.TimestampUnixSeconds, requireKeyFrame));
            _encoder.ProcessInput(0, converted, 0);
            _encoderAcceptedInput = true;
            _lastSampleTime = sampleTime;
            _forceNext = false;
            var frames = new List<WindowsDesktopEncodedFrame>();
            while (true)
            {
                using var output = ReadOutput(_encoder, "H.264 encoding");
                if (output is null) break;
                if (frames.Count >= MaximumPendingFrames)
                    throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "The H.264 encoder produced too many frames for one input operation.");
                if (!_timestamps.Remove(output.SampleTime, out var timestamp))
                    throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "The H.264 encoder returned a frame without its original capture timestamp.");
                ReadSequenceHeader();
                var bytes = ReadSampleBytes(output);
                var accessUnit = WindowsH264AccessUnit.Prepare(bytes, _sequenceHeader, out var isKeyFrame);
                if (timestamp.RequiresKeyFrame && !isKeyFrame)
                    throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "The H.264 encoder did not honor the required decoder-refresh frame.");
                frames.Add(new(accessUnit, isKeyFrame, _options.Width, _options.Height, timestamp.UnixSeconds));
            }
            return frames;
        }

        internal void RequestKeyFrame() => _forceNext = true;
        internal void UpdateBitrate(int bitrate) =>
            WindowsMediaFoundationInterop.SetCodecValue(_encoder, WindowsMediaFoundationInterop.MeanBitrate, (uint)bitrate);

        private IMFTransform EnsureProcessor(int width, int height)
        {
            if (_processor is not null)
            {
                if (_sourceWidth != width || _sourceHeight != height)
                    throw new WindowsDesktopException(WindowsDesktopFailure.DisplayConfigurationChanged,
                        "Capture dimensions changed; recreate the encoder so its decoder configuration stays consistent.");
                return _processor;
            }
            var processor = WindowsMediaFoundationInterop.CreateTransform(WindowsMediaFoundationInterop.VideoProcessorClass);
            try
            {
                using var attributes = processor.Attributes;
                attributes.Set(WindowsMediaFoundationInterop.DisableFrameRateConversion, 1u).CheckError();
                attributes.Set(WindowsMediaFoundationInterop.CallerAllocatesOutput, 1u).CheckError();
                attributes.Set(WindowsMediaFoundationInterop.LowLatency, 1u).CheckError();
                // The desktop is opaque; RGB32 ignores the captured alpha byte.
                using var input = VideoType(VideoFormatGuids.Rgb32, width, height);
                input.Set(MediaTypeAttributeKeys.DefaultStride, checked((uint)(width * 4))).CheckError();
                processor.SetInputType(0, input, 0);
                using var output = VideoType(VideoFormatGuids.NV12, _options.Width, _options.Height);
                processor.SetOutputType(0, output, 0);
                StartStreaming(processor);
                _processor = processor; _sourceWidth = width; _sourceHeight = height;
                return processor;
            }
            catch { processor.Dispose(); throw; }
        }

        private IMFMediaType VideoType(Guid subtype, int width, int height)
        {
            var type = MediaFactory.MFCreateMediaType();
            try
            {
                type.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video).CheckError();
                type.Set(MediaTypeAttributeKeys.Subtype, subtype).CheckError();
                type.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive).CheckError();
                MediaFactory.MFSetAttributeSize(type, MediaTypeAttributeKeys.FrameSize, (uint)width, (uint)height).CheckError();
                MediaFactory.MFSetAttributeRatio(type, MediaTypeAttributeKeys.FrameRate, (uint)_options.FramesPerSecond, 1).CheckError();
                MediaFactory.MFSetAttributeRatio(type, MediaTypeAttributeKeys.PixelAspectRatio, 1, 1).CheckError();
                return type;
            }
            catch { type.Dispose(); throw; }
        }

        private IMFSample CreateInputSample(ReadOnlyMemory<byte> pixels, long sampleTime)
        {
            var sample = MediaFactory.MFCreateSample();
            try
            {
                using var buffer = MediaFactory.MFCreateMemoryBuffer(pixels.Length);
                buffer.Lock(out var address, out var maximum, out _);
                try
                {
                    if (maximum < pixels.Length) throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "MF supplied an undersized input buffer.");
                    if (!MemoryMarshal.TryGetArray(pixels, out ArraySegment<byte> array) || array.Array is null)
                        throw new ArgumentException("Desktop frames must expose their owned BGRA array.", nameof(pixels));
                    Marshal.Copy(array.Array, array.Offset, address, pixels.Length);
                }
                finally { buffer.Unlock(); }
                buffer.CurrentLength = pixels.Length;
                sample.AddBuffer(buffer);
                sample.SampleTime = sampleTime;
                sample.SampleDuration = TimeSpan.TicksPerSecond / _options.FramesPerSecond;
                return sample;
            }
            catch { sample.Dispose(); throw; }
        }

        private static IMFSample? ReadOutput(IMFTransform transform, string operation)
        {
            var info = transform.GetOutputStreamInfo(0);
            IMFSample? provided = null;
            var output = new OutputDataBuffer { StreamID = 0 };
            var sampleTransferred = false;
            var retainedOutputReference = false;
            try
            {
                if ((info.Flags & (int)OutputStreamInfoFlags.OutputStreamProvidesSamples) == 0)
                {
                    if (info.Size is < 1 or > 128 * 1024 * 1024 || info.Alignment < 0 || info.Alignment > 4096 ||
                        (info.Alignment != 0 && (info.Alignment & (info.Alignment - 1)) != 0))
                        throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "MF returned invalid output buffer requirements.");
                    provided = MediaFactory.MFCreateSample();
                    using var buffer = info.Alignment == 0 ? MediaFactory.MFCreateMemoryBuffer(info.Size) :
                        MediaFactory.MFCreateAlignedMemoryBuffer(info.Size, info.Alignment - 1);
                    provided.AddBuffer(buffer);
                    // Vortice's ProcessOutput unmarshals a new wrapper for the same
                    // caller-owned pointer. Each managed wrapper needs one COM reference.
                    provided.AddRef();
                    retainedOutputReference = true;
                    output.Sample = provided;
                }
                var result = transform.ProcessOutput(ProcessOutputFlags.None, 1, ref output, out _);
                if (result.Code == NeedMoreInput) return null;
                if (result.Failure)
                    throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, $"Media Foundation failed during {operation}.", new SharpGenException(result));
                if (output.Sample is null)
                    throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, $"Media Foundation completed {operation} without a sample.");
                sampleTransferred = true;
                return output.Sample;
            }
            finally
            {
                var returnedProvidedWrapper = provided is not null && output.Sample is not null &&
                    !ReferenceEquals(provided, output.Sample) && output.Sample.NativePointer == provided.NativePointer;
                if (retainedOutputReference && !returnedProvidedWrapper)
                    provided?.Release();
                output.Events?.Dispose();
                if (!sampleTransferred) output.Sample?.Dispose();
                provided?.Dispose();
            }
        }

        private void ReadSequenceHeader()
        {
            using var type = _encoder.GetOutputCurrentType(0);
            var result = type.GetBlobSize(MediaTypeAttributeKeys.MpegSequenceHeader, out var length);
            if (result.Code == AttributeNotFound) return; // Some MFTs publish this only with the first output.
            result.CheckError();
            if (length is < 1 or > 64 * 1024)
                throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "The H.264 decoder configuration exceeded its size budget.");
            _sequenceHeader = type.GetBlob(MediaTypeAttributeKeys.MpegSequenceHeader);
        }

        private static byte[] ReadSampleBytes(IMFSample sample)
        {
            using var buffer = sample.ConvertToContiguousBuffer();
            buffer.Lock(out var address, out var maximum, out var length);
            try
            {
                if (length is < 1 or > 32 * 1024 * 1024 || length > maximum)
                    throw new WindowsDesktopException(WindowsDesktopFailure.EncodingFailed, "MF returned an invalid H.264 output sample length.");
                var bytes = new byte[length];
                Marshal.Copy(address, bytes, 0, length);
                return bytes;
            }
            finally { buffer.Unlock(); }
        }

        private static void StartStreaming(IMFTransform transform)
        {
            transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
            transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);
        }

        public void Dispose()
        {
            var failures = new List<Exception>();
            foreach (var owner in new[] { (Transform: _processor, HasInput: _processorAcceptedInput), (Transform: _encoder, HasInput: _encoderAcceptedInput) })
            {
                var transform = owner.Transform;
                if (transform is null) continue;
                // The system H.264 MFT rejects FLUSH before its first ProcessInput.
                // No media buffers belong to the transform in that state.
                try { if (owner.HasInput) transform.ProcessMessage(TMessageType.MessageCommandFlush, UIntPtr.Zero); }
                catch (Exception failure) { failures.Add(failure); }
                finally { transform.Dispose(); }
            }
            _processor = null;
            _timestamps.Clear();
            if (failures.Count > 0) throw new AggregateException("Desktop media transforms reported errors while stopping.", failures);
        }
        private sealed record FrameTimestamp(double UnixSeconds, bool RequiresKeyFrame);
    }
}
