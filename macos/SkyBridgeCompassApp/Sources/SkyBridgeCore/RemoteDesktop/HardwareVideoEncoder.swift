import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import AVFoundation
import Accelerate
import QuartzCore

/// 硬件视频编码器 - 使用VideoToolbox实现高性能H.264/H.265编码
@MainActor
public class HardwareVideoEncoder: ObservableObject {
    
    // MARK: - 发布的属性
    @Published public var isEncoding = false
    @Published public var encodingFrameRate: Double = 0
    @Published public var averageBitrate: UInt64 = 0
    @Published public var instantaneousBitrate: UInt64 = 0
    @Published public var compressionRatio: Double = 0
    @Published public var keyFrameInterval: Int = 0
    @Published public var encodingLatency: TimeInterval = 0
    
    // MARK: - 私有属性
    private var compressionSession: VTCompressionSession?
    private var currentConfiguration: VideoEncodingConfiguration
    private let encodingQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    
    // 编码回调 - 使用 @Sendable 闭包确保线程安全
    private var frameEncodedCallback: (@Sendable (EncodedVideoFrame) -> Void)?
    private var errorCallback: (@Sendable (Error) -> Void)?
    
    // 性能监控
    private var frameCount: UInt64 = 0
    private var totalEncodedBytes: UInt64 = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var performanceTimer: Timer?
    private var encodingStartTime: CFTimeInterval = 0
    
    // 编码状态
    private var isConfigured = false
    private var pendingFrames: [PendingFrame] = []
    private let maxPendingFrames = 10
    
    // MARK: - 初始化
    
    public init(configuration: VideoEncodingConfiguration) throws {
        self.currentConfiguration = configuration
        self.encodingQueue = DispatchQueue(label: "com.skybridge.video.encoding", qos: .userInitiated)
        self.callbackQueue = DispatchQueue(label: "com.skybridge.video.callback", qos: .userInitiated)
        
        print("🎬 硬件视频编码器初始化")
        print("📊 编解码器: \(configuration.codec.displayName)")
        print("📐 分辨率: \(Int(configuration.resolution.width))x\(Int(configuration.resolution.height))")
        print("🎯 比特率: \(configuration.bitrate / 1000) kbps")
        print("⚡ 质量: \(configuration.quality)")
        
        try setupCompressionSession()
    }
    
    deinit {
        // 在 deinit 中避免访问非 Sendable 属性
        // 这些资源会在类销毁时自动清理
    }
    
    // MARK: - 公共方法
    
    /// 开始编码
    public func startEncoding(frameCallback: @escaping @Sendable (EncodedVideoFrame) -> Void,
                             errorCallback: @escaping @Sendable (Error) -> Void) throws {
        guard !isEncoding else {
            print("⚠️ 视频编码器已在运行")
            return
        }
        
        print("🚀 开始视频编码")
        
        self.frameEncodedCallback = frameCallback
        self.errorCallback = errorCallback
        
        // 确保压缩会话已配置
        if !isConfigured {
            try setupCompressionSession()
        }
        
        isEncoding = true
        
        // 开始性能监控
        startPerformanceMonitoring()
        
        print("✅ 视频编码已启动")
    }
    
    /// 停止编码
    public func stopEncoding() {
        guard isEncoding else { return }
        
        print("⏹️ 停止视频编码")
        
        isEncoding = false
        
        // 完成所有待处理的帧
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: CMTime.invalid)
        }
        
        // 清理回调
        frameEncodedCallback = nil
        errorCallback = nil
        
        // 停止性能监控
        stopPerformanceMonitoring()
        
        // 清理待处理帧
        pendingFrames.removeAll()
        
        print("✅ 视频编码已停止")
    }
    
    /// 编码单帧
    public func encodeFrame(_ pixelBuffer: CVPixelBuffer, 
                           presentationTime: CMTime,
                           duration: CMTime = CMTime.invalid,
                           forceKeyFrame: Bool = false) throws {
        guard isEncoding, let session = compressionSession else {
            throw VideoEncodingError.encoderNotReady
        }
        
        // 检查待处理帧数量
        if pendingFrames.count >= maxPendingFrames {
            print("⚠️ 待处理帧过多，丢弃帧")
            return
        }
        
        encodingStartTime = CACurrentMediaTime()
        
        // 创建待处理帧记录
        let pendingFrame = PendingFrame(
            presentationTime: presentationTime,
            startTime: encodingStartTime
        )
        pendingFrames.append(pendingFrame)
        
        // 设置帧属性
        var frameProperties: [String: Any] = [:]
        
        if forceKeyFrame {
            frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = kCFBooleanTrue!
        }
        
        // 异步编码 - 使用 nonisolated 上下文处理 CMSampleBuffer
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties.isEmpty ? nil : frameProperties as CFDictionary,
            infoFlagsOut: nil
        ) { [weak self] status, infoFlags, sampleBuffer in
            // 在 nonisolated 上下文中处理 CMSampleBuffer，避免跨 actor 传递
            guard let strongSelf = self else { return }
            
            // 创建本地副本避免跨 actor 传递 CMSampleBuffer
            let localStatus = status
            let localInfoFlags = infoFlags
            let localPresentationTime = presentationTime
            
            // 在编码回调中直接提取数据，避免传递 CMSampleBuffer
            var encodedData: Data?
            var isKeyFrame = false
            
            if localStatus == noErr, let buffer = sampleBuffer {
                // 检查是否为关键帧
                if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) {
                    let attachments = CFArrayGetValueAtIndex(attachmentsArray, 0)
                    if let attachments = attachments {
                        let attachmentsDict = Unmanaged<CFDictionary>.fromOpaque(attachments).takeUnretainedValue()
                        isKeyFrame = !CFDictionaryContainsKey(
                            attachmentsDict,
                            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
                        )
                    }
                }
                
                // 提取编码数据
                if let dataBuffer = CMSampleBufferGetDataBuffer(buffer) {
                    let dataLength = CMBlockBufferGetDataLength(dataBuffer)
                    var data = Data(count: dataLength)
                    
                    let copyStatus = data.withUnsafeMutableBytes { bytes in
                        return CMBlockBufferCopyDataBytes(
                            dataBuffer,
                            atOffset: 0,
                            dataLength: dataLength,
                            destination: bytes.baseAddress!
                        )
                    }
                    
                    if copyStatus == noErr {
                        encodedData = data
                    }
                }
            }
            
            // 在 MainActor 上下文中处理结果
            Task { @MainActor in
                strongSelf.handleEncodedFrameData(
                    status: localStatus,
                    infoFlags: localInfoFlags,
                    encodedData: encodedData,
                    isKeyFrame: isKeyFrame,
                    originalPresentationTime: localPresentationTime
                )
            }
        }
        
        if status != noErr {
            // 创建本地副本避免发送风险
            let localStatus = status
            if let errorCallback = self.errorCallback {
                callbackQueue.async {
                    errorCallback(VideoEncodingError.encodingFailed(localStatus))
                }
            }
        }
    }
    
    /// 强制生成关键帧
    public func forceKeyFrame() {
        guard let session = compressionSession else { return }
        
        print("🔑 强制生成关键帧")
        
        // 设置下一帧为关键帧
        let status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanFalse
        )
        
        if status != noErr {
            print("⚠️ 设置关键帧属性失败: \(status)")
        }
    }
    
    /// 更新编码配置
    public func updateConfiguration(_ configuration: VideoEncodingConfiguration) throws {
        print("🔄 更新编码配置")
        
        let wasEncoding = isEncoding
        
        if wasEncoding {
            stopEncoding()
        }
        
        self.currentConfiguration = configuration
        
        // 重新创建压缩会话
        try setupCompressionSession()
        
        if wasEncoding, let frameCallback = frameEncodedCallback, let errorCallback = errorCallback {
            try startEncoding(frameCallback: frameCallback, errorCallback: errorCallback)
        }
        
        print("✅ 编码配置已更新")
    }
    
    /// 更新比特率
    public func updateBitrate(_ bitrate: Int) throws {
        guard let session = compressionSession else {
            throw VideoEncodingError.sessionNotInitialized
        }
        
        print("📊 更新比特率: \(bitrate / 1000) kbps")
        
        let status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrate)
        )
        
        if status != noErr {
            throw VideoEncodingError.propertyUpdateFailed(status)
        }
        
        currentConfiguration = VideoEncodingConfiguration(
            codec: currentConfiguration.codec,
            resolution: currentConfiguration.resolution,
            bitrate: bitrate,
            frameRate: currentConfiguration.frameRate,
            keyFrameInterval: currentConfiguration.keyFrameInterval,
            quality: currentConfiguration.quality,
            profile: currentConfiguration.profile,
            enableBFrames: currentConfiguration.enableBFrames,
            enableHardwareAcceleration: currentConfiguration.enableHardwareAcceleration
        )
    }
    
    /// 更新帧率
    public func updateFrameRate(_ frameRate: Int) throws {
        guard let session = compressionSession else {
            throw VideoEncodingError.sessionNotInitialized
        }
        
        print("🎯 更新帧率: \(frameRate) fps")
        
        let expectedFrameRate = NSNumber(value: frameRate)
        let status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: expectedFrameRate
        )
        
        if status != noErr {
            throw VideoEncodingError.propertyUpdateFailed(status)
        }
        
        currentConfiguration = VideoEncodingConfiguration(
            codec: currentConfiguration.codec,
            resolution: currentConfiguration.resolution,
            bitrate: currentConfiguration.bitrate,
            frameRate: frameRate,
            keyFrameInterval: currentConfiguration.keyFrameInterval,
            quality: currentConfiguration.quality,
            profile: currentConfiguration.profile,
            enableBFrames: currentConfiguration.enableBFrames,
            enableHardwareAcceleration: currentConfiguration.enableHardwareAcceleration
        )
    }
    
    // MARK: - 私有方法
    
    /// 设置压缩会话
    private func setupCompressionSession() throws {
        // 清理现有会话
        invalidateCompressionSession()
        
        print("⚙️ 设置压缩会话")
        
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(currentConfiguration.resolution.width),
            height: Int32(currentConfiguration.resolution.height),
            codecType: currentConfiguration.codec.vtCodecType,
            encoderSpecification: currentConfiguration.enableHardwareAcceleration ? nil : [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanFalse
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!
            ] as CFDictionary,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            throw VideoEncodingError.sessionCreationFailed(status)
        }
        
        self.compressionSession = session
        
        // 配置编码参数
        try configureCompressionSession(session)
        
        // 准备编码
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepareStatus != noErr {
            throw VideoEncodingError.sessionPreparationFailed(prepareStatus)
        }
        
        isConfigured = true
        print("✅ 压缩会话设置完成")
    }
    
    /// 配置压缩会话参数
    private func configureCompressionSession(_ session: VTCompressionSession) throws {
        var status: OSStatus
        
        // 设置比特率
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: currentConfiguration.bitrate)
        )
        if status != noErr {
            throw VideoEncodingError.propertySetFailed("AverageBitRate", status)
        }
        
        // 设置最大比特率（防止突发）
        let maxBitrate = currentConfiguration.bitrate * 2
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [NSNumber(value: maxBitrate / 8), NSNumber(value: 1)] as CFArray
        )
        if status != noErr {
            print("⚠️ 设置最大比特率失败: \(status)")
        }
        
        // 设置关键帧间隔
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: currentConfiguration.keyFrameInterval)
        )
        if status != noErr {
            throw VideoEncodingError.propertySetFailed("MaxKeyFrameInterval", status)
        }
        
        // 设置期望帧率
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: currentConfiguration.frameRate)
        )
        if status != noErr {
            throw VideoEncodingError.propertySetFailed("ExpectedFrameRate", status)
        }
        
        // 设置质量
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_Quality,
            value: NSNumber(value: currentConfiguration.quality)
        )
        if status != noErr {
            print("⚠️ 设置质量失败: \(status)")
        }
        
        // 设置实时编码
        status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue!
        )
        if status != noErr {
            print("⚠️ 设置实时编码失败: \(status)")
        }
        
        // 设置编码器配置文件
        if let profileLevel = currentConfiguration.profile.vtProfileLevel {
            status = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: profileLevel
            )
            if status != noErr {
                print("⚠️ 设置编码配置文件失败: \(status)")
            }
        }
        
        // 设置B帧
        if currentConfiguration.enableBFrames {
            status = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanTrue!
            )
            if status != noErr {
                print("⚠️ 启用B帧失败: \(status)")
            }
        } else {
            status = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse
            )
        }
        
        // 设置熵编码模式（H.264）
        if currentConfiguration.codec == .h264 {
            status = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_H264EntropyMode,
                value: kVTH264EntropyMode_CABAC
            )
            if status != noErr {
                print("⚠️ 设置H.264熵编码模式失败: \(status)")
            }
        }
        
        print("✅ 压缩会话参数配置完成")
    }
    
    /// 处理编码完成的帧数据 - 在 MainActor 上下文中安全处理
    private func handleEncodedFrameData(status: OSStatus,
                                       infoFlags: VTEncodeInfoFlags,
                                       encodedData: Data?,
                                       isKeyFrame: Bool,
                                       originalPresentationTime: CMTime) {
        
        // 移除对应的待处理帧
        if let index = pendingFrames.firstIndex(where: { $0.presentationTime == originalPresentationTime }) {
            let pendingFrame = pendingFrames.remove(at: index)
            let encodingTime = CACurrentMediaTime() - pendingFrame.startTime
            
            // 直接更新延迟，因为已经在 MainActor 上下文中
            self.encodingLatency = encodingTime
        }
        
        guard status == noErr else {
            print("❌ 帧编码失败: \(status)")
            // 使用 @Sendable 回调
            if let errorCallback = self.errorCallback {
                callbackQueue.async {
                    errorCallback(VideoEncodingError.encodingFailed(status))
                }
            }
            return
        }
        
        guard let data = encodedData else {
            print("❌ 编码帧数据为空")
            return
        }
        
        // 更新统计信息 - 直接在 MainActor 上下文中更新
        self.frameCount += 1
        self.totalEncodedBytes += UInt64(data.count)
        self.instantaneousBitrate = UInt64(data.count * 8) // 转换为比特
        
        // 创建编码帧对象
        let encodedFrame = EncodedVideoFrame(
            data: data,
            presentationTime: originalPresentationTime,
            duration: CMTime.invalid, // 无法从回调中获取持续时间
            isKeyFrame: isKeyFrame,
            codec: currentConfiguration.codec,
            resolution: currentConfiguration.resolution
        )
        
        // 调用回调 - 使用 @Sendable 回调
        if let frameCallback = self.frameEncodedCallback {
            callbackQueue.async {
                frameCallback(encodedFrame)
            }
        }
    }
    
    /// 处理编码完成的帧
    /// 处理编码完成的帧 - 在 MainActor 上下文中安全处理
    private func handleEncodedFrame(status: OSStatus,
                                   infoFlags: VTEncodeInfoFlags,
                                   sampleBuffer: CMSampleBuffer?,
                                   originalPresentationTime: CMTime) {
        
        // 移除对应的待处理帧
        if let index = pendingFrames.firstIndex(where: { $0.presentationTime == originalPresentationTime }) {
            let pendingFrame = pendingFrames.remove(at: index)
            let encodingTime = CACurrentMediaTime() - pendingFrame.startTime
            
            // 直接更新延迟，因为已经在 MainActor 上下文中
            self.encodingLatency = encodingTime
        }
        
        guard status == noErr else {
            print("❌ 帧编码失败: \(status)")
            // 使用 @Sendable 回调
            if let errorCallback = self.errorCallback {
                callbackQueue.async {
                    errorCallback(VideoEncodingError.encodingFailed(status))
                }
            }
            return
        }
        
        guard let sampleBuffer = sampleBuffer else {
            print("❌ 编码帧缓冲区为空")
            return
        }
        
        // 在 MainActor 上下文中安全处理 CMSampleBuffer
        self.processSampleBuffer(sampleBuffer, originalPresentationTime: originalPresentationTime)
    }
    
    /// 处理 CMSampleBuffer 并提取编码数据
    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, originalPresentationTime: CMTime) {
        // 检查是否为关键帧
        let isKeyFrame: Bool
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) {
            let attachments = CFArrayGetValueAtIndex(attachmentsArray, 0)
            if let attachments = attachments {
                let attachmentsDict = Unmanaged<CFDictionary>.fromOpaque(attachments).takeUnretainedValue()
                isKeyFrame = !CFDictionaryContainsKey(
                    attachmentsDict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
                )
            } else {
                isKeyFrame = false
            }
        } else {
            isKeyFrame = false
        }
        
        // 提取编码数据
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("❌ 无法获取编码数据缓冲区")
            return
        }
        
        let dataLength = CMBlockBufferGetDataLength(dataBuffer)
        var data = Data(count: dataLength)
        
        let status = data.withUnsafeMutableBytes { bytes in
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: dataLength,
                destination: bytes.baseAddress!
            )
        }
        
        guard status == noErr else {
            print("❌ 复制编码数据失败: \(status)")
            return
        }
        
        // 更新统计信息 - 直接在 MainActor 上下文中更新
        self.frameCount += 1
        self.totalEncodedBytes += UInt64(dataLength)
        self.instantaneousBitrate = UInt64(dataLength * 8) // 转换为比特
        
        // 创建编码帧对象
        let encodedFrame = EncodedVideoFrame(
            data: data,
            presentationTime: originalPresentationTime,
            duration: CMSampleBufferGetDuration(sampleBuffer),
            isKeyFrame: isKeyFrame,
            codec: currentConfiguration.codec,
            resolution: currentConfiguration.resolution
        )
        
        // 调用回调 - 使用 @Sendable 回调
        if let frameCallback = self.frameEncodedCallback {
            callbackQueue.async {
                frameCallback(encodedFrame)
            }
        }
    }
    
    /// 清理压缩会话
    private func invalidateCompressionSession() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: CMTime.invalid)
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
        isConfigured = false
    }
    
    /// 开始性能监控
    private func startPerformanceMonitoring() {
        lastFrameTime = CACurrentMediaTime()
        frameCount = 0
        totalEncodedBytes = 0
        
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
            encodingFrameRate = Double(frameCount) / deltaTime
            averageBitrate = UInt64(Double(totalEncodedBytes * 8) / deltaTime) // 转换为比特率
            
            // 计算压缩比（假设原始帧大小）
            let originalFrameSize = currentConfiguration.resolution.width * currentConfiguration.resolution.height * 4 // BGRA
            let averageEncodedSize = totalEncodedBytes / max(frameCount, 1)
            compressionRatio = Double(originalFrameSize) / Double(averageEncodedSize)
        }
        
        // 重置计数器
        frameCount = 0
        totalEncodedBytes = 0
        lastFrameTime = currentTime
    }
}

// MARK: - 支持结构体和枚举

/// 待处理帧记录
private struct PendingFrame {
    let presentationTime: CMTime
    let startTime: CFTimeInterval
}

/// 编码帧结构 - 符合 Sendable 协议
public struct EncodedVideoFrame: Sendable {
    /// 编码后的数据
    public let data: Data
    /// 显示时间戳
    public let presentationTime: CMTime
    /// 帧持续时间
    public let duration: CMTime
    /// 是否为关键帧
    public let isKeyFrame: Bool
    /// 编解码器类型
    public let codec: VideoCodec
    /// 分辨率
    public let resolution: CGSize
    
    /// 数据大小（字节）
    public var size: Int {
        return data.count
    }
    
    /// 比特率（基于帧大小和持续时间）
    public var bitrate: UInt64 {
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds > 0 else { return 0 }
        return UInt64(Double(data.count * 8) / durationSeconds)
    }
}

/// 视频编码配置 - 符合 Sendable 协议
public struct VideoEncodingConfiguration: Sendable {
    /// 编解码器
    public let codec: VideoCodec
    /// 分辨率
    public let resolution: CGSize
    /// 比特率（bps）
    public let bitrate: Int
    /// 帧率
    public let frameRate: Int
    /// 关键帧间隔
    public let keyFrameInterval: Int
    /// 质量（0.0-1.0）
    public let quality: Float
    /// 编码配置文件
    public let profile: VideoProfile
    /// 是否启用B帧
    public let enableBFrames: Bool
    /// 是否启用硬件加速
    public let enableHardwareAcceleration: Bool
    
    public init(codec: VideoCodec,
                resolution: CGSize,
                bitrate: Int,
                frameRate: Int,
                keyFrameInterval: Int,
                quality: Float,
                profile: VideoProfile,
                enableBFrames: Bool,
                enableHardwareAcceleration: Bool) {
        self.codec = codec
        self.resolution = resolution
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.keyFrameInterval = keyFrameInterval
        self.quality = quality
        self.profile = profile
        self.enableBFrames = enableBFrames
        self.enableHardwareAcceleration = enableHardwareAcceleration
    }
    
    /// 默认配置
    public static func defaultConfiguration() -> VideoEncodingConfiguration {
        return VideoEncodingConfiguration(
            codec: .h264,
            resolution: CGSize(width: 1920, height: 1080),
            bitrate: 5_000_000, // 5 Mbps
            frameRate: 30,
            keyFrameInterval: 30,
            quality: 0.8,
            profile: .h264Baseline,
            enableBFrames: false,
            enableHardwareAcceleration: true
        )
    }
    
    /// 高质量配置
    public static func highQualityConfiguration() -> VideoEncodingConfiguration {
        return VideoEncodingConfiguration(
            codec: .h265,
            resolution: CGSize(width: 2560, height: 1440),
            bitrate: 10_000_000, // 10 Mbps
            frameRate: 60,
            keyFrameInterval: 60,
            quality: 0.9,
            profile: .h265Main,
            enableBFrames: true,
            enableHardwareAcceleration: true
        )
    }
    
    /// 低延迟配置
    public static func lowLatencyConfiguration() -> VideoEncodingConfiguration {
        return VideoEncodingConfiguration(
            codec: .h264,
            resolution: CGSize(width: 1280, height: 720),
            bitrate: 2_000_000, // 2 Mbps
            frameRate: 60,
            keyFrameInterval: 15,
            quality: 0.7,
            profile: .h264Baseline,
            enableBFrames: false,
            enableHardwareAcceleration: true
        )
    }
}

/// 视频编解码器
/// 视频编解码器类型
public enum VideoCodec: String, CaseIterable, Sendable {
    case h264 = "H.264"
    case h265 = "H.265"
    
    var vtCodecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .h265: return kCMVideoCodecType_HEVC
        }
    }
    
    var displayName: String {
        return rawValue
    }
}

/// 视频编码配置文件 - 符合 Sendable 协议
public enum VideoProfile: String, CaseIterable, Sendable {
    case h264Baseline = "H.264 Baseline"
    case h264Main = "H.264 Main"
    case h264High = "H.264 High"
    case h265Main = "H.265 Main"
    case h265Main10 = "H.265 Main 10"
    
    var vtProfileLevel: CFString? {
        switch self {
        case .h264Baseline: return kVTProfileLevel_H264_Baseline_AutoLevel
        case .h264Main: return kVTProfileLevel_H264_Main_AutoLevel
        case .h264High: return kVTProfileLevel_H264_High_AutoLevel
        case .h265Main: return kVTProfileLevel_HEVC_Main_AutoLevel
        case .h265Main10: return kVTProfileLevel_HEVC_Main10_AutoLevel
        }
    }
}

// MARK: - 错误定义

public enum VideoEncodingError: LocalizedError, Sendable {
    case sessionCreationFailed(OSStatus)
    case sessionPreparationFailed(OSStatus)
    case sessionNotInitialized
    case encoderNotReady
    case encodingFailed(OSStatus)
    case propertySetFailed(String, OSStatus)
    case propertyUpdateFailed(OSStatus)
    case unsupportedCodec
    case unsupportedResolution
    case invalidConfiguration
    
    public var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "压缩会话创建失败: \(status)"
        case .sessionPreparationFailed(let status):
            return "压缩会话准备失败: \(status)"
        case .sessionNotInitialized:
            return "压缩会话未初始化"
        case .encoderNotReady:
            return "编码器未就绪"
        case .encodingFailed(let status):
            return "视频编码失败: \(status)"
        case .propertySetFailed(let property, let status):
            return "设置属性 \(property) 失败: \(status)"
        case .propertyUpdateFailed(let status):
            return "更新属性失败: \(status)"
        case .unsupportedCodec:
            return "不支持的编解码器"
        case .unsupportedResolution:
            return "不支持的分辨率"
        case .invalidConfiguration:
            return "无效的编码配置"
        }
    }
}