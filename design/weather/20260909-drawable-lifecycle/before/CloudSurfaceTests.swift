import SwiftUI
import MetalKit
import Testing
@testable import SkyBridgeWeatherRendering

@MainActor
struct CloudSurfaceTests {
    @Test func nativeSurfaceLoadsWhenPausedAndTracksWindowSize() async throws {
        let root = CinematicCloudView(isAnimating: false)
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
        while findSurface(in: host) == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let surface = try #require(findSurface(in: host))
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
        let drawable = try #require(metalLayer.nextDrawable())
        #expect(drawable.texture.width == Int(surface.drawableSize.width))
        #expect(drawable.texture.height == Int(surface.drawableSize.height))
        #expect(drawable.texture.pixelFormat == .bgra8Unorm)
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
