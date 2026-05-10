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

    @Test("原生屏幕视频优先选择 HEVC/H.265，其次 H.264，再避开 VP8/VP9")
    func testNativeScreenVideoCodecPreferenceRank() {
        #expect(WebRTCSession.nativeScreenVideoCodecPreferenceRank("HEVC") < WebRTCSession.nativeScreenVideoCodecPreferenceRank("H264"))
        #expect(WebRTCSession.nativeScreenVideoCodecPreferenceRank("video/H265") < WebRTCSession.nativeScreenVideoCodecPreferenceRank("AVC"))
        #expect(WebRTCSession.nativeScreenVideoCodecPreferenceRank("H264") < WebRTCSession.nativeScreenVideoCodecPreferenceRank("VP8"))
        #expect(WebRTCSession.nativeScreenVideoCodecPreferenceRank("video/H265") < WebRTCSession.nativeScreenVideoCodecPreferenceRank("VP9"))
        #expect(WebRTCSession.nativeScreenVideoCodecPreferenceRank("H264") < WebRTCSession.nativeScreenVideoCodecPreferenceRank("video/AV1"))
        #expect(WebRTCSession.nativeScreenVideoCodecPreferenceRank("AVC") == 1)
        #expect(WebRTCSession.nativeScreenVideoCodecIsHardwarePreferred("video/H264"))
        #expect(WebRTCSession.nativeScreenVideoCodecIsHardwarePreferred("HEVC"))
        #expect(!WebRTCSession.nativeScreenVideoCodecIsHardwarePreferred("AV1"))
        #expect(WebRTCSession.nativeScreenVideoCodecIsRTX("rtx"))
        #expect(!WebRTCSession.nativeScreenVideoCodecIsRTX("red"))
    }

    @Test("SDP video summary is scoped to the video m-section")
    func testVideoSDPSummaryUsesVideoSectionOnly() {
        let sdp = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=sendrecv
        a=rtpmap:111 opus/48000/2
        a=fmtp:111 minptime=10;useinbandfec=1
        m=video 9 UDP/TLS/RTP/SAVPF 96 97
        a=mid:1
        a=sendonly
        a=rtpmap:96 VP8/90000
        a=rtpmap:97 H264/90000
        a=fmtp:97 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f;max-fs=3600;max-mbps=108000
        a=msid:screen stream
        a=ssrc:1234 cname:screen
        """
        let video = WebRTCSession.mediaSummaries(from: sdp).first { $0.kind == "video" }
        #expect(video?.port == "9")
        #expect(video?.mid == "1")
        #expect(video?.direction == "sendonly")
        #expect(video?.codecs == ["96:VP8/90000", "97:H264/90000"])
        #expect(video?.codecParameters == ["97:H264(profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1;max-fs=3600;max-mbps=108000)"])
        #expect(video?.hasMSID == true)
        #expect(video?.hasSSRC == true)
        #expect(video?.rejected == false)
    }

    @Test("SDP fmtp summary prioritizes H264 level and bitrate constraints")
    func testSDPFmtpSummaryPrioritizesH264LevelConstraints() {
        let summary = WebRTCSession.conciseSDPFmtpParameters(
            "foo=bar;packetization-mode=1;profile-level-id=42e01f;max-mbps=108000;level-asymmetry-allowed=1;max-fs=3600;x-google-max-bitrate=16000"
        )
        #expect(
            summary == "profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1;max-fs=3600;max-mbps=108000;x-google-max-bitrate=16000;foo=bar"
        )
    }

    @Test("extreme native H264 SDP constraints cover 2056x1329 at 60 fps")
    func testExtremeNativeH264SDPConstraintBudgetCoversTargetResolution() {
        #expect(WebRTCSession.nativeScreenVideoH264MacroblockFrameSize(width: 2_056, height: 1_329) == 10_836)
        #expect(WebRTCSession.extremeNativeScreenVideoH264MaxFS == 10_836)
        #expect(WebRTCSession.extremeNativeScreenVideoH264MaxMBPS == 650_160)
        #expect(WebRTCSession.extremeNativeScreenVideoH264LevelHex == "33")
        #expect(WebRTCSession.nativeScreenVideoEvenBackingDimension(1_329) == 1_330)
        #expect(WebRTCSession.nativeScreenVideoEvenBackingDimension(2_056) == 2_056)
    }

    @Test("extreme native H264 SDP constraints are gated to strict media modes")
    func testNativeH264SDPConstraintsAreStrictModeOnly() {
        #expect(WebRTCSession.nativeScreenVideoH264SDPConstraintsEnabled(environment: [:]) == false)
        #expect(
            WebRTCSession.nativeScreenVideoH264SDPConstraintsEnabled(
                environment: ["SKYBRIDGE_WEBRTC_EXTREME_MEDIA": "1"]
            )
        )
        #expect(
            WebRTCSession.nativeScreenVideoH264SDPConstraintsEnabled(
                environment: ["SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK": "1"]
            )
        )
    }

    @Test("H264 profile-level-id upgrade preserves profile and constraint bytes")
    func testH264ProfileLevelUpgradePreservesProfileBytes() {
        #expect(WebRTCSession.h264ProfileLevelID("42e01f", upgradedToAtLeast: "33") == "42e033")
        #expect(WebRTCSession.h264ProfileLevelID("640c1f", upgradedToAtLeast: "33") == "640c33")
        #expect(WebRTCSession.h264ProfileLevelID("640c34", upgradedToAtLeast: "33") == "640c34")
    }

    @Test("H264 fmtp upgrade raises level and macroblock caps without lowering existing caps")
    func testH264FmtpUpgradeRaisesNativeScreenCaps() {
        let upgraded = WebRTCSession.h264FmtpParametersWithNativeScreenLevelSupport(
            "profile-level-id=42e01f;level-asymmetry-allowed=0;packetization-mode=1;max-fs=3600;max-mbps=108000",
            requiredLevelHex: "33",
            maxFS: 10_836,
            maxMBPS: 650_160
        )
        #expect(upgraded == "profile-level-id=42e033;level-asymmetry-allowed=1;packetization-mode=1;max-fs=10836;max-mbps=650160")

        let alreadyHigher = WebRTCSession.h264FmtpParametersWithNativeScreenLevelSupport(
            "profile-level-id=640c34;max-fs=36864;max-mbps=983040",
            requiredLevelHex: "33",
            maxFS: 10_836,
            maxMBPS: 650_160
        )
        #expect(alreadyHigher.contains("profile-level-id=640c34"))
        #expect(alreadyHigher.contains("max-fs=36864"))
        #expect(alreadyHigher.contains("max-mbps=983040"))
    }

    @Test("SDP H264 upgrade is scoped to video H264 fmtp lines")
    func testSDPH264UpgradeOnlyTouchesVideoH264Fmtp() {
        let sdp = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=rtpmap:111 opus/48000/2
        a=fmtp:111 minptime=10;useinbandfec=1
        m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99
        a=mid:0
        a=rtpmap:96 H264/90000
        a=fmtp:96 profile-level-id=640c1f;level-asymmetry-allowed=1;packetization-mode=1
        a=rtpmap:97 rtx/90000
        a=fmtp:97 apt=96
        a=rtpmap:98 H264/90000
        a=fmtp:98 profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1
        a=rtpmap:99 VP8/90000
        a=fmtp:99 x-google-start-bitrate=8000
        """

        let upgraded = WebRTCSession.sdpWithNativeScreenH264LevelSupport(
            sdp,
            requiredLevelHex: "33",
            maxFS: 10_836,
            maxMBPS: 650_160
        )

        #expect(upgraded.contains("a=fmtp:111 minptime=10;useinbandfec=1"))
        #expect(upgraded.contains("a=fmtp:96 profile-level-id=640c33;level-asymmetry-allowed=1;packetization-mode=1;max-fs=10836;max-mbps=650160"))
        #expect(upgraded.contains("a=fmtp:97 apt=96"))
        #expect(upgraded.contains("a=fmtp:98 profile-level-id=42e033;level-asymmetry-allowed=1;packetization-mode=1;max-fs=10836;max-mbps=650160"))
        #expect(upgraded.contains("a=fmtp:99 x-google-start-bitrate=8000"))
    }
}
