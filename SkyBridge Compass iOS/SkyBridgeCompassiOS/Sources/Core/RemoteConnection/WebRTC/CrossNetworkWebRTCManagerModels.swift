import Foundation
import SkyBridgeRealtimeMedia

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    public struct VerifiedConnectLinkTrustImport: Sendable, Equatable {
        public let deviceID: String
        public let deviceName: String
        public let capabilities: [String]
        public let protocolPublicKeyFingerprint: String
        public let kemSuiteWireIDs: [UInt16]
    }

    public enum State: Sendable, Equatable {
        case idle
        case connecting(sessionId: String)
        case connected(sessionId: String)
        case failed(String)
    }

    public enum Readiness: Sendable, Equatable {
        case idle
        case transportReady(sessionId: String)
        case handshakeComplete(sessionId: String, negotiatedSuite: String)
    }

    public enum ConnectionCodeLeaseMode: String, CaseIterable, Sendable {
        case shortLived
        case dayStable

        var validDuration: TimeInterval {
            switch self {
            case .shortLived:
                return 10 * 60
            case .dayStable:
                return 24 * 60 * 60
            }
        }
    }

    public struct IdleConnectionPrompt: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let sessionId: String
        public let deviceName: String
    }

    struct RealtimeMediaRelayEndpointPair: Sendable, Equatable {
        let localEndpoint: SkyBridgeMediaEndpoint
        let localRole: String
    }

    enum SignalingHealth: Equatable {
        case healthy
        case degradedRecoverable
        case degradedFatal
    }

    struct SessionSnapshotMetadata: Sendable {
        let snapshotToken: UUID
        let source: ActiveSessionSnapshotSource
        let deviceId: String?
        let deviceName: String?
    }

    enum FileTransferWaitError: LocalizedError {
        case timeout
        case cancelled
        case transportClosed

        var errorDescription: String? {
            switch self {
            case .timeout: return "跨网文件传输等待超时"
            case .cancelled: return "跨网文件传输已取消"
            case .transportClosed: return "跨网文件传输通道已关闭"
            }
        }
    }
}
