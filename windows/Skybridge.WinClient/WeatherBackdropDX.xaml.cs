using System;
using System.Diagnostics;
using System.Numerics;
using System.Threading;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using SharpGen.Runtime;
using Vortice.Direct3D;
using Vortice.Direct3D12;
using Vortice.Direct3D12.Debug;
using Vortice.DXGI;
using Vortice.Mathematics;
using Vortice.WinUI;
using static Vortice.Direct3D12.D3D12;
using static Vortice.DXGI.DXGI;

namespace Skybridge.WinClient;

// =====================================================================================
//  WeatherBackdropDX — Direct3D 12 + WinUI 3 SwapChainPanel feasibility probe.
//
//  Renders an ANIMATED clear color (time-based hue cycle) into a DXGI composition swap
//  chain bound to a SwapChainPanel, proving the native DX12 pipeline runs on net10 with no
//  Roslyn dependency. Clear-color only — NO HLSL shader yet.
//
//  Lifecycle (all DX touch-points on the UI thread, which is where SwapChainPanel events
//  and CompositionTarget.Rendering fire):
//    Panel.Loaded   -> InitializeDirectX(): debug layer (Debug builds), DXGI factory, D3D12
//                      device on the first hardware adapter, direct command queue,
//                      CreateSwapChainForComposition (queue as first arg, B8G8R8A8_UNorm,
//                      flip-discard, 2 buffers), QI to IDXGISwapChain3, SetSwapChain on the
//                      panel, RTV heap + per-buffer RTVs, per-buffer allocators + one command
//                      list, fence + AutoResetEvent. Then subscribe CompositionTarget.Rendering.
//    Rendering      -> RenderFrame(): reset allocator+list, barrier Present->RenderTarget,
//                      clear to the animated color, barrier back to Present, execute, Present,
//                      then fence-pace so we never overwrite an in-flight buffer.
//    Panel.SizeChanged / CompositionScaleChanged -> ResizeSwapChain(): GPU idle, drop RTVs,
//                      ResizeBuffers to physical pixels, recreate RTVs, SetMatrixTransform
//                      (1/scale) so XAML doesn't double-apply DPI. Guards zero size.
//    Panel.Unloaded -> Teardown(): unsubscribe Rendering, fence-wait GPU idle, Dispose all
//                      COM objects.
//
//  Any failure in init is caught, logged via Debug.WriteLine, and leaves the panel blank so a
//  DX failure degrades gracefully rather than crashing the app. No per-frame allocations in
//  the render path (arrays/handles are reused).
// =====================================================================================
public sealed partial class WeatherBackdropDX : UserControl
{
    private const int BufferCount = 2;
    private static readonly Format BackBufferFormat = Format.B8G8R8A8_UNorm;

    // ── DX12 objects (null until a successful Initialize; _ready gates the render path). ──
    private ID3D12Device2? _device;
    private ID3D12CommandQueue? _queue;
    private IDXGISwapChain3? _swapChain;
    private IDXGISwapChain2? _swapChain2;   // for SetMatrixTransform (DPI compensation)
    private ID3D12DescriptorHeap? _rtvHeap;
    private uint _rtvDescriptorSize;
    private readonly ID3D12Resource?[] _renderTargets = new ID3D12Resource?[BufferCount];
    private readonly ID3D12CommandAllocator?[] _allocators = new ID3D12CommandAllocator?[BufferCount];
    private ID3D12GraphicsCommandList4? _commandList;

    private ID3D12Fence? _fence;
    private AutoResetEvent? _fenceEvent;
    private readonly ulong[] _frameFenceValues = new ulong[BufferCount];
    private ulong _fenceValue;
    private uint _backBufferIndex;

    // ── Backbuffer pixel size + composition scale (driven by SizeChanged / scale change). ──
    private uint _width;
    private uint _height;
    private float _scaleX = 1f;
    private float _scaleY = 1f;

    // ── State flags. ──
    private bool _ready;            // DX initialized + RTVs valid -> render path armed
    private bool _renderingHooked;  // CompositionTarget.Rendering subscription active

    // ── Animation clock (Stopwatch, NOT DateTime). ──
    private readonly Stopwatch _clock = new();

    public WeatherBackdropDX()
    {
        InitializeComponent();
        Panel.Loaded += OnPanelLoaded;
        Panel.Unloaded += OnPanelUnloaded;
        Panel.SizeChanged += OnPanelSizeChanged;
        Panel.CompositionScaleChanged += OnCompositionScaleChanged;
    }

    // -------------------------------------------------------------------------------------
    //  Condition dependency property — IDENTICAL contract to WeatherBackdrop so the existing
    //  MainWindow binding (Condition="{Binding WeatherConditionKey}") works unchanged. The
    //  probe ignores the value for now (clear-color only).
    // -------------------------------------------------------------------------------------
    public static readonly DependencyProperty ConditionProperty =
        DependencyProperty.Register(
            nameof(Condition),
            typeof(string),
            typeof(WeatherBackdropDX),
            new PropertyMetadata("Clear"));

    public string Condition
    {
        get => (string)GetValue(ConditionProperty);
        set => SetValue(ConditionProperty, value);
    }

    // -------------------------------------------------------------------------------------
    //  Lifecycle
    // -------------------------------------------------------------------------------------

    private void OnPanelLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            InitializeDirectX();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WeatherBackdropDX] DX12 init failed, panel left transparent: {ex}");
            Teardown();   // release any partially-created objects; leaves panel blank
            return;
        }

        _clock.Restart();

        if (!_renderingHooked)
        {
            CompositionTarget.Rendering += OnRendering;
            _renderingHooked = true;
        }
    }

    private void OnPanelUnloaded(object sender, RoutedEventArgs e)
    {
        Teardown();
    }

    private void OnPanelSizeChanged(object sender, SizeChangedEventArgs e)
    {
        TryResize();
    }

    private void OnCompositionScaleChanged(SwapChainPanel sender, object args)
    {
        TryResize();
    }

    // -------------------------------------------------------------------------------------
    //  Initialization
    // -------------------------------------------------------------------------------------

    private void InitializeDirectX()
    {
        ComputeBackBufferSize(out _width, out _height);
        if (_width == 0 || _height == 0)
        {
            // Panel not measured yet: create at 1x1, the first SizeChanged will ResizeBuffers.
            _width = 1;
            _height = 1;
        }

        // 1. Optional debug layer (must run BEFORE device/factory creation). Debug builds only.
        bool validation = false;
#if DEBUG
        if (D3D12GetDebugInterface(out ID3D12Debug? debug).Success && debug is not null)
        {
            debug.EnableDebugLayer();
            debug.Dispose();
            validation = true;
        }
#endif

        // DXGI factory (validation flag => DXGI_CREATE_FACTORY_DEBUG).
        using IDXGIFactory4 factory = CreateDXGIFactory2<IDXGIFactory4>(validation);

        // 1b. Device — first non-software adapter at FeatureLevel 11_0.
        ID3D12Device2? device = null;
        for (uint i = 0; factory.EnumAdapters1(i, out IDXGIAdapter1? adapter).Success; i++)
        {
            if (adapter is null)
            {
                continue;
            }

            if ((adapter.Description1.Flags & AdapterFlags.Software) != AdapterFlags.None)
            {
                adapter.Dispose();
                continue;
            }

            if (D3D12CreateDevice(adapter, FeatureLevel.Level_11_0, out device).Success)
            {
                adapter.Dispose();
                break;
            }

            adapter.Dispose();
        }

        _device = device ?? throw new PlatformNotSupportedException("No Direct3D 12 hardware adapter available.");

        // 2. Direct command queue (DXGI presents through the direct queue for D3D12).
        _queue = _device.CreateCommandQueue(CommandListType.Direct);

        // 3 + 4. Composition swap chain — queue is the FIRST arg for D3D12; then QI to SwapChain3.
        var desc = new SwapChainDescription1
        {
            Width = _width,
            Height = _height,
            Format = BackBufferFormat,
            Stereo = false,
            SampleDescription = new SampleDescription(1, 0),
            BufferUsage = Usage.RenderTargetOutput,
            BufferCount = BufferCount,
            Scaling = Scaling.Stretch,            // REQUIRED for composition swap chains
            SwapEffect = SwapEffect.FlipDiscard,  // flip model required; discard preferred for DX12
            AlphaMode = AlphaMode.Premultiplied,  // premultiplied for XAML composition
            Flags = SwapChainFlags.None,
        };

        using (IDXGISwapChain1 sc1 = factory.CreateSwapChainForComposition(_queue, desc, null))
        {
            _swapChain = sc1.QueryInterface<IDXGISwapChain3>();
        }
        _swapChain2 = _swapChain.QueryInterface<IDXGISwapChain2>();
        _backBufferIndex = _swapChain.CurrentBackBufferIndex;

        // Wire the swap chain into the SwapChainPanel (UI thread — we are in Panel.Loaded).
        using (var native = new ISwapChainPanelNative(Panel))
        {
            native.SetSwapChain(_swapChain).CheckError();
        }

        // 5. RTV descriptor heap + per-buffer RTVs.
        _rtvHeap = _device.CreateDescriptorHeap(
            new DescriptorHeapDescription(DescriptorHeapType.RenderTargetView, BufferCount));
        _rtvDescriptorSize = _device.GetDescriptorHandleIncrementSize(DescriptorHeapType.RenderTargetView);
        CreateRenderTargetViews();

        // 6. One allocator per buffer + a single command list (created open -> close it).
        for (int i = 0; i < BufferCount; i++)
        {
            _allocators[i] = _device.CreateCommandAllocator(CommandListType.Direct);
        }
        _commandList = _device.CreateCommandList<ID3D12GraphicsCommandList4>(
            CommandListType.Direct, _allocators[0]!, null);
        _commandList.Close();

        // 7. Fence + wait event for frame pacing.
        _fence = _device.CreateFence(0);
        _fenceEvent = new AutoResetEvent(false);
        _fenceValue = 0;
        Array.Clear(_frameFenceValues, 0, _frameFenceValues.Length);

        // Apply the initial DPI-compensation transform.
        ApplyDpiTransform();

        _ready = true;
    }

    private void CreateRenderTargetViews()
    {
        if (_device is null || _swapChain is null || _rtvHeap is null)
        {
            return;
        }

        CpuDescriptorHandle handle = _rtvHeap.GetCPUDescriptorHandleForHeapStart();
        for (uint i = 0; i < BufferCount; i++)
        {
            _renderTargets[i] = _swapChain.GetBuffer<ID3D12Resource>(i);
            _device.CreateRenderTargetView(_renderTargets[i], null, handle);
            handle += (int)_rtvDescriptorSize;
        }
    }

    private void ReleaseRenderTargetViews()
    {
        for (int i = 0; i < BufferCount; i++)
        {
            _renderTargets[i]?.Dispose();
            _renderTargets[i] = null;
        }
    }

    // -------------------------------------------------------------------------------------
    //  Render loop
    // -------------------------------------------------------------------------------------

    private void OnRendering(object? sender, object e)
    {
        if (!_ready)
        {
            return;
        }

        try
        {
            RenderFrame();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WeatherBackdropDX] render failed, stopping loop: {ex}");
            Teardown();
        }
    }

    private void RenderFrame()
    {
        if (_device is null || _queue is null || _swapChain is null ||
            _commandList is null || _rtvHeap is null)
        {
            return;
        }

        ID3D12CommandAllocator? allocator = _allocators[_backBufferIndex];
        ID3D12Resource? backBuffer = _renderTargets[_backBufferIndex];
        if (allocator is null || backBuffer is null)
        {
            return;
        }

        allocator.Reset();
        _commandList.Reset(allocator, null);

        // Present -> RenderTarget.
        _commandList.ResourceBarrierTransition(backBuffer, ResourceStates.Present, ResourceStates.RenderTarget);

        var rtv = new CpuDescriptorHandle(
            _rtvHeap.GetCPUDescriptorHandleForHeapStart(), (int)_backBufferIndex, _rtvDescriptorSize);

        _commandList.OMSetRenderTargets(rtv, null);
        _commandList.ClearRenderTargetView(rtv, ComputeAnimatedColor());

        // RenderTarget -> Present.
        _commandList.ResourceBarrierTransition(backBuffer, ResourceStates.RenderTarget, ResourceStates.Present);

        _commandList.Close();
        _queue.ExecuteCommandList(_commandList);

        Result present = _swapChain.Present(1, PresentFlags.None);
        if (present.Failure)
        {
            if (present.Code == Vortice.DXGI.ResultCode.DeviceRemoved.Code ||
                present.Code == Vortice.DXGI.ResultCode.DeviceReset.Code)
            {
                // Device lost — stop rendering and tear down; a future revision can recreate.
                Debug.WriteLine($"[WeatherBackdropDX] device lost on Present (0x{present.Code:X8}); tearing down.");
                Teardown();
                return;
            }

            present.CheckError();
        }

        MoveToNextFrame();
    }

    // Smooth time-based hue cycle so it is visibly ANIMATED (proves the loop is live), with a
    // gentle dark-blue bias so it reads as an ambient backdrop rather than a strobing rainbow.
    private Color4 ComputeAnimatedColor()
    {
        double t = _clock.Elapsed.TotalSeconds;
        float hue = (float)((t * 12.0) % 360.0);                  // ~30s per full hue rotation
        float pulse = 0.5f + 0.5f * (float)Math.Sin(t * 0.8);     // slow brightness breathing
        // Low saturation/value keep it dark and ambient; full alpha (opaque clear).
        return HsvToColor4(hue, 0.55f, 0.18f + 0.12f * pulse);
    }

    private static Color4 HsvToColor4(float h, float s, float v)
    {
        h = ((h % 360f) + 360f) % 360f;
        float c = v * s;
        float x = c * (1f - Math.Abs((h / 60f) % 2f - 1f));
        float m = v - c;
        float r, g, b;
        if (h < 60f) { r = c; g = x; b = 0f; }
        else if (h < 120f) { r = x; g = c; b = 0f; }
        else if (h < 180f) { r = 0f; g = c; b = x; }
        else if (h < 240f) { r = 0f; g = x; b = c; }
        else if (h < 300f) { r = x; g = 0f; b = c; }
        else { r = c; g = 0f; b = x; }
        return new Color4(r + m, g + m, b + m, 1f);
    }

    // Fence pacing so we never overwrite a buffer the GPU is still presenting.
    private void MoveToNextFrame()
    {
        if (_queue is null || _fence is null || _swapChain is null || _fenceEvent is null)
        {
            return;
        }

        ulong signal = ++_fenceValue;
        _queue.Signal(_fence, signal);
        _frameFenceValues[_backBufferIndex] = signal;

        _backBufferIndex = _swapChain.CurrentBackBufferIndex;

        if (_fence.CompletedValue < _frameFenceValues[_backBufferIndex])
        {
            _fence.SetEventOnCompletion(_frameFenceValues[_backBufferIndex], _fenceEvent);
            _fenceEvent.WaitOne();
        }
    }

    private void WaitForGpuIdle()
    {
        if (_queue is null || _fence is null || _fenceEvent is null)
        {
            return;
        }

        ulong signal = ++_fenceValue;
        _queue.Signal(_fence, signal);
        if (_fence.CompletedValue < signal)
        {
            _fence.SetEventOnCompletion(signal, _fenceEvent);
            _fenceEvent.WaitOne();
        }
    }

    // -------------------------------------------------------------------------------------
    //  Resize / DPI
    // -------------------------------------------------------------------------------------

    private void TryResize()
    {
        if (!_ready || _swapChain is null)
        {
            return;
        }

        ComputeBackBufferSize(out uint newWidth, out uint newHeight);
        if (newWidth == 0 || newHeight == 0)
        {
            return; // guard against zero size (collapsed / not measured)
        }

        if (newWidth == _width && newHeight == _height)
        {
            // Size unchanged — the scale may still have changed; refresh the transform.
            ApplyDpiTransform();
            return;
        }

        try
        {
            ResizeSwapChain(newWidth, newHeight);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WeatherBackdropDX] resize failed, tearing down: {ex}");
            Teardown();
        }
    }

    private void ResizeSwapChain(uint newWidth, uint newHeight)
    {
        if (_swapChain is null)
        {
            return;
        }

        WaitForGpuIdle();
        ReleaseRenderTargetViews();

        _swapChain.ResizeBuffers(BufferCount, newWidth, newHeight, BackBufferFormat, SwapChainFlags.None);
        _width = newWidth;
        _height = newHeight;

        CreateRenderTargetViews();
        _backBufferIndex = _swapChain.CurrentBackBufferIndex;

        ApplyDpiTransform();
    }

    // Counter the composition scale: render at native pixels, display 1:1. Scale+translation
    // only (SetMatrixTransform rejects skew/rotation).
    private void ApplyDpiTransform()
    {
        if (_swapChain2 is null)
        {
            return;
        }

        float sx = _scaleX <= 0f ? 1f : _scaleX;
        float sy = _scaleY <= 0f ? 1f : _scaleY;
        var inverse = new Matrix3x2(1f / sx, 0f, 0f, 1f / sy, 0f, 0f);
        _swapChain2.SetMatrixTransform(inverse);
    }

    // Back-buffer pixel size = DIP size * composition scale, rounded, clamped to >= 0.
    private void ComputeBackBufferSize(out uint width, out uint height)
    {
        _scaleX = Panel.CompositionScaleX <= 0f ? 1f : Panel.CompositionScaleX;
        _scaleY = Panel.CompositionScaleY <= 0f ? 1f : Panel.CompositionScaleY;

        double w = Panel.ActualWidth * _scaleX;
        double h = Panel.ActualHeight * _scaleY;

        width = w >= 1.0 ? (uint)(w + 0.5) : 0u;
        height = h >= 1.0 ? (uint)(h + 0.5) : 0u;
    }

    // -------------------------------------------------------------------------------------
    //  Teardown
    // -------------------------------------------------------------------------------------

    private void Teardown()
    {
        _ready = false;

        if (_renderingHooked)
        {
            CompositionTarget.Rendering -= OnRendering;
            _renderingHooked = false;
        }

        // Flush the GPU before releasing anything it might still reference.
        try
        {
            WaitForGpuIdle();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WeatherBackdropDX] GPU flush during teardown failed: {ex}");
        }

        _clock.Reset();

        ReleaseRenderTargetViews();

        for (int i = 0; i < BufferCount; i++)
        {
            _allocators[i]?.Dispose();
            _allocators[i] = null;
        }

        _commandList?.Dispose();
        _commandList = null;

        _rtvHeap?.Dispose();
        _rtvHeap = null;

        _swapChain2?.Dispose();
        _swapChain2 = null;

        _swapChain?.Dispose();
        _swapChain = null;

        _fence?.Dispose();
        _fence = null;

        _fenceEvent?.Dispose();
        _fenceEvent = null;

        _queue?.Dispose();
        _queue = null;

        _device?.Dispose();
        _device = null;

        _fenceValue = 0;
        _backBufferIndex = 0;
        Array.Clear(_frameFenceValues, 0, _frameFenceValues.Length);
    }
}
