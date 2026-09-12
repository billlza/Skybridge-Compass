using System.Buffers;
using System.Threading;

namespace Skybridge.WinClient.Services.RemoteControl;

internal enum WindowsDesktopFailure
{
    InteractiveDesktopUnavailable,
    DisplayUnavailable,
    DisplayConfigurationChanged,
    CaptureAccessLost,
    CaptureFailed,
    CaptureScalingUnavailable,
    EncoderUnavailable,
    EncodingFailed,
    InputRejected
}

internal sealed class WindowsDesktopException : InvalidOperationException
{
    public WindowsDesktopException(WindowsDesktopFailure failure, string message, Exception? innerException = null)
        : base(message, innerException) => Failure = failure;

    public WindowsDesktopFailure Failure { get; }
}

internal sealed record WindowsDesktopDisplay(
    string Id, string Name, int Left, int Top, int Width, int Height, bool IsPrimary);

/// <summary>One owned, top-down BGRA image; dimensions may be scaled from the physical display.</summary>
internal sealed class WindowsDesktopFrame : IDisposable
{
    private byte[]? _pixels;

    internal WindowsDesktopFrame(
        byte[] rentedPixels, int width, int height, long timestampTicks,
        double timestampUnixSeconds, bool protectedContentMasked)
    {
        ArgumentNullException.ThrowIfNull(rentedPixels);
        if (width < 1 || height < 1 || rentedPixels.Length < checked(width * height * 4))
            throw new ArgumentOutOfRangeException(nameof(rentedPixels), "The BGRA buffer must contain the complete frame.");
        _pixels = rentedPixels;
        Width = width;
        Height = height;
        TimestampTicks = timestampTicks;
        TimestampUnixSeconds = timestampUnixSeconds;
        ProtectedContentMasked = protectedContentMasked;
    }

    public int Width { get; }
    public int Height { get; }
    public int Stride => checked(Width * 4);
    /// <summary>Stopwatch.GetTimestamp units, used only for a monotonic media clock.</summary>
    public long TimestampTicks { get; }
    /// <summary>UTC Unix seconds; suitable for the cross-platform ScreenData timestamp.</summary>
    public double TimestampUnixSeconds { get; }
    public bool ProtectedContentMasked { get; }
    public ReadOnlyMemory<byte> BgraPixels => (_pixels ?? throw new ObjectDisposedException(nameof(WindowsDesktopFrame)))
        .AsMemory(0, checked(Stride * Height));

    public void Dispose()
    {
        var pixels = Interlocked.Exchange(ref _pixels, null);
        if (pixels is not null) ArrayPool<byte>.Shared.Return(pixels);
    }
}

internal sealed record WindowsDesktopEncodingOptions(
    int Width, int Height, int FramesPerSecond, int BitrateBitsPerSecond)
{
    public void RequireValid()
    {
        if (Width is < 2 or > 8192 || Height is < 2 or > 8192 || (Width & 1) != 0 || (Height & 1) != 0)
            throw new ArgumentOutOfRangeException(nameof(Width), "H.264 output dimensions must be even and between 2 and 8192 pixels.");
        if ((long)Width * Height > 33_177_600)
            throw new ArgumentOutOfRangeException(nameof(Height), "H.264 output must not exceed the 8K pixel budget.");
        if (FramesPerSecond is < 1 or > 120)
            throw new ArgumentOutOfRangeException(nameof(FramesPerSecond), "Frame rate must be between 1 and 120 FPS.");
        if (BitrateBitsPerSecond is < 64_000 or > 150_000_000)
            throw new ArgumentOutOfRangeException(nameof(BitrateBitsPerSecond), "Bitrate must be between 64 kbps and 150 Mbps.");
    }
}

internal sealed record WindowsDesktopEncodedFrame(
    byte[] H264Bytes, bool IsKeyFrame, int Width, int Height, double TimestampUnixSeconds);

internal interface IWindowsDesktopCapture : IDisposable
{
    WindowsDesktopDisplay Display { get; }
    /// <returns>Null when no desktop update arrived, unless an explicit refresh requests the last captured desktop.</returns>
    Task<WindowsDesktopFrame?> CaptureAsync(TimeSpan timeout, CancellationToken cancellationToken = default,
        bool includeUnchangedFrame = false);
}

internal interface IWindowsDesktopEncoder : IDisposable
{
    WindowsDesktopEncodingOptions Options { get; }
    IReadOnlyList<WindowsDesktopEncodedFrame> Encode(WindowsDesktopFrame frame, bool forceKeyFrame = false);
    void UpdateBitrate(int bitrateBitsPerSecond);
    void RequestKeyFrame();
}
