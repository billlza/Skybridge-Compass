import SwiftUI
@preconcurrency import Metal
import MetalKit
import Combine
import os.log
import SkyBridgeCore

/// 支持输入事件的交互式远程显示视图
class InteractiveRemoteView: MTKView {
 /// 输入事件回调
    var onMouseEvent: ((CGPoint, NSEvent.EventType, Int) -> Void)?
    var onKeyboardEvent: ((UInt16, Bool) -> Void)?
    var onScrollEvent: ((CGFloat, CGFloat) -> Void)?
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "RemoteInput")
    private var renderingErrorLabel: NSTextField?
    
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    
    override func awakeFromNib() {
        super.awakeFromNib()
        Task { @MainActor in
            setupInputTracking()
        }
    }
    
    @MainActor
    private func setupInputTracking() {
 // 启用鼠标跟踪
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        
        logger.info("🖱️ 远程显示视图输入跟踪已启用")
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
    
 // MARK: - 鼠标事件处理
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .leftMouseDown, Int(event.buttonNumber))
    }
    
    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .leftMouseUp, Int(event.buttonNumber))
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .rightMouseDown, Int(event.buttonNumber))
    }
    
    override func rightMouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .rightMouseUp, Int(event.buttonNumber))
    }
    
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .mouseMoved, 0)
    }
    
    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .leftMouseDragged, Int(event.buttonNumber))
    }
    
    override func rightMouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .rightMouseDragged, Int(event.buttonNumber))
    }
    
    override func scrollWheel(with event: NSEvent) {
        onScrollEvent?(event.scrollingDeltaX, event.scrollingDeltaY)
    }
    
 // MARK: - 键盘事件处理
    
    override func keyDown(with event: NSEvent) {
        onKeyboardEvent?(event.keyCode, true)
    }
    
    override func keyUp(with event: NSEvent) {
        onKeyboardEvent?(event.keyCode, false)
    }
    
    override func flagsChanged(with event: NSEvent) {
 // 处理修饰键变化（Shift、Ctrl、Alt、Cmd等）
        let modifierFlags = event.modifierFlags
        
 // 可以根据需要处理特定的修饰键
        if modifierFlags.contains(.shift) {
 // Shift键状态变化
        }
        if modifierFlags.contains(.control) {
 // Control键状态变化
        }
        if modifierFlags.contains(.option) {
 // Option键状态变化
        }
        if modifierFlags.contains(.command) {
 // Command键状态变化
        }
    }
}

/// SwiftUI 包装的 MTKView，用于在屏幕上呈现远端 GPU 纹理。
/// - 设计遵循 Apple 官方在 MTKView 文档中的建议：迟取 drawable、在命令缓冲上注册呈现、
/// 使用显式绘制模式减少无效帧。
/// - 新增：完整的鼠标和键盘事件处理，支持远程桌面交互
struct RemoteDisplayView: NSViewRepresentable {
    let textureFeed: RemoteTextureFeed
    
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
        
 // 设置输入事件回调
        view.onMouseEvent = onMouseEvent
        view.onKeyboardEvent = onKeyboardEvent
        view.onScrollEvent = onScrollEvent
        
        context.coordinator.attach(view: view, feed: textureFeed)
        return view
    }

    func updateNSView(_ nsView: InteractiveRemoteView, context: Context) {
        context.coordinator.attach(view: nsView, feed: textureFeed)
 // 更新回调
        nsView.onMouseEvent = onMouseEvent
        nsView.onKeyboardEvent = onKeyboardEvent
        nsView.onScrollEvent = onScrollEvent
    }
    
    static func dismantleNSView(_ nsView: InteractiveRemoteView, coordinator: RendererCoordinator) {
 // 在视图销毁时清理资源
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
