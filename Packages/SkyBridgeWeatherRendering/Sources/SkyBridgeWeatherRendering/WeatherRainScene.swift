import SwiftUI
import MetalKit

/// A dashboard-local connection between rain behind the UI and water on its glass.
/// The foreground has no display link: the background submits both surfaces together.
@MainActor
public final class WeatherRainScene {
    private weak var owner: AnyObject?
    private weak var surface: RainGlassSurface?
    private var device: (any MTLDevice)?
    private var requestFrame: (() -> Void)?

    public init() {}

    func bind(owner: AnyObject, device: any MTLDevice, requestFrame: @escaping () -> Void) {
        self.owner = owner
        self.device = device
        self.requestFrame = requestFrame
        configureSurface()
    }

    func unbind(owner: AnyObject) {
        guard self.owner === owner else { return }
        self.owner = nil
        device = nil
        requestFrame = nil
        configureSurface()
    }

    fileprivate func attach(_ surface: RainGlassSurface) {
        self.surface = surface
        configureSurface()
        requestFrame?()
    }

    fileprivate func detach(_ surface: RainGlassSurface) {
        guard self.surface === surface else { return }
        self.surface = nil
    }

    fileprivate func surfaceDidChange() { requestFrame?() }

    private func configureSurface() {
        // Hiding is immediate; clearing the layer's device could invalidate a presentation
        // already queued on the GPU. The layer releases its pool with its owning view.
        if let device, surface?.metalLayer.device?.registryID != device.registryID { surface?.metalLayer.device = device }
        surface?.metalLayer.isHidden = owner == nil
    }

    func hasPresentationTarget(owner: AnyObject) -> Bool {
        self.owner === owner && surface?.window != nil && surface?.metalLayer.isHidden == false &&
            (surface?.bounds.width ?? 0) > 0 && (surface?.bounds.height ?? 0) > 0
    }

    func nextDrawable(owner: AnyObject) -> (any CAMetalDrawable)? {
        guard hasPresentationTarget(owner: owner), let surface else {
            return nil // A detached or inactive foreground has no presentation target.
        }
        return surface.metalLayer.nextDrawable()
    }
}

/// Place once above the dashboard's glass components, with the same bounds as its rain background.
public struct WeatherRainGlassOverlay: View {
    private let scene: WeatherRainScene
    public init(scene: WeatherRainScene) { self.scene = scene }
    public var body: some View {
        RainGlassNativeView(scene: scene).allowsHitTesting(false).accessibilityHidden(true)
    }
}

#if os(macOS)
private typealias RainGlassPlatformView = NSView
#else
private typealias RainGlassPlatformView = UIView
#endif

@MainActor
private final class RainGlassSurface: RainGlassPlatformView {
    let metalLayer = CAMetalLayer()
    weak var scene: WeatherRainScene?

    init(scene: WeatherRainScene) {
        self.scene = scene
        super.init(frame: .zero)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.isHidden = true
        #if os(macOS)
        wantsLayer = true
        layer = metalLayer
        #else
        isOpaque = false
        isUserInteractionEnabled = false
        layer.addSublayer(metalLayer)
        #endif
        scene.attach(self)
    }

    required init?(coder: NSCoder) { fatalError("Rain glass surfaces are created programmatically") }

    private func updateDrawableSize() {
        #if os(macOS)
        let scale = window?.backingScaleFactor ?? 1
        #else
        let scale = contentScaleFactor
        metalLayer.frame = bounds
        #endif
        metalLayer.contentsScale = scale
        let pixels = CGSize(width: max(1, (bounds.width * scale).rounded()),
                            height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.drawableSize != pixels {
            metalLayer.drawableSize = pixels
            scene?.surfaceDidChange()
        }
    }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); updateDrawableSize() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        scene?.surfaceDidChange()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); updateDrawableSize() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
        scene?.surfaceDidChange()
    }
    #endif
}

#if os(macOS)
private struct RainGlassNativeView: NSViewRepresentable {
    let scene: WeatherRainScene
    func makeNSView(context: Context) -> RainGlassSurface { RainGlassSurface(scene: scene) }
    func updateNSView(_ view: RainGlassSurface, context: Context) {
        if view.scene !== scene { view.scene?.detach(view); view.scene = scene; scene.attach(view) }
    }
    static func dismantleNSView(_ view: RainGlassSurface, coordinator: ()) { view.scene?.detach(view) }
}
#else
private struct RainGlassNativeView: UIViewRepresentable {
    let scene: WeatherRainScene
    func makeUIView(context: Context) -> RainGlassSurface { RainGlassSurface(scene: scene) }
    func updateUIView(_ view: RainGlassSurface, context: Context) {
        if view.scene !== scene { view.scene?.detach(view); view.scene = scene; scene.attach(view) }
    }
    static func dismantleUIView(_ view: RainGlassSurface, coordinator: ()) { view.scene?.detach(view) }
}
#endif
