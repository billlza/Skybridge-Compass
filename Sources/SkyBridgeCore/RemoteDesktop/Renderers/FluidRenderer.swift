import Foundation
@preconcurrency import Metal
import MetalKit
import VideoToolbox
import CoreVideo
import CoreMedia
import os.log

// MARK: - Fluid Renderer

/// 高性能显示驱动渲染器。
///
/// 核心架构改造：不再"解码回调 push 渲染器"，而是 Apple 风格的"显示驱动拉帧"模型。
///
/// ```
/// VTDecompressionSession (解码线程)
///        │
///        ▼ push
///  [DecodedFrameRingBuffer (3 slots)]
///        │
///        ▼ pull (屏幕刷新时)
///  CVMetalTextureCache → MTLTexture (零拷贝 IOSurface)
///        │
///        ▼
///  Pass-through shader (全屏三角形 + 纹理采样)
///        │
///        ▼
///  MTKView drawable → present
/// ```
///
/// 设计原则：
/// 1. **显示驱动**：MTKView 按屏幕刷新率调用 draw，不是解码回调驱动
/// 2. **最新帧语义**：每次 draw 只取 ring buffer 里最新的一帧，跳过中间帧
/// 3. **没有新帧不重画**：ring buffer 无新数据时，保持上一帧不动
/// 4. **零拷贝渲染**：CVMetalTextureCache + pass-through shader，不走 CIContext
/// 5. **Probation 集成**：通过 RenderingModeController 管理升级/降级
public final class FluidRenderer: @unchecked Sendable {

    // MARK: - 输出

    /// 帧输出回调。texture 为当前帧纹理，backing 持有引用防止提前释放。
    public var frameHandler: ((MTLTexture, AnyObject?) -> Void)?

    // MARK: - Metal 资源

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var pipelineState: MTLRenderPipelineState?

    // MARK: - Ring Buffer

    private let ringBuffer = DecodedFrameRingBuffer(capacity: 3)

    // MARK: - VideoToolbox

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentCodec: RemoteFrameType?

    // MARK: - 状态

    private let log = Logger(subsystem: "com.skybridge.compass", category: "FluidRenderer")
    private var previousFrameTimestamp: DispatchTime?

    /// 上一帧纹理——用于"没有新帧时保持上一帧"
    private var lastTexture: MTLTexture?
    private var lastBacking: AnyObject?

    /// 是否已成功呈现过至少一帧
    private var hasPresented: Bool = false

    // MARK: - 健康监测

    private let healthMonitor: RendererHealthMonitor?

    // MARK: - 色彩配置

    private let colorConfig: ColorPipelineConfiguration

    // MARK: - 初始化

    public init(colorConfig: ColorPipelineConfiguration = .sdr, healthMonitor: RendererHealthMonitor? = nil) {
        self.colorConfig = colorConfig
        self.healthMonitor = healthMonitor
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            buildPipelineState(device: device)
        }
    }

    // MARK: - 生命周期

    public func teardown() {
        invalidateDecompressionSession()
        ringBuffer.reset()
        lastTexture = nil
        lastBacking = nil
        hasPresented = false
        textureCache = nil
        pipelineState = nil
    }

    // MARK: - 帧输入（解码线程调用）

    /// 接收一帧远程桌面数据，解码后推入 ring buffer。
    ///
    /// 此方法由网络接收线程调用。解码在 VT 回调线程完成后自动推入 ring buffer。
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
        return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: max(elapsed, delta * 1000))
    }

    // MARK: - 显示驱动拉帧（主线程 / MTKView.draw 调用）

    /// 在屏幕刷新时调用：从 ring buffer 取最新帧，渲染到输出。
    ///
    /// 此方法应由 MTKView 的 draw(in:) 回调调用。
    /// - 有新帧：零拷贝转 MTLTexture → pass-through shader → emit
    /// - 无新帧：不做任何操作（保持上一帧）
    ///
    /// - Parameter renderPassDescriptor: MTKView 提供的渲染 pass 描述符（可选，仅用于直接渲染到 drawable）
    /// - Parameter drawable: MTKView 的当前 drawable（可选）
    /// - Returns: `true` if a new frame was rendered, `false` if no new frame was available
    @discardableResult
    public func pullAndRender(
        renderPassDescriptor: MTLRenderPassDescriptor? = nil,
        drawable: (any MTLDrawable)? = nil
    ) -> Bool {
        guard let frame = ringBuffer.latestFrame() else {
            return false // 没有新帧，保持上一帧
        }

        let pixelBuffer = frame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let textureCache else {
            healthMonitor?.recordDroppedFrame(reason: .textureCreationFailed)
            return false
        }

        // 零拷贝：CVPixelBuffer → CVMetalTexture → MTLTexture
        // 注意：CVMetalTexture 的像素格式必须匹配 VT 解码输出格式 (BGRA)，
        // 而非 colorConfig.pixelFormat（后者用于 pipeline state）。
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
              let texture = CVMetalTextureGetTexture(textureRef) else {
            log.error("CVMetalTexture creation failed in pull: \(status)")
            healthMonitor?.recordDroppedFrame(reason: .textureCreationFailed)
            return false
        }

        let backing = FluidRendererBacking(textureRef: textureRef, imageBuffer: pixelBuffer)

        // 如果提供了 renderPassDescriptor 和 drawable，直接渲染到 drawable
        if let rpd = renderPassDescriptor, let drawable, let pipelineState, let commandQueue {
            renderToDrawable(
                texture: texture,
                renderPassDescriptor: rpd,
                drawable: drawable,
                pipelineState: pipelineState,
                commandQueue: commandQueue
            )
        }

        // 更新最新帧引用
        lastTexture = texture
        lastBacking = backing
        hasPresented = true

        // 计算延迟并记录
        let presentTime = DispatchTime.now()
        let latencyNs = presentTime.uptimeNanoseconds - frame.recvTimestampNs

        healthMonitor?.recordPresentedFrame(latencyNs: latencyNs, recvBytes: frame.recvBytes)
        frameHandler?(texture, backing)
        return true
    }

    // MARK: - 直接渲染到 MTKView drawable

    private func renderToDrawable(
        texture: MTLTexture,
        renderPassDescriptor: MTLRenderPassDescriptor,
        drawable: any MTLDrawable,
        pipelineState: MTLRenderPipelineState,
        commandQueue: MTLCommandQueue
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        // 全屏三角形：3 顶点，无 vertex buffer
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        // 不 waitUntilCompleted —— triple buffering 自然管理节奏
    }

    // MARK: - Pipeline State 构建

    private func buildPipelineState(device: MTLDevice) {
        // 从 bundle 加载编译后的 Metal shader
        guard let library = loadShaderLibrary(device: device) else {
            log.warning("Pass-through shader library not available; fallback to texture-only mode")
            return
        }

        guard let vertexFunc = library.makeFunction(name: "fluidPassthroughVertex"),
              let fragmentFunc = library.makeFunction(name: "fluidPassthroughFragment") else {
            log.warning("Pass-through shader functions not found in library")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.colorAttachments[0].pixelFormat = colorConfig.pixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            log.info("Fluid pass-through pipeline state created")
        } catch {
            log.error("Failed to create pipeline state: \(String(describing: error))")
        }
    }

    private func loadShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        SkyBridgeMetalShaderLibrary.loadIfAvailable(
            device: device,
            bundle: SkyBridgeResourceBundleLocator.core,
            sourceResourceNames: ["RemoteDesktopPassthrough"],
            requiredFunctionNames: [
                "fluidPassthroughVertex",
                "fluidPassthroughFragment"
            ]
        )
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

        let decodeTime = DispatchTime.now()
        let bufferedFrame = DecodedFrameRingBuffer.BufferedFrame(
            pixelBuffer: buffer,
            recvTimestampNs: recvTime.uptimeNanoseconds,
            decodeTimestampNs: decodeTime.uptimeNanoseconds,
            recvBytes: data.count
        )
        ringBuffer.push(bufferedFrame)
    }

    // MARK: - 压缩帧处理

    private func processCompressedFrame(data: Data, width: Int, height: Int, codec: RemoteFrameType, recvTime: DispatchTime) {
        ensureFormatDescription(width: width, height: height, codec: codec)
        guard let formatDescription else {
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

        ensureDecompressionSession(formatDescription: formatDescription, codec: codec)
        guard let decompressionSession else {
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
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

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
                    self.healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
                    return
                }
                guard let imageBuffer else {
                    self.healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
                    return
                }

                let decodeTime = DispatchTime.now()
                let bufferedFrame = DecodedFrameRingBuffer.BufferedFrame(
                    pixelBuffer: imageBuffer,
                    recvTimestampNs: recvNs,
                    decodeTimestampNs: decodeTime.uptimeNanoseconds,
                    recvBytes: byteCount
                )
                self.ringBuffer.push(bufferedFrame)
            }
        )

        if decodeStatus != noErr {
            log.error("VTDecompressionSessionDecodeFrame failed: \(decodeStatus)")
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
        }
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

        // 高性能模式：强制要求硬件解码
        let decoderSpec: [NSString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        if status == noErr, let session {
            decompressionSession = session
            currentCodec = codec
            // 设置实时解码
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            log.info("Fluid decompression session created (hardware required)")
        } else {
            log.error("Hardware decompression session creation failed: \(status)")
            // 不回退到软件解码——Fluid 模式要求硬件解码
            // RenderingModeController 会检测到失败并降级到 Stable
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

    // MARK: - 查询

    /// Ring buffer 中被跳过的帧数
    public var skippedFrameCount: UInt64 {
        ringBuffer.skippedFrameCount
    }

    /// 是否有未显示的新帧
    public var hasNewFrame: Bool {
        ringBuffer.hasNewFrame
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

private final class FluidRendererBacking: @unchecked Sendable {
    let textureRef: CVMetalTexture
    let imageBuffer: CVImageBuffer

    init(textureRef: CVMetalTexture, imageBuffer: CVImageBuffer) {
        self.textureRef = textureRef
        self.imageBuffer = imageBuffer
    }
}
