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

    @Test("原生 WebRTC 音频发送轨默认关闭，避免无接收端时抢占音频会话")
    func testNativeOutgoingAudioTrackDefaultsOff() {
        #expect(
            WebRTCSession.nativeOutgoingAudioTrackPreference(environment: [:]) == false
        )
    }

    @Test("原生 WebRTC 音频发送轨仅允许显式环境开关打开")
    func testNativeOutgoingAudioTrackCanBeExplicitlyEnabled() {
        #expect(
            WebRTCSession.nativeOutgoingAudioTrackPreference(
                environment: ["SKYBRIDGE_ENABLE_WEBRTC_NATIVE_AUDIO_TRACK": "1"]
            ) == true
        )
        #expect(
            WebRTCSession.nativeOutgoingAudioTrackPreference(
                environment: ["SKYBRIDGE_ENABLE_WEBRTC_NATIVE_AUDIO_TRACK": "0"]
            ) == false
        )
    }
}
