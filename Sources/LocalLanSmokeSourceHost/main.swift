import AppKit
import Darwin
import Foundation
import MetalKit
import SkyBridgeSmokeSupport
import simd

@MainActor
private final class SmokeSourceCoordinator {
    private let reporter: SmokeStatusReporter
    private var source: SmokeCaptureAnimationSource?
    private var activity: NSObjectProtocol?

    init() {
        reporter = SmokeStatusReporter(statusURL: Self.statusURL())
    }

    func start() throws {
        SmokeSourceProcessPriority.applyUserInteractiveMainThreadQoS()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiatedAllowingIdleSystemSleep,
                .latencyCritical,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled
            ],
            reason: "SkyBridge remote smoke source must stay live during final-window capture validation."
        )
        reporter.append("boot role=mac-smoke-source")
        reporter.append(
            "smoke-capture-source activity=active appNapDisabled=1 mainThreadQOS=userInteractive statusWriter=background-serial"
        )
        let source = SmokeCaptureAnimationSource(reporter: reporter)
        try source.start()
        self.source = source
    }

    private static func statusURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }
}

@MainActor
private final class SmokeCaptureAnimationSource {
    fileprivate static let targetCaptureFramesPerSecond = 60
    private static let statusReportIntervalSeconds: TimeInterval = 1
    private static let staleRenderRepairThresholdMilliseconds = 100.0
    private let reporter: SmokeStatusReporter
    private var size = NSSize(width: 640, height: 360)
    private var window: NSWindow?
    private var animationView: SmokeCaptureAnimationView?
    private var statusTimer: DispatchSourceTimer?
    private var frameIndex: UInt64 = 0
    private var lastStatusReportAt: Date = .distantPast
    private var displayID: CGDirectDisplayID = 0
    private var screenMaximumFramesPerSecond = targetCaptureFramesPerSecond
    private var targetRenderFramesPerSecond = targetCaptureFramesPerSecond
    private var visibilityRepairCount: UInt64 = 0

    init(reporter: SmokeStatusReporter) {
        self.reporter = reporter
    }

    deinit {
        statusTimer?.setEventHandler {}
        statusTimer?.cancel()
    }

    func start() throws {
        guard window == nil else { return }

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()

        let mainDisplayID = CGMainDisplayID()
        let targetScreen = Self.screen(for: mainDisplayID) ?? NSScreen.main
        displayID = targetScreen.flatMap(Self.displayID(for:)) ?? mainDisplayID
        screenMaximumFramesPerSecond = Self.maximumFramesPerSecond(for: targetScreen)
        targetRenderFramesPerSecond = Self.renderFramesPerSecond(for: targetScreen)
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        size = Self.captureWindowSize(for: visibleFrame)
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            reporter.appendAndWait("failed stage=mac-smoke-source phase=smoke_source reason=metal_unavailable")
            throw SmokeCaptureAnimationSourceError.metalUnavailable
        }

        let view: SmokeCaptureAnimationView
        do {
            view = try SmokeCaptureAnimationView(
                frame: NSRect(origin: .zero, size: size),
                metalDevice: metalDevice
            )
        } catch {
            reporter.appendAndWait("failed stage=mac-smoke-source phase=smoke_source reason=metal_renderer_unavailable")
            throw error
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SkyBridge Remote Smoke Source"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = view
        placeWindow(window, visibleFrame: visibleFrame)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        view.setRenderingFrameRate(targetRenderFramesPerSecond)
        view.startRendering()
        window.displayIfNeeded()
        application.updateWindows()

        self.window = window
        self.animationView = view

        reportSourceStatus(frame: 0)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .seconds(1),
            repeating: .seconds(1),
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.heartbeat()
            }
        }
        timer.resume()
        statusTimer = timer
    }

    private static func captureWindowSize(for visibleFrame: NSRect) -> NSSize {
        let width = max(640, floor(visibleFrame.width - 64))
        let height = max(360, floor(visibleFrame.height - 64))
        return NSSize(width: width, height: height)
    }

    private static func maximumFramesPerSecond(for screen: NSScreen?) -> Int {
        max(targetCaptureFramesPerSecond, screen?.maximumFramesPerSecond ?? targetCaptureFramesPerSecond)
    }

    private static func renderFramesPerSecond(for _: NSScreen?) -> Int {
        targetCaptureFramesPerSecond
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            self.displayID(for: screen) == displayID
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func placeWindow(_ window: NSWindow, visibleFrame: NSRect) {
        let origin = NSPoint(
            x: visibleFrame.minX + max(32, floor((visibleFrame.width - size.width) / 2)),
            y: visibleFrame.minY + max(32, floor((visibleFrame.height - size.height) / 2))
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func heartbeat() {
        repairCaptureWindowIfNeeded()
        let now = Date()
        if now.timeIntervalSince(lastStatusReportAt) >= Self.statusReportIntervalSeconds {
            lastStatusReportAt = now
            let renderSnapshot = animationView?.renderSnapshot()
            frameIndex = renderSnapshot?.renderedFrames ?? frameIndex
            reportSourceStatus(frame: frameIndex, renderSnapshot: renderSnapshot)
        }
    }

    private func repairCaptureWindowIfNeeded() {
        let isVisible = window?.isVisible == true
        let isOcclusionVisible = window?.occlusionState.contains(.visible) == true
        let lastFrameAge = animationView?.lastFrameAgeMilliseconds() ?? -1
        let renderIsStale = lastFrameAge >= Self.staleRenderRepairThresholdMilliseconds
        guard !isVisible || !isOcclusionVisible || renderIsStale else {
            animationView?.ensureRendering()
            return
        }

        visibilityRepairCount &+= 1
        window?.orderFrontRegardless()
        animationView?.ensureRendering()
        window?.displayIfNeeded()
        NSApplication.shared.updateWindows()
        let ageText = lastFrameAge >= 0 ? String(format: "%.2f", lastFrameAge) : "-"
        reporter.append(
            "smoke-capture-source visibilityRepair=1 count=\(visibilityRepairCount) windowVisible=\(isVisible ? 1 : 0) windowOcclusionVisible=\(isOcclusionVisible ? 1 : 0) lastRenderAgeMs=\(ageText)"
        )
    }

    private func reportSourceStatus(
        frame: UInt64,
        renderSnapshot: SmokeCaptureRenderSnapshot? = nil
    ) {
        let window = self.window
        let windowFrame = window?.frame ?? .zero
        let windowNumber = window?.windowNumber ?? 0
        let visible = window?.isVisible == true ? 1 : 0
        let occlusionVisible = window?.occlusionState.contains(.visible) == true ? 1 : 0
        let level = Int(window?.level.rawValue ?? 0)
        let renderedFrames = renderSnapshot?.renderedFrames ?? 0
        let renderFPS = renderSnapshot.map { String(format: "%.1f", $0.framesPerSecond) } ?? "-"
        let renderGapMax = renderSnapshot.map { String(format: "%.2f", $0.maxFrameGapMilliseconds) } ?? "-"
        let lastRenderAge = renderSnapshot.map { String(format: "%.2f", $0.lastFrameAgeMilliseconds) } ?? "-"
        reporter.append(
            "smoke-capture-source active=1 mode=metal-vsync sourceCadenceDriver=mtkview-display-link statusWriter=background-serial visibilityRepair=conditional process=helper fps=\(Self.targetCaptureFramesPerSecond) targetCaptureFPS=\(Self.targetCaptureFramesPerSecond) targetRenderFPS=\(targetRenderFramesPerSecond) screenMaxFPS=\(screenMaximumFramesPerSecond) frame=\(frame) renderedFrames=\(renderedFrames) renderFPS=\(renderFPS) renderGapMaxMs=\(renderGapMax) lastRenderAgeMs=\(lastRenderAge) displayID=\(displayID) windowID=\(windowNumber) window=\(Int(size.width))x\(Int(size.height)) windowVisible=\(visible) windowOcclusionVisible=\(occlusionVisible) windowLevel=\(level) windowFrame=\(Int(windowFrame.origin.x)),\(Int(windowFrame.origin.y)),\(Int(windowFrame.size.width)),\(Int(windowFrame.size.height))"
        )
    }
}

private enum SmokeSourceProcessPriority {
    static func applyUserInteractiveMainThreadQoS() {
        _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    }
}

private enum SmokeCaptureAnimationSourceError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable
    case shaderLibraryUnavailable(String)
    case pipelineUnavailable(String)
    case vertexBufferUnavailable

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal is unavailable for the remote smoke source."
        case .commandQueueUnavailable:
            return "Metal command queue is unavailable for the remote smoke source."
        case .shaderLibraryUnavailable(let detail):
            return "Metal shader library is unavailable for the remote smoke source: \(detail)"
        case .pipelineUnavailable(let detail):
            return "Metal render pipeline is unavailable for the remote smoke source: \(detail)"
        case .vertexBufferUnavailable:
            return "Metal vertex buffer is unavailable for the remote smoke source."
        }
    }
}

private struct SmokeCaptureRenderSnapshot: Sendable {
    let renderedFrames: UInt64
    let framesPerSecond: Double
    let maxFrameGapMilliseconds: Double
    let lastFrameAgeMilliseconds: Double
}

private struct SmokeCaptureVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

@MainActor
private final class SmokeCaptureAnimationView: MTKView {
    private let renderer: SmokeCaptureMetalRenderer

    init(frame frameRect: NSRect, metalDevice: MTLDevice) throws {
        let renderer = try SmokeCaptureMetalRenderer(device: metalDevice)
        self.renderer = renderer
        super.init(frame: frameRect, device: metalDevice)
        configureView(renderer: renderer)
    }

    required init(coder: NSCoder) {
        guard let metalDevice = MTLCreateSystemDefaultDevice(),
              let renderer = try? SmokeCaptureMetalRenderer(device: metalDevice) else {
            fatalError("Metal is required for SmokeCaptureAnimationView")
        }
        self.renderer = renderer
        super.init(coder: coder)
        device = metalDevice
        configureView(renderer: renderer)
    }

    func startRendering() {
        renderer.reset()
        isPaused = false
        needsDisplay = true
    }

    func ensureRendering() {
        if isPaused {
            isPaused = false
        }
    }

    func setRenderingFrameRate(_ framesPerSecond: Int) {
        preferredFramesPerSecond = framesPerSecond
    }

    func renderSnapshot() -> SmokeCaptureRenderSnapshot {
        renderer.snapshot()
    }

    func lastFrameAgeMilliseconds() -> Double {
        renderer.lastFrameAgeMilliseconds()
    }

    private func configureView(renderer: SmokeCaptureMetalRenderer) {
        delegate = renderer
        preferredFramesPerSecond = SmokeCaptureAnimationSource.targetCaptureFramesPerSecond
        enableSetNeedsDisplay = false
        isPaused = false
        framebufferOnly = true
        autoResizeDrawable = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.02, 0.15, 0.82, 1.0)
        layer?.isOpaque = true
    }
}

private final class SmokeCaptureMetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private static let maxVertexCount = 96
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct SmokeVertex {
        float2 position;
        float4 color;
    };

    struct SmokeRaster {
        float4 position [[position]];
        float4 color;
    };

    vertex SmokeRaster smoke_vertex(const device SmokeVertex *vertices [[buffer(0)]],
                                    uint vertexID [[vertex_id]]) {
        SmokeRaster out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.color = vertices[vertexID].color;
        return out;
    }

    fragment float4 smoke_fragment(SmokeRaster in [[stage_in]]) {
        return in.color;
    }
    """

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let stateLock = NSLock()
    private var startedAtNanos: UInt64 = 0
    private var lastFrameAtNanos: UInt64 = 0
    private var lastSnapshotAtNanos: UInt64 = 0
    private var lastSnapshotFrameCount: UInt64 = 0
    private var renderedFrames: UInt64 = 0
    private var maxFrameGapMilliseconds: Double = 0

    init(device: MTLDevice) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw SmokeCaptureAnimationSourceError.commandQueueUnavailable
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw SmokeCaptureAnimationSourceError.shaderLibraryUnavailable(error.localizedDescription)
        }
        guard let vertexFunction = library.makeFunction(name: "smoke_vertex"),
              let fragmentFunction = library.makeFunction(name: "smoke_fragment") else {
            throw SmokeCaptureAnimationSourceError.shaderLibraryUnavailable("missing smoke shader entry point")
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw SmokeCaptureAnimationSourceError.pipelineUnavailable(error.localizedDescription)
        }
        guard let vertexBuffer = device.makeBuffer(
            length: MemoryLayout<SmokeCaptureVertex>.stride * Self.maxVertexCount,
            options: [.storageModeShared]
        ) else {
            throw SmokeCaptureAnimationSourceError.vertexBufferUnavailable
        }
        self.commandQueue = commandQueue
        self.vertexBuffer = vertexBuffer
        super.init()
    }

    func reset() {
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        startedAtNanos = now
        lastFrameAtNanos = 0
        lastSnapshotAtNanos = now
        lastSnapshotFrameCount = 0
        renderedFrames = 0
        maxFrameGapMilliseconds = 0
        stateLock.unlock()
    }

    func snapshot() -> SmokeCaptureRenderSnapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        let started = startedAtNanos
        let previousSnapshot = lastSnapshotAtNanos > 0 ? lastSnapshotAtNanos : started
        let lastFrame = lastFrameAtNanos
        let frames = renderedFrames
        let frameDelta = frames >= lastSnapshotFrameCount ? frames - lastSnapshotFrameCount : 0
        let maxGap = maxFrameGapMilliseconds
        lastSnapshotAtNanos = now
        lastSnapshotFrameCount = frames
        maxFrameGapMilliseconds = 0
        stateLock.unlock()

        let elapsedSeconds: Double
        if previousSnapshot > 0, now >= previousSnapshot {
            elapsedSeconds = Double(now - previousSnapshot) / 1_000_000_000
        } else {
            elapsedSeconds = 0
        }
        let ageMs: Double
        if lastFrame > 0, now >= lastFrame {
            ageMs = Double(now - lastFrame) / 1_000_000
        } else {
            ageMs = -1
        }
        let fps = elapsedSeconds > 0 ? Double(frameDelta) / elapsedSeconds : 0
        return SmokeCaptureRenderSnapshot(
            renderedFrames: frames,
            framesPerSecond: fps,
            maxFrameGapMilliseconds: maxGap,
            lastFrameAgeMilliseconds: ageMs
        )
    }

    func lastFrameAgeMilliseconds() -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        let lastFrame = lastFrameAtNanos
        stateLock.unlock()
        guard lastFrame > 0, now >= lastFrame else {
            return -1
        }
        return Double(now - lastFrame) / 1_000_000
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange _: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let frame = noteFrameRendered()
        let vertices = makeDynamicFrameVertices(for: frame)
        descriptor.colorAttachments[0].clearColor = clearColor(for: frame)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            let byteCount = vertices.count * MemoryLayout<SmokeCaptureVertex>.stride
            precondition(vertices.count <= Self.maxVertexCount)
            vertices.withUnsafeBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress {
                    vertexBuffer.contents().copyMemory(from: baseAddress, byteCount: byteCount)
                }
            }
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func noteFrameRendered() -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        if startedAtNanos == 0 {
            startedAtNanos = now
            lastSnapshotAtNanos = now
        }
        if lastFrameAtNanos > 0, now >= lastFrameAtNanos {
            let gapMs = Double(now - lastFrameAtNanos) / 1_000_000
            maxFrameGapMilliseconds = max(maxFrameGapMilliseconds, gapMs)
        }
        lastFrameAtNanos = now
        renderedFrames &+= 1
        let frame = renderedFrames
        stateLock.unlock()
        return frame
    }

    private func clearColor(for frame: UInt64) -> MTLClearColor {
        let phase = Double(frame % 180) / 180.0
        let wave = (1.0 + sin(phase * 2.0 * Double.pi)) / 2.0
        let counterWave = (1.0 + sin((phase + 0.33) * 2.0 * Double.pi)) / 2.0
        let pulse = frame.isMultiple(of: 24) ? 0.35 : 0.12
        return MTLClearColorMake(
            0.05 + 0.72 * wave,
            0.14 + 0.66 * counterWave,
            0.30 + pulse,
            1.0
        )
    }

    private func makeDynamicFrameVertices(for frame: UInt64) -> [SmokeCaptureVertex] {
        var vertices: [SmokeCaptureVertex] = []
        vertices.reserveCapacity(Self.maxVertexCount)

        let phase = Float(frame % 240) / 240.0
        let fastPhase = Float((frame * 5) % 240) / 240.0
        let pulse = frame.isMultiple(of: 2) ? Float(1.0) : Float(0.55)

        appendRect(
            x: -1.25 + 2.50 * phase,
            y: -1.0,
            width: 0.22,
            height: 2.0,
            color: SIMD4<Float>(1.0, 0.92 * pulse, 0.08, 1.0),
            to: &vertices
        )
        appendRect(
            x: -1.0,
            y: -1.20 + 2.40 * fastPhase,
            width: 2.0,
            height: 0.18,
            color: SIMD4<Float>(0.02, 0.95, 1.0 * pulse, 1.0),
            to: &vertices
        )
        appendRect(
            x: 0.82 - 1.64 * phase,
            y: -0.78 + 1.56 * fastPhase,
            width: 0.26,
            height: 0.26,
            color: SIMD4<Float>(1.0, 0.08, 0.76, 1.0),
            to: &vertices
        )

        for index in 0..<6 {
            let offset = Float(index) * 0.34
            let x = -0.95 + offset
            let y = -0.84 + 0.10 * sin(Float(frame + UInt64(index * 17)) * 0.12)
            let brightness = (index + Int(frame % 2)).isMultiple(of: 2) ? Float(0.95) : Float(0.22)
            appendRect(
                x: x,
                y: y,
                width: 0.18,
                height: 0.14,
                color: SIMD4<Float>(brightness, 0.22 + 0.55 * brightness, 0.95 - 0.45 * brightness, 1.0),
                to: &vertices
            )
        }

        return vertices
    }

    private func appendRect(
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        color: SIMD4<Float>,
        to vertices: inout [SmokeCaptureVertex]
    ) {
        let minX = max(-1.0, x)
        let minY = max(-1.0, y)
        let maxX = min(1.0, x + width)
        let maxY = min(1.0, y + height)
        guard maxX > minX, maxY > minY else { return }

        vertices.append(SmokeCaptureVertex(position: SIMD2<Float>(minX, minY), color: color))
        vertices.append(SmokeCaptureVertex(position: SIMD2<Float>(maxX, minY), color: color))
        vertices.append(SmokeCaptureVertex(position: SIMD2<Float>(minX, maxY), color: color))
        vertices.append(SmokeCaptureVertex(position: SIMD2<Float>(maxX, minY), color: color))
        vertices.append(SmokeCaptureVertex(position: SIMD2<Float>(maxX, maxY), color: color))
        vertices.append(SmokeCaptureVertex(position: SIMD2<Float>(minX, maxY), color: color))
    }
}

@MainActor
private enum SmokeSourceLifetime {
    static var coordinator: SmokeSourceCoordinator?
}

private final class SmokeStatusReporter {
    let statusURL: URL?
    private let queue = DispatchQueue(
        label: "com.skybridge.smoke.status-writer",
        qos: .utility
    )

    init(statusURL: URL?) {
        self.statusURL = statusURL
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        queue.async {
            Self.write(line, to: statusURL)
        }
    }

    func appendAndWait(_ line: String) {
        guard let statusURL else { return }
        queue.sync {
            Self.write(line, to: statusURL)
        }
    }

    private static func write(_ line: String, to statusURL: URL) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatted = "[\(formatter.string(from: Date()))] \(line)\n"
        guard let data = formatted.data(using: .utf8) else { return }
        try? SmokeStatusFileAppender.append(
            data,
            to: statusURL,
            protection: .completeUntilFirstUserAuthentication
        )
    }
}

private func writeProtectedData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: url.path) {
        try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
    } else {
        FileManager.default.createFile(atPath: url.path, contents: data)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

@main
struct LocalLanSmokeSourceHostMain {
    static func main() {
        setenv("SKYBRIDGE_SMOKE_ROLE", "mac-smoke-source", 1)
        Task { @MainActor in
            let coordinator = SmokeSourceCoordinator()
            SmokeSourceLifetime.coordinator = coordinator
            do {
                try coordinator.start()
            } catch {
                fputs("LocalLanSmokeSourceHost failed: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }

        NSApplication.shared.run()
    }
}
