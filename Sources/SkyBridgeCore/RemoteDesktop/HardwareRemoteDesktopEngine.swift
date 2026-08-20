// macOS-exclusive: this file is built on frameworks that exist only on macOS
// (AppKit / IOKit / ScreenCaptureKit / CoreWLAN / MetalFX / ServiceManagement /
// ApplicationServices). It is excluded from other platforms so SkyBridgeCore can be
// the single shared core for iOS as well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import Metal
import MetalKit
import VideoToolbox
import CoreGraphics
import CoreVideo
import AVFoundation
import Accelerate
import ScreenCaptureKit
import CoreMedia

// MARK: - Sendable 扩展，用于安全传递 Core Video 类型
extension CVPixelBuffer: @retroactive @unchecked Sendable {}

/// 硬件级远程桌面引擎 - 提供低延迟、高性能的远程桌面体验
/// 硬件加速远程桌面引擎 - 使用 nonisolated 处理 CVPixelBuffer
@MainActor
public class HardwareRemoteDesktopEngine: ObservableObject {
    
 // MARK: - 发布的属性
    @Published public var isCapturing = false
    @Published public var isStreaming = false
    @Published public var frameRate: Double = 0
    @Published public var bitrate: UInt64 = 0
    @Published public var latency: TimeInterval = 0
    @Published public var compressionRatio: Double = 0
    
 // MARK: - 私有属性
    private let metalDevice: MTLDevice
    private let metalCommandQueue: MTLCommandQueue
    private let screenCaptureEngine: InternalScreenCaptureEngine
    private let videoEncoder: InternalHardwareVideoEncoder
    private let frameProcessor: MetalFrameProcessor
    private let networkStreamer: RemoteDesktopStreamer
    
 // 性能监控
    private var frameCount: UInt64 = 0
    private var lastFrameTime: CFTimeInterval = 0
 // 性能监控定时器（需要在主线程上管理）
    private var performanceTimer: Timer?
    
 // 配置参数
    private var captureConfig: CaptureConfiguration
    private var encodingConfig: EncodingConfiguration
    
 // MARK: - 初始化
    
    public init() throws {
 // 初始化Metal设备
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RemoteDesktopError.metalInitializationFailed
        }
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw RemoteDesktopError.metalCommandQueueCreationFailed
        }
        
        self.metalDevice = device
        self.metalCommandQueue = commandQueue
        
 // 初始化各个组件
        self.captureConfig = CaptureConfiguration.defaultConfig()
        self.encodingConfig = EncodingConfiguration.defaultConfig()
        
        self.screenCaptureEngine = try InternalScreenCaptureEngine(metalDevice: device)
        self.videoEncoder = try InternalHardwareVideoEncoder(configuration: encodingConfig)
        self.frameProcessor = try MetalFrameProcessor(device: device, commandQueue: commandQueue)
        self.networkStreamer = RemoteDesktopStreamer()
        
        SkyBridgeLogger.metal.debugOnly("🚀 硬件级远程桌面引擎初始化完成")
        SkyBridgeLogger.metal.debugOnly("📱 Metal设备: \(device.name)")
 // 移除不存在的 maxTextureSize 属性访问
    }
    
    deinit {
 // 在 deinit 中清理资源，由于是 @MainActor 类，Timer 会在主线程上被清理
 // 这里不直接访问 performanceTimer，让系统自动处理
    }
    
 // MARK: - 公共方法
    
 /// 开始屏幕捕获
    public func startCapture() async throws {
        guard !isCapturing else { return }
        
        SkyBridgeLogger.metal.debugOnly("📹 开始屏幕捕获")
        
 // 配置屏幕捕获
        try await screenCaptureEngine.configure(config: captureConfig)
        
 // 开始捕获 - 使用 @unchecked Sendable 扩展安全传递 CVPixelBuffer
        try await screenCaptureEngine.startCapture { [weak self] pixelBuffer, timestamp in
            guard let self = self else { return }
 // 将重负载处理迁移到后台 detached 任务，避免主线程拥塞
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                await self.processFrameOffMain(pixelBuffer: pixelBuffer, timestamp: timestamp)
            }
        }
        
        isCapturing = true
        startPerformanceMonitoring()
    }
    
 /// 停止屏幕捕获
    public func stopCapture() {
        guard isCapturing else { return }
        
        SkyBridgeLogger.metal.debugOnly("⏹️ 停止屏幕捕获")
        
        screenCaptureEngine.stopCapture()
        isCapturing = false
        stopPerformanceMonitoring()
    }
    
 /// 开始流媒体传输
    public func startStreaming(to connection: P2PConnection) async throws {
        guard !isStreaming else { return }
        
        SkyBridgeLogger.metal.debugOnly("📡 开始流媒体传输到: \(connection.device.name)")
        
        try await networkStreamer.startStreaming(to: connection)
        isStreaming = true
    }
    
 /// 停止流媒体传输
    public func stopStreaming() {
        guard isStreaming else { return }
        
        SkyBridgeLogger.metal.debugOnly("📡 停止流媒体传输")
        
        networkStreamer.stopStreaming()
        isStreaming = false
    }
    
 /// 更新捕获配置
    public func updateCaptureConfig(_ config: CaptureConfiguration) async throws {
        self.captureConfig = config
        
        if isCapturing {
            try screenCaptureEngine.updateConfiguration(config)
        }
    }
    
 /// 更新编码配置
    public func updateEncodingConfig(_ config: EncodingConfiguration) async throws {
        self.encodingConfig = config
        try videoEncoder.updateConfiguration(config)
    }
    
 // MARK: - 私有方法
    
 /// 后台线程安全处理帧数据（迁移重负载，降低主线程压力）
    nonisolated private func processFrameOffMain(pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval) async {
        let startTime = CACurrentMediaTime()
        do {
 // 1. 使用Metal进行帧预处理（缩放、格式转换、滤镜等）
            let processedBuffer = try await frameProcessor.processFrame(
                pixelBuffer: pixelBuffer,
                timestamp: timestamp
            )
 // 2. 硬件编码
            let encodedData = try await videoEncoder.encode(
                pixelBuffer: processedBuffer,
                timestamp: timestamp
            )
 // 3. 网络传输（读取主 actor 状态，避免跨 actor 访问）
            let shouldStream = await MainActor.run { self.isStreaming }
            if shouldStream {
                try await networkStreamer.sendFrame(encodedData, timestamp: timestamp)
            }
 // 4. 更新统计信息（回到主线程）
            let processingTime = CACurrentMediaTime() - startTime
            Task { @MainActor in
                self.updateStatistics(encodedData: encodedData, processingTime: processingTime)
            }
        } catch {
            SkyBridgeLogger.metal.error("❌ 帧处理失败: \(String(describing: error), privacy: .private)")
        }
    }
    
 /// 更新性能统计
    private func updateStatistics(encodedData: Data, processingTime: TimeInterval) {
 // 在主线程上更新 @Published 属性
        Task { @MainActor in
            frameCount += 1
            bitrate += UInt64(encodedData.count * 8) // 转换为比特
            latency = processingTime
            
 // 计算压缩比（假设原始帧大小）
            let originalSize = captureConfig.resolution.width * captureConfig.resolution.height * 4 // RGBA
            compressionRatio = Double(originalSize) / Double(encodedData.count)
        }
    }
    
 /// 开始性能监控
    private func startPerformanceMonitoring() {
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
    @MainActor
    private func updatePerformanceMetrics() {
        let currentTime = CACurrentMediaTime()
        let deltaTime = currentTime - lastFrameTime
        
        if deltaTime > 0 {
            frameRate = Double(frameCount) / deltaTime
        }
        
 // 重置计数器
        frameCount = 0
        bitrate = 0
        lastFrameTime = currentTime
    }
}

// MARK: - 内部屏幕捕获引擎
// 内部屏幕捕获引擎类，标记为 Sendable 以支持跨 actor 使用
private class InternalScreenCaptureEngine: @unchecked Sendable {
 // 使用 ScreenCaptureKit 进行系统推帧，彻底移除 Timer + mock
    private let metalDevice: MTLDevice
    private var stream: SCStream?
    private var output: StreamOutput?
    private var captureConfig: CaptureConfiguration = .defaultConfig()
    private var frameCallback: (@Sendable (CVPixelBuffer, CFTimeInterval) -> Void)?

    init(metalDevice: MTLDevice) throws {
        self.metalDevice = metalDevice
    }

    func configure(config: CaptureConfiguration) async throws {
        self.captureConfig = config
        SkyBridgeLogger.metal.debugOnly("⚙️ 配置屏幕捕获: \(config.resolution.width)x\(config.resolution.height) @ \(config.frameRate)fps")
    }

    func startCapture(_ callback: @escaping @Sendable (CVPixelBuffer, CFTimeInterval) -> Void) async throws {
        self.frameCallback = callback

 // 获取可共享内容
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw RemoteDesktopError.connectionFailed("ScreenCaptureKit不可用或未发现显示器")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

 // 配置Stream
        let scConfig = SCStreamConfiguration()
        scConfig.width = Int(captureConfig.resolution.width)
        scConfig.height = Int(captureConfig.resolution.height)
        scConfig.pixelFormat = kCVPixelFormatType_32BGRA
        scConfig.showsCursor = true
        scConfig.queueDepth = 3
        scConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(captureConfig.frameRate))

        let output = StreamOutput { [weak self] pixelBuffer, ts in
            guard let cb = self?.frameCallback else { return }
            cb(pixelBuffer, ts)
        }
        self.output = output

        let stream = SCStream(filter: filter, configuration: scConfig, delegate: nil)
 // addStreamOutput 为同步抛错方法，移除无意义 await
        try stream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "scstream.frames", qos: .userInitiated)
        )
        self.stream = stream

        try await stream.startCapture()
        SkyBridgeLogger.metal.debugOnly("✅ 屏幕捕获已启动 (SCStream)")
    }

    func stopCapture() {
        let s = stream
 // 使用继承当前actor的 ，在异步上下文安全调用 async/throws 的 stopCapture
        Task { [weak s] in
            try? await s?.stopCapture()
        }
        stream = nil
        output = nil
        frameCallback = nil
        SkyBridgeLogger.metal.debugOnly("⏹️ 屏幕捕获已停止")
    }

    func updateConfiguration(_ config: CaptureConfiguration) throws {
 // 简化：保存配置，下一次 startCapture 生效
        self.captureConfig = config
        SkyBridgeLogger.metal.debugOnly("🔄 更新捕获配置（将于下次启动生效）")
    }

    private final class StreamOutput: NSObject, SCStreamOutput {
        private let onFrame: (CVPixelBuffer, CFTimeInterval) -> Void
        init(onFrame: @escaping (CVPixelBuffer, CFTimeInterval) -> Void) { self.onFrame = onFrame }
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
            guard outputType == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ts = CACurrentMediaTime()
            onFrame(pixelBuffer, ts)
        }
    }
}

// MARK: - 内部硬件视频编码器
// 内部硬件视频编码器类，标记为 Sendable 以支持跨 actor 使用
private class InternalHardwareVideoEncoder: @unchecked Sendable {
    private var compressionSession: VTCompressionSession?
    private var config: EncodingConfiguration
    private var encodedFrameCallback: ((Data, CFTimeInterval) -> Void)?
    
    init(configuration: EncodingConfiguration) throws {
        self.config = configuration
        try setupCompressionSession()
    }
    
    deinit {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: CMTime.invalid)
            VTCompressionSessionInvalidate(session)
        }
    }
    
    func encode(pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval) async throws -> Data {
        guard let session = compressionSession else {
            throw RemoteDesktopError.encoderNotInitialized
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let presentationTime = CMTime(seconds: timestamp, preferredTimescale: 1000000)
            
 // 设置编码回调
            encodedFrameCallback = { data, _ in
                continuation.resume(returning: data)
            }
            
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: CMTime.invalid,
                frameProperties: nil,
                infoFlagsOut: nil,
                outputHandler: { [weak self] status, infoFlags, sampleBuffer in
                    self?.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
                }
            )
            
            if status != noErr {
                continuation.resume(throwing: RemoteDesktopError.encodingFailed(status))
            }
        }
    }
    
    func updateConfiguration(_ config: EncodingConfiguration) throws {
        self.config = config
        try setupCompressionSession()
    }
    
    private func setupCompressionSession() throws {
 // 清理现有会话
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
        
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.resolution.width),
            height: Int32(config.resolution.height),
            codecType: config.codec.vtCodecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            throw RemoteDesktopError.compressionSessionCreationFailed(status)
        }
        
 // 配置编码参数
        try configureCompressionSession(session)
        
        self.compressionSession = session
        SkyBridgeLogger.metal.debugOnly("✅ 硬件编码器初始化完成: \(config.codec)")
    }
    
    private func configureCompressionSession(_ session: VTCompressionSession) throws {
 // 设置比特率
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: config.bitrate)
        )
        
 // 设置关键帧间隔
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: config.keyFrameInterval)
        )
        
 // 设置实时编码
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue!
        )
        
 // 设置质量
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_Quality,
            value: NSNumber(value: config.quality)
        )
        
 // 准备编码
        let status = VTCompressionSessionPrepareToEncodeFrames(session)
        if status != noErr {
            throw RemoteDesktopError.compressionSessionPreparationFailed(status)
        }
    }
    
    private func handleEncodedFrame(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr,
              let sampleBuffer = sampleBuffer,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            SkyBridgeLogger.metal.error("❌ 编码帧处理失败: \(status)")
            return
        }
        
 // 提取编码数据
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else {
            SkyBridgeLogger.metal.debugOnly("⚠️ 编码数据长度为 0，跳过该帧")
            return
        }
        var data = Data(count: length)
        
        let copyStatus: OSStatus = data.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let dst = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: dst)
        }
        
        guard copyStatus == noErr else {
            SkyBridgeLogger.metal.error("❌ 复制编码数据失败: \(copyStatus)")
            return
        }
        
        let timestamp = CACurrentMediaTime()
        encodedFrameCallback?(data, timestamp)
    }
}

// MARK: - Metal帧处理器
// Metal 帧处理器类，标记为 Sendable 以支持跨 actor 使用
private class MetalFrameProcessor: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let scalingPipeline: MTLComputePipelineState
    
    init(device: MTLDevice, commandQueue: MTLCommandQueue) throws {
        self.device = device
        self.commandQueue = commandQueue
        
 // 创建纹理缓存
        var textureCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard status == kCVReturnSuccess, let cache = textureCache else {
            throw RemoteDesktopError.textureCacheCreationFailed
        }
        self.textureCache = cache
        
 // 创建计算管线
        guard let library = SkyBridgeMetalShaderLibrary.loadIfAvailable(
            device: device,
            bundle: SkyBridgeResourceBundleLocator.core,
            sourceResourceNames: ["RemoteDesktopShaders"],
            requiredFunctionNames: ["scaleFrame"]
        ),
              let function = library.makeFunction(name: "scaleFrame"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            throw RemoteDesktopError.metalPipelineCreationFailed
        }
        self.scalingPipeline = pipeline
        
        SkyBridgeLogger.metal.debugOnly("✅ Metal帧处理器初始化完成")
    }
    
    func processFrame(pixelBuffer: CVPixelBuffer, timestamp: CFTimeInterval) async throws -> CVPixelBuffer {
 // 创建Metal纹理
        let inputTexture = try createMetalTexture(from: pixelBuffer)
        
 // 创建输出像素缓冲区
        let outputBuffer = try createOutputPixelBuffer(from: pixelBuffer)
        let outputTexture = try createMetalTexture(from: outputBuffer)
        
 // 执行Metal计算
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RemoteDesktopError.metalCommandCreationFailed
        }
        
        encoder.setComputePipelineState(scalingPipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (inputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (inputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
 // 等待命令缓冲区完成（使用 continuation 转为异步等待）
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
        }
        
        return outputBuffer
    }
    
    private func createMetalTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &texture
        )
        
        guard status == kCVReturnSuccess,
              let texture = texture,
              let metalTexture = CVMetalTextureGetTexture(texture) else {
            throw RemoteDesktopError.metalTextureCreationFailed
        }
        
        return metalTexture
    }
    
    private func createOutputPixelBuffer(from inputBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(inputBuffer)
        let height = CVPixelBufferGetHeight(inputBuffer)
        
        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &outputBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = outputBuffer else {
            throw RemoteDesktopError.pixelBufferCreationFailed
        }
        
        return buffer
    }
}

// MARK: - 网络流媒体传输器
// 远程桌面流传输器类，标记为 Sendable 以支持跨 actor 使用
private class RemoteDesktopStreamer: @unchecked Sendable {
    private var connection: P2PConnection?
    private var isStreaming = false
    
    func startStreaming(to connection: P2PConnection) async throws {
        self.connection = connection
        self.isStreaming = true
        SkyBridgeLogger.metal.debugOnly("📡 开始流媒体传输")
    }
    
    func stopStreaming() {
        self.connection = nil
        self.isStreaming = false
        SkyBridgeLogger.metal.debugOnly("📡 停止流媒体传输")
    }
    
    func sendFrame(_ data: Data, timestamp: CFTimeInterval) async throws {
        guard let connection = connection, isStreaming else { return }

        // Paper-aligned: remote desktop stream frames MUST be carried over the established SessionKeys channel.
        // Avoid JSON/base64 overhead (which destroys throughput and latency).
        let safeTimestamp = timestamp.isFinite ? max(0, timestamp) : 0
        let timestampNs = UInt64(safeTimestamp * 1_000_000_000.0)
        try await connection.sendRemoteDesktopFrame(data, timestampNs: timestampNs)
    }
}

// MARK: - 配置结构体

/// 捕获配置
public struct CaptureConfiguration: Sendable {
    public let resolution: CGSize
    public let frameRate: Int
    public let colorSpace: CGColorSpace?
    public let captureArea: CGRect?
    
    public static func defaultConfig() -> CaptureConfiguration {
        return CaptureConfiguration(
            resolution: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB),
            captureArea: nil
        )
    }
}

/// 编码配置
public struct EncodingConfiguration: Sendable {
    public let codec: VideoCodec
    public let resolution: CGSize
    public let bitrate: Int
    public let quality: Float
    public let keyFrameInterval: Int
    
    public static func defaultConfig() -> EncodingConfiguration {
        return EncodingConfiguration(
            codec: .h264,
            resolution: CGSize(width: 1920, height: 1080),
            bitrate: 5000000,
            quality: 0.8,
            keyFrameInterval: 30
        )
    }
}

// 注意：VideoCodec 和 RemoteDesktopError 已在其他文件中定义，此处不再重复定义
#endif
