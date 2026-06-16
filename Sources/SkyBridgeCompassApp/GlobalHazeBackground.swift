import SwiftUI
import Metal
import MetalKit
import SkyBridgeCore

/// 全页面雾霾背景视图
/// 支持鼠标悬停驱散效果，无需点击
/// 全页面雾霾背景视图，新增对交互式驱散管理器的绑定，
/// 通过 clearManager.globalOpacity 控制整体透明度，从而在挥动时逐步露出底层星空背景。
struct GlobalHazeBackground: View {
    @ObservedObject var clearManager: InteractiveClearManager
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject var bgControl = BackgroundControlManager.shared
    
    @StateObject private var renderer = GlobalHazeRenderer()
    @State private var mouseLocation: CGPoint = .zero
    @State private var isMouseInside = false
    
    var body: some View {
        GeometryReader { geometry in
            MetalView(
                renderer: renderer,
                clearManager: clearManager,
                settingsManager: settingsManager,
                bgControl: bgControl
            )
                .onAppear {
                    renderer.setupMetal(size: geometry.size)
 // Release模式不打印调试信息
                }
                .onChange(of: geometry.size) { _, newSize in
                    renderer.updateSize(newSize)
                }
 // 联动交互式驱散的全局透明度，传递到Metal着色器。
                .onReceive(clearManager.$globalOpacity) { newOpacity in
                    renderer.updateGlobalOpacity(newOpacity)
                }
 // 鼠标位置改为在每帧采样，移除通知依赖，降低延迟与丢事件概率
                .onAppear {
 // 确保交互式清除管理器启动更新循环，实现透明度平滑插值与能量恢复。
        Task { @MainActor in
 // start() 为同步方法，这里在主线程直接调用即可。
            clearManager.start()
        }
                }
        }
        .ignoresSafeArea(.all) // 覆盖整个窗口
    }
}

/// 全页面雾霾渲染器
@MainActor
class GlobalHazeRenderer: ObservableObject {
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var renderPipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    
    private var currentSize: CGSize = .zero
    private var mousePosition: SIMD2<Float> = SIMD2<Float>(0, 0)
    private var isMouseActive: Bool = false
    private var lastMouseUpdateTime: CFTimeInterval = 0

 // 雾霾参数
    private var hazeIntensity: Float = 0.8
    private var disperseRadius: Float = 100.0
    private var disperseStrength: Float = 2.0
 // 新增全局透明度（0=完全透明，1=完全不透明），由交互管理器驱动。
    private var globalOpacity: Float = 1.0
    
    func setupMetal(size: CGSize) {
        guard let device = MTLCreateSystemDefaultDevice() else {
 // Release模式不打印调试信息
            return
        }
        
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        self.currentSize = size
        
        setupRenderPipeline()
        setupBuffers()
        
 // Release模式不打印调试信息
    }
    
    private func setupRenderPipeline() {
        guard let device = device else { return }
        
        guard let library = SkyBridgeMetalShaderLibrary.loadIfAvailable(
            device: device,
            bundle: Bundle.module,
            sourceResourceNames: ["GlobalHazeShaders"],
            requiredFunctionNames: [
                "globalHazeVertexShader",
                "globalHazeFragmentShader"
            ]
        ) else {
 // Release模式不打印调试信息
            return
        }
        
 // Release模式不打印调试信息
        
        guard let vertexFunction = library.makeFunction(name: "globalHazeVertexShader") else {
 // Release模式不打印调试信息
 // Release模式不打印调试信息
 // Release模式不打印调试信息
            return
        }
        
        guard let fragmentFunction = library.makeFunction(name: "globalHazeFragmentShader") else {
 // Release模式不打印调试信息
            return
        }
        
 // Release模式不打印调试信息
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
 // Release模式不打印调试信息
        }
    }
    
    private func setupBuffers() {
        guard let device = device else { return }
        
 // 全屏四边形顶点
        let vertices: [Float] = [
            -1.0, -1.0, 0.0, 1.0,  // 左下
             1.0, -1.0, 1.0, 1.0,  // 右下
            -1.0,  1.0, 0.0, 0.0,  // 左上
             1.0,  1.0, 1.0, 0.0   // 右上
        ]
        
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.size, options: [])
        uniformBuffer = device.makeBuffer(length: MemoryLayout<GlobalHazeUniforms>.size, options: [])
    }
    
    func updateSize(_ size: CGSize) {
        currentSize = size
    }
    
    func updateMousePosition(_ position: CGPoint, isActive: Bool) {
        let w = max(currentSize.width, 1)
        let h = max(currentSize.height, 1)
        var nx = Float(position.x / w)
        var ny = Float(1.0 - position.y / h)
        nx = min(max(nx, 0), 1)
        ny = min(max(ny, 0), 1)
        mousePosition = SIMD2<Float>(nx, ny)
        isMouseActive = isActive && nx >= 0 && nx <= 1 && ny >= 0 && ny <= 1
        lastMouseUpdateTime = CACurrentMediaTime()
    }
    
 /// 更新全局透明度（由交互驱散系统提供），用于在片段着色器中衰减雾霾不透明度。
    func updateGlobalOpacity(_ value: Double) {
        globalOpacity = Float(max(0.0, min(1.0, value)))
 // 调试输出节流可在此添加，如需：logger.debugOnly("🌫️ 全局透明度更新")
    }
    
    func render(in view: MTKView) {
        guard device != nil,
              let commandQueue = commandQueue,
              let renderPipelineState = renderPipelineState,
              let vertexBuffer = vertexBuffer,
              let uniformBuffer = uniformBuffer,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }
        
 // 更新鼠标活动状态（最近250ms未更新则视为不活动）
        let now = CACurrentMediaTime()
        if now - lastMouseUpdateTime > 0.25 {
            isMouseActive = false
        }
 // 更新uniform数据
        let uniforms = GlobalHazeUniforms(
            resolution: SIMD2<Float>(Float(currentSize.width), Float(currentSize.height)),
            mousePosition: mousePosition,
            isMouseActive: isMouseActive ? 1 : 0,
            hazeIntensity: hazeIntensity,
            disperseRadius: disperseRadius,
            disperseStrength: disperseStrength,
            time: Float(CACurrentMediaTime()),
            globalOpacity: globalOpacity
        )
        
        let uniformBufferPointer = uniformBuffer.contents().bindMemory(to: GlobalHazeUniforms.self, capacity: 1)
        uniformBufferPointer.pointee = uniforms
        
        let commandBuffer = commandQueue.makeCommandBuffer()
        let renderEncoder = commandBuffer?.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        
        renderEncoder?.setRenderPipelineState(renderPipelineState)
        renderEncoder?.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder?.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        renderEncoder?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder?.endEncoding()
        
        commandBuffer?.present(drawable)
        commandBuffer?.commit()
    }

    func updateDisperseParameters(radiusPixels: CGFloat, strength: Float) {
        let maxDim = max(currentSize.width, currentSize.height)
        if maxDim > 0 {
            let uv = Float(radiusPixels / maxDim)
            disperseRadius = max(uv, 1e-5)
        }
        disperseStrength = strength
    }
}

/// 全页面雾霾uniform数据结构
struct GlobalHazeUniforms {
    var resolution: SIMD2<Float>
    var mousePosition: SIMD2<Float>
    var isMouseActive: Int32
    var hazeIntensity: Float
    var disperseRadius: Float
    var disperseStrength: Float
    var time: Float
 // 新增全局驱散透明度，控制整体雾霾的不透明度，用于露出底层背景。
    var globalOpacity: Float
}

/// Metal视图包装器
struct MetalView: NSViewRepresentable {
    let renderer: GlobalHazeRenderer
    let clearManager: InteractiveClearManager
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var bgControl: BackgroundControlManager
    
    func makeNSView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.delegate = context.coordinator
        metalView.preferredFramesPerSecond = Int(settingsManager.performanceMode.targetFPS)
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.framebufferOnly = false
        metalView.layer?.isOpaque = false
        return metalView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
 // 根据性能模式和闲置状态动态调整帧率
        let baseFPS = settingsManager.performanceMode.targetFPS
        let effectiveFPS = bgControl.getEffectiveFPS(base: baseFPS)
        
        nsView.preferredFramesPerSecond = Int(effectiveFPS)
        
 // 根据背景控制器的状态暂停或恢复渲染
        nsView.isPaused = bgControl.isPaused
        
 // 应用背景控制器的透明度（用于天气出现时的淡出）
 // 注意：这里叠加了clearManager的驱散透明度，后者在Coordinator中处理
        nsView.alphaValue = bgControl.backgroundOpacity
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer, clearManager: clearManager)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        let renderer: GlobalHazeRenderer
        weak var clearManager: InteractiveClearManager?
        
        init(renderer: GlobalHazeRenderer, clearManager: InteractiveClearManager) {
            self.renderer = renderer
            self.clearManager = clearManager
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer.updateSize(size)
        }
        
        func draw(in view: MTKView) {
            if let window = view.window, let contentView = window.contentView {
                let wp = window.mouseLocationOutsideOfEventStream
                let vp = view.convert(wp, from: contentView)
                let inside = view.bounds.contains(vp)
                let ds = view.drawableSize
                let bs = view.bounds.size
                if ds.width > 0 && ds.height > 0 && bs.width > 0 && bs.height > 0 {
                    let nxRaw = vp.x / bs.width
                    let nyRaw = vp.y / bs.height
                    let nx = Float(min(max(nxRaw, 0), 1))
                    let nyInv = Float(min(max(1.0 - nyRaw, 0), 1))
                    let px = CGFloat(nx) * ds.width
                    let py = CGFloat(nyInv) * ds.height
                    renderer.updateMousePosition(CGPoint(x: px, y: py), isActive: inside)
                    if let cm = clearManager {
                        let rp = cm.currentDisperseRadiusPixels()
                        let st = cm.currentDisperseStrength()
                        renderer.updateDisperseParameters(radiusPixels: rp, strength: st)
                        let scale = window.backingScaleFactor
                        cm.handleMouseMove(CGPoint(x: vp.x * scale, y: vp.y * scale))
                    }
                }
            }
            renderer.render(in: view)
        }
    }
}
