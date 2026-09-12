using System;
using Skybridge.WinClient.Services;
using Vortice.Direct3D12;
using Vortice.DXGI;

namespace Skybridge.WinClient;

public sealed partial class WeatherBackdropDX
{
    private int _backgroundMode;
    private WallpaperPixels? _backgroundImage;
    private ID3D12Resource? _wallpaperTexture;

    public void SetBackground(string theme, WallpaperPixels? image)
    {
        int mode = theme switch
        {
            "weather" => 0, "starryNight" => 1, "deepSpace" => 2,
            "aurora" => 3, "classic" => 4, "custom" => 5,
            _ => throw new ArgumentOutOfRangeException(nameof(theme))
        };
        if (mode == 5 && image is null) throw new ArgumentException("A custom background requires decoded pixels.", nameof(image));
        if (image is not null && (image.Width is <= 0 or > 4096 || image.Height is <= 0 or > 4096
            || image.Rgba.Length != checked(image.Width * image.Height * 4)))
            throw new ArgumentException("Wallpaper pixels do not match their dimensions.", nameof(image));
        if (_ready && !ReferenceEquals(image, _backgroundImage)) CreateWallpaperTexture(image);
        _backgroundImage = image;
        _backgroundMode = mode;
        RequestFrame();
    }

    private void CreateWallpaperTexture(WallpaperPixels? image)
    {
        if (_device is null || _queue is null || _commandList is null || _srvHeap is null || _allocators[0] is null)
            throw new InvalidOperationException("Wallpaper upload requires an initialized graphics device.");

        var allocator = _allocators[0] ?? throw new InvalidOperationException("Wallpaper command allocator is unavailable.");
        int width = image?.Width ?? 1, height = image?.Height ?? 1;
        byte[] pixels = image?.Rgba ?? [0, 0, 0, 255];
        int rowBytes = checked(width * 4), rowPitch = (rowBytes + 255) & ~255;
        int uploadBytes = checked(rowPitch * height);
        // This wait happens only on a user-requested image change/device creation.
        // No old texture or descriptor may be replaced while a frame uses it.
        WaitForGpuIdle();
        var next = _device.CreateCommittedResource(HeapType.Default,
            ResourceDescription.Texture2D(Format.R8G8B8A8_UNorm, checked((uint)width), checked((uint)height), 1, 1), ResourceStates.CopyDest);
        try
        {
            using var upload = _device.CreateCommittedResource(HeapType.Upload, ResourceDescription.Buffer(checked((ulong)uploadBytes)), ResourceStates.GenericRead);
            Span<byte> destination = upload.Map<byte>(0, uploadBytes);
            try
            {
                for (int row = 0; row < height; row++) pixels.AsSpan(row * rowBytes, rowBytes).CopyTo(destination.Slice(row * rowPitch, rowBytes));
            }
            finally { upload.Unmap(0); }
            allocator.Reset();
            _commandList.Reset(allocator, null);
            var footprint = new PlacedSubresourceFootPrint
            {
                Offset = 0,
                Footprint = new SubresourceFootPrint(Format.R8G8B8A8_UNorm, checked((uint)width), checked((uint)height), 1, checked((uint)rowPitch))
            };
            _commandList.CopyTextureRegion(new TextureCopyLocation(next, 0), 0, 0, 0, new TextureCopyLocation(upload, footprint), null);
            _commandList.ResourceBarrierTransition(next, ResourceStates.CopyDest, ResourceStates.PixelShaderResource);
            _commandList.Close();
            _queue.ExecuteCommandList(_commandList);
            WaitForGpuIdle();
            uint increment = _device.GetDescriptorHandleIncrementSize(DescriptorHeapType.ConstantBufferViewShaderResourceViewUnorderedAccessView);
            _device.CreateShaderResourceView(next, null, new CpuDescriptorHandle(_srvHeap.GetCPUDescriptorHandleForHeapStart(), 2, increment));
            _wallpaperTexture?.Dispose();
            _wallpaperTexture = next;
        }
        catch { next.Dispose(); throw; }
    }
}
