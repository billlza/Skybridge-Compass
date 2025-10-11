import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreVideo
import Metal
import MetalKit
import AVFoundation
import Accelerate

/// 高性能屏幕捕获引擎 - 使用ScreenCaptureKit实现硬件加速的屏幕捕获
@MainActor
public class ScreenCaptureEngine: NSObject, ObservableObject {
    
    // MARK: - 发布的属性
    @Published public var isCapturing = false
    @Published public var captureFrameRate: Double = 0
    @Published public var captureResolution: CGSize = .zero
    @Published public var availableDisplays: [SCDisplay] = []
    @Published public var availableWindows: [SCWindow] = []
    @Published public var selectedDisplay: SCDisplay?
    @Published public var selectedWindows: Set<SCWindow> = []
    
    // MARK: - 私有属性
    private var captureEngine: SCStreamConfiguration?
    private var stream: SCStream?
    private var streamOutput: ScreenCaptureStreamOutput?
    private var metalDevice: MTLDevice
    private var metalCommandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache
    
    // 捕获配置
    private var currentConfiguration: ScreenCaptureConfiguration
    private var frameCallback: ((CVPixelBuffer, CFTimeInterval) -> Void)?
    
    // 性能监控
    private var frameCount: UInt64 = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var performanceTimer: Timer?
    
    // 缓冲区管理
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferAttributes: [String: Any] = [:]
    
    // MARK: - 初始化
    
    public init(metalDevice: MTLDevice) throws {
        self.metalDevice = metalDevice
        
        guard let commandQueue = metalDevice.makeCommandQueue() else {
            throw ScreenCaptureError.metalCommandQueueCreationFailed
        }
        self.metalCommandQueue = commandQueue
        
        // 创建Metal纹理缓存
        var textureCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            metalDevice,
            nil,
            &textureCache
        )
        
        guard status == kCVReturnSuccess, let cache = textureCache else {
            throw ScreenCaptureError.textureCacheCreationFailed
        }
        self.textureCache = cache
        
        // 初始化默认配置
        self.currentConfiguration = ScreenCaptureConfiguration.defaultConfiguration()
        
        super.init()
        
        // 初始化像素缓冲区属性
        setupPixelBufferAttributes()
        
        print("🎥 屏幕捕获引擎初始化完成")
        print("📱 Metal设备: \(metalDevice.name)")
    }
    
    deinit {
        // 在deinit中不能访问非Sendable类型的属性
        // 系统会自动清理这些资源
    }
    
    // MARK: - 公共方法
    
    /// 获取可用的显示器和窗口
    public func refreshAvailableContent() async throws {
        print("🔍 刷新可用的显示器和窗口")
        
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            
            await MainActor.run {
                self.availableDisplays = content.displays
                self.availableWindows = content.windows
                
                // 如果没有选择显示器，默认选择主显示器
                if selectedDisplay == nil, let mainDisplay = content.displays.first {
                    selectedDisplay = mainDisplay
                }
            }
            
            print("✅ 发现 \(content.displays.count) 个显示器，\(content.windows.count) 个窗口")
            
        } catch {
            print("❌ 获取可共享内容失败: \(error)")
            throw ScreenCaptureError.contentDiscoveryFailed(error)
        }
    }
    
    /// 配置屏幕捕获
    public func configure(with configuration: ScreenCaptureConfiguration) async throws {
        print("⚙️ 配置屏幕捕获")
        print("📐 分辨率: \(configuration.captureResolution.width)x\(configuration.captureResolution.height)")
        print("🎯 帧率: \(configuration.frameRate) fps")
        print("🎨 像素格式: \(configuration.pixelFormat)")
        print("🔧 硬件加速: \(configuration.enableHardwareAcceleration ? "启用" : "禁用")")
        
        self.currentConfiguration = configuration
        
        // 更新像素缓冲区配置
        setupPixelBufferAttributes()
        try createPixelBufferPool()
        
        // 如果正在捕获，重新启动以应用新配置
        if isCapturing {
            try await restartCapture()
        }
    }
    
    /// 开始屏幕捕获
    public func startCapture(callback: @escaping (CVPixelBuffer, CFTimeInterval) -> Void) async throws {
        guard !isCapturing else {
            print("⚠️ 屏幕捕获已在运行")
            return
        }
        
        print("🚀 开始屏幕捕获")
        
        // 确保有可用内容
        if availableDisplays.isEmpty {
            try await refreshAvailableContent()
        }
        
        guard let display = selectedDisplay else {
            throw ScreenCaptureError.noDisplaySelected
        }
        
        self.frameCallback = callback
        
        // 创建捕获配置
        let streamConfiguration = SCStreamConfiguration()
        
        // 设置基本参数
        streamConfiguration.width = Int(currentConfiguration.captureResolution.width)
        streamConfiguration.height = Int(currentConfiguration.captureResolution.height)
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(currentConfiguration.frameRate)
        )
        
        // 设置像素格式
        streamConfiguration.pixelFormat = currentConfiguration.pixelFormat.osType
        
        // 设置颜色空间
        if let colorSpace = currentConfiguration.colorSpace,
           let colorSpaceName = colorSpace.name {
            streamConfiguration.colorSpaceName = colorSpaceName
        }
        
        // 设置硬件加速
        if currentConfiguration.enableHardwareAcceleration {
            streamConfiguration.queueDepth = 6 // 增加队列深度以提高性能
        }
        
        // 设置显示内容过滤器
        let contentFilter: SCContentFilter
        if selectedWindows.isEmpty {
            // 捕获整个显示器
            contentFilter = SCContentFilter(display: display, excludingWindows: [])
            print("📺 捕获整个显示器: \(display.displayID)")
        } else {
            // 捕获特定窗口
            contentFilter = SCContentFilter(display: display, including: Array(selectedWindows))
            print("🪟 捕获 \(selectedWindows.count) 个窗口")
        }
        
        // 创建流输出处理器
        streamOutput = ScreenCaptureStreamOutput(
            textureCache: textureCache,
            metalDevice: metalDevice,
            frameCallback: { [weak self] pixelBuffer, timestamp in
                Task { @MainActor in
                    self?.handleCapturedFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
                }
            }
        )
        
        guard let streamOutput = streamOutput else {
            throw ScreenCaptureError.streamOutputCreationFailed
        }
        
        // 创建并启动流
        do {
            stream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: self)
            
            guard let stream = stream else {
                throw ScreenCaptureError.streamCreationFailed
            }
            
            try await stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            
            isCapturing = true
            captureResolution = currentConfiguration.captureResolution
            
            // 开始性能监控
            startPerformanceMonitoring()
            
            print("✅ 屏幕捕获已启动")
            
        } catch {
            print("❌ 启动屏幕捕获失败: \(error)")
            throw ScreenCaptureError.captureStartFailed(error)
        }
    }
    
    /// 停止屏幕捕获
    public func stopCapture() {
        guard isCapturing else { return }
        
        print("⏹️ 停止屏幕捕获")
        
        Task {
            do {
                if let stream = stream {
                    try await stream.stopCapture()
                }
            } catch {
                print("⚠️ 停止捕获时出错: \(error)")
            }
            
            await MainActor.run {
                self.stream = nil
                self.streamOutput = nil
                self.frameCallback = nil
                self.isCapturing = false
                self.captureFrameRate = 0
                
                // 停止性能监控
                self.stopPerformanceMonitoring()
                
                print("✅ 屏幕捕获已停止")
            }
        }
    }
    
    /// 暂停捕获
    public func pauseCapture() async throws {
        guard isCapturing, let stream = stream else { return }
        
        print("⏸️ 暂停屏幕捕获")
        try await stream.stopCapture()
    }
    
    /// 恢复捕获
    public func resumeCapture() async throws {
        guard let stream = stream else { return }
        
        print("▶️ 恢复屏幕捕获")
        try await stream.startCapture()
    }
    
    /// 更新捕获区域
    public func updateCaptureArea(_ area: CGRect) async throws {
        print("📐 更新捕获区域: \(area)")
        
        currentConfiguration.captureArea = area
        
        if isCapturing {
            try await restartCapture()
        }
    }
    
    /// 选择显示器
    public func selectDisplay(_ display: SCDisplay) {
        print("📺 选择显示器: \(display.displayID)")
        selectedDisplay = display
        selectedWindows.removeAll() // 清除窗口选择
    }
    
    /// 选择窗口
    public func selectWindows(_ windows: Set<SCWindow>) {
        print("🪟 选择窗口: \(windows.count) 个")
        selectedWindows = windows
    }
    
    /// 添加窗口到选择
    public func addWindow(_ window: SCWindow) {
        selectedWindows.insert(window)
        print("➕ 添加窗口: \(window.title ?? "未知窗口")")
    }
    
    /// 从选择中移除窗口
    public func removeWindow(_ window: SCWindow) {
        selectedWindows.remove(window)
        print("➖ 移除窗口: \(window.title ?? "未知窗口")")
    }
    
    // MARK: - 私有方法
    
    /// 重新启动捕获
    private func restartCapture() async throws {
        guard let callback = frameCallback else { return }
        
        print("🔄 重新启动屏幕捕获")
        
        stopCapture()
        
        // 等待停止完成
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        try await startCapture(callback: callback)
    }
    
    /// 设置像素缓冲区属性
    private func setupPixelBufferAttributes() {
        pixelBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: currentConfiguration.pixelFormat.osType,
            kCVPixelBufferWidthKey as String: Int(currentConfiguration.captureResolution.width),
            kCVPixelBufferHeightKey as String: Int(currentConfiguration.captureResolution.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        // 如果启用硬件加速，添加相关属性
        if currentConfiguration.enableHardwareAcceleration {
            pixelBufferAttributes[kCVPixelBufferOpenGLCompatibilityKey as String] = true
        }
    }
    
    /// 创建像素缓冲区池
    private func createPixelBufferPool() throws {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 6,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 0
        ]
        
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        
        guard status == kCVReturnSuccess, let pool = pool else {
            throw ScreenCaptureError.pixelBufferPoolCreationFailed
        }
        
        self.pixelBufferPool = pool
        print("✅ 像素缓冲区池创建完成")
    }
    
    /// 处理捕获的帧
    private func handleCapturedFrame(pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval) {
        frameCount += 1
        
        // 应用捕获区域裁剪（如果需要）
        let processedBuffer: CVPixelBuffer
        if let captureArea = currentConfiguration.captureArea {
            processedBuffer = cropPixelBuffer(pixelBuffer, to: captureArea) ?? pixelBuffer
        } else {
            processedBuffer = pixelBuffer
        }
        
        // 调用回调
        frameCallback?(processedBuffer, timestamp)
    }
    
    /// 裁剪像素缓冲区
    private func cropPixelBuffer(_ pixelBuffer: CVPixelBuffer, to rect: CGRect) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        
        // 计算裁剪区域
        let cropX = Int(rect.origin.x * CGFloat(sourceWidth))
        let cropY = Int(rect.origin.y * CGFloat(sourceHeight))
        let cropWidth = Int(rect.size.width * CGFloat(sourceWidth))
        let cropHeight = Int(rect.size.height * CGFloat(sourceHeight))
        
        // 边界检查
        guard cropX >= 0, cropY >= 0,
              cropX + cropWidth <= sourceWidth,
              cropY + cropHeight <= sourceHeight else {
            return nil
        }
        
        // 创建输出缓冲区
        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            cropWidth,
            cropHeight,
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            nil,
            &outputBuffer
        )
        
        guard status == kCVReturnSuccess, let output = outputBuffer else {
            return nil
        }
        
        // 执行裁剪操作
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }
        
        guard let sourceData = CVPixelBufferGetBaseAddress(pixelBuffer),
              let outputData = CVPixelBufferGetBaseAddress(output) else {
            return nil
        }
        
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let outputBytesPerRow = CVPixelBufferGetBytesPerRow(output)
        let bytesPerPixel = 4 // 假设BGRA格式
        
        for y in 0..<cropHeight {
            let sourceOffset = (cropY + y) * sourceBytesPerRow + cropX * bytesPerPixel
            let outputOffset = y * outputBytesPerRow
            
            memcpy(
                outputData.advanced(by: outputOffset),
                sourceData.advanced(by: sourceOffset),
                cropWidth * bytesPerPixel
            )
        }
        
        return output
    }
    
    /// 开始性能监控
    private func startPerformanceMonitoring() {
        lastFrameTime = CACurrentMediaTime()
        
        performanceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePerformanceMetrics()
            }
        }
    }
    
    /// 停止性能监控
    private func stopPerformanceMonitoring() {
        performanceTimer?.invalidate()
        performanceTimer = nil
    }
    
    /// 更新性能指标
    private func updatePerformanceMetrics() {
        let currentTime = CACurrentMediaTime()
        let deltaTime = currentTime - lastFrameTime
        
        if deltaTime > 0 {
            captureFrameRate = Double(frameCount) / deltaTime
        }
        
        // 重置计数器
        frameCount = 0
        lastFrameTime = currentTime
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureEngine: SCStreamDelegate {
    
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ 屏幕捕获流停止，错误: \(error)")
        
        Task { @MainActor in
            self.isCapturing = false
            self.captureFrameRate = 0
            self.stopPerformanceMonitoring()
        }
    }
    
    nonisolated public func streamDidBecomeActive(_ stream: SCStream) {
        print("✅ 屏幕捕获流已激活")
    }
    
    nonisolated public func streamDidBecomeInactive(_ stream: SCStream) {
        print("⚠️ 屏幕捕获流已停用")
    }
}

// MARK: - 流输出处理器

private class ScreenCaptureStreamOutput: NSObject, SCStreamOutput {
    
    private let textureCache: CVMetalTextureCache
    private let metalDevice: MTLDevice
    private let frameCallback: (CVPixelBuffer, CFTimeInterval) -> Void
    
    init(textureCache: CVMetalTextureCache,
         metalDevice: MTLDevice,
         frameCallback: @escaping (CVPixelBuffer, CFTimeInterval) -> Void) {
        self.textureCache = textureCache
        self.metalDevice = metalDevice
        self.frameCallback = frameCallback
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let timestamp = CACurrentMediaTime()
        frameCallback(pixelBuffer, timestamp)
    }
}

// MARK: - 配置结构体

/// 屏幕捕获配置
public struct ScreenCaptureConfiguration {
    /// 捕获分辨率
    public let captureResolution: CGSize
    /// 帧率
    public let frameRate: Int
    /// 像素格式
    public let pixelFormat: ScreenCapturePixelFormat
    /// 颜色空间
    public let colorSpace: CGColorSpace?
    /// 捕获区域（相对于显示器的比例，nil表示全屏）
    public var captureArea: CGRect?
    /// 是否启用硬件加速
    public let enableHardwareAcceleration: Bool
    /// 是否捕获鼠标光标
    public let captureCursor: Bool
    /// 是否排除桌面窗口
    public let excludeDesktopWindows: Bool
    
    public init(captureResolution: CGSize,
                frameRate: Int,
                pixelFormat: ScreenCapturePixelFormat,
                colorSpace: CGColorSpace?,
                captureArea: CGRect?,
                enableHardwareAcceleration: Bool,
                captureCursor: Bool,
                excludeDesktopWindows: Bool) {
        self.captureResolution = captureResolution
        self.frameRate = frameRate
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
        self.captureArea = captureArea
        self.enableHardwareAcceleration = enableHardwareAcceleration
        self.captureCursor = captureCursor
        self.excludeDesktopWindows = excludeDesktopWindows
    }
    
    public static func defaultConfiguration() -> ScreenCaptureConfiguration {
        return ScreenCaptureConfiguration(
            captureResolution: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            pixelFormat: .bgra8888,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB),
            captureArea: nil,
            enableHardwareAcceleration: true,
            captureCursor: true,
            excludeDesktopWindows: false
        )
    }
    
    public static func highPerformanceConfiguration() -> ScreenCaptureConfiguration {
        return ScreenCaptureConfiguration(
            captureResolution: CGSize(width: 2560, height: 1440),
            frameRate: 60,
            pixelFormat: .bgra8888,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3),
            captureArea: nil,
            enableHardwareAcceleration: true,
            captureCursor: true,
            excludeDesktopWindows: false
        )
    }
    
    public static func lowLatencyConfiguration() -> ScreenCaptureConfiguration {
        return ScreenCaptureConfiguration(
            captureResolution: CGSize(width: 1280, height: 720),
            frameRate: 120,
            pixelFormat: .bgra8888,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB),
            captureArea: nil,
            enableHardwareAcceleration: true,
            captureCursor: false,
            excludeDesktopWindows: true
        )
    }
}

/// 屏幕捕获像素格式
public enum ScreenCapturePixelFormat: String, CaseIterable {
    case bgra8888 = "BGRA8888"
    case rgba8888 = "RGBA8888"
    case yuv420p = "YUV420P"
    case nv12 = "NV12"
    
    var osType: OSType {
        switch self {
        case .bgra8888: return kCVPixelFormatType_32BGRA
        case .rgba8888: return kCVPixelFormatType_32RGBA
        case .yuv420p: return kCVPixelFormatType_420YpCbCr8Planar
        case .nv12: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }
    
    var description: String {
        switch self {
        case .bgra8888: return "BGRA 8888 (32位)"
        case .rgba8888: return "RGBA 8888 (32位)"
        case .yuv420p: return "YUV 420 Planar"
        case .nv12: return "NV12 (YUV 420 Semi-Planar)"
        }
    }
}

// MARK: - 错误定义

public enum ScreenCaptureError: LocalizedError {
    case metalCommandQueueCreationFailed
    case textureCacheCreationFailed
    case contentDiscoveryFailed(Error)
    case noDisplaySelected
    case streamOutputCreationFailed
    case streamCreationFailed
    case captureStartFailed(Error)
    case pixelBufferPoolCreationFailed
    case configurationUpdateFailed
    case unsupportedPixelFormat
    case captureAreaInvalid
    
    public var errorDescription: String? {
        switch self {
        case .metalCommandQueueCreationFailed:
            return "Metal命令队列创建失败"
        case .textureCacheCreationFailed:
            return "纹理缓存创建失败"
        case .contentDiscoveryFailed(let error):
            return "内容发现失败: \(error.localizedDescription)"
        case .noDisplaySelected:
            return "未选择显示器"
        case .streamOutputCreationFailed:
            return "流输出创建失败"
        case .streamCreationFailed:
            return "流创建失败"
        case .captureStartFailed(let error):
            return "捕获启动失败: \(error.localizedDescription)"
        case .pixelBufferPoolCreationFailed:
            return "像素缓冲区池创建失败"
        case .configurationUpdateFailed:
            return "配置更新失败"
        case .unsupportedPixelFormat:
            return "不支持的像素格式"
        case .captureAreaInvalid:
            return "无效的捕获区域"
        }
    }
}