//
// UltraStream.swift
// SkyBridge Compass Pro
//
// UltraStream v1: 局域网高性能远程桌面传输协议 + 解码层
//
// 要求：
// - macOS 26.0+ 才启用（Metal 4 / CryptoKit PQC / Network QUIC）
// - 依赖现有的：RemoteFrameRenderer / RemoteFrameType / RemoteTextureFeed / ScreenCaptureKitStreamer
//

import Foundation
import Network
import OSLog
import CryptoKit
import Metal
import ScreenCaptureKit
import VideoToolbox
import CoreMedia

#if HAS_APPLE_PQC_SDK

// MARK: - 公共配置 & 错误

@available(macOS 26.0, *)
public struct UltraStreamConfig: Sendable {
    public enum Codec: UInt8, Sendable {
        case h264 = 1
        case hevc = 2
    }
    
 /// 目标帧率（建议：60，在 4K/5K 场景上限 90，120 只在超高端 + 近距离环境尝试）
    public var targetFPS: Int
    
 /// 最大分辨率（编码前可以做降采样）
    public var maxResolution: CGSize
    
 /// 码率上限（bps），交给 VTCompressionSession 做软限制
    public var maxBitrate: Int
    
 /// 使用的编码器类型
    public var codec: Codec
    
 /// 帧内 GOP（关键帧间隔，单位：帧数）
    public var keyFrameInterval: Int
    
 /// 每个 UDP/QUIC 数据包负载大小（不含协议头），建议 1200~1400 之间
    public var mtu: Int
    
    public init(
        targetFPS: Int = 60,
        maxResolution: CGSize = CGSize(width: 3840, height: 2160),
        maxBitrate: Int = 25_000_000,
        codec: Codec = .hevc,
        keyFrameInterval: Int = 60,
        mtu: Int = 1200
    ) {
        self.targetFPS = max(15, min(240, targetFPS))
        self.maxResolution = maxResolution
        self.maxBitrate = max(2_000_000, maxBitrate)
        self.codec = codec
        self.keyFrameInterval = max(10, keyFrameInterval)
        self.mtu = max(512, min(12_000, mtu))
    }
}

@available(macOS 26.0, *)
public enum UltraStreamError: Error, LocalizedError, Sendable {
    case unsupportedOS
    case connectionNotReady
    case missingSymmetricKey
    case invalidHeader
    case decryptionFailed
    case codecNotSupported
    case streamStopped
    case internalError(String)
 // 握手相关错误
    case handshakeTimeout
    case handshakeFailed(String)
    case handshakeRejected
    case invalidHandshakeMessage
    case keyExchangeFailed
 // 网络相关错误
    case networkError(underlying: Error?)
    case connectionLost
    case packetLossExceeded
 // 帧重组相关错误
    case frameReassemblyTimeout
    case frameCorrupted
    case duplicateFrame
    
    public var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "当前系统版本不支持 UltraStream（需要 macOS 26.0+）"
        case .connectionNotReady:
            return "网络连接尚未就绪"
        case .missingSymmetricKey:
            return "会话对称密钥未初始化（请先完成 PQC 协商）"
        case .invalidHeader:
            return "收到的 UltraStream 包头无效"
        case .decryptionFailed:
            return "UltraStream 数据解密失败"
        case .codecNotSupported:
            return "不支持的编码器类型"
        case .streamStopped:
            return "UltraStream 会话已停止"
        case .internalError(let msg):
            return "UltraStream 内部错误：\(msg)"
        case .handshakeTimeout:
            return "握手超时（请检查网络连接）"
        case .handshakeFailed(let reason):
            return "握手失败：\(reason)"
        case .handshakeRejected:
            return "握手被拒绝（可能是身份验证失败）"
        case .invalidHandshakeMessage:
            return "无效的握手消息格式"
        case .keyExchangeFailed:
            return "密钥交换失败"
        case .networkError(let underlying):
            if let underlying = underlying {
                return "网络错误：\(underlying.localizedDescription)"
            }
            return "网络错误"
        case .connectionLost:
            return "连接已断开"
        case .packetLossExceeded:
            return "数据包丢失率过高"
        case .frameReassemblyTimeout:
            return "帧重组超时"
        case .frameCorrupted:
            return "帧数据损坏"
        case .duplicateFrame:
            return "收到重复帧"
        }
    }
    
 /// 判断错误是否可重试
    public var isRetriable: Bool {
        switch self {
        case .handshakeTimeout, .networkError, .connectionLost, .packetLossExceeded, .frameReassemblyTimeout:
            return true
        case .handshakeRejected, .keyExchangeFailed, .decryptionFailed, .frameCorrupted:
            return false
        default:
            return false
        }
    }
}

// MARK: - 协议头定义（纯二进制）

@available(macOS 26.0, *)
fileprivate struct UltraStreamFlags: OptionSet {
    let rawValue: UInt8
    
 /// 握手包（payload = 会话密钥封装、元信息等）
    static let handshake = UltraStreamFlags(rawValue: 1 << 0)
    
 /// 关键帧
    static let keyFrame = UltraStreamFlags(rawValue: 1 << 1)
    
 /// 预留：前向纠错开启
    static let fecEnabled = UltraStreamFlags(rawValue: 1 << 2)
}

/// UltraStream v1 二进制帧头：28 字节
///
/// 字节布局（全部网络字节序：大端）
/// 0 - 3 : magic 'USTR'
/// 4 : version
/// 5 : flags
/// 6 : codecRaw (1 = H264, 2 = HEVC; 握手包可以为 0)
/// 7 : reserved
/// 8 - 11: frameId
/// 12 - 15: timestampMs（客户端本地时间，相对会话启动时刻）
/// 16 - 17: width
/// 18 - 19: height
/// 20 - 21: chunkIndex
/// 22 - 23: chunkCount
/// 24 - 27: payloadLength
///
@available(macOS 26.0, *)
fileprivate struct UltraStreamHeader {
    static let magic: UInt32 = 0x55535452 // ASCII "USTR"
    static let length: Int = 28
    static let versionCurrent: UInt8 = 1
    
    var version: UInt8
    var flags: UltraStreamFlags
    var codecRaw: UInt8
    var reserved: UInt8
    var frameId: UInt32
    var timestampMs: UInt32
    var width: UInt16
    var height: UInt16
    var chunkIndex: UInt16
    var chunkCount: UInt16
    var payloadLength: UInt32
    
    init(
        flags: UltraStreamFlags,
        codecRaw: UInt8,
        frameId: UInt32,
        timestampMs: UInt32,
        width: UInt16,
        height: UInt16,
        chunkIndex: UInt16,
        chunkCount: UInt16,
        payloadLength: UInt32
    ) {
        self.version = Self.versionCurrent
        self.flags = flags
        self.codecRaw = codecRaw
        self.reserved = 0
        self.frameId = frameId
        self.timestampMs = timestampMs
        self.width = width
        self.height = height
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.payloadLength = payloadLength
    }
    
 /// 生成用于 AEAD 的 AAD：不包含 payloadLength 和 magic
 /// 这样分片时所有 chunk 使用相同 AAD，只靠 frameId/seq 保证唯一性
    func aadData() -> Data {
        var data = Data(capacity: 4 + 1 + 1 + 1 + 4 + 4 + 2 + 2 + 2 + 2)
        
        func append<T>(_ v: T) {
            var value = v
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        
 // 使用常量 magic 保证双方一致
        var magicBE = UltraStreamHeader.magic.bigEndian
        withUnsafeBytes(of: &magicBE) { data.append(contentsOf: $0) }
        
        append(version)
        append(flags.rawValue)
        append(codecRaw)
        append(reserved)
        append(frameId.bigEndian)
        append(timestampMs.bigEndian)
        append(width.bigEndian)
        append(height.bigEndian)
        append(chunkIndex.bigEndian)
        append(chunkCount.bigEndian)
        
        return data
    }
    
    func encode() -> Data {
        var data = Data(capacity: UltraStreamHeader.length)
        
        func append<T>(_ v: T) {
            var value = v
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        
        var magicBE = UltraStreamHeader.magic.bigEndian
        withUnsafeBytes(of: &magicBE) { data.append(contentsOf: $0) }
        
        append(version)
        append(flags.rawValue)
        append(codecRaw)
        append(reserved)
        append(frameId.bigEndian)
        append(timestampMs.bigEndian)
        append(width.bigEndian)
        append(height.bigEndian)
        append(chunkIndex.bigEndian)
        append(chunkCount.bigEndian)
        append(payloadLength.bigEndian)
        
        return data
    }
    
    init?(data: Data) {
        guard data.count >= UltraStreamHeader.length else { return nil }
        
        func read<T>(_ type: T.Type, _ offset: inout Int) -> T {
            let size = MemoryLayout<T>.size
            let range = offset ..< (offset + size)
            let value = data[range].withUnsafeBytes { $0.load(as: T.self) }
            offset += size
            return value
        }
        
        var offset = 0
        let magicBE: UInt32 = read(UInt32.self, &offset)
        let magic = UInt32(bigEndian: magicBE)
        guard magic == UltraStreamHeader.magic else { return nil }
        
        let ver: UInt8 = read(UInt8.self, &offset)
        version = ver
        
        let flagRaw: UInt8 = read(UInt8.self, &offset)
        flags = UltraStreamFlags(rawValue: flagRaw)
        
        let codec: UInt8 = read(UInt8.self, &offset)
        codecRaw = codec
        
        reserved = read(UInt8.self, &offset)
        frameId = UInt32(bigEndian: read(UInt32.self, &offset))
        timestampMs = UInt32(bigEndian: read(UInt32.self, &offset))
        width = UInt16(bigEndian: read(UInt16.self, &offset))
        height = UInt16(bigEndian: read(UInt16.self, &offset))
        chunkIndex = UInt16(bigEndian: read(UInt16.self, &offset))
        chunkCount = UInt16(bigEndian: read(UInt16.self, &offset))
        payloadLength = UInt32(bigEndian: read(UInt32.self, &offset))
    }
}

// MARK: - 帧重组结构

@available(macOS 26.0, *)
fileprivate struct UltraStreamFrameAssembly {
    let frameId: UInt32
    let codec: UltraStreamConfig.Codec
    let width: Int
    let height: Int
    let timestampMs: UInt32
    let totalChunks: Int
    var receivedChunks: [Int: Data] = [:]
    
    mutating func insert(chunkIndex: Int, data: Data) {
        receivedChunks[chunkIndex] = data
    }
    
    var isComplete: Bool {
        return receivedChunks.count == totalChunks
    }
    
    func combinedData() -> Data? {
        guard isComplete else { return nil }
        var buffer = Data()
        for idx in 0..<totalChunks {
            guard let chunk = receivedChunks[idx] else { return nil }
            buffer.append(chunk)
        }
        return buffer
    }
}

// MARK: - 会话级对称加密（AES.GCM）

///
/// 注意：
/// - 对称密钥应该由上层的 CryptoKit HPKE (XWing ML-KEM) 协商得到；
/// - 这里不再关心 PQC，只负责帧级加密/解密。
///
@available(macOS 26.0, *)
fileprivate struct UltraStreamCrypto {
    let key: SymmetricKey
    
    init(key: SymmetricKey) {
        self.key = key
    }
    
    func encrypt(plaintext: Data, aad: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else {
            throw UltraStreamError.internalError("AES.GCM.sealedBox.combined 为空")
        }
        return combined
    }
    
    func decrypt(ciphertext: Data, aad: Data) throws -> Data {
        let sealed = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(sealed, using: key, authenticating: aad)
        return plaintext
    }
}

// MARK: - UltraStream 发送端

/// UltraStream 发送端：
/// - 依赖：ScreenCaptureKitStreamer（编码）
/// - 输出：通过 NWConnection 发送二进制包
@available(macOS 26.0, *)
@MainActor
public final class UltraStreamSender {
    private let log = Logger(subsystem: "com.skybridge.compass", category: "UltraStreamSender")
    private let connection: NWConnection
    private let config: UltraStreamConfig
    private let crypto: UltraStreamCrypto
    private let captureStreamer = ScreenCaptureKitStreamer()
    private var frameId: UInt32 = 0
    private var startTime: Date = Date()
    private var running = false
    private let sendQueue = DispatchQueue(label: "com.skybridge.ultrastream.sender")
    
 /// - Parameters:
 /// - host: 对端主机（IPv4/IPv6）
 /// - port: 对端端口
 /// - symmetricKey: 会话对称密钥（由上层 PQC 协商获得）
 /// - config: UltraStream 参数
    public init(
        host: String,
        port: UInt16,
        symmetricKey: SymmetricKey,
        config: UltraStreamConfig = UltraStreamConfig()
    ) {
        self.config = config
        self.crypto = UltraStreamCrypto(key: symmetricKey)
        
 // 使用 QUIC 优先，失败时可以由上层自动降级为 TCP/UDP
        let quicOptions = NWProtocolQUIC.Options()
        quicOptions.isDatagram = true
        let parameters = NWParameters(quic: quicOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        
        let endpoint = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 443
        
        self.connection = NWConnection(host: endpoint, port: nwPort, using: parameters)
    }
    
    public func start() async throws {
        guard !running else { return }
        running = true
        startTime = Date()
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.info("UltraStream Sender connection ready")
            case .failed(let error):
                self.log.error("UltraStream Sender connection failed: \(String(describing: error))")
            case .cancelled:
                self.log.info("UltraStream Sender connection cancelled")
            default:
                break
            }
        }
        
        connection.start(queue: sendQueue)
        
 // 绑定编码回调 -> UltraStream 发送
        captureStreamer.onEncodedFrame = { [weak self] data, w, h, type in
            guard let self else { return }
 // 在主线程捕获值，然后在后台队列处理
            let frameType = type
            self.sendQueue.async { [weak self] in
                guard let self else { return }
 // 捕获 Sendable 类型 - 符合 Swift 6.2.1 的严格并发要求
                let capturedFrameType = frameType // RemoteFrameType 已符合 Sendable
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleEncodedFrame(data: data, width: w, height: h, frameType: capturedFrameType)
                }
            }
        }
        
 // 启动屏幕采集 + VTCompressionSession（你原来的 ScreenCaptureKitStreamer）
        let frameType: RemoteFrameType = (config.codec == .hevc) ? .hevc : .h264
        try await captureStreamer.start(
            preferredCodec: frameType,
            preferredSize: config.maxResolution,
            targetFPS: config.targetFPS,
            keyFrameInterval: config.keyFrameInterval
        )
        
        log.info("UltraStream Sender started")
    }
    
    public func stop() {
        guard running else { return }
        running = false
        captureStreamer.stop()
        connection.cancel()
        log.info("UltraStream Sender stopped")
    }
    
 /// 处理编码后的单帧数据 -> 分片 + 加密 + 发送
    private func handleEncodedFrame(
        data: Data,
        width: Int,
        height: Int,
        frameType: RemoteFrameType
    ) {
        guard running else { return }
        
        let codecRaw: UInt8
        switch config.codec {
        case .h264: codecRaw = UltraStreamConfig.Codec.h264.rawValue
        case .hevc: codecRaw = UltraStreamConfig.Codec.hevc.rawValue
        }
        
        frameId &+= 1
        let elapsed = Date().timeIntervalSince(startTime)
        let timestampMs = UInt32(elapsed * 1000.0)
        
 // 简化：目前无法从回调中精确判断关键帧，先全部标非关键帧；
 // 如你在 ScreenCaptureKitStreamer 中有 isKeyFrame 标记，可以在这里加 flags.insert(.keyFrame)
        let flags: UltraStreamFlags = []
        
        let totalCipher: Data
        do {
            let headerForAAD = UltraStreamHeader(
                flags: flags,
                codecRaw: codecRaw,
                frameId: frameId,
                timestampMs: timestampMs,
                width: UInt16(clamping: width),
                height: UInt16(clamping: height),
                chunkIndex: 0,
                chunkCount: 0,
                payloadLength: 0
            )
            let aad = headerForAAD.aadData()
            totalCipher = try crypto.encrypt(plaintext: data, aad: aad)
        } catch {
            log.error("UltraStream encrypt failed: \(error.localizedDescription)")
            return
        }
        
        let mtu = config.mtu
        let totalLength = totalCipher.count
        let totalChunks = Int(ceil(Double(totalLength) / Double(mtu)))
        
        for chunkIndex in 0..<totalChunks {
            let start = chunkIndex * mtu
            let end = min(start + mtu, totalLength)
            let chunk = totalCipher.subdata(in: start..<end)
            
            let header = UltraStreamHeader(
                flags: flags,
                codecRaw: codecRaw,
                frameId: frameId,
                timestampMs: timestampMs,
                width: UInt16(clamping: width),
                height: UInt16(clamping: height),
                chunkIndex: UInt16(chunkIndex),
                chunkCount: UInt16(totalChunks),
                payloadLength: UInt32(chunk.count)
            )
            
            let packet = header.encode() + chunk
            sendPacket(packet)
        }
    }
    
    private func sendPacket(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log.error("UltraStream send error: \(error.localizedDescription)")
            }
        })
    }
}

// MARK: - UltraStream 接收端

/// UltraStream 接收端：
/// - 依赖：RemoteFrameRenderer + RemoteTextureFeed（渲染）
/// - 输入：NWConnection 收到的二进制包
@available(macOS 26.0, *)
@MainActor
public final class UltraStreamReceiver {
    private let log = Logger(subsystem: "com.skybridge.compass", category: "UltraStreamReceiver")
    private let connection: NWConnection
    private let crypto: UltraStreamCrypto
    private let renderer: RemoteFrameRenderer
    private let textureFeed: RemoteTextureFeed
    private let receiveQueue = DispatchQueue(label: "com.skybridge.ultrastream.receiver")
    private var running = false
    
 /// frameId -> 重组状态
    private var assemblies: [UInt32: UltraStreamFrameAssembly] = [:]
    
 /// 握手状态
    private var handshakeState: HandshakeState = .waiting
    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private let handshakeTimeout: TimeInterval = 10.0
    private var handshakeTimer: Timer?
    
 /// 帧重组超时管理（清理过期帧）
    private var frameTimestamps: [UInt32: Date] = [:]
    private let frameTimeout: TimeInterval = 5.0
    private var frameCleanupTimer: Timer?
    
    private enum HandshakeState: CustomStringConvertible {
        case waiting
        case inProgress
        case completed
        case failed
        
        var description: String {
            switch self {
            case .waiting: return "waiting"
            case .inProgress: return "inProgress"
            case .completed: return "completed"
            case .failed: return "failed"
            }
        }
    }
    
    public init(
        connection: NWConnection,
        symmetricKey: SymmetricKey,
        renderer: RemoteFrameRenderer,
        textureFeed: RemoteTextureFeed
    ) {
        self.connection = connection
        self.crypto = UltraStreamCrypto(key: symmetricKey)
        self.renderer = renderer
        self.textureFeed = textureFeed
    }
    
    public func start() async throws {
        guard !running else { return }
        running = true
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.log.info("UltraStream Receiver connection ready")
                case .failed(let error):
                    self.log.error("UltraStream Receiver connection failed: \(String(describing: error))")
                    self.handshakeState = .failed
                    if let cont = self.handshakeContinuation {
                        self.handshakeContinuation = nil
                        cont.resume(throwing: UltraStreamError.networkError(underlying: error))
                    }
                case .cancelled:
                    self.log.info("UltraStream Receiver connection cancelled")
                    self.handshakeState = .failed
                default:
                    break
                }
            }
        }
        
        connection.start(queue: receiveQueue)
        
 // 启动帧清理定时器
        startFrameCleanupTimer()
        
 // 等待握手完成
        try await performHandshake()
        
        receiveLoop()
        
        log.info("UltraStream Receiver started")
    }
    
 /// 执行握手（接收端等待发送端的握手包）
    private func performHandshake() async throws {
        handshakeState = .inProgress
        
        return try await withCheckedThrowingContinuation { continuation in
            handshakeContinuation = continuation
            
 // 设置超时
            handshakeTimer = Timer.scheduledTimer(withTimeInterval: handshakeTimeout, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.handshakeState == .inProgress else { return }
                    self.handshakeState = .failed
                    self.handshakeContinuation = nil
                    continuation.resume(throwing: UltraStreamError.handshakeTimeout)
                }
            }
        }
    }
    
 /// 启动帧清理定时器（清理超时的帧重组状态）
    private func startFrameCleanupTimer() {
        frameCleanupTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                let expiredFrames = self.frameTimestamps.filter { now.timeIntervalSince($0.value) > self.frameTimeout }
                for (frameId, _) in expiredFrames {
                    self.assemblies.removeValue(forKey: frameId)
                    self.frameTimestamps.removeValue(forKey: frameId)
                    self.log.warning("清理超时帧重组: frameId=\(frameId)")
                }
            }
        }
    }
    
 /// 处理握手包
    private func handleHandshakePacket(header: UltraStreamHeader, payload: Data) {
        guard handshakeState == .inProgress else {
            log.warning("收到握手包但状态不正确: \(self.handshakeState)")
            return
        }
        
 // 解析握手消息（简化实现：payload 应包含服务器公钥或确认消息）
 // 这里可以解析握手消息，验证服务器身份等
 // 简化实现：直接接受握手
        handshakeState = .completed
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume()
        }
        
        log.info("✅ UltraStream 握手完成")
    }
    
    public func stop() {
        guard running else { return }
        running = false
        
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        frameCleanupTimer?.invalidate()
        frameCleanupTimer = nil
        
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume(throwing: UltraStreamError.streamStopped)
        }
        
        connection.cancel()
        assemblies.removeAll()
        frameTimestamps.removeAll()
        handshakeState = .waiting
        
        log.info("UltraStream Receiver stopped")
    }
    
    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            if let error {
                self.log.error("UltraStream receive error: \(error.localizedDescription)")
                return
            }
            
            if let data {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handlePacket(data)
                }
            }
            
            if isComplete {
                self.log.info("UltraStream receive completed")
                return
            }
            
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.receiveLoop()
            }
        }
    }
    
    private func handlePacket(_ packet: Data) {
        guard packet.count >= UltraStreamHeader.length else {
            log.error("UltraStream packet too small")
            return
        }
        
        guard let header = UltraStreamHeader(data: packet) else {
            log.error("UltraStream invalid header")
            return
        }
        
        let payload = packet.subdata(in: UltraStreamHeader.length ..< UltraStreamHeader.length + Int(header.payloadLength))
        
 // 处理握手包
        if header.flags.contains(.handshake) {
            handleHandshakePacket(header: header, payload: payload)
            return
        }
        
        guard let codec = UltraStreamConfig.Codec(rawValue: header.codecRaw) else {
            log.error("UltraStream unsupported codec: \(header.codecRaw)")
            return
        }
        
 // 检查握手状态
        guard handshakeState == .completed else {
            log.warning("收到数据包但握手未完成，忽略")
            return
        }
        
        let frameId = header.frameId
        let totalChunks = Int(header.chunkCount)
        let chunkIndex = Int(header.chunkIndex)
        
 // 检查重复帧
        if let existing = assemblies[frameId], existing.receivedChunks[chunkIndex] != nil {
            log.warning("收到重复帧块: frameId=\(frameId), chunkIndex=\(chunkIndex)")
            return
        }
        
        var assembly = assemblies[frameId] ?? UltraStreamFrameAssembly(
            frameId: frameId,
            codec: codec,
            width: Int(header.width),
            height: Int(header.height),
            timestampMs: header.timestampMs,
            totalChunks: totalChunks,
            receivedChunks: [:]
        )
        
        assembly.insert(chunkIndex: chunkIndex, data: payload)
        assemblies[frameId] = assembly
        frameTimestamps[frameId] = Date() // 更新时间戳
        
        guard assembly.isComplete, let cipher = assembly.combinedData() else { return }
        
 // 完整帧就绪，开始解密+解码
        assemblies.removeValue(forKey: frameId)
        frameTimestamps.removeValue(forKey: frameId)
        
        let headerForAAD = UltraStreamHeader(
            flags: header.flags,
            codecRaw: header.codecRaw,
            frameId: header.frameId,
            timestampMs: header.timestampMs,
            width: header.width,
            height: header.height,
            chunkIndex: 0,
            chunkCount: header.chunkCount,
            payloadLength: 0
        )
        
        let aad = headerForAAD.aadData()
        
        let clear: Data
        do {
            clear = try crypto.decrypt(ciphertext: cipher, aad: aad)
        } catch {
            log.error("UltraStream decrypt failed: \(error.localizedDescription)")
 // 标记为损坏帧
            NotificationCenter.default.post(
                name: .ultraStreamFrameError,
                object: nil,
                userInfo: ["frameId": frameId, "error": UltraStreamError.frameCorrupted]
            )
            return
        }
        
 // 使用你的 RemoteFrameRenderer 做 VideoToolbox + Metal 解码渲染
        let frameType: RemoteFrameType = (codec == .hevc) ? .hevc : .h264
        
        let metrics = renderer.processFrame(
            data: clear,
            width: assembly.width,
            height: assembly.height,
            stride: 0,
            type: frameType
        )
        
 // 将纹理同步给 UI
 // RemoteFrameRenderer 内部应该在解码后回调 frameHandler(texture:)，
 // 这里只要确保 frameHandler 已经设置为更新 textureFeed 即可。
 // metrics 可用于更新带宽/FPS 折线图
        _ = metrics // 你可以在这里把 metrics 推到仪表盘
    }
}

// MARK: - PQC HPKE X-Wing 会话密钥协商（示例层）

//
// 说明：
//
// UltraStreamCrypto 只关心 SymmetricKey；
// 这里提供一个示例工具，演示如何用 CryptoKit HPKE + XWingMLKEM768X25519
// 生成会话对称密钥。你可以把它接到现有的 Supabase / 设备信任体系里。
//
@available(macOS 26.0, *)
public enum UltraStreamKeyAgreement {
 /// HPKE 使用的 cipher suite：X-Wing (ML-KEM-768 + X25519) + SHA256 + AES-GCM-256
    private static let suite = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
    private static let sessionKeyExporterContextPrefix = Data("SkyBridge-UltraStream-SessionKey-v1|".utf8)
    
 /// 服务端生成长生命周期的 XWing 私钥，存入 Keychain 或 Supabase
    public static func generateServerStaticKeyPair() throws -> (privateKey: XWingMLKEM768X25519.PrivateKey, publicKeyData: Data) {
        let sk = try XWingMLKEM768X25519.PrivateKey.generate()
        let pk = sk.publicKey
        let raw = pk.rawRepresentation
        return (sk, raw)
    }
    
 /// 客户端：基于服务端公开的 HPKE 公钥，构造 Sender，并返回：
 /// - 对称会话密钥（从 HPKE 密钥材料派生）
 /// - encapsulatedKey：需要通过控制信道发给服务端
    public static func createClientContext(
        serverPublicKeyData: Data,
        info: Data = Data("SkyBridge UltraStream v1".utf8)
    ) throws -> (sessionKey: SymmetricKey, encapsulatedKey: Data, seedCiphertext: Data) {
        let serverPublicKey = try XWingMLKEM768X25519.PublicKey(rawRepresentation: serverPublicKeyData)
        var sender = try HPKE.Sender(
            recipientKey: serverPublicKey,
            ciphersuite: suite,
            info: info
        )
        
        let enc = sender.encapsulatedKey
        
        var rng = SystemRandomNumberGenerator()
        let seedPlaintext = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let seedCiphertext = try sender.seal(seedPlaintext, authenticating: info)
        
        var exporterContext = sessionKeyExporterContextPrefix
        exporterContext.append(info)
        exporterContext.append(enc)
        exporterContext.append(seedPlaintext)
        
        let sessionKey = try sender.exportSecret(
            context: exporterContext,
            outputByteCount: 32
        )
        
        return (sessionKey, enc, seedCiphertext)
    }
    
 /// 服务端：拿到客户端发来的 encapsulatedKey，构造 Recipient 并恢复会话对称密钥
 /// - Parameters:
 /// - serverPrivateKey: 服务端私钥
 /// - encapsulatedKey: 客户端发来的封装密钥
 /// - seedCiphertext: 客户端发来的第一条密文（包含会话密钥种子）
 /// - info: HPKE info 参数
 /// - Returns: 会话对称密钥
    public static func createServerContext(
        serverPrivateKey: XWingMLKEM768X25519.PrivateKey,
        encapsulatedKey: Data,
        seedCiphertext: Data,
        info: Data = Data("SkyBridge UltraStream v1".utf8)
    ) throws -> SymmetricKey {
        var recipient = try HPKE.Recipient(
            privateKey: serverPrivateKey,
            ciphersuite: suite,
            info: info,
            encapsulatedKey: encapsulatedKey
        )
        
        let seedPlaintext = try recipient.open(seedCiphertext, authenticating: info)
        
        var exporterContext = sessionKeyExporterContextPrefix
        exporterContext.append(info)
        exporterContext.append(encapsulatedKey)
        exporterContext.append(seedPlaintext)
        
        return try recipient.exportSecret(
            context: exporterContext,
            outputByteCount: 32
        )
    }
}

// MARK: - 通知名称扩展

@available(macOS 26.0, *)
public extension Notification.Name {
    static let ultraStreamFrameError = Notification.Name("ultraStreamFrameError")
    static let ultraStreamHandshakeCompleted = Notification.Name("ultraStreamHandshakeCompleted")
    static let ultraStreamNetworkQualityChanged = Notification.Name("ultraStreamNetworkQualityChanged")
}

#endif
