//
// P2PProtocolConstants.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Protocol Constants & Domain Separation
// Requirements: 4.5, 9.5
//

import Foundation
import CryptoKit

// MARK: - Protocol Version & Domain Separation

/// P2P 协议版本
/// 用于握手协商和向后兼容性检查
public enum P2PProtocolVersion: Int, Codable, Sendable, Comparable {
    case v1 = 1
    
    public static let current: P2PProtocolVersion = .v1
    
    public static func < (lhs: P2PProtocolVersion, rhs: P2PProtocolVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 域分离器 - 用于 transcript 和密钥派生
/// 确保不同协议/版本的密钥材料不会混淆
public enum P2PDomainSeparator: String, Sendable {
 /// 主协议域分离器
    case protocol_ = "SkyBridge-P2P-v1"
    
 /// Transcript 域分离器
    case transcript = "SkyBridge-P2P-Transcript-v1"
    
 /// 密钥派生域分离器
    case keyDerivation = "SkyBridge-P2P-KDF-v1"
    
 /// 签名域分离器
    case signature = "SkyBridge-P2P-Sig-v1"
    
 /// 配对域分离器
    case pairing = "SkyBridge-P2P-Pairing-v1"
}

// MARK: - Role Definition

/// 握手角色 - 用于 transcript 和密钥派生
/// 确保双方派生的密钥不同（防止反射攻击）
public enum P2PRole: String, Codable, Sendable {
    case initiator = "initiator"
    case responder = "responder"
    
 /// 获取对端角色
    public var peer: P2PRole {
        switch self {
        case .initiator: return .responder
        case .responder: return .initiator
        }
    }
}

// MARK: - HKDF Info Strings

/// HKDF Info 字符串 - 用于会话密钥派生
/// 每个逻辑通道使用不同的 info 字符串，确保密钥隔离
///
/// 密钥派生公式：
/// `sessionKey = HKDF(sharedSecret, salt="", info=SkyBridge-KDF||suite||transcriptA||transcriptB||nonces||channel||direction||role)`
public enum P2PHKDFInfo: String, Sendable {
 /// 控制通道密钥派生 info
    case control = "skybridge-control-v1"
    
 /// 视频通道密钥派生 info
    case video = "skybridge-video-v1"
    
 /// 文件传输通道密钥派生 info
    case file = "skybridge-file-v1"
    
 /// 认证密钥派生 info
    case authentication = "skybridge-auth-v1"
    
 /// Finished MAC 密钥派生 info
    case finishedMAC = "skybridge-finished-v1"
    
 /// 构建完整的 info 字符串（包含角色）
 /// - Parameter role: 当前角色
 /// - Returns: 完整的 info 字符串 bytes
    public func infoData(role: P2PRole) -> Data {
        let combined = "\(self.rawValue)||\(role.rawValue)"
        return Data(combined.utf8)
    }
}

// MARK: - Logical Channel Types

/// 逻辑通道类型
/// 用于标识不同类型的数据流
public enum P2PLogicalChannel: String, Codable, Sendable {
 /// 控制通道 - 可靠，用于 RPC/命令
    case control = "control"
    
 /// 视频通道 - 不可靠 (QUIC Datagram)，用于屏幕镜像
    case video = "video"
    
 /// 文件通道 - 可靠，用于文件传输
    case file = "file"
    
 /// 获取对应的 HKDF info
    public var hkdfInfo: P2PHKDFInfo {
        switch self {
        case .control: return .control
        case .video: return .video
        case .file: return .file
        }
    }
    
 /// 是否需要可靠传输
    public var requiresReliableTransport: Bool {
        switch self {
        case .control, .file: return true
        case .video: return false
        }
    }
}

// MARK: - Message Types (for Transcript TLV)

/// 消息类型标签 - 用于 Transcript TLV 编码
/// 每种消息类型有唯一的标签值
public enum P2PMessageType: UInt8, Codable, Sendable {
 // 握手消息 (0x01 - 0x1F)
    case handshakeInit = 0x01
    case handshakeResponse = 0x02
    case handshakeFinished = 0x03
    case handshakeError = 0x04
    
 // 配对消息 (0x20 - 0x3F)
    case pairingQRData = 0x20
    case pairingPAKEMessageA = 0x21
    case pairingPAKEMessageB = 0x22
    case pairingConfirmation = 0x23
    
 // 能力协商 (0x40 - 0x5F)
    case cryptoCapabilities = 0x40
    case negotiatedProfile = 0x41
    case videoCodecConfig = 0x42
    
 // 控制消息 (0x60 - 0x7F)
    case controlCommand = 0x60
    case controlResponse = 0x61
    case heartbeat = 0x62
    case requestKeyFrame = 0x63
    
 // 数据消息 (0x80 - 0x9F)
    case videoFrame = 0x80
    case fileMetadata = 0x81
    case fileChunk = 0x82
    case fileAck = 0x83
    
 /// 消息类型名称（用于调试）
    public var name: String {
        switch self {
        case .handshakeInit: return "HandshakeInit"
        case .handshakeResponse: return "HandshakeResponse"
        case .handshakeFinished: return "HandshakeFinished"
        case .handshakeError: return "HandshakeError"
        case .pairingQRData: return "PairingQRData"
        case .pairingPAKEMessageA: return "PAKEMessageA"
        case .pairingPAKEMessageB: return "PAKEMessageB"
        case .pairingConfirmation: return "PairingConfirmation"
        case .cryptoCapabilities: return "CryptoCapabilities"
        case .negotiatedProfile: return "NegotiatedProfile"
        case .videoCodecConfig: return "VideoCodecConfig"
        case .controlCommand: return "ControlCommand"
        case .controlResponse: return "ControlResponse"
        case .heartbeat: return "Heartbeat"
        case .requestKeyFrame: return "RequestKeyFrame"
        case .videoFrame: return "VideoFrame"
        case .fileMetadata: return "FileMetadata"
        case .fileChunk: return "FileChunk"
        case .fileAck: return "FileAck"
        }
    }
    
 /// 是否应该进入 transcript
    public var shouldEnterTranscript: Bool {
        switch self {
        case .handshakeInit, .handshakeResponse, .handshakeFinished,
             .pairingQRData, .pairingPAKEMessageA, .pairingPAKEMessageB, .pairingConfirmation,
             .cryptoCapabilities, .negotiatedProfile, .videoCodecConfig:
            return true
        default:
            return false
        }
    }
}

// MARK: - Timestamp Encoding

/// 时间戳编码工具
/// 统一使用 Unix epoch 毫秒，避免跨平台 Date 编码不一致
public enum P2PTimestamp {
 /// 当前时间戳（毫秒）
    public static var nowMillis: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
    
 /// Date 转毫秒时间戳
    public static func toMillis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
    
 /// 毫秒时间戳转 Date
    public static func fromMillis(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000.0)
    }
    
 /// 编码为 8 字节大端序
    public static func encode(_ date: Date) -> Data {
        var millis = toMillis(date).bigEndian
        return Data(bytes: &millis, count: 8)
    }
    
 /// 从 8 字节大端序解码
    public static func decode(_ data: Data) -> Date? {
        guard data.count >= 8 else { return nil }
        let millis = data.withUnsafeBytes { $0.load(as: Int64.self).bigEndian }
        return fromMillis(millis)
    }
}

// MARK: - Protocol Constants

/// P2P 协议常量
public enum P2PConstants {
 // MARK: - Timing Constants
    
 /// QR 码有效期（秒）
    public static let qrCodeExpirationSeconds: TimeInterval = 300 // 5 分钟
    
 /// PAKE 配对码有效期（秒）
    public static let pairingCodeExpirationSeconds: TimeInterval = 120 // 2 分钟
    
 /// 配对失败锁定时间（秒）
    public static let pairingLockoutSeconds: TimeInterval = 60
    
 /// 最大配对失败次数
    public static let maxPairingAttempts: Int = 3
    
 /// 握手超时（秒）
    public static let handshakeTimeoutSeconds: TimeInterval = 30
    
 /// 心跳间隔（秒）
    public static let heartbeatIntervalSeconds: TimeInterval = 10
    
 /// 设备离线判定时间（秒）
    public static let deviceOfflineThresholdSeconds: TimeInterval = 5
    
 /// 设备发现超时（秒）
    public static let discoveryTimeoutSeconds: TimeInterval = 10
    
 /// 自动重连延迟（秒）
    public static let autoReconnectDelaySeconds: TimeInterval = 5
    
 /// 最大重连尝试次数
    public static let maxReconnectAttempts: Int = 3
    
 /// 方向变化更新超时（毫秒）
    public static let orientationUpdateTimeoutMs: Int = 500
    
 // MARK: - Size Constants
    
 /// Nonce 大小（字节）
    public static let nonceSize: Int = 32
    
 /// Challenge 大小（字节）
    public static let challengeSize: Int = 32
    
 /// 配对码长度
    public static let pairingCodeLength: Int = 6
    
 /// pubKeyFP 完整长度（SHA-256 hex = 64 chars）
    public static let pubKeyFPFullLength: Int = 64
    
 /// pubKeyFP 显示长度（截断用于 UI）
    public static let pubKeyFPDisplayLength: Int = 16
    
 /// VideoFramePacket 固定头部大小（字节）
 /// frameSeq(8) + fragIndex(2) + fragCount(2) + flags(2) + timestamp(8) + reserved(2) = 24
    public static let videoFrameHeaderSize: Int = 24
    
 /// 保守的 datagram payload 基准大小（字节）
 /// 实际使用时应根据 maxDatagramSize 动态计算
    public static let conservativeDatagramPayloadSize: Int = 1200
    
 /// Merkle tree 块大小（字节）
    public static let merkleBlockSize: Int = 64 * 1024 // 64KB
    
 /// 文件传输块大小（字节）
    public static let fileChunkSize: Int = 256 * 1024 // 256KB
    
 // MARK: - Replay Prevention
    
 /// Nonce 缓存过期时间（秒）
    public static let nonceCacheExpirationSeconds: TimeInterval = 300 // 5 分钟
    
 /// 最大 nonce 缓存大小
    public static let maxNonceCacheSize: Int = 10000
    
 // MARK: - Rate Limiting
    
 /// Rate limit 窗口大小（秒）
    public static let rateLimitWindowSeconds: TimeInterval = 60
    
 /// 每窗口最大请求数
    public static let rateLimitMaxRequests: Int = 10
    
 /// 指数退避基数（秒）
    public static let exponentialBackoffBaseSeconds: TimeInterval = 2
    
 /// 指数退避最大值（秒）
    public static let exponentialBackoffMaxSeconds: TimeInterval = 300
    
 // MARK: - Video Constants
    
 /// 过期帧丢弃窗口（毫秒）
    public static let staleFrameWindowMs: Int = 100
    
 /// 默认视频帧率
    public static let defaultVideoFPS: Int = 30
    
 /// 默认视频比特率（bps）
    public static let defaultVideoBitrate: Int = 4_000_000 // 4 Mbps
    
 // MARK: - Service Discovery
    
 /// Bonjour 服务类型 (UDP - QUIC primary)
    public static let bonjourServiceTypeUDP = "_skybridge._udp"
    
 /// Bonjour 服务类型 (TCP - fallback)
    public static let bonjourServiceTypeTCP = "_skybridge._tcp"
    
 /// Bonjour 服务域
    public static let bonjourServiceDomain = "local."
}

// MARK: - Crypto Algorithm Identifiers

/// 加密算法标识符
public enum P2PCryptoAlgorithm: String, Codable, Sendable {
 // KEM 算法
    case xWing = "X-Wing"           // X25519 + ML-KEM-768 (iOS 26+)
    case mlKEM768 = "ML-KEM-768"    // 纯 PQC KEM
    case x25519 = "X25519"          // 经典 ECDH
    
 // 签名算法
    case mlDSA65 = "ML-DSA-65"      // PQC 签名 (iOS 26+)
    case p256 = "P-256"             // 经典 ECDSA
    
 // AEAD 算法
    case aes256GCM = "AES-256-GCM"
    case chaCha20Poly1305 = "ChaCha20-Poly1305"
    
 /// 是否为 PQC 算法
    public var isPQC: Bool {
        switch self {
        case .xWing, .mlKEM768, .mlDSA65:
            return true
        default:
            return false
        }
    }
}

// MARK: - Attestation Levels

/// 设备证明等级
public enum P2PAttestationLevel: Int, Codable, Sendable, Comparable {
 /// 无证明 - 仅依赖公钥指纹
    case none = 0
    
 /// DeviceCheck - 风控/反滥用信号
    case deviceCheck = 1
    
 /// App Attest - 硬件密钥 + Apple 服务器背书
    case appAttest = 2
    
    public static func < (lhs: P2PAttestationLevel, rhs: P2PAttestationLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
 /// 显示名称
    public var displayName: String {
        switch self {
        case .none: return "无证明"
        case .deviceCheck: return "DeviceCheck"
        case .appAttest: return "App Attest"
        }
    }
    
 /// 是否需要服务器验证
    public var requiresServerVerification: Bool {
        switch self {
        case .none: return false
        case .deviceCheck, .appAttest: return true
        }
    }
}
