import Testing
import Foundation
@testable import SkyBridgeCore

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

    @Test("screen chunked sender has a dedicated gate and no legacy length prefix")
    func screenChunkedSenderUsesDedicatedGateAndSBC2Telemetry() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift")
        let hostSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")

        #expect(source.contains("public func sendScreenChunkedPayloadAsync"))
        #expect(source.contains("encodeScreenChunkEnvelope"))
        #expect(source.contains("gate: outboundScreenFrameGate") || source.contains("outboundScreenFrameGate.run"))
        #expect(hostSource.contains("session.sendScreenChunkedPayloadAsync"))
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

        #expect(source.contains("session.sendScreenFramedPayloadAsync"))
        #expect(source.contains("screenChannelWireFormat"))
        #expect(source.contains("RemoteDesktopStreamConfiguration.screenChannelWireFormatSBC2ChunkedV1"))
        #expect(source.contains("let wireFormat = useChunkedScreenWire ? WebRTCSession.screenChunkedWireFormat : \"length-framed\""))
        #expect(source.contains("payloadMagic="))
        #expect(source.contains("framedBytes="))
        #expect(source.contains("chunkCount="))
        #expect(source.contains("session.screenDataChannelBufferedAmountBytes()"))
        #expect(source.contains("droppedBackpressure="))
    }

    @Test("native WebRTC screen sender exposes host-side RTP telemetry before nativeReady promotion")
    func nativeScreenVideoSenderExposesRTPTelemetry() throws {
        let sessionSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift")
        let hostSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")

        #expect(sessionSource.contains("NativeScreenVideoSendSnapshot"))
        #expect(sessionSource.contains("NativeScreenVideoRTCStats"))
        #expect(sessionSource.contains("outgoingNativeScreenVideoRTCStats"))
        #expect(sessionSource.contains("framesSent"))
        #expect(sessionSource.contains("bytesSent"))
        #expect(hostSource.contains("native WebRTC screen tx"))
        #expect(hostSource.contains("native-video-tx session="))
        #expect(hostSource.contains("NativeVideoHealthState"))
        #expect(hostSource.contains("failedNoRTP"))
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
        #expect(hostSource.contains("scaledImageForFallback"))
        #expect(hostSource.contains("evenDimension"))
        #expect(hostSource.contains("requiredStableDirectEncoderFrames"))
        #expect(hostSource.contains("nativeVideoHasRenderEvidence"))
        #expect(hostSource.contains("webRTCFallbackSCKLatestProducer"))
        #expect(hostSource.contains("webRTCFallbackCGDisplayProducer"))
        #expect(hostSource.contains("webRTCFallbackCGDisplayEmergencyProducer"))
        #expect(hostSource.contains("takeLatest(maxAge: Self.webRTCSCKLatestFallbackMaxAgeSeconds"))
        #expect(hostSource.contains("sck-latest-stale-or-missing"))
        #expect(hostSource.contains("stream-native-warmup-fallback-main"))
        #expect(hostSource.contains("CGDisplay emergency fallback active until fresh SCK frame or nativeReady"))
        #expect(hostSource.contains("nativeVideoTrackReady"))
    }

    @Test("WebRTC PQC media audio refreshes expired admission and relay leases")
    func realtimeMediaAudioRefreshesAdmissionAndRelayLeaseExpiry() throws {
        let clientSource = try readSource("Sources/SkyBridgeProtocolCore/RemoteConnection/SignalServerClient.swift")
        let hostSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let viewerSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift")
        let viewerWebRTCSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")

        #expect(clientSource.contains("public func refreshMediaAdmissionLease"))
        #expect(clientSource.contains("idempotencyKey"))
        #expect(hostSource.contains("webrtcMediaAdmissionLeaseExpiresAtBySessionId"))
        #expect(hostSource.contains("usableWebRTCMediaAdmissionLease"))
        #expect(hostSource.contains("isReusableMediaRelayEndpoint(expiresAt: directRealtimeAudioSenderRelayExpiresAt)"))
        #expect(hostSource.contains("isMediaAdmissionLeaseRefreshable"))
        #expect(hostSource.contains("media_admission_token_expired"))
        #expect(hostSource.contains("media_admission_token_lease_limit"))
        #expect(hostSource.contains("WebRTC PQC media audio config received"))
        #expect(hostSource.contains("reason=missingViewerEndpoint"))
        #expect(hostSource.contains("audioTxCaptured="))
        #expect(hostSource.contains("telemetryTotals()"))
        #expect(viewerSource.contains("isUsableRealtimeMediaAudioEndpoint(endpoint)"))
        #expect(viewerSource.contains("PQC media relay lease request"))
        #expect(viewerSource.contains("streamConfigIncludesAudio="))
        #expect(viewerSource.contains("audioRxRecv=0"))
        #expect(viewerSource.contains("relayEndpoint = try await crossNetwork.requestRealtimeMediaRelayEndpointForActiveSession()"))
        #expect(viewerWebRTCSource.contains("mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)"))
        #expect(viewerWebRTCSource.contains("/api/webrtc/session/refresh"))
        #expect(viewerWebRTCSource.contains("refreshWebRTCSessionAdmissionTokens"))
        #expect(viewerWebRTCSource.contains("serverStateMismatch"))
        #expect(viewerWebRTCSource.contains("refreshLeaseSuperseded"))
        #expect(viewerWebRTCSource.contains("media_admission_token_expired"))
        #expect(viewerWebRTCSource.contains("media_admission_token_lease_limit"))
    }

    @Test("WebRTC stream configuration ACK and nonblocking audio receiver startup are wired")
    func streamConfigurationAckAndNonblockingAudioReceiverStartupAreWired() throws {
        let hostSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let viewerSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift")
        let viewerWebRTCSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")

        #expect(hostSource.contains("case streamConfigurationAck"))
        #expect(hostSource.contains("RemoteDesktopStreamConfigurationAckWire"))
        #expect(hostSource.contains("streamConfigReceived session="))
        #expect(hostSource.contains("streamConfigurationAckSent session="))
        #expect(hostSource.contains("sessionReady session="))
        #expect(hostSource.contains("stream-deferred session="))

        #expect(viewerSource.contains("case streamConfigurationAck = \"streamConfigurationAck\""))
        #expect(viewerSource.contains("RemoteDesktopStreamConfigurationAckPayload"))
        #expect(viewerSource.contains("currentRealtimeMediaAudioBindingIfUsable()"))
        #expect(viewerSource.contains("ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mediaAudioMode)"))
        #expect(viewerSource.contains("receiverStartPending"))
        #expect(viewerSource.contains("receiverStartSlow"))
        #expect(viewerSource.contains("leaseReady"))
        #expect(viewerSource.contains("udpBindStarted"))
        #expect(viewerSource.contains("receiverStarted"))
        #expect(viewerSource.contains("receiverStartFailed"))
        #expect(viewerSource.contains("event=audioPresentConfigSent"))
        #expect(!viewerSource.contains("event=receiverStartTimeout"))
        #expect(viewerSource.contains("event=streamConfigSent"))
        #expect(viewerSource.contains("scheduleStreamConfigurationAckRetryIfNeeded(for: payload)"))
        #expect(viewerSource.contains("try await self.sendViewerStreamConfigurationPayload(payload, retryAttempt: index + 1)"))

        #expect(viewerWebRTCSource.contains("msg.type == .streamConfigurationAck"))
        #expect(viewerWebRTCSource.contains("handleStreamConfigurationAck(payload)"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
