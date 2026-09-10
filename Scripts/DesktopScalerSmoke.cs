using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using Skybridge.WinClient.Services.RemoteControl;
using Vortice;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

internal static class DesktopScalerSmoke
{
    internal static int Run(string evidence)
    {
        Directory.CreateDirectory(evidence);
        try
        {
            var checks = Validate();
            File.WriteAllText(Path.Combine(evidence, "gpu-rotation.json"), JsonSerializer.Serialize(new
            {
                Status = "passed", Rotations = checks, NoDisplayConfigurationChange = true,
                NoInputInjected = true, NoForegroundChange = true
            }, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        catch (Exception failure)
        {
            File.WriteAllText(Path.Combine(evidence, "gpu-rotation.json"), JsonSerializer.Serialize(new
            {
                Status = "failed", Error = failure.ToString()
            }, new JsonSerializerOptions { WriteIndented = true }));
            return 1;
        }
    }

    private static IReadOnlyList<string> Validate()
    {
        var display = WindowsDesktopCapture.EnumerateDisplays().Single(item => item.IsPrimary);
        var luid = (Luid)long.Parse(display.Id.AsSpan(0, 16), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory4>();
        using var adapter = factory.EnumAdapterByLuid<IDXGIAdapter1>(luid);
        D3D11.D3D11CreateDevice(adapter, DriverType.Unknown, DeviceCreationFlags.BgraSupport,
            [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0], out ID3D11Device device, out ID3D11DeviceContext context).CheckError();
        using (device)
        using (context)
        {
            const int width = 128, height = 64;
            var pixels = new byte[width * height * 4];
            for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var value = (byte)((x < width / 2 ? 10 : 70) + (y < height / 2 ? 0 : 140));
                var offset = (y * width + x) * 4;
                pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = value;
                pixels[offset + 3] = 255;
            }
            var pin = GCHandle.Alloc(pixels, GCHandleType.Pinned);
            ID3D11Texture2D input;
            try
            {
                input = device.CreateTexture2D(new Texture2DDescription
                {
                    Width = width, Height = height, MipLevels = 1, ArraySize = 1, Format = Format.B8G8R8A8_UNorm,
                    Usage = ResourceUsage.Default, BindFlags = BindFlags.None, SampleDescription = new SampleDescription(1, 0)
                }, new SubresourceData(pin.AddrOfPinnedObject(), width * 4, 0));
            }
            finally { pin.Free(); }
            using (input)
            {
                var rotations = new List<string>();
                foreach (var rotation in Enum.GetValues<WindowsDesktopRotation>())
                {
                    var portrait = rotation is WindowsDesktopRotation.Clockwise90 or WindowsDesktopRotation.Clockwise270;
                    var outputWidth = (portrait ? height : width) / 2;
                    var outputHeight = (portrait ? width : height) / 2;
                    using var scaler = new WindowsDesktopScaler(device, context, width, height, rotation, outputWidth, outputHeight);
                    using var staging = device.CreateTexture2D(new Texture2DDescription
                    {
                        Width = (uint)outputWidth, Height = (uint)outputHeight, MipLevels = 1, ArraySize = 1,
                        Format = Format.B8G8R8A8_UNorm, Usage = ResourceUsage.Staging,
                        CPUAccessFlags = CpuAccessFlags.Read, SampleDescription = new SampleDescription(1, 0)
                    });
                    context.CopyResource(staging, scaler.Process(input));
                    var expected = new byte[pixels.Length];
                    WindowsDesktopPixels.RotateBgra(pixels, width, height, rotation, expected);
                    var mapped = context.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
                    try
                    {
                        foreach (var y in new[] { outputHeight / 4, outputHeight * 3 / 4 })
                        foreach (var x in new[] { outputWidth / 4, outputWidth * 3 / 4 })
                        for (var channel = 0; channel < 4; channel++)
                        {
                            var actual = Marshal.ReadByte(mapped.DataPointer + checked(y * (int)mapped.RowPitch + x * 4 + channel));
                            var reference = expected[((y * 2 + 1) * outputWidth * 2 + x * 2 + 1) * 4 + channel];
                            if (actual != reference)
                                throw new InvalidOperationException($"GPU {rotation} corner ({x},{y}) channel {channel}: expected {reference}, got {actual}.");
                        }
                    }
                    finally { context.Unmap(staging, 0); }
                    rotations.Add(rotation.ToString());
                }
                return rotations;
            }
        }
    }
}
