import Testing
import Foundation
import CoreVideo
@testable import SkyBridgeCore

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

@Suite("WebRTCSession Framed Payload Validation Tests")
struct WebRTCSessionFramedPayloadValidationTests {
    @Test("非法分块大小返回错误而不是触发 precondition 崩溃")
    func invalidChunkSizeThrowsTypedError() throws {
        do {
            _ = try WebRTCSession.validateFramedPayloadParameters(
                payloadByteCount: 128,
                maxChunkBytes: 0
            )
            Issue.record("应当抛出 invalidChunkSize 错误")
        } catch let error as WebRTCSession.WebRTCError {
            switch error {
            case .invalidChunkSize(let value):
                #expect(value == 0)
            default:
                Issue.record("错误类型不正确: \(error)")
            }
        } catch {
            Issue.record("未预期的错误类型: \(error)")
        }
    }

    @Test("超出 4 GiB 的分帧负载被拒绝而不是在长度转换时崩溃")
    func oversizedPayloadThrowsTypedError() throws {
        do {
            _ = try WebRTCSession.validateFramedPayloadParameters(
                payloadByteCount: Int(UInt32.max) + 1,
                maxChunkBytes: 8 * 1024
            )
            Issue.record("应当抛出 framedPayloadTooLarge 错误")
        } catch let error as WebRTCSession.WebRTCError {
            switch error {
            case .framedPayloadTooLarge(let value):
                #expect(value == Int(UInt32.max) + 1)
            default:
                Issue.record("错误类型不正确: \(error)")
            }
        } catch {
            Issue.record("未预期的错误类型: \(error)")
        }
    }

    @Test("screen framed sender keeps one length prefix on the dedicated screen channel")
    func screenFramedSenderUsesDedicatedGateAndSinglePrefix() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift")

        #expect(source.contains("public func sendScreenFramedPayloadAsync"))
        #expect(source.contains("preferScreenChannel: true"))
        #expect(source.contains("fallbackToControlChannel: false"))
        #expect(source.contains("gate: outboundScreenFrameGate"))
        #expect(source.contains("var framed = Data()"))
        #expect(source.contains("framed.append(Data(bytes: &length, count: 4))"))
        #expect(source.contains("framed.append(payload)"))
    }

    @Test("SBC2 screen chunks are self-describing DataChannel messages")
    func screenChunkedEnvelopeUsesSingleSBC2HeaderPerChunk() throws {
        let payload = Data((0..<32).map { UInt8($0) })
        let chunk = try WebRTCSession.encodeScreenChunkEnvelope(
            frameId: 9,
            chunkIndex: 1,
            chunkCount: 3,
            totalBytes: 96,
            chunkOffset: 32,
            payload: payload
        )

        #expect(chunk.count == WebRTCSession.screenChunkHeaderByteCount + payload.count)
        #expect(chunk.prefix(4) == Data([0x53, 0x42, 0x43, 0x32]))
        #expect(chunk[4] == 1)
        #expect(chunk[5] == 0)
        #expect(chunk.suffix(payload.count) == payload)
    }

    @Test("SBC2 sender rejects whole frames that cannot fit the current screen buffer budget")
    func screenChunkedWholeFrameBudgetRejectsBeforeChunkZero() throws {
        let accepted = try WebRTCSession.validateScreenChunkedWholeFrameBudget(
            payloadByteCount: 100,
            maxChunkBytes: WebRTCSession.screenChunkHeaderByteCount + 50,
            bufferedAmountBytes: 20,
            maxBufferedAmountBytes: 228
        )

        #expect(accepted.chunkCount == 2)
        #expect(accepted.framedBytes == 172)

        do {
            _ = try WebRTCSession.validateScreenChunkedWholeFrameBudget(
                payloadByteCount: 100,
                maxChunkBytes: WebRTCSession.screenChunkHeaderByteCount + 50,
                bufferedAmountBytes: 57,
                maxBufferedAmountBytes: 228
            )
            Issue.record("SBC2 sender must reject the whole frame before sending chunk 0")
        } catch let error as WebRTCSession.WebRTCError {
            switch error {
            case .screenFrameBudgetExceeded(
                let framedBytes,
                let bufferedAmount,
                let maxBufferedAmountBytes
            ):
                #expect(framedBytes == 172)
                #expect(bufferedAmount == 57)
                #expect(maxBufferedAmountBytes == 228)
            default:
                Issue.record("错误类型不正确: \(error)")
            }
        } catch {
            Issue.record("未预期的错误类型: \(error)")
        }
    }

    @Test("screen chunked sender has a dedicated gate and no legacy length prefix")
    func screenChunkedSenderUsesDedicatedGateAndSBC2Telemetry() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift")
        let hostSource = try [
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCCompat.swift"
        ].map { path in
            try readSource(path)
        }.joined(separator: "\n")

        #expect(source.contains("public func sendScreenChunkedPayloadAsync"))
        #expect(source.contains("validateScreenChunkedWholeFrameBudget"))
        #expect(source.contains("dataChannelBufferedAmountBytes(for: channel)"))
        #expect(source.contains("encodeScreenChunkEnvelope"))
        #expect(source.contains("gate: outboundScreenFrameGate") || source.contains("outboundScreenFrameGate.run"))
        #expect(hostSource.contains("session.sendScreenChunkedPayloadAsync"))
        #expect(hostSource.contains("chunkDropReason=whole-frame-budget"))
        #expect(hostSource.contains("catch WebRTCSession.WebRTCError.screenFrameBudgetExceeded"))
        #expect(hostSource.contains("wire=\\(wireFormat"))
        #expect(hostSource.contains("frameId="))
        #expect(hostSource.contains("sendLatencyMs="))
        #expect(hostSource.contains("screenBuffered="))
        #expect(hostSource.contains("chunkDropReason=stale-nonkey-backpressure"))
        #expect(hostSource.contains("sendPartialFailure=1"))
    }

    @Test("remote desktop WebRTC screen sender negotiates SBC2 and retains v1 fallback telemetry")
    func remoteDesktopScreenSenderNegotiatesSBC2AndRetainsV1FallbackTelemetry() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let policySource = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCScreenStreamingPolicy.swift")
        let hostAndPolicySource = source + "\n" + policySource

        #expect(source.contains("session.sendScreenFramedPayloadAsync"))
        #expect(source.contains("screenChannelWireFormat"))
        #expect(hostAndPolicySource.contains("RemoteDesktopStreamConfiguration.screenChannelWireFormatSBC2ChunkedV1"))
        #expect(source.contains("let wireFormat = useChunkedScreenWire ? WebRTCSession.screenChunkedWireFormat : \"length-framed\""))
        #expect(source.contains("payloadMagic="))
        #expect(source.contains("framedBytes="))
        #expect(source.contains("chunkCount="))
        #expect(source.contains("session.screenDataChannelBufferedAmountBytes()"))
        #expect(source.contains("droppedBackpressure="))
    }

    @Test("native WebRTC screen sender exposes host-side RTP telemetry before nativeReady promotion")
    func nativeScreenVideoSenderExposesRTPTelemetry() throws {
        let sessionSource = try macWebRTCSessionSource()
        let iosSessionSource = try iosWebRTCSessionSource()
        let hostSource = try [
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCCompat.swift"
        ].map { path in
            try readSource(path)
        }.joined(separator: "\n")
        let hostPolicySource = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCScreenStreamingPolicy.swift")
        let hostAndPolicySource = hostSource + "\n" + hostPolicySource

        #expect(sessionSource.contains("NativeScreenVideoSendSnapshot"))
        #expect(sessionSource.contains("NativeScreenVideoRTCStats"))
        #expect(sessionSource.contains("outgoingNativeScreenVideoRTCStats"))
        #expect(sessionSource.contains("refreshOutgoingScreenVideoSender"))
        #expect(sessionSource.contains("monotonicOutgoingNativeVideoTimestamp"))
        #expect(sessionSource.contains("WebRTCNativeScreenVideoValuePolicy"))
        #expect(sessionSource.contains("recommendedNativeScreenVideoBitrateBps"))
        #expect(sessionSource.contains("minimumExtremeNativeScreenVideoBitrateBps"))
        #expect(sessionSource.contains("recommendedBitrateBps"))
        #expect(sessionSource.contains("minimumExtremeBitrateBps"))
        #expect(sessionSource.contains("maxBitrateBps"))
        #expect(sessionSource.contains("minBitrateBps"))
        #expect(sessionSource.contains("degradationPreference"))
        #expect(sessionSource.contains("disallowQualityDegradation"))
        #expect(sessionSource.contains("lastFrameTimestampWasAdjusted"))
        #expect(sessionSource.contains("mediaSummaries(from sdp: String)"))
        #expect(sessionSource.contains("preferNativeScreenVideoCodecIfPossible"))
        #expect(sessionSource.contains("preferredHardwareVideoEncoderCodec"))
        #expect(sessionSource.contains("encoderFactory.preferredCodec"))
        #expect(sessionSource.contains("codecPreferenceRank"))
        #expect(sessionSource.contains("codecIsHardwarePreferred"))
        #expect(sessionSource.contains("codecPreferences(from codecs: [RTCRtpCodecCapability])"))
        #expect(sessionSource.contains("codecIsRTX"))
        #expect(sessionSource.contains("preferredPayloadType"))
        #expect(sessionSource.contains("parameters[\"apt\"]"))
        #expect(sessionSource.contains("shouldUpdateNativeVideoFormat"))
        #expect(sessionSource.contains("pushDiagnosticSyntheticNativeVideoFrame"))
        #expect(sessionSource.contains("com.skybridge.webrtc.synthetic-native-video"))
        #expect(sessionSource.contains("SKYBRIDGE_WEBRTC_DIAGNOSTIC_GENERIC_VIDEO_SOURCE"))
        #expect(sessionSource.contains("SKYBRIDGE_WEBRTC_DIAGNOSTIC_SKIP_VIDEO_SENDER_PARAMETERS"))
        #expect(sessionSource.contains("SKYBRIDGE_WEBRTC_DIAGNOSTIC_SKIP_ADAPT_OUTPUT_FORMAT"))
        #expect(sessionSource.contains("factory.videoSource()"))
        #expect(sessionSource.contains("sourceKind="))
        #expect(sessionSource.contains("pixelBufferPrimaryBytesPerRow"))
        #expect(sessionSource.contains("CVPixelBufferGetIOSurface"))
        #expect(sessionSource.contains("lastSubmittedFrameBytesPerRow"))
        #expect(sessionSource.contains("lastSubmittedFrameHasIOSurface"))
        #expect(sessionSource.contains("lastRawFrameTimestampDeltaNs"))
        #expect(sessionSource.contains("lastFrameTimestampDeltaNs"))
        #expect(sessionSource.contains("targetWidth"))
        #expect(sessionSource.contains("targetHeight"))
        #expect(sessionSource.contains("targetFPS"))
        #expect(sessionSource.contains("codecParameters"))
        #expect(sessionSource.contains("conciseSDPFmtpParameters"))
        #expect(sessionSource.contains("profile-level-id"))
        #expect(sessionSource.contains("max-fs"))
        #expect(sessionSource.contains("max-mbps"))
        #expect(sessionSource.contains("h264SDPConstraintsEnabled"))
        #expect(sessionSource.contains("sdpWithNativeScreenH264LevelSupport"))
        #expect(sessionSource.contains("h264ProfileLevelID"))
        #expect(sessionSource.contains("local-sdp-h264-extreme-constraints"))
        #expect(iosSessionSource.contains("nativeScreenVideoH264SDPConstraintsEnabled"))
        #expect(iosSessionSource.contains("sdpWithNativeScreenH264LevelSupport"))
        #expect(iosSessionSource.contains("h264ProfileLevelID"))
        #expect(iosSessionSource.contains("local-sdp-h264-extreme-constraints"))
        #expect(sessionSource.contains("WebRTCNativeScreenVideoFrameNormalizer"))
        #expect(sessionSource.contains("VTPixelTransferSessionTransferImage"))
        #expect(sessionSource.contains("evenBackingDimension"))
        #expect(sessionSource.contains("requiresVisibleCrop"))
        #expect(sessionSource.contains("adaptedWidth: Int32(normalizedFrame.visibleWidth)"))
        #expect(sessionSource.contains("adaptedHeight: Int32(normalizedFrame.visibleHeight)"))
        #expect(sessionSource.contains("cropWidth: Int32(normalizedFrame.visibleWidth)"))
        #expect(sessionSource.contains("cropHeight: Int32(normalizedFrame.visibleHeight)"))
        #expect(sessionSource.contains("codedSize="))
        #expect(sessionSource.contains("kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange"))
        #expect(sessionSource.contains("kCVPixelFormatType_420YpCbCr8BiPlanarFullRange"))
        #expect(sessionSource.contains("preferredNormalizedPixelFormat"))
        #expect(sessionSource.contains("cachedRawTimestampNs"))
        #expect(sessionSource.contains("rawTimestampNs: rawTimeStampNs"))
        #expect(sessionSource.contains("lastRawFramePixelFormat"))
        #expect(sessionSource.contains("lastSubmittedFramePixelFormat"))
        #expect(sessionSource.contains("normalizedFrames"))
        #expect(sessionSource.contains("rtpFlowing"))
        #expect(sessionSource.contains("framesSent"))
        #expect(sessionSource.contains("bytesSent"))
        #expect(sessionSource.contains("availableOutgoingBitrate"))
        #expect(sessionSource.contains("currentRoundTripTime"))
        #expect(sessionSource.contains("nackCount"))
        #expect(sessionSource.contains("pliCount"))
        #expect(sessionSource.contains("firCount"))
        #expect(hostSource.contains("native WebRTC screen tx"))
        #expect(hostSource.contains("native-video-tx session="))
        #expect(hostSource.contains("rawPixelFormat="))
        #expect(hostSource.contains("submittedPixelFormat="))
        #expect(hostSource.contains("native-video-frame-source"))
        #expect(hostSource.contains("SKYBRIDGE_WEBRTC_DIAGNOSTIC_SYNTHETIC_NATIVE_VIDEO"))
        #expect(hostSource.contains("SKYBRIDGE_WEBRTC_DIAGNOSTIC_SYNTHETIC_NATIVE_VIDEO_SIZE"))
        #expect(hostSource.contains("stream-diagnostic-synthetic-native-video-started"))
        #expect(hostSource.contains("diagnostic-synthetic-native-video-enabled"))
        #expect(hostSource.contains("bytesPerRow="))
        #expect(hostSource.contains("iosurface="))
        #expect(hostSource.contains("target="))
        #expect(hostSource.contains("rawDeltaNs="))
        #expect(hostSource.contains("timestampDeltaNs="))
        #expect(hostSource.contains("frameNormalized="))
        #expect(hostAndPolicySource.contains("NativeVideoHealthState"))
        #expect(hostAndPolicySource.contains("rawFramesSubmitted"))
        #expect(hostAndPolicySource.contains("rtpFlowing"))
        #expect(hostAndPolicySource.contains("rendered"))
        #expect(hostAndPolicySource.contains("degradedNoRTP"))
        #expect(hostSource.contains("native-video-sender-refresh session="))
        #expect(!hostSource.contains("action=recreate-transceiver"))
        #expect(hostSource.contains("native-video-rtp-flowing"))
        #expect(hostAndPolicySource.contains("failedNoRTP"))
        #expect(hostSource.contains("fallbackMode="))
        #expect(hostSource.contains("fallbackSentFPS="))
        #expect(hostSource.contains("fallbackProducer="))
        #expect(hostSource.contains("fallbackSignature="))
        #expect(hostSource.contains("fallbackLoopTickFPS="))
        #expect(hostSource.contains("directEncodedFPS="))
        #expect(hostSource.contains("sckLatestFPS="))
        #expect(hostSource.contains("sckLatestAgeMs="))
        #expect(hostSource.contains("cgdisplayCaptureMs="))
        #expect(hostSource.contains("jpegEncodeMs="))
        #expect(hostSource.contains("sendSuccessFPS="))
        #expect(hostSource.contains("dropReason="))
        #expect(hostSource.contains("screenSendMaxBufferedAmountBytes"))
        #expect(hostAndPolicySource.contains("requiredStableDirectEncoderFrames"))
        #expect(hostAndPolicySource.contains("nativeVideoHasRenderEvidence"))
        #expect(hostAndPolicySource.contains("webRTCFallbackSCKLatestProducer"))
        #expect(hostAndPolicySource.contains("webRTCFallbackCGDisplayProducer"))
        #expect(hostAndPolicySource.contains("webRTCFallbackCGDisplayEmergencyProducer"))
        #expect(hostSource.contains("captureStreamer.onEncodedFrame = nil"))
        #expect(hostSource.contains("degradedFallbackJPEGProfile: nil"))
        #expect(hostSource.contains("format=webrtc-native-video-waiting"))
        #expect(hostSource.contains("fallback=forbidden"))
        #expect(hostAndPolicySource.contains("remoteStreamConfiguration.allowsDegradedMediaFallbacks == false"))
        #expect(hostSource.contains("nativeVideoTrackReady"))
        #expect(hostAndPolicySource.contains("shouldDropNativeWarmupNonJPEGFallbackFrame"))
        #expect(hostSource.contains("dropReason=native-warmup-non-jpeg-fallback"))
        #expect(hostSource.contains("droppedNativeWarmupNonJPEG="))
        #expect(hostSource.contains("nativeCaptureCodec="))
        #expect(hostSource.contains("effectiveWebRTCNativeCaptureVideoFormats"))
        #expect(hostSource.contains("webRTCHardwareCompatibleCaptureSize"))
        #expect(hostSource.contains("native-video-quality-limited-"))
        #expect(hostSource.contains("native-video-bwe-stats-unavailable"))
        #expect(hostAndPolicySource.contains("native-video-unacceptable-codec-"))
        #expect(hostAndPolicySource.contains("native-video-software-encoder-"))
        #expect(hostSource.contains("native-video-target-bitrate-below-floor"))
        #expect(hostAndPolicySource.contains("nativeVideoNoRTPFailureGraceSeconds"))
        #expect(hostAndPolicySource.contains("strictNativeVideoNoRTPFailureReason"))
        #expect(hostAndPolicySource.contains("native-video-encoder-no-output"))
        #expect(hostSource.contains("bitrateFloorTolerance"))
        #expect(hostSource.contains("availableOutgoingBitrate="))
        #expect(hostSource.contains("remotePacketsLost="))
        #expect(hostSource.contains("nack="))
    }

    @Test("WebRTC PQC media audio refreshes expired admission and relay leases")
    func realtimeMediaAudioRefreshesAdmissionAndRelayLeaseExpiry() throws {
        let clientSource = try readSource("Sources/SkyBridgeProtocolCore/RemoteConnection/SignalServerClient.swift")
        let managerSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let mediaRelayPolicySource = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCMediaRelayPolicy.swift")
        let realtimeAudioCoordinatorSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCRealtimeAudioSenderCoordinator.swift")
        let hostSource = managerSource + "\n" + mediaRelayPolicySource + "\n" + realtimeAudioCoordinatorSource
        let viewerSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift")
        let viewerWebRTCSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")
        let viewerWebRTCRefreshSources = [
            viewerWebRTCSource,
            try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkSignalServerClient.swift"),
            try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCMediaAdmissionFailurePolicy.swift")
        ].joined(separator: "\n")
        let smokeHarnessSource = try [
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/SmokeSupport.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalWebRTCSmokeHarness.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/SmokeStatusReporter.swift"
        ].map { path in
            try readSource(path)
        }.joined(separator: "\n")

        #expect(clientSource.contains("public func refreshMediaAdmissionLease"))
        #expect(clientSource.contains("idempotencyKey"))
        #expect(hostSource.contains("webrtcMediaAdmissionLeaseExpiresAtBySessionId"))
        #expect(hostSource.contains("usableWebRTCMediaAdmissionLease"))
        #expect(hostSource.contains("isReusableMediaRelayEndpoint("))
        #expect(hostSource.contains("minimumRemainingTime: realtimeAudioRelayRenewalMargin"))
        #expect(hostSource.contains("requestWebRTCRealtimeAudioSenderEndpoint"))
        #expect(hostSource.contains("leaseSource=localRoleLease"))
        #expect(hostSource.contains("isMediaAdmissionLeaseRefreshable"))
        #expect(hostSource.contains("media_admission_token_expired"))
        #expect(hostSource.contains("media_admission_token_lease_limit"))
        #expect(hostSource.contains("let errorCode = mediaAdmissionLeaseErrorCode(from: body)"))
        #expect(hostSource.contains("status == 429 && errorCode == \"media_admission_token_lease_limit\""))
        #expect(hostSource.contains("WebRTC PQC media audio config received"))
        #expect(hostSource.contains("reason=missingViewerEndpoint"))
        #expect(hostSource.contains("audioTxCaptured="))
        #expect(hostSource.contains("diagnosticSnapshot()"))
        #expect(hostSource.contains("diagnosticSessionId: sessionID"))
        #expect(hostSource.contains("audioTxEncoded="))
        #expect(hostSource.contains("WebRTCMediaDiagnosticWriter.append"))
        #expect(viewerSource.contains("isUsableRealtimeMediaAudioEndpoint(endpoint)"))
        #expect(viewerSource.contains("max(RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioEndpointRenewalLeadTime, 35)"))
        #expect(viewerSource.contains("let strictRenewalRequiresRollover = strictCrossNetworkMediaValidationActive && sameRelayAddress"))
        #expect(viewerSource.contains("reason=strict-make-before-break"))
        #expect(viewerSource.contains("PQC media relay lease request"))
        #expect(viewerSource.contains("streamConfigIncludesAudio="))
        #expect(viewerSource.contains("audioRxRecv=0"))
        #expect(viewerSource.contains("relayEndpointPair = try await crossNetwork.requestRealtimeMediaRelayEndpointForActiveSession()"))
        #expect(smokeHarnessSource.contains("requiresStrictAudioRelayRenewal ? .requireAcknowledgement : .optimisticAfterSend"))
        #expect(smokeHarnessSource.contains("initialSmokeAudioRelayBindPolicy"))
        #expect(smokeHarnessSource.contains("max(Self.audioRelayRenewalLeadTime, 35)"))
        #expect(smokeHarnessSource.contains("let sameRelayAddress = skyBridgeIsSameRealtimeMediaRelayAddress(currentEndpoint, newEndpoint)"))
        #expect(smokeHarnessSource.contains("if !requiresStrictAudioRelayRenewal,\n           sameRelayAddress,"))
        #expect(smokeHarnessSource.contains("probable\": \"strict-make-before-break\""))
        #expect(viewerWebRTCRefreshSources.contains("mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)"))
        #expect(viewerWebRTCRefreshSources.contains("/api/webrtc/session/refresh"))
        #expect(viewerWebRTCRefreshSources.contains("refreshWebRTCSessionAdmissionTokens"))
        #expect(viewerWebRTCRefreshSources.contains("serverStateMismatch"))
        #expect(viewerWebRTCRefreshSources.contains("refreshLeaseSuperseded"))
        #expect(viewerWebRTCRefreshSources.contains("media_admission_token_expired"))
        #expect(viewerWebRTCRefreshSources.contains("media_admission_token_lease_limit"))
        #expect(viewerWebRTCRefreshSources.contains("let errorCode = mediaAdmissionLeaseErrorCode(from: body)"))
        #expect(viewerWebRTCRefreshSources.contains("status == 429 && errorCode == \"media_admission_token_lease_limit\""))
    }

    @Test("registry WebRTC smoke rejects compat JWTs before hitting Supabase")
    func registrySmokeRejectsUnsignedCompatJWTsBeforeRegistryRequests() throws {
        let scriptSource = try readSource("Scripts/run_local_webrtc_smoke.sh")
        let hostSource = try readSource("Sources/LocalWebRTCSmokeHost/main.swift")

        #expect(scriptSource.contains("SMOKE_AUTH_SESSION_SOURCE_FILE"))
        #expect(scriptSource.contains("SKYBRIDGE_SMOKE_AUTH_SESSION_FILE"))
        #expect(scriptSource.contains("jwt_validation_error(token, require_fresh)"))
        #expect(scriptSource.contains("JWT header alg=none is a compatibility smoke token"))
        #expect(scriptSource.contains("not a usable signed Supabase JWT for registry smoke"))
        #expect(scriptSource.contains("Registry media smoke requires a signed Supabase user JWT"))
        #expect(scriptSource.contains("SKYBRIDGE_ACCESS_TOKEN"))
        #expect(scriptSource.contains("SKYBRIDGE_REFRESH_TOKEN"))
        #expect(scriptSource.contains("minimum_lifetime_seconds = 300"))

        #expect(hostSource.contains("validateRegistrySmokeAuthSessionIfNeeded"))
        #expect(hostSource.contains("auth-registry-jwt-validated"))
        #expect(hostSource.contains("auth-registry-jwt-validation-skipped"))
        #expect(hostSource.contains("smokeAuthJWTValidationError"))
        #expect(hostSource.contains("JWT header alg=none is a compatibility smoke token"))
        #expect(hostSource.contains("registry smoke auth requires a usable signed Supabase JWT"))
    }

    @Test("WebRTC stream configuration ACK and nonblocking audio receiver startup are wired")
    func streamConfigurationAckAndNonblockingAudioReceiverStartupAreWired() throws {
        let hostSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let hostWireSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/RemoteDesktopWebRTCWire.swift")
        let viewerSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift")
        let viewerTypesSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopTypes.swift")
        let viewerWebRTCSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")

        #expect(hostWireSource.contains("case streamConfigurationAck"))
        #expect(hostWireSource.contains("RemoteDesktopStreamConfigurationAckWire"))
        #expect(hostSource.contains("streamConfigReceived session="))
        #expect(hostSource.contains("streamConfigurationAckSent session="))
        #expect(hostSource.contains("sessionReady session="))
        #expect(hostSource.contains("stream-deferred session="))

        #expect(viewerTypesSource.contains("case streamConfigurationAck = \"streamConfigurationAck\""))
        #expect(viewerTypesSource.contains("RemoteDesktopStreamConfigurationAckPayload"))
        #expect(viewerSource.contains("currentRealtimeMediaAudioBindingIfUsable()"))
        #expect(viewerSource.contains("ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mediaAudioMode)"))
        #expect(viewerSource.contains("receiverStartPending"))
        #expect(viewerSource.contains("receiverStartSlow"))
        #expect(viewerSource.contains("leaseReady"))
        #expect(viewerSource.contains("audioEndpointPrepared"))
        #expect(viewerSource.contains("udpConnectionStarted"))
        #expect(viewerSource.contains("relayBindSent"))
        #expect(viewerSource.contains("relayBindAckTimedOut"))
        #expect(viewerSource.contains("action=optimistic-grace"))
        #expect(viewerSource.contains("relayBindAckGraceTrafficObserved"))
        #expect(viewerSource.contains("relayBindAckTimedOutNoTraffic"))
        #expect(viewerSource.contains("relayBindAckTimedOutNoAuthenticatedTraffic"))
        #expect(viewerSource.contains("pushViewerStreamConfiguration(force: false, refreshStream: false)"))
        #expect(viewerSource.contains("strictRelayBindRequired ? .requireAcknowledgement : .optimisticAfterSend"))
        #expect(viewerSource.contains("relayBindPolicy: relayBindPolicy"))
        #expect(viewerSource.contains("receiverStarted"))
        #expect(viewerSource.contains("receiverStartFailed"))
        #expect(viewerSource.contains("event=audioPresentConfigSent"))
        #expect(!viewerSource.contains("event=receiverStartTimeout"))
        #expect(viewerSource.contains("event=streamConfigSent"))
        #expect(viewerSource.contains("scheduleStreamConfigurationAckRetryIfNeeded(for: payload)"))
        #expect(viewerSource.contains("try await self.sendViewerStreamConfigurationPayload(payload, retryAttempt: index + 1)"))

        #expect(viewerWebRTCSource.contains("msg.type == .streamConfigurationAck"))
        #expect(viewerWebRTCSource.contains("handleStreamConfigurationAck(payload)"))
        #expect(viewerWebRTCSource.contains("markRealtimeMediaRelayEndpointUnusableForActiveSession"))
    }

#if canImport(WebRTC)
    @Test("RTCCVPixelBuffer crop metadata preserves odd visible screen height")
    func rtccvPixelBufferCropPreservesOddVisibleHeight() throws {
        let width = 2_056
        let visibleHeight = 1_329
        let codedHeight = 1_330
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            codedHeight,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let unwrappedPixelBuffer = try #require(pixelBuffer)
        let rtcBuffer = RTCCVPixelBuffer(
            pixelBuffer: unwrappedPixelBuffer,
            adaptedWidth: Int32(width),
            adaptedHeight: Int32(visibleHeight),
            cropWidth: Int32(width),
            cropHeight: Int32(visibleHeight),
            cropX: 0,
            cropY: 0
        )
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: 1)

        #expect(CVPixelBufferGetHeight(unwrappedPixelBuffer) == codedHeight)
        #expect(rtcBuffer.width == Int32(width))
        #expect(rtcBuffer.height == Int32(visibleHeight))
        #expect(rtcBuffer.cropHeight == Int32(visibleHeight))
        #expect(frame.width == Int32(width))
        #expect(frame.height == Int32(visibleHeight))
    }
#endif

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func macWebRTCSessionSource() throws -> String {
        try [
            "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift",
            "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession+SDP.swift",
            "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession+StatePolicy.swift",
            "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCNativeScreenVideoValuePolicy.swift",
            "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCNativeScreenVideoFrameNormalizer.swift",
            "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSessionRuntimeSupport.swift"
        ].map { path in
            try readSource(path)
        }.joined(separator: "\n")
    }

    private func iosWebRTCSessionSource() throws -> String {
        try [
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession+SDP.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSessionLifecycleSupport.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSessionRemoteVideoStats.swift"
        ].map { path in
            try readSource(path)
        }.joined(separator: "\n")
    }
}
