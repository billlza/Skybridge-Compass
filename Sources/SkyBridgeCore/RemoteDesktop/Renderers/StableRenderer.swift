import Foundation
@preconcurrency import Metal
import VideoToolbox
import CoreVideo
import CoreMedia
import CoreGraphics
import ImageIO
import os.log

// MARK: - Stable Renderer

/// 稳定渲染器——远程桌面的"保底链"正式产品化。
///
/// 设计原则：
/// 1. **永不失败**：任何 Metal/VT 操作出错时立即回退到 CGImage 路径
/// 2. **增量合成**：利用 damage rects 只更新变化区域，降低每帧渲染成本
/// 3. **Backing store 复用**：维护一个持久 MTLTexture，不每帧新建
/// 4. **零依赖高级特性**：不依赖 MetalFX、不依赖 CADisplayLink、不依赖 CIContext
///
/// 帧流水线：
/// ```
/// 收到帧 → VT 解码 → CVPixelBuffer → CVMetalTexture (零拷贝 IOSurface)
///                                          │
///                   有 damage rects? ───── Yes → 增量 blit dirty rects 到 backing store
///                                    └──── No  → 全帧 blit 到 backing store
///                                                     │
///                                               发布 backing store texture
/// ```
public final class StableRenderer: @unchecked Sendable {

    // MARK: - 输出

    /// 帧输出回调。texture 为最终合成结果，backing 持有引用防止提前释放。
    public var frameHandler: ((MTLTexture, AnyObject?) -> Void)?

    // MARK: - Metal 资源

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?

    /// 持久 backing store 纹理——不每帧新建
    private var backingStore: MTLTexture?
    private var backingStoreWidth: Int = 0
    private var backingStoreHeight: Int = 0

    // MARK: - VideoToolbox

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentCodec: RemoteFrameType?
    /// 安全的回调上下文管理
    private var callbackContext: StableRendererCallbackContext?

    // MARK: - 状态

    private var previousFrameTimestamp: DispatchTime?
    private let renderQueue = DispatchQueue(label: "com.skybridge.compass.stable.render")
    private let log = Logger(subsystem: "com.skybridge.compass", category: "StableRenderer")

    // MARK: - 健康监测

    private let healthMonitor: RendererHealthMonitor?

    // MARK: - 色彩配置

    private let colorConfig: ColorPipelineConfiguration

    // MARK: - 增量合成追踪

    /// 最近一次收到的 damage report
    private var pendingDamageReport: RemoteDesktopDamageReport?

    // MARK: - 初始化

    /// 创建稳定渲染器。
    /// - Parameters:
    ///   - colorConfig: 色彩管线配置，默认 `.sdr`
    ///   - healthMonitor: 可选的健康监测器，传入时自动记录帧统计。
    public init(colorConfig: ColorPipelineConfiguration = .sdr, healthMonitor: RendererHealthMonitor? = nil) {
        self.colorConfig = colorConfig
        self.healthMonitor = healthMonitor
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
    }

    // MARK: - 生命周期

    public func teardown() {
        invalidateDecompressionSession()
        backingStore = nil
        backingStoreWidth = 0
        backingStoreHeight = 0
        textureCache = nil
        renderQueue.sync {
            pendingDamageReport = nil
        }
    }

    // MARK: - Damage 报告

    /// 设置下一帧的 damage 信息。
    ///
    /// 在 processFrame 之前调用，渲染器将仅更新 dirty rects。
    public func setDamageReport(_ report: RemoteDesktopDamageReport?) {
        renderQueue.sync {
            pendingDamageReport = report
        }
    }

    // MARK: - 帧处理入口

    /// 处理一帧远程桌面数据。
    ///
    /// 根据帧类型走不同的解码路径，然后执行增量合成到 backing store。
    /// 永不抛出异常——任何失败都会回退到 CGImage 兜底。
    @discardableResult
    public func processFrame(
        data: Data,
        width: Int,
        height: Int,
        stride: Int,
        type: RemoteFrameType
    ) -> RenderMetrics {
        let recvTime = DispatchTime.now()
        guard width > 0, height > 0, !data.isEmpty else {
            return RenderMetrics(bandwidthMbps: 0, latencyMilliseconds: 0)
        }

        let delta = interFrameInterval()
        let bandwidth = calculateBandwidth(bytes: data.count, delta: delta)

        switch type {
        case .bgra:
            processBGRAFrame(data: data, width: width, height: height, stride: stride, recvTime: recvTime)
        case .h264, .hevc:
            processCompressedFrame(data: data, width: width, height: height, codec: type, recvTime: recvTime)
        }

        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - recvTime.uptimeNanoseconds) / 1_000_000.0
        previousFrameTimestamp = end

        return RenderMetrics(
            bandwidthMbps: bandwidth,
            latencyMilliseconds: max(elapsed, delta * 1000)
        )
    }

    /// 处理静态图像帧 (JPEG 等)。
    ///
    /// 这是原 `handleStaticImageFallback` 的正式产品化版本。
    @discardableResult
    public func processStaticImage(data: Data) -> RenderMetrics {
        let recvTime = DispatchTime.now()
        guard !data.isEmpty else {
            return RenderMetrics(bandwidthMbps: 0, latencyMilliseconds: 0)
        }

        let delta = interFrameInterval()
        let bandwidth = calculateBandwidth(bytes: data.count, delta: delta)

        // CGImage 路径——终极兜底
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            log.error("Failed to decode static image data (\(data.count) bytes)")
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
        }

        let width = cgImage.width
        let height = cgImage.height

        if let texture = createTextureFromCGImage(cgImage, width: width, height: height) {
            emitTexture(texture, backing: nil, recvTime: recvTime, bytes: data.count)
        } else {
            healthMonitor?.recordDroppedFrame(reason: .textureCreationFailed)
        }

        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - recvTime.uptimeNanoseconds) / 1_000_000.0
        previousFrameTimestamp = end
        return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: max(elapsed, delta * 1000))
    }

    // MARK: - BGRA 帧处理

    private func processBGRAFrame(data: Data, width: Int, height: Int, stride: Int, recvTime: DispatchTime) {
        let frame = BGRAFrame(data: data, width: width, height: height, stride: stride)
        let buffer: CVPixelBuffer
        do {
            buffer = try BGRAFrameBuilder.buildPixelBuffer(from: frame, mode: .safeCopy)
        } catch {
            log.error("BGRA pixel buffer build failed: \(String(describing: error))")
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

        handleDecodedPixelBuffer(buffer, width: width, height: height, recvTime: recvTime, bytes: data.count)
    }

    // MARK: - 压缩帧处理 (H.264 / HEVC)

    private func processCompressedFrame(data: Data, width: Int, height: Int, codec: RemoteFrameType, recvTime: DispatchTime) {
        ensureFormatDescription(width: width, height: height, codec: codec)
        guard let formatDescription else {
            log.error("No format description for \(String(describing: codec))")
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

        ensureDecompressionSession(formatDescription: formatDescription, codec: codec)
        guard let decompressionSession else {
            log.error("No decompression session for \(String(describing: codec))")
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

        // 构建 CMBlockBuffer
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
            log.error("CMBlockBuffer creation failed: \(status)")
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

        data.withUnsafeBytes { pointer in
            if let baseAddress = pointer.baseAddress {
                CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: block,
                    offsetIntoDestination: 0,
                    dataLength: data.count
                )
            }
        }

        // 构建 CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSizes = [data.count]
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sample = sampleBuffer else {
            log.error("CMSampleBuffer creation failed: \(status)")
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

        // 异步解码
        let recvNs = recvTime.uptimeNanoseconds
        let byteCount = data.count
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil,
            outputHandler: { [weak self] decStatus, _, imageBuffer, _, _ in
                guard let self else { return }
                if decStatus != noErr {
                    self.log.error("VT decode error: \(decStatus)")
                    self.healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
                    return
                }
                guard let imageBuffer else {
                    self.healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
                    return
                }
                let w = CVPixelBufferGetWidth(imageBuffer)
                let h = CVPixelBufferGetHeight(imageBuffer)
                let recvDispatchTime = DispatchTime(uptimeNanoseconds: recvNs)
                self.handleDecodedPixelBuffer(
                    imageBuffer,
                    width: w,
                    height: h,
                    recvTime: recvDispatchTime,
                    bytes: byteCount
                )
            }
        )

        if decodeStatus != noErr {
            log.error("VTDecompressionSessionDecodeFrame failed: \(decodeStatus)")
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
        }
    }

    // MARK: - 解码后处理：增量合成到 backing store

    private func handleDecodedPixelBuffer(
        _ pixelBuffer: CVImageBuffer,
        width: Int,
        height: Int,
        recvTime: DispatchTime,
        bytes: Int
    ) {
        guard let textureCache else {
            log.error("No texture cache; falling back to CGImage path")
            handlePixelBufferFallback(pixelBuffer, width: width, height: height, recvTime: recvTime, bytes: bytes)
            return
        }

        // 零拷贝：CVPixelBuffer → CVMetalTexture → MTLTexture
        // 注意：CVMetalTexture 的像素格式必须匹配 pixelBuffer 的实际格式，
        // 而非 colorConfig.pixelFormat（后者用于 backing store 和 pipeline state）。
        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &textureRef
        )
        guard status == kCVReturnSuccess,
              let textureRef,
              let srcTexture = CVMetalTextureGetTexture(textureRef) else {
            log.error("CVMetalTexture creation failed: \(status), falling back to CGImage")
            handlePixelBufferFallback(pixelBuffer, width: width, height: height, recvTime: recvTime, bytes: bytes)
            return
        }

        // 持有 CVMetalTexture + CVImageBuffer 防止提前释放
        let backing = StableRendererBacking(textureRef: textureRef, imageBuffer: pixelBuffer)

        renderQueue.async { [weak self] in
            guard let self else { return }
            self.compositeToBackingStore(
                srcTexture: srcTexture,
                width: width,
                height: height,
                backing: backing,
                recvTime: recvTime,
                bytes: bytes
            )
        }
    }

    /// 增量合成到 backing store
    private func compositeToBackingStore(
        srcTexture: MTLTexture,
        width: Int,
        height: Int,
        backing: StableRendererBacking,
        recvTime: DispatchTime,
        bytes: Int
    ) {
        guard let device, let commandQueue else {
            // Metal 不可用——直接输出源纹理
            emitTexture(srcTexture, backing: backing, recvTime: recvTime, bytes: bytes)
            return
        }

        // 确保 backing store 尺寸匹配
        ensureBackingStore(device: device, width: width, height: height)

        guard let backingStore else {
            // backing store 创建失败——直接输出源纹理
            emitTexture(srcTexture, backing: backing, recvTime: recvTime, bytes: bytes)
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            emitTexture(srcTexture, backing: backing, recvTime: recvTime, bytes: bytes)
            return
        }

        let damage = pendingDamageReport
        pendingDamageReport = nil

        if let damage, !damage.fullFrameFallback, !damage.rects.isEmpty {
            // 增量 blit：只更新 dirty rects
            for rect in damage.rects {
                let x = max(0, Int(rect.x))
                let y = max(0, Int(rect.y))
                let w = min(Int(rect.width), width - x)
                let h = min(Int(rect.height), height - y)
                guard w > 0, h > 0 else { continue }

                let origin = MTLOrigin(x: x, y: y, z: 0)
                let size = MTLSize(width: w, height: h, depth: 1)
                blitEncoder.copy(
                    from: srcTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: origin,
                    sourceSize: size,
                    to: backingStore,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: origin
                )
            }
        } else {
            // 全帧 blit
            let size = MTLSize(width: width, height: height, depth: 1)
            blitEncoder.copy(
                from: srcTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: size,
                to: backingStore,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }

        blitEncoder.endEncoding()
        commandBuffer.addCompletedHandler { [weak self, backingStore] _ in
            guard let self else { return }
            self.emitTexture(backingStore, backing: backing, recvTime: recvTime, bytes: bytes)
        }
        commandBuffer.commit()
    }

    // MARK: - CGImage 兜底路径

    /// 当 Metal 路径全部失败时的终极兜底
    private func handlePixelBufferFallback(
        _ pixelBuffer: CVImageBuffer,
        width: Int,
        height: Int,
        recvTime: DispatchTime,
        bytes: Int
    ) {
        // CVPixelBuffer → CGImage → MTLTexture
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            healthMonitor?.recordDroppedFrame(reason: .textureCreationFailed)
            return
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = colorConfig.makeSourceColorSpace() ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = context.makeImage() else {
            healthMonitor?.recordDroppedFrame(reason: .textureCreationFailed)
            return
        }

        if let texture = createTextureFromCGImage(cgImage, width: width, height: height) {
            renderQueue.async { [weak self] in
                self?.emitTexture(texture, backing: nil, recvTime: recvTime, bytes: bytes)
            }
        } else {
            healthMonitor?.recordDroppedFrame(reason: .textureCreationFailed)
        }
    }

    /// CGImage → MTLTexture（最后兜底路径）
    private func createTextureFromCGImage(_ image: CGImage, width: Int, height: Int) -> MTLTexture? {
        guard let device else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorConfig.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        let bytesPerRow = width * colorConfig.bytesPerPixel
        let totalBytes = bytesPerRow * height
        var pixelData = [UInt8](repeating: 0, count: totalBytes)

        let colorSpace = colorConfig.makeSourceColorSpace() ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: bytesPerRow
        )

        return texture
    }

    // MARK: - Backing Store 管理

    private func ensureBackingStore(device: MTLDevice, width: Int, height: Int) {
        if let existing = backingStore,
           backingStoreWidth == width,
           backingStoreHeight == height {
            _ = existing // 尺寸匹配，复用
            return
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorConfig.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        backingStore = device.makeTexture(descriptor: desc)
        backingStoreWidth = width
        backingStoreHeight = height

        if backingStore != nil {
            log.info("Backing store created: \(width)x\(height)")
        } else {
            log.error("Failed to create backing store: \(width)x\(height)")
        }
    }

    // MARK: - 帧输出

    private func emitTexture(_ texture: MTLTexture, backing: AnyObject?, recvTime: DispatchTime, bytes: Int) {
        let presentTime = DispatchTime.now()
        let latencyNs = presentTime.uptimeNanoseconds - recvTime.uptimeNanoseconds

        healthMonitor?.recordPresentedFrame(latencyNs: latencyNs, recvBytes: bytes)
        frameHandler?(texture, backing)
    }

    // MARK: - VTDecompressionSession 管理

    private func ensureFormatDescription(width: Int, height: Int, codec: RemoteFrameType) {
        guard codec != .bgra else { return }

        var needsNew = formatDescription == nil || currentCodec != codec
        if let desc = formatDescription, !needsNew {
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            needsNew = dims.width != width || dims.height != height
        }
        guard needsNew else { return }

        formatDescription = nil
        currentCodec = nil

        let codecType: CMVideoCodecType = (codec == .h264)
            ? kCMVideoCodecType_H264
            : kCMVideoCodecType_HEVC

        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &desc
        )
        if status == noErr, let desc {
            formatDescription = desc
            currentCodec = codec
        } else {
            log.error("CMVideoFormatDescription creation failed: \(status)")
        }
    }

    private func ensureDecompressionSession(
        formatDescription: CMVideoFormatDescription,
        codec: RemoteFrameType
    ) {
        if decompressionSession != nil, currentCodec == codec {
            return
        }

        invalidateDecompressionSession()

        let destinationAttributes: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        var decoderSpec: CFDictionary?
        if codec == .hevc {
            decoderSpec = [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: false
            ] as CFDictionary
        }

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpec,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        if status == noErr, let session {
            decompressionSession = session
            currentCodec = codec
        } else {
            log.error("VTDecompressionSession creation failed: \(status)")
        }
    }

    private func invalidateDecompressionSession() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        currentCodec = nil
    }

    // MARK: - 工具方法

    private func interFrameInterval() -> Double {
        guard let previous = previousFrameTimestamp else {
            previousFrameTimestamp = DispatchTime.now()
            return 0.016
        }
        let now = DispatchTime.now()
        let delta = Double(now.uptimeNanoseconds - previous.uptimeNanoseconds) / 1_000_000_000.0
        return max(delta, 0.001)
    }

    private func calculateBandwidth(bytes: Int, delta: Double) -> Double {
        guard delta > 0 else { return 0 }
        return (Double(bytes) * 8.0) / (delta * 1_000_000.0)
    }
}

// MARK: - 内部类型

/// 持有 CVMetalTexture 和 CVImageBuffer 的引用，防止 IOSurface 提前释放
private final class StableRendererBacking: @unchecked Sendable {
    let textureRef: CVMetalTexture
    let imageBuffer: CVImageBuffer

    init(textureRef: CVMetalTexture, imageBuffer: CVImageBuffer) {
        self.textureRef = textureRef
        self.imageBuffer = imageBuffer
    }
}

/// VTDecompressionSession 回调上下文的安全封装
private final class StableRendererCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    weak var renderer: StableRenderer?
    private var isActive = true

    init(renderer: StableRenderer) {
        self.renderer = renderer
    }

    func deactivate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    func activeRenderer() -> StableRenderer? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return nil }
        return renderer
    }
}
