using Skybridge.WinClient;

internal static class WeatherGlassGeometryTests
{
    internal static IReadOnlyList<(string Name, Func<Task> Run)> Cases { get; } =
    [
        ("frost rect to uv maps dips onto the panel and switches off for empty or unsized input", RectToUv),
        ("frost region validation rejects non-finite and negative regions and accepts empty ones", Validation),
        ("constant slots are distinct, 256-byte aligned and inside the per-back-buffer ring", ConstantRing),
        ("glass source is one texel per eight dips at every DPI and never below one texel", GlassSourceSize),
        ("frost kernel radius is sixteen dips of the panel width", BlurFraction)
    ];

    private static void Require(bool value, string reason) { if (!value) throw new InvalidOperationException(reason); }
    private static bool Near(float actual, double expected) => Math.Abs(actual - expected) < 1e-6;

    private static Task RectToUv()
    {
        var uv = WeatherGlassGeometry.RectToUv(10, 20, 30, 40, 100, 200);
        Require(Near(uv.X, 0.1) && Near(uv.Y, 0.1) && Near(uv.W, 0.3) && Near(uv.H, 0.2), "A 10,20,30,40 rect on a 100x200 panel must map to 0.1,0.1,0.3,0.2.");
        Require(WeatherGlassGeometry.RectToUv(10, 20, 0, 40, 100, 200) == (0f, 0f, 0f, 0f), "An empty rect must switch the frost off.");
        Require(WeatherGlassGeometry.RectToUv(10, 20, 30, 40, 0, 200) == (0f, 0f, 0f, 0f), "An unmeasured panel must switch the frost off.");
        Require(WeatherGlassGeometry.RectToUv(0, 0, 100, 200, 100, 200) == (0f, 0f, 1f, 1f), "A rect covering the panel must map to the full uv square.");
        return Task.CompletedTask;
    }

    private static Task Validation()
    {
        foreach (var (x, y, w, h) in new[] { (double.NaN, 0d, 1d, 1d), (0d, double.PositiveInfinity, 1d, 1d), (0d, 0d, -1d, 1d), (0d, 0d, 1d, double.NegativeInfinity) })
        {
            var rejected = false;
            try { WeatherGlassGeometry.ValidateRegion("region", x, y, w, h); }
            catch (ArgumentOutOfRangeException) { rejected = true; }
            Require(rejected, $"Region {x},{y},{w},{h} must be rejected.");
        }

        WeatherGlassGeometry.ValidateRegion("region", 0, 0, 0, 0);
        WeatherGlassGeometry.ValidateRegion("region", -5, -5, 10, 10);
        return Task.CompletedTask;
    }

    private static Task ConstantRing()
    {
        const uint backBuffers = 2;
        var bytes = WeatherGlassGeometry.ConstantBufferBytes(backBuffers);
        Require(WeatherGlassGeometry.ConstantSlotBytes >= 96 + WeatherGlassGeometry.MaximumSurfaceCount * 48, "A slot must contain the fixed header and every clipped glass surface record.");
        var offsets = new List<ulong>();
        for (uint index = 0; index < backBuffers; index++)
        for (uint pass = 0; pass < WeatherGlassGeometry.PassesPerFrame; pass++)
        {
            offsets.Add(WeatherGlassGeometry.ConstantSlotOffset(index, pass));
        }

        Require(offsets.Distinct().Count() == offsets.Count, "Every (back buffer, pass) slot must be distinct.");
        Require(offsets.All(o => o % 256 == 0), "Every slot must be 256-byte aligned.");
        Require(offsets.Max() + WeatherGlassGeometry.ConstantSlotBytes <= bytes, "Every slot must lie inside the ring buffer.");
        var rejected = false;
        try { WeatherGlassGeometry.ConstantSlotOffset(0, WeatherGlassGeometry.PassesPerFrame); }
        catch (ArgumentOutOfRangeException) { rejected = true; }
        Require(rejected, "A pass index beyond the frame's passes must be rejected.");
        rejected = false;
        try { WeatherGlassGeometry.ConstantBufferBytes(0); }
        catch (ArgumentOutOfRangeException) { rejected = true; }
        Require(rejected, "A swap chain without back buffers must be rejected.");
        return Task.CompletedTask;
    }

    private static Task GlassSourceSize()
    {
        Require(WeatherGlassGeometry.GlassSourceSize(1200, 800) == (150u, 100u), "A 1200x800 dip panel needs a 150x100 glass source at every DPI.");
        Require(WeatherGlassGeometry.GlassSourceSize(2400, 1600) == (300u, 200u), "A 2400x1600 dip panel needs a 300x200 glass source.");
        Require(WeatherGlassGeometry.GlassSourceSize(0, 0) == (1u, 1u), "An unsized panel still needs a 1x1 glass source.");
        Require(WeatherGlassGeometry.GlassSourceSize(4, 4) == (1u, 1u), "A tiny panel never drops below one texel.");
        Require(WeatherGlassGeometry.GlassSourceSize(double.NaN, 800) == (1u, 100u), "A non-finite width falls back to one texel without failing the height.");
        return Task.CompletedTask;
    }

    private static Task BlurFraction()
    {
        Require(Near(WeatherGlassGeometry.GlassBlurFraction(1200), 16.0 / 1200.0), "On a 1200 dip panel the radius is 16/1200 of the width.");
        Require(Near(WeatherGlassGeometry.GlassBlurFraction(0), 16.0), "An unmeasured panel clamps the divisor to one dip.");
        return Task.CompletedTask;
    }
}
