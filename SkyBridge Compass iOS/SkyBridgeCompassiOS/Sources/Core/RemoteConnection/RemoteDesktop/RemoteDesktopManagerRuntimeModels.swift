import Foundation
import SkyBridgeRealtimeMedia

enum RemoteDesktopManagerRuntimeLimits {
    static let lanReceiveChunkMaxBytes: Int = 256 * 1024
    static let maxLANScreenFramesPerParserDrain = 4
    static let maxLANParserDrainBudgetMs: Double = 6.0
    static let maxPredictiveVideoDecodeInFlight = 4
    static let maxPendingDecodeCompletionBacklog = 8
    static let decodeCompletionGapWatchdogDelay: Duration = .milliseconds(500)
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

enum RemoteDesktopMetalContinuityStallDecision: Equatable {
    case failFast
    case deferStall(classification: String)
}

struct RemoteDesktopMetalContinuityStallPolicyInput {
    let reason: String
    let isMetalRenderer: Bool
    let hasPresentationOwner: Bool
    let activeMetalConsumerCount: Int
    let displayedFramesInStatsWindow: Int
    let displayedFramesInCurrentStream: Int
    let observedDisplayedFramesWatermark: Int
    let metalDisplayedFramesInWindow: Int
    let metalDisplayedFramesInStream: Int
    let observedMetalDisplayedFramesWatermark: Int
    let displayedAgeSeconds: TimeInterval?
    let metalDisplayedAgeSeconds: TimeInterval?
    let arrivalAgeSeconds: TimeInterval?
    let decodedAgeSeconds: TimeInterval?
    let enqueueAgeSeconds: TimeInterval?
    let decodedFramesInStatsWindow: Int
    let rendererEnqueuedFramesInStatsWindow: Int
    let inputFPS: Double
    let inputFailureThresholdFPS: Double
}

struct RemoteDesktopMetalContinuityStallPolicyResult: Equatable {
    let decision: RemoteDesktopMetalContinuityStallDecision
    let observedDisplayedFramesWatermark: Int
    let observedMetalDisplayedFramesWatermark: Int
}

enum RemoteDesktopMetalContinuityStallPolicy {
    static func evaluate(
        _ input: RemoteDesktopMetalContinuityStallPolicyInput
    ) -> RemoteDesktopMetalContinuityStallPolicyResult {
        func result(
            _ decision: RemoteDesktopMetalContinuityStallDecision,
            displayedWatermark: Int,
            metalDisplayedWatermark: Int
        ) -> RemoteDesktopMetalContinuityStallPolicyResult {
            RemoteDesktopMetalContinuityStallPolicyResult(
                decision: decision,
                observedDisplayedFramesWatermark: displayedWatermark,
                observedMetalDisplayedFramesWatermark: metalDisplayedWatermark
            )
        }
        func unchangedResult(
            _ decision: RemoteDesktopMetalContinuityStallDecision
        ) -> RemoteDesktopMetalContinuityStallPolicyResult {
            result(
                decision,
                displayedWatermark: input.observedDisplayedFramesWatermark,
                metalDisplayedWatermark: input.observedMetalDisplayedFramesWatermark
            )
        }

        guard input.isMetalRenderer else { return unchangedResult(.failFast) }
        guard input.hasPresentationOwner else {
            return unchangedResult(.deferStall(classification: "remote-view-not-presented"))
        }
        guard input.activeMetalConsumerCount > 0 else {
            return unchangedResult(.deferStall(classification: "metal-consumer-not-active"))
        }

        let effectiveDisplayedAge = [
            input.displayedAgeSeconds,
            input.metalDisplayedAgeSeconds
        ].compactMap { $0 }.min()
        let hasDisplayedFrame = input.displayedAgeSeconds != nil
            || input.displayedFramesInCurrentStream > 0
            || input.metalDisplayedFramesInStream > 0
        let hasRecentDisplayProgress = input.displayedFramesInStatsWindow > 0
            || (input.displayedAgeSeconds.map { $0 < 2.0 } ?? false)
            || input.metalDisplayedFramesInWindow > 0
            || (input.metalDisplayedAgeSeconds.map { $0 < 2.0 } ?? false)
        let hasRecentDecodedInput = input.decodedAgeSeconds.map { $0 < 2.0 } ?? false
        let hasRecentEnqueuedInput = input.enqueueAgeSeconds.map { $0 < 2.0 } ?? false
        let hasRecentArrivingInput = input.arrivalAgeSeconds.map { $0 < 2.0 } ?? false
        let hasRendererEnqueue = input.rendererEnqueuedFramesInStatsWindow > 0 || hasRecentEnqueuedInput
        let hasRendererInput = input.decodedFramesInStatsWindow > 0
            || hasRendererEnqueue
            || hasRecentDecodedInput
        let displayStaleEnough = effectiveDisplayedAge.map { $0 >= 2.0 } ?? false

        if hasDisplayedFrame, hasRecentDisplayProgress {
            return unchangedResult(.deferStall(classification: "display-progress-present"))
        }

        let displayTotalAdvanced = input.displayedFramesInCurrentStream > input.observedDisplayedFramesWatermark
            || input.metalDisplayedFramesInStream > input.observedMetalDisplayedFramesWatermark
        let updatedDisplayedWatermark = max(
            input.observedDisplayedFramesWatermark,
            input.displayedFramesInCurrentStream
        )
        let updatedMetalDisplayedWatermark = max(
            input.observedMetalDisplayedFramesWatermark,
            input.metalDisplayedFramesInStream
        )

        if displayTotalAdvanced {
            return result(
                .deferStall(classification: "display-total-progress-present"),
                displayedWatermark: updatedDisplayedWatermark,
                metalDisplayedWatermark: updatedMetalDisplayedWatermark
            )
        }

        func observedResult(
            _ decision: RemoteDesktopMetalContinuityStallDecision
        ) -> RemoteDesktopMetalContinuityStallPolicyResult {
            result(
                decision,
                displayedWatermark: updatedDisplayedWatermark,
                metalDisplayedWatermark: updatedMetalDisplayedWatermark
            )
        }

        if hasDisplayedFrame,
           (input.reason == "frames-arriving-without-display"
            || input.reason == "frames-decoding-without-display"),
           (!hasRendererInput || !displayStaleEnough) {
            return observedResult(.deferStall(classification: "post-first-display-not-renderer-failure"))
        }

        if input.reason == "frames-decoding-without-display", !hasRendererEnqueue {
            return observedResult(.deferStall(classification: "decoded-without-renderer-enqueue"))
        }

        if input.reason == "frames-arriving-without-display", !hasRendererEnqueue {
            return observedResult(.deferStall(classification: "arrived-without-renderer-enqueue"))
        }

        if input.inputFPS > 0, input.inputFPS < input.inputFailureThresholdFPS {
            return observedResult(
                .deferStall(
                    classification: hasDisplayedFrame
                        ? "input-cadence-below-display-failure-threshold"
                        : "startup-input-cadence-below-display-failure-threshold"
                )
            )
        }

        if input.inputFPS == 0,
           hasRecentArrivingInput || hasRecentDecodedInput || hasRecentEnqueuedInput {
            return observedResult(
                .deferStall(
                    classification: hasDisplayedFrame
                        ? "input-cadence-window-reset-below-display-failure-threshold"
                        : "startup-input-cadence-window-reset-below-display-failure-threshold"
                )
            )
        }

        if input.reason == "metal-first-display-timeout" {
            if !hasDisplayedFrame,
               hasRendererEnqueue,
               input.enqueueAgeSeconds.map({ $0 >= 2.0 }) ?? false {
                return observedResult(.failFast)
            }
            return observedResult(
                .deferStall(
                    classification: hasRendererEnqueue
                        ? "startup-renderer-input-not-stale"
                        : "startup-no-renderer-enqueue"
                )
            )
        }

        guard hasRendererInput else {
            return observedResult(.deferStall(classification: "no-renderer-input-evidence"))
        }

        guard effectiveDisplayedAge.map({ $0 >= 2.0 }) ?? true else {
            return observedResult(.deferStall(classification: "display-stale-window-not-expired"))
        }

        return observedResult(.failFast)
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

    struct PendingDecodeCompletion {
        let decoded: DecodeOutput?
        let decodeFailureReason: String?
        let isStillImageFrame: Bool
        let sourceFrame: ScreenData
        let format: String
        let decoder: VideoDecoder
        let generation: UInt64
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
