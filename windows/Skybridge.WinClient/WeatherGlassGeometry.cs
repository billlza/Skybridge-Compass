namespace Skybridge.WinClient;

// The arithmetic behind the shell frost, kept free of WinUI and Direct3D types so the renderer's
// contract (uv rects, the per-back-buffer constant ring, the glass-source size) can be exercised by
// the contract tests on any OS. WeatherBackdropDX is the only production caller.
internal static class WeatherGlassGeometry
{
    // One constant slot; D3D12 requires 256-byte alignment for a constant buffer view.
    public const int MaximumSurfaceCount = 16;
    public const uint ConstantSlotBytes = 1024;

    // Per frame: slot 0 drives the glass-source pass, slot 1 the final pass.
    public const uint PassesPerFrame = 2;

    // The glass source is one texel per eight dips at every DPI, so the frost's dominant blur (the
    // downsample) does not change with the display scale.
    public const double GlassSourceDipsPerTexel = 8.0;

    // Frost kernel radius in dips.
    public const double GlassBlurDips = 16.0;

    public static uint ConstantBufferBytes(uint backBufferCount)
    {
        if (backBufferCount == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(backBufferCount), "A swap chain has at least one back buffer.");
        }

        return ConstantSlotBytes * PassesPerFrame * backBufferCount;
    }

    // Byte offset of a pass's constant slot for the frame rendering into the given back buffer.
    public static ulong ConstantSlotOffset(uint backBufferIndex, uint pass)
    {
        if (pass >= PassesPerFrame)
        {
            throw new ArgumentOutOfRangeException(nameof(pass), $"A frame has {PassesPerFrame} passes; got pass {pass}.");
        }

        return ((ulong)backBufferIndex * PassesPerFrame + pass) * ConstantSlotBytes;
    }

    public static (uint Width, uint Height) GlassSourceSize(double panelDipWidth, double panelDipHeight) =>
        (TexelsFor(panelDipWidth), TexelsFor(panelDipHeight));

    private static uint TexelsFor(double dips)
    {
        // An unsized (0 or not yet measured) panel still needs a 1x1 target for its first frame.
        if (!double.IsFinite(dips) || dips <= 0)
        {
            return 1;
        }

        return Math.Max(1u, (uint)Math.Round(dips / GlassSourceDipsPerTexel));
    }

    // The frost kernel radius as a fraction of the panel width (the shader scales y by the aspect).
    public static float GlassBlurFraction(double panelDipWidth) =>
        (float)(GlassBlurDips / Math.Max(panelDipWidth, 1.0));

    // A frost region must be finite with a non-negative size; an empty size means "no frost".
    public static void ValidateRegion(string name, double x, double y, double width, double height)
    {
        if (!double.IsFinite(x) || !double.IsFinite(y) || !double.IsFinite(width) || !double.IsFinite(height) || width < 0 || height < 0)
        {
            throw new ArgumentOutOfRangeException(name, $"A frost region must be finite with a non-negative size; got x={x}, y={y}, width={width}, height={height}.");
        }
    }

    // A validated region in the panel's dip space -> screen uv (x, y, w, h). Empty regions and an
    // unmeasured panel yield zeros, which the shader reads as "no frost".
    public static (float X, float Y, float W, float H) RectToUv(double x, double y, double width, double height, double panelWidth, double panelHeight)
    {
        if (width <= 0 || height <= 0 || panelWidth <= 0 || panelHeight <= 0)
        {
            return (0f, 0f, 0f, 0f);
        }

        return ((float)(x / panelWidth), (float)(y / panelHeight), (float)(width / panelWidth), (float)(height / panelHeight));
    }
}
