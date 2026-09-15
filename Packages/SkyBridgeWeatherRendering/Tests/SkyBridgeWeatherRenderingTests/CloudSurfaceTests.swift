import SwiftUI
import MetalKit
import Testing
@testable import SkyBridgeWeatherRendering

@Suite(.serialized)
@MainActor
struct CloudSurfaceTests {
    @Test(arguments: AtmosphereKind.allCases)
    func updatingPausedSurfaceDoesNotDrawInsideTheUpdateCallback(kind: AtmosphereKind) throws {
        let renderer = try AtmosphereRenderer(kind: kind)
        let settings = AtmosphereNativeView(renderer: renderer, intensity: 0.68, wind: 0.25, quality: 1,
                                       framesPerSecond: 30, isAnimating: false, onFailure: { Issue.record("\($0)") })
        let coordinator = settings.makeCoordinator()
        let view = DrawTrackingMetalView(frame: CGRect(x: 0, y: 0, width: 480, height: 780), device: renderer.device)
        coordinator.update(settings, view: view)
        #expect(view.drawCalls == 0, "A view update must schedule a frame instead of synchronously entering MetalKit drawing")
        #expect(view.isPaused)
        #expect(!view.enableSetNeedsDisplay)
    }

    @Test(arguments: AtmosphereKind.allCases)
    func nativeSurfaceLoadsWhenPausedAndTracksWindowSize(kind: AtmosphereKind) async throws {
        let rainScene = WeatherRainScene()
        let root = AtmosphereView(kind: kind, isAnimating: false, rainScene: kind == .rain ? rainScene : nil)
            .overlay { if kind == .rain { WeatherRainGlassOverlay(scene: rainScene) } }
        #if os(macOS)
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 480, height: 780),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        #else
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let host = try #require(controller.view)
        defer { window.isHidden = true; window.rootViewController = nil }
        #endif

        // Wait for the real asynchronous resource load, then require a native Metal surface.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (findSurface(in: host) == nil || findSurface(in: host)?.isPaused == false) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let surface = try #require(findSurface(in: host))
        #expect(surface.window != nil)
        #expect(surface.isPaused)
        #expect(surface.bounds.width > 0 && surface.bounds.height > 0)
        #expect(surface.drawableSize.width > 0 && surface.drawableSize.height > 0)
        #expect(min(surface.drawableSize.width, surface.drawableSize.height) <= (kind == .rain ? 900 : 600))
        #expect(max(surface.drawableSize.width, surface.drawableSize.height) <= (kind == .rain ? 1950 : 1300))
        #expect(abs(surface.drawableSize.width / surface.drawableSize.height - surface.bounds.width / surface.bounds.height) < 0.01)
        #expect(surface.colorPixelFormat == .bgra8Unorm)
        let metalLayer = try #require(surface.layer as? CAMetalLayer)
        #expect(metalLayer.colorspace?.name == CGColorSpace.sRGB)
        #expect(surface.delegate != nil)
        let coordinator = try #require(surface.delegate as? AtmosphereNativeView.Coordinator)
        let observer = SurfaceFrameObserver(coordinator: coordinator)
        surface.delegate = observer
        let original = coordinator.settings
        let changed = AtmosphereNativeView(renderer: original.renderer, intensity: 0.5, wind: original.wind,
                                      quality: original.quality, framesPerSecond: original.framesPerSecond,
                                      isAnimating: false, onFailure: { Issue.record("\($0)") }, rainScene: original.rainScene)
        coordinator.update(changed, view: surface)
        #expect(!surface.isPaused, "A static settings change must request one new frame")
        try await requireSubmittedStaticFrame(surface)
        let frame = try #require(observer.lastFrame)
        #expect(frame.width == Int(surface.drawableSize.width))
        #expect(frame.height == Int(surface.drawableSize.height))
        #expect(frame.pixelFormat == .bgra8Unorm)

        let parent = try #require(surface.superview)
        surface.removeFromSuperview()
        #expect(surface.isPaused, "Detached surfaces must stop their frame clock")
        parent.addSubview(surface)
        #expect(!surface.isPaused, "Reattaching a static surface must redraw even when its size is unchanged")
        try await requireSubmittedStaticFrame(surface)

        let animated = AtmosphereNativeView(renderer: original.renderer, intensity: changed.intensity,
                                           wind: original.wind, quality: original.quality,
                                           framesPerSecond: 30, isAnimating: true,
                                           onFailure: { Issue.record("\($0)") }, rainScene: original.rainScene)
        let firstAnimatedFrame = observer.presentedAnimationFrames
        coordinator.update(animated, view: surface)
        let animationDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        while observer.presentedAnimationFrames - firstAnimatedFrame < 60 && ContinuousClock.now < animationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(observer.presentedAnimationFrames - firstAnimatedFrame >= 60, "A visible surface must present at least 60 animated frames")
        #expect(!surface.isPaused)
        coordinator.update(changed, view: surface)
        #expect(surface.isPaused, "Stopping animation must pause the frame clock without another settings change")
        if kind == .rain {
            #expect(rainScene.hasPresentationTarget(owner: coordinator))
            let replacement = NSObject()
            rainScene.bind(owner: replacement, device: original.renderer.device, requestFrame: {})
            coordinator.update(changed, view: surface)
            #expect(rainScene.hasPresentationTarget(owner: replacement), "A retiring rain view's settings update cannot reclaim the foreground")
            rainScene.unbind(owner: coordinator)
            #expect(rainScene.hasPresentationTarget(owner: replacement), "An old rain view cannot detach the replacement weather owner")
            rainScene.unbind(owner: replacement)
            #expect(!rainScene.hasPresentationTarget(owner: replacement), "Leaving rain must hide foreground droplets")
        }
    }

    private func requireSubmittedStaticFrame(_ surface: MTKView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !surface.isPaused && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(surface.window != nil)
        try #require(surface.isPaused, "A static surface must pause after submitting its requested frame")
    }

    #if os(macOS)
    private func findSurface(in view: NSView) -> MTKView? {
        if let surface = view as? MTKView { return surface }
        for child in view.subviews {
            if let surface = findSurface(in: child) { return surface }
        }
        return nil
    }
    #else
    private func findSurface(in view: UIView) -> MTKView? {
        if let surface = view as? MTKView { return surface }
        for child in view.subviews {
            if let surface = findSurface(in: child) { return surface }
        }
        return nil
    }
    #endif
}

@MainActor
private final class SurfaceFrameObserver: NSObject, MTKViewDelegate {
    struct FrameLayout {
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
    }

    private let coordinator: AtmosphereNativeView.Coordinator
    private(set) var lastFrame: FrameLayout?
    private(set) var presentedAnimationFrames = 0

    init(coordinator: AtmosphereNativeView.Coordinator) {
        self.coordinator = coordinator
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        coordinator.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        // Inspect the real render target inside MetalKit's owning callback, before presentation.
        if let texture = view.currentRenderPassDescriptor?.colorAttachments[0].texture {
            lastFrame = FrameLayout(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat)
        }
        let isAnimating = coordinator.settings.isAnimating
        if let drawable = view.currentDrawable {
            drawable.addPresentedHandler { [weak self] presented in
                guard isAnimating, presented.presentedTime > 0 else { return }
                Task { @MainActor [weak self] in
                    self?.presentedAnimationFrames += 1
                }
            }
        }
        coordinator.draw(in: view)
    }
}

@MainActor
private final class DrawTrackingMetalView: MTKView {
    private(set) var drawCalls = 0

    override func draw() { drawCalls += 1 }
}
