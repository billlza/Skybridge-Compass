import SwiftUI
import Metal
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
    
 // MARK: - 鼠标事件处理
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .leftMouseDown, Int(event.buttonNumber))
        logger.debug("🖱️ 鼠标按下: (\(location.x), \(location.y))")
    }
    
    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .leftMouseUp, Int(event.buttonNumber))
        logger.debug("🖱️ 鼠标释放: (\(location.x), \(location.y))")
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .rightMouseDown, Int(event.buttonNumber))
        logger.debug("🖱️ 右键按下: (\(location.x), \(location.y))")
    }
    
    override func rightMouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseEvent?(location, .rightMouseUp, Int(event.buttonNumber))
        logger.debug("🖱️ 右键释放: (\(location.x), \(location.y))")
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
        logger.debug("🎡 滚轮事件: dx=\(event.scrollingDeltaX), dy=\(event.scrollingDeltaY)")
    }
    
 // MARK: - 键盘事件处理
    
    override func keyDown(with event: NSEvent) {
        onKeyboardEvent?(event.keyCode, true)
        logger.debug("⌨️ 按键按下: \(event.keyCode)")
    }
    
    override func keyUp(with event: NSEvent) {
        onKeyboardEvent?(event.keyCode, false)
        logger.debug("⌨️ 按键释放: \(event.keyCode)")
    }
    
    override func flagsChanged(with event: NSEvent) {
 // 处理修饰键变化（Shift、Ctrl、Alt、Cmd等）
        let modifierFlags = event.modifierFlags
        logger.debug("🔧 修饰键变化: \(modifierFlags.rawValue)")
        
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
        view.enableSetNeedsDisplay = false    // 不使用 setNeedsDisplay 驱动
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
        private var device: MTLDevice!
        private var commandQueue: MTLCommandQueue!
        private var pipelineState: MTLRenderPipelineState!
        private var vertexBuffer: MTLBuffer!
        private weak var view: MTKView?
        private var cancellable: AnyCancellable?
        private var latestTexture: MTLTexture?

 /// 绑定 MTKView 与纹理发布者。
        func attach(view: MTKView, feed: RemoteTextureFeed) {
            self.view = view
            guard let device = view.device else { return }
            self.device = device
            self.commandQueue = device.makeCommandQueue()

 // 运行时编译着色器库。若迁移到 Xcode App 目标，可改为 makeDefaultLibrary() 加载 .metal 文件。
            let shaderSource = Self.basicShaderSource
            let library = try? device.makeLibrary(source: shaderSource, options: nil)
            let vertexFunc = library?.makeFunction(name: "passthroughVertex")
            let fragmentFunc = library?.makeFunction(name: "blitFragment")

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)

 // 全屏矩形（两三角），NDC 坐标与纹理坐标。
            struct Vertex { var pos: SIMD2<Float>; var uv: SIMD2<Float> }
            let quad: [Vertex] = [
                Vertex(pos: [-1, -1], uv: [0, 1]),
                Vertex(pos: [ 1, -1], uv: [1, 1]),
                Vertex(pos: [-1,  1], uv: [0, 0]),
                Vertex(pos: [-1,  1], uv: [0, 0]),
                Vertex(pos: [ 1, -1], uv: [1, 1]),
                Vertex(pos: [ 1,  1], uv: [1, 0])
            ]
            vertexBuffer = device.makeBuffer(bytes: quad, length: MemoryLayout<Vertex>.stride * quad.count, options: .storageModeShared)

 // 订阅纹理更新：收到新纹理时触发一次显式绘制。
            cancellable = feed.$texture
                .receive(on: DispatchQueue.main)
                .sink { [weak self] (tex: MTLTexture?) in
                    guard let self = self else { return }
                    self.latestTexture = tex
                    self.view?.draw()
                }
        }
        
        func detach() {
 // 手动清理订阅
            cancellable?.cancel()
            cancellable = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
 // 视图尺寸变化无需特殊处理；渲染为全屏矩形。
        }

        func draw(in view: MTKView) {
            guard let commandQueue, let pipelineState else { return }
            guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }

            let commandBuffer = commandQueue.makeCommandBuffer()
            let encoder = commandBuffer?.makeRenderCommandEncoder(descriptor: descriptor)
            encoder?.setRenderPipelineState(pipelineState)
            encoder?.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            if let texture = latestTexture {
                encoder?.setFragmentTexture(texture, index: 0)
            }
            encoder?.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder?.endEncoding()

 // 注册呈现并提交命令缓冲，遵循 MTKView 文档的推荐流程。
            commandBuffer?.present(drawable)
            commandBuffer?.commit()
        }

 /// 基本着色器：直通顶点 + 采样片段，将远端纹理贴到屏幕。
        private static let basicShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
        struct VSOut { float4 position [[position]]; float2 uv; };

        vertex VSOut passthroughVertex(uint vid [[vertex_id]], const device VertexIn* vertices [[buffer(0)]]) {
            VSOut out;
            out.position = float4(vertices[vid].pos, 0.0, 1.0);
            out.uv = vertices[vid].uv;
            return out;
        }

        fragment float4 blitFragment(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            return tex.sample(s, in.uv);
        }
        """
    }
}