//
// QUICTransportService.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - QUIC Transport Service
// Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6
//
// QUIC 多流传输管理：
// 1. Control Channel: 第一个 bidirectional stream (可靠)
// 2. Video Channel: 单例 datagram flow (不可靠, 每连接只有一个)
// 3. File Channels: N 个 bidirectional streams (可靠)
//

import Foundation
import Network

// MARK: - Logical Channel

/// 逻辑通道类型（不是 QUIC stream ID）
public enum LogicalChannel: Sendable, Hashable {
 /// 控制通道（第一个 bidirectional stream）
    case control

 /// 视频通道（单例 datagram flow）
    case videoDatagram

 /// 文件通道（transport 分配 stream）
    case file(FileChannelId)
}

// MARK: - File Channel ID

/// 文件通道句柄
public struct FileChannelId: Hashable, Sendable, Codable {
 /// 传输 ID
    public let transferId: UUID

 /// 流索引
    public let streamIndex: Int

    public init(transferId: UUID, streamIndex: Int) {
        self.transferId = transferId
        self.streamIndex = streamIndex
    }
}

// MARK: - File Stream Handle

/// 文件流句柄（完全 opaque）
public struct FileStreamHandle: Sendable, Hashable {
 /// 通道 ID
    public let channelId: FileChannelId

 /// 内部标识符
    internal let internalId: UUID

    public init(channelId: FileChannelId) {
        self.channelId = channelId
        self.internalId = UUID()
    }

    public static func == (lhs: FileStreamHandle, rhs: FileStreamHandle) -> Bool {
        lhs.channelId == rhs.channelId
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(channelId)
    }
}


// MARK: - Connection State

/// 连接状态
public enum QUICConnectionState: String, Sendable {
    case disconnected = "disconnected"
    case connecting = "connecting"
    case connected = "connected"
    case reconnecting = "reconnecting"
    case failed = "failed"
}

// MARK: - QUIC Network Quality

/// QUIC 网络质量
public enum QUICNetworkQuality: Int, Sendable, Comparable {
    case unknown = 0
    case poor = 1
    case fair = 2
    case good = 3
    case excellent = 4

    public static func < (lhs: QUICNetworkQuality, rhs: QUICNetworkQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

 /// 推荐的并发流数量
    public var recommendedConcurrentStreams: Int {
        switch self {
        case .unknown, .poor: return 1
        case .fair: return 2
        case .good: return 4
        case .excellent: return 8
        }
    }
}

// MARK: - File Chunk

/// QUIC 文件块
public struct QUICFileChunk: Sendable {
 /// 块索引
    public let index: UInt64

 /// 块数据
    public let data: Data

 /// 是否为最后一块
    public let isLast: Bool

 /// 校验和
    public let checksum: Data?

    public init(index: UInt64, data: Data, isLast: Bool, checksum: Data? = nil) {
        self.index = index
        self.data = data
        self.isLast = isLast
        self.checksum = checksum
    }
}

// MARK: - Video Frame Packet

/// 视频帧分片包
public struct VideoFramePacket: Sendable {
 /// 帧序列号
    public let frameSeq: UInt64

 /// 是否关键帧
    public let isKeyFrame: Bool

 /// 分片索引 (0-based)
    public let fragIndex: UInt16

 /// 总分片数
    public let fragCount: UInt16

 /// 分片数据
    public let payload: Data

 /// 时间戳
    public let timestamp: TimeInterval

 /// 视频方向
    public let orientation: VideoOrientation

    public init(
        frameSeq: UInt64,
        isKeyFrame: Bool,
        fragIndex: UInt16,
        fragCount: UInt16,
        payload: Data,
        timestamp: TimeInterval,
        orientation: VideoOrientation = .portrait
    ) {
        self.frameSeq = frameSeq
        self.isKeyFrame = isKeyFrame
        self.fragIndex = fragIndex
        self.fragCount = fragCount
        self.payload = payload
        self.timestamp = timestamp
        self.orientation = orientation
    }

 /// 编码为固定大小头部 + payload
    public func encode() -> Data {
        var data = Data(capacity: P2PConstants.videoFrameHeaderSize + payload.count)

 // frameSeq (8 bytes)
        var seq = frameSeq.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &seq) { Data($0) })

 // fragIndex (2 bytes)
        var idx = fragIndex.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &idx) { Data($0) })

 // fragCount (2 bytes)
        var cnt = fragCount.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &cnt) { Data($0) })

 // flags (2 bytes): bit 0 = isKeyFrame, bits 1-3 = orientation
        var flags: UInt16 = 0
        if isKeyFrame { flags |= 0x01 }
        flags |= UInt16(orientation.rawValue & 0x07) << 1
        var flagsBE = flags.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &flagsBE) { Data($0) })

 // timestamp (8 bytes)
        var ts = timestamp.bitPattern.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &ts) { Data($0) })

 // reserved (2 bytes)
        data.append(contentsOf: [0, 0])

 // payload
        data.append(payload)

        return data
    }

 /// 从数据解码
    public static func decode(from data: Data) -> VideoFramePacket? {
        guard data.count >= P2PConstants.videoFrameHeaderSize else { return nil }

        var offset = 0

 // frameSeq
        let frameSeq = data.subdata(in: offset..<offset+8).withUnsafeBytes {
            $0.load(as: UInt64.self).bigEndian
        }
        offset += 8

 // fragIndex
        let fragIndex = data.subdata(in: offset..<offset+2).withUnsafeBytes {
            $0.load(as: UInt16.self).bigEndian
        }
        offset += 2

 // fragCount
        let fragCount = data.subdata(in: offset..<offset+2).withUnsafeBytes {
            $0.load(as: UInt16.self).bigEndian
        }
        offset += 2

 // flags
        let flags = data.subdata(in: offset..<offset+2).withUnsafeBytes {
            $0.load(as: UInt16.self).bigEndian
        }
        let isKeyFrame = (flags & 0x01) != 0
        let orientationRaw = Int((flags >> 1) & 0x07)
        let orientation = VideoOrientation(rawValue: orientationRaw) ?? .portrait
        offset += 2

 // timestamp
        let tsBits = data.subdata(in: offset..<offset+8).withUnsafeBytes {
            $0.load(as: UInt64.self).bigEndian
        }
        let timestamp = Double(bitPattern: tsBits)
        offset += 8

 // skip reserved
        offset += 2

 // payload
        let payload = data.subdata(in: offset..<data.count)

        return VideoFramePacket(
            frameSeq: frameSeq,
            isKeyFrame: isKeyFrame,
            fragIndex: fragIndex,
            fragCount: fragCount,
            payload: payload,
            timestamp: timestamp,
            orientation: orientation
        )
    }
}

/// 视频方向
public enum VideoOrientation: Int, Codable, Sendable {
    case portrait = 0
    case landscapeLeft = 1
    case landscapeRight = 2
    case portraitUpsideDown = 3
}


// MARK: - QUIC Transport Error

/// QUIC 传输错误
public enum QUICTransportError: Error, LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case streamOpenFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case datagramNotSupported
    case invalidState
    case timeout
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .streamOpenFailed(let reason):
            return "Stream open failed: \(reason)"
        case .sendFailed(let reason):
            return "Send failed: \(reason)"
        case .receiveFailed(let reason):
            return "Receive failed: \(reason)"
        case .datagramNotSupported:
            return "QUIC datagram not supported"
        case .invalidState:
            return "Invalid transport state"
        case .timeout:
            return "Operation timed out"
        case .notImplemented(let detail):
            return "Not implemented: \(detail)"
        }
    }
}

// MARK: - QUIC Transport Service

/// QUIC 传输服务 - 逻辑通道复用
@available(macOS 14.0, iOS 17.0, *)
public actor QUICTransportService {

 // MARK: - Properties

 /// 当前连接状态
    public private(set) var state: QUICConnectionState = .disconnected

 /// QUIC 连接
    private var connection: NWConnection?

    /// 连接端点（用于诊断；本实现不支持真实“QUIC streams”）
    private var connectedEndpoint: NWEndpoint?

 /// 控制流
    private var controlStream: NWConnection?

 /// 文件流映射
    private var fileStreams: [FileChannelId: NWConnection] = [:]

 /// 当前网络质量
    private var networkQuality: QUICNetworkQuality = .unknown

 /// 最大并发流数量
    private var maxConcurrentStreams: Int = 4

 /// 最大 datagram 大小
    public private(set) var maxDatagramSize: Int = 1200

 // MARK: - Callbacks

 /// 控制消息接收回调
    public var onControlReceived: (@Sendable (Data) -> Void)?

 /// 视频帧接收回调
    public var onVideoFrameReceived: (@Sendable (VideoFramePacket) -> Void)?

 /// 文件块接收回调
    public var onQUICFileChunkReceived: (@Sendable (FileChannelId, QUICFileChunk) -> Void)?

 /// 连接状态变化回调
    public var onStateChanged: (@Sendable (QUICConnectionState) -> Void)?

 // MARK: - Initialization

    public init() {}

 // MARK: - Connection Management

 /// 建立 QUIC 连接
 /// - Parameters:
 /// - endpoint: 目标端点
 /// - tlsOptions: TLS 配置
    public func connect(
        to endpoint: NWEndpoint,
        tlsOptions: NWProtocolTLS.Options? = nil
    ) async throws {
        guard state == .disconnected || state == .failed else {
            throw QUICTransportError.invalidState
        }

        state = .connecting
        onStateChanged?(.connecting)

 // 创建 QUIC 参数
        let quicOptions = NWProtocolQUIC.Options()

 // 启用 datagram
        quicOptions.isDatagram = true
        quicOptions.maxDatagramFrameSize = 65535

 // 创建参数
        let parameters = NWParameters(quic: quicOptions)

 // 添加 TLS
        if let tls = tlsOptions {
            parameters.defaultProtocolStack.applicationProtocols.insert(tls, at: 0)
        }

 // 创建连接
        let conn = NWConnection(to: endpoint, using: parameters)
        connection = conn
        connectedEndpoint = endpoint

 // 等待连接就绪
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: QUICTransportError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: QUICTransportError.connectionFailed("Connection cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        state = .connected
        onStateChanged?(.connected)

 // 获取 datagram 大小
 // 检查路径是否有可用接口，如果有则使用保守值
        if conn.currentPath?.availableInterfaces.first != nil {
            maxDatagramSize = P2PConstants.conservativeDatagramPayloadSize
        }

 // 开始接收 datagram
        startReceivingDatagrams()

        SkyBridgeLogger.p2p.info("QUIC connected")
    }

 /// 断开连接
    public func disconnect() async {
        connection?.cancel()
        controlStream?.cancel()

        for (_, stream) in fileStreams {
            stream.cancel()
        }
        fileStreams.removeAll()

        connection = nil
        controlStream = nil
        state = .disconnected
        onStateChanged?(.disconnected)

        SkyBridgeLogger.p2p.info("QUIC disconnected")
    }

 // MARK: - Control Channel

 /// 发送控制消息（可靠，控制通道）
    public func sendControl(_ data: Data) async throws {
        guard state == .connected else {
            throw QUICTransportError.notConnected
        }

 // 确保控制流已打开
        if controlStream == nil {
            controlStream = try await openBidirectionalStream()
            startReceivingControl()
        }

        guard let stream = controlStream else {
            throw QUICTransportError.streamOpenFailed("Control stream not available")
        }

        try await send(data: data, on: stream)
    }

 // MARK: - Video Channel (Datagram)

 /// 发送视频帧（不可靠，datagram）
    public func sendVideoFrame(_ frame: VideoFramePacket) async throws {
        guard state == .connected else {
            throw QUICTransportError.notConnected
        }

        guard let conn = connection else {
            throw QUICTransportError.notConnected
        }

        let data = frame.encode()

 // 检查大小
        if data.count > maxDatagramSize {
            throw QUICTransportError.sendFailed("Frame too large for datagram: \(data.count) > \(maxDatagramSize)")
        }

 // 发送 datagram
        conn.send(content: data, contentContext: .datagram, completion: .contentProcessed { error in
            if let error = error {
                SkyBridgeLogger.p2p.error("Datagram send failed: \(error.localizedDescription)")
            }
        })
    }


 // MARK: - File Channel

 /// 打开文件流（返回句柄，transport 分配 stream ID）
    public func openFileStream(transferId: UUID) async throws -> FileStreamHandle {
        guard state == .connected else {
            throw QUICTransportError.notConnected
        }

 // 检查并发限制
        if fileStreams.count >= maxConcurrentStreams {
            throw QUICTransportError.streamOpenFailed("Max concurrent streams reached")
        }

        let stream = try await openBidirectionalStream()
        let streamIndex = fileStreams.count
        let channelId = FileChannelId(transferId: transferId, streamIndex: streamIndex)

        fileStreams[channelId] = stream

 // 开始接收
        startReceivingFile(channelId: channelId, stream: stream)

        return FileStreamHandle(channelId: channelId)
    }

 /// 发送文件块（可靠，指定句柄）
    public func sendQUICFileChunk(_ chunk: QUICFileChunk, on handle: FileStreamHandle) async throws {
        guard let stream = fileStreams[handle.channelId] else {
            throw QUICTransportError.streamOpenFailed("File stream not found")
        }

 // 编码块
        var data = Data()

 // index (8 bytes)
        var index = chunk.index.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &index) { Data($0) })

 // flags (1 byte)
        let flags: UInt8 = chunk.isLast ? 0x01 : 0x00
        data.append(flags)

 // data length (4 bytes)
        var length = UInt32(chunk.data.count).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &length) { Data($0) })

 // data
        data.append(chunk.data)

 // checksum (optional, 32 bytes)
        if let checksum = chunk.checksum {
            data.append(checksum)
        }

        try await send(data: data, on: stream)
    }

 /// 关闭文件流
    public func closeFileStream(_ handle: FileStreamHandle) async {
        if let stream = fileStreams.removeValue(forKey: handle.channelId) {
            stream.cancel()
        }
    }

 // MARK: - Connection Access

 /// 获取当前 NWConnection（用于指标获取）
 /// Requirements: 4.1
    public func getConnection() -> NWConnection? {
        return connection
    }

 // MARK: - Adaptive Control

 /// 自适应流控制
    public func adjustConcurrency(networkQuality: QUICNetworkQuality) async {
        self.networkQuality = networkQuality
        self.maxConcurrentStreams = networkQuality.recommendedConcurrentStreams

 // 如果当前流数超过限制，关闭多余的流
        while fileStreams.count > maxConcurrentStreams {
            if let (channelId, stream) = fileStreams.first {
                stream.cancel()
                fileStreams.removeValue(forKey: channelId)
            }
        }

        SkyBridgeLogger.p2p.debug("Adjusted concurrency to \(self.maxConcurrentStreams) streams")
    }

 // MARK: - Private Methods

 /// 处理连接状态
    private func handleConnectionState(
        _ newState: NWConnection.State,
        continuation: CheckedContinuation<Void, Error>?
    ) {
        switch newState {
        case .ready:
            state = .connected
            onStateChanged?(.connected)
            continuation?.resume()

        case .failed(let error):
            state = .failed
            onStateChanged?(.failed)
            continuation?.resume(throwing: QUICTransportError.connectionFailed(error.localizedDescription))

        case .cancelled:
            state = .disconnected
            onStateChanged?(.disconnected)

        case .waiting(let error):
            SkyBridgeLogger.p2p.warning("Connection waiting: \(error.localizedDescription)")

        default:
            break
        }
    }

 /// 打开双向流
    private func openBidirectionalStream() async throws -> NWConnection {
        // ⚠️ 重要：当前实现没有使用 Network.framework 的真正 QUIC stream API，
        // 直接在同一个 NWConnection 上并发 receive 会导致随机丢包/卡死/“幽灵中断”。
        // 为了避免“看似可用但其实不稳定”，这里直接 fail-fast。
        let ep = connectedEndpoint.map { String(describing: $0) } ?? "unknown-endpoint"
        throw QUICTransportError.notImplemented("QUIC streams are not implemented in QUICTransportService (endpoint=\(ep)). Use TCP framed transport (HandshakeDriver) or implement stream multiplexing explicitly.")
    }

 /// 发送数据
    private func send(data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: QUICTransportError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

 /// 开始接收 datagram
    private func startReceivingDatagrams() {
        guard let conn = connection else { return }

        conn.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }

            Task {
                if let data = data, context?.identifier == NWConnection.ContentContext.datagram.identifier {
                    if let packet = VideoFramePacket.decode(from: data) {
                        await self.handleVideoFrame(packet)
                    }
                }

 // 继续接收
                if error == nil {
                    await self.startReceivingDatagrams()
                }
            }
        }
    }

 /// 开始接收控制消息
    private func startReceivingControl() {
        guard let stream = controlStream else { return }

        stream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            Task {
                if let data = data {
                    await self.handleControlMessage(data)
                }

                if !isComplete && error == nil {
                    await self.startReceivingControl()
                }
            }
        }
    }

 /// 开始接收文件数据
    private func startReceivingFile(channelId: FileChannelId, stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            Task {
                if let data = data {
                    await self.handleFileData(channelId: channelId, data: data)
                }

                if !isComplete && error == nil {
                    await self.startReceivingFile(channelId: channelId, stream: stream)
                }
            }
        }
    }

 /// 处理视频帧
    private func handleVideoFrame(_ packet: VideoFramePacket) {
        onVideoFrameReceived?(packet)
    }

 /// 处理控制消息
    private func handleControlMessage(_ data: Data) {
        onControlReceived?(data)
    }

 /// 处理文件数据
    private func handleFileData(channelId: FileChannelId, data: Data) {
 // 解码文件块
        guard data.count >= 13 else { return } // 8 + 1 + 4 = 13 bytes header

        var offset = 0

 // index
        let index = data.subdata(in: offset..<offset+8).withUnsafeBytes {
            $0.load(as: UInt64.self).bigEndian
        }
        offset += 8

 // flags
        let flags = data[offset]
        let isLast = (flags & 0x01) != 0
        offset += 1

 // length
        let length = data.subdata(in: offset..<offset+4).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        offset += 4

 // data
        let chunkData = data.subdata(in: offset..<offset+Int(length))
        offset += Int(length)

 // checksum (optional)
        let checksum: Data? = data.count > offset ? data.subdata(in: offset..<data.count) : nil

        let chunk = QUICFileChunk(index: index, data: chunkData, isLast: isLast, checksum: checksum)
        onQUICFileChunkReceived?(channelId, chunk)
    }
}

// MARK: - NWConnection.ContentContext Extension

extension NWConnection.ContentContext {
 /// Datagram context
    static let datagram = NWConnection.ContentContext(identifier: "datagram")
}
