using System;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace Skybridge.WinClient.Services.RemoteControl;

public sealed record WindowsOpusAudioFrame(
    byte[] Payload,
    ulong TimestampSamples,
    int SamplesPerChannel,
    bool Discontinuity);

/// <summary>
/// Owns one system-audio capture epoch. The session owns media encryption and
/// counters; stopping and recreating this source must not reset those counters.
/// </summary>
public sealed class WindowsLoopbackAudioSource : IAsyncDisposable
{
    private readonly object _gate = new();
    private readonly IWindowsLoopbackCapture _capture;
    private RunState? _run;
    private bool _disposed;
    private bool _started;

    public WindowsLoopbackAudioSource()
        : this(new WindowsWasapiLoopbackCapture())
    {
    }

    internal WindowsLoopbackAudioSource(IWindowsLoopbackCapture capture)
    {
        _capture = capture ?? throw new ArgumentNullException(nameof(capture));
    }

    /// <summary>Completes only after capture, encoding and delivery have stopped.</summary>
    public Task Completion
    {
        get
        {
            lock (_gate)
            {
                return _run?.Completion ?? Task.CompletedTask;
            }
        }
    }

    public long CapturedFrames => Interlocked.Read(ref _capturedFrames);
    public long EncodedFrames => Interlocked.Read(ref _encodedFrames);
    public long Discontinuities => Interlocked.Read(ref _discontinuities);
    private long _capturedFrames;
    private long _encodedFrames;
    private long _discontinuities;

    /// <summary>
    /// Returns after WASAPI has started successfully. The caller must observe
    /// Completion and propagate later failures to its session. The delivery
    /// callback must honor cancellation and must not retain mutable source state.
    /// </summary>
    public async Task StartAsync(
        Func<WindowsOpusAudioFrame, CancellationToken, ValueTask> onFrame,
        string mode = "low-latency",
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(onFrame);
        WindowsOpusAudioEncoder.ValidateMode(mode);
        cancellationToken.ThrowIfCancellationRequested();

        RunState run;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_started)
            {
                throw new InvalidOperationException("A loopback audio source owns one capture epoch and cannot be restarted.");
            }

            _started = true;
            run = new RunState(cancellationToken);
            _run = run;
            var captureTask = Task.Factory.StartNew(
                () => Capture(run),
                CancellationToken.None,
                TaskCreationOptions.LongRunning,
                TaskScheduler.Default);
            var deliveryTask = Task.Run(() => DeliverAsync(run, mode, onFrame));
            run.Completion = ObserveCompletionAsync(run, captureTask, deliveryTask);
        }

        try
        {
            await run.Ready.Task.ConfigureAwait(false);
        }
        catch when (!cancellationToken.IsCancellationRequested)
        {
            await run.Completion.ConfigureAwait(false);
            throw;
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        RunState? run;
        lock (_gate)
        {
            run = _run;
            if (run is not null && !run.CancellationDisposed)
            {
                run.Cancellation.Cancel();
            }
        }

        if (run is not null)
        {
            // Cancelling a caller's wait does not abandon the source's shutdown;
            // Completion remains the owner of both workers until they terminate.
            await run.Completion.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        lock (_gate)
        {
            _disposed = true;
        }

        try
        {
            await StopAsync().ConfigureAwait(false);
        }
        finally
        {
            lock (_gate)
            {
                if (_run is not null && _run.Completion.IsCompleted && !_run.CancellationDisposed)
                {
                    _run.Cancellation.Dispose();
                    _run.CancellationDisposed = true;
                }
            }
        }
    }

    private void Capture(RunState run)
    {
        try
        {
            _capture.Run(
                frame =>
                {
                    run.Cancellation.Token.ThrowIfCancellationRequested();
                    if (!run.Frames.Writer.TryWrite(frame))
                    {
                        throw new InvalidOperationException("Remote audio delivery exceeded the eight-frame capture queue.");
                    }

                    Interlocked.Increment(ref _capturedFrames);
                    if (frame.Discontinuity)
                    {
                        Interlocked.Increment(ref _discontinuities);
                    }
                },
                () => run.Ready.TrySetResult(),
                run.Cancellation.Token);
            run.Ready.TrySetCanceled(run.Cancellation.Token);
            run.Frames.Writer.TryComplete();
        }
        catch (OperationCanceledException) when (run.Cancellation.IsCancellationRequested)
        {
            run.Ready.TrySetCanceled(run.Cancellation.Token);
            run.Frames.Writer.TryComplete();
        }
        catch (Exception error)
        {
            run.Ready.TrySetException(error);
            run.Frames.Writer.TryComplete(error);
            throw;
        }
    }

    private async Task DeliverAsync(
        RunState run,
        string mode,
        Func<WindowsOpusAudioFrame, CancellationToken, ValueTask> onFrame)
    {
        using var encoder = new WindowsOpusAudioEncoder(mode);
        try
        {
            await foreach (var pcm in run.Frames.Reader.ReadAllAsync(run.Cancellation.Token).ConfigureAwait(false))
            {
                var encoded = encoder.Encode(pcm);
                Interlocked.Increment(ref _encodedFrames);
                await onFrame(encoded, run.Cancellation.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (run.Cancellation.IsCancellationRequested)
        {
            // The source's explicit stop cancels both workers.
        }
    }

    private static async Task ObserveCompletionAsync(RunState run, Task captureTask, Task deliveryTask)
    {
        var first = await Task.WhenAny(captureTask, deliveryTask).ConfigureAwait(false);
        if (first.IsFaulted || first.IsCanceled)
        {
            run.Cancellation.Cancel();
        }

        try
        {
            await Task.WhenAll(captureTask, deliveryTask).ConfigureAwait(false);
        }
        finally
        {
            // If encoding failed before WASAPI became ready, StartAsync must
            // observe that failure instead of waiting for a capture callback.
            if (deliveryTask.IsFaulted)
            {
                run.Ready.TrySetException(deliveryTask.Exception!.InnerExceptions);
            }
        }
    }

    private sealed class RunState
    {
        public RunState(CancellationToken cancellationToken)
        {
            Cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            Frames = Channel.CreateBounded<WindowsPcmAudioFrame>(new BoundedChannelOptions(8)
            {
                SingleReader = true,
                SingleWriter = true,
                FullMode = BoundedChannelFullMode.Wait,
                AllowSynchronousContinuations = false
            });
        }

        public CancellationTokenSource Cancellation { get; }
        public bool CancellationDisposed { get; set; }
        public Channel<WindowsPcmAudioFrame> Frames { get; }
        public TaskCompletionSource Ready { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task Completion { get; set; } = Task.CompletedTask;
    }
}
