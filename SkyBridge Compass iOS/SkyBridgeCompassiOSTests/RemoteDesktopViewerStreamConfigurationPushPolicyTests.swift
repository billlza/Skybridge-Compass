import XCTest

@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class RemoteDesktopViewerStreamConfigurationPushPolicyTests: XCTestCase {
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
