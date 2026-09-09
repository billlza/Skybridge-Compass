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
        let root = Group {
            if kind == .clouds {
                CinematicCloudView(isAnimating: false)
            } else {
                CinematicHazeView(isAnimating: false)
            }
        }
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
        #expect(min(surface.drawableSize.width, surface.drawableSize.height) <= 600)
        #expect(max(surface.drawableSize.width, surface.drawableSize.height) <= 1300)
        #expect(abs(surface.drawableSize.width / surface.drawableSize.height - surface.bounds.width / surface.bounds.height) < 0.01)
        #expect(surface.colorPixelFormat == .bgra8Unorm)
        let metalLayer = try #require(surface.layer as? CAMetalLayer)
        #expect(metalLayer.colorspace?.name == CGColorSpace.sRGB)
        #expect(surface.delegate != nil)
        // MTKView's currentDrawable belongs to its draw callback and may already have
        // been presented. Acquire our own drawable to verify the live surface's format.
        do {
            let drawable = try #require(metalLayer.nextDrawable())
            #expect(drawable.texture.width == Int(surface.drawableSize.width))
            #expect(drawable.texture.height == Int(surface.drawableSize.height))
            #expect(drawable.texture.pixelFormat == .bgra8Unorm)
        }

        let coordinator = try #require(surface.delegate as? AtmosphereNativeView.Coordinator)
        let original = coordinator.settings
        let changed = AtmosphereNativeView(renderer: original.renderer, intensity: 0.5, wind: original.wind,
                                      quality: original.quality, framesPerSecond: original.framesPerSecond,
                                      isAnimating: false, onFailure: { Issue.record("\($0)") })
        coordinator.update(changed, view: surface)
        #expect(!surface.isPaused, "A static settings change must request one new frame")
        try await requireSubmittedStaticFrame(surface)

        let parent = try #require(surface.superview)
        surface.removeFromSuperview()
        #expect(surface.isPaused, "Detached surfaces must stop their frame clock")
        parent.addSubview(surface)
        #expect(!surface.isPaused, "Reattaching a static surface must redraw even when its size is unchanged")
        try await requireSubmittedStaticFrame(surface)
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
private final class DrawTrackingMetalView: MTKView {
    private(set) var drawCalls = 0

    override func draw() { drawCalls += 1 }
}
