import Foundation
import SkyBridgeRealtimeMedia

enum RemoteDesktopManagerRuntimeLimits {
    static let lanReceiveChunkMaxBytes: Int = 8 * 1024
    static let maxLANScreenFramesPerParserDrain = 4
    static let smokeRollingFrameWindowSeconds: TimeInterval = 2.0
}

enum RemoteDesktopManagerRuntimeConfig {
    static let crossNetworkNativeAudioReceiveEnabled = false
    static let realtimeMediaAudioReceiverSlowDiagnosticDelay: Duration = .seconds(3)
    static let realtimeMediaAudioReceiverStageTimeout: Duration = .seconds(8)
    static let realtimeMediaAudioReceiverTotalTimeout: Duration = .seconds(15)
    static let realtimeMediaAudioRelayBindAckGraceDelay: Duration = .seconds(5)
    static let realtimeMediaAudioNoTrafficRecoveryDelay: Duration = .seconds(10)
    static let realtimeMediaAudioNoTrafficRecoveryMaxAttempts: Int = 2
    static let realtimeMediaAudioRelayRolloverGraceDelay: Duration = .seconds(15)
    static let realtimeMediaAudioRelayRolloverTrafficObservationTimeout: TimeInterval = 10
    static let realtimeMediaAudioRelayRolloverTrafficObservationPoll: Duration = .milliseconds(250)
    static let realtimeMediaAudioRelayRolloverMinimumObservedPackets: UInt64 = 4
    static let realtimeMediaAudioEndpointRenewalLeadTime: TimeInterval = 12
    static let viewerSettingsStore = CodablePersistenceStore<RemoteDesktopViewerSettings>(
        location: .protectedApplicationSupport(
            path: "RemoteDesktop/viewer-settings.json",
            legacyUserDefaultsKey: "com.skybridge.remoteDesktop.viewerSettings.v1"
        )
    )

    static var remoteDesktopBuildFingerprint: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "-"
        let build = (info["CFBundleVersion"] as? String) ?? "-"
        let bundleId = Bundle.main.bundleIdentifier ?? "-"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return "bundle=\(bundleId) version=\(version) build=\(build) os=\(osVersion)"
    }
}

enum LANInboundPayloadKind: Equatable {
    case audio
    case screen
    case control
}

final class RealtimeMediaAudioRelayTrafficCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: UInt64 = 0

    func increment() {
        lock.lock()
        packets &+= 1
        lock.unlock()
    }

    func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return packets
    }
}

@available(iOS 17.0, *)
extension RemoteDesktopManager {
    struct IncomingStreamSignature: Equatable {
        let format: String
        let width: Int
        let height: Int
    }

    enum ActiveTransportMode {
        case none
        case lan
        case crossNetwork
    }

    enum DecodedVideoRendererPreference {
        case metal
        case sampleBuffer
        case cgImage
    }

    enum RealtimeMediaAudioReceiverStartPhase: String {
        case pending
        case lease
        case udpConnection
        case relayBindAck
        case receiverReady
    }

    enum RealtimeMediaAudioReceiverStartFailureReason: String {
        case stageTimeout
        case totalTimeout
    }

    enum OptimisticRelayBindState: Equatable {
        case idle
        case ackPending(sessionId: String, endpoint: SkyBridgeMediaEndpoint)
        case accepted(sessionId: String, endpoint: SkyBridgeMediaEndpoint)
        case trafficObserved(sessionId: String, endpoint: SkyBridgeMediaEndpoint)
        case failed(sessionId: String, endpoint: SkyBridgeMediaEndpoint, reason: String)
    }
}
