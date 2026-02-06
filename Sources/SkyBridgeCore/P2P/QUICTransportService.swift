//
// QUICTransportService.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - QUIC Transport Service
// Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6
//
// QUIC 多流传输管理：
// 1. Control Channel: 可靠（基于 QUIC reliable stream 的应用层复用）
// 2. Video Channel: 单例 datagram flow (不可靠, 每连接只有一个)
// 3. File Channels: N 个可靠“逻辑流”（同一可靠流上复用，避免在同一 NWConnection 上并发 receive）
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

    /// connect() 的一次性等待 continuation（由 actor 串行化保证只 resume 一次）
    private var connectContinuation: CheckedContinuation<Void, Error>?

    /// 可靠“数据平面”复用接收缓冲
    private var reliableReceiveBuffer = Data()
    private var reliableReceiveBufferOffset: Int = 0

    /// 本端打开的文件“逻辑流”（仅用于并发限制/关闭；对端可直接发送未知 channelId）
    private var fileStreams: Set<FileChannelId> = []
    private var nextFileStreamIndexByTransferId: [UUID: Int] = [:]

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

 // MARK: - Callback Wiring

    public func getOnControlReceived() -> (@Sendable (Data) -> Void)? {
        onControlReceived
    }

    public func setOnControlReceived(_ handler: (@Sendable (Data) -> Void)?) {
        onControlReceived = handler
    }

    public func getOnQUICFileChunkReceived() -> (@Sendable (FileChannelId, QUICFileChunk) -> Void)? {
        onQUICFileChunkReceived
    }

    public func setOnQUICFileChunkReceived(_ handler: (@Sendable (FileChannelId, QUICFileChunk) -> Void)?) {
        onQUICFileChunkReceived = handler
    }

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

        // 等待连接就绪（由 handleConnectionState 串行化 resume，避免 double-resume）
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectContinuation = continuation
            conn.stateUpdateHandler = { [weak self] newState in
                Task { await self?.handleConnectionState(newState) }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

 // 获取 datagram 大小
 // 检查路径是否有可用接口，如果有则使用保守值
        if conn.currentPath?.availableInterfaces.first != nil {
            maxDatagramSize = P2PConstants.conservativeDatagramPayloadSize
        }

 // 开始接收 datagram
        startReceivingDatagrams()
        // 开始接收可靠复用流（control + file）
        startReceivingReliableStream()

        SkyBridgeLogger.p2p.info("QUIC connected")
    }

 /// 断开连接
    public func disconnect() async {
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: QUICTransportError.connectionFailed("Connection cancelled"))
        }
        connection?.cancel()
        fileStreams.removeAll()
        nextFileStreamIndexByTransferId.removeAll()
        reliableReceiveBuffer.removeAll(keepingCapacity: false)
        reliableReceiveBufferOffset = 0

        connection = nil
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

        try await sendReliableFrame(kind: .control, channelId: nil, payload: data)
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

        let streamIndex = nextFileStreamIndexByTransferId[transferId] ?? 0
        nextFileStreamIndexByTransferId[transferId] = streamIndex + 1
        let channelId = FileChannelId(transferId: transferId, streamIndex: streamIndex)
        fileStreams.insert(channelId)

        return FileStreamHandle(channelId: channelId)
    }

 /// 发送文件块（可靠，指定句柄）
    public func sendQUICFileChunk(_ chunk: QUICFileChunk, on handle: FileStreamHandle) async throws {
        guard fileStreams.contains(handle.channelId) else {
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

        try await sendReliableFrame(kind: .fileChunk, channelId: handle.channelId, payload: data)
    }

 /// 关闭文件流
    public func closeFileStream(_ handle: FileStreamHandle) async {
        fileStreams.remove(handle.channelId)
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
            if let channelId = fileStreams.first {
                fileStreams.remove(channelId)
            }
        }

        SkyBridgeLogger.p2p.debug("Adjusted concurrency to \(self.maxConcurrentStreams) streams")
    }

 // MARK: - Private Methods

 /// 处理连接状态
    private func handleConnectionState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            state = .connected
            onStateChanged?(.connected)
            if let continuation = connectContinuation {
                connectContinuation = nil
                continuation.resume()
            }

        case .failed(let error):
            state = .failed
            onStateChanged?(.failed)
            if let continuation = connectContinuation {
                connectContinuation = nil
                continuation.resume(throwing: QUICTransportError.connectionFailed(error.localizedDescription))
            }

        case .cancelled:
            state = .disconnected
            onStateChanged?(.disconnected)
            if let continuation = connectContinuation {
                connectContinuation = nil
                continuation.resume(throwing: QUICTransportError.connectionFailed("Connection cancelled"))
            }

        case .waiting(let error):
            SkyBridgeLogger.p2p.warning("Connection waiting: \(error.localizedDescription)")

        default:
            break
        }
    }

    // MARK: Reliable Framing (control + file chunks)

    private static let reliableFrameVersion: UInt8 = 1

    private enum ReliableFrameKind: UInt8 {
        case control = 0
        case fileChunk = 1
    }

    private func sendReliableFrame(
        kind: ReliableFrameKind,
        channelId: FileChannelId?,
        payload: Data
    ) async throws {
        guard let conn = connection else { throw QUICTransportError.notConnected }
        let frame = try encodeReliableFrame(kind: kind, channelId: channelId, payload: payload)
        try await send(data: frame, on: conn)
    }

    private func encodeReliableFrame(
        kind: ReliableFrameKind,
        channelId: FileChannelId?,
        payload: Data
    ) throws -> Data {
        guard payload.count <= Int(UInt32.max) else {
            throw QUICTransportError.sendFailed("Payload too large: \(payload.count) bytes")
        }

        var data = Data()
        data.reserveCapacity(32 + payload.count)

        data.append(Self.reliableFrameVersion)
        data.append(kind.rawValue)

        switch kind {
        case .control:
            break
        case .fileChunk:
            guard let channelId else {
                throw QUICTransportError.sendFailed("Missing FileChannelId for fileChunk frame")
            }

            var uuidBytes = channelId.transferId.uuid
            withUnsafeBytes(of: &uuidBytes) { raw in
                data.append(contentsOf: raw)
            }

            var streamIndexBE = UInt32(channelId.streamIndex).bigEndian
            data.append(contentsOf: withUnsafeBytes(of: &streamIndexBE) { Data($0) })
        }

        var lengthBE = UInt32(payload.count).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &lengthBE) { Data($0) })
        data.append(payload)
        return data
    }

    private func startReceivingReliableStream() {
        guard let conn = connection else { return }

        // Use a larger read size to reduce callback churn for 256KB file chunks.
        let maxRead = max(64 * 1024, P2PConstants.fileChunkSize + 1024)

        conn.receive(minimumIncompleteLength: 1, maximumLength: maxRead) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            Task {
                if let data, !data.isEmpty {
                    await self.appendReliableBytes(data)
                }

                if !isComplete && error == nil {
                    await self.startReceivingReliableStream()
                } else if let error {
                    SkyBridgeLogger.p2p.error("Reliable stream receive failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func appendReliableBytes(_ data: Data) {
        reliableReceiveBuffer.append(data)
        parseReliableFrames()
        compactReliableBufferIfNeeded()
    }

    private func compactReliableBufferIfNeeded() {
        // Avoid unbounded growth when we parse many frames.
        guard reliableReceiveBufferOffset > 0 else { return }
        if reliableReceiveBufferOffset > 64 * 1024 || reliableReceiveBufferOffset > reliableReceiveBuffer.count / 2 {
            reliableReceiveBuffer.removeSubrange(0..<reliableReceiveBufferOffset)
            reliableReceiveBufferOffset = 0
        }
    }

    private func parseReliableFrames() {
        while true {
            let available = reliableReceiveBuffer.count - reliableReceiveBufferOffset
            // Need at least version(1) + kind(1) + length(4)
            guard available >= 6 else { return }

            let base = reliableReceiveBufferOffset

            let version = reliableReceiveBuffer[base]
            guard version == Self.reliableFrameVersion else {
                // Protocol mismatch: drop buffer to resync to next frame boundary.
                SkyBridgeLogger.p2p.error("Reliable frame version mismatch: \(version) != \(Self.reliableFrameVersion)")
                reliableReceiveBuffer.removeAll(keepingCapacity: true)
                reliableReceiveBufferOffset = 0
                return
            }

            guard let kind = ReliableFrameKind(rawValue: self.reliableReceiveBuffer[base + 1]) else {
                SkyBridgeLogger.p2p.error("Unknown reliable frame kind: \(self.reliableReceiveBuffer[base + 1])")
                self.reliableReceiveBuffer.removeAll(keepingCapacity: true)
                self.reliableReceiveBufferOffset = 0
                return
            }

            var cursor = base + 2
            var channelId: FileChannelId?

            if kind == .fileChunk {
                // Need transferId(16) + streamIndex(4)
                guard available >= 2 + 16 + 4 + 4 else { return }
                guard let transferId = decodeUUID(from: reliableReceiveBuffer, at: cursor) else {
                    SkyBridgeLogger.p2p.error("Failed to decode transferId in reliable frame")
                    reliableReceiveBuffer.removeAll(keepingCapacity: true)
                    reliableReceiveBufferOffset = 0
                    return
                }
                cursor += 16

                let streamIndexBE: UInt32 = reliableReceiveBuffer.withUnsafeBytes { raw in
                    raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                }
                cursor += 4
                channelId = FileChannelId(transferId: transferId, streamIndex: Int(UInt32(bigEndian: streamIndexBE)))
            }

            // length
            let lengthBE: UInt32 = reliableReceiveBuffer.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            }
            let length = Int(UInt32(bigEndian: lengthBE))
            cursor += 4

            let frameTotal = (cursor - base) + length
            guard available >= frameTotal else { return }

            let payloadRange = cursor..<(cursor + length)
            let payload = Data(reliableReceiveBuffer[payloadRange])

            reliableReceiveBufferOffset += frameTotal

            switch kind {
            case .control:
                handleControlMessage(payload)
            case .fileChunk:
                if let channelId {
                    handleFileData(channelId: channelId, data: payload)
                }
            }
        }
    }

    private func decodeUUID(from data: Data, at offset: Int) -> UUID? {
        guard offset >= 0, data.count >= offset + 16 else { return nil }
        return data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return NSUUID(uuidBytes: base.advanced(by: offset)) as UUID
        }
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
        // Decode file chunk: index(8) + flags(1) + len(4) + payload + checksum(optional)
        data.withUnsafeBytes { raw in
            guard raw.count >= 13 else { return }

            let indexBE = raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
            let index = UInt64(bigEndian: indexBE)

            let flags = raw[8]
            let isLast = (flags & 0x01) != 0

            let lengthBE = raw.loadUnaligned(fromByteOffset: 9, as: UInt32.self)
            let length = Int(UInt32(bigEndian: lengthBE))

            let payloadStart = 13
            let payloadEnd = payloadStart + length
            guard payloadEnd <= raw.count else { return }

            let chunkData = Data(data[payloadStart..<payloadEnd])
            let checksum: Data? = (payloadEnd < raw.count) ? Data(data[payloadEnd..<raw.count]) : nil

            let chunk = QUICFileChunk(index: index, data: chunkData, isLast: isLast, checksum: checksum)
            onQUICFileChunkReceived?(channelId, chunk)
        }
    }
}

// MARK: - NWConnection.ContentContext Extension

extension NWConnection.ContentContext {
 /// Datagram context
    static let datagram = NWConnection.ContentContext(identifier: "datagram")
}
