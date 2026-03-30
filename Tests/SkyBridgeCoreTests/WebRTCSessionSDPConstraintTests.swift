import Testing
@testable import SkyBridgeCore

@Suite("WebRTCSession SDP Constraint Tests")
struct WebRTCSessionSDPConstraintTests {
    @Test("本地存在视频 transceiver 时应请求保留 video m-line")
    func testOfferToReceiveVideoEnabledWhenVideoTransceiverExists() {
        #expect(
            WebRTCSession.offerToReceiveVideoConstraintValue(
                hasNegotiatedVideoTransceiver: true
            ) == "true"
        )
    }

    @Test("本地不存在视频 transceiver 时不应请求 video m-line")
    func testOfferToReceiveVideoDisabledWithoutVideoTransceiver() {
        #expect(
            WebRTCSession.offerToReceiveVideoConstraintValue(
                hasNegotiatedVideoTransceiver: false
            ) == "false"
        )
    }
}
