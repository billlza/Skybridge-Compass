using System.Threading.Channels;

namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>Bounded live H.264 input. A slow decoder cannot block authenticated control traffic.</summary>
internal sealed class RemoteControlVideoFrameBuffer
{
    internal const int Capacity = 3;
    internal static readonly TimeSpan RefreshDeadline = TimeSpan.FromSeconds(5);
    private readonly Channel<RemoteH264ScreenFrame> _frames = Channel.CreateBounded<RemoteH264ScreenFrame>(
        new BoundedChannelOptions(Capacity) { SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly TimeProvider _time;
    private readonly object _gate = new();
    private long? _waitingSince;
    private bool _completed;
    private ulong _dropped;

    internal RemoteControlVideoFrameBuffer(TimeProvider? time = null) => _time = time ?? TimeProvider.System;
    internal int Count => _frames.Reader.Count;
    internal ulong DroppedFrames { get { lock (_gate) return _dropped; } }

    internal void Enqueue(RemoteH264ScreenFrame frame)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_completed, this);
            RequireRefreshDeadline();
            if (_waitingSince is not null)
            {
                if (!frame.IsKeyFrame) { _dropped++; return; }
                _waitingSince = null;
            }
            if (_frames.Writer.TryWrite(frame)) return;

            // Retire the queued GOP as a unit. Any sample already handed to the
            // decoder remains ordered before the next IDR's discontinuity marker.
            while (_frames.Reader.TryRead(out _)) _dropped++;
            if (frame.IsKeyFrame)
            {
                if (!_frames.Writer.TryWrite(frame)) throw new InvalidOperationException("The emptied video buffer rejected its refresh frame.");
            }
            else { _dropped++; _waitingSince = _time.GetTimestamp(); }
        }
    }

    internal ValueTask<RemoteH264ScreenFrame> ReadAsync(CancellationToken token) => _frames.Reader.ReadAsync(token);

    internal void RequireRefreshDeadline()
    {
        lock (_gate)
        {
            if (_waitingSince is { } started && _time.GetElapsedTime(started) >= RefreshDeadline)
                throw new TimeoutException("The host did not provide an H.264 refresh frame within 5 seconds of decoder backpressure.");
        }
    }

    internal void Complete(Exception? failure = null)
    {
        lock (_gate)
        {
            if (_completed) return;
            _completed = true;
            _frames.Writer.TryComplete(failure);
            while (_frames.Reader.TryRead(out _)) { }
        }
    }
}
