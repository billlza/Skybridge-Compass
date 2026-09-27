import SwiftUI
import MetalKit
import os

/// Opaque, bounded-resolution atmosphere. Only the native surface owns frame cadence.
struct AtmosphereView: View {
    @Environment(\.weatherFrameRateMonitor) private var frameRateMonitor
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
                                     onFailure: recordFailure, appearance: appearance, rain: rain, rainScene: rainScene,
                                     frameRateMonitor: frameRateMonitor)
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
    var frameRateMonitor: WeatherFrameRateMonitor?

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
        private weak var boundFrameRateMonitor: WeatherFrameRateMonitor?
        private var frameRateSource: UUID?
        private var frameRateIsAnimating: Bool?
        private var frameRateCounter: PresentedFrameRateCounter?
        private var nextFrameRateSampleTime: TimeInterval = 0
        private var frameRateMonitoringEnded = false
        #if os(macOS)
        private weak var frameRateWindow: NSWindow?
        private weak var frameRateSurface: MTKView?
        #endif

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
            updateFrameRateMonitoring(view)
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

        private func updateFrameRateMonitoring(_ view: MTKView) {
            #if targetEnvironment(simulator)
            // The simulator Metal SDK omits drawable presentation callbacks.
            // Keep the readout unavailable instead of measuring submissions or
            // reporting a synthetic zero while the surface still renders.
            if !frameRateMonitoringEnded { stopFrameRateMonitoring() }
            #else
            guard !frameRateMonitoringEnded,
                  settings.frameRateMonitor != nil || frameRateSource != nil else { return }
            #if os(macOS)
            frameRateSurface = view
            let window = settings.frameRateMonitor == nil ? nil : view.window
            if frameRateWindow !== window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
                frameRateWindow = window
                if let window {
                    NotificationCenter.default.addObserver(self, selector: #selector(frameRateVisibilityChanged),
                        name: NSWindow.didChangeOcclusionStateNotification, object: window)
                }
            }
            let visible = view.window?.occlusionState.contains(.visible) == true && !view.isHiddenOrHasHiddenAncestor
            #else
            let visible = view.window != nil && !view.isHidden
            #endif
            let animating = settings.isAnimating && visible && view.bounds.width > 0 && view.bounds.height > 0
            guard boundFrameRateMonitor !== settings.frameRateMonitor || frameRateIsAnimating != animating else { return }
            if boundFrameRateMonitor !== settings.frameRateMonitor {
                if let source = frameRateSource { boundFrameRateMonitor?.endSource(source) }
                boundFrameRateMonitor = settings.frameRateMonitor
                frameRateSource = settings.frameRateMonitor?.beginSource(isAnimating: animating)
            } else if let source = frameRateSource {
                // A retiring weather surface must not reclaim the replacement's readout.
                boundFrameRateMonitor?.update(animating ? .measuring : .paused, source: source)
            }
            frameRateIsAnimating = animating
            let now = CACurrentMediaTime()
            frameRateCounter = frameRateSource != nil && animating ? PresentedFrameRateCounter(startingAt: now) : nil
            nextFrameRateSampleTime = now + 1
            #endif
        }

        #if os(macOS)
        @objc private func frameRateVisibilityChanged() {
            if let view = frameRateSurface { updateFrameRateMonitoring(view) }
        }
        #endif

        private func sampleFrameRate(at timestamp: TimeInterval) {
            guard let counter = frameRateCounter, let source = frameRateSource,
                  timestamp >= nextFrameRateSampleTime else { return }
            nextFrameRateSampleTime = timestamp + 1
            if let fps = counter.sample(at: timestamp) {
                boundFrameRateMonitor?.update(.framesPerSecond(fps), source: source)
            }
        }

        func stopFrameRateMonitoring() {
            frameRateMonitoringEnded = true
            if let source = frameRateSource { boundFrameRateMonitor?.endSource(source) }
            frameRateSource = nil
            frameRateCounter = nil
            boundFrameRateMonitor = nil
            #if os(macOS)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            frameRateWindow = nil
            frameRateSurface = nil
            #endif
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            autoreleasepool { renderFrame(in: view) }
        }

        private func renderFrame(in view: MTKView) {
            resize(view)
            // Poll using the existing render callback, including while GPU backpressure
            // prevents a submission. No presentation in a full window is a measured zero.
            let now = CACurrentMediaTime()
            sampleFrameRate(at: now)
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
                let time = clock.sample(at: now, animating: settings.isAnimating)
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
                #if !targetEnvironment(simulator)
                if let counter = frameRateCounter {
                    drawable.addPresentedHandler { presented in
                        counter.recordPresentation(at: presented.presentedTime)
                    }
                }
                #endif
                // The foreground glass and background share one frame. Count only the
                // background drawable, never both layers, submission attempts or GPU completions.
                buffer.present(drawable)
                if let glassDrawable { buffer.present(glassDrawable) }
                buffer.commit()
                needsFrame = settings.rainScene?.hasPresentationTarget(owner: self) == true && glassDrawable == nil
                updateFrameClock(view)
            } catch {
                availableFrames.signal()
                view.isPaused = true
                stopFrameRateMonitoring()
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
        coordinator.stopFrameRateMonitoring()
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
        coordinator.stopFrameRateMonitoring()
        coordinator.settings.rainScene?.unbind(owner: coordinator)
        view.isPaused = true
        view.delegate = nil
        view.releaseDrawables()
    }
}
#endif
