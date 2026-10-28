import SwiftUI
@preconcurrency import Metal
import MetalKit
import Combine
import SkyBridgeCore

/// 支持输入事件的交互式远程显示视图
class InteractiveRemoteView: MTKView {
 /// 输入事件回调
    var onMouseEvent: ((CGPoint, NSEvent.EventType, Int) -> Void)?
    var onKeyboardEvent: ((UInt16, Bool) -> Void)?
    var onScrollEvent: ((CGFloat, CGFloat) -> Void)?
    
    var mapsPointerToRemoteFrame = false
    var remoteFrameSize: CGSize = .zero
    private var inputFeedIdentity: ObjectIdentifier?
    private enum PressedControl: Equatable {
        case key(UInt16)
        case mouse(Int)
    }
    private var pressedControls: [PressedControl] = []
    private var lastPointerLocation: CGPoint = .zero
    private var inputTrackingArea: NSTrackingArea?
    private var renderingErrorLabel: NSTextField?

    override var acceptsFirstResponder: Bool { onKeyboardEvent != nil }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func updateTrackingAreas() {
        if let inputTrackingArea { removeTrackingArea(inputTrackingArea) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        inputTrackingArea = tracking
        super.updateTrackingAreas()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        releasePressedInput()
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification, object: window
            )
        }
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        releasePressedInput()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { releasePressedInput() }
        return resigned
    }

    func prepareInputBinding(feed: RemoteTextureFeed, hasKeyboardInput: Bool, hasMouseInput: Bool) {
        let identity = ObjectIdentifier(feed)
        if inputFeedIdentity != identity || !hasKeyboardInput || !hasMouseInput {
            releasePressedInput()
        }
        inputFeedIdentity = identity
    }

    /// Release through the old callbacks before focus, feed, or window ownership changes.
    func releasePressedInput() {
        let controls = pressedControls.reversed()
        pressedControls.removeAll()
        for control in controls {
            switch control {
            case .key(let key): onKeyboardEvent?(key, false)
            case .mouse(let button):
                onMouseEvent?(lastPointerLocation, button == 0 ? .leftMouseUp : .rightMouseUp, button)
            }
        }
    }

    @MainActor
    func showRenderingError() {
        guard renderingErrorLabel == nil else { return }
        let label = NSTextField(
            labelWithString: LocalizationManager.shared.localizedString("remote.camera.rendererUnavailable")
        )
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        renderingErrorLabel = label
    }

    @MainActor
    func clearRenderingError() {
        renderingErrorLabel?.removeFromSuperview()
        renderingErrorLabel = nil
    }
    
    // MARK: - Input in the displayed frame's coordinate space

    private func pointerLocation(for event: NSEvent) -> CGPoint? {
        let location = convert(event.locationInWindow, from: nil)
        guard mapsPointerToRemoteFrame else { return location }
        guard bounds.width > 0, bounds.height > 0,
              remoteFrameSize.width > 0, remoteFrameSize.height > 0 else { return nil }
        let x = (location.x - bounds.minX) / bounds.width
        let y = isFlipped
            ? (location.y - bounds.minY) / bounds.height
            : (bounds.maxY - location.y) / bounds.height
        return CGPoint(
            x: min(max(x * remoteFrameSize.width, 0), remoteFrameSize.width - 1),
            y: min(max(y * remoteFrameSize.height, 0), remoteFrameSize.height - 1)
        )
    }

    private func forwardMouse(_ event: NSEvent, type: NSEvent.EventType, button: Int = 0) {
        guard let onMouseEvent else { return }
        let isRelease = type == .leftMouseUp || type == .rightMouseUp
        let location: CGPoint
        if let mapped = pointerLocation(for: event) {
            location = mapped
        } else if isRelease, pressedControls.contains(.mouse(button)) {
            // A frame transition must not strand a previously delivered press.
            location = lastPointerLocation
        } else {
            return
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            window?.makeFirstResponder(self)
            if !pressedControls.contains(.mouse(button)) { pressedControls.append(.mouse(button)) }
        } else if isRelease {
            guard let index = pressedControls.firstIndex(of: .mouse(button)) else { return }
            pressedControls.remove(at: index)
        }
        lastPointerLocation = location
        onMouseEvent(location, type, button)
    }

    override func mouseDown(with event: NSEvent) { forwardMouse(event, type: .leftMouseDown) }
    override func mouseUp(with event: NSEvent) { forwardMouse(event, type: .leftMouseUp) }
    override func rightMouseDown(with event: NSEvent) { forwardMouse(event, type: .rightMouseDown, button: 1) }
    override func rightMouseUp(with event: NSEvent) { forwardMouse(event, type: .rightMouseUp, button: 1) }
    override func mouseMoved(with event: NSEvent) { forwardMouse(event, type: .mouseMoved) }
    override func mouseDragged(with event: NSEvent) { forwardMouse(event, type: .leftMouseDragged) }
    override func rightMouseDragged(with event: NSEvent) { forwardMouse(event, type: .rightMouseDragged, button: 1) }
    override func scrollWheel(with event: NSEvent) {
        onScrollEvent?(event.scrollingDeltaX, event.scrollingDeltaY)
    }

    private func forwardKey(_ code: UInt16, pressed: Bool) {
        guard let onKeyboardEvent else { return }
        if pressed {
            if !pressedControls.contains(.key(code)) { pressedControls.append(.key(code)) }
        } else {
            guard let index = pressedControls.firstIndex(of: .key(code)) else { return }
            pressedControls.remove(at: index)
        }
        onKeyboardEvent(code, pressed)
    }

    override func keyDown(with event: NSEvent) {
        reconcileKeyboardModifiers(event.modifierFlags)
        forwardKey(event.keyCode, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        forwardKey(event.keyCode, pressed: false)
        reconcileKeyboardModifiers(event.modifierFlags)
    }

    /// Focus may enter this view after a modifier was pressed, and synthesized
    /// key events may carry flags without a separate flagsChanged event. Emit
    /// the missing physical modifier events through the existing input binding.
    private func reconcileKeyboardModifiers(_ flags: NSEvent.ModifierFlags) {
        let groups: [(NSEvent.ModifierFlags, [UInt16])] = [
            (.shift, [56, 60]), (.control, [59, 62]), (.option, [58, 61]),
            (.command, [55, 54])
        ]
        for (flag, codes) in groups {
            let held = codes.filter { pressedControls.contains(.key($0)) }
            if flags.contains(flag) {
                if held.isEmpty, let code = codes.first { forwardKey(code, pressed: true) }
            } else {
                for code in held { forwardKey(code, pressed: false) }
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags
        let codes: [UInt16]
        switch event.keyCode {
        case 54, 55: flag = .command; codes = [54, 55]
        case 56, 60: flag = .shift; codes = [56, 60]
        case 58, 61: flag = .option; codes = [58, 61]
        case 59, 62: flag = .control; codes = [59, 62]
        case 63: flag = .function; codes = [63]
        case 57:
            forwardKey(57, pressed: true)
            forwardKey(57, pressed: false)
            return
        default: return
        }
        if event.modifierFlags.contains(flag) {
            forwardKey(event.keyCode, pressed: !pressedControls.contains(.key(event.keyCode)))
        } else {
            for code in codes { forwardKey(code, pressed: false) }
        }
    }

}

/// SwiftUI 包装的 MTKView，用于在屏幕上呈现远端 GPU 纹理。
/// - 设计遵循 Apple 官方在 MTKView 文档中的建议：迟取 drawable、在命令缓冲上注册呈现、
/// 使用显式绘制模式减少无效帧。
/// - 新增：完整的鼠标和键盘事件处理，支持远程桌面交互
struct RemoteDisplayView: NSViewRepresentable {
    let textureFeed: RemoteTextureFeed
    var mapsPointerToRemoteFrame = false
    
 /// 输入事件回调
    var onMouseEvent: ((CGPoint, NSEvent.EventType, Int) -> Void)?
    var onKeyboardEvent: ((UInt16, Bool) -> Void)?
    var onScrollEvent: ((CGFloat, CGFloat) -> Void)?

    func makeNSView(context: Context) -> InteractiveRemoteView {
        let view = InteractiveRemoteView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true                  // 显式绘制：仅在收到新纹理时绘制
        view.enableSetNeedsDisplay = true     // 使用 setNeedsDisplay 驱动，避免重入 draw()
        view.framebufferOnly = true           // 仅作为显示目标，提高驱动优化
        view.delegate = context.coordinator
        
        view.mapsPointerToRemoteFrame = mapsPointerToRemoteFrame
        view.prepareInputBinding(feed: textureFeed, hasKeyboardInput: onKeyboardEvent != nil, hasMouseInput: onMouseEvent != nil)
 // 设置输入事件回调
        view.onMouseEvent = onMouseEvent
        view.onKeyboardEvent = onKeyboardEvent
        view.onScrollEvent = onScrollEvent
        
        context.coordinator.attach(view: view, feed: textureFeed)
        return view
    }

    func updateNSView(_ nsView: InteractiveRemoteView, context: Context) {
        nsView.prepareInputBinding(feed: textureFeed, hasKeyboardInput: onKeyboardEvent != nil, hasMouseInput: onMouseEvent != nil)
        nsView.mapsPointerToRemoteFrame = mapsPointerToRemoteFrame
        context.coordinator.attach(view: nsView, feed: textureFeed)
 // 更新回调
        nsView.onMouseEvent = onMouseEvent
        nsView.onKeyboardEvent = onKeyboardEvent
        nsView.onScrollEvent = onScrollEvent
    }
    
    static func dismantleNSView(_ nsView: InteractiveRemoteView, coordinator: RendererCoordinator) {
 // 在视图销毁时清理资源
        nsView.releasePressedInput()
        coordinator.detach()
    }

    func makeCoordinator() -> RendererCoordinator {
        RendererCoordinator()
    }

 /// 渲染协调器：构建管线并在收到新纹理时编码一次全屏绘制。
    @MainActor
    final class RendererCoordinator: NSObject, MTKViewDelegate {
        private final class DeviceBox: @unchecked Sendable {
            let device: MTLDevice

            init(_ device: MTLDevice) {
                self.device = device
            }
        }

        private struct PipelineArtifacts: @unchecked Sendable {
            let commandQueue: MTLCommandQueue
            let pipelineState: MTLRenderPipelineState
        }

        private enum PipelineError: Error {
            case missingCommandQueue
            case missingShaderFunction
        }

        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private weak var view: MTKView?
        private weak var presentationFeed: RemoteTextureFeed?
        private var cancellable: AnyCancellable?
        private var pipelineBuildTask: Task<Void, Never>?
        private var attachedFeedID: ObjectIdentifier?
        private var latestFrame: RemoteTextureFrame?
        private var displayRequestPending = false

 /// 绑定 MTKView 与纹理发布者。
        func attach(view: MTKView, feed: RemoteTextureFeed) {
            self.view = view
            self.presentationFeed = feed
            let feedID = ObjectIdentifier(feed)
            guard attachedFeedID != feedID else { return }
            attachedFeedID = feedID
            cancellable?.cancel()
            latestFrame = nil
            displayRequestPending = false
            guard let device = view.device else {
                (view as? InteractiveRemoteView)?.showRenderingError()
                return
            }
            buildPipelineIfNeeded(device: device, pixelFormat: view.colorPixelFormat)

 // 订阅纹理更新：收到新纹理时触发一次显式绘制。
            cancellable = feed.$frame
                .receive(on: DispatchQueue.main)
                .sink { [weak self] frame in
                    guard let self = self else { return }
                    self.latestFrame = frame
                    (self.view as? InteractiveRemoteView)?.remoteFrameSize = frame.map {
                        CGSize(width: $0.texture.width, height: $0.texture.height)
                    } ?? .zero
                    guard let view = self.view, view.window != nil else { return }
                    if !self.displayRequestPending {
                        self.displayRequestPending = true
                        view.needsDisplay = true
                    }
                }
        }
        
        func detach() {
 // 手动清理订阅
            cancellable?.cancel()
            cancellable = nil
            attachedFeedID = nil
            latestFrame = nil
            presentationFeed = nil
            displayRequestPending = false
            pipelineBuildTask?.cancel()
            pipelineBuildTask = nil
            view?.delegate = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
 // 视图尺寸变化无需特殊处理；渲染为全屏矩形。
        }

        func draw(in view: MTKView) {
            displayRequestPending = false
            guard let commandQueue, let pipelineState else { return }
            guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
            guard let frame = latestFrame else { return }

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                (view as? InteractiveRemoteView)?.showRenderingError()
                return
            }
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(frame.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            // `present()`/`commit()` only submit work. The drawable callback is
            // the first boundary that proves this exact texture became visible.
            let presentationFeed = presentationFeed
            drawable.addPresentedHandler { [weak presentationFeed, frame] _ in
                Task { @MainActor [weak presentationFeed, frame] in
                    presentationFeed?.reportPresentedFrame(frame)
                }
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func buildPipelineIfNeeded(device: MTLDevice, pixelFormat: MTLPixelFormat) {
            guard pipelineState == nil, pipelineBuildTask == nil else { return }
            let deviceBox = DeviceBox(device)
            pipelineBuildTask = Task { @MainActor [weak self] in
                do {
                    let artifacts = try await Task.detached(priority: .userInitiated) {
                        let device = deviceBox.device
                        let library = try SkyBridgeMetalShaderLibrary.loadCore(
                            device: device,
                            sourceResourceNames: ["RemoteDesktopPassthrough"],
                            requiredFunctionNames: [
                                "fluidPassthroughVertex",
                                "fluidPassthroughFragment",
                            ]
                        )
                        guard let vertexFunction = library.makeFunction(name: "fluidPassthroughVertex"),
                              let fragmentFunction = library.makeFunction(name: "fluidPassthroughFragment") else {
                            throw PipelineError.missingShaderFunction
                        }
                        guard let commandQueue = device.makeCommandQueue() else {
                            throw PipelineError.missingCommandQueue
                        }
                        let descriptor = MTLRenderPipelineDescriptor()
                        descriptor.vertexFunction = vertexFunction
                        descriptor.fragmentFunction = fragmentFunction
                        descriptor.colorAttachments[0].pixelFormat = pixelFormat
                        let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
                        return PipelineArtifacts(
                            commandQueue: commandQueue,
                            pipelineState: pipelineState
                        )
                    }.value
                    guard !Task.isCancelled, let self else { return }
                    self.commandQueue = artifacts.commandQueue
                    self.pipelineState = artifacts.pipelineState
                    self.pipelineBuildTask = nil
                    (self.view as? InteractiveRemoteView)?.clearRenderingError()
                    if self.latestFrame != nil {
                        self.view?.needsDisplay = true
                    }
                } catch is CancellationError {
                    self?.pipelineBuildTask = nil
                } catch {
                    guard let self else { return }
                    self.pipelineBuildTask = nil
                    (self.view as? InteractiveRemoteView)?.showRenderingError()
                }
            }
        }
    }
}
