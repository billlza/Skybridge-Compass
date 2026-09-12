using System.Threading.Channels;
using System.Diagnostics;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Playback;
using Windows.Storage.Streams;

namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>System H.264 decoding and presentation with a bounded encoded-frame queue.</summary>
internal sealed class WindowsRemoteVideoPlayer : IAsyncDisposable
{
    private readonly RemoteControlVideoFrameBuffer _frames = new();
    private readonly RemoteControlVideoTimeline _timeline = new();
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TaskCompletionSource<MediaPlayer> _available = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource<Exception> _failure = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _requestsDrained = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object _gate = new();
    private readonly SemaphoreSlim _sampleOrder = new(1, 1);
    private MediaPlayer? _player;
    private MediaStreamSource? _source;
    private MediaSource? _mediaSource;
    private TaskCompletionSource? _disposal;
    private Exception? _shutdownFailure;
    private ulong _firstTimestamp;
    private ulong _lastSampleSequence;
    private long _sampleCount;
    private long _lastSampleTelemetry = Stopwatch.GetTimestamp();
    private int _width, _height, _activeRequests;
    private bool _stopping;

    internal Task<MediaPlayer> Available => _available.Task;
    internal Task<Exception> Failure => _failure.Task;
    internal (int Width, int Height) Dimensions { get { lock (_gate) return (_width, _height); } }

    internal Task ReceiveAsync(RemoteH264ScreenFrame frame, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_stopping, this);
            if (_source is null) Initialize(frame);
            if (frame.Width != _width || frame.Height != _height)
                throw new InvalidDataException("The host changed video dimensions without a new stream negotiation.");
            _frames.Enqueue(frame);
        }
        return Task.CompletedTask;
    }

    private void Initialize(RemoteH264ScreenFrame frame)
    {
        var properties = VideoEncodingProperties.CreateH264();
        properties.Width = checked((uint)frame.Width);
        properties.Height = checked((uint)frame.Height);
        properties.FrameRate.Numerator = 30;
        properties.FrameRate.Denominator = 1;
        _width = frame.Width;
        _height = frame.Height;
        _firstTimestamp = frame.TimestampMicroseconds;
        _source = new MediaStreamSource(new VideoStreamDescriptor(properties))
        {
            CanSeek = false, IsLive = true, BufferTime = TimeSpan.Zero
        };
        _source.Starting += OnStarting;
        _source.SampleRequested += OnSampleRequested;
        _mediaSource = MediaSource.CreateFromMediaStreamSource(_source);
        _player = new MediaPlayer { AutoPlay = false, RealTimePlayback = true, IsMuted = true };
        _player.MediaFailed += OnMediaFailed;
        _player.PlaybackSession.PlaybackStateChanged += OnPlaybackStateChanged;
        _player.Source = _mediaSource;
        _available.TrySetResult(_player);
    }

    private void OnStarting(MediaStreamSource sender, MediaStreamSourceStartingEventArgs args)
    {
        if (Volatile.Read(ref _stopping)) return;
        try { args.Request.SetActualStartPosition(TimeSpan.Zero); }
        catch (Exception failure) { ReportFailure(failure); }
    }

    private async void OnSampleRequested(MediaStreamSource sender, MediaStreamSourceSampleRequestedEventArgs args)
    {
        CancellationTokenSource progressLifetime;
        lock (_gate)
        {
            if (_stopping) return;
            Interlocked.Increment(ref _activeRequests);
            progressLifetime = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        }
        var request = args.Request;
        MediaStreamSourceSampleRequestDeferral? deferral = null;
        Task<RemoteH264ScreenFrame>? pending = null;
        var ownsSampleOrder = false;
        try
        {
            deferral = request.GetDeferral();
            await _sampleOrder.WaitAsync(_lifetime.Token).ConfigureAwait(false);
            ownsSampleOrder = true;
            pending = _frames.ReadAsync(_lifetime.Token).AsTask();
            while (!pending.IsCompleted)
            {
                var progressTick = Task.Delay(500, progressLifetime.Token);
                if (await Task.WhenAny(pending, progressTick).ConfigureAwait(false) == pending) break;
                await progressTick.ConfigureAwait(false);
                _frames.RequireRefreshDeadline();
                request.ReportSampleProgress(0);
            }
            var frame = await pending.ConfigureAwait(false);
            using var writer = new DataWriter();
            writer.WriteBytes(frame.Bytes);
            var ticks = checked((long)(frame.TimestampMicroseconds - _firstTimestamp) * 10);
            var player = _player ?? throw new InvalidOperationException("A video sample was requested before its player was initialized.");
            var presentationTime = _timeline.Next(player.PlaybackSession.Position);
            request.Sample = MediaStreamSample.CreateFromBuffer(writer.DetachBuffer(), presentationTime);
            request.Sample.Duration = RemoteControlVideoTimeline.FrameDuration;
            request.Sample.KeyFrame = frame.IsKeyFrame;
            // The host may retire an overloaded GOP and resume at a refresh frame.
            // Tell the system decoder about that gap instead of promising continuity.
            request.Sample.Discontinuous = _lastSampleSequence != 0 && frame.Sequence != _lastSampleSequence + 1;
            _lastSampleSequence = frame.Sequence;
            _sampleCount++;
            if (Stopwatch.GetElapsedTime(_lastSampleTelemetry) >= TimeSpan.FromSeconds(10))
            {
                WindowsRuntimeLog.Write(WindowsLogLevel.Info, "RemoteControlVideo",
                    $"Decoded-input progress; samples={_sampleCount}; sequence={frame.Sequence}; captureTimeMs={ticks / TimeSpan.TicksPerMillisecond}; presentationTimeMs={presentationTime.TotalMilliseconds:F0}; pending={_frames.Count}; dropped={_frames.DroppedFrames}; wire={_width}x{_height}; decoded={player.PlaybackSession.NaturalVideoWidth}x{player.PlaybackSession.NaturalVideoHeight}.");
                _lastSampleTelemetry = Stopwatch.GetTimestamp();
            }
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
            request.Sample = null; // The owning viewer has explicitly ended this source.
        }
        catch (ChannelClosedException) when (_stopping)
        {
            request.Sample = null;
        }
        catch (Exception failure)
        {
            ReportFailure(failure);
        }
        finally
        {
            progressLifetime.Cancel();
            if (pending is not null)
            {
                try { _ = await pending.ConfigureAwait(false); }
                catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
                catch (ChannelClosedException) when (_stopping || _lifetime.IsCancellationRequested) { }
                catch (Exception drainFailure) { ReportFailure(drainFailure); }
            }
            try { deferral?.Complete(); }
            catch (Exception completionFailure) { ReportFailure(completionFailure); }
            finally
            {
                if (ownsSampleOrder) _sampleOrder.Release();
                progressLifetime.Dispose();
                if (Interlocked.Decrement(ref _activeRequests) == 0 && Volatile.Read(ref _stopping)) _requestsDrained.TrySetResult();
            }
        }
    }

    private void OnMediaFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args)
    {
        if (Volatile.Read(ref _stopping)) return;
        ReportFailure(new InvalidOperationException($"Windows could not decode the remote video ({args.Error}): {args.ErrorMessage}", args.ExtendedErrorCode));
    }

    private void OnPlaybackStateChanged(MediaPlaybackSession sender, object args)
    {
        if (Volatile.Read(ref _stopping)) return;
        try
        {
            WindowsRuntimeLog.Write(WindowsLogLevel.Info, "RemoteControlVideo",
                $"Playback state={sender.PlaybackState}; positionMs={sender.Position.TotalMilliseconds:F0}.");
        }
        catch (Exception failure) { ReportFailure(failure); }
    }

    private void ReportFailure(Exception failure)
    {
        lock (_gate)
        {
            if (_stopping) { _shutdownFailure ??= failure; return; }
            if (_failure.TrySetResult(failure))
            {
                _frames.Complete(failure);
                _lifetime.Cancel();
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        TaskCompletionSource completion;
        bool ownsDisposal;
        lock (_gate)
        {
            ownsDisposal = _disposal is null;
            completion = _disposal ??= new(TaskCreationOptions.RunContinuationsAsynchronously);
            if (ownsDisposal)
            {
                Volatile.Write(ref _stopping, true);
            }
        }
        if (ownsDisposal)
        {
            try { await DisposeCoreAsync().ConfigureAwait(false); completion.TrySetResult(); }
            catch (Exception failure) { completion.TrySetException(failure); }
        }
        await completion.Task.ConfigureAwait(false);
    }

    private async Task DisposeCoreAsync()
    {
        if (_source is { } source)
        {
            source.Starting -= OnStarting;
            source.SampleRequested -= OnSampleRequested;
        }
        if (_player is { } player)
        {
            player.MediaFailed -= OnMediaFailed;
            player.PlaybackSession.PlaybackStateChanged -= OnPlaybackStateChanged;
        }
        _frames.Complete();
        await _lifetime.CancelAsync().ConfigureAwait(false);
        _available.TrySetCanceled(_lifetime.Token);
        if (Volatile.Read(ref _activeRequests) == 0) _requestsDrained.TrySetResult();
        await _requestsDrained.Task.ConfigureAwait(false);
        var failures = new List<Exception>();
        lock (_gate) { if (_shutdownFailure is { } failure) failures.Add(failure); }
        try { _player?.Dispose(); } catch (Exception failure) { failures.Add(failure); }
        try { _mediaSource?.Dispose(); } catch (Exception failure) { failures.Add(failure); }
        _sampleOrder.Dispose();
        _lifetime.Dispose();
        if (failures.Count > 0) throw new AggregateException("Windows video cleanup failed.", failures);
    }
}
