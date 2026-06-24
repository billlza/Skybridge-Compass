using System;
using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
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
    private ID3D12RootSignature? _rootSignature;     // one root CBV at b0 (no descriptor heap)
    private ID3D12PipelineState? _pipelineState;      // VS+PS fullscreen-triangle PSO
    private ID3D12Resource? _constantBuffer;          // Upload heap, 256-byte CB, mapped per-frame
    private bool _shaderReady;                        // true once PSO/root-sig/CB are valid

    // CPU-side mirror of the HLSL cbuffer. Layout MUST match `cbuffer WeatherCB` in WeatherHlsl
    // EXACTLY (HLSL packs into 16-byte rows; a field never straddles a 16-byte boundary). Row map:
    //   row 0 (off 0):  float  time(0)  + float2 resolution(4,8) + int condition(12)
    //   row 1 (off 16): float2 pointerUV(16,20) + float pointerStrength(24) + float pointerRadius(28)
    //   row 2 (off 32): float2 pointerVelocity(32,36) + 8 bytes pad to fill the row
    // 40 bytes used; CB stays padded to 256 (well within the D3D12 256-byte CBV requirement).
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
        public float Pad0;             // offset 40  (pad to keep the row aligned; unused)
        public float Pad1;             // offset 44  (pad; unused)
    }

    private const uint ConstantBufferSize = 256; // 256-byte aligned (D3D12 CBV requirement)

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
        _lastFrameSeconds = 0.0;

        // Subscribe to window-root pointer events for the wave-to-disperse interaction. Safe to
        // call once XamlRoot is available (Loaded guarantees we are in the live visual tree).
        HookPointerHost();

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
        // Use the event's NewSize: it is the authoritative just-laid-out DIP size, whereas
        // Panel.ActualWidth/Height can still report the PREVIOUS layout pass when this handler
        // runs (the root cause of the swap chain getting stuck at an early, too-small size and
        // only covering part of the content area).
        TryResize(e.NewSize.Width, e.NewSize.Height);
    }

    private void OnCompositionScaleChanged(SwapChainPanel sender, object args)
    {
        // No size in the args; the live ActualWidth/Height are valid by the time a scale change
        // is delivered, so let TryResize read them.
        TryResize(Panel.ActualWidth, Panel.ActualHeight);
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
            Debug.WriteLine($"[WeatherBackdropDX] debug-layer enable failed (continuing without validation): {ex.Message}");
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

        // 8. Compile the weather shader and build the size-independent graphics pipeline
        //    (root signature + PSO + constant buffer). Failure here is non-fatal: the panel
        //    falls back to the animated clear color rather than crashing.
        try
        {
            CreateGraphicsPipeline();
            _shaderReady = true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WeatherBackdropDX] shader pipeline init failed, using clear-color fallback: {ex}");
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

    private void CreateGraphicsPipeline()
    {
        if (_device is null)
        {
            return;
        }

        // 1. Compile VS + PS from the embedded HLSL (FXC, Shader Model 5.0).
        //    Overload: (source, ShaderMacro[] defines, Include include, entryPoint, sourceName,
        //    profile, ShaderFlags, out Blob, out Blob errorBlob). defines/include are null.
        Compiler.Compile(
            WeatherHlsl, null, null, "VSMain", "WeatherBackdrop.hlsl", "vs_5_0",
            ShaderFlags.None, out Blob vsBlob, out Blob vsError).CheckError();
        vsError?.Dispose();

        Compiler.Compile(
            WeatherHlsl, null, null, "PSMain", "WeatherBackdrop.hlsl", "ps_5_0",
            ShaderFlags.None, out Blob psBlob, out Blob psError).CheckError();
        psError?.Dispose();

        using (vsBlob)
        using (psBlob)
        {
            // 2. Root signature: ONE root CBV at b0, visible to all stages. No descriptor heap.
            var cbvDescriptor = new RootDescriptor1(0, 0);
            var rootParam = new RootParameter1(
                RootParameterType.ConstantBufferView, cbvDescriptor, ShaderVisibility.All);
            var rsDesc = new RootSignatureDescription1(
                RootSignatureFlags.None, new[] { rootParam });
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

        // 4. Upload-heap constant buffer (256-byte aligned). Mapped per-frame via the safe
        //    Span<T> overload in UpdateConstantBuffer; no persistent map / no unsafe field.
        _constantBuffer = _device.CreateCommittedResource(
            HeapType.Upload,
            ResourceDescription.Buffer(ConstantBufferSize),
            ResourceStates.GenericRead);
    }

    // Per-frame: write { time, resolution, condition } into the upload CB. Safe Span<T> map.
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
        };

        Span<WeatherConstants> cb = _constantBuffer.Map<WeatherConstants>(0, 1);
        cb[0] = data;
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
        // Reset with the weather PSO as the initial pipeline state when it is live (matches the
        // upstream HelloDirect3D12 sample, which passes the PSO to Reset). SetPipelineState below
        // still re-binds it; passing it here just guarantees a valid initial state object.
        _commandList.Reset(allocator, _shaderReady ? _pipelineState : null);

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

        // Fullscreen weather raymarch pass (SV_VertexID triangle, no vertex/index buffers).
        if (_shaderReady && _rootSignature is not null && _pipelineState is not null && _constantBuffer is not null)
        {
            UpdateConstantBuffer();

            _commandList.SetGraphicsRootSignature(_rootSignature);
            _commandList.SetPipelineState(_pipelineState);
            _commandList.SetGraphicsRootConstantBufferView(0, _constantBuffer.GPUVirtualAddress);

            // Explicit full-surface viewport (MinDepth=0, MaxDepth=1 — the VS emits z=0, so a
            // MaxDepth of 0 would depth-clip the whole triangle) and scissor. Built from explicit
            // Viewport/RawRect values so the rasterizer always covers the entire back buffer and is
            // never left degenerate by an ambiguous helper overload.
            var viewport = new Viewport(0f, 0f, _width, _height, 0f, 1f);
            _commandList.RSSetViewport(viewport);

            var scissor = new RawRect(0, 0, (int)_width, (int)_height); // left, top, right, bottom
            _commandList.RSSetScissorRect(scissor);

            _commandList.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
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

        // Detach the window-root pointer handlers (no-op if never hooked).
        UnhookPointerHost();

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

        // Weather shader pipeline (root sig + PSO + constant buffer).
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
    //    6 Haze    : warm yellow-grey particulate haze layers reducing contrast
    //  Starfield (twinkling parallax stars over the night gradient) shows through on Clear-night.
    //  cbuffer matches { float time; float2 resolution; int condition; } at register(b0).
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
    float2 _pointerPad;      // row2: 40,44  padding to match the C# struct (unused)
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
    d = saturate((d - (1.0 - coverage * 0.85)) * 2.6);   // coverage threshold + sharper remap
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
            // cloud body shading: dark base -> bright lit edges
            float3 baseCol = float3(0.55, 0.58, 0.64);          // bottom shadow
            float3 litCol  = float3(0.92, 0.94, 0.98);          // sunlit top
            float3 col = lerp(baseCol, litCol, lit);
            col = lerp(col, col * sunCol, 0.35);
            float3 amb = skyTint * 0.5;
            col += amb * (1.0 - lit) * 0.4;
            // energy-conserving in-scatter integration
            float dens = d * dt * 6.0;
            float a = 1.0 - exp(-dens);
            scattered += transmittance * a * col;
            transmittance *= 1.0 - a;
        }
        t += dt;
    }
    float alpha = 1.0 - transmittance;
    return float4(scattered, alpha);
}

// ============================ parallax rain ============================
// 3 depth layers of streaks. `intensity` scales density, `slant` tilts (Stormy).
float rainLayer(float2 uv, float scale, float speed, float slant, float thickness, float seed)
{
    float2 p = uv;
    p.x += p.y * slant;                                   // tilt the whole field
    p.x += sin(time * 0.3) * 0.04 * slant;                // wind oscillation
    p *= scale;
    p.y += time * speed;
    float2 cell = floor(p);
    float2 f = frac(p);
    float r = hash21(cell + seed);
    if (r < 0.5) return 0.0;                              // sparse columns
    float colJ = hash21(cell.yx + seed) - 0.5;
    float xline = smoothstep(thickness, 0.0, abs(f.x - 0.5 + colJ * 0.3));
    // vertical streak with a brighter head on the top 30%
    float streak = smoothstep(0.0, 0.15, f.y) * smoothstep(1.0, 0.4, f.y);
    return xline * streak;
}

float3 rainComposite(float2 uv, float density, float slant)
{
    // streak color gradient white->cyan->blue->white-ish (Mac advanced streak)
    float far  = rainLayer(uv, float2(80.0, 26.0) * density, 0.9 + density, slant * 0.6, 0.10, 11.0) * 0.6;
    float mid  = rainLayer(uv, float2(60.0, 22.0) * density, 1.2 + density, slant * 0.8, 0.12, 23.0) * 0.65;
    float near = rainLayer(uv, float2(40.0, 18.0) * density, 1.6 + density, slant,       0.16, 37.0) * 0.8;
    float s = saturate(far + mid + near);
    float3 streakCol = lerp(float3(0.7, 0.9, 1.0), float3(1.0, 1.0, 1.0), near);
    return streakCol * s;
}

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
    if (rnd.x < 0.45) return 0.0;
    float2 c = rnd - 0.5;
    float d = length(f - 0.5 - c * 0.6);
    float flake = smoothstep(size, 0.0, d);
    glow = smoothstep(size * 2.5, 0.0, d) * 0.25;
    return flake;
}

float3 snowComposite(float2 uv)
{
    float g0, g1, g2;
    // far bokeh (soft, small), mid, near (large crystals) - sizes/speeds per Mac tables
    float far  = snowLayer(uv, 18.0, 0.10, 0.010, 0.45, 3.0, g0) * 0.4;
    float mid  = snowLayer(uv, 12.0, 0.16, 0.018, 0.32, 9.0, g1) * 0.7;
    float near = snowLayer(uv,  7.0, 0.22, 0.026, 0.26, 19.0, g2) * 0.95;
    float s = saturate(far + mid + near);
    float glow = (g0 + g1 + g2);
    float3 col = float3(1.0, 1.0, 1.0) * s + float3(0.9, 0.95, 1.0) * glow;
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

// ============================ pixel shader ============================
float4 PSMain(VSOut input) : SV_TARGET
{
    float2 uv = saturate(input.uv);     // 0..1 screen uv (top-left origin)
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
    }
    else if (condition == 2)            // ---- Rainy ----
    {
        col = stormSky(ty);
        float coverage = 0.85;
        float4 clouds = raymarchClouds(ro, rd, coverage, float3(0.2, 0.2, 0.26), float3(0.6, 0.6, 0.7));
        col = lerp(col, clouds.rgb * 0.5, clouds.a * densMul);
        col += rainComposite(dispUV, 1.0, 0.18) * densMul;   // rain parts + thins under the wave
        // bottom atmospheric fog
        col = lerp(col, float3(0.5, 0.5, 0.55), smoothstep(0.7, 1.0, ty) * 0.25);
    }
    else if (condition == 3)            // ---- Stormy ----
    {
        col = stormSky(ty) * 0.85;
        float coverage = 0.92;
        float4 clouds = raymarchClouds(ro, rd, coverage, float3(0.15, 0.15, 0.2), float3(0.5, 0.5, 0.6));
        col = lerp(col, clouds.rgb * 0.4, clouds.a * densMul);
        col += rainComposite(dispUV, 1.5, 0.4) * densMul;    // x1.5 density, steeper slant; parts under the wave
        col = lerp(col, float3(0.45, 0.45, 0.5), smoothstep(0.65, 1.0, ty) * 0.3);
        // lightning: randomized flash, full-screen white
        float flashSeed = floor(time / 8.0);
        float flashT = frac(time / 8.0);
        float trigger = step(0.85, hash11(flashSeed));     // ~15% of windows fire
        float flash = trigger * exp(-flashT * 14.0) * (0.6 + 0.4 * hash11(flashSeed + 7.0));
        col += (float3(1.0, 1.0, 1.0) * 0.6 + float3(0.5, 0.8, 1.0) * 0.4) * flash * 0.8; // white core + cyan glow (Mac)
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
        float3 baseSky = lerp(float3(0.62, 0.60, 0.52), float3(0.80, 0.76, 0.66), ty);
        // 3 drifting warm yellow-grey particulate layers reducing contrast
        float h0 = fbm2(uv * 3.0 + float2(time * 0.02, 0.0), 4);
        float h1 = fbm2(uv * 5.0 - float2(time * 0.015, 0.0), 4);
        float h2 = fbm2(uv * 8.0 + float2(time * 0.01, time * 0.005), 3);
        float haze = saturate(h0 * 0.5 + h1 * 0.3 + h2 * 0.2);
        float3 hazeCol = float3(0.80, 0.74, 0.62);          // warm-grey particulate
        col = lerp(baseSky, hazeCol, haze * 0.55 * densMul); // wave disperses the haze (Mac parity)
        col = lerp(col, float3(0.78, 0.75, 0.68), 0.15);    // contrast reduction
    }

    // ---- night starfield base shows through on the clear night theme (low-light scenes) ----
    // (already added to Clear; leave others as-is so the weather reads clearly)

    // ---- finish: gamma + gentle vignette (NO Reinhard - the scene is already LDR 0..1, so
    //      Reinhard would just crush every sky color to ~half brightness). ----
    col = pow(saturate(col), 1.0 / 2.2);                    // sRGB encode for the UNORM target
    float2 vd = uv - 0.5;
    float vig = smoothstep(1.05, 0.45, length(vd) * 1.25);
    col *= lerp(0.92, 1.0, vig);                            // very light vignette

    return float4(col, 1.0);
}
";
}
