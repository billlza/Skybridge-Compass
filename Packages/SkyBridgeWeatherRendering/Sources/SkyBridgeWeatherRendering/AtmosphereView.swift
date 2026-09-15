import SwiftUI
import MetalKit
import os

/// Opaque, bounded-resolution atmosphere. Only the native surface owns frame cadence.
struct AtmosphereView: View {
    private let kind: AtmosphereKind
    private let appearance: HazeAppearance
    private let rain: RainAppearance
    private let rainScene: WeatherRainScene?
    private let intensity: Float
    private let wind: Float
    private let quality: Float
    private let framesPerSecond: Int
    private let isAnimating: Bool
    @State private var renderer: AtmosphereRenderer?
    @State private var failure: String?

    init(kind: AtmosphereKind, intensity: Float = 0.68, wind: Float = 0.2, quality: Float = 1,
         framesPerSecond: Int = 30, isAnimating: Bool = true, appearance: HazeAppearance = HazeAppearance(),
         rain: RainAppearance = RainAppearance(), rainScene: WeatherRainScene? = nil) {
        precondition(intensity.isFinite && wind.isFinite && quality.isFinite)
        precondition(appearance.tint.x.isFinite && appearance.tint.y.isFinite && appearance.tint.z.isFinite)
        self.kind = kind
        self.appearance = appearance
        self.rain = rain
        self.rainScene = rainScene
        self.intensity = min(max(intensity, 0), 1)
        self.wind = min(max(wind, 0), 1)
        self.quality = min(max(quality, 0), 1)
        self.framesPerSecond = min(max(framesPerSecond, 1), 60)
        self.isAnimating = isAnimating
    }

    var body: some View {
        Group {
            if failure != nil {
                Image(systemName: "cloud.slash")
                    .accessibilityLabel("Weather effect unavailable")
            } else if let renderer {
                AtmosphereNativeView(renderer: renderer, intensity: intensity, wind: wind, quality: quality,
                                     framesPerSecond: framesPerSecond, isAnimating: isAnimating,
                                     onFailure: recordFailure, appearance: appearance, rain: rain, rainScene: rainScene)
            } else {
                Color(red: 0.035, green: 0.065, blue: 0.115)
            }
        }
        .task {
            guard renderer == nil, failure == nil else { return }
            do {
                let loaded = try await AtmosphereRenderer.load(kind: kind)
                try Task.checkCancellation()
                renderer = loaded
            } catch is CancellationError {
                // The owning weather surface disappeared while its pipeline was compiling.
                return
            } catch {
                recordFailure(error.localizedDescription)
            }
        }
        .allowsHitTesting(false)
    }

    private func recordFailure(_ message: String) {
        Logger(subsystem: "com.skybridge.weather", category: "AtmosphereRendering").error("\(message, privacy: .public)")
        failure = message
    }
}

struct AtmosphereNativeView {
    let renderer: AtmosphereRenderer
    let intensity: Float
    let wind: Float
    let quality: Float
    let framesPerSecond: Int
    let isAnimating: Bool
    let onFailure: @MainActor (String) -> Void
    var appearance = HazeAppearance()
    var rain = RainAppearance()
    var rainScene: WeatherRainScene?

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator(settings: self) }

    @MainActor
    func makeSurface(coordinator: Coordinator) -> MTKView {
        let view = AtmosphereMetalSurface(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        #if os(macOS)
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #else
        guard let metalLayer = view.layer as? CAMetalLayer else {
            preconditionFailure("MTKView requires a Metal backing layer")
        }
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #endif
        view.autoResizeDrawable = false
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.delegate = coordinator
        view.onLayout = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.resize(view)
        }
        view.onWindowChange = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.windowDidChange(view)
        }
        #if os(macOS)
        view.layer?.isOpaque = true
        #else
        view.isOpaque = true
        #endif
        coordinator.update(self, view: view)
        return view
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var settings: AtmosphereNativeView
        private var clock = AtmosphereAnimationClock()
        private let availableFrames = DispatchSemaphore(value: 2)
        private var needsFrame = true
        private weak var boundRainScene: WeatherRainScene?

        init(settings: AtmosphereNativeView) { self.settings = settings }

        func update(_ settings: AtmosphereNativeView, view: MTKView) {
            if boundRainScene !== settings.rainScene {
                boundRainScene?.unbind(owner: self)
                boundRainScene = settings.rainScene
                settings.rainScene?.bind(owner: self, device: settings.renderer.device) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.needsFrame = true
                    self.updateFrameClock(view)
                }
            }
            if self.settings.intensity != settings.intensity || self.settings.wind != settings.wind ||
                self.settings.quality != settings.quality || self.settings.appearance != settings.appearance ||
                self.settings.rain != settings.rain {
                needsFrame = true
            }
            self.settings = settings
            if !settings.isAnimating { clock.pause() }
            view.preferredFramesPerSecond = settings.framesPerSecond
            resize(view)
        }

        func resize(_ view: MTKView) {
            #if os(macOS)
            let scale = view.window?.backingScaleFactor ?? 1
            #else
            let scale = view.contentScaleFactor
            #endif
            let pixels = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
            let size = AtmosphereRenderPolicy.drawableSize(for: pixels, quality: settings.quality,
                                                          kind: settings.renderer.kind)
            if size != .zero, size != view.drawableSize {
                view.drawableSize = size
                needsFrame = true
            }
            updateFrameClock(view)
        }

        func windowDidChange(_ view: MTKView) {
            clock.pause()
            needsFrame = true
            resize(view)
        }

        private func updateFrameClock(_ view: MTKView) {
            // Only MetalKit's frame clock may enter draw. A static change requests one
            // frame and pauses after submission, including when GPU backpressure delays it.
            view.isPaused = view.window == nil || (!settings.isAnimating && !needsFrame)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            autoreleasepool { renderFrame(in: view) }
        }

        private func renderFrame(in view: MTKView) {
            resize(view)
            guard settings.isAnimating || needsFrame else { return }
            guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0,
                  availableFrames.wait(timeout: .now()) == .success else { return }
            // Both values belong to this MetalKit draw callback; neither is retained after presentation.
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
                availableFrames.signal()
                return // A detached or occluded surface has no drawable.
            }
            do {
                guard let buffer = settings.renderer.queue.makeCommandBuffer() else {
                    throw AtmosphereRenderError.unavailable("command buffer allocation failed")
                }
                let time = clock.sample(at: CACurrentMediaTime(), animating: settings.isAnimating)
                let uniforms = AtmosphereUniforms(resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                                             time: time, quality: settings.quality, intensity: settings.intensity, wind: settings.wind)
                try settings.renderer.encode(commandBuffer: buffer, pass: pass, uniforms: uniforms,
                                             appearance: settings.appearance, rain: settings.rain,
                                             compositeGlass: settings.rainScene == nil)
                let glassDrawable = settings.rainScene?.nextDrawable(owner: self)
                if let glassDrawable {
                    // Read the texture before presentation, exactly once, while this drawable is owned.
                    let texture = glassDrawable.texture
                    let glassPass = MTLRenderPassDescriptor()
                    glassPass.colorAttachments[0].texture = texture
                    glassPass.colorAttachments[0].loadAction = .clear
                    glassPass.colorAttachments[0].storeAction = .store
                    glassPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                    var glassUniforms = uniforms
                    glassUniforms.resolution = SIMD2(Float(texture.width), Float(texture.height))
                    try settings.renderer.encodeGlass(commandBuffer: buffer, pass: glassPass,
                                                       uniforms: glassUniforms, rain: settings.rain)
                }
                let availableFrames = availableFrames
                let onFailure = settings.onFailure
                buffer.addCompletedHandler { completed in
                    availableFrames.signal()
                    if let error = completed.error {
                        let message = error.localizedDescription
                        Task { @MainActor in onFailure(message) }
                    }
                }
                buffer.present(drawable)
                if let glassDrawable { buffer.present(glassDrawable) }
                buffer.commit()
                needsFrame = settings.rainScene?.hasPresentationTarget(owner: self) == true && glassDrawable == nil
                updateFrameClock(view)
            } catch {
                availableFrames.signal()
                view.isPaused = true
                settings.rainScene?.unbind(owner: self)
                settings.onFailure(error.localizedDescription)
            }
        }
    }
}

@MainActor
private final class AtmosphereMetalSurface: MTKView {
    var onLayout: (() -> Void)?
    var onWindowChange: (() -> Void)?
    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
    #endif
}

#if os(macOS)
extension AtmosphereNativeView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { makeSurface(coordinator: context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) { context.coordinator.update(self, view: view) }
    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.settings.rainScene?.unbind(owner: coordinator)
        view.isPaused = true
        view.delegate = nil
        view.releaseDrawables()
    }
}
#else
extension AtmosphereNativeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView { makeSurface(coordinator: context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) { context.coordinator.update(self, view: view) }
    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.settings.rainScene?.unbind(owner: coordinator)
        view.isPaused = true
        view.delegate = nil
        view.releaseDrawables()
    }
}
#endif
