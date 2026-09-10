namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>Owns the native resources of one accepted stream configuration; queues never outlive that configuration.</summary>
internal sealed class WindowsRemoteControlStream : IRemoteControlHostStream
{
    private readonly RemoteStreamConfiguration _configuration;
    private readonly Func<WindowsDesktopEncodedFrame, CancellationToken, Task> _sendVideo;
    private readonly Func<WindowsOpusAudioFrame, CancellationToken, ValueTask> _sendAudio;
    private readonly TaskCompletionSource _prepared = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private CancellationTokenSource? _lifetime;
    private WindowsLoopbackAudioSource? _audio;
    private IWindowsRemoteInput? _input;
    private Task _videoTask = Task.CompletedTask;
    private bool _disposed;
    private bool _completionObserved;
    private int _keyFrameRequested;

    internal WindowsRemoteControlStream(RemoteStreamConfiguration configuration,
        Func<WindowsDesktopEncodedFrame, CancellationToken, Task> sendVideo,
        Func<WindowsOpusAudioFrame, CancellationToken, ValueTask> sendAudio)
    {
        _configuration = configuration;
        _sendVideo = sendVideo;
        _sendAudio = sendAudio;
    }

    public Task Completion { get; private set; } = Task.CompletedTask;
    public int Width { get; private set; }
    public int Height { get; private set; }
    public IWindowsRemoteInput Input => _input ?? throw new InvalidOperationException("Desktop input is not prepared.");

    public async Task PrepareAsync(CancellationToken cancellationToken)
    {
        if (_lifetime is not null) throw new InvalidOperationException("A desktop stream can only be prepared once.");
        _lifetime = new CancellationTokenSource();
        // The caller's deadline governs preparation. Once accepted, this stream
        // owns its lifetime and is retired explicitly before its replacement.
        using var preparationCancellation = cancellationToken.Register(_lifetime.Cancel);
        _videoTask = Task.Run(() => RunVideoAsync(_lifetime.Token), CancellationToken.None);
        Completion = _videoTask;
        await _prepared.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        if (_configuration.AudioRedirectionEnabled == true)
        {
            _audio = new WindowsLoopbackAudioSource();
            await _audio.StartAsync(async (frame, token) =>
            {
                await _started.Task.WaitAsync(token).ConfigureAwait(false);
                await _sendAudio(frame, token).ConfigureAwait(false);
            }, _configuration.AudioMode!, _lifetime.Token).ConfigureAwait(false);
        }
        Completion = ObserveWorkersAsync(_lifetime, _videoTask, _audio?.Completion);
    }

    public void Start()
    {
        if (!_prepared.Task.IsCompletedSuccessfully) throw new InvalidOperationException("Desktop resources are not ready.");
        if (!_started.TrySetResult()) throw new InvalidOperationException("The desktop stream is already started.");
    }

    public void RequestKeyFrame() => Interlocked.Exchange(ref _keyFrameRequested, 1);

    private async Task RunVideoAsync(CancellationToken cancellationToken)
    {
        try
        {
            if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
                throw new PlatformNotSupportedException("Desktop streaming requires Windows 10 version 2004 or later.");
            // Idle display power-off stops DXGI updates while the authenticated
            // connection remains alive. Only an accepted stream owns this request.
            using var awake = WindowsPowerKeepAwake.Arm(keepDisplayAwake: true);
            var displays = WindowsDesktopCapture.EnumerateDisplays();
            var display = displays.SingleOrDefault(display => display.IsPrimary)
                ?? throw new WindowsDesktopException(WindowsDesktopFailure.DisplayUnavailable, "No primary desktop display is available.");
            var (width, height) = FitOutput(display.Width, display.Height, _configuration.Width, _configuration.Height);
            // Scale on the capture device before CPU readback when the viewer
            // explicitly enables acceleration. Input retains physical display coordinates.
            using var capture = _configuration.EnableHardwareAcceleration
                ? new WindowsDesktopCapture(display.Id, width, height)
                : new WindowsDesktopCapture(display.Id);
            Width = width;
            Height = height;
            var bitrate = CalculateBitrate(width, height, _configuration.TargetFrameRate, _configuration.VideoCompressionLevel);
            using var encoder = new WindowsDesktopEncoder(new WindowsDesktopEncodingOptions(
                width, height, _configuration.TargetFrameRate, bitrate));
            _input = new WindowsRemoteInput(display);
            var firstFrames = await PrepareFirstFrameAsync(capture, encoder, cancellationToken).ConfigureAwait(false);
            _prepared.TrySetResult();
            await _started.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            foreach (var frame in firstFrames) await _sendVideo(frame, cancellationToken).ConfigureAwait(false);
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1d / _configuration.TargetFrameRate));
            ulong encodedFrames = (ulong)firstFrames.Count;
            while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
            {
                var refresh = Interlocked.Exchange(ref _keyFrameRequested, 0) != 0;
                using var frame = await capture.CaptureAsync(TimeSpan.FromMilliseconds(100), cancellationToken,
                    includeUnchangedFrame: refresh).ConfigureAwait(false);
                if (frame is null) continue;
                var forceKeyFrame = refresh || encodedFrames % (ulong)_configuration.KeyFrameInterval == 0;
                foreach (var encoded in encoder.Encode(frame, forceKeyFrame))
                {
                    await _sendVideo(encoded, cancellationToken).ConfigureAwait(false);
                    encodedFrames++;
                }
            }
        }
        catch (Exception failure)
        {
            _prepared.TrySetException(failure);
            throw;
        }
    }

    private static async Task<IReadOnlyList<WindowsDesktopEncodedFrame>> PrepareFirstFrameAsync(
        IWindowsDesktopCapture capture, IWindowsDesktopEncoder encoder, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            while (true)
            {
                using var frame = await capture.CaptureAsync(TimeSpan.FromMilliseconds(100), deadline.Token).ConfigureAwait(false);
                if (frame is null) continue;
                var encoded = encoder.Encode(frame, forceKeyFrame: true);
                var firstKeyFrame = encoded.ToList().FindIndex(item => item.IsKeyFrame);
                if (firstKeyFrame >= 0) return encoded.Skip(firstKeyFrame).ToArray();
            }
        }
        catch (OperationCanceledException failure) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("Desktop capture and encoding did not produce an initial keyframe within five seconds.", failure);
        }
    }

    internal static (int Width, int Height) FitOutput(int sourceWidth, int sourceHeight, int? requestedWidth, int? requestedHeight)
    {
        if (sourceWidth < 2 || sourceHeight < 2) throw new InvalidDataException("The source display is too small to encode.");
        // Auto is a bounded software-encoding budget. Explicit dimensions remain
        // an intentional user request; they are never retried at a different size.
        var maxWidth = requestedWidth ?? 1920;
        var maxHeight = requestedHeight ?? 1080;
        var scale = Math.Min(1d, Math.Min((double)maxWidth / sourceWidth, (double)maxHeight / sourceHeight));
        var width = (int)(sourceWidth * scale) & ~1;
        var height = (int)(sourceHeight * scale) & ~1;
        if (width < 2 || height < 2) throw new InvalidDataException("The requested bounds cannot preserve this display's aspect ratio.");
        return (width, height);
    }

    internal static int CalculateBitrate(int width, int height, int fps, int? compressionLevel)
    {
        if (compressionLevel is < 0 or > 100) throw new InvalidDataException("Video compression level must be between 0 and 100.");
        var quality = 1.5 - (compressionLevel ?? 50) / 100d;
        return (int)Math.Clamp(width * (double)height * fps * 0.12 * quality, 256_000, 50_000_000);
    }

    private static async Task ObserveWorkersAsync(CancellationTokenSource lifetime, Task video, Task? audio)
    {
        var tasks = audio is null ? new[] { video } : new[] { video, audio };
        await Task.WhenAny(tasks).ConfigureAwait(false);
        await lifetime.CancelAsync().ConfigureAwait(false);
        await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        var failures = new List<Exception>();
        if (_lifetime is { } lifetime)
        {
            await lifetime.CancelAsync().ConfigureAwait(false);
            try { await Completion.ConfigureAwait(false); }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
            catch (Exception failure)
            {
                if (!_completionObserved) failures.Add(failure);
                _completionObserved = true;
            }
        }
        try { _input?.Dispose(); }
        catch (Exception failure) { failures.Add(failure); }
        try { if (_audio is not null) await _audio.DisposeAsync().ConfigureAwait(false); }
        catch (Exception failure) { failures.Add(failure); }
        finally { if (_audio?.Completion.IsCompleted == true) _audio = null; }
        if (failures.Count > 0) throw new AggregateException("Desktop stream cleanup reported a failure. Restore the interactive desktop and stop sharing again.", failures);
        _lifetime?.Dispose();
        _disposed = true;
    }
}
