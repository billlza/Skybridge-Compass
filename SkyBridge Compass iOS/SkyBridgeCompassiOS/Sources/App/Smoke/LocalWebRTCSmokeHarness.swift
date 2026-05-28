import Foundation
import SkyBridgeRealtimeMedia
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

@available(iOS 17.0, *)
@MainActor
final class LocalWebRTCSmokeHarness {
    static let shared = LocalWebRTCSmokeHarness()
    private static let xwingSuiteWireID: UInt16 = 0x0001
    private static let mlkem768SuiteWireID: UInt16 = 0x0101
    private static let mlkem768FSSuiteWireID: UInt16 = 0x0102
    private static let audioRelayRenewalLeadTime: TimeInterval = 12
    private static let audioRelayKeepaliveIntervalSeconds: TimeInterval = 10
    private static let audioRelayRolloverGraceDelaySeconds: TimeInterval = 15
    private static let audioRelayRolloverTrafficObservationTimeout: TimeInterval = 10
    private static let audioRelayRolloverTrafficObservationPollNanoseconds: UInt64 = 250_000_000
    private static let audioRelayRolloverMinimumObservedPackets: UInt64 = 4
    private static let audioDiagnosticsHeartbeatNanoseconds: UInt64 = 5_000_000_000
    private var smokeAudioReceiver: IOSRealtimeMediaAudioReceiver?
    private var smokeAudioRelayTransport: SkyBridgeUDPRealtimeMediaTransport?
    private var smokeAudioRelayRenewalTask: Task<Void, Never>?
    private var smokeAudioRelayKeepaliveTask: Task<Void, Never>?
    private var smokeAudioDiagnosticsTask: Task<Void, Never>?

    private var didStart = false

    private init() {}

    var isEnabled: Bool {
        role == "ios-client" || role == "ios-host"
    }

    private var role: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var connectCode: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_CONNECT_CODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var expectsPQCRekey: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"
    }

    private var expectsHandshakeOnly: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_HANDSHAKE_ONLY"] == "1"
    }

    private var requiresAudio: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_AUDIO"] == "1"
    }

    private var requiresNativeVideo: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_NATIVE_VIDEO"] == "1"
    }

    private var usesRealRemoteDesktopViewForNativeVideo: Bool {
        requiresNativeVideo
            && ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB"] == "1"
    }

    private var requiresExtremeMediaValidation: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXTREME_MEDIA"] == "1"
            || ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_EXTREME_MEDIA"] == "1"
            || ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK"] == "1"
    }

    private var requiresStrictAudioRelayRenewal: Bool {
        requiresAudio && requiresExtremeMediaValidation
    }

    private var initialSmokeAudioRelayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy {
        requiresStrictAudioRelayRenewal ? .requireAcknowledgement : .optimisticAfterSend
    }

    private var smokeAudioRelayRenewalBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy {
        requiresStrictAudioRelayRenewal ? .requireAcknowledgement : .optimisticAfterSend
    }

    private var requestedSmokeVideoSize: (width: Int, height: Int)? {
        guard let width = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_WIDTH"),
              let height = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_HEIGHT") else {
            return nil
        }
        return (width, height)
    }

    private var requestedSmokeTargetFrameRate: Int {
        guard let value = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_TARGET_FPS") else {
            return 30
        }
        return max(1, min(value, 120))
    }

    private func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func positiveEnvironmentInteger(_ name: String) -> Int? {
        guard let raw = environmentValue(name),
              let value = Int(raw),
              value > 0 else {
            return nil
        }
        return value
    }

    func startIfNeeded() async {
        guard isEnabled, !didStart else { return }
        didStart = true

        let reporter = SmokeStatusReporter(statusURL: statusURL())
        reporter.reset()
        stopSmokeAudioReceiver()
        PQCCryptoManager.instance.allowClassicFallbackForCompatibility = false
        if expectsPQCRekey {
            do {
                try await PQCCryptoManager.instance.initialize()
                reporter.append("pqc policy allowClassicBootstrap=0 targetRekey=X-Wing")
            } catch {
                reporter.append("failed stage=pqc-policy error=\(Self.sanitize(error.localizedDescription))")
                return
            }
        }
        await exportLocalPQCIdentityIfNeeded(reporter: reporter)
        await preseedPeerKEMTrustIfNeeded(reporter: reporter)

        let manager = CrossNetworkWebRTCManager.instance
        await manager.disconnect()

        switch role {
        case "ios-client":
            reporter.append("boot role=ios-client")
            guard !connectCode.isEmpty else {
                reporter.append("failed stage=bootstrap error=missing_connect_code")
                return
            }
            reporter.append("connect \(connectCode)")
            await manager.connect(withCode: connectCode)
        case "ios-host":
            reporter.append("boot role=ios-host")
            guard let code = await manager.generateConnectionCode(), !code.isEmpty else {
                reporter.append("failed stage=bootstrap error=missing_generated_code")
                return
            }
            writeGeneratedCode(code)
            reporter.append("code \(code)")
        default:
            reporter.append("failed stage=bootstrap error=unsupported_role_\(role)")
            return
        }

        let timeoutSeconds = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 90
        let holdAfterSuccessSeconds = max(
            0,
            Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS"] ?? "") ?? 0
        )
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastState = ""
        var lastReadiness = ""
        var lastRekeyEvent = ""
        var heartbeatStarted = false
        var streamConfigurationSent = false
        var reportedPreRekeyNativeFrame = false
        var reportedPreRekeyNativeReady = false
        var reportedPQCRekeyComplete = false
        var successReported = false
        var successHoldUntil: Date?

        func shouldFinishAfterSuccess(_ line: String) -> Bool {
            if !successReported {
                successReported = true
                reporter.append(line)
                if holdAfterSuccessSeconds > 0 {
                    successHoldUntil = Date().addingTimeInterval(holdAfterSuccessSeconds)
                    reporter.append("success-hold seconds=\(Int(holdAfterSuccessSeconds.rounded()))")
                }
            }
            return successHoldUntil == nil
        }

        while Date() < deadline || successHoldUntil != nil {
            if successHoldUntil == nil, Date() >= deadline {
                break
            }
            let stateDescription = String(describing: manager.state)
            if stateDescription != lastState {
                lastState = stateDescription
                reporter.append("state \(Self.sanitize(stateDescription))")
            }

            let readinessDescription = String(describing: manager.readiness)
            if readinessDescription != lastReadiness {
                lastReadiness = readinessDescription
                reporter.append("readiness \(Self.sanitize(readinessDescription))")
            }

            let rekeyDescription = manager.lastRekeyEvent ?? ""
            if rekeyDescription != lastRekeyEvent, !rekeyDescription.isEmpty {
                lastRekeyEvent = rekeyDescription
                reporter.append("rekey \(Self.sanitize(rekeyDescription))")
            }

            if case .failed(let message) = manager.state {
                reporter.append("failed stage=handshake error=\(Self.sanitize(message))")
                return
            }
            if let successHoldUntil, Date() >= successHoldUntil {
                reporter.append("success-hold-complete")
                return
            }

            if case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness,
               !heartbeatStarted {
                heartbeatStarted = true
                reporter.append(
                    "handshake session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite))"
                )
                if role == "ios-client" {
                    if usesRealRemoteDesktopViewForNativeVideo {
                        reporter.append(
                            "remote-view required=1 uiSurface=remoteDesktopView streamOwner=RemoteDesktopView"
                        )
                    } else if expectsHandshakeOnly {
                        reporter.append("stream-config skipped reason=handshakeOnly")
                    } else if !streamConfigurationSent {
                        streamConfigurationSent = await sendSmokeViewerStreamConfiguration(
                            manager: manager,
                            reporter: reporter,
                            sessionId: sessionId
                        )
                    }
                    if !usesRealRemoteDesktopViewForNativeVideo {
                        manager.startRemoteDesktopHeartbeat()
                    }
                }
            }

            if role == "ios-client" {
                let successDescriptor: (width: Int, height: Int, bytes: Int, transport: String)? = {
                    if let screenData = manager.lastScreenData, !requiresNativeVideo {
                        return (
                            width: screenData.width,
                            height: screenData.height,
                            bytes: screenData.imageData.count,
                            transport: "fallback-screen"
                        )
                    }

                    let nativeFrameSize = manager.remoteVideoTrackFrameSize
                    if manager.remoteVideoTrackHasRenderedFrame,
                       nativeFrameSize.width > 0,
                       nativeFrameSize.height > 0 {
                        return (
                            width: Int(nativeFrameSize.width),
                            height: Int(nativeFrameSize.height),
                            bytes: 0,
                            transport: "webrtc-native"
                        )
                    }

                    if manager.remoteVideoTrackReadyForPromotion,
                       nativeFrameSize.width > 0,
                       nativeFrameSize.height > 0 {
                        if requiresNativeVideo {
                            return nil
                        }
                        return (
                            width: Int(nativeFrameSize.width),
                            height: Int(nativeFrameSize.height),
                            bytes: 0,
                            transport: "webrtc-native-ready"
                        )
                    }

                    return nil
                }()

                if let successDescriptor,
                   case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                    let suiteLabel = Self.sanitize(negotiatedSuite)
                    let bootstrapSatisfied = !expectsPQCRekey
                        || suiteLabel.uppercased().contains("X-WING")
                    if bootstrapSatisfied {
                        if shouldFinishAfterSuccess(
                            "success session=\(sessionId) suite=\(suiteLabel) bootstrapRekey=\(expectsPQCRekey ? 1 : 0) frame=\(successDescriptor.width)x\(successDescriptor.height) bytes=\(successDescriptor.bytes) transport=\(successDescriptor.transport)"
                        ) {
                            return
                        }
                    }
                }

                if let screenData = manager.lastScreenData {
                    if !requiresNativeVideo {
                        if shouldFinishAfterSuccess(
                            "success frame=\(screenData.width)x\(screenData.height) bytes=\(screenData.imageData.count) transport=fallback-screen"
                        ) {
                            return
                        }
                    }
                    reporter.append(
                        "fallback-frame frame=\(screenData.width)x\(screenData.height) bytes=\(screenData.imageData.count) transport=fallback-screen"
                    )
                }

                let nativeFrameSize = manager.remoteVideoTrackFrameSize
                if manager.remoteVideoTrackHasRenderedFrame,
                   nativeFrameSize.width > 0,
                   nativeFrameSize.height > 0 {
                    if !expectsPQCRekey {
                        if shouldFinishAfterSuccess(
                            "success frame=\(Int(nativeFrameSize.width))x\(Int(nativeFrameSize.height)) bytes=0 transport=webrtc-native"
                        ) {
                            return
                        }
                    }
                    if !reportedPreRekeyNativeFrame {
                        reportedPreRekeyNativeFrame = true
                        reporter.append(
                            "native-frame-observed frame=\(Int(nativeFrameSize.width))x\(Int(nativeFrameSize.height)) bytes=0 transport=webrtc-native waitingForRekey=1"
                        )
                    }
                }

                if manager.remoteVideoTrackReadyForPromotion,
                   nativeFrameSize.width > 0,
                   nativeFrameSize.height > 0 {
                    if !expectsPQCRekey, !requiresNativeVideo {
                        if shouldFinishAfterSuccess(
                            "success frame=\(Int(nativeFrameSize.width))x\(Int(nativeFrameSize.height)) bytes=0 transport=webrtc-native-ready"
                        ) {
                            return
                        }
                    }
                    if !reportedPreRekeyNativeReady {
                        reportedPreRekeyNativeReady = true
                        reporter.append(
                            "native-frame-observed frame=\(Int(nativeFrameSize.width))x\(Int(nativeFrameSize.height)) bytes=0 transport=webrtc-native-ready waitingForRekey=1"
                        )
                    }
                }
            }

            if role == "ios-client",
               expectsPQCRekey,
               case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness,
               negotiatedSuite.caseInsensitiveCompare("X-Wing") == .orderedSame,
               let rekeyDescription = manager.lastRekeyEvent,
               rekeyDescription.caseInsensitiveCompare("complete suite=X-Wing") == .orderedSame {
                if requiresNativeVideo {
                    if !reportedPQCRekeyComplete {
                        reportedPQCRekeyComplete = true
                        reporter.append(
                            "rekey-complete session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) awaitingNativeVideo=1"
                        )
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if shouldFinishAfterSuccess(
                    "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) bootstrapRekey=1"
                ) {
                    return
                }
            }

            if role == "ios-client",
               expectsHandshakeOnly,
               case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                if shouldFinishAfterSuccess(
                    "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) handshakeOnly=1"
                ) {
                    return
                }
            }

            if role == "ios-host",
               case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                if expectsPQCRekey {
                    if let rekeyDescription = manager.lastRekeyEvent,
                       rekeyDescription.starts(with: "complete suite=") {
                        if shouldFinishAfterSuccess(
                            "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) rekey=\(Self.sanitize(rekeyDescription))"
                        ) {
                            return
                        }
                    }
                } else {
                    if shouldFinishAfterSuccess(
                        "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite))"
                    ) {
                        return
                    }
                }
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        reporter.append("failed stage=timeout error=ios_smoke_timeout")
    }

    private func statusURL() -> URL? {
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "skybridge-smoke-status.log"
        guard !fileName.isEmpty else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    private func codeURL() -> URL? {
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_CODE_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "skybridge-smoke-code.txt"
        guard !fileName.isEmpty else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    private func writeGeneratedCode(_ code: String) {
        guard let codeURL = codeURL() else { return }
        guard let data = code.appending("\n").data(using: .utf8) else { return }
        try? writeProtectedData(data, to: codeURL)
    }

    private func pqcReportURL() -> URL? {
        guard let fileName = environmentValue("SKYBRIDGE_SMOKE_PQC_REPORT_BASENAME") else {
            return nil
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    private func resolvedLocalDeviceID() -> String {
        ProtocolDeviceIdentity.stableDeviceId()
    }

    private func decodeBase64Key(
        _ name: String,
        reporter: SmokeStatusReporter
    ) -> Data? {
        guard let raw = environmentValue(name) else { return nil }
        guard let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
            reporter.append("failed stage=pqc-preseed error=invalid_base64_\(name)")
            return nil
        }
        return data
    }

    private func preseedPeerKEMTrustIfNeeded(reporter: SmokeStatusReporter) async {
        guard let peerDeviceID = environmentValue("SKYBRIDGE_PQC_PEER_DEVICE_ID") else {
            return
        }

        var keysBySuite: [UInt16: KEMPublicKeyInfo] = [:]
        if let xwing = decodeBase64Key("SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.xwingSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.xwingSuiteWireID,
                publicKey: xwing
            )
        }
        if let mlkem768 = decodeBase64Key("SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.mlkem768SuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.mlkem768SuiteWireID,
                publicKey: mlkem768
            )
            if environmentValue("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64") == nil {
                keysBySuite[Self.mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                    suiteWireId: Self.mlkem768FSSuiteWireID,
                    publicKey: mlkem768
                )
            }
        }
        if let mlkem768fs = decodeBase64Key("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.mlkem768FSSuiteWireID,
                publicKey: mlkem768fs
            )
        }

        let keys = keysBySuite.keys.sorted().compactMap { keysBySuite[$0] }
        guard !keys.isEmpty else {
            reporter.append("pqc-preseed skipped device=\(Self.sanitize(peerDeviceID)) reason=missing_keys")
            return
        }

        await KEMTrustStore.shared.upsert(deviceId: peerDeviceID, kemPublicKeys: keys)
        let suites = keys.map { String(format: "0x%04x", $0.suiteWireId) }.joined(separator: ",")
        reporter.append("pqc-preseed device=\(Self.sanitize(peerDeviceID)) suites=\(suites)")
    }

    private func exportLocalPQCIdentityIfNeeded(reporter: SmokeStatusReporter) async {
        guard let reportURL = pqcReportURL() else { return }

        struct LocalPQCReport: Encodable {
            struct PublicKeyEntry: Encodable {
                let suiteWireId: UInt16
                let publicKeyBase64: String
            }

            let deviceId: String
            let keys: [PublicKeyEntry]
        }

        do {
            let keys = try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
            let report = LocalPQCReport(
                deviceId: resolvedLocalDeviceID(),
                keys: keys.map { key in
                    LocalPQCReport.PublicKeyEntry(
                        suiteWireId: key.suiteWireId,
                        publicKeyBase64: key.publicKey.base64EncodedString()
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try writeProtectedData(data, to: reportURL)
            reporter.append(
                "pqc-report device=\(Self.sanitize(report.deviceId)) keys=\(report.keys.count) file=\(reportURL.lastPathComponent) reportJSONBase64=\(data.base64EncodedString())"
            )
        } catch {
            reporter.append("failed stage=pqc-report error=\(Self.sanitize(error.localizedDescription))")
        }
    }

    private func stopSmokeAudioReceiver() {
        CrossNetworkWebRTCManager.instance.smokeMediaHeartbeatDiagnosticsProvider = nil
        smokeAudioDiagnosticsTask?.cancel()
        smokeAudioDiagnosticsTask = nil
        smokeAudioRelayRenewalTask?.cancel()
        smokeAudioRelayRenewalTask = nil
        smokeAudioRelayKeepaliveTask?.cancel()
        smokeAudioRelayKeepaliveTask = nil
        if let transport = smokeAudioRelayTransport {
            Task(priority: .utility) {
                await transport.stop()
            }
        }
        if let receiver = smokeAudioReceiver {
            Task(priority: .utility) {
                await receiver.close()
            }
        }
        smokeAudioRelayTransport = nil
        smokeAudioReceiver = nil
    }

    private func installSmokeMediaHeartbeatDiagnosticsProvider(manager: CrossNetworkWebRTCManager) {
        manager.smokeMediaHeartbeatDiagnosticsProvider = { [weak self, weak manager] in
            guard let self, let manager else { return nil }
            let nativeSize = manager.remoteVideoTrackFrameSize
            let nativeWidth = nativeSize.width > 0 ? Int(nativeSize.width) : nil
            let nativeHeight = nativeSize.height > 0 ? Int(nativeSize.height) : nil
            let audio = await self.smokeAudioReceiver?.heartbeatDiagnosticSnapshot()
            return AppMessage.WebRTCMediaHeartbeatDiagnostics(
                nativeVideoRendered: manager.remoteVideoTrackHasRenderedFrame,
                nativeVideoWidth: nativeWidth,
                nativeVideoHeight: nativeHeight,
                audioRxDatagrams: audio?.datagramsSeen,
                audioRxRecv: audio?.received,
                audioRxDecoded: audio?.decoded,
                audioRxPlayed: audio?.played,
                audioRxRejected: audio?.rejected,
                audioRxAuthRejected: audio?.authRejected,
                audioRxSessionHashRejected: audio?.sessionHashRejected,
                audioRxReplayRejected: audio?.replayRejected,
                audioRxJitterEvicted: audio?.jitterEvicted,
                audioRxPlaybackDropped: audio?.playbackDropped,
                audioRenderedFrames: audio?.renderedFrames,
                audioUnderflow: audio?.underflowEvents,
                audioRebuffer: audio?.rebufferEvents,
                audioStartupSilenceFrames: audio?.startupSilenceFrames,
                audioEngineRunning: audio?.engineRunning
            )
        }
    }

    private func startSmokeAudioDiagnosticsHeartbeat(
        receiver: IOSRealtimeMediaAudioReceiver,
        sessionId: String
    ) {
        smokeAudioDiagnosticsTask?.cancel()
        smokeAudioDiagnosticsTask = Task { @MainActor [weak self, weak receiver] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.audioDiagnosticsHeartbeatNanoseconds)
                } catch {
                    return
                }
                guard let self, let receiver else { return }
                let snapshot = await receiver.heartbeatDiagnosticSnapshot()
                guard snapshot.datagramsSeen == 0,
                      snapshot.received == 0,
                      snapshot.decoded == 0,
                      snapshot.played == 0 else {
                    continue
                }
                self.appendSmokeAudioDiagnosticsSnapshot(
                    snapshot,
                    sessionId: sessionId,
                    source: "smoke-heartbeat"
                )
            }
        }
    }

    private func appendSmokeAudioDiagnosticsSnapshot(
        _ snapshot: IOSRealtimeMediaAudioReceiverHeartbeatSnapshot,
        sessionId: String,
        source: String
    ) {
        let renderedFrames = snapshot.renderedFrames.map(String.init) ?? "-"
        let underflow = snapshot.underflowEvents.map(String.init) ?? "-"
        let rebuffer = snapshot.rebufferEvents.map(String.init) ?? "-"
        let startupSilenceFrames = snapshot.startupSilenceFrames.map(String.init) ?? "-"
        let engineRunning = snapshot.engineRunning.map { $0 ? "true" : "false" } ?? "-"
        let probableSuffix = snapshot.datagramsSeen == 0
            ? " probable=audio-rx-zero-datagrams"
            : ""
        let line = "audio-rx session=\(sessionId) source=\(source) "
            + "audioRxDatagrams=\(snapshot.datagramsSeen) "
            + "audioRxRecv=\(snapshot.received) "
            + "audioRxDecoded=\(snapshot.decoded) "
            + "audioRxPlayed=\(snapshot.played) "
            + "recvTotal=\(snapshot.received) "
            + "decodeTotal=\(snapshot.decoded) "
            + "playTotal=\(snapshot.played) "
            + "rejected=\(snapshot.rejected) "
            + "authRejected=\(snapshot.authRejected) "
            + "sessionHashRejected=\(snapshot.sessionHashRejected) "
            + "replayRejected=\(snapshot.replayRejected) "
            + "jitterEvicted=\(snapshot.jitterEvicted) "
            + "playbackDrop=\(snapshot.playbackDropped) "
            + "renderedFrames=\(renderedFrames) "
            + "underflow=\(underflow) "
            + "rebuffer=\(rebuffer) "
            + "startupSilenceFrames=\(startupSilenceFrames) "
            + "engineRunning=\(engineRunning)"
            + probableSuffix
        SkyBridgeSmokeTraceWriter.appendStatus(line)
        SkyBridgeSmokeTraceWriter.append(line)
        var diagnosticFields: [String: Any] = [
            "kind": "audioRxHeartbeat",
            "session": sessionId,
            "session_id": sessionId,
            "source": source,
            "audioRxDatagrams": snapshot.datagramsSeen,
            "audioRxRecv": snapshot.received,
            "audioRxDecoded": snapshot.decoded,
            "audioRxPlayed": snapshot.played,
            "recvTotal": snapshot.received,
            "decodeTotal": snapshot.decoded,
            "playTotal": snapshot.played,
            "rejected": snapshot.rejected,
            "authRejected": snapshot.authRejected,
            "sessionHashRejected": snapshot.sessionHashRejected,
            "replayRejected": snapshot.replayRejected,
            "jitterEvicted": snapshot.jitterEvicted,
            "playbackDrop": snapshot.playbackDropped
        ]
        if let renderedFrames = snapshot.renderedFrames {
            diagnosticFields["renderedFrames"] = renderedFrames
        }
        if let underflowEvents = snapshot.underflowEvents {
            diagnosticFields["underflow"] = underflowEvents
        }
        if let rebufferEvents = snapshot.rebufferEvents {
            diagnosticFields["rebuffer"] = rebufferEvents
        }
        if let startupSilenceFrames = snapshot.startupSilenceFrames {
            diagnosticFields["startupSilenceFrames"] = startupSilenceFrames
        }
        if let engineRunning = snapshot.engineRunning {
            diagnosticFields["engineRunning"] = engineRunning
        }
        if snapshot.datagramsSeen == 0 {
            diagnosticFields["probable"] = "audio-rx-zero-datagrams"
        }
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(diagnosticFields)
    }

    private func startSmokeAudioRelayKeepalive(
        endpoint: SkyBridgeMediaEndpoint,
        transport: SkyBridgeUDPRealtimeMediaTransport,
        sessionId: String
    ) {
        smokeAudioRelayKeepaliveTask?.cancel()
        smokeAudioRelayKeepaliveTask = nil
        guard requiresAudio,
              let relayToken = endpoint.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayToken.isEmpty else {
            return
        }
        let relay = "\(endpoint.host):\(endpoint.port)"
        smokeAudioRelayKeepaliveTask = Task { @MainActor [weak self, weak transport] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.audioRelayKeepaliveIntervalSeconds * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard let self,
                      let transport,
                      self.smokeAudioRelayTransport === transport else {
                    return
                }
                do {
                    try await transport.refreshRelayBinding(relayToken)
                    SkyBridgeSmokeTraceWriter.append(
                        "audio-rx relayKeepaliveSent session=\(sessionId) relay=\(relay)"
                    )
                    SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                        [
                            "kind": "audioRxRelayKeepaliveSent",
                            "session": sessionId,
                            "session_id": sessionId,
                            "relay": relay
                        ]
                    )
                } catch {
                    SkyBridgeSmokeTraceWriter.append(
                        "audio-rx relayKeepaliveFailed session=\(sessionId) relay=\(relay) error=\(Self.sanitize(error.localizedDescription))"
                    )
                    SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                        [
                            "kind": "audioRxRelayKeepaliveFailed",
                            "session": sessionId,
                            "session_id": sessionId,
                            "relay": relay,
                            "error": Self.sanitize(error.localizedDescription)
                        ]
                    )
                }
            }
        }
    }

    private func makeSmokeViewerStreamConfigurationPayload(
        sessionId: String,
        mediaAudioEndpoint: SkyBridgeMediaEndpoint?
    ) -> RemoteDesktopStreamConfigurationPayload {
        let supportedFormats = RemoteDesktopManager.supportedRemoteVideoFormats()
            .filter { $0 != "jpeg" && $0 != "jpg" && $0 != "bgra" }
        let preferredCodec = supportedFormats.first {
            $0.caseInsensitiveCompare("hevc") == .orderedSame
                || $0.caseInsensitiveCompare("h264") == .orderedSame
        } ?? supportedFormats.first ?? "jpeg"
        let audioEnabled = requiresAudio
        let targetFrameRate = requestedSmokeTargetFrameRate
        let screenFrameTransport = "webrtc-native-main"
        let requestedVideoSize = requestedSmokeVideoSize
        return RemoteDesktopStreamConfigurationPayload(
            width: requestedVideoSize?.width,
            height: requestedVideoSize?.height,
            preferredCodec: preferredCodec,
            supportedVideoFormats: supportedFormats,
            qualityPreset: "fluid",
            adaptiveResolutionEnabled: requestedVideoSize == nil,
            targetFrameRate: targetFrameRate,
            keyFrameInterval: targetFrameRate,
            lowLatencyMode: requiresExtremeMediaValidation,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            damageTrackingEnabled: true,
            separateCursorChannelEnabled: true,
            interactionOverlayChannelEnabled: false,
            jitterBufferFrames: 2,
            screenFrameTransport: screenFrameTransport,
            screenDataChannelEnabled: false,
            nativeVideoTrackReady: false,
            nativeAudioTrackEnabled: false,
            audioRedirectionEnabled: audioEnabled,
            audioTransport: audioEnabled ? SkyBridgeRealtimeMediaConstants.audioTransportPQCv1 : "disabled",
            audioMode: "low-latency",
            mediaSessionId: sessionId,
            mediaAudioEndpoint: mediaAudioEndpoint,
            compatibilityAudioFallbackEnabled: false,
            preferredAudioEncoding: nil,
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            performanceValidationMode: requiresExtremeMediaValidation ? "extreme" : nil,
            mediaFallbackPolicy: "forbidden",
            streamRefreshToken: UInt64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    private func scheduleSmokeAudioRelayRenewal(
        manager: CrossNetworkWebRTCManager,
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint
    ) {
        smokeAudioRelayRenewalTask?.cancel()
        smokeAudioRelayRenewalTask = nil
        guard requiresAudio, let expiresAt = endpoint.expiresAt else { return }
        let nowSeconds = Date().timeIntervalSince1970
        let renewalLeadTime = requiresStrictAudioRelayRenewal
            ? max(Self.audioRelayRenewalLeadTime, 35)
            : Self.audioRelayRenewalLeadTime
        let delaySeconds = max(1, expiresAt - nowSeconds - renewalLeadTime)
        let delayMs = Int((delaySeconds * 1000).rounded())
        let expiresInMs = Int(((expiresAt - nowSeconds) * 1000).rounded())
        SkyBridgeSmokeTraceWriter.append(
            "audio-rx relayLeaseRenewalScheduled session=\(sessionId) delayMs=\(delayMs) relay=\(endpoint.host):\(endpoint.port)"
        )
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
            [
                "kind": "audioRxEndpointRenewalScheduled",
                "session": sessionId,
                "session_id": sessionId,
                "relay": "\(endpoint.host):\(endpoint.port)",
                "delayMs": delayMs,
                "expiresInMs": expiresInMs
            ]
        )
        smokeAudioRelayRenewalTask = Task { @MainActor [weak self, manager] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                return
            }
            await self?.renewSmokeAudioRelayEndpoint(
                manager: manager,
                sessionId: sessionId,
                currentEndpoint: endpoint
            )
        }
    }

    private func renewSmokeAudioRelayEndpoint(
        manager: CrossNetworkWebRTCManager,
        sessionId: String,
        currentEndpoint: SkyBridgeMediaEndpoint
    ) async {
        guard requiresAudio,
              let currentTransport = smokeAudioRelayTransport,
              let receiver = smokeAudioReceiver else {
            return
        }
        SkyBridgeSmokeTraceWriter.append(
            "audio-rx relayLeaseRenewalStart session=\(sessionId) relay=\(currentEndpoint.host):\(currentEndpoint.port)"
        )
        manager.clearCachedRealtimeMediaRelayEndpointForActiveSession(reason: "smoke-lease-renewal")
        let endpointPair: CrossNetworkWebRTCManager.RealtimeMediaRelayEndpointPair?
        do {
            endpointPair = try await manager.requestRealtimeMediaRelayEndpointForActiveSession()
        } catch {
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalFailed session=\(sessionId) stage=lease error=\(Self.sanitize(error.localizedDescription))"
            )
            scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: currentEndpoint)
            return
        }
        guard let endpointPair else {
            let reason = manager.mediaRelayLeaseDiagnosticForActiveSession() ?? "missing_endpoint"
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalFailed session=\(sessionId) stage=lease reason=\(Self.sanitize(reason))"
            )
            if reason.hasPrefix("missingSession") {
                return
            }
            scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: currentEndpoint)
            return
        }

        let newEndpoint = endpointPair.localEndpoint
        let sameRelayAddress = skyBridgeIsSameRealtimeMediaRelayAddress(currentEndpoint, newEndpoint)
        if !requiresStrictAudioRelayRenewal,
           sameRelayAddress,
           let relayToken = newEndpoint.relayToken,
           let currentTransport = smokeAudioRelayTransport {
            let bindPolicy = smokeAudioRelayRenewalBindPolicy
            let bindPolicyDescription: String
            switch bindPolicy {
            case .requireAcknowledgement:
                bindPolicyDescription = "require-ack"
            case .optimisticAfterSend:
                bindPolicyDescription = "optimistic"
            }
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalInPlaceStart session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port) bindPolicy=\(bindPolicyDescription)"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxEndpointRenewalInPlaceStart",
                    "session": sessionId,
                    "session_id": sessionId,
                    "relay": "\(newEndpoint.host):\(newEndpoint.port)",
                    "bindPolicy": bindPolicyDescription,
                    "probable": "same-relay-token-rebind"
                ]
            )
            do {
                try await currentTransport.rebindRelayToken(
                    relayToken,
                    relayBindPolicy: bindPolicy
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewed session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port) mode=in-place bindPolicy=\(bindPolicyDescription)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointRenewed",
                        "session": sessionId,
                        "session_id": sessionId,
                        "relay": "\(newEndpoint.host):\(newEndpoint.port)",
                        "relayTokenPresent": true,
                        "bindPolicy": bindPolicyDescription,
                        "probable": bindPolicy == .requireAcknowledgement
                            ? "smoke-relay-lease-renewed-in-place-ack"
                            : "smoke-relay-lease-renewed-in-place"
                    ]
                )
                scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: newEndpoint)
                startSmokeAudioRelayKeepalive(
                    endpoint: newEndpoint,
                    transport: currentTransport,
                    sessionId: sessionId
                )
                return
            } catch {
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewalFallback session=\(sessionId) stage=in-place error=\(Self.sanitize(error.localizedDescription))"
                )
            }
        }
        if requiresStrictAudioRelayRenewal,
           sameRelayAddress {
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalRollover session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port) reason=strict-make-before-break"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxEndpointRenewalRollover",
                    "session": sessionId,
                    "session_id": sessionId,
                    "relay": "\(newEndpoint.host):\(newEndpoint.port)",
                    "probable": "strict-make-before-break"
                ]
            )
        }
        let renewalTrafficCounter = SmokeAudioRelayTrafficCounter()
        let relayTransport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: newEndpoint,
            receiveHandler: { [receiver, renewalTrafficCounter] datagram in
                renewalTrafficCounter.increment()
                Task.detached(priority: .utility) {
                    await receiver.handle(datagram: datagram)
                }
            },
            relayBindPolicy: smokeAudioRelayRenewalBindPolicy,
            startEventHandler: { event in
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx renewalTransportEvent session=\(sessionId) event=\(Self.sanitize(String(describing: event)))"
                )
            }
        )
        do {
            try await relayTransport.start()
        } catch {
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalFailed session=\(sessionId) stage=transport error=\(Self.sanitize(error.localizedDescription))"
            )
            scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: currentEndpoint)
            return
        }

        SkyBridgeSmokeTraceWriter.append(
            "audio-rx relayLeaseRenewalRolloverReady session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port)"
        )
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
            [
                "kind": "audioRxEndpointRolloverReady",
                "session": sessionId,
                "session_id": sessionId,
                "relay": "\(newEndpoint.host):\(newEndpoint.port)",
                "relayTokenPresent": newEndpoint.relayToken != nil,
                "probable": "smoke-relay-rollover-transport-ready"
            ]
        )

        let payload = makeSmokeViewerStreamConfigurationPayload(
            sessionId: sessionId,
            mediaAudioEndpoint: newEndpoint
        )
        do {
            let encoded = try JSONEncoder().encode(payload)
            try await manager.sendRemoteDesktopMessage(
                RemoteMessage(type: .streamConfiguration, payload: encoded)
            )
            SkyBridgeSmokeTraceWriter.append(
                "stream-config audioRenewalSent session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port)"
            )
        } catch {
            SkyBridgeSmokeTraceWriter.append(
                "stream-config audioRenewalFailed session=\(sessionId) error=\(Self.sanitize(error.localizedDescription))"
            )
        }
        promoteSmokeAudioRelayTransportAfterNewTraffic(
            newTransport: relayTransport,
            oldTransport: currentTransport,
            trafficCounter: renewalTrafficCounter,
            manager: manager,
            sessionId: sessionId,
            currentEndpoint: currentEndpoint,
            newEndpoint: newEndpoint
        )
    }

    private func promoteSmokeAudioRelayTransportAfterNewTraffic(
        newTransport: SkyBridgeUDPRealtimeMediaTransport,
        oldTransport: SkyBridgeUDPRealtimeMediaTransport,
        trafficCounter: SmokeAudioRelayTrafficCounter,
        manager: CrossNetworkWebRTCManager,
        sessionId: String,
        currentEndpoint: SkyBridgeMediaEndpoint,
        newEndpoint: SkyBridgeMediaEndpoint
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.audioRelayRolloverTrafficObservationTimeout)
            var observedTotal: UInt64 = 0
            var observedTraffic = false
            while Date() < deadline {
                observedTotal = trafficCounter.snapshot()
                if observedTotal >= Self.audioRelayRolloverMinimumObservedPackets {
                    observedTraffic = true
                    break
                }
                try? await Task.sleep(nanoseconds: Self.audioRelayRolloverTrafficObservationPollNanoseconds)
            }

            let relay = "\(newEndpoint.host):\(newEndpoint.port)"
            if observedTraffic {
                if self.smokeAudioRelayTransport === oldTransport {
                    self.smokeAudioRelayTransport = newTransport
                }
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewalTrafficObserved session=\(sessionId) relay=\(relay) newTransportRecvTotal=\(observedTotal)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointRenewalTrafficObserved",
                        "session": sessionId,
                        "session_id": sessionId,
                        "relay": relay,
                        "newTransportRecvTotal": observedTotal
                    ]
                )
                self.scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: newEndpoint)
                self.startSmokeAudioRelayKeepalive(
                    endpoint: newEndpoint,
                    transport: newTransport,
                    sessionId: sessionId
                )
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.audioRelayRolloverGraceDelaySeconds * 1_000_000_000)
                )
                if self.smokeAudioRelayTransport !== oldTransport {
                    await oldTransport.stop()
                }
            } else {
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewalTrafficMissing session=\(sessionId) relay=\(relay) newTransportRecvTotal=\(observedTotal)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointRenewalTrafficMissing",
                        "session": sessionId,
                        "session_id": sessionId,
                        "relay": relay,
                        "newTransportRecvTotal": observedTotal,
                        "probable": "smoke-relay-renewal-no-post-renewal-rx"
                    ]
                )
                await newTransport.stop()
                self.scheduleSmokeAudioRelayRenewal(
                    manager: manager,
                    sessionId: sessionId,
                    endpoint: currentEndpoint
                )
            }
        }
    }

    private func sendSmokeViewerStreamConfiguration(
        manager: CrossNetworkWebRTCManager,
        reporter: SmokeStatusReporter,
        sessionId: String
    ) async -> Bool {
        let mediaAudioEndpoint: SkyBridgeMediaEndpoint?
        if requiresAudio {
            var endpointPair: CrossNetworkWebRTCManager.RealtimeMediaRelayEndpointPair?
            for _ in 0..<20 {
                do {
                    endpointPair = try await manager.requestRealtimeMediaRelayEndpointForActiveSession()
                } catch {
                    reporter.append("stream-config failed stage=audio-relay error=\(Self.sanitize(error.localizedDescription))")
                    return false
                }
                if endpointPair != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let endpointPair else {
                let reason = manager.mediaRelayLeaseDiagnosticForActiveSession() ?? "missing_endpoint"
                reporter.append("stream-config failed stage=audio-relay error=\(Self.sanitize(reason))")
                return false
            }
            let localEndpoint = endpointPair.localEndpoint
            guard let snapshot = manager.realtimeMediaKeySnapshot() else {
                reporter.append("stream-config failed stage=audio-relay error=missing_media_keys")
                return false
            }
            do {
                let receiver = try IOSRealtimeMediaAudioReceiver(snapshot: snapshot, mode: .lowLatency)
                let relayTransport = SkyBridgeUDPRealtimeMediaTransport(
                    endpoint: localEndpoint,
                    receiveHandler: { [receiver] datagram in
                        Task.detached(priority: .utility) {
                            await receiver.handle(datagram: datagram)
                        }
                    },
                    relayBindPolicy: initialSmokeAudioRelayBindPolicy,
                    startEventHandler: { event in
                        SkyBridgeSmokeTraceWriter.append(
                            "audio-rx transportEvent session=\(sessionId) event=\(Self.sanitize(String(describing: event)))"
                        )
                    }
                )
                try await relayTransport.start()
                smokeAudioReceiver = receiver
                smokeAudioRelayTransport = relayTransport
                installSmokeMediaHeartbeatDiagnosticsProvider(manager: manager)
                startSmokeAudioDiagnosticsHeartbeat(receiver: receiver, sessionId: sessionId)
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx receiverStarted session=\(sessionId) relay=\(localEndpoint.host):\(localEndpoint.port)"
                )
                startSmokeAudioRelayKeepalive(
                    endpoint: localEndpoint,
                    transport: relayTransport,
                    sessionId: sessionId
                )
                scheduleSmokeAudioRelayRenewal(
                    manager: manager,
                    sessionId: sessionId,
                    endpoint: localEndpoint
                )
            } catch {
                reporter.append("stream-config failed stage=audio-receiver error=\(Self.sanitize(error.localizedDescription))")
                return false
            }
            mediaAudioEndpoint = localEndpoint
        } else {
            mediaAudioEndpoint = nil
        }
        let payload = makeSmokeViewerStreamConfigurationPayload(
            sessionId: sessionId,
            mediaAudioEndpoint: mediaAudioEndpoint
        )

        do {
            let encoded = try JSONEncoder().encode(payload)
            try await manager.sendRemoteDesktopMessage(
                RemoteMessage(type: .streamConfiguration, payload: encoded)
            )
            reporter.append(
                "stream-config preferred=\(payload.preferredCodec ?? "auto") formats=\(payload.supportedVideoFormats.joined(separator: ",")) size=\(payload.width.map(String.init) ?? "auto")x\(payload.height.map(String.init) ?? "auto") adaptive=\(payload.adaptiveResolutionEnabled == true ? 1 : 0) fps=\(payload.targetFrameRate) lowLatency=\(requiresExtremeMediaValidation ? 1 : 0) audio=\(requiresAudio ? 1 : 0) relay=\(mediaAudioEndpoint == nil ? 0 : 1)"
            )
            return true
        } catch {
            reporter.append(
                "stream-config failed error=\(Self.sanitize(error.localizedDescription))"
            )
            return false
        }
    }

    private nonisolated static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}
