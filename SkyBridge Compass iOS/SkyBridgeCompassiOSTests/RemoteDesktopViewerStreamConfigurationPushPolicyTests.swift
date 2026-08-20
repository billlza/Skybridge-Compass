import XCTest
import SkyBridgeProtocolCore

@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class RemoteDesktopViewerStreamConfigurationPushPolicyTests: XCTestCase {
    func testAudioAdmissionCloseWaitsForInFlightPublisherAndRejectsLateEffects() {
        let gate = IOSRealtimeMediaAudioAdmissionGate(open: true)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let closeStarted = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = gate.withOpen {
                entered.signal()
                release.wait()
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            closeStarted.signal()
            gate.setOpen(false)
            closeFinished.signal()
        }
        XCTAssertEqual(closeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(gate.withOpen { 1 })

        gate.setOpen(true)
        XCTAssertEqual(gate.withOpen { 2 }, 2)
    }

    func testMediaAdmissionRequiresExactConfigurationAcknowledgement() throws {
        let first = RemoteDesktopStreamConfigurationTransaction(
            id: try XCTUnwrap(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        )
        let replacement = RemoteDesktopStreamConfigurationTransaction(
            id: try XCTUnwrap(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440001"))
        )

        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.allowsMediaAdmission(
                isReadOnlyCameraSession: false,
                activeTransaction: first,
                acknowledgedTransaction: nil
            )
        )
        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.allowsMediaAdmission(
                isReadOnlyCameraSession: false,
                activeTransaction: replacement,
                acknowledgedTransaction: first
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.allowsMediaAdmission(
                isReadOnlyCameraSession: false,
                activeTransaction: first,
                acknowledgedTransaction: first
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.allowsMediaAdmission(
                isReadOnlyCameraSession: true,
                activeTransaction: nil,
                acknowledgedTransaction: nil
            )
        )
    }

    func testStreamConfigurationOperationGateRejectsOutOfOrderCompletion() {
        let gate = RemoteDesktopManager.RemoteDesktopStreamConfigurationOperationGate()
        let first = gate.begin()
        let replacement = gate.begin()

        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(replacement))
        gate.invalidate(first)
        XCTAssertTrue(gate.isCurrent(replacement))
        gate.invalidate(replacement)
        XCTAssertFalse(gate.isCurrent(replacement))
    }

    func testAcknowledgementMustMatchExactLogicalConfiguration() {
        let first = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        let replacement = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )
        let expectation = RemoteDesktopViewerStreamConfigurationPushPolicy
            .AcknowledgementExpectation(
                transaction: replacement,
                streamRefreshToken: 7,
                audioEndpointPresent: true,
                screenFrameTransport: "webrtc-native-main",
                framePresentationAckVersion:
                    RemoteDesktopFramePresentationAcknowledgement.currentVersion
            )

        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.acknowledgementMatches(
                .init(
                    acceptedAt: 1,
                    transaction: first,
                    streamRefreshToken: 7,
                    audioEndpointPresent: true,
                    screenFrameTransport: "webrtc-native-main",
                    framePresentationAckVersion:
                        RemoteDesktopFramePresentationAcknowledgement.currentVersion
                ),
                expectation: expectation
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.acknowledgementMatches(
                .init(
                    acceptedAt: 2,
                    transaction: replacement,
                    streamRefreshToken: 7,
                    audioEndpointPresent: true,
                    screenFrameTransport: "webrtc-native-main",
                    framePresentationAckVersion:
                        RemoteDesktopFramePresentationAcknowledgement.currentVersion
                ),
                expectation: expectation
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.acknowledgementMatches(
                .init(
                    acceptedAt: 3,
                    transaction: replacement,
                    streamRefreshToken: 7,
                    audioEndpointPresent: true,
                    screenFrameTransport: "webrtc-native-main",
                    framePresentationAckVersion: nil
                ),
                expectation: expectation
            ),
            "A legacy host must keep streaming when it omits the optional capability receipt"
        )
        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.acknowledgementMatches(
                .init(
                    acceptedAt: 4,
                    transaction: replacement,
                    streamRefreshToken: 7,
                    audioEndpointPresent: true,
                    screenFrameTransport: "webrtc-native-main",
                    framePresentationAckVersion: 2
                ),
                expectation: expectation
            )
        )
    }

    func testFramePresentationAcknowledgementGateRejectsDuplicateAndStaleRelease() {
        let first = RemoteDesktopFramePresentationContext(
            sequenceNumber: 1,
            streamTransaction: RemoteDesktopStreamConfigurationTransaction(),
            streamEpoch: 7
        )
        let replacement = RemoteDesktopFramePresentationContext(
            sequenceNumber: 2,
            streamTransaction: RemoteDesktopStreamConfigurationTransaction(),
            streamEpoch: 8
        )
        var gate = RemoteDesktopManager.FramePresentationAcknowledgementGate()

        XCTAssertTrue(gate.reserve(first))
        XCTAssertFalse(gate.reserve(first))
        gate.release(replacement)
        XCTAssertTrue(gate.isCurrent(first))
        gate.release(first)
        XCTAssertTrue(gate.reserve(replacement))
        gate.reset()
        XCTAssertFalse(gate.isCurrent(replacement))
    }
    func testPendingAudioBindingIsNotUsableBeforeExactTransportIsReady() {
        XCTAssertFalse(
            RemoteDesktopManager.RealtimeMediaAudioBindingAvailabilityPolicy.isUsable(
                transportMode: .crossNetwork,
                hasRenderer: true,
                hasLANReceiver: false,
                hasRelayTransport: false,
                installedMode: .lowLatency,
                expectedMode: .lowLatency
            )
        )
        XCTAssertTrue(
            RemoteDesktopManager.RealtimeMediaAudioBindingAvailabilityPolicy.isUsable(
                transportMode: .crossNetwork,
                hasRenderer: true,
                hasLANReceiver: false,
                hasRelayTransport: true,
                installedMode: .lowLatency,
                expectedMode: .lowLatency
            )
        )
    }

    func testAudioModeChangeInvalidatesExistingBinding() {
        XCTAssertFalse(
            RemoteDesktopManager.RealtimeMediaAudioBindingAvailabilityPolicy.isUsable(
                transportMode: .lan,
                hasRenderer: true,
                hasLANReceiver: true,
                hasRelayTransport: false,
                installedMode: .highFidelity,
                expectedMode: .lowLatency
            )
        )
    }

    func testSessionMutationGateInvalidatesAttemptsAndSerializesTeardown() throws {
        let gate = RemoteDesktopManager.RemoteDesktopSessionMutationGate()
        let attempt = try XCTUnwrap(gate.beginConnectionAttempt())
        let witness = try XCTUnwrap(gate.captureOperationWitness())
        XCTAssertTrue(gate.isCurrent(attempt))
        XCTAssertTrue(gate.isCurrent(witness))
        XCTAssertNil(gate.beginConnectionAttempt())

        let teardown = try XCTUnwrap(gate.beginExclusiveMutation())
        XCTAssertFalse(gate.isCurrent(attempt))
        XCTAssertFalse(gate.isCurrent(witness))
        XCTAssertTrue(gate.hasActiveExclusiveMutation)
        XCTAssertNil(gate.beginConnectionAttempt())
        XCTAssertFalse(gate.canCommit(teardown, ownerIsCurrent: false))
        XCTAssertTrue(gate.canCommit(teardown, ownerIsCurrent: true))

        gate.finish(teardown)
        XCTAssertFalse(gate.hasActiveExclusiveMutation)
        let replacement = try XCTUnwrap(gate.beginConnectionAttempt())
        gate.finish(attempt)
        XCTAssertTrue(gate.isCurrent(replacement))
        gate.finish(replacement)
        XCTAssertNil(gate.beginExclusiveMutation(ifCurrent: false))
    }

    func testNoTransportCannotSendButStillPlansAudioIntent() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .none,
            hasCurrentConnection: false,
            hasLANConnection: false,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: false,
            refreshStream: false,
            lastSentMediaAudioEndpointPresent: false,
            lastAcknowledgedMediaAudioEndpointPresent: false
        )

        XCTAssertFalse(plan.canSend)
        XCTAssertFalse(plan.canSendOverWebRTC)
        XCTAssertFalse(plan.canSendOverLAN)
        XCTAssertTrue(plan.shouldStartRealtimeMediaAudioReceiver)
        XCTAssertFalse(plan.shouldStopRealtimeMediaAudioReceiver)
    }

    func testStrictAudioValidationSendsExplicitVideoOnlyWhileEndpointPrepares() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .crossNetwork,
            hasCurrentConnection: true,
            hasLANConnection: false,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: false,
            refreshStream: false,
            lastSentMediaAudioEndpointPresent: false,
            lastAcknowledgedMediaAudioEndpointPresent: false
        )

        XCTAssertTrue(plan.canSend)
        XCTAssertTrue(plan.shouldStartRealtimeMediaAudioReceiver)
        XCTAssertFalse(plan.includeAudioEndpointInStreamConfig)
    }

    func testCrossNetworkRefreshDoesNotRepeatExistingAudioEndpoint() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .crossNetwork,
            hasCurrentConnection: true,
            hasLANConnection: false,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: true,
            refreshStream: true,
            lastSentMediaAudioEndpointPresent: true,
            lastAcknowledgedMediaAudioEndpointPresent: true
        )

        XCTAssertFalse(plan.includeAudioEndpointInStreamConfig)
    }

    func testCrossNetworkRefreshRepeatsAudioEndpointUntilHostAcknowledgesIt() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .crossNetwork,
            hasCurrentConnection: true,
            hasLANConnection: false,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: true,
            refreshStream: true,
            lastSentMediaAudioEndpointPresent: true,
            lastAcknowledgedMediaAudioEndpointPresent: false
        )

        XCTAssertTrue(plan.includeAudioEndpointInStreamConfig)
    }

    func testCrossNetworkFirstAudioConfigIncludesEndpoint() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .crossNetwork,
            hasCurrentConnection: true,
            hasLANConnection: false,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: true,
            refreshStream: false,
            lastSentMediaAudioEndpointPresent: false,
            lastAcknowledgedMediaAudioEndpointPresent: false
        )

        XCTAssertTrue(plan.includeAudioEndpointInStreamConfig)
    }

    func testLANRefreshAlwaysKeepsAudioEndpointWhenAvailable() {
        let plan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: .lan,
            hasCurrentConnection: false,
            hasLANConnection: true,
            audioRedirectionEnabled: true,
            hasUsableMediaAudioBinding: true,
            refreshStream: true,
            lastSentMediaAudioEndpointPresent: true,
            lastAcknowledgedMediaAudioEndpointPresent: true
        )

        XCTAssertTrue(plan.canSendOverLAN)
        XCTAssertTrue(plan.includeAudioEndpointInStreamConfig)
    }

    func testPayloadSendAndAckRetryGatesMatchExistingBehavior() {
        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.shouldSendPayload(
                force: false,
                payloadMatchesLastSent: true
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.shouldSendPayload(
                force: true,
                payloadMatchesLastSent: true
            )
        )
        XCTAssertTrue(
            RemoteDesktopViewerStreamConfigurationPushPolicy.shouldScheduleAckRetry(
                activeTransportMode: .crossNetwork,
                isStreaming: true,
                hasReceivedFrameInCurrentStream: false,
                payloadIncludesAudioEndpoint: false
            )
        )
        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.shouldScheduleAckRetry(
                activeTransportMode: .crossNetwork,
                isStreaming: true,
                hasReceivedFrameInCurrentStream: false,
                payloadIncludesAudioEndpoint: true
            )
        )
        XCTAssertFalse(
            RemoteDesktopViewerStreamConfigurationPushPolicy.shouldScheduleAckRetry(
                activeTransportMode: .lan,
                isStreaming: true,
                hasReceivedFrameInCurrentStream: false,
                payloadIncludesAudioEndpoint: false
            )
        )
    }
}
