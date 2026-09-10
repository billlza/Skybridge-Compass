using System;
using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Skybridge.WinClient.Services;
using SharpGen.Runtime;
using Vortice;                  // RawRect (full-surface scissor)
using Vortice.Direct3D;
using Vortice.Direct3D12;
using Vortice.Direct3D12.Debug;
using Vortice.D3DCompiler;
using Vortice.DXGI;
using Vortice.Mathematics;
using Vortice.WinUI;
using static Vortice.Direct3D12.D3D12;
using static Vortice.DXGI.DXGI;

namespace Skybridge.WinClient;

// =====================================================================================
//  WeatherBackdropDX — Direct3D 12 + WinUI 3 SwapChainPanel cinematic weather backdrop.
//
//  Renders a fullscreen raymarch HLSL shader (VS+PS, SV_VertexID fullscreen triangle) into a
//  DXGI composition swap chain bound to a SwapChainPanel. The pixel shader composites a
//  per-condition cinematic weather scene — volumetric raymarched clouds, parallax rain/snow,
//  twinkling stars, height fog, and Stormy lightning — tuned to match the macOS cinematic
//  weather effects (Sources/SkyBridgeCore/Weather/Effects/Cinematic/*). The clear color is kept
//  as the backdrop base; the shader draws over it. Runs on net10 via Vortice 3.8.3 with no Roslyn
//  dependency; shaders are compiled at init with Vortice.D3DCompiler (FXC vs_5_0/ps_5_0).
//
//  Two passes per frame: pass 0 draws the scene into a 1/8-resolution "glass source" texture;
//  pass 1 draws the frame and, under the sidebar / top-bar rects the window hands over through
//  SetGlassRegions, replaces the sky with a blurred, dimmed, filmed sample of that texture: the
//  Mac's .ultraThinMaterial, rendered here because WinUI paints every in-app AcrylicBrush as
//  its FallbackColor while this swap chain is attached to the XAML tree.
//
//  Lifecycle (all DX touch-points on the UI thread, which is where SwapChainPanel events
//  and CompositionTarget.Rendering fire):
//    Panel.Loaded   -> InitializeDirectX(): debug layer (Debug builds), DXGI factory, D3D12
//                      device on the first hardware adapter, direct command queue,
//                      CreateSwapChainForComposition (queue as first arg, B8G8R8A8_UNorm,
//                      flip-discard, 2 buffers), QI to IDXGISwapChain3, SetSwapChain on the
//                      panel, RTV heap + per-buffer RTVs, per-buffer allocators + one command
//                      list, fence + AutoResetEvent. Then subscribe CompositionTarget.Rendering.
//    Rendering      -> RenderFrame(): reset allocator+list, pass 0 into the glass source,
//                      barrier Present->RenderTarget, clear, pass 1 (the frame with the frost),
//                      barrier back to Present, execute, Present, then fence-pace so we never
//                      overwrite an in-flight buffer (constants are a per-back-buffer ring).
//    Panel.SizeChanged / CompositionScaleChanged -> ResizeSwapChain(): GPU idle, drop RTVs,
//                      ResizeBuffers to physical pixels, recreate RTVs, SetMatrixTransform
//                      (1/scale) so XAML doesn't double-apply DPI. Guards zero size.
//    Panel.Unloaded -> Teardown(): unsubscribe Rendering, fence-wait GPU idle, Dispose all
//                      COM objects.
//
//  Any failure in init is caught, logged through WindowsRuntimeLog (Error/"backdrop"), and
//  DX failure degrades gracefully rather than crashing the app. No per-frame allocations in
//  the render path (arrays/handles are reused).
// =====================================================================================
public sealed partial class WeatherBackdropDX : UserControl
{
    private const int BufferCount = 2;
    private static readonly Format BackBufferFormat = Format.B8G8R8A8_UNorm;

    // Internal render scale for the heavy volumetric raymarch. The fullscreen pixel shader
    // (40-step cloud view march + 6-step light march + 64-step fog march, 5-6 octave fbm) is
    // run once per back-buffer pixel every frame, so its cost is quadratic in the render
    // resolution. Rendering the back buffer at a FRACTION of the panel's physical pixels and
    // letting the composition swap chain stretch it up to fill the panel cuts pixel-shader cost
    // by ~1/(scale^2) (0.6 -> ~2.8x cheaper) while a slowly moving cloudy backdrop tolerates the
    // slight softness. The shader's visual complexity is unchanged (no fewer steps / octaves).
    private const float RenderScale = 0.6f;

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

    // ── Graphics pipeline for the fullscreen weather shader pass. ──
    private ID3D12RootSignature? _rootSignature;     // root CBV b0 + glass SRV table (t0) + static sampler s0
    private ID3D12PipelineState? _pipelineState;      // VS+PS fullscreen-triangle PSO (both passes)
    private ID3D12Resource? _constantBuffer;          // Upload heap; per back buffer two 256-byte slots (pass 0 / pass 1)
    private bool _shaderReady;                        // true once PSO/root-sig/CB are valid

    // ── Frosted glass for the shell chrome. XAML cannot provide it: with this control's swap chain
    //    attached to the tree, WinUI paints every in-app AcrylicBrush as its FallbackColor (verified
    //    on the Windows box by detaching the swap chain, which made the brushes live). So pass 0
    //    renders the scene into a small "glass source" texture and pass 1 blurs it under the
    //    sidebar / top-bar rects the window hands over through SetGlassRegions. ──
    //    Sizes and offsets come from WeatherGlassGeometry (one texel per eight dips, 16 dip radius).
    private ID3D12DescriptorHeap? _srvHeap;           // one shader-visible SRV (t0): the glass source
    private ID3D12Resource? _glassSource;             // RT + SRV, recreated with the back buffers
    private uint _glassWidth;
    private uint _glassHeight;
    private Windows.Foundation.Rect _glassSidebarDip; // frost rects in this control's dip space
    private Windows.Foundation.Rect _glassTopBarDip;  // (zero-sized = no frost)

    // CPU-side mirror of the HLSL cbuffer. Layout MUST match `cbuffer WeatherCB` in WeatherHlsl
    // EXACTLY (HLSL packs into 16-byte rows; a field never straddles a 16-byte boundary). Row map:
    //   row 0 (off 0):  float  time(0)  + float2 resolution(4,8) + int condition(12)
    //   row 1 (off 16): float2 pointerUV(16,20) + float pointerStrength(24) + float pointerRadius(28)
    //   row 2 (off 32): float2 pointerVelocity(32,36) + int renderPass(40) + float glassBlur(44)
    //   row 3 (off 48): float4 glassRect0 (sidebar frost rect in screen uv: x, y, w, h)
    //   row 4 (off 64): float4 glassRect1 (top-bar frost rect)
    //   row 5 (off 80): 16 bytes pad
    // 96 bytes used per slot; the upload buffer holds two 256-byte slots (pass 0 and pass 1).
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct WeatherConstants
    {
        public float Time;             // offset 0
        public float ResolutionX;      // offset 4
        public float ResolutionY;      // offset 8
        public int Condition;          // offset 12
        public float PointerU;         // offset 16  (pointerUV.x)
        public float PointerV;         // offset 20  (pointerUV.y)
        public float PointerStrength;  // offset 24  (0..1 disperse strength)
        public float PointerRadius;    // offset 28  (influence radius in UV)
        public float PointerVelX;      // offset 32  (pointerVelocity.x, UV/sec)
        public float PointerVelY;      // offset 36  (pointerVelocity.y, UV/sec)
        public int RenderPass;         // offset 40  (0 = scene into the glass source, 1 = final frame)
        public float GlassBlur;        // offset 44  (frost kernel radius as a fraction of the panel width)
        public float Glass0X;          // offset 48  (sidebar frost rect in screen uv: x, y, w, h)
        public float Glass0Y;          // offset 52
        public float Glass0W;          // offset 56
        public float Glass0H;          // offset 60
        public float Glass1X;          // offset 64  (top-bar frost rect)
        public float Glass1Y;          // offset 68
        public float Glass1W;          // offset 72
        public float Glass1H;          // offset 76
        public float Pad0;             // offset 80  (pad to fill the row; unused)
        public float Pad1;             // offset 84
        public float Pad2;             // offset 88
        public float Pad3;             // offset 92
    }

    // Frame pacing only waits for the frame that last used the current back buffer, so the
    // constants are a ring indexed by back buffer (two 256-byte slots per back buffer: glass
    // source pass, final pass): frame N+1 never rewrites what frame N's list may still read.
    private static readonly uint ConstantBufferBytes = WeatherGlassGeometry.ConstantBufferBytes(BufferCount);

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
    private bool _frameRequested;   // one static redraw after load, layout or weather changes
    private bool _initializedUnsized; // init ran before layout (1x1 buffer) -> force first resize

    // ── Animation clock (Stopwatch, NOT DateTime). ──
    private readonly Stopwatch _clock = new();

    // ── Wave-to-disperse pointer interaction (port of the macOS InteractiveClearSystem /
    //    GlobalHaze hover-disperse). The pointer is captured at the window-root level (this
    //    UserControl is IsHitTestVisible=False and never sees its own pointer events), normalized
    //    to 0..1 panel UV, and fed to the shader so clouds part / thin where the pointer waves and
    //    re-fill after it stops. All state is touched only on the UI thread (pointer events +
    //    CompositionTarget.Rendering both fire there), so no locking is needed. ──
    private UIElement? _pointerHost;          // window-root element we listen on (handledEventsToo)
    private bool _pointerHandlersHooked;
    // Cache the delegate instances so AddHandler/RemoveHandler use the SAME reference (RemoveHandler
    // matches by delegate identity; a freshly-constructed wrapper would NOT detach the subscription).
    private Microsoft.UI.Xaml.Input.PointerEventHandler? _pointerMovedHandler;
    private Microsoft.UI.Xaml.Input.PointerEventHandler? _pointerExitedHandler;
    private Vector2 _pointerUV = new(0.5f, 0.5f);     // last normalized pointer position (0..1)
    private Vector2 _pointerVelocityUV = Vector2.Zero; // smoothed UV/sec velocity (for trailing wake)
    private float _pointerStrength;            // 0..1 disperse strength, ramps up on move, decays after
    private float _pointerRadius = DefaultPointerRadiusUV; // current influence radius in UV
    private bool _pointerInside;               // pointer currently over the panel area
    private double _lastPointerSeconds;        // _clock timestamp of the last pointer-move sample
    private Vector2 _lastPointerUV = new(0.5f, 0.5f);

    // Disperse tuning — ported from the macOS InteractiveClearSystem numbers, re-expressed in
    // UV space (Mac works in pixels: baseRadius 100px, strength 0.3..1.0). On a ~1200px-wide
    // panel, 100px ~= 0.085 UV, so the base radius below matches Mac's resting influence; fast
    // waving widens it toward DefaultPointerRadiusUV*~1.9 just like Mac's velocity multiplier.
    private const float DefaultPointerRadiusUV = 0.16f;  // resting influence radius in UV (~120-190px)
    private const float MaxPointerRadiusUV = 0.30f;      // velocity-widened cap (Mac min(2.5x) growth)
    private const float PointerStrengthRise = 8.0f;      // strength ramp-up rate (per sec) while moving
    private const float PointerStrengthDecay = 2.2f;     // strength fade rate (per sec) after stop/leave
                                                         //  ~0.45s to fully re-fill, mirrors Mac's
                                                         //  opacityResponseRate=0.9 smooth re-fill feel
    private const double PointerIdleSeconds = 0.18;      // no move within this -> treat as stopped
                                                         //  (Mac uses 0.25s isMouseActive timeout)
    private const float VelocitySmoothing = 0.25f;       // EMA on pointer velocity (Mac alpha 0.20)

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
    //  MainWindow binding (Condition="{Binding WeatherConditionKey}") works unchanged.
    // -------------------------------------------------------------------------------------
    public static readonly DependencyProperty ConditionProperty =
        DependencyProperty.Register(
            nameof(Condition),
            typeof(string),
            typeof(WeatherBackdropDX),
            new PropertyMetadata("Clear", OnConditionChanged));

    public string Condition
    {
        get => (string)GetValue(ConditionProperty);
        set => SetValue(ConditionProperty, value);
    }

    /// <summary>Pauses decorative animation while retaining the rendered weather frame.</summary>
    public static readonly DependencyProperty IsAnimationEnabledProperty =
        DependencyProperty.Register(
            nameof(IsAnimationEnabled),
            typeof(bool),
            typeof(WeatherBackdropDX),
            new PropertyMetadata(true, OnAnimationEnabledChanged));

    public bool IsAnimationEnabled
    {
        get => (bool)GetValue(IsAnimationEnabledProperty);
        set => SetValue(IsAnimationEnabledProperty, value);
    }

    private static void OnConditionChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((WeatherBackdropDX)sender).RequestFrame();

    private static void OnAnimationEnabledChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((WeatherBackdropDX)sender).UpdateRenderLoop();

    private void RequestFrame()
    {
        _frameRequested = true;
        UpdateRenderLoop();
    }

    private void UpdateRenderLoop()
    {
        if (_ready && IsAnimationEnabled)
        {
            _clock.Start();
        }
        else
        {
            _clock.Stop();
            _pointerInside = false;
        }

        var shouldRender = _ready && (IsAnimationEnabled || _frameRequested);
        if (shouldRender == _renderingHooked) return;
        if (shouldRender)
            CompositionTarget.Rendering += OnRendering;
        else
            CompositionTarget.Rendering -= OnRendering;
        _renderingHooked = shouldRender;
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
            WindowsRuntimeLog.Write(
                WindowsLogLevel.Error,
                "backdrop",
                $"DX12 init failed, panel left transparent: {ex}");
            Teardown();   // release any partially-created objects; leaves panel blank
            return;
        }

        _clock.Reset();
        _lastFrameSeconds = 0.0;

        // Subscribe to window-root pointer events for the wave-to-disperse interaction. Safe to
        // call once XamlRoot is available (Loaded guarantees we are in the live visual tree).
        HookPointerHost();

        RequestFrame();
    }

    private void OnPanelUnloaded(object sender, RoutedEventArgs e)
    {
        Teardown();
    }

    private void OnPanelSizeChanged(object sender, SizeChangedEventArgs e)
    {
        // Use the event's NewSize: it is the authoritative just-laid-out DIP size, whereas
        // Panel.ActualWidth/Height can still report the PREVIOUS layout pass when this handler
        // runs (the root cause of the swap chain getting stuck at an early, too-small size and
        // only covering part of the content area).
        TryResize(e.NewSize.Width, e.NewSize.Height);
        RequestFrame();
    }

    private void OnCompositionScaleChanged(SwapChainPanel sender, object args)
    {
        // No size in the args; the live ActualWidth/Height are valid by the time a scale change
        // is delivered, so let TryResize read them.
        TryResize(Panel.ActualWidth, Panel.ActualHeight);
        RequestFrame();
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
            _initializedUnsized = true;
        }

        // 1. Debug layer (must run BEFORE device/factory creation). Debug builds only:
        //    if the D3D12 SDK debug layers are not installed, D3D12GetDebugInterface simply
        //    fails and we fall back to a non-validated device.
        bool validation = false;
#if DEBUG
        try
        {
            if (D3D12GetDebugInterface(out ID3D12Debug? debug).Success && debug is not null)
            {
                debug.EnableDebugLayer();
                debug.Dispose();
                validation = true;
            }
        }
        catch (Exception ex)
        {
            WindowsRuntimeLog.Write(
                WindowsLogLevel.Error,
                "backdrop",
                $"debug-layer enable failed (continuing without validation): {ex.Message}");
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
        // Vortice.DXGI also defines ISwapChainPanelNative; we want the WinUI one for SwapChainPanel.
        using (var native = new Vortice.WinUI.ISwapChainPanelNative(Panel))
        {
            native.SetSwapChain(_swapChain).CheckError();
        }

        // 5. RTV descriptor heap + per-buffer RTVs.
        //    One RTV per back buffer plus one for the glass source (index BufferCount).
        _rtvHeap = _device.CreateDescriptorHeap(
            new DescriptorHeapDescription(DescriptorHeapType.RenderTargetView, BufferCount + 1));
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

        // 8. Compile the weather shader and build the size-independent graphics pipeline
        //    (root signature + PSO + constant buffer). Failure here is non-fatal: the panel
        //    falls back to the animated clear color rather than crashing.
        try
        {
            CreateGraphicsPipeline();
            CreateGlassSource();
            _shaderReady = true;
        }
        catch (Exception ex)
        {
            WindowsRuntimeLog.Write(
                WindowsLogLevel.Error,
                "backdrop",
                $"shader pipeline init failed, using clear-color fallback: {ex}");
            ReleaseGlassSource();
            DisposeGraphicsPipeline();
            _shaderReady = false;
        }

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

    // Frost rects in this control's dip space, as laid out by the window (sidebar and top bar; the
    // Mac renders the same two surfaces as .ultraThinMaterial). Zero-sized rects switch the frost
    // off. A change redraws a static scene once so the frost follows the new layout.
    public void SetGlassRegions(Windows.Foundation.Rect sidebar, Windows.Foundation.Rect topBar)
    {
        if (!DispatcherQueue.HasThreadAccess)
        {
            throw new InvalidOperationException("SetGlassRegions must be called on the UI thread that owns the panel.");
        }

        WeatherGlassGeometry.ValidateRegion(nameof(sidebar), sidebar.X, sidebar.Y, sidebar.Width, sidebar.Height);
        WeatherGlassGeometry.ValidateRegion(nameof(topBar), topBar.X, topBar.Y, topBar.Width, topBar.Height);
        if (sidebar == _glassSidebarDip && topBar == _glassTopBarDip)
        {
            return;
        }

        _glassSidebarDip = sidebar;
        _glassTopBarDip = topBar;
        RequestFrame();
    }

    // The glass source: the scene at one texel per eight dips (so the frost's downsample blur is the
    // same at every DPI), render target for pass 0 and shader resource for pass 1. It is (re)built
    // wherever the back buffers are, once the pipeline (RTV heap slot, SRV heap) exists.
    private void CreateGlassSource()
    {
        if (_device is null || _rtvHeap is null || _srvHeap is null)
        {
            throw new InvalidOperationException("The glass source needs the device, the RTV heap and the SRV heap.");
        }

        ReleaseGlassSource();
        (_glassWidth, _glassHeight) = WeatherGlassGeometry.GlassSourceSize(Panel.ActualWidth, Panel.ActualHeight);
        _glassSource = _device.CreateCommittedResource(
            HeapType.Default,
            ResourceDescription.Texture2D(BackBufferFormat, _glassWidth, _glassHeight, 1, 1, 1, 0, ResourceFlags.AllowRenderTarget),
            ResourceStates.PixelShaderResource);

        var rtv = new CpuDescriptorHandle(_rtvHeap.GetCPUDescriptorHandleForHeapStart(), BufferCount, _rtvDescriptorSize);
        _device.CreateRenderTargetView(_glassSource, null, rtv);
        _device.CreateShaderResourceView(_glassSource, null, _srvHeap.GetCPUDescriptorHandleForHeapStart());
    }

    private void ReleaseGlassSource()
    {
        _glassSource?.Dispose();
        _glassSource = null;
        _glassWidth = 0;
        _glassHeight = 0;
    }

    // Pass 0: the scene into the glass source (root signature, PSO and table already bound by the
    // caller). The texture rests in the shader-resource state between frames; the fullscreen
    // triangle overwrites every texel, so no clear is needed.
    private void RenderGlassSource()
    {
        if (_commandList is null || _rtvHeap is null || _glassSource is null || _constantBuffer is null)
        {
            throw new InvalidOperationException("The glass source pass needs the command list, the RTV heap, the glass texture and the constants.");
        }

        _commandList.ResourceBarrierTransition(_glassSource, ResourceStates.PixelShaderResource, ResourceStates.RenderTarget);
        var rtv = new CpuDescriptorHandle(_rtvHeap.GetCPUDescriptorHandleForHeapStart(), BufferCount, _rtvDescriptorSize);
        _commandList.OMSetRenderTargets(rtv, null);
        _commandList.SetGraphicsRootConstantBufferView(0, _constantBuffer.GPUVirtualAddress + ConstantSlotOffset(0));
        _commandList.RSSetViewport(new Viewport(0f, 0f, _glassWidth, _glassHeight, 0f, 1f));
        _commandList.RSSetScissorRect(new RawRect(0, 0, (int)_glassWidth, (int)_glassHeight));
        _commandList.DrawInstanced(3, 1, 0, 0);
        _commandList.ResourceBarrierTransition(_glassSource, ResourceStates.RenderTarget, ResourceStates.PixelShaderResource);
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
    //  Graphics pipeline (fullscreen weather shader) — size-independent, built once in init.
    // -------------------------------------------------------------------------------------

    // D3DCompile reports a source-level failure as a bare E_FAIL and puts the only usable
    // diagnosis in the error blob, so discarding that blob turns every shader defect into an
    // unexplained HRESULT and the backdrop silently falls back to a flat clear colour. The
    // previous call shape also leaked both blobs, because CheckError() throws before the
    // Dispose() statement that followed it.
    private static Blob CompileShaderStage(string entryPoint, string profile)
    {
        Result result = Compiler.Compile(
            WeatherHlsl, entryPoint, "WeatherBackdrop.hlsl", profile,
            out Blob bytecode, out Blob errors);

        try
        {
            string diagnostic = ReadCompilerDiagnostic(errors);

            if (result.Failure)
            {
                bytecode?.Dispose();
                string detail = string.IsNullOrEmpty(diagnostic) ? "compiler produced no diagnostic" : diagnostic;
                throw new InvalidOperationException(
                    $"HLSL {profile} compilation of {entryPoint} failed ({result}): {detail}");
            }

            // A shader can compile AND warn. Reading the blob only on failure made those warnings
            // structurally invisible, which is not compatible with holding the build to zero
            // warnings - surface them instead of letting them accumulate unseen.
            if (!string.IsNullOrEmpty(diagnostic))
            {
                WindowsRuntimeLog.Write(
                    WindowsLogLevel.Warning,
                    "backdrop",
                    $"HLSL {profile} compilation of {entryPoint} succeeded with diagnostics: {diagnostic}");
            }

            return bytecode;
        }
        finally
        {
            errors?.Dispose();
        }
    }

    // Returns the compiler's own text, or an empty string when it said nothing. Callers decide
    // how to present "nothing", so this never invents a sentinel string that a caller would then
    // have to recognise by shape.
    private static string ReadCompilerDiagnostic(Blob errors)
    {
        if (errors is null)
        {
            return string.Empty;
        }

        IntPtr buffer = errors.BufferPointer;
        if (buffer == IntPtr.Zero)
        {
            return string.Empty;
        }

        // The blob is NUL-terminated ANSI. Reading to the terminator avoids converting
        // BufferSize (a PointerUSize) and avoids carrying the terminator into the message.
        string? text = Marshal.PtrToStringAnsi(buffer);
        return string.IsNullOrWhiteSpace(text) ? string.Empty : text.Trim();
    }

    private void CreateGraphicsPipeline()
    {
        if (_device is null)
        {
            return;
        }

        // 1. Compile VS + PS from the embedded HLSL (FXC, Shader Model 5.0).
        Blob vsBlob = CompileShaderStage("VSMain", "vs_5_0");
        Blob psBlob;
        try
        {
            psBlob = CompileShaderStage("PSMain", "ps_5_0");
        }
        catch
        {
            vsBlob.Dispose();
            throw;
        }

        using (vsBlob)
        using (psBlob)
        {
            // 2. Root signature: root CBV at b0 for all stages, a one-entry descriptor table with
            //    the glass source SRV (t0) and a static linear-clamp sampler (s0) for the pixel stage.
            var cbvDescriptor = new RootDescriptor1(0, 0);
            var cbvParam = new RootParameter1(
                RootParameterType.ConstantBufferView, cbvDescriptor, ShaderVisibility.All);
            // Data-volatile: the table stays bound while pass 0 writes the glass source (pass 0 never
            // samples it; the barriers order the write before pass 1's reads).
            var glassRange = new DescriptorRange1(DescriptorRangeType.ShaderResourceView, 1, 0, 0, 0, DescriptorRangeFlags.DataVolatile);
            var glassParam = new RootParameter1(new RootDescriptorTable1(glassRange), ShaderVisibility.Pixel);
            var glassSampler = new StaticSamplerDescription(SamplerDescription.LinearClamp, ShaderVisibility.Pixel, 0, 0);
            var rsDesc = new RootSignatureDescription1(
                RootSignatureFlags.None, new[] { cbvParam, glassParam }, new[] { glassSampler });
            _rootSignature = _device.CreateRootSignature(rsDesc);

            // 3. Graphics PSO: empty input layout (fullscreen triangle via SV_VertexID), triangle
            //    topology, cull none, opaque blend, depth disabled, single B8G8R8A8_UNorm RTV.
            var psoDesc = new GraphicsPipelineStateDescription
            {
                RootSignature = _rootSignature,
                VertexShader = vsBlob.AsMemory(),
                PixelShader = psBlob.AsMemory(),
                InputLayout = null,
                PrimitiveTopologyType = PrimitiveTopologyType.Triangle,
                RasterizerState = RasterizerDescription.CullNone,
                BlendState = BlendDescription.Opaque,
                DepthStencilState = DepthStencilDescription.None, // DepthEnable=false preset
                SampleMask = uint.MaxValue,
                RenderTargetFormats = new[] { BackBufferFormat },
                DepthStencilFormat = Format.Unknown,
                SampleDescription = new SampleDescription(1, 0),
            };
            _pipelineState = _device.CreateGraphicsPipelineState<ID3D12PipelineState>(psoDesc);
        }

        // 4. Upload-heap constant buffer: per back buffer two 256-byte slots (glass source pass,
        //    final pass). Mapped per-frame via the safe Span<T> overload in UpdateConstantBuffer;
        //    no persistent map / no unsafe field.
        _constantBuffer = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer(ConstantBufferBytes),
            ResourceStates.GenericRead);

        // 5. Shader-visible heap with the single glass-source SRV (filled by CreateGlassSource).
        _srvHeap = _device.CreateDescriptorHeap(new DescriptorHeapDescription(
            DescriptorHeapType.ConstantBufferViewShaderResourceViewUnorderedAccessView, 1, DescriptorHeapFlags.ShaderVisible));
    }

    // Byte offset of a pass's constant slot for the frame that renders into the current back buffer.
    private ulong ConstantSlotOffset(uint pass) => WeatherGlassGeometry.ConstantSlotOffset(_backBufferIndex, pass);

    // Per-frame: write the constants for both passes into this frame's ring slots (pass 0 = glass
    // source at its own resolution, pass 1 = final frame). Safe Span<T> map.
    private void UpdateConstantBuffer()
    {
        if (_constantBuffer is null)
        {
            return;
        }

        double now = _clock.Elapsed.TotalSeconds;
        AdvancePointerState(now);

        var data = new WeatherConstants
        {
            Time = (float)now,
            ResolutionX = _width,
            ResolutionY = _height,
            Condition = MapCondition(Condition),
            PointerU = _pointerUV.X,
            PointerV = _pointerUV.Y,
            PointerStrength = _pointerStrength,
            PointerRadius = _pointerRadius,
            PointerVelX = _pointerVelocityUV.X,
            PointerVelY = _pointerVelocityUV.Y,
            GlassBlur = WeatherGlassGeometry.GlassBlurFraction(Panel.ActualWidth),
        };
        (data.Glass0X, data.Glass0Y, data.Glass0W, data.Glass0H) = WeatherGlassGeometry.RectToUv(
            _glassSidebarDip.X, _glassSidebarDip.Y, _glassSidebarDip.Width, _glassSidebarDip.Height, Panel.ActualWidth, Panel.ActualHeight);
        (data.Glass1X, data.Glass1Y, data.Glass1W, data.Glass1H) = WeatherGlassGeometry.RectToUv(
            _glassTopBarDip.X, _glassTopBarDip.Y, _glassTopBarDip.Width, _glassTopBarDip.Height, Panel.ActualWidth, Panel.ActualHeight);

        WeatherConstants glassPass = data;
        glassPass.RenderPass = 0;
        glassPass.ResolutionX = _glassWidth;   // pixel-scaled effects follow the glass source's own grid
        glassPass.ResolutionY = _glassHeight;
        WeatherConstants finalPass = data;
        finalPass.RenderPass = 1;

        Span<byte> cb = _constantBuffer.Map<byte>(0, (int)ConstantBufferBytes);
        MemoryMarshal.Write(cb.Slice((int)ConstantSlotOffset(0)), in glassPass);
        MemoryMarshal.Write(cb.Slice((int)ConstantSlotOffset(1)), in finalPass);
        _constantBuffer.Unmap(0);
    }

    // -------------------------------------------------------------------------------------
    //  Wave-to-disperse pointer interaction (UI thread only)
    // -------------------------------------------------------------------------------------

    // Per-frame strength/velocity state machine, mirroring the macOS InteractiveClearSystem:
    //  - while the pointer is moving over the panel, strength ramps toward 1 and the radius
    //    widens with pointer speed (Mac: radius = base + base*velocityMultiplier);
    //  - once the pointer stops (no move within PointerIdleSeconds) or leaves, strength decays so
    //    the clouds smoothly re-fill (Mac: globalOpacity eased back, ~0.9 response rate).
    private void AdvancePointerState(double now)
    {
        // Frame delta (clamped so a stall doesn't snap the effect).
        float dt = (float)Math.Clamp(now - _lastFrameSeconds, 0.0, 0.1);
        _lastFrameSeconds = now;

        bool moving = _pointerInside && (now - _lastPointerSeconds) <= PointerIdleSeconds;

        if (moving)
        {
            // Ramp strength up toward 1 (exponential approach, frame-rate independent).
            _pointerStrength += (1.0f - _pointerStrength) * (1.0f - (float)Math.Exp(-PointerStrengthRise * dt));
        }
        else
        {
            // Decay strength toward 0 so the clouds re-fill; also relax velocity so the
            // trailing wake fades out.
            _pointerStrength *= (float)Math.Exp(-PointerStrengthDecay * dt);
            if (_pointerStrength < 0.001f)
            {
                _pointerStrength = 0f;
            }
            _pointerVelocityUV *= (float)Math.Exp(-PointerStrengthDecay * dt);
        }
    }

    private double _lastFrameSeconds;

    // Hook pointer-move / -exit on the window root so we observe the pointer even though this
    // UserControl is IsHitTestVisible=False. handledEventsToo:true means we still see moves that
    // the cards/buttons above us mark handled — and because we only READ the position (never set
    // e.Handled), clicks and hovers on the UI are completely unaffected.
    private void HookPointerHost()
    {
        if (_pointerHandlersHooked)
        {
            return;
        }

        // XamlRoot.Content is the top-level UIElement of the window's visual tree; it always
        // sees pointer moves regardless of which child consumes them.
        _pointerHost = XamlRoot?.Content as UIElement;
        if (_pointerHost is null)
        {
            return; // not in the tree yet; OnPanelLoaded retries, and SizeChanged can re-try too
        }

        _pointerMovedHandler = new Microsoft.UI.Xaml.Input.PointerEventHandler(OnHostPointerMoved);
        _pointerExitedHandler = new Microsoft.UI.Xaml.Input.PointerEventHandler(OnHostPointerExited);
        _pointerHost.AddHandler(UIElement.PointerMovedEvent, _pointerMovedHandler, handledEventsToo: true);
        _pointerHost.AddHandler(UIElement.PointerExitedEvent, _pointerExitedHandler, handledEventsToo: true);
        _pointerHandlersHooked = true;
    }

    private void UnhookPointerHost()
    {
        if (!_pointerHandlersHooked || _pointerHost is null)
        {
            return;
        }

        if (_pointerMovedHandler is not null)
        {
            _pointerHost.RemoveHandler(UIElement.PointerMovedEvent, _pointerMovedHandler);
        }
        if (_pointerExitedHandler is not null)
        {
            _pointerHost.RemoveHandler(UIElement.PointerExitedEvent, _pointerExitedHandler);
        }
        _pointerMovedHandler = null;
        _pointerExitedHandler = null;
        _pointerHandlersHooked = false;
        _pointerHost = null;
    }

    private void OnHostPointerMoved(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (!IsAnimationEnabled) return;
        // Position relative to THIS panel (so 0..1 maps to the backdrop, which spans the window).
        Windows.Foundation.Point pt = e.GetCurrentPoint(Panel).Position;
        double w = Panel.ActualWidth;
        double h = Panel.ActualHeight;
        if (w <= 0 || h <= 0)
        {
            return;
        }

        float u = (float)Math.Clamp(pt.X / w, 0.0, 1.0);
        float v = (float)Math.Clamp(pt.Y / h, 0.0, 1.0);
        bool inside = pt.X >= 0 && pt.X <= w && pt.Y >= 0 && pt.Y <= h;

        double now = _clock.Elapsed.TotalSeconds;
        double dt = now - _lastPointerSeconds;

        if (inside && dt > 0.0)
        {
            // Instantaneous UV velocity, EMA-smoothed (Mac: smoothedVelocity, alpha 0.20).
            var instVel = new Vector2((u - _lastPointerUV.X) / (float)dt, (v - _lastPointerUV.Y) / (float)dt);
            _pointerVelocityUV = Vector2.Lerp(_pointerVelocityUV, instVel, VelocitySmoothing);

            // Widen the influence radius with pointer speed, mirroring Mac's
            // radius = base + base*min(cap, velocity/k). speed here is in UV/sec.
            float speed = _pointerVelocityUV.Length();
            float velMul = Math.Min(1.0f, speed / 1.6f); // ~1.6 UV/sec saturates the growth
            _pointerRadius = DefaultPointerRadiusUV + (MaxPointerRadiusUV - DefaultPointerRadiusUV) * velMul;
        }

        _lastPointerUV = new Vector2(u, v);
        _pointerUV = new Vector2(u, v);
        _pointerInside = inside;
        _lastPointerSeconds = now;
    }

    private void OnHostPointerExited(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        // Pointer left the window -> let the disperse decay (handled in AdvancePointerState).
        _pointerInside = false;
    }

    // Maps the WeatherBackdrop Condition string to the shader's integer condition selector.
    // Matches the documented WeatherBackdrop conditions; unknown/empty falls back to Clear (0).
    private static int MapCondition(string? condition)
    {
        if (string.IsNullOrWhiteSpace(condition))
        {
            return 0;
        }

        return condition.Trim().ToLowerInvariant() switch
        {
            "clear" or "unknown" or "sunny" or "fair" => 0,
            "cloudy" or "clouds" or "overcast" or "partlycloudy" or "mostlycloudy" => 1,
            "rainy" or "rain" or "drizzle" or "showers" => 2,
            "stormy" or "storm" or "thunderstorm" or "thunder" => 3,
            "snowy" or "snow" or "sleet" or "blizzard" => 4,
            "foggy" or "fog" or "mist" => 5,
            "haze" or "hazy" or "smoke" or "dust" => 6,
            _ => 0,
        };
    }

    private void DisposeGraphicsPipeline()
    {
        _pipelineState?.Dispose();
        _pipelineState = null;

        _rootSignature?.Dispose();
        _rootSignature = null;

        _constantBuffer?.Dispose();
        _constantBuffer = null;

        _srvHeap?.Dispose();
        _srvHeap = null;
    }

    // -------------------------------------------------------------------------------------
    //  Render loop
    // -------------------------------------------------------------------------------------

    private void OnRendering(object? sender, object e)
    {
        if (!_ready || (!IsAnimationEnabled && !_frameRequested))
        {
            UpdateRenderLoop();
            return;
        }

        // Clear before drawing so a new invalidation raised during rendering is
        // retained. A paused background consumes one request and then unsubscribes.
        _frameRequested = false;
        try
        {
            RenderFrame();
        }
        catch (Exception ex)
        {
            WindowsRuntimeLog.Write(
                WindowsLogLevel.Error,
                "backdrop",
                $"render failed, stopping loop: {ex}");
            Teardown();
        }
        finally
        {
            UpdateRenderLoop();
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
        // Reset with the weather PSO as the initial pipeline state when it is live (matches the
        // upstream HelloDirect3D12 sample, which passes the PSO to Reset). SetPipelineState below
        // still re-binds it; passing it here just guarantees a valid initial state object.
        _commandList.Reset(allocator, _shaderReady ? _pipelineState : null);

        if (_shaderReady)
        {
            if (_rootSignature is null || _pipelineState is null || _constantBuffer is null || _glassSource is null || _srvHeap is null)
            {
                throw new InvalidOperationException("The weather shader is marked ready but part of its pipeline is missing.");
            }

            UpdateConstantBuffer();

            // Bindings shared by both passes, the glass-source table included (its range is
            // data-volatile, see CreateGraphicsPipeline).
            _commandList.SetGraphicsRootSignature(_rootSignature);
            _commandList.SetPipelineState(_pipelineState);
            _commandList.SetDescriptorHeaps(_srvHeap);
            _commandList.SetGraphicsRootDescriptorTable(1, _srvHeap.GetGPUDescriptorHandleForHeapStart());
            _commandList.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);

            RenderGlassSource();   // pass 0, before the back buffer is touched
        }

        // Present -> RenderTarget.
        _commandList.ResourceBarrierTransition(backBuffer, ResourceStates.Present, ResourceStates.RenderTarget);

        var rtv = new CpuDescriptorHandle(
            _rtvHeap.GetCPUDescriptorHandleForHeapStart(), (int)_backBufferIndex, _rtvDescriptorSize);

        _commandList.OMSetRenderTargets(rtv, null);

        // Clear stays as the backdrop base. When the shader pipeline is live it draws over a
        // black clear (so transparent/edge regions read as the composition background); the
        // animated hue clear is the fallback when the shader failed to initialize.
        Color4 clearColor = _shaderReady ? new Color4(0f, 0f, 0f, 1f) : ComputeAnimatedColor();
        _commandList.ClearRenderTargetView(rtv, clearColor);

        // Pass 1: fullscreen weather raymarch (SV_VertexID triangle, no vertex/index buffers); the
        // frost rects sample the pass-0 glass source through t0.
        if (_shaderReady)
        {
            _commandList.SetGraphicsRootConstantBufferView(0, _constantBuffer!.GPUVirtualAddress + ConstantSlotOffset(1));

            // Explicit full-surface viewport (MinDepth=0, MaxDepth=1 — the VS emits z=0, so a
            // MaxDepth of 0 would depth-clip the whole triangle) and scissor. Built from explicit
            // Viewport/RawRect values so the rasterizer always covers the entire back buffer and is
            // never left degenerate by an ambiguous helper overload.
            var viewport = new Viewport(0f, 0f, _width, _height, 0f, 1f);
            _commandList.RSSetViewport(viewport);

            var scissor = new RawRect(0, 0, (int)_width, (int)_height); // left, top, right, bottom
            _commandList.RSSetScissorRect(scissor);
            _commandList.DrawInstanced(3, 1, 0, 0);
        }

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
                WindowsRuntimeLog.Write(
                WindowsLogLevel.Error,
                "backdrop",
                $"device lost on Present (0x{present.Code:X8}); tearing down.");
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
        _queue.Signal(_fence, signal).CheckError();
        _frameFenceValues[_backBufferIndex] = signal;

        _backBufferIndex = _swapChain.CurrentBackBufferIndex;

        if (_fence.CompletedValue < _frameFenceValues[_backBufferIndex])
        {
            _fence.SetEventOnCompletion(_frameFenceValues[_backBufferIndex], _fenceEvent).CheckError();
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
        _queue.Signal(_fence, signal).CheckError();
        if (_fence.CompletedValue < signal)
        {
            _fence.SetEventOnCompletion(signal, _fenceEvent).CheckError();
            _fenceEvent.WaitOne();
        }
    }

    // -------------------------------------------------------------------------------------
    //  Resize / DPI
    // -------------------------------------------------------------------------------------

    private void TryResize(double dipWidth, double dipHeight)
    {
        if (!_ready || _swapChain is null)
        {
            return;
        }

        // Lazily hook the window-root pointer host if it wasn't available at Loaded time
        // (XamlRoot can be null on the very first Loaded in some hosting paths). Layout passes
        // run after XamlRoot is populated, so this is a reliable late retry. No-op once hooked.
        if (!_pointerHandlersHooked)
        {
            HookPointerHost();
        }

        ComputeBackBufferSize(dipWidth, dipHeight, out uint newWidth, out uint newHeight);
        if (newWidth == 0 || newHeight == 0)
        {
            return; // guard against zero size (collapsed / not measured)
        }

        if (newWidth == _width && newHeight == _height && !_initializedUnsized)
        {
            // Size unchanged — the scale may still have changed; refresh the transform.
            ApplyDpiTransform();
            return;
        }

        try
        {
            ResizeSwapChain(newWidth, newHeight);
            _initializedUnsized = false; // first real size has now been applied
        }
        catch (Exception ex)
        {
            WindowsRuntimeLog.Write(
                WindowsLogLevel.Error,
                "backdrop",
                $"resize failed, tearing down: {ex}");
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
        ReleaseGlassSource();

        _swapChain.ResizeBuffers(BufferCount, newWidth, newHeight, BackBufferFormat, SwapChainFlags.None);
        _width = newWidth;
        _height = newHeight;

        CreateRenderTargetViews();
        if (_shaderReady)
        {
            CreateGlassSource();
        }
        _backBufferIndex = _swapChain.CurrentBackBufferIndex;

        ApplyDpiTransform();
    }

    // Map the reduced-resolution back buffer onto the FULL panel DIP rect. The composition swap
    // chain's surface is (dipW * scaleX * RenderScale) physical pixels wide; it must end up
    // covering dipW DIP. The SwapChainPanel applies the inverse of this matrix in DIP space, so
    // the surface fills the panel when the X factor is 1/(scaleX * RenderScale) (and Y likewise):
    //   surfacePx * (1/(scaleX*RenderScale)) = dipW*scaleX*RenderScale / (scaleX*RenderScale) = dipW.
    // This single factor does BOTH jobs at once: it counters the composition DPI scale (the old
    // 1/scale) AND stretches the RenderScale-reduced buffer back up to full size. Scale-only
    // (SetMatrixTransform rejects skew/rotation), no translation.
    private void ApplyDpiTransform()
    {
        if (_swapChain2 is null)
        {
            return;
        }

        float sx = _scaleX <= 0f ? 1f : _scaleX;
        float sy = _scaleY <= 0f ? 1f : _scaleY;
        float fx = 1f / (sx * RenderScale);
        float fy = 1f / (sy * RenderScale);
        var transform = new Matrix3x2(fx, 0f, 0f, fy, 0f, 0f);
        // Vortice maps the DXGI Get/SetMatrixTransform pair to a property.
        _swapChain2.MatrixTransform = transform;
    }

    // Back-buffer pixel size = DIP size * composition scale * RenderScale, rounded, clamped to
    // >= 1 when the panel has a real size. The DIP size is read from an explicit argument so the
    // SizeChanged path can feed the authoritative SizeChangedEventArgs.NewSize (which is set
    // before ActualWidth/ActualHeight are guaranteed to reflect the new layout pass), and the
    // Loaded/scale paths fall back to the live ActualWidth/ActualHeight. The buffer aspect equals
    // (dipW*scaleX*RenderScale) / (dipH*scaleY*RenderScale) = the panel's physical aspect, so the
    // shader's `aspect = resolution.x/resolution.y` stays correct at any render scale.
    private void ComputeBackBufferSize(out uint width, out uint height)
    {
        ComputeBackBufferSize(Panel.ActualWidth, Panel.ActualHeight, out width, out height);
    }

    private void ComputeBackBufferSize(double dipWidth, double dipHeight, out uint width, out uint height)
    {
        _scaleX = Panel.CompositionScaleX <= 0f ? 1f : Panel.CompositionScaleX;
        _scaleY = Panel.CompositionScaleY <= 0f ? 1f : Panel.CompositionScaleY;

        // Physical pixels covering the FULL panel, then reduced by RenderScale. The composition
        // swap chain (Scaling.Stretch) + MatrixTransform stretches this smaller buffer back over
        // the full panel DIP rect (see ApplyDpiTransform).
        double w = dipWidth * _scaleX * RenderScale;
        double h = dipHeight * _scaleY * RenderScale;

        // Clamp to >= 1 so a valid (>0 DIP) panel never produces a 0-size buffer after the
        // RenderScale multiply rounds a thin sliver down; 0 only when the panel is truly unsized.
        width = w >= 0.5 ? (uint)Math.Max(1.0, w + 0.5) : 0u;
        height = h >= 0.5 ? (uint)Math.Max(1.0, h + 0.5) : 0u;
    }

    // -------------------------------------------------------------------------------------
    //  Teardown
    // -------------------------------------------------------------------------------------

    private void Teardown()
    {
        _ready = false;
        _shaderReady = false;
        _frameRequested = false;
        UpdateRenderLoop();

        // Detach the window-root pointer handlers (no-op if never hooked).
        UnhookPointerHost();

        // Flush the GPU before releasing anything it might still reference.
        try
        {
            WaitForGpuIdle();
        }
        catch (Exception ex)
        {
            WindowsRuntimeLog.Write(
                WindowsLogLevel.Error,
                "backdrop",
                $"GPU flush during teardown failed: {ex}");
        }

        _clock.Reset();

        ReleaseRenderTargetViews();
        ReleaseGlassSource();

        // Weather shader pipeline (root sig + PSO + constant buffer + SRV heap).
        DisposeGraphicsPipeline();

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

    // =====================================================================================
    //  HLSL — fullscreen weather shader (VS + PS), Shader Model 5.0, FXC vs_5_0 / ps_5_0.
    //
    //  VSMain: SV_VertexID fullscreen triangle (no input layout, no vertex buffer).
    //  PSMain: per-condition cinematic composite tuned to the macOS effects —
    //    0 Clear   : blue->gold sky gradient + sun glow + caustic light spots
    //    1 Cloudy  : raymarched volumetric clouds (lit fluffy edges), upper-left key light
    //    2 Rainy   : dark volumetric clouds + parallax rain streaks + bottom atmospheric fog
    //    3 Stormy  : rain x1.5 density / steeper slant + full-screen lightning flashes
    //    4 Snowy   : blue-grey winter sky + sun halo + parallax drifting snowflakes
    //    5 Foggy   : true raymarched Perlin-FBM height fog (octaves per quality)
    //    6 Haze    : shared aerosol scattering, filtered sun and depth-dependent terrain extinction
    //  Starfield (twinkling parallax stars over the night gradient) shows through on Clear-night.
    //  cbuffer WeatherCB at register(b0) mirrors WeatherConstants (time, resolution, condition,
    //  pointer state, renderPass, frost rects); t0/s0 carry the pass-0 glass source.
    // =====================================================================================
    private const string WeatherHlsl = @"
cbuffer WeatherCB : register(b0)
{
    float  time;             // row0: 0
    float2 resolution;       // row0: 4,8
    int    condition;        // row0: 12
    float2 pointerUV;        // row1: 16,20  pointer position in 0..1 panel UV
    float  pointerStrength;  // row1: 24     0..1 wave-to-disperse strength (decays after stop)
    float  pointerRadius;    // row1: 28     influence radius in UV (widens with pointer speed)
    float2 pointerVelocity;  // row2: 32,36  pointer velocity in UV/sec (trailing wake direction)
    int    renderPass;       // row2: 40     0 = scene into the glass source, 1 = final frame
    float  glassBlur;        // row2: 44     frost kernel radius as a fraction of the panel width
    float4 glassRect0;       // row3: 48     sidebar frost rect in screen uv (x, y, w, h); w <= 0 = off
    float4 glassRect1;       // row4: 64     top-bar frost rect
    float4 _glassPad;        // row5: 80     padding to match the C# struct (unused)
};

// ----- fullscreen triangle (SV_VertexID) -----
struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

VSOut VSMain(uint vid : SV_VertexID)
{
    VSOut o;
    // 3-vertex oversized triangle covering the screen.
    float2 uv = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2)
    o.uv  = uv;                                     // 0..2, clamps over the screen
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

// ============================ noise / hashing ============================
float hash11(float p)
{
    p = frac(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return frac(p);
}

float hash21(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float2 hash22(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.xx + p3.yz) * p3.zy);
}

float3 hash33(float3 p)
{
    p = frac(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return frac((p.xxy + p.yxx) * p.zyx);
}

// value noise (2D)
float vnoise2(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i + float2(0, 0));
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// value noise (3D) - used for the cloud / fog density field
float vnoise3(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float n = i.x + i.y * 57.0 + i.z * 113.0;
    float a = lerp(lerp(lerp(hash11(n +   0.0), hash11(n +   1.0), f.x),
                        lerp(hash11(n +  57.0), hash11(n +  58.0), f.x), f.y),
                   lerp(lerp(hash11(n + 113.0), hash11(n + 114.0), f.x),
                        lerp(hash11(n + 170.0), hash11(n + 171.0), f.x), f.y), f.z);
    return a;
}

static const float2x2 ROT = float2x2(0.80, 0.60, -0.60, 0.80);

// FBM over 3D value-noise; octaves chosen per quality (we use 6 - the macOS top tier).
float fbm3(float3 p, int octaves)
{
    float a = 0.5;
    float sum = 0.0;
    [loop]
    for (int i = 0; i < octaves; i++)
    {
        sum += a * vnoise3(p);
        p *= 2.02;                 // lacunarity ~2
        p.xy = mul(p.xy, ROT);     // rotate to break axis alignment
        a *= 0.5;                  // gain 0.5
    }
    return sum;
}

float fbm2(float2 p, int octaves)
{
    float a = 0.5;
    float sum = 0.0;
    [loop]
    for (int i = 0; i < octaves; i++)
    {
        sum += a * vnoise2(p);
        p = mul(p, ROT) * 2.02;
        a *= 0.5;
    }
    return sum;
}

// ============================ wave-to-disperse force field ============================
// Port of the macOS hover-disperse (InteractiveClearSystem / GlobalHaze): within pointerRadius
// of the pointer, push cloud sample positions radially AWAY from the pointer (so the cloud parts
// and reveals the dark starry sky behind) and report a thinning factor that reduces cloud density.
// ASCII ONLY (a non-ASCII char previously broke FXC). Cheap: a couple of distance calcs, no loops.
//
//   falloff = pow( saturate(1 - dist/radius), 2 ) * strength   (Mac uses squared falloff)
// The push is offset along pointerVelocity for a trailing wake, exactly like Mac feeding mouse
// velocity into the repel. `aspect` corrects the UV distance so the disperse region is circular.
//
// Returns: x = density multiplier in [1-strength .. 1] (1 = untouched, lower = thinned/parted),
//          yz = UV-space warp vector to add to the sampled screen position (push-away + wake).
float3 pointerDisperse(float2 uv, float aspect)
{
    if (pointerStrength <= 0.001) return float3(1.0, 0.0, 0.0);

    float2 toP = uv - pointerUV;
    float2 toPa = float2(toP.x * aspect, toP.y);     // aspect-correct so the region is round
    float dist = length(toPa);
    float radius = max(pointerRadius, 1e-4);

    float falloff = saturate(1.0 - dist / radius);
    falloff = falloff * falloff;                      // squared edge gradient (Mac parity)
    float fs = falloff * pointerStrength;

    // density multiplier: clouds thin/part toward the pointer center.
    float densMul = 1.0 - fs;

    // radial push AWAY from the pointer (normalize in plain UV so warp stays in UV units),
    // plus a trailing wake offset along the pointer velocity. Magnitude scaled by fs and radius
    // so a wider/stronger wave shoves the cloud further aside.
    float2 dir = (dist > 1e-4) ? (toP / max(length(toP), 1e-4)) : float2(0.0, 0.0);
    float2 warp = dir * fs * radius * 1.4;
    warp += pointerVelocity * fs * 0.05;             // wake trail in the direction of motion

    return float3(densMul, warp.x, warp.y);
}

// ============================ sky gradients (Mac params) ============================
float3 clearSky(float t)   // top(0)->bottom(1): deep blue -> light -> pale -> pale gold
{
    float3 c0 = float3(0.40, 0.60, 0.90);
    float3 c1 = float3(0.60, 0.80, 1.00);
    float3 c2 = float3(0.90, 0.95, 0.98);
    float3 c3 = float3(1.00, 0.98, 0.90);
    float3 a = lerp(c0, c1, smoothstep(0.0, 0.40, t));
    float3 b = lerp(c2, c3, smoothstep(0.65, 1.0, t));
    return lerp(a, b, smoothstep(0.40, 0.75, t));
}

float3 snowSky(float t)    // blue-grey -> near white
{
    float3 c0 = float3(0.75, 0.80, 0.88);
    float3 c1 = float3(0.82, 0.85, 0.90);
    float3 c2 = float3(0.88, 0.90, 0.93);
    float3 c3 = float3(0.92, 0.93, 0.95);
    float3 a = lerp(c0, c1, smoothstep(0.0, 0.4, t));
    float3 b = lerp(c2, c3, smoothstep(0.6, 1.0, t));
    return lerp(a, b, smoothstep(0.4, 0.8, t));
}

float3 stormSky(float t)   // dark storm cloud band over theme
{
    float3 c0 = float3(0.12, 0.12, 0.18);
    float3 c1 = float3(0.18, 0.18, 0.24);
    float3 c2 = float3(0.25, 0.25, 0.32);
    return lerp(lerp(c0, c1, smoothstep(0.0, 0.5, t)), c2, smoothstep(0.5, 1.0, t));
}

float3 nightSky(float t)   // starry base background
{
    float3 c0 = float3(0.01, 0.01, 0.08);
    float3 c1 = float3(0.03, 0.03, 0.15);
    float3 c2 = float3(0.08, 0.06, 0.25);
    float3 c3 = float3(0.12, 0.10, 0.30);
    float3 a = lerp(c0, c1, smoothstep(0.0, 0.4, t));
    float3 b = lerp(c2, c3, smoothstep(0.6, 1.0, t));
    return lerp(a, b, smoothstep(0.4, 0.8, t));
}

// ============================ twinkling parallax stars ============================
// 3 layers (far/mid/near) of point stars with per-star twinkle + horizontal drift.
float3 starLayer(float2 uv, float density, float driftSpeed, float twinkleSpeed,
                 float baseSize, float3 tint, float layerOpacity)
{
    float3 acc = 0.0;
    float2 p = uv;
    p.x += time * driftSpeed * 0.02;       // horizontal wrap drift
    float2 g = p * density;
    float2 cell = floor(g);
    float2 f = frac(g);
    [unroll]
    for (int oy = -1; oy <= 1; oy++)
    [unroll]
    for (int ox = -1; ox <= 1; ox++)
    {
        float2 o = float2(ox, oy);
        float2 rnd = hash22(cell + o);
        if (rnd.x < 0.55) continue;        // sparse population
        float2 d = f - (o + rnd);
        float dist = length(d);
        float phase = rnd.y * 6.2831853;
        float indiv = twinkleSpeed * (0.5 + rnd.x);
        float bright = 0.5 + 0.5 * sin(time * indiv + phase);
        float sizeJ = lerp(0.7, 1.3, rnd.x);
        float r = baseSize * sizeJ * 0.012;
        float star = smoothstep(r, 0.0, dist) * bright;
        acc += tint * star;
    }
    return acc * layerOpacity;
}

float3 starfield(float2 uv)
{
    float3 c = 0.0;
    c += starLayer(uv, 28.0, 0.3, 0.8, 0.8, float3(0.70, 0.80, 1.00), 0.6);  // far blue
    c += starLayer(uv, 14.0, 0.8, 1.5, 1.5, float3(1.00, 1.00, 1.00), 0.8);  // mid white
    c += starLayer(uv,  7.0, 1.2, 2.5, 2.8, float3(1.00, 1.00, 1.00), 1.0);  // near white
    return c;
}

// ============================ raymarched volumetric clouds ============================
// Genuine raymarch: 40 view steps through a cloud slab, 6-step light march toward the
// upper-left sun, Beer-Lambert extinction + energy-conserving in-scatter. Lit fluffy edges.
static const float SLAB_LO = 1.2;   // cloud altitude band, low
static const float SLAB_HI = 3.0;   // cloud altitude band, high

float cloudDensity(float3 p, float coverage)
{
    p.x += time * 0.20;             // scroll
    float base = fbm3(p * 0.55, 5);
    // height falloff to keep clouds inside the slab band
    float h = (p.y - SLAB_LO) / (SLAB_HI - SLAB_LO);
    float shape = smoothstep(0.0, 0.25, h) * smoothstep(1.0, 0.55, h);
    float d = base * shape;
    // Discrete clumps: only the densest fbm peaks survive. The threshold is raised
    // (1.0 - coverage*0.85) and the remap sharpened (x2.6) so the dark starry sky shows
    // clearly between clumps instead of a continuous overcast sheet.
    // The remap used to be x2.6, which drove almost every sample that cleared the threshold
    // straight to 1.0 - a binary field, so clumps had hard edges and no interior gradient.
    // x1.1 keeps a real density ramp, which is what gives clouds a soft edge and lets the
    // march build up structure instead of hitting a wall.
    d = saturate((d - (1.0 - coverage * 0.85)) * 1.1);
    return d;
}

// march toward the sun to estimate shadowing -> lit silver edges
float cloudLight(float3 p, float3 sunDir, float coverage)
{
    float t = 0.0;
    float dens = 0.0;
    [unroll]
    for (int i = 0; i < 6; i++)
    {
        float3 sp = p + sunDir * t;
        dens += cloudDensity(sp, coverage) * 0.16;
        t += 0.18;
    }
    return exp(-dens * 3.0);        // Beer-Lambert transmittance toward the light
}

// returns rgb premultiplied scene contribution + alpha in .a
float4 raymarchClouds(float3 ro, float3 rd, float coverage, float3 skyTint, float3 sunCol)
{
    // upper-left key light (matches Mac (0.28w,0.12h) light source)
    float3 sunDir = normalize(float3(-0.55, 0.65, 0.25));
    // Horizon falloff: near-horizontal rays (small rd.y) graze a very long path through the
    // slab and pile up density into an opaque white wall across the lower/horizon band. Weight
    // density by the ray's upward angle so the horizon region reads as mostly-clear dark sky and
    // clouds concentrate in the UPPER (steeper-ray) portion of the view. Below the cutoff the
    // contribution is zero -> no white horizon wall.
    float horizonWeight = smoothstep(0.10, 0.42, rd.y);   // 0 at/below horizon, 1 looking up
    if (rd.y <= 0.001 || horizonWeight <= 0.0) return float4(0,0,0,0);
    // intersect the view ray with the slab to bound the march
    float tEnter = (SLAB_LO - ro.y) / max(rd.y, 0.001);
    float tExit  = (SLAB_HI - ro.y) / max(rd.y, 0.001);
    tEnter = max(tEnter, 0.0);
    if (tExit <= tEnter) return float4(0,0,0,0);
    // Cap the march length so grazing rays can't accumulate an unbounded slab traversal.
    float maxMarch = 9.0;
    tExit = min(tExit, tEnter + maxMarch);

    float steps = 40.0;
    float dt = (tExit - tEnter) / steps;
    float jitter = hash21(rd.xy * resolution + time) * dt;   // blue-noise-ish dejitter
    float t = tEnter + jitter;

    float transmittance = 1.0;
    float3 scattered = 0.0;
    [loop]
    for (int i = 0; i < 40; i++)
    {
        if (transmittance < 0.02) break;   // early-out
        float3 p = ro + rd * t;
        float d = cloudDensity(p, coverage);
        // distance extinction: far samples thin out so distant clouds don't stack into a wall
        d *= exp(-(t - tEnter) * 0.12) * horizonWeight;
        if (d > 0.001)
        {
            float lit = cloudLight(p, sunDir, coverage);
            // Cloud body shading, NIGHT-lit. These used to be daylight-cumulus values
            // (0.55..0.92 grey rising to a warm sunlit white); multiplied by the warm sunCol
            // they produced the flat cream sheet that had no business appearing over a
            // nightSky whose brightest stop is 0.30. Clouds on a starry sky are dark forms
            // that catch a thin cool rim, so the body sits below the sky's own luminance and
            // only the lit edge lifts above it.
            float3 baseCol = float3(0.05, 0.05, 0.10);          // shadowed body, darker than the sky
            float3 litCol  = float3(0.34, 0.36, 0.46);          // cool rim where the key light grazes
            float3 col = lerp(baseCol, litCol, lit);
            col = lerp(col, col * sunCol, 0.12);                // was 0.35 - a hint of warmth, not a wash
            float3 amb = skyTint * 0.5;
            col += amb * (1.0 - lit) * 0.4;
            // Energy-conserving in-scatter. The extinction constant was 6.0, which with
            // dt <= 0.225 gave alpha ~0.74 PER SAMPLE: two or three dense samples saturated
            // the ray, so nothing behind the first cloud face was ever visible and the whole
            // band collapsed into one opaque wall. 1.6 lets the 40 steps actually integrate.
            float dens = d * dt * 1.6;
            float a = 1.0 - exp(-dens);
            scattered += transmittance * a * col;
            transmittance *= 1.0 - a;
        }
        t += dt;
    }
    float alpha = 1.0 - transmittance;
    return float4(scattered, alpha);
}

// BEGIN RAIN OPTICS
float rainHash(float2 p) {
    float3 q = frac(float3(p.x, p.y, p.x) * 0.1031);
    q += dot(q, q.yzx + float3(33.33, 33.33, 33.33));
    return frac((q.x + q.y) * q.z);
}

float rainNoise(float2 p) {
    float2 cell = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(rainHash(cell), rainHash(cell + float2(1.0, 0.0)), f.x),
               lerp(rainHash(cell + float2(0.0, 1.0)), rainHash(cell + float2(1.0, 1.0)), f.x), f.y);
}

float rainCloudField(float2 p) {
    float value = rainNoise(p) * 0.56;
    value += rainNoise(p * 2.03 + float2(7.1, 2.7)) * 0.28;
    value += rainNoise(p * 4.11 + float2(13.7, 9.2)) * 0.16;
    return value;
}

float3 rainToLinear(float3 c) {
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(0.04045, c));
}

float3 rainToDisplay(float3 c) {
    c = max(c, float3(0.0, 0.0, 0.0));
    return lerp(c * 12.92, 1.055 * pow(c, float3(0.4166667, 0.4166667, 0.4166667)) - 0.055,
               step(0.0031308, c));
}

float3 rainSky(float2 p, float t, float storm) {
    float horizon = smoothstep(-0.32, 0.38, p.y);
    float cloud = rainCloudField(float2(p.x * 2.0 + t * 0.007, p.y * 2.8 - t * 0.004));
    float veil = rainNoise(p * float2(0.8, 3.1) + float2(t * 0.004, 1.7));
    float light = exp(-pow((p.x - 0.24) * 2.6, 2.0) - pow((p.y + 0.10) * 3.2, 2.0));
    float3 color = lerp(rainToLinear(float3(0.12, 0.17, 0.20)),
                       rainToLinear(float3(0.29, 0.34, 0.35)), horizon);
    color *= lerp(0.48, 1.12, smoothstep(0.18, 0.80, cloud));
    color += rainToLinear(float3(0.28, 0.29, 0.27)) * light * veil * 0.55;
    return color * lerp(1.0, 0.68, storm);
}

float rainStreak(float2 p, float t, float2 gridSize, float speed, float slant,
                 float shutter, float width, float pixel, float seed) {
    float2 velocity = float2(slant, speed);
    // Align the cell columns with the velocity, so a long exposure never clips
    // against a vertical cell boundary. Time only advects the falling axis.
    float2 grid = float2(p.x - p.y * slant / speed, p.y - speed * t) * gridSize +
                  float2(seed, seed * 0.37);
    // Independent column phases remove synchronized rows while retaining terminal velocity.
    grid.y += rainHash(float2(floor(grid.x), seed + 83.1)) * 17.0;
    float2 cell = floor(grid);
    float choice = rainHash(cell + float2(seed, 4.7));
    float2 center = float2(0.24 + rainHash(cell) * 0.52,
                          0.42 + rainHash(cell + float2(9.2, 7.6)) * 0.48);
    float2 offset = (frac(grid) - center) / gridSize;
    offset.x += offset.y * slant / speed;
    float2 direction = normalize(velocity);
    float along = dot(offset, direction);
    float across = abs(dot(offset, float2(direction.y, -direction.x)));
    float streakLength = length(velocity) * shutter * lerp(0.72, 1.25, choice);
    float radius = width * lerp(0.65, 1.2, choice);
    // Prefilter a subpixel filament instead of switching a hard edge on and off.
    // Preserve its integrated brightness as the footprint crosses pixel centers.
    float sigma = max(pixel, width * 2.0);
    float body = exp(-0.5 * across * across / (sigma * sigma)) * radius / sigma;
    float tail = smoothstep(-streakLength, -streakLength * 0.10, along);
    float head = 1.0 - smoothstep(-pixel, pixel, along);
    float exposure = lerp(0.35, 1.0, choice) * step(0.18, choice);
    return body * tail * head * exposure;
}

float2 rainWaterWaves(float2 p, float t) {
    float2 cell = floor(p);
    float2 f = frac(p);
    float waves = 0.0;
    float impacts = 0.0;
    for (int y = -1; y <= 1; y += 1) {
        for (int x = -1; x <= 1; x += 1) {
            float2 neighbor = float2(float(x), float(y));
            float seed = rainHash(cell + neighbor);
            float age = frac(t * 0.65 + seed * 11.3);
            float2 center = neighbor + float2(0.2 + seed * 0.6,
                0.2 + rainHash(cell + neighbor + float2(9.4, 3.2)) * 0.6);
            float distance = length(f - center);
            float envelope = smoothstep(0.0, 0.05, age) * (1.0 - smoothstep(0.65, 1.0, age));
            float ringDistance = distance - age * 0.95;
            waves += cos(ringDistance * 48.0) * exp(-abs(ringDistance) * 24.0) * envelope * exp(-age * 2.2);
            impacts += exp(-distance * distance * 850.0) * (1.0 - smoothstep(0.0, 0.12, age));
        }
    }
    return float2(waves, impacts);
}

float4 cinematicRain(float2 uv, float2 viewport, float time, float intensity,
                      float wind, float quality, float storm, float allowFlash,
                      float disperse, float2 flowOffset) {
    float aspect = viewport.x / max(viewport.y, 1.0);
    float2 p = (uv - 0.5) * float2(aspect, 1.0);
    float pixel = 1.0 / max(viewport.y, 1.0);
    float3 color = rainSky(p, time, storm);
    float fog = exp(-pow((p.y - 0.20) * 5.2, 2.0));
    color = lerp(color, rainToLinear(float3(0.26, 0.30, 0.31)), fog * intensity * 0.22);

    float water = smoothstep(0.75, 0.79, uv.y);
    if (water > 0.0) {
        float depth = max(uv.y - 0.71, 0.03);
        float2 plane = float2(p.x / depth * 2.8, 1.6 / depth);
        float2 waves = rainWaterWaves(plane, time);
        float shimmer = rainNoise(plane * 1.8 + float2(time * 0.17, time * 0.06));
        float2 reflection = float2(p.x + waves.x * 0.004,
                                   0.24 - (uv.y - 0.77) * 1.7 + shimmer * 0.009);
        float3 reflected = rainSky(reflection, time, storm);
        float fresnel = lerp(0.72, 0.30, smoothstep(0.77, 1.0, uv.y));
        float3 waterColor = lerp(rainToLinear(float3(0.035, 0.060, 0.075)), reflected, fresnel);
        waterColor += rainToLinear(float3(0.31, 0.36, 0.38)) *
                      (max(waves.x, 0.0) * 0.30 + waves.y * 0.60) * intensity;
        color = lerp(color, waterColor, water);
    }

    float slant = 0.11 + wind * 0.32 + sin(time * 0.11) * 0.012;
    slant *= lerp(1.0, 1.45, storm);
    float2 rainPosition = p + flowOffset * float2(aspect, 1.0);
    float streaks = rainStreak(rainPosition, time, float2(110.0, 13.0), 0.48, slant * 0.45,
                               0.035, pixel * 0.20, pixel * 0.70, 7.0) * 0.15;
    streaks += rainStreak(rainPosition, time, float2(64.0, 8.0), 0.87, slant * 0.72,
                          0.035, pixel * 0.27, pixel * 0.70, 19.0) * 0.29;
    streaks += rainStreak(rainPosition, time, float2(31.0, 4.0), 1.38, slant,
                          0.045, pixel * 0.36, pixel * 0.75, 31.0) * 0.42;
    if (quality > 0.65) {
        streaks += rainStreak(rainPosition, time, float2(15.0, 2.0), 1.91, slant * 1.30,
                              0.045, pixel * 0.48, pixel * 1.10, 47.0) * 0.18;
    }
    streaks *= intensity * lerp(0.80, 1.30, storm) * disperse;
    color += rainToLinear(float3(0.67, 0.72, 0.76)) * streaks;
    float flashPhase = frac(time / 13.0);
    float flash = exp(-pow((flashPhase - 0.72) * 220.0, 2.0)) +
                  exp(-pow((flashPhase - 0.728) * 330.0, 2.0)) * 0.45;
    color += rainToLinear(float3(0.20, 0.23, 0.26)) * flash * storm * allowFlash;
    float vignette = 1.0 - smoothstep(0.35, 1.15, length(p * float2(0.60, 0.85))) * 0.24;
    color *= vignette;
    return float4(clamp(rainToDisplay(color), 0.0, 1.0), 1.0);
}

float4 rainBead(float2 offset, float radius, float elongation) {
    float2 q = offset / float2(radius, radius * elongation);
    float d = length(q);
    float coverage = 1.0 - smoothstep(0.84, 1.08, d);
    float rim = exp(-pow((d - 0.83) * 10.0, 2.0));
    float highlight = exp(-dot(q + float2(0.30, 0.36), q + float2(0.30, 0.36)) * 20.0);
    float caustic = exp(-pow(q.x * 2.5, 2.0) - pow((q.y - 0.55) * 7.0, 2.0));
    float3 color = lerp(float3(0.11, 0.16, 0.18), float3(0.90, 0.95, 0.96),
                       clamp(highlight + caustic * 0.55 + rim * 0.28, 0.0, 1.0));
    return float4(color, coverage * min(0.24 + rim * 0.40 + highlight * 0.65, 1.0));
}

float4 rainWetGlass(float2 uv, float2 viewport, float time, float4 region,
                    float cornerRadius, float intensity) {
    if (region.z <= 0.0 || region.w <= 0.0) return float4(0.0, 0.0, 0.0, 0.0);
    float2 local = (uv - region.xy) * viewport;
    float2 extent = region.zw * viewport;
    float radiusScale = max(viewport.y / 900.0, 0.40);
    float margin = 14.0 * radiusScale;
    if (local.x < -margin || local.y < -margin || local.x > extent.x + margin || local.y > extent.y + margin) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    float seed = rainHash(region.xy * 127.0 + region.zw * 53.0);
    float corner = cornerRadius * viewport.y;
    float4 result = float4(0.0, 0.0, 0.0, 0.0);
    if (local.x > corner && local.x < extent.x - corner && abs(local.y) < margin) {
        float spacing = 43.0 * radiusScale;
        float cell = floor(local.x / spacing);
        float variation = rainHash(float2(cell, seed * 71.0));
        float age = frac(time * 0.019 + variation);
        float radius = (1.4 + age * 2.8) * radiusScale;
        float2 center = float2((cell + 0.2 + variation * 0.6) * spacing, radius * 0.25);
        result = rainBead(local - center, radius, 1.10 + age * 0.40);
        result.w *= smoothstep(0.0, 0.06, age) * (1.0 - smoothstep(0.92, 1.0, age));
    }
    float edge = local.x < extent.x * 0.5 ? 0.0 : extent.x;
    if (abs(local.x - edge) < margin && local.y > corner && local.y < extent.y - corner) {
        float spacing = 82.0 * radiusScale;
        float cell = floor(local.y / spacing);
        float variation = rainHash(float2(cell + edge * 0.13, seed * 97.0));
        float age = frac(time * (0.022 + variation * 0.016) + variation * 7.0);
        float radius = (2.0 + variation * 2.2) * radiusScale;
        float2 center = float2(edge + (edge == 0.0 ? -0.25 : 0.25) * radius,
                               (cell + 0.12 + age * 0.73) * spacing);
        float4 bead = rainBead(local - center, radius, 1.35 + age * 0.95);
        bead.w *= smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(0.87, 1.0, age));
        if (bead.w > result.w) result = bead;
    }
    // Water gathers under the lower lip, stretches, then detaches under gravity.
    if (local.x > corner && local.x < extent.x - corner && abs(local.y - extent.y) < margin) {
        float spacing = 97.0 * radiusScale;
        float cell = floor(local.x / spacing);
        float variation = rainHash(float2(cell + 17.0, seed * 63.0));
        float age = frac(time * 0.028 + variation * 5.0);
        float radius = (1.5 + sqrt(age) * 2.1) * radiusScale;
        float falling = max(age - 0.80, 0.0);
        float2 center = float2((cell + 0.2 + variation * 0.6) * spacing,
                               extent.y + radius * 0.25 + falling * falling * 220.0 * radiusScale);
        float4 bead = rainBead(local - center, radius, 1.15 + age * 0.85);
        bead.w *= smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(0.88, 1.0, age));
        if (bead.w > result.w) result = bead;
    }
    result.w *= intensity;
    return result;
}

float4 rainApplyWetGlass(float4 background, float4 wet) {
    return float4(rainToDisplay(lerp(rainToLinear(background.rgb), rainToLinear(wet.rgb), wet.w)), background.w);
}
// END RAIN OPTICS

// ============================ parallax snow ============================
float snowLayer(float2 uv, float scale, float fall, float sway, float size, float seed,
                out float glow)
{
    float2 p = uv * scale;
    p.x += sin(time * 2.0 + p.y * 3.0 + seed) * sway;     // sway
    p.x += sin(time * 0.3) * 0.5;                          // wind
    p.y += time * fall;
    float2 cell = floor(p);
    float2 f = frac(p);
    float2 rnd = hash22(cell + seed);
    glow = 0.0;
    if (rnd.x < 0.78) return 0.0;                         // sparse flakes (raised 0.45->0.78: far fewer)
    float2 c = rnd - 0.5;
    float d = length(f - 0.5 - c * 0.6);
    float flake = smoothstep(size, 0.0, d);
    glow = smoothstep(size * 2.0, 0.0, d) * 0.10;         // tighter, dimmer halo (2.5->2.0, 0.25->0.10)
    return flake;
}

float3 snowComposite(float2 uv)
{
    float g0, g1, g2;
    // BACKDROP snow: small drifting flakes over the dark cold sky -- the far layer is no longer a
    // huge out-of-focus bokeh wall (size 0.45->0.10), all layers are smaller, sparser (threshold in
    // snowLayer) and dimmer so the UI stays readable. Sizes are in cell units (smaller = tinier flake).
    float far  = snowLayer(uv, 18.0, 0.10, 0.010, 0.10, 3.0, g0) * 0.22;
    float mid  = snowLayer(uv, 12.0, 0.16, 0.018, 0.12, 9.0, g1) * 0.35;
    float near = snowLayer(uv,  7.0, 0.22, 0.026, 0.14, 19.0, g2) * 0.5;
    float s = saturate(far + mid + near);
    float glow = (g0 + g1 + g2);
    float3 col = (float3(0.9, 0.93, 0.98) * s + float3(0.85, 0.9, 1.0) * glow) * 0.6;  // opacity/glow cut
    return col;
}

// ============================ scatterable wisp / mote particles ============================
// A faint, drifting layer of soft white cloud 'wisps' that the pointer SCATTERS apart, ported
// in feel from the macOS InteractiveWeatherParticleSystem: discrete cloud motes (Mac type 2:
// ~1000 particles, size 3..6, color (0.8,0.8,0.8,0.4), slow random drift) that get pushed away
// from the cursor (Mac repelForce 50 over influenceRadius 100, dispersionRadius 150) and then
// drift back as the repel relaxes (Mac velocity damping 0.95..0.98 -> smooth recover). Here it is
// procedural: one wisp per grid cell (hash22), O(9) per pixel like snowLayer/rainLayer -- NO global
// N-particle loop. At rest the layer is very faint (reads as a haze sparkle within the cloud), and
// each wisp's REST position is displaced AWAY from the pointer (squared falloff * pointerStrength,
// + a wake along pointerVelocity) so a wave scatters the motes apart, revealing the dark starry sky;
// as pointerStrength decays the displacement shrinks and the wisps FLOW BACK to their drift spots.
// ASCII ONLY (a non-ASCII char previously broke FXC).
//
//   scale     : grid frequency (bigger -> smaller, denser cells)
//   drift     : vertical drift speed (slow upward-ish flow of the cloud field)
//   sway      : per-cell horizontal sway amplitude (gives the layer life at rest)
//   size      : wisp soft-sprite radius (in cell units)
//   seed      : layer decorrelation seed
//   aspect    : x/y aspect so scatter displacement and sprites stay round
//   out streak: 0..1 elongation hint along the scatter direction (motion blur feel)
float wispLayer(float2 uv, float scale, float drift, float sway, float size, float seed,
                float aspect, out float streak)
{
    streak = 0.0;
    // Slow global scroll of the whole wisp field (the cloud drifts even at rest).
    float2 p = uv;
    p.x += time * 0.012 + sin(time * 0.05 + seed) * 0.01;   // gentle horizontal flow + breathing
    p.y -= time * drift;                                     // slow vertical drift
    p *= scale;
    float2 cell = floor(p);
    float2 f = frac(p);

    float acc = 0.0;
    [unroll]
    for (int oy = -1; oy <= 1; oy++)
    [unroll]
    for (int ox = -1; ox <= 1; ox++)
    {
        float2 o = float2(ox, oy);
        float2 rnd = hash22(cell + o + seed);
        if (rnd.x < 0.42) continue;                         // sparse population (faint haze)

        // Rest position of this wisp inside its cell (jittered) + a small per-cell sway so the
        // layer is alive even with no pointer (Mac cloud motes have a small random base velocity).
        float2 jitter = (rnd - 0.5) * 0.7;
        float swayPhase = rnd.y * 6.2831853 + seed;
        jitter.x += sin(time * 0.6 + swayPhase) * sway;
        jitter.y += cos(time * 0.5 + swayPhase) * sway * 0.7;
        float2 wispCell = o + 0.5 + jitter;                 // wisp center in this cell's frac space

        // World-UV position of this wisp center (undo the grid scale) so we can scatter it against
        // the pointer in the SAME UV space the pointer lives in.
        float2 wispUV = (cell + wispCell) / scale;
        wispUV.x -= time * 0.012 + sin(time * 0.05 + seed) * 0.01;  // remove the scroll for UV match
        wispUV.y += time * drift;

        // ---- pointer scatter: push the wisp AWAY from the cursor (squared falloff, Mac parity) ----
        float2 toW = wispUV - pointerUV;
        float2 toWa = float2(toW.x * aspect, toW.y);
        float dist = length(toWa);
        float radius = max(pointerRadius, 1e-4);
        float falloff = saturate(1.0 - dist / radius);
        falloff = falloff * falloff;                        // squared edge gradient (Mac)
        float fs = falloff * pointerStrength;               // shrinks to 0 as strength decays -> flow back
        float2 dir = (dist > 1e-4) ? (toW / max(length(toW), 1e-4)) : float2(0.0, 0.0);
        // displacement = normalize(away) * falloff * strength * scatterAmount  (Mac dispersionRadius feel)
        float2 scatter = dir * fs * radius * 1.8;
        scatter += pointerVelocity * fs * 0.06;             // wake along pointer motion (Mac velocity repel)

        // Apply the scatter in grid (frac) space (scale UV displacement back into cell units).
        wispCell += scatter * scale;
        streak = max(streak, fs);                           // hint: elongate harder when shoved

        // Soft sprite: smoothstep distance to the (possibly scattered) wisp center. When scattered,
        // squash along the scatter direction so it reads as a streaking mote (liveliness).
        float2 d = f - wispCell;
        float2 sdir = (fs > 1e-3) ? normalize(scatter + 1e-5) : float2(0.0, 1.0);
        float along = dot(d, sdir);
        float perp  = dot(d, float2(-sdir.y, sdir.x));
        // elongate along the scatter dir (stretch) by up to ~1.7x at full shove
        float stretch = 1.0 + fs * 1.7;
        float dd = length(float2(along / stretch, perp));
        float bright = lerp(0.6, 1.0, rnd.y);               // per-wisp brightness variation
        acc += smoothstep(size, 0.0, dd) * bright;
    }
    return acc;
}

// Composite the wisp layers into an additive white glow. `cloudPresence` (the local cloud alpha,
// or a coarse fbm) modulates opacity so the motes concentrate where there ARE clouds -- you scatter
// the CLOUD, not sparkle the clear sky. `baseOpacity` keeps it faint at rest (UI readable); the
// scatter streak adds a touch more glow where the pointer is actively shoving wisps apart.
float3 wispComposite(float2 uv, float aspect, float cloudPresence, float baseOpacity)
{
    float s0, s1, s2;
    // two-to-three layers (far faint motes, mid, near larger wisps) -- sizes/speeds echo Mac motes.
    float far  = wispLayer(uv, 16.0, 0.010, 0.010, 0.42, 5.0,  aspect, s0) * 0.45;
    float mid  = wispLayer(uv, 10.0, 0.016, 0.016, 0.34, 13.0, aspect, s1) * 0.70;
    float near = wispLayer(uv,  6.0, 0.022, 0.022, 0.28, 27.0, aspect, s2) * 0.90;
    float m = far + mid + near;
    float streak = max(max(s0, s1), s2);

    // Concentrate where clouds exist; keep faint at rest so the UI stays readable. The active-scatter
    // streak brightens the motes a little so a wave reads as the cloud breaking into drifting wisps.
    float opacity = baseOpacity * saturate(0.35 + cloudPresence) * (1.0 + streak * 0.8);
    float3 col = float3(0.92, 0.95, 1.0) * saturate(m) * opacity;
    return col;
}

// ============================ raymarched height fog (Perlin FBM) ============================
// True ray-march: step through the volume, accumulate FBM density, depth-fade + scatter.
float3 fogComposite(float2 uv, float intensity, out float fogAlpha)
{
    float3 ro = float3(0.0, 0.0, 0.0);
    float3 rd = normalize(float3((uv - 0.5) * float2(resolution.x / resolution.y, 1.0), 1.0));
    float stepSize = 200.0 / 64.0;                         // 64 steps, march length 200
    float t = 0.0;
    float density = 0.0;
    [loop]
    for (int i = 0; i < 64; i++)
    {
        float3 pos = ro + rd * t * stepSize;
        float3 sp = pos * 0.01 + float3(time * 0.5, 0.0, 0.0);
        float d = fbm3(sp, 6);
        float depthFade = exp(-t * 0.02);
        density += saturate(d - 0.35) * 0.06 * depthFade;
        t += 1.0;
    }
    density *= intensity;
    fogAlpha = saturate(density);
    // bright neutral grey/white fog with a soft light-scatter glow
    float3 fogCol = float3(0.82, 0.84, 0.86);
    float scatter = saturate(density * 1.2);
    fogCol += float3(0.05, 0.05, 0.06) * scatter;
    return fogCol;
}

// BEGIN AEROSOL FIELD
float hazeHash(float3 p) {
    p = frac(p * 0.1031);
    float hashOffset = dot(p, p.zyx + float3(31.32, 31.32, 31.32));
    p += float3(hashOffset, hashOffset, hashOffset);
    return frac((p.x + p.y) * p.z);
}

float hazeNoise(float3 p) {
    float3 cell = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float nearPlane = lerp(
        lerp(hazeHash(cell), hazeHash(cell + float3(1.0, 0.0, 0.0)), f.x),
        lerp(hazeHash(cell + float3(0.0, 1.0, 0.0)), hazeHash(cell + float3(1.0, 1.0, 0.0)), f.x), f.y);
    float farPlane = lerp(
        lerp(hazeHash(cell + float3(0.0, 0.0, 1.0)), hazeHash(cell + float3(1.0, 0.0, 1.0)), f.x),
        lerp(hazeHash(cell + float3(0.0, 1.0, 1.0)), hazeHash(cell + float3(1.0, 1.0, 1.0)), f.x), f.y);
    return lerp(nearPlane, farPlane, f.z);
}

float3 hazeToLinear(float3 color) {
    return lerp(color / 12.92, pow((color + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(float3(0.04045, 0.04045, 0.04045), color));
}

float3 hazeToDisplay(float3 color) {
    color = max(color, float3(0.0, 0.0, 0.0));
    return lerp(color * 12.92, 1.055 * pow(color, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(float3(0.0031308, 0.0031308, 0.0031308), color));
}

float3 hazeViewRay(float2 uv, float2 viewport) {
    return normalize(float3((uv.x - 0.5) * viewport.x / viewport.y, 0.61 - uv.y, 1.5));
}

float hazeTerrainHeight(float x, float seed) {
    float broad = hazeNoise(float3(x * 0.46, seed, 0.7));
    float detail = hazeNoise(float3(x * 1.31, seed + 8.3, 0.2));
    float ridge = abs(hazeNoise(float3(x * 3.7, seed + 21.4, 1.3)) - 0.5);
    return broad * 0.62 + detail * 0.26 + ridge * 0.24;
}

float4 cinematicHaze(float2 uv, float2 viewport, float time, float intensity, float wind,
                     float quality, float3 tint, float grainAmount, float2 flowOffset) {
    float amount = clamp(intensity, 0.0, 1.0);
    float3 ray = hazeViewRay(uv, viewport);
    float3 sunDirection = normalize(float3(0.10, 0.41, 1.5));
    float alignment = max(dot(ray, sunDirection), 0.0);
    float halo = exp((alignment - 1.0) * 46.0);
    float sunDisc = smoothstep(0.999975, 0.999991, alignment);

    // Dense aerosols mute blue light first. The distant sun shares the scattering direction.
    float3 warmLight = hazeToLinear(lerp(float3(0.93, 0.84, 0.69), tint, 0.22));
    float3 upperSky = hazeToLinear(float3(0.25, 0.32, 0.38));
    float3 horizon = hazeToLinear(lerp(float3(0.60, 0.57, 0.50), tint, 0.25));
    float3 sky = lerp(upperSky, horizon, smoothstep(0.03, 0.64, uv.y));
    sky += warmLight * (halo * 0.23 + sunDisc * 1.4);

    // Quiet distant terrain gives the aerosol a measurable depth reference. Each ridge
    // terminates the same atmosphere ray at its actual distance; no screen-space fog blobs.
    float rayLength = 18.0;
    for (int ridgeIndex = 0; ridgeIndex < 3; ridgeIndex += 1) {
        float ridge = float(ridgeIndex);
        float planeDepth = 16.0 - ridge * 5.0;
        float hitDistance = planeDepth / ray.z;
        float x = ray.x * hitDistance;
        float height = hazeTerrainHeight(x, 4.7 + ridge * 13.3) * (2.1 - ridge * 0.38) - ridge * 0.40;
        float y = 1.1 + ray.y * hitDistance;
        float coverage = 1.0 - smoothstep(-0.025, 0.025, y - height);
        float3 terrain = hazeToLinear(lerp(float3(0.20, 0.27, 0.31), float3(0.085, 0.13, 0.17), ridge * 0.5));
        float surfaceDetail = hazeNoise(float3(x * 3.8, y * 5.1, 9.0 + ridge));
        terrain *= lerp(0.76, 1.15, surfaceDetail);
        sky = lerp(sky, terrain, coverage);
        rayLength = lerp(rayLength, hitDistance, coverage);
    }

    float3 transmittance = float3(1.0, 1.0, 1.0);
    float3 scatteredLight = float3(0.0, 0.0, 0.0);
    float g = 0.68;
    float phase = (1.0 - g * g) / (12.5663706 * pow(1.0 + g * g - 2.0 * g * alignment, 1.5));
    float3 drift = float3(time * (0.018 + clamp(wind, 0.0, 1.0) * 0.038), 0.0, time * 0.009);
    drift += float3(flowOffset.x * 4.0, -flowOffset.y * 4.0, 0.0);
    float stepLength = rayLength / (quality > 0.65 ? 24.0 : 12.0);
    for (int stepIndex = 0; stepIndex < 24; stepIndex += 1) {
        if (quality <= 0.65 && stepIndex >= 12) break;
        float distance = (float(stepIndex) + 0.5) * stepLength;
        float3 position = float3(0.0, 1.1, 0.0) + ray * distance;
        float field = hazeNoise(position * float3(0.38, 0.55, 0.31) + drift);
        float layer = exp(-max(position.y - 0.2, 0.0) * 0.36);
        float density = lerp(0.045, 0.24, amount) * layer * lerp(0.62, 1.38, field);
        float3 extinction = density * float3(0.78, 0.95, 1.22);
        float3 segment = exp(-extinction * stepLength);
        float3 lightPosition = position + sunDirection * max((7.0 - position.y) / sunDirection.y, 0.0);
        float lightVeil = hazeNoise(lightPosition * float3(0.30, 0.19, 0.30) + drift * 0.42);
        float sunVisibility = exp(-density * (2.5 + distance * 0.22) - smoothstep(0.32, 0.76, lightVeil) * 2.0);
        float3 ambient = hazeToLinear(float3(0.37, 0.40, 0.43));
        float3 lighting = ambient * 0.42 + warmLight * phase * sunVisibility * 2.0;
        scatteredLight += transmittance * (float3(1.0, 1.0, 1.0) - segment) * lighting;
        transmittance *= segment;
    }

    float3 color = sky * transmittance + scatteredLight;
    // A quiet foreground preserves the existing dashboard's light text and controls.
    color = lerp(color, hazeToLinear(float3(0.065, 0.085, 0.12)), smoothstep(0.57, 1.0, uv.y) * 0.91);
    float2 edge = float2((uv.x - 0.5) * viewport.x / viewport.y, uv.y - 0.46);
    color *= 1.0 - 0.10 * smoothstep(0.2, 0.95, length(edge));
    float grain = (hazeNoise(float3(uv * viewport * 0.52, time * 0.4)) - 0.5) * 0.003;
    float grainOffset = grain * grainAmount * quality;
    color = hazeToDisplay(color) + float3(grainOffset, grainOffset, grainOffset);
    return float4(clamp(color, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), 1.0);
}
// END AEROSOL FIELD

// ============================ pixel shader ============================
// ============================ frosted glass (shell chrome) ============================
// Pass 0 renders the scene into a 1/8-resolution texture (sRGB-encoded, no vignette); pass 1
// samples it here with a two-ring disc kernel and tones it like the Mac's dark ultraThinMaterial:
// mostly the blurred sky, slightly desaturated and dimmed, a thin white film, a touch of grain.
Texture2D<float4> glassSource : register(t0);
SamplerState glassSampler : register(s0);

static const float GLASS_DIM = 0.90;          // dims the blurred sky (smoked; keeps white text readable)
static const float GLASS_FILM = 0.035;        // linear white film: the milky lift of frosted glass
static const float GLASS_DESATURATE = 0.15;   // glass scatters some of the sky's colour away
static const float GLASS_GRAIN = 0.012;       // fine grain (added after the encode) so flat areas do not band

float glassCoverage(float2 uv)
{
    float inside = 0.0;
    if (glassRect0.z > 0.0 && all(uv >= glassRect0.xy) && all(uv < glassRect0.xy + glassRect0.zw)) inside = 1.0;
    if (glassRect1.z > 0.0 && all(uv >= glassRect1.xy) && all(uv < glassRect1.xy + glassRect1.zw)) inside = 1.0;
    return inside;
}

float3 glassSample(float2 uv)
{
    // the glass source is sRGB-encoded (UNORM target); blur in linear light
    return pow(saturate(glassSource.SampleLevel(glassSampler, uv, 0).rgb), 2.2);
}

float3 frostedGlass(float2 uv)
{
    static const float2 taps[12] = {
        float2( 0.50,  0.00), float2(-0.50,  0.00), float2( 0.00,  0.50), float2( 0.00, -0.50),
        float2( 0.70,  0.70), float2(-0.70,  0.70), float2( 0.70, -0.70), float2(-0.70, -0.70),
        float2( 0.38,  0.92), float2(-0.92,  0.38), float2(-0.38, -0.92), float2( 0.92, -0.38)
    };
    // the radius is a fraction of the width; the y radius is scaled by the aspect so the disc is round
    float2 radius = glassBlur * float2(1.0, resolution.x / max(resolution.y, 1.0));
    float3 acc = glassSample(uv) * 2.0;
    [unroll]
    for (int i = 0; i < 12; i++)
    {
        acc += glassSample(uv + taps[i] * radius);
    }
    float3 g = acc / 14.0;
    float lum = dot(g, float3(0.2126, 0.7152, 0.0722));
    g = lerp(g, lum.xxx, GLASS_DESATURATE);
    return g * GLASS_DIM + GLASS_FILM;
}

// The finish shared by the scene and the frost paths of pass 1: sRGB encode for the UNORM target,
// a very light vignette, and the frost grain (uniform in back-buffer pixels, frost pixels only).
float4 finishFrame(float3 col, float2 uv, float frost)
{
    col = pow(saturate(col), 1.0 / 2.2);
    float2 vd = uv - 0.5;
    float vig = smoothstep(1.05, 0.45, length(vd) * 1.25);
    col *= lerp(0.92, 1.0, vig);
    col += (hash21(uv * resolution) - 0.5) * GLASS_GRAIN * frost;
    return float4(col, 1.0);
}

// Wet edges are composed after the frost kernel, preserving sharp droplets without
// another render target. Geometry comes from the actual sidebar and top bar bounds.
float3 wetGlassColor(float3 color, float2 uv)
{
    if (condition != 2 && condition != 3) return color;
    float density = pointerDisperse(uv, resolution.x / resolution.y).x;
    float4 wet0 = rainWetGlass(uv, resolution, time, glassRect0, 0.0, density * 0.68);
    float4 wet1 = rainWetGlass(uv, resolution, time, glassRect1, 0.0, density * 0.68);
    color = lerp(color, pow(saturate(wet0.rgb), 2.2), wet0.w);
    return lerp(color, pow(saturate(wet1.rgb), 2.2), wet1.w);
}

float4 PSMain(VSOut input) : SV_TARGET
{
    float2 uv = saturate(input.uv);     // 0..1 screen uv (top-left origin)

    // Pass 1 pixels under the shell chrome show the frost and never the scene, so the raymarch
    // below is skipped for them (about a quarter of the frame at the default layout).
    [branch]
    if (renderPass != 0 && glassCoverage(uv) > 0.5)
    {
        return finishFrame(wetGlassColor(frostedGlass(uv), uv), uv, 1.0);
    }
    float ty = uv.y;                    // vertical gradient param
    float aspect = resolution.x / max(resolution.y, 1.0);

    // wave-to-disperse: density multiplier (.x) + UV warp (.yz). dispUV is the screen position
    // shifted AWAY from the pointer, so the cloud/precip sampled at this pixel is pushed aside and
    // the dark starry sky behind shows through where you wave; densMul thins what remains.
    float3 disp = pointerDisperse(uv, aspect);
    float densMul = disp.x;
    float2 dispUV = uv + disp.yz;

    // view ray for the cloud raymarch (camera pitched up slightly; vertical squash). Built from
    // the WARPED uv so clouds visibly part around the pointer.
    float3 ro = float3(0.0, 0.0, 0.0);
    float3 rd = normalize(float3((dispUV.x - 0.5) * aspect, (0.62 - dispUV.y) * 0.9 + 0.18, 1.0));

    float3 col;

    if (condition == 0)                 // ---- Clear ----
    {
        col = lerp(nightSky(ty), clearSky(ty), 0.55);   // translucent blue veil over the dark starry theme (Mac parity)
        // sun glow upper-left + caustic light spots
        float2 sun = float2(0.28, 0.18);
        float sd = length((uv - sun) * float2(aspect, 1.0));
        col += float3(1.0, 0.95, 0.8) * smoothstep(0.45, 0.0, sd) * 0.5;
        float caustic = fbm2(uv * 6.0 + time * 0.1, 4);
        col += float3(1.0, 0.98, 0.9) * smoothstep(0.6, 0.95, caustic) * 0.12;
        // a faint hint of stars high in a clear sky on the dark top
        col += starfield(uv) * smoothstep(0.5, 0.0, ty) * 0.15;
    }
    else if (condition == 1)            // ---- Cloudy ----
    {
        float3 baseSky = nightSky(ty);                  // dark starry theme shows through (Mac cloudy lays no grey sky)
        baseSky += starfield(uv) * smoothstep(0.55, 0.0, ty) * 0.5;
        float coverage = 0.55;                          // lower so the dark starry sky shows between cloud clumps (Mac)
        float4 clouds = raymarchClouds(ro, rd, coverage, baseSky, float3(1.0, 0.97, 0.9));
        col = lerp(baseSky, clouds.rgb, clouds.a * densMul);  // wave thins the cloud -> starry sky shows
        // scatterable wisp motes ON TOP of the cloud field: faint at rest, scatter apart on a wave
        // (revealing the starry sky) then drift back -- the discrete-particle liveliness from Mac.
        col += wispComposite(uv, aspect, clouds.a, 0.45);
    }
    else if (condition == 2 || condition == 3) // ---- Rain / storm ----
    {
        float storm = condition == 3 ? 1.0 : 0.0;
        float3 rain = cinematicRain(uv, resolution, time, lerp(0.68, 0.95, storm),
                                     0.25, 1.0, storm, 1.0, densMul, disp.yz).rgb;
        float3 baseSky = nightSky(ty) + starfield(uv) * 0.25;
        col = lerp(baseSky, pow(saturate(rain), 2.2), densMul);
    }
    else if (condition == 4)            // ---- Snowy ----
    {
        col = lerp(nightSky(ty), float3(0.20, 0.24, 0.34), 0.4);  // dim cold base so white flakes pop (Mac parity)
        col += starfield(uv) * smoothstep(0.55, 0.0, ty) * 0.4;
        // soft moon/halo glow at (0.3w, 0.15h)
        float2 halo = float2(0.3, 0.15);
        float hd = length((uv - halo) * float2(aspect, 1.0));
        col += float3(0.8, 0.85, 0.95) * smoothstep(0.35, 0.0, hd) * 0.18;
        col += snowComposite(dispUV) * densMul;             // snow parts + thins under the wave
        // cold color grade
        col = lerp(col, col * float3(0.85, 0.90, 1.0), 0.15);
        // keep the lower/card region DARK so UI text stays readable (snow has no grey wall, just darken)
        col = lerp(col, float3(0.10, 0.12, 0.18), smoothstep(0.74, 1.0, ty) * 0.22);
    }
    else if (condition == 5)            // ---- Foggy ----
    {
        float3 baseSky = lerp(float3(0.55, 0.57, 0.6), float3(0.78, 0.80, 0.82), ty);
        float fogAlpha;
        float3 fog = fogComposite(uv, 0.6, fogAlpha);
        col = lerp(baseSky, fog, saturate(fogAlpha * 1.4) * densMul);  // wave clears the fog (Mac haze parity)
    }
    else                                // ---- Haze (6) ----
    {
        float3 baseSky = nightSky(ty);
        baseSky += starfield(uv) * smoothstep(0.55, 0.0, ty) * 0.35;
        float3 haze = cinematicHaze(uv, resolution, time, 0.68, 0.25, 1.0,
                                    float3(0.78, 0.72, 0.58), 1.0, dispUV - uv).rgb;
        // The shared field returns sRGB display values. Decode with the exact inverse
        // of the existing frame finish so the shell's frost and presentation stay intact.
        col = lerp(baseSky, pow(saturate(haze), 2.2), densMul);
    }

    // ---- night starfield base shows through on the clear night theme (low-light scenes) ----
    // (already added to Clear; leave others as-is so the weather reads clearly)

    // ---- glass source pass: the scene as the frost will see it, encoded for the UNORM glass
    //      texture, no vignette (the final pass applies it once, over the frost as well). ----
    [branch]
    if (renderPass == 0)
    {
        return float4(pow(saturate(col), 1.0 / 2.2), 1.0);
    }

    // ---- finish: gamma + gentle vignette (NO Reinhard - the scene is already LDR 0..1, so
    //      Reinhard would just crush every sky color to ~half brightness). ----
    return finishFrame(wetGlassColor(col, uv), uv, 0.0);
}
";
}
