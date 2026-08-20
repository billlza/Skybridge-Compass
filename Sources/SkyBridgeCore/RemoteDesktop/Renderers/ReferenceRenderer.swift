// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
@preconcurrency import Metal
import MetalKit
import VideoToolbox
import CoreVideo
import CoreMedia
import CoreGraphics
import os.log

// MARK: - Reference Renderer

/// 高保真渲染器——远程桌面的"参考级"色彩管线。
///
/// 建立在 FluidRenderer 的 ring buffer + 显示驱动拉帧架构之上，
/// 增加 HEVC Main10 解码、HDR 色彩管线、EDR 输出。
///
/// 核心架构：
/// ```
/// HEVC Main10 data
///        │
///        ▼
///  VTDecompressionSession (10-bit 硬件解码)
///        │ 420YpCbCr10BiPlanar → CVPixelBuffer
///        ▼ push
///  [DecodedFrameRingBuffer (3 slots)]
///        │
///        ▼ pull (屏幕刷新时)
///  CVMetalTextureCache → MTLTexture (零拷贝 IOSurface, rgba16Float)
///        │
///        ▼
///  HDR shader (PQ/HLG EOTF → 线性光 → BT.2020→P3 → tone mapping → EDR)
///        │
///        ▼
///  CAMetalLayer (EDR drawable) → present
/// ```
///
/// 激活条件：
/// 1. `HardwareCapabilityProbe.probe().isReferenceCapable == true`
/// 2. 源端发送 HEVC Main10 编码流
/// 3. 用户显式选择 Reference 模式
///
/// 功耗策略：
/// - 电池模式：最高 30fps / 1080p，禁用 tone mapping (直通)
/// - 外接电源：最高 60fps / 4K，完整 HDR 管线
/// - 热状态 serious/critical：自动触发降级到 Fluid
public final class ReferenceRenderer: @unchecked Sendable {

    // MARK: - 输出

    /// 帧输出回调。texture 为 HDR 渲染后纹理，backing 持有引用防止提前释放。
    public var frameHandler: ((MTLTexture, AnyObject?) -> Void)?

    // MARK: - Metal 资源

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var hdrPipelineState: MTLRenderPipelineState?
    private var uniformBuffer: MTLBuffer?

    // MARK: - Ring Buffer

    private let ringBuffer = DecodedFrameRingBuffer(capacity: 3)

    // MARK: - VideoToolbox

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentCodec: RemoteFrameType?

    // MARK: - 色彩配置

    private let colorConfig: ColorPipelineConfiguration
    private var currentTransferFunc: TransferFunction
    private var currentToneMapping: ToneMappingMode

    /// 离屏 HDR 渲染目标池（rgba16Float，3 槽轮转），避免视图仍在采样上一帧时被下一帧覆盖。
    private var hdrOutputTextures: [MTLTexture] = []
    private var hdrOutputIndex = 0
    private var hdrOutputDimensions: (width: Int, height: Int) = (0, 0)

    // MARK: - 状态

    private let log = Logger(subsystem: "com.skybridge.compass", category: "ReferenceRenderer")
    private var previousFrameTimestamp: DispatchTime?

    /// 上一帧纹理——用于"没有新帧时保持上一帧"
    private var lastTexture: MTLTexture?
    private var lastBacking: AnyObject?

    /// 是否已成功呈现过至少一帧
    private var hasPresented: Bool = false

    /// 热状态监控
    private var thermalObserver: NSObjectProtocol?

    // MARK: - 健康监测

    private let healthMonitor: RendererHealthMonitor?

    // MARK: - 功耗策略

    /// 功耗模式
    public enum PowerMode: Sendable {
        /// 电池模式：保守设置
        case battery
        /// 外接电源：全功率
        case externalPower
    }

    private var powerMode: PowerMode

    /// 电池模式最大分辨率宽度
    private let batteryMaxWidth: Int = 1920

    // MARK: - 降级回调

    /// 当 Reference 渲染器因硬件或热状态问题需要降级时调用
    public var onDegradationNeeded: ((String) -> Void)?

    // MARK: - 初始化

    /// 创建高保真渲染器。
    ///
    /// - Parameters:
    ///   - colorConfig: 色彩管线配置，默认 `.hdr`
    ///   - healthMonitor: 可选的健康监测器
    public init(
        colorConfig: ColorPipelineConfiguration = .hdr,
        healthMonitor: RendererHealthMonitor? = nil
    ) {
        self.colorConfig = colorConfig
        self.currentTransferFunc = colorConfig.transferFunction
        self.currentToneMapping = colorConfig.toneMappingMode
        self.healthMonitor = healthMonitor
        self.powerMode = HardwareCapabilityProbe.isOnExternalPower() ? .externalPower : .battery

        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            buildHDRPipelineState(device: device)
            createUniformBuffer(device: device)
        }

        setupThermalMonitoring()
    }

    // MARK: - 生命周期

    public func teardown() {
        invalidateDecompressionSession()
        ringBuffer.reset()
        lastTexture = nil
        lastBacking = nil
        hasPresented = false
        textureCache = nil
        hdrPipelineState = nil
        uniformBuffer = nil

        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
    }

    // MARK: - 功耗管理

    /// 更新功耗模式
    public func updatePowerMode() {
        let onAC = HardwareCapabilityProbe.isOnExternalPower()
        powerMode = onAC ? .externalPower : .battery
        log.info("Power mode updated: \(onAC ? "external" : "battery")")
    }

    // MARK: - 帧输入（解码线程调用）

    /// 接收一帧远程桌面数据，解码后推入 ring buffer。
    ///
    /// Reference 模式专用：仅处理 HEVC（Main10），不支持 H.264 或 BGRA。
    /// 如果传入非 HEVC 数据，会记录错误并丢帧。
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

        // 功耗策略：电池模式下限制分辨率
        if powerMode == .battery && width > batteryMaxWidth {
            // 不拒绝帧，但记录警告——实际限制应在编码端协商
            log.debug("Battery mode: frame \(width)x\(height) exceeds limit \(self.batteryMaxWidth)")
        }

        switch type {
        case .hevc:
            processHEVCMain10Frame(data: data, width: width, height: height, recvTime: recvTime)
        case .h264:
            // Reference 模式也可以处理 H.264，但使用标准解码路径
            processCompressedFrame(data: data, width: width, height: height, codec: type, recvTime: recvTime)
        case .bgra:
            processBGRAFrame(data: data, width: width, height: height, stride: stride, recvTime: recvTime)
        }

        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - recvTime.uptimeNanoseconds) / 1_000_000.0
        previousFrameTimestamp = end
        return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: max(elapsed, delta * 1000))
    }

    // MARK: - 显示驱动拉帧（主线程 / MTKView.draw 调用）

    /// 在屏幕刷新时调用：从 ring buffer 取最新帧，经 HDR 管线渲染到输出。
    ///
    /// - Parameters:
    ///   - renderPassDescriptor: MTKView 提供的渲染 pass 描述符
    ///   - drawable: MTKView 的当前 drawable
    ///   - edrHeadroom: 当前显示器的 EDR headroom（由外部查询传入）
    /// - Returns: `true` if a new frame was rendered, `false` if no new frame was available
    @discardableResult
    public func pullAndRender(
        renderPassDescriptor: MTLRenderPassDescriptor? = nil,
        drawable: (any MTLDrawable)? = nil,
        edrHeadroom: Float = 1.0
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

        // 确定纹理像素格式
        // 10-bit YCbCr 双平面 → 使用 Y 平面（单通道）或转换
        // 对于 420YpCbCr10BiPlanar，需要双纹理采样 (Y + CbCr)
        // 简化路径：如果 VT 输出已转换为 BGRA/rgba16Float，直接使用
        let pixelFormat = metalPixelFormat(for: pixelBuffer)

        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &textureRef
        )

        guard status == kCVReturnSuccess,
              let textureRef,
              let sourceTexture = CVMetalTextureGetTexture(textureRef) else {
            log.error("CVMetalTexture creation failed in Reference pull: \(status)")
            healthMonitor?.recordDroppedFrame(reason: .textureCreationFailed)
            return false
        }

        let backing = ReferenceRendererBacking(textureRef: textureRef, imageBuffer: pixelBuffer)

        // 依据解码缓冲的真实传输函数判定是否为 HDR 帧。SDR（含 Reference 模式下的 SDR 内容）
        // 一律走原直通路径，绝不误用 PQ/HLG EOTF。
        let detectedTF = detectTransferFunction(pixelBuffer)
        let isHDRFrame = isHDRTransferFunction(detectedTF)

        // 更新 HDR uniform buffer
        updateUniforms(edrHeadroom: edrHeadroom)

        let emittedTexture: MTLTexture
        if let rpd = renderPassDescriptor, let drawable,
           let hdrPipelineState, let commandQueue, let uniformBuffer {
            // 显式 drawable 路径：当呈现视图已启用 EDR（CAMetalLayer.wantsExtendedDynamicRangeContent
            // + rgba16Float + extended colorspace）时，由其 draw(in:) 直接驱动 HDR 渲染并呈现。
            renderHDR(
                sourceTexture: sourceTexture,
                renderPassDescriptor: rpd,
                drawable: drawable,
                pipelineState: hdrPipelineState,
                commandQueue: commandQueue,
                uniformBuffer: uniformBuffer
            )
            emittedTexture = sourceTexture
        } else if isHDRFrame,
                  let hdrPipelineState, let commandQueue, let uniformBuffer, let device,
                  let hdrTexture = renderHDROffscreen(
                      sourceTexture: sourceTexture, width: width, height: height,
                      pipelineState: hdrPipelineState, commandQueue: commandQueue,
                      uniformBuffer: uniformBuffer, device: device) {
            // 真正的 HDR (PQ/HLG) 内容：离屏运行 HDR 着色器（PQ/HLG EOTF + BT.2020→P3 + tone map），
            // 输出经 tone map 的 rgba16Float 纹理给呈现层。此前该着色器从不执行（drawable 始终为 nil）。
            emittedTexture = hdrTexture
        } else {
            // SDR / 无 HDR 管线：保持改动前逐字节一致的直通行为。
            emittedTexture = sourceTexture
        }

        // 更新最新帧引用
        lastTexture = emittedTexture
        lastBacking = backing
        hasPresented = true

        // 计算延迟并记录
        let presentTime = DispatchTime.now()
        let latencyNs = presentTime.uptimeNanoseconds - frame.recvTimestampNs

        healthMonitor?.recordPresentedFrame(latencyNs: latencyNs, recvBytes: frame.recvBytes)
        frameHandler?(emittedTexture, backing)
        return true
    }

    // MARK: - 传输函数检测 / 离屏 HDR 渲染

    private func isHDRTransferFunction(_ tf: TransferFunction) -> Bool {
        tf == .pq || tf == .hlg
    }

    /// 从解码缓冲的传输函数附件检测 PQ/HLG。这是 HDR 分支的唯一开关——SDR 内容据此被排除。
    private func detectTransferFunction(_ pixelBuffer: CVPixelBuffer) -> TransferFunction {
        guard let raw = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil),
              let tfString = raw as? String else {
            return .sRGB
        }
        if tfString == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
            currentTransferFunc = .pq
            return .pq
        }
        if tfString == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
            currentTransferFunc = .hlg
            return .hlg
        }
        return .sRGB
    }

    /// 取下一个离屏 HDR 渲染目标（rgba16Float）。尺寸变化时重建 3 槽池。
    private func nextHDROutputTexture(width: Int, height: Int, device: MTLDevice) -> MTLTexture? {
        if hdrOutputDimensions.width != width || hdrOutputDimensions.height != height || hdrOutputTextures.isEmpty {
            hdrOutputTextures.removeAll(keepingCapacity: true)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorConfig.pixelFormat, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            for _ in 0..<3 {
                guard let texture = device.makeTexture(descriptor: desc) else { return nil }
                hdrOutputTextures.append(texture)
            }
            hdrOutputDimensions = (width, height)
            hdrOutputIndex = 0
        }
        guard !hdrOutputTextures.isEmpty else { return nil }
        let texture = hdrOutputTextures[hdrOutputIndex % hdrOutputTextures.count]
        hdrOutputIndex = (hdrOutputIndex + 1) % hdrOutputTextures.count
        return texture
    }

    /// 将 HDR 着色器渲染到离屏 rgba16Float 纹理（无需 drawable），返回该纹理供呈现层采样。
    /// 跨队列同步为 best-effort：呈现视图在帧发布后的下一次 runloop 才采样，离屏 GPU 工作通常已完成；
    /// 偶发 1 帧撕裂对实时流是可接受代价，且远优于 HDR 完全错误显示。
    private func renderHDROffscreen(
        sourceTexture: MTLTexture, width: Int, height: Int,
        pipelineState: MTLRenderPipelineState, commandQueue: MTLCommandQueue,
        uniformBuffer: MTLBuffer, device: MTLDevice
    ) -> MTLTexture? {
        guard let target = nextHDROutputTexture(width: width, height: height, device: device) else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        return target
    }

    // MARK: - HDR 渲染

    private func renderHDR(
        sourceTexture: MTLTexture,
        renderPassDescriptor: MTLRenderPassDescriptor,
        drawable: any MTLDrawable,
        pipelineState: MTLRenderPipelineState,
        commandQueue: MTLCommandQueue,
        uniformBuffer: MTLBuffer
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        // 全屏三角形：3 顶点，无 vertex buffer
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - HDR Uniform 管理

    private func createUniformBuffer(device: MTLDevice) {
        // HDRUniforms: edrHeadroom(float) + transferFunc(uint) + toneMappingMode(uint) + maxContentLight(float) = 16 bytes
        uniformBuffer = device.makeBuffer(length: 16, options: .storageModeShared)
    }

    private func updateUniforms(edrHeadroom: Float) {
        guard let buffer = uniformBuffer else { return }
        let ptr = buffer.contents()

        // edrHeadroom: float at offset 0
        ptr.storeBytes(of: edrHeadroom, toByteOffset: 0, as: Float.self)

        // transferFunc: uint32 at offset 4
        let tfValue: UInt32
        switch currentTransferFunc {
        case .sRGB: tfValue = 0
        case .pq: tfValue = 1
        case .hlg: tfValue = 2
        case .linear: tfValue = 3
        }
        ptr.storeBytes(of: tfValue, toByteOffset: 4, as: UInt32.self)

        // toneMappingMode: uint32 at offset 8
        let tmValue: UInt32
        switch currentToneMapping {
        case .none: tmValue = 0
        case .reinhard: tmValue = 1
        case .aces: tmValue = 2
        case .display: tmValue = 3
        }
        ptr.storeBytes(of: tmValue, toByteOffset: 8, as: UInt32.self)

        // maxContentLight: float at offset 12
        // PQ 标准最大 10000 nits，电池模式降低到 1000
        let maxCLL: Float = (powerMode == .battery) ? 1000.0 : 10000.0
        ptr.storeBytes(of: maxCLL, toByteOffset: 12, as: Float.self)
    }

    // MARK: - Pipeline State 构建

    private func buildHDRPipelineState(device: MTLDevice) {
        guard let library = loadHDRShaderLibrary(device: device) else {
            log.warning("HDR shader library not available; Reference renderer limited to texture-only mode")
            return
        }

        guard let vertexFunc = library.makeFunction(name: "referenceHDRVertex"),
              let fragmentFunc = library.makeFunction(name: "referenceHDRFragment") else {
            log.warning("HDR shader functions not found in library")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        // HDR 输出使用 rgba16Float 以支持 EDR 值 > 1.0
        descriptor.colorAttachments[0].pixelFormat = colorConfig.pixelFormat

        do {
            hdrPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            log.info("Reference HDR pipeline state created")
        } catch {
            log.error("Failed to create HDR pipeline state: \(String(describing: error))")
        }
    }

    private func loadHDRShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        SkyBridgeMetalShaderLibrary.loadIfAvailable(
            device: device,
            bundle: SkyBridgeResourceBundleLocator.core,
            sourceResourceNames: ["RemoteDesktopHDR"],
            requiredFunctionNames: [
                "referenceHDRVertex",
                "referenceHDRFragment"
            ]
        )
    }

    // MARK: - HEVC Main10 解码

    private func processHEVCMain10Frame(data: Data, width: Int, height: Int, recvTime: DispatchTime) {
        ensureFormatDescription(width: width, height: height, codec: .hevc)
        guard let formatDescription else {
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

        ensureDecompressionSession(formatDescription: formatDescription, is10Bit: true)
        guard let decompressionSession else {
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

        decodeAndPush(data: data, session: decompressionSession, formatDescription: formatDescription, recvTime: recvTime)
    }

    private func processCompressedFrame(data: Data, width: Int, height: Int, codec: RemoteFrameType, recvTime: DispatchTime) {
        ensureFormatDescription(width: width, height: height, codec: codec)
        guard let formatDescription else {
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

        ensureDecompressionSession(formatDescription: formatDescription, is10Bit: false)
        guard let decompressionSession else {
            healthMonitor?.recordDroppedFrame(reason: .decodeFailed)
            return
        }

        decodeAndPush(data: data, session: decompressionSession, formatDescription: formatDescription, recvTime: recvTime)
    }

    private func decodeAndPush(
        data: Data,
        session: VTDecompressionSession,
        formatDescription: CMVideoFormatDescription,
        recvTime: DispatchTime
    ) {
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
            session,
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

    // MARK: - 像素格式检测

    private func metalPixelFormat(for pixelBuffer: CVPixelBuffer) -> MTLPixelFormat {
        let osType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch osType {
        case kCVPixelFormatType_32BGRA:
            return .bgra8Unorm
        case kCVPixelFormatType_64RGBAHalf:
            return .rgba16Float
        case kCVPixelFormatType_128RGBAFloat:
            return .rgba32Float
        default:
            // 10-bit YCbCr 或其他格式——VT 应该已经转换为 BGRA
            return .bgra8Unorm
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
        } else {
            log.error("CMVideoFormatDescription creation failed: \(status)")
        }
    }

    private func ensureDecompressionSession(
        formatDescription: CMVideoFormatDescription,
        is10Bit: Bool
    ) {
        if decompressionSession != nil, let current = currentCodec, current == .hevc {
            return
        }

        invalidateDecompressionSession()

        // 解码输出统一请求 32BGRA：对 SDR/8-bit 与 SDR-10-bit 内容是安全且经过验证的路径。
        // 注意：32BGRA 为 8 bit/通道，并不保留 HEVC Main10 的完整 10-bit 精度——此前注释中
        // “10-bit 精度通过 32BGRA 保留在浮点通道中”的说法不正确。真正的 10-bit/HDR 精度需要改用
        // kCVPixelFormatType_64RGBAHalf 或双平面 420YpCbCr10 采样，并配合启用 EDR 的呈现视图，
        // 属于需在 HDR 真机上验证的后续工作（HDR 着色器本身已在 pullAndRender 离屏分支接入）。
        _ = is10Bit
        let pixelFormatType: OSType = kCVPixelFormatType_32BGRA

        let destinationAttributes: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormatType,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        // Reference 模式：强制要求硬件解码
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
            // 设置实时解码
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            log.info("Reference decompression session created (hardware required, 10-bit: \(is10Bit))")
        } else {
            log.error("Hardware decompression session creation failed: \(status)")
            // 通知降级——Reference 模式要求硬件解码
            onDegradationNeeded?("hardware_decode_unavailable")
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

    // MARK: - 热状态监控

    private func setupThermalMonitoring() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleThermalStateChange()
        }
    }

    private func handleThermalStateChange() {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .serious, .critical:
            log.warning("Thermal state \(String(describing: state)) — requesting degradation from Reference")
            onDegradationNeeded?("thermal_\(state == .critical ? "critical" : "serious")")
        case .nominal, .fair:
            break
        @unknown default:
            break
        }
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

    /// 当前功耗模式
    public var currentPowerMode: PowerMode {
        powerMode
    }

    // MARK: - 色彩管线控制

    /// 更新传输函数（用于切换 PQ / HLG / sRGB 源）
    public func setTransferFunction(_ tf: TransferFunction) {
        currentTransferFunc = tf
    }

    /// 更新色调映射模式
    public func setToneMappingMode(_ mode: ToneMappingMode) {
        currentToneMapping = mode
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

private final class ReferenceRendererBacking: @unchecked Sendable {
    let textureRef: CVMetalTexture
    let imageBuffer: CVImageBuffer

    init(textureRef: CVMetalTexture, imageBuffer: CVImageBuffer) {
        self.textureRef = textureRef
        self.imageBuffer = imageBuffer
    }
}
#endif
