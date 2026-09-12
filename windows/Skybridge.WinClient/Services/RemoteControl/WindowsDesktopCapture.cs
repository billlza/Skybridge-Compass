using System.Buffers;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using SharpGen.Runtime;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Skybridge.WinClient.Services.RemoteControl;

/// <summary>One DXGI duplication and D3D11 device, owned by one selected display session.</summary>
[SupportedOSPlatform("windows10.0.19041")]
internal sealed class WindowsDesktopCapture : IWindowsDesktopCapture
{
    private const int DxgiNotFound = unchecked((int)0x887a0002);
    private const int DxgiWaitTimeout = unchecked((int)0x887a0027);
    private const int DxgiAccessLost = unchecked((int)0x887a0026);
    private readonly ID3D11Device _device;
    private readonly ID3D11DeviceContext _context;
    private readonly IDXGIOutputDuplication _duplication;
    private readonly ID3D11Texture2D _staging;
    private readonly int _sourceWidth;
    private readonly int _sourceHeight;
    private readonly int _readbackWidth, _readbackHeight, _outputWidth, _outputHeight;
    private readonly WindowsDesktopScaler? _scaler;
    private readonly WindowsDesktopRotation _rotation;
    private readonly object _gate = new();
    private WindowsDesktopPointerShape? _pointerShape;
    private int _pointerX, _pointerY;
    private bool _pointerVisible;
    private bool _hasDesktopImage;
    private bool _protectedContentMasked;
    private int _capturePending;
    private bool _disposed;

    public WindowsDesktopCapture(string displayId, int? outputWidth = null, int? outputHeight = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(displayId);
        if (outputWidth.HasValue != outputHeight.HasValue)
            throw new ArgumentException("GPU capture width and height must be supplied together.");
        if (outputWidth is { } width && outputHeight is { } height &&
            (width is < 2 or > 8192 || height is < 2 or > 8192 || (width & 1) != 0 || (height & 1) != 0 || (long)width * height > 33_177_600))
            throw new ArgumentOutOfRangeException(nameof(outputWidth), "GPU output dimensions must be even and fit the 8K pixel budget.");
        WindowsInteractiveDesktop.RequireAvailable();
        using var coordinates = WindowsDesktopDpiScope.Enter();
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        using var selection = FindDisplay(factory, displayId);
        Display = selection.Display;
        ID3D11Device? device = null;
        ID3D11DeviceContext? context = null;
        IDXGIOutputDuplication? duplication = null;
        ID3D11Texture2D? staging = null;
        WindowsDesktopScaler? scaler = null;
        try
        {
            D3D11.D3D11CreateDevice(selection.Adapter, DriverType.Unknown, DeviceCreationFlags.BgraSupport,
                [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0], out device, out context).CheckError();
            using var output = selection.Output.QueryInterface<IDXGIOutput1>();
            duplication = output.DuplicateOutput(device);
            var description = duplication.Description;
            _sourceWidth = checked((int)description.ModeDescription.Width);
            _sourceHeight = checked((int)description.ModeDescription.Height);
            _rotation = MapRotation(description.Rotation);
            RequireDimensions(_sourceWidth, _sourceHeight, Display, _rotation);
            _outputWidth = outputWidth ?? Display.Width;
            _outputHeight = outputHeight ?? Display.Height;
            if (outputWidth.HasValue)
                scaler = new WindowsDesktopScaler(device, context, _sourceWidth, _sourceHeight, _rotation, _outputWidth, _outputHeight);
            _readbackWidth = scaler is null ? _sourceWidth : _outputWidth;
            _readbackHeight = scaler is null ? _sourceHeight : _outputHeight;
            var textureDescription = new Texture2DDescription
            {
                Width = (uint)_readbackWidth, Height = (uint)_readbackHeight,
                MipLevels = 1, ArraySize = 1, Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Staging,
                CPUAccessFlags = CpuAccessFlags.Read, BindFlags = BindFlags.None
            };
            staging = device.CreateTexture2D(textureDescription);
            _device = device; _context = context; _duplication = duplication; _staging = staging;
            _scaler = scaler;
        }
        catch (Exception failure)
        {
            staging?.Dispose(); scaler?.Dispose(); duplication?.Dispose(); context?.Dispose(); device?.Dispose();
            throw NativeFailure("Unable to start DXGI desktop capture for the selected display.", failure);
        }
    }

    public WindowsDesktopDisplay Display { get; }

    public static IReadOnlyList<WindowsDesktopDisplay> EnumerateDisplays()
    {
        WindowsInteractiveDesktop.RequireAvailable();
        using var coordinates = WindowsDesktopDpiScope.Enter();
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        var displays = new List<WindowsDesktopDisplay>();
        for (uint adapterIndex = 0; ; adapterIndex++)
        {
            var result = factory.EnumAdapters1(adapterIndex, out var adapter);
            if (result.Code == DxgiNotFound) break;
            result.CheckError();
            using (adapter)
            for (uint outputIndex = 0; ; outputIndex++)
            {
                result = adapter.EnumOutputs(outputIndex, out var output);
                if (result.Code == DxgiNotFound) break;
                result.CheckError();
                using (output)
                {
                    var description = output.Description;
                    if (description.AttachedToDesktop) displays.Add(Describe(adapter, outputIndex, description));
                }
            }
        }
        return displays;
    }

    public async Task<WindowsDesktopFrame?> CaptureAsync(TimeSpan timeout, CancellationToken cancellationToken = default,
        bool includeUnchangedFrame = false)
    {
        if (timeout < TimeSpan.Zero || timeout > TimeSpan.FromSeconds(2))
            throw new ArgumentOutOfRangeException(nameof(timeout), "A capture wait must be between zero and two seconds.");
        if (Interlocked.CompareExchange(ref _capturePending, 1, 0) != 0)
            throw new InvalidOperationException("Only one desktop capture request may be pending.");
        try
        {
            return await Task.Run(() => Capture(timeout, cancellationToken, includeUnchangedFrame), cancellationToken).ConfigureAwait(false);
        }
        finally { Volatile.Write(ref _capturePending, 0); }
    }

    private WindowsDesktopFrame? Capture(TimeSpan timeout, CancellationToken cancellationToken, bool includeUnchangedFrame)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            using var coordinates = WindowsDesktopDpiScope.Enter();
            var started = Stopwatch.GetTimestamp();
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                WindowsInteractiveDesktop.RequireAvailable();
                var remaining = timeout - Stopwatch.GetElapsedTime(started);
                var waitMilliseconds = (uint)Math.Clamp(Math.Ceiling(remaining.TotalMilliseconds), 0, 100);
                var acquired = _duplication.AcquireNextFrame(waitMilliseconds, out var info, out var resource);
                if (acquired.Code == DxgiWaitTimeout)
                {
                    if (Stopwatch.GetElapsedTime(started) >= timeout)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        WindowsInteractiveDesktop.RequireAvailable();
                        return includeUnchangedFrame && _hasDesktopImage ? CopyFrame(_protectedContentMasked) : null;
                    }
                    continue;
                }
                if (acquired.Failure) throw NativeFailure("DXGI could not acquire the next desktop frame.", new SharpGenException(acquired));
                WindowsDesktopFrame? frame = null;
                Exception? failure = null;
                try
                {
                    using (resource)
                    using (var texture = resource.QueryInterface<ID3D11Texture2D>())
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        var description = texture.Description;
                        if (description.Width != _sourceWidth || description.Height != _sourceHeight || description.Format != Format.B8G8R8A8_UNorm)
                            throw new WindowsDesktopException(WindowsDesktopFailure.DisplayConfigurationChanged,
                                "The captured display format changed; recreate capture and encoding for the new display configuration.");
                        UpdatePointer(info);
                        // A cursor-only acquisition has no desktop update. Its texture
                        // can be blank, including the first acquisition of a duplication.
                        // Keep the last real desktop separate from cursor composition.
                        if (info.LastPresentTime != 0)
                        {
                            _context.CopyResource(_staging, _scaler is null ? texture : _scaler.Process(texture));
                            _hasDesktopImage = true;
                            _protectedContentMasked = info.ProtectedContentMaskedOut;
                        }
                        if (_hasDesktopImage) frame = CopyFrame(_protectedContentMasked);
                        WindowsInteractiveDesktop.RequireAvailable();
                    }
                }
                catch (Exception error) { failure = error; }
                var released = _duplication.ReleaseFrame();
                if (released.Failure)
                {
                    var releaseFailure = NativeFailure("DXGI failed to release a captured frame.", new SharpGenException(released));
                    failure = failure is null ? releaseFailure : new AggregateException(failure, releaseFailure);
                }
                if (failure is not null)
                {
                    frame?.Dispose();
                    if (failure is OperationCanceledException) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
                    throw NativeFailure("Desktop capture failed.", failure);
                }
                if (frame is not null) return frame;
                if (Stopwatch.GetElapsedTime(started) >= timeout) return null;
            }
        }
    }

    private WindowsDesktopFrame CopyFrame(bool protectedContentMasked)
    {
        var length = checked(_readbackWidth * _readbackHeight * 4);
        byte[]? source = ArrayPool<byte>.Shared.Rent(length);
        byte[]? rotated = null;
        try
        {
            var mapped = _context.Map(_staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
            try
            {
                if (mapped.RowPitch < _readbackWidth * 4)
                    throw new WindowsDesktopException(WindowsDesktopFailure.CaptureFailed, "DXGI supplied an invalid BGRA row pitch.");
                for (var row = 0; row < _readbackHeight; row++)
                    Marshal.Copy(mapped.DataPointer + checked(row * (int)mapped.RowPitch), source, row * _readbackWidth * 4, _readbackWidth * 4);
            }
            finally { _context.Unmap(_staging, 0); }
            var pixels = source;
            if (_scaler is null && _rotation != WindowsDesktopRotation.Identity)
            {
                rotated = ArrayPool<byte>.Shared.Rent(length);
                WindowsDesktopPixels.RotateBgra(source.AsSpan(0, length), _sourceWidth, _sourceHeight, _rotation, rotated.AsSpan(0, length));
                pixels = rotated;
            }
            if (_pointerVisible && _pointerShape is not null)
                WindowsDesktopPixels.CompositePointer(pixels.AsSpan(0, length), _outputWidth, _outputHeight,
                    _pointerShape, _pointerX, _pointerY, Display.Width, Display.Height);
            var frame = new WindowsDesktopFrame(pixels, _outputWidth, _outputHeight, Stopwatch.GetTimestamp(),
                (DateTimeOffset.UtcNow - DateTimeOffset.UnixEpoch).TotalSeconds, protectedContentMasked);
            if (ReferenceEquals(pixels, source)) source = null;
            else rotated = null;
            return frame;
        }
        finally
        {
            if (source is not null) ArrayPool<byte>.Shared.Return(source);
            if (rotated is not null) ArrayPool<byte>.Shared.Return(rotated);
        }
    }

    private void UpdatePointer(OutduplFrameInfo info)
    {
        if (info.LastMouseUpdateTime != 0)
        {
            _pointerVisible = info.PointerPosition.Visible;
            _pointerX = info.PointerPosition.Position.X; _pointerY = info.PointerPosition.Position.Y;
        }
        if (info.PointerShapeBufferSize == 0) return;
        if (info.PointerShapeBufferSize > 4 * 1024 * 1024)
            throw new WindowsDesktopException(WindowsDesktopFailure.CaptureFailed, "DXGI desktop pointer exceeded the supported shape budget.");
        var memory = Marshal.AllocHGlobal(checked((int)info.PointerShapeBufferSize));
        try
        {
            _duplication.GetFramePointerShape(info.PointerShapeBufferSize, memory, out var required, out var shape).CheckError();
            if (required > info.PointerShapeBufferSize)
                throw new WindowsDesktopException(WindowsDesktopFailure.CaptureFailed, "DXGI desktop pointer exceeded the allocated shape buffer.");
            var bytes = new byte[checked((int)required)];
            Marshal.Copy(memory, bytes, 0, bytes.Length);
            _pointerShape = new((WindowsDesktopPointerKind)shape.Type, checked((int)shape.Width),
                checked((int)shape.Height), checked((int)shape.Pitch), bytes);
        }
        finally { Marshal.FreeHGlobal(memory); }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _staging.Dispose(); _scaler?.Dispose(); _duplication.Dispose(); _context.Dispose(); _device.Dispose();
            _pointerShape = null;
        }
    }

    private static DisplaySelection FindDisplay(IDXGIFactory1 factory, string displayId)
    {
        for (uint adapterIndex = 0; ; adapterIndex++)
        {
            var result = factory.EnumAdapters1(adapterIndex, out var adapter);
            if (result.Code == DxgiNotFound) break;
            result.CheckError();
            var retainAdapter = false;
            try
            {
                for (uint outputIndex = 0; ; outputIndex++)
                {
                    result = adapter.EnumOutputs(outputIndex, out var output);
                    if (result.Code == DxgiNotFound) break;
                    result.CheckError();
                    var retainOutput = false;
                    try
                    {
                        var description = output.Description;
                        if (!description.AttachedToDesktop) continue;
                        var display = Describe(adapter, outputIndex, description);
                        if (!string.Equals(display.Id, displayId, StringComparison.Ordinal)) continue;
                        retainAdapter = true; retainOutput = true;
                        return new(adapter, output, display);
                    }
                    finally { if (!retainOutput) output.Dispose(); }
                }
            }
            finally { if (!retainAdapter) adapter.Dispose(); }
        }
        throw new WindowsDesktopException(WindowsDesktopFailure.DisplayUnavailable, "The requested desktop display is no longer attached.");
    }

    private static WindowsDesktopDisplay Describe(IDXGIAdapter1 adapter, uint outputIndex, OutputDescription description)
    {
        var monitor = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(description.Monitor, ref monitor))
            throw new WindowsDesktopException(WindowsDesktopFailure.DisplayUnavailable,
                "Unable to inspect the selected desktop monitor.", new Win32Exception(Marshal.GetLastWin32Error()));
        var bounds = description.DesktopCoordinates;
        return new($"{(long)adapter.Description1.Luid:x16}:{outputIndex}", description.DeviceName,
            bounds.Left, bounds.Top, bounds.Right - bounds.Left, bounds.Bottom - bounds.Top, (monitor.Flags & 1) != 0);
    }

    private static WindowsDesktopRotation MapRotation(ModeRotation rotation) => rotation switch
    {
        ModeRotation.Unspecified or ModeRotation.Identity => WindowsDesktopRotation.Identity,
        ModeRotation.Rotate90 => WindowsDesktopRotation.Clockwise90,
        ModeRotation.Rotate180 => WindowsDesktopRotation.Clockwise180,
        ModeRotation.Rotate270 => WindowsDesktopRotation.Clockwise270,
        _ => throw new WindowsDesktopException(WindowsDesktopFailure.DisplayConfigurationChanged, "DXGI returned an unsupported desktop rotation.")
    };

    private static void RequireDimensions(int width, int height, WindowsDesktopDisplay display, WindowsDesktopRotation rotation)
    {
        var portrait = rotation is WindowsDesktopRotation.Clockwise90 or WindowsDesktopRotation.Clockwise270;
        if (width < 1 || height < 1 || width > 8192 || height > 8192 || (long)width * height > 33_177_600 ||
            display.Width != (portrait ? height : width) || display.Height != (portrait ? width : height))
            throw new WindowsDesktopException(WindowsDesktopFailure.DisplayConfigurationChanged,
                "The desktop duplication dimensions do not match the selected physical display or exceed the supported capture budget.");
    }

    private static WindowsDesktopException NativeFailure(string message, Exception failure)
    {
        if (failure is WindowsDesktopException known) return known;
        var kind = failure is SharpGenException native ? native.ResultCode.Code switch
        {
            DxgiAccessLost or unchecked((int)0x887a0005) or unchecked((int)0x887a0007) => WindowsDesktopFailure.CaptureAccessLost,
            unchecked((int)0x80070005) or unchecked((int)0x887a0028) => WindowsDesktopFailure.InteractiveDesktopUnavailable,
            _ => WindowsDesktopFailure.CaptureFailed
        } : WindowsDesktopFailure.CaptureFailed;
        return new(kind, message, failure);
    }

    private sealed record DisplaySelection(IDXGIAdapter1 Adapter, IDXGIOutput Output, WindowsDesktopDisplay Display) : IDisposable
    {
        public void Dispose() { Output.Dispose(); Adapter.Dispose(); }
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo { internal int Size; internal Vortice.RawRect Monitor, Work; internal uint Flags; }
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
}
