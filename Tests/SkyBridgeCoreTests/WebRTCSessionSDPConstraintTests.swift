import Foundation
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
        #expect(WebRTCNativeScreenVideoValuePolicy.encoderCodecPreferenceRank("HEVC") == 0)
        #expect(WebRTCNativeScreenVideoValuePolicy.encoderCodecPreferenceRank("H264") == 1)
        #expect(WebRTCNativeScreenVideoValuePolicy.encoderCodecPreferenceRank("video/AV1") == 10)
        #expect(WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("HEVC") < WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("H264"))
        #expect(WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("video/H265") < WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("AVC"))
        #expect(WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("H264") < WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("VP8"))
        #expect(WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("video/H265") < WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("VP9"))
        #expect(WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("H264") < WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("video/AV1"))
        #expect(WebRTCNativeScreenVideoValuePolicy.codecPreferenceRank("AVC") == 1)
        #expect(WebRTCNativeScreenVideoValuePolicy.codecIsHardwarePreferred("video/H264"))
        #expect(WebRTCNativeScreenVideoValuePolicy.codecIsHardwarePreferred("HEVC"))
        #expect(!WebRTCNativeScreenVideoValuePolicy.codecIsHardwarePreferred("AV1"))
        #expect(WebRTCNativeScreenVideoValuePolicy.codecIsRTX("rtx"))
        #expect(!WebRTCNativeScreenVideoValuePolicy.codecIsRTX("red"))
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
        let video = WebRTCSession.videoSDPMediaSummary(from: sdp)
        #expect(video.hasVideo)
        #expect(video.direction == "sendonly")
        #expect(
            video.description == "kind=video mid=1 port=9 rejected=false direction=sendonly codecs=96:VP8/90000,97:H264/90000 fmtp=97:H264(profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1;max-fs=3600;max-mbps=108000) msid=true ssrc=true"
        )
        #expect(!video.description.contains("opus"))
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
        #expect(WebRTCNativeScreenVideoValuePolicy.h264MacroblockFrameSize(width: 2_056, height: 1_329) == 10_836)
        #expect(WebRTCNativeScreenVideoValuePolicy.extremeH264MaxFS == 10_836)
        #expect(WebRTCNativeScreenVideoValuePolicy.extremeH264MaxMBPS == 650_160)
        #expect(WebRTCNativeScreenVideoValuePolicy.extremeH264LevelHex == "33")
        #expect(WebRTCNativeScreenVideoValuePolicy.evenBackingDimension(1_329) == 1_330)
        #expect(WebRTCNativeScreenVideoValuePolicy.evenBackingDimension(2_056) == 2_056)
    }

    @Test("extreme native H264 SDP constraints are gated to strict media modes")
    func testNativeH264SDPConstraintsAreStrictModeOnly() {
        #expect(WebRTCNativeScreenVideoValuePolicy.h264SDPConstraintsEnabled(environment: [:]) == false)
        #expect(
            WebRTCNativeScreenVideoValuePolicy.h264SDPConstraintsEnabled(
                environment: ["SKYBRIDGE_WEBRTC_EXTREME_MEDIA": "1"]
            )
        )
        #expect(
            WebRTCNativeScreenVideoValuePolicy.h264SDPConstraintsEnabled(
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

    @Test("remote SDP validator accepts bounded DTLS ICE datachannel SDP")
    func testRemoteSDPValidatorAcceptsBoundedDataChannelSDP() throws {
        let accepted = try WebRTCSession.validateRemoteSessionDescription(
            validRemoteDataChannelSDP(),
            expectedKind: "remote offer"
        )
        #expect(accepted.mediaSections == [
            WebRTCSession.ValidatedRemoteSDPMediaSection(index: 0, mid: "0")
        ])
    }

    @Test("remote SDP validator rejects missing DTLS fingerprint and ICE credentials")
    func testRemoteSDPValidatorRequiresFingerprintAndICECredentials() {
        assertSDPFailure("missing DTLS fingerprint") {
            try WebRTCSession.validateRemoteSessionDescription(
                validRemoteDataChannelSDP().replacingOccurrences(
                    of: "a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF\n",
                    with: ""
                ),
                expectedKind: "remote answer"
            )
        }
        assertSDPFailure("missing ICE credentials") {
            try WebRTCSession.validateRemoteSessionDescription(
                validRemoteDataChannelSDP().replacingOccurrences(
                    of: "a=ice-pwd:abcdefghijklmnopqrstuvwxyz\n",
                    with: ""
                ),
                expectedKind: "remote answer"
            )
        }
    }

    @Test("remote SDP validator rejects session-level candidates and duplicate mids")
    func testRemoteSDPValidatorRejectsSessionLevelCandidatesAndDuplicateMids() {
        assertSDPFailure("session-level ICE candidate") {
            try WebRTCSession.validateRemoteSessionDescription(
                validRemoteDataChannelSDP().replacingOccurrences(
                    of: "m=application",
                    with: "a=candidate:2 1 udp 2122260223 192.168.1.5 50000 typ host\nm=application"
                ),
                expectedKind: "remote offer"
            )
        }
        assertSDPFailure("duplicate a=mid") {
            try WebRTCSession.validateRemoteSessionDescription(
                validRemoteDataChannelSDP() + """
                m=audio 9 UDP/TLS/RTP/SAVPF 111
                a=mid:0
                a=rtpmap:111 opus/48000/2

                """,
                expectedKind: "remote offer"
            )
        }
    }

    @Test("remote ICE validator normalizes valid candidate and rejects malformed input")
    func testRemoteICECandidateValidator() throws {
        let valid = try WebRTCSession.validatedRemoteICECandidate(
            candidate: "a=candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        #expect(valid.candidate == "candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host")
        #expect(valid.sdpMid == "0")
        #expect(valid.sdpMLineIndex == 0)

        assertSDPFailure("missing sdpMLineIndex") {
            _ = try WebRTCSession.validatedRemoteICECandidate(
                candidate: "candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host",
                sdpMid: "0",
                sdpMLineIndex: nil
            )
        }
        assertSDPFailure("invalid port") {
            _ = try WebRTCSession.validatedRemoteICECandidate(
                candidate: "candidate:1 1 udp 2122260223 192.168.1.5 0 typ host",
                sdpMid: "0",
                sdpMLineIndex: 0
            )
        }
        assertSDPFailure("contains control characters") {
            _ = try WebRTCSession.validatedRemoteICECandidate(
                candidate: "candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host\ncandidate:2 1 udp 1 192.168.1.6 54322 typ host",
                sdpMid: "0",
                sdpMLineIndex: 0
            )
        }
    }

    @Test("remote ICE validator binds trickle candidates to accepted SDP media sections")
    func testRemoteICECandidateValidatorRequiresAcceptedSDPMediaBinding() throws {
        let accepted = try WebRTCSession.validateRemoteSessionDescription(
            validRemoteDataChannelSDP(),
            expectedKind: "remote offer"
        )
        let valid = try WebRTCSession.validatedRemoteICECandidate(
            candidate: "candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0,
            acceptedRemoteDescription: accepted
        )
        #expect(valid.sdpMid == "0")
        #expect(valid.sdpMLineIndex == 0)

        assertSDPFailure("sdpMid does not match accepted remote SDP m-line") {
            _ = try WebRTCSession.validatedRemoteICECandidate(
                candidate: "candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host",
                sdpMid: "9",
                sdpMLineIndex: 0,
                acceptedRemoteDescription: accepted
            )
        }
        assertSDPFailure("m-line index is not present in accepted remote SDP") {
            _ = try WebRTCSession.validatedRemoteICECandidate(
                candidate: "candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host",
                sdpMid: "0",
                sdpMLineIndex: 9,
                acceptedRemoteDescription: accepted
            )
        }
    }

    @Test("duplicate SDP branches do not replace accepted validation state")
    func testDuplicateSDPBranchesDoNotReplaceAcceptedValidationState() throws {
        let macSource = try repositorySource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift")
        let iosSource = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift")

        for source in [macSource, iosSource] {
            #expect(!source.contains("if self.hasRemoteDescription || self.isSettingRemoteDescription || pc.remoteDescription != nil"))
            #expect(!source.contains("""
            if self.hasRemoteDescription {
                                self.acceptedRemoteDescriptionValidation = remoteDescriptionValidation
                            }
            """))
            #expect(source.contains("acceptAppliedRemoteDescriptionFromPeerConnection"))
            #expect(source.contains("acceptedRemoteDescriptionValidation = try Self.validateRemoteSessionDescription(\n                appliedSDP,"))
        }
    }

    private func validRemoteDataChannelSDP() -> String {
        """
        v=0
        o=- 461173305123456789 2 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0
        a=msid-semantic: WMS
        m=application 9 UDP/DTLS/SCTP webrtc-datachannel
        c=IN IP4 0.0.0.0
        a=mid:0
        a=ice-ufrag:abcd
        a=ice-pwd:abcdefghijklmnopqrstuvwxyz
        a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF
        a=setup:actpass
        a=sctp-port:5000
        a=candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host

        """
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func assertSDPFailure(
        _ expectedMessageFragment: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected WebRTCError.sdpFailed containing \(expectedMessageFragment)")
        } catch WebRTCSession.WebRTCError.sdpFailed(let message) {
            #expect(message.contains(expectedMessageFragment))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
