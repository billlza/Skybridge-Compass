using System;
using System.IO;
using Vortice.Direct3D12;
using Vortice.DXGI;

namespace Skybridge.WinClient;

public sealed partial class WeatherBackdropDX
{
    private ID3D12Resource? _cloudDensityAtlas;

    // The same periodic density atlas used by Android and Apple. It is linear data,
    // uploaded once per device lifetime; it does not pass through sRGB conversion.
    private void CreateCloudDensityAtlas()
    {
        if (_device is null || _queue is null || _commandList is null || _srvHeap is null || _allocators[0] is null)
        {
            throw new InvalidOperationException("Cloud density upload requires an initialized graphics device.");
        }

        const int size = 528;
        const int rowBytes = size * 4;
        // D3D12 texture upload rows are aligned to 256 bytes; the first footprint starts at 0.
        const int rowPitch = (rowBytes + 255) & ~255;
        const int uploadBytes = rowPitch * size;
        using Stream source = typeof(WeatherBackdropDX).Assembly.GetManifestResourceStream("Skybridge.Weather.CloudDensity.rgba")
            ?? throw new InvalidDataException("The packaged cloud density atlas is missing.");
        if (source.Length != rowBytes * size)
        {
            throw new InvalidDataException("The cloud density atlas must contain 528 by 528 RGBA texels.");
        }
        byte[] pixels = new byte[rowBytes * size];
        source.ReadExactly(pixels);

        _cloudDensityAtlas = _device.CreateCommittedResource(
            HeapType.Default,
            ResourceDescription.Texture2D(Format.R8G8B8A8_UNorm, size, size, 1, 1),
            ResourceStates.CopyDest);
        using ID3D12Resource upload = _device.CreateCommittedResource(
            HeapType.Upload, ResourceDescription.Buffer(uploadBytes), ResourceStates.GenericRead);
        Span<byte> destination = upload.Map<byte>(0, uploadBytes);
        try
        {
            for (int row = 0; row < size; row++)
            {
                pixels.AsSpan(row * rowBytes, rowBytes).CopyTo(destination.Slice(row * rowPitch, rowBytes));
            }
        }
        finally
        {
            upload.Unmap(0);
        }

        _allocators[0]!.Reset();
        _commandList.Reset(_allocators[0]!, null);
        var footprint = new PlacedSubresourceFootPrint
        {
            Offset = 0,
            Footprint = new SubresourceFootPrint(Format.R8G8B8A8_UNorm, size, size, 1, rowPitch),
        };
        _commandList.CopyTextureRegion(
            new TextureCopyLocation(_cloudDensityAtlas, 0), 0, 0, 0,
            new TextureCopyLocation(upload, footprint), null);
        _commandList.ResourceBarrierTransition(_cloudDensityAtlas, ResourceStates.CopyDest, ResourceStates.PixelShaderResource);
        _commandList.Close();
        _queue.ExecuteCommandList(_commandList);
        // The upload allocation stays alive until this one-time copy is complete.
        WaitForGpuIdle();

        uint increment = _device.GetDescriptorHandleIncrementSize(
            DescriptorHeapType.ConstantBufferViewShaderResourceViewUnorderedAccessView);
        _device.CreateShaderResourceView(_cloudDensityAtlas, null,
            new CpuDescriptorHandle(_srvHeap.GetCPUDescriptorHandleForHeapStart(), 1, increment));
    }
}
