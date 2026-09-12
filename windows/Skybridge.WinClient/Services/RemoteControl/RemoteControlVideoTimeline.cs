namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>Presentation clock for the negotiated video-only live stream.</summary>
internal sealed class RemoteControlVideoTimeline
{
    internal static readonly TimeSpan FrameDuration = TimeSpan.FromTicks(TimeSpan.TicksPerSecond / 30);
    private long _lastTicks = -FrameDuration.Ticks;

    internal TimeSpan Next(TimeSpan playbackPosition)
    {
        if (playbackPosition < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(playbackPosition));
        // Capture timestamps order incoming frames, but gaps in discarded GOPs
        // are not video that the local player should wait to play. Keep samples
        // ordered on its own clock, including after a buffering pause.
        _lastTicks = Math.Max(checked(_lastTicks + FrameDuration.Ticks), playbackPosition.Ticks);
        return TimeSpan.FromTicks(_lastTicks);
    }
}
