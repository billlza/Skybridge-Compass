import Foundation
import Network

enum QRCodeTrustSource {
    case selfAsserted
    case trustedDevice
}

/// Device info returned by connection-code lookup.
struct CrossNetworkDeviceInfo: Sendable {
    let deviceFingerprint: String
    let deviceName: String
    let publicKey: Data
}

struct ICECandidate {
    let host: String
    let port: UInt16
    let type: CandidateType

    enum CandidateType {
        case host, srflx, relay
    }
}

struct ConnectionOffer: Codable {
    let sessionID: String
    let fromDevice: String
    let iceCandidates: [String]
    let timestamp: Date
}

struct ConnectionAnswer: Codable {
    let sessionID: String
    let toDevice: String
    let iceCandidates: [String]
    let timestamp: Date
}

public struct RemoteConnection: @unchecked Sendable {
    public enum Transport: @unchecked Sendable {
        case webrtc(WebRTCSession)
        case nw(NWConnection)
    }

    public let id: String
    public let deviceName: String
    public let transport: Transport
}

public struct CrossNetworkProtocolIdentityStatus: Sendable, Equatable {
    public enum Mode: String, Sendable {
        case configuredAuthority
        case peerCompatibilityIdentity
    }

    public let sessionID: String
    public let configuredAlgorithm: ProtocolSigningAlgorithm
    public let configuredProtection: ProtocolSigningKeyProtection
    public let sessionAlgorithm: ProtocolSigningAlgorithm
    public let sessionProtection: ProtocolSigningKeyProtection
    public let mode: Mode

    public var usesPeerCompatibilityIdentity: Bool {
        mode == .peerCompatibilityIdentity
    }
}

public enum CrossNetworkConnectionError: Error {
    case invalidQRCode
    case qrCodeExpired
    case invalidSignature
    case invalidDevice
    case missingSignalingToken
    case timeout
    case networkError
}

extension CrossNetworkConnectionManager {
    struct SessionSnapshotMetadata: Sendable {
        let snapshotToken: UUID
        let source: ActiveSessionSnapshotSource
        let deviceId: String?
        let deviceName: String?
    }

    enum SignalingOperationRejection: LocalizedError {
        case degradedFatal(String)

        var errorDescription: String? {
            switch self {
            case .degradedFatal(let sessionId):
                return "当前 signaling 处于 degraded-fatal，已封禁新的 signaling 操作: \(sessionId)"
            }
        }
    }

    public enum ConnectionCodeLeaseMode: String, CaseIterable, Sendable {
        case shortLived
        case dayStable

        public var validDuration: TimeInterval {
            switch self {
            case .shortLived:
                return 10 * 60
            case .dayStable:
                return 24 * 60 * 60
            }
        }
    }

    public struct IssuedConnectionCode: Sendable, Equatable {
        public let code: String
        public let sessionID: String
        public let expiresAt: Date?
        public let leaseMode: ConnectionCodeLeaseMode
    }

    /// 跨网络连接状态 - 符合 Swift 6.2.3 的 Sendable 要求和严格并发控制。
    /// 注意：这是 CrossNetworkConnectionManager 专用的连接状态，与全局 ConnectionStatus 不同。
    /// 论文口径：`connected` 必须与 `readiness == .handshakeComplete` 对齐。
    public enum CrossNetworkConnectionStatus: Sendable {
        case idle
        case generating
        case waiting(code: String)
        case connecting
        case connected
        case failed(String)
    }

    public enum CrossNetworkReadiness: Sendable, Equatable {
        case idle
        case transportReady(sessionId: String)
        case handshakeComplete(sessionId: String, negotiatedSuite: String)
    }

    @available(
        *,
        deprecated,
        renamed: "CrossNetworkConnectionStatus",
        message: "使用 CrossNetworkConnectionStatus 以避免与全局 ConnectionStatus 冲突"
    )
    public typealias ConnectionStatus = CrossNetworkConnectionStatus
}
