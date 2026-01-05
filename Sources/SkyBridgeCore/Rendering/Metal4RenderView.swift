import SwiftUI
import MetalKit
import Combine

/// Metal 4.0 渲染视图 - 提供实时渲染控制和性能监控
public struct Metal4RenderView: NSViewRepresentable {
    
 // MARK: - 绑定属性
    
    @Binding var renderingEnabled: Bool
    @Binding var aiInferenceEnabled: Bool
    @Binding var metalFXEnabled: Bool
    @Binding var frameInterpolationEnabled: Bool
    @Binding var rayTracingEnabled: Bool
    
 // MARK: - 配置
    
    let configuration: Metal4Engine.Configuration
    let weatherDataService: WeatherDataService
    
 // MARK: - 初始化

    public init(
        renderingEnabled: Binding<Bool> = .constant(true),
        aiInferenceEnabled: Binding<Bool> = .constant(true),
        metalFXEnabled: Binding<Bool> = .constant(true),
        frameInterpolationEnabled: Binding<Bool> = .constant(true),
        rayTracingEnabled: Binding<Bool> = .constant(false),
        configuration: Metal4Engine.Configuration = .default,
        weatherDataService: WeatherDataService
    ) {
        self._renderingEnabled = renderingEnabled
        self._aiInferenceEnabled = aiInferenceEnabled
        self._metalFXEnabled = metalFXEnabled
        self._frameInterpolationEnabled = frameInterpolationEnabled
        self._rayTracingEnabled = rayTracingEnabled
        self.configuration = configuration
        self.weatherDataService = weatherDataService
    }
    
 // MARK: - NSViewRepresentable 实现
    
    public func makeNSView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.delegate = context.coordinator
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.framebufferOnly = false
        
 // 设置Metal视图属性
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
 // 默认关闭MSAA（sampleCount=1），质量档再启用4x MSAA
        metalView.sampleCount = configuration.targetFrameRate <= 30 ? 4 : 1
        
 // 创建渲染器 - 优化错误处理
        let renderer = Metal4ViewRenderer(
            metalView: metalView,
            configuration: configuration,
            weatherDataService: weatherDataService
        )
        context.coordinator.renderer = renderer
        
 // 添加鼠标跟踪区域 - 增强版本
        let trackingArea = NSTrackingArea(
            rect: metalView.bounds,
            options: [
                .activeInKeyWindow,
                .mouseMoved,
                .mouseEnteredAndExited,
                .inVisibleRect
            ],
            owner: context.coordinator,
            userInfo: nil
        )
        metalView.addTrackingArea(trackingArea)
        
 // 设置鼠标事件处理
        context.coordinator.setupMouseEventHandling(for: metalView)
        
        return metalView
    }
    
    public func updateNSView(_ nsView: MTKView, context: Context) {
 // 更新渲染器设置
        if let renderer = context.coordinator.renderer {
            renderer.updateSettings(
                aiInferenceEnabled: aiInferenceEnabled,
                metalFXEnabled: metalFXEnabled,
                frameInterpolationEnabled: frameInterpolationEnabled,
                rayTracingEnabled: rayTracingEnabled
            )
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
 // MARK: - 协调器
    
    @MainActor
    public class Coordinator: NSObject, MTKViewDelegate {
        var renderer: Metal4ViewRenderer? // Metal 4.0 视图渲染器
        private var metalView: MTKView?
        private var isMousePressed: Bool = false // 保留原有的声明
        
        func setupMouseEventHandling(for view: MTKView) {
            self.metalView = view
        }
        
 // MARK: - MTKViewDelegate
        
        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
 // 处理视图大小变化
        }
        
        public func draw(in view: MTKView) {
 // 委托给renderer处理绘制
            renderer?.draw(in: view)
        }
        
 // MARK: - 鼠标事件处理
        
        func mouseMoved(with event: NSEvent) {
            let location = event.locationInWindow
            renderer?.handleMouseMoved(at: location)
        }

        func mouseDown(with event: NSEvent) {
            let location = event.locationInWindow
            isMousePressed = true
            renderer?.handleMousePressed(at: location, pressed: true)
        }

        func mouseUp(with event: NSEvent) {
            let location = event.locationInWindow
            isMousePressed = false
            renderer?.handleMousePressed(at: location, pressed: false)
        }

        func mouseDragged(with event: NSEvent) {
            let location = event.locationInWindow
            renderer?.handleMouseDragged(at: location)
        }

        func mouseEntered(with event: NSEvent) {
            let location = event.locationInWindow
            renderer?.handleMouseEntered(at: location)
        }

        func mouseExited(with event: NSEvent) {
            let location = event.locationInWindow
            renderer?.handleMouseExited(at: location)
        }
    }
}

// MARK: - Metal 4.0 视图渲染器

@MainActor
class Metal4ViewRenderer: NSObject, MTKViewDelegate {
    
 // MARK: - 属性
    
    private let metalEngine: Metal4Engine
    private let metalView: MTKView
    private let weatherDataService: WeatherDataService
    private var renderingEngine: Metal4RenderingEngine?
    
    private var viewMatrix: simd_float4x4 = matrix_identity_float4x4
    private var projectionMatrix: simd_float4x4 = matrix_identity_float4x4
    
    private var rotation: Float = 0.0
    private var lastUpdateTime: CFTimeInterval = 0.0
    
 // MARK: - 设置
    
    private var aiInferenceEnabled: Bool = true
    private var metalFXEnabled: Bool = true
    private var frameInterpolationEnabled: Bool = true
    private var rayTracingEnabled: Bool = false
    
 // MARK: - 初始化
    
    init(metalView: MTKView, configuration: Metal4Engine.Configuration, weatherDataService: WeatherDataService) {
        self.metalView = metalView
        self.weatherDataService = weatherDataService
        self.metalEngine = Metal4Engine()
        
        super.init()
        
 // 初始化渲染引擎
        self.renderingEngine = Metal4RenderingEngine(weatherDataService: weatherDataService)
 // 将FPS统计打通到Metal4Engine.renderingStats（2Hz发布）
        self.renderingEngine?.statsCallback = { [weak metalEngine] stats in
            Task { @MainActor in
                metalEngine?.renderingStats = stats
 // 通过通知中心向实际App导出FPS（DashboardView订阅显示）
                NotificationCenter.default.post(name: Notification.Name("MetalFPSUpdated"), object: nil, userInfo: ["fps": stats.formattedFPS])
            }
        }
        
        setupMatrices()
        
 // 异步初始化渲染引擎
        Task {
            await renderingEngine?.initializeMetal()
        }
    }
    
 // MARK: - 矩阵设置
    
    private func setupMatrices() {
 // 设置视图矩阵
        let eye = simd_float3(0, 0, 5)
        let center = simd_float3(0, 0, 0)
        let up = simd_float3(0, 1, 0)
        viewMatrix = lookAt(eye: eye, center: center, up: up)
        
 // 设置投影矩阵
        let aspect = Float(metalView.bounds.width / metalView.bounds.height)
        projectionMatrix = perspective(fovy: 45.0 * Float.pi / 180.0, aspect: aspect, near: 0.1, far: 100.0)
    }
    
 // MARK: - 设置更新
    
    func updateSettings(
        aiInferenceEnabled: Bool,
        metalFXEnabled: Bool,
        frameInterpolationEnabled: Bool,
        rayTracingEnabled: Bool
    ) {
        self.aiInferenceEnabled = aiInferenceEnabled
        self.metalFXEnabled = metalFXEnabled
        self.frameInterpolationEnabled = frameInterpolationEnabled
        self.rayTracingEnabled = rayTracingEnabled
        
 // 更新引擎设置
        metalEngine.aiInferenceEnabled = aiInferenceEnabled
        metalEngine.metalFXEnabled = metalFXEnabled
        metalEngine.frameInterpolationEnabled = frameInterpolationEnabled
    }
    
 // MARK: - MTKViewDelegate 实现
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
 // 更新投影矩阵
        let aspect = Float(size.width / size.height)
        projectionMatrix = perspective(fovy: 45.0 * Float.pi / 180.0, aspect: aspect, near: 0.1, far: 100.0)
    }
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderingEngine = renderingEngine else { return }
        
 // 更新动画
        updateAnimation()
        
 // 获取当前天气参数
        let weatherParams = weatherDataService.getWeatherRenderingParameters()
        
 // 执行渲染（同步链路，门闩控制丢帧，不阻塞UI）
        do {
            try renderingEngine.renderWeatherScene(
                parameters: weatherParams,
                to: drawable,
                viewportSize: view.drawableSize
            )
        } catch {
            SkyBridgeLogger.metal.error("渲染错误: \(error.localizedDescription, privacy: .private)")
        }
    }
    
 // MARK: - 鼠标事件处理
    
    func handleMouseMoved(at location: CGPoint) {
        renderingEngine?.updateMousePosition(location)
    }
    
    func handleMousePressed(at location: CGPoint, pressed: Bool) {
        renderingEngine?.updateMousePosition(location)
        renderingEngine?.setMousePressed(pressed)
    }
    
    func handleMouseDragged(at location: CGPoint) {
        renderingEngine?.updateMousePosition(location)
 // 拖拽时增强交互效果
        renderingEngine?.setMouseInteractionParameters(
            repelForce: 80.0,
            dispersionRadius: 200.0
        )
    }
    
    func handleMouseEntered(at location: CGPoint) {
        renderingEngine?.updateMousePosition(location)
 // 鼠标进入时启用交互效果
        renderingEngine?.setMouseInteractionParameters(
            influenceRadius: 120.0,
            mistBlurIntensity: 1.0
        )
    }
    
    func handleMouseExited(at location: CGPoint) {
        renderingEngine?.updateMousePosition(location)
 // 鼠标离开时减弱交互效果
        renderingEngine?.setMouseInteractionParameters(
            influenceRadius: 80.0,
            mistBlurIntensity: 0.5
        )
    }
    
 // MARK: - 动画更新
    
    private func updateAnimation() {
        let currentTime = CACurrentMediaTime()
        
        if lastUpdateTime == 0.0 {
            lastUpdateTime = currentTime
        }
        
        let deltaTime = Float(currentTime - lastUpdateTime)
        lastUpdateTime = currentTime
        
 // 更新旋转
        rotation += deltaTime * 0.5
        
 // 更新视图矩阵
        let rotationMatrix = simd_float4x4(rotationY: rotation)
        let eye = simd_float3(0, 0, 5)
        let center = simd_float3(0, 0, 0)
        let up = simd_float3(0, 1, 0)
        viewMatrix = lookAt(eye: eye, center: center, up: up) * rotationMatrix
    }
}

// MARK: - Metal 4.0 控制面板

public struct Metal4ControlPanel: View {
    
 // MARK: - 状态
    
    @StateObject private var metalEngine = Metal4Engine()
    @State private var selectedConfiguration: Metal4Engine.Configuration = .default
    @State private var showAdvancedSettings = false
    
 // MARK: - 渲染设置
    
    @State private var aiInferenceEnabled = true
    @State private var metalFXEnabled = true
    @State private var frameInterpolationEnabled = true
    @State private var rayTracingEnabled = false
    @State private var renderScale: Float = 0.75
    @State private var targetFrameRate = 60
    
 // 调试选项
    @State private var showWireframe = false
    @State private var showNormals = false
    @State private var showDepthBuffer = false
    
    public var body: some View {
        VStack(spacing: 20) {
 // 标题
            HStack {
                Image(systemName: "cpu.fill")
                    .foregroundColor(.blue)
                Text("Metal 4.0 渲染引擎")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                
 // 引擎状态指示器
                HStack(spacing: 8) {
                    Circle()
                        .fill(metalEngine.isInitialized ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(metalEngine.isInitialized ? "已初始化" : "初始化中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
 // 性能统计
            performanceStatsView
            
 // 渲染设置
            renderingSettingsView
            
 // 高级设置
            if showAdvancedSettings {
                advancedSettingsView
            }
            
 // 控制按钮
            controlButtonsView
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
    
 // MARK: - 性能统计视图
    
    private var performanceStatsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("性能统计")
                .font(.headline)
            
            HStack {
                VStack(alignment: .leading) {
                    Text("帧率")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(metalEngine.renderingStats.formattedFPS)
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                
                Spacer()
                
                VStack(alignment: .leading) {
                    Text("帧时间")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(metalEngine.renderingStats.formattedFrameTime)
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                
                Spacer()
                
                VStack(alignment: .leading) {
                    Text("三角形数")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(metalEngine.renderingStats.triangleCount)")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding()
        .background(Color(NSColor.separatorColor).opacity(0.3))
        .cornerRadius(8)
    }
    
 // MARK: - 渲染设置视图
    
    private var renderingSettingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("渲染设置")
                .font(.headline)
            
 // AI推理开关
            Toggle("AI推理增强", isOn: $aiInferenceEnabled)
                .onChange(of: aiInferenceEnabled) { _, newValue in
                    metalEngine.aiInferenceEnabled = newValue
                }
            
 // MetalFX开关
            Toggle("MetalFX上采样", isOn: $metalFXEnabled)
                .onChange(of: metalFXEnabled) { _, newValue in
                    metalEngine.metalFXEnabled = newValue
                }
            
 // 帧插值开关
            Toggle("帧插值", isOn: $frameInterpolationEnabled)
                .onChange(of: frameInterpolationEnabled) { _, newValue in
                    metalEngine.frameInterpolationEnabled = newValue
                }
            
 // 光线追踪开关
            Toggle("硬件光线追踪", isOn: $rayTracingEnabled)
            
 // 渲染比例滑块
            VStack(alignment: .leading) {
                Text("渲染比例: \(String(format: "%.0f%%", renderScale * 100))")
                    .font(.caption)
                Slider(value: $renderScale, in: 0.25...1.0, step: 0.05)
            }
            
 // 目标帧率选择
            VStack(alignment: .leading) {
                Text("目标帧率")
                    .font(.caption)
                Picker("目标帧率", selection: $targetFrameRate) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                    Text("120 FPS").tag(120)
                    Text("无限制").tag(0)
                }
                .pickerStyle(SegmentedPickerStyle())
            }
        }
    }
    
 // MARK: - 高级设置视图
    
    private var advancedSettingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("高级设置")
                .font(.headline)
            
 // 预设配置选择
            VStack(alignment: .leading) {
                Text("预设配置")
                    .font(.caption)
                Picker("预设配置", selection: $selectedConfiguration) {
                    Text("默认").tag(Metal4Engine.Configuration.default)
                    Text("性能优先").tag(Metal4Engine.Configuration.performance)
                    Text("质量优先").tag(Metal4Engine.Configuration.quality)
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            
 // GPU内存使用情况
            VStack(alignment: .leading) {
                Text("GPU内存使用")
                    .font(.caption)
                ProgressView(value: metalEngine.gpuMemoryUsage.percentage / 100.0)
                    .progressViewStyle(LinearProgressViewStyle())
                Text(formatGPUMemory(used: metalEngine.gpuMemoryUsage.used, total: metalEngine.gpuMemoryUsage.total))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
 // 调试选项
            VStack(alignment: .leading) {
                Text("调试选项")
                    .font(.caption)
                
                Toggle("显示线框", isOn: $showWireframe)
                    .onChange(of: showWireframe) { _, _ in
                        metalEngine.updateDebugFlags(
                            showWireframe: showWireframe,
                            showNormals: showNormals,
                            showDepth: showDepthBuffer
                        )
                    }
                Toggle("显示法线", isOn: $showNormals)
                    .onChange(of: showNormals) { _, _ in
                        metalEngine.updateDebugFlags(
                            showWireframe: showWireframe,
                            showNormals: showNormals,
                            showDepth: showDepthBuffer
                        )
                    }
                Toggle("显示深度缓冲", isOn: $showDepthBuffer)
                    .onChange(of: showDepthBuffer) { _, _ in
                        metalEngine.updateDebugFlags(
                            showWireframe: showWireframe,
                            showNormals: showNormals,
                            showDepth: showDepthBuffer
                        )
                    }
            }
        }
        .padding()
        .background(Color(NSColor.separatorColor).opacity(0.2))
        .cornerRadius(8)
    }
    
 // MARK: - 控制按钮视图
    
    private var controlButtonsView: some View {
        HStack {
            Button(action: {
                showAdvancedSettings.toggle()
            }) {
                HStack {
                    Image(systemName: showAdvancedSettings ? "chevron.up" : "chevron.down")
                    Text(showAdvancedSettings ? "隐藏高级设置" : "显示高级设置")
                }
            }
            .buttonStyle(BorderedButtonStyle())
            
            Spacer()
            
            Button("重置设置") {
                resetToDefaults()
            }
            .buttonStyle(BorderedButtonStyle())
            
            Button("应用配置") {
                applyConfiguration()
            }
            .buttonStyle(BorderedProminentButtonStyle())
        }
    }
    
 // MARK: - 操作方法
    
    private func resetToDefaults() {
        aiInferenceEnabled = true
        metalFXEnabled = true
        frameInterpolationEnabled = true
        rayTracingEnabled = false
        renderScale = 0.75
        targetFrameRate = 60
        selectedConfiguration = .default
    }
    
    private func applyConfiguration() {
 // 应用新配置到引擎
        metalEngine.aiInferenceEnabled = aiInferenceEnabled
        metalEngine.metalFXEnabled = metalFXEnabled
        metalEngine.frameInterpolationEnabled = frameInterpolationEnabled
        
        SkyBridgeLogger.metal.debugOnly("Metal 4.0配置已应用")
    }
    
 // MARK: - 格式化方法
    
    private func formatGPUMemory(used: Int64, total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        
        let usedStr = formatter.string(fromByteCount: used)
        let totalStr = formatter.string(fromByteCount: total)
        
        return "\(usedStr) / \(totalStr)"
    }
}

// MARK: - 矩阵工具函数

func lookAt(eye: simd_float3, center: simd_float3, up: simd_float3) -> simd_float4x4 {
    let z = normalize(eye - center)
    let x = normalize(cross(up, z))
    let y = cross(z, x)
    
    return simd_float4x4(
        simd_float4(x.x, y.x, z.x, 0),
        simd_float4(x.y, y.y, z.y, 0),
        simd_float4(x.z, y.z, z.z, 0),
        simd_float4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
    )
}

func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let f = 1.0 / tan(fovy * 0.5)
    
    return simd_float4x4(
        simd_float4(f / aspect, 0, 0, 0),
        simd_float4(0, f, 0, 0),
        simd_float4(0, 0, (far + near) / (near - far), -1),
        simd_float4(0, 0, (2 * far * near) / (near - far), 0)
    )
}

extension simd_float4x4 {
    init(rotationY angle: Float) {
        let c = cos(angle)
        let s = sin(angle)
        
        self.init(
            simd_float4(c, 0, s, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(-s, 0, c, 0),
            simd_float4(0, 0, 0, 1)
        )
    }
}

// MARK: - 预览

#if DEBUG
struct Metal4RenderView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Metal4RenderView(weatherDataService: WeatherDataService())
                .frame(height: 400)
            
            Metal4ControlPanel()
        }
        .padding()
    }
}
#endif
