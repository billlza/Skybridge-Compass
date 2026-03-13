//
// SkyBridgeMessages.swift
// SkyBridgeCore
//
// SkyBridge Protocol 消息类型定义
// 跨平台统一的信令消息格式
//
// Requirements: 2.6, 2.7, 9.1
//

import Foundation

// MARK: - Protocol Base

/// SkyBridge 协议消息基础协议
public protocol SkyBridgeMessage: Codable, Sendable, Equatable {
 /// 消息类型标识
    var type: String { get }
}

// MARK: - Authentication Messages

/// 认证消息 - 客户端发送给 Agent
public struct AuthMessage: SkyBridgeMessage {
    public let type: String = "auth"
    public let token: String
    
    public init(token: String) {
        self.token = token
    }
    
    enum CodingKeys: String, CodingKey {
        case type, token
    }
}

/// 认证成功响应 - Agent 返回给客户端
public struct AuthOKMessage: SkyBridgeMessage {
    public let type: String = "auth-ok"
    public let message: String
    
    public init(message: String) {
        self.message = message
    }
    
    enum CodingKeys: String, CodingKey {
        case type, message
    }
}

/// 认证失败响应
public struct AuthFailedMessage: SkyBridgeMessage {
    public let type: String = "auth-failed"
    public let reason: String
    
    public init(reason: String) {
        self.reason = reason
    }
    
    enum CodingKeys: String, CodingKey {
        case type, reason
    }
}


// MARK: - Session Messages

/// 会话加入消息
public struct SessionJoinMessage: SkyBridgeMessage {
    public let type: String = "session-join"
    public let sessionId: String
    public let deviceId: String
    
    public init(sessionId: String, deviceId: String) {
        self.sessionId = sessionId
        self.deviceId = deviceId
    }
    
    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case deviceId = "device_id"
    }
}

/// 会话已加入响应
public struct SessionJoinedMessage: SkyBridgeMessage {
    public let type: String = "session-joined"
    public let sessionId: String
    public let deviceId: String
    
    public init(sessionId: String, deviceId: String) {
        self.sessionId = sessionId
        self.deviceId = deviceId
    }
    
    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case deviceId = "device_id"
    }
}

/// 会话离开消息
public struct SessionLeaveMessage: SkyBridgeMessage {
    public let type: String = "session-leave"
    public let sessionId: String
    public let deviceId: String
    
    public init(sessionId: String, deviceId: String) {
        self.sessionId = sessionId
        self.deviceId = deviceId
    }
    
    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case deviceId = "device_id"
    }
}

// MARK: - SDP Messages

/// SDP 描述结构
public struct SDPDescription: Codable, Sendable, Equatable {
    public let type: String  // "offer" or "answer"
    public let sdp: String
    
    public init(type: String, sdp: String) {
        self.type = type
        self.sdp = sdp
    }
}

/// SDP Offer 消息
public struct SDPOfferMessage: SkyBridgeMessage {
    public let type: String = "sdp-offer"
    public let sessionId: String
    public let deviceId: String
    public let authToken: String
    public let offer: SDPDescription
    
    public init(sessionId: String, deviceId: String, authToken: String, offer: SDPDescription) {
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.authToken = authToken
        self.offer = offer
    }
    
    enum CodingKeys: String, CodingKey {
        case type, offer
        case sessionId = "session_id"
        case deviceId = "device_id"
        case authToken = "auth_token"
    }
}

/// SDP Answer 消息
public struct SDPAnswerMessage: SkyBridgeMessage {
    public let type: String = "sdp-answer"
    public let sessionId: String
    public let deviceId: String
    public let authToken: String
    public let answer: SDPDescription
    
    public init(sessionId: String, deviceId: String, authToken: String, answer: SDPDescription) {
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.authToken = authToken
        self.answer = answer
    }
    
    enum CodingKeys: String, CodingKey {
        case type, answer
        case sessionId = "session_id"
        case deviceId = "device_id"
        case authToken = "auth_token"
    }
}


// MARK: - ICE Messages

/// ICE 候选结构 (SkyBridge Protocol)
public struct SBICECandidate: Codable, Sendable, Equatable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int?
    
    public init(candidate: String, sdpMid: String? = nil, sdpMLineIndex: Int? = nil) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
    
    enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_m_line_index"
    }
}

/// ICE Candidate 消息 (SkyBridge Protocol)
public struct SBICECandidateMessage: SkyBridgeMessage {
    public let type: String = "ice-candidate"
    public let sessionId: String
    public let deviceId: String
    public let authToken: String
    public let candidate: SBICECandidate
    
    public init(sessionId: String, deviceId: String, authToken: String, candidate: SBICECandidate) {
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.authToken = authToken
        self.candidate = candidate
    }
    
    enum CodingKeys: String, CodingKey {
        case type, candidate
        case sessionId = "session_id"
        case deviceId = "device_id"
        case authToken = "auth_token"
    }
}

// MARK: - Device Messages

/// 设备信息结构 (SkyBridge Protocol - Agent 设备发现)
public struct SBDeviceInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let ipv4: String?
    public let ipv6: String?
    public let services: [String]
    public let portMap: [String: Int]
    public let connectionTypes: [String]
    public let source: String
    public let isLocalDevice: Bool
    public let deviceId: String?
    public let pubKeyFP: String?
    
    public init(
        id: String,
        name: String,
        ipv4: String? = nil,
        ipv6: String? = nil,
        services: [String] = [],
        portMap: [String: Int] = [:],
        connectionTypes: [String] = [],
        source: String = "bonjour",
        isLocalDevice: Bool = false,
        deviceId: String? = nil,
        pubKeyFP: String? = nil
    ) {
        self.id = id
        self.name = name
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.services = services
        self.portMap = portMap
        self.connectionTypes = connectionTypes
        self.source = source
        self.isLocalDevice = isLocalDevice
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
    }
    
 // 显式指定所有键名以避免 convertToSnakeCase/convertFromSnakeCase 策略的不一致行为
 // pubKeyFP 会被自动转换成 pub_key_f_p（每个大写字母前加下划线），而不是 pub_key_fp
    enum CodingKeys: String, CodingKey {
        case id, name, ipv4, ipv6, services
        case portMap = "port_map"
        case connectionTypes = "connection_types"
        case source
        case isLocalDevice = "is_local_device"
        case deviceId = "device_id"
        case pubKeyFP = "pub_key_fp"
    }
}

/// 设备列表消息
public struct SBDevicesMessage: SkyBridgeMessage {
    public let type: String = "devices"
    public let devices: [SBDeviceInfo]
    
    public init(devices: [SBDeviceInfo]) {
        self.devices = devices
    }
    
    enum CodingKeys: String, CodingKey {
        case type, devices
    }
}

/// 设备更新消息
public struct SBDeviceUpdateMessage: SkyBridgeMessage {
    public let type: String = "device-update"
    public let device: SBDeviceInfo
    public let action: String  // "added", "removed", "updated"
    
    public init(device: SBDeviceInfo, action: String) {
        self.device = device
        self.action = action
    }
    
    enum CodingKeys: String, CodingKey {
        case type, device, action
    }
}


// MARK: - File Transfer Messages

/// 文件元数据消息
public struct FileMetaMessage: SkyBridgeMessage {
    public let type: String = "file-meta"
    public let fileId: String
    public let fileName: String
    public let fileSize: Int64
    public let mimeType: String?
    public let checksum: String?
    
    public init(fileId: String, fileName: String, fileSize: Int64, mimeType: String? = nil, checksum: String? = nil) {
        self.fileId = fileId
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.checksum = checksum
    }
    
    enum CodingKeys: String, CodingKey {
        case type, checksum
        case fileId = "file_id"
        case fileName = "file_name"
        case fileSize = "file_size"
        case mimeType = "mime_type"
    }
}

/// 文件元数据确认消息
public struct FileAckMetaMessage: SkyBridgeMessage {
    public let type: String = "file-ack-meta"
    public let fileId: String
    public let accepted: Bool
    public let reason: String?
    
    public init(fileId: String, accepted: Bool, reason: String? = nil) {
        self.fileId = fileId
        self.accepted = accepted
        self.reason = reason
    }
    
    enum CodingKeys: String, CodingKey {
        case type, accepted, reason
        case fileId = "file_id"
    }
}

/// 文件传输结束消息
public struct FileEndMessage: SkyBridgeMessage {
    public let type: String = "file-end"
    public let fileId: String
    public let success: Bool
    public let bytesTransferred: Int64
    
    public init(fileId: String, success: Bool, bytesTransferred: Int64) {
        self.fileId = fileId
        self.success = success
        self.bytesTransferred = bytesTransferred
    }
    
    enum CodingKeys: String, CodingKey {
        case type, success
        case fileId = "file_id"
        case bytesTransferred = "bytes_transferred"
    }
}

// MARK: - Error Messages

/// 错误消息
public struct ErrorMessage: SkyBridgeMessage {
    public let type: String = "error"
    public let code: String
    public let message: String
    public let details: String?
    
    public init(code: String, message: String, details: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
    
    enum CodingKeys: String, CodingKey {
        case type, code, message, details
    }
}

// MARK: - Message Codec

/// 消息类型枚举
public enum SkyBridgeMessageType: String, Codable, Sendable {
    case auth = "auth"
    case authOK = "auth-ok"
    case authFailed = "auth-failed"
    case sessionJoin = "session-join"
    case sessionJoined = "session-joined"
    case sessionLeave = "session-leave"
    case sdpOffer = "sdp-offer"
    case sdpAnswer = "sdp-answer"
    case iceCandidate = "ice-candidate"
    case devices = "devices"
    case deviceUpdate = "device-update"
    case fileMeta = "file-meta"
    case fileAckMeta = "file-ack-meta"
    case fileEnd = "file-end"
    case error = "error"
}

/// 消息编解码器
public enum SkyBridgeMessageCodec {
    
 // 不使用 convertToSnakeCase/convertFromSnakeCase 策略
 // 所有消息类型通过 CodingKeys 显式指定 snake_case 键名
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()
    
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
    
 /// 编码消息为 JSON Data
    public static func encode<T: SkyBridgeMessage>(_ message: T) throws -> Data {
        try encoder.encode(message)
    }
    
 /// 编码消息为 JSON 字符串
    public static func encodeToString<T: SkyBridgeMessage>(_ message: T) throws -> String {
        let data = try encode(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SkyBridgeMessageError.encodingFailed
        }
        return string
    }
    
 /// 解码 JSON Data 为指定类型消息
    public static func decode<T: SkyBridgeMessage>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
    
 /// 解码 JSON 字符串为指定类型消息
    public static func decode<T: SkyBridgeMessage>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw SkyBridgeMessageError.invalidUTF8
        }
        return try decode(type, from: data)
    }
    
 /// 从 JSON Data 中提取消息类型
    public static func extractMessageType(from data: Data) throws -> SkyBridgeMessageType {
        struct TypeWrapper: Decodable {
            let type: String
        }
        let wrapper = try decoder.decode(TypeWrapper.self, from: data)
        guard let messageType = SkyBridgeMessageType(rawValue: wrapper.type) else {
            throw SkyBridgeMessageError.unknownMessageType(wrapper.type)
        }
        return messageType
    }
}

/// 消息编解码错误
public enum SkyBridgeMessageError: Error, LocalizedError, Sendable {
    case encodingFailed
    case decodingFailed(String)
    case invalidUTF8
    case unknownMessageType(String)
    case missingRequiredField(String)
    
    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "消息编码失败"
        case .decodingFailed(let reason):
            return "消息解码失败: \(reason)"
        case .invalidUTF8:
            return "无效的 UTF-8 编码"
        case .unknownMessageType(let type):
            return "未知的消息类型: \(type)"
        case .missingRequiredField(let field):
            return "缺少必需字段: \(field)"
        }
    }
}
