#if DEBUG || SKYBRIDGE_TESTING
import Foundation
import Darwin
import SkyBridgeRealtimeMedia
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

@available(iOS 17.0, *)
struct LocalWebRTCSmokeBootstrap: Sendable, Equatable {
    struct RuntimeMaterial: Sendable, Equatable {
        let connectionCode: String
        let peerDeviceID: String
        let peerKEMPublicKeys: [KEMPublicKeyInfo]
    }

    struct Document: Decodable {
        struct PeerKEMPublicKey: Decodable {
            let suiteWireId: UInt16
            let publicKeyBase64: String
        }

        let schemaVersion: Int
        let runId: String
        let expiresAtEpochSeconds: Int64
        let accessToken: String
        let tenantId: String
        let connectionCode: String
        let peerDeviceId: String
        let peerKEMPublicKeys: [PeerKEMPublicKey]
    }

    enum ValidationError: LocalizedError, Equatable {
        case malformedDocument
        case unsupportedSchemaVersion
        case invalidRunID
        case runIDMismatch
        case expired
        case lifetimeTooLong
        case invalidAccessToken
        case invalidTenantID
        case tenantBindingFailed
        case invalidConnectionCode
        case invalidPeerDeviceID
        case invalidPeerKEMPublicKeys

        var errorDescription: String? {
            switch self {
            case .malformedDocument: return "bootstrap document is malformed"
            case .unsupportedSchemaVersion: return "bootstrap schema version is unsupported"
            case .invalidRunID: return "bootstrap run identifier is invalid"
            case .runIDMismatch: return "bootstrap run identifier does not match this launch"
            case .expired: return "bootstrap document has expired"
            case .lifetimeTooLong: return "bootstrap lifetime exceeds the allowed window"
            case .invalidAccessToken: return "bootstrap access token is invalid"
            case .invalidTenantID: return "bootstrap tenant identifier is invalid"
            case .tenantBindingFailed: return "bootstrap token and tenant identity do not match"
            case .invalidConnectionCode: return "bootstrap connection code is invalid"
            case .invalidPeerDeviceID: return "bootstrap peer device identifier is invalid"
            case .invalidPeerKEMPublicKeys: return "bootstrap peer KEM public keys are invalid"
            }
        }
    }

    enum ConsumptionError: LocalizedError, Equatable {
        case unableToOpen(Int32)
        case unableToReadMetadata(Int32)
        case unsafeFile
        case unableToRead(Int32)
        case changedWhileReading
        case unableToRemove(Int32)

        var errorDescription: String? {
            switch self {
            case .unableToOpen(let rawErrno):
                return "unable to open bootstrap file (errno \(rawErrno))"
            case .unableToReadMetadata(let rawErrno):
                return "unable to inspect bootstrap file (errno \(rawErrno))"
            case .unsafeFile:
                return "bootstrap file is not a private bounded regular file"
            case .unableToRead(let rawErrno):
                return "unable to read bootstrap file (errno \(rawErrno))"
            case .changedWhileReading:
                return "bootstrap file changed while it was consumed"
            case .unableToRemove(let rawErrno):
                return "unable to remove consumed bootstrap file (errno \(rawErrno))"
            }
        }
    }

    static let schemaVersion = 1
    static let maximumEncodedByteCount = 64 * 1_024
    static let maximumLifetimeSeconds: Int64 = 15 * 60

    let runID: String
    let accessToken: String
    let tenantID: String
    let connectionCode: String
    let peerDeviceID: String
    let peerKEMPublicKeys: [KEMPublicKeyInfo]

    var runtimeMaterial: RuntimeMaterial {
        RuntimeMaterial(
            connectionCode: connectionCode,
            peerDeviceID: peerDeviceID,
            peerKEMPublicKeys: peerKEMPublicKeys
        )
    }

    static func validate(
        data: Data,
        expectedRunID: String,
        now: Date = Date()
    ) throws -> LocalWebRTCSmokeBootstrap {
        guard !data.isEmpty, data.count <= maximumEncodedByteCount else {
            throw ValidationError.malformedDocument
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw ValidationError.malformedDocument
        }

        guard document.schemaVersion == schemaVersion else {
            throw ValidationError.unsupportedSchemaVersion
        }
        guard isSafeRunID(document.runId), isSafeRunID(expectedRunID) else {
            throw ValidationError.invalidRunID
        }
        guard document.runId == expectedRunID else {
            throw ValidationError.runIDMismatch
        }

        let nowEpochSeconds = Int64(now.timeIntervalSince1970)
        guard document.expiresAtEpochSeconds > nowEpochSeconds else {
            throw ValidationError.expired
        }
        guard document.expiresAtEpochSeconds - nowEpochSeconds <= maximumLifetimeSeconds else {
            throw ValidationError.lifetimeTooLong
        }

        guard isBoundedExactValue(document.accessToken, maximumUTF8Bytes: 16_384),
              document.accessToken.split(separator: ".", omittingEmptySubsequences: false).count == 3 else {
            throw ValidationError.invalidAccessToken
        }
        guard isBoundedExactValue(document.tenantId, maximumUTF8Bytes: 256) else {
            throw ValidationError.invalidTenantID
        }
        do {
            let identity = try SignalServerClientCompat.resolveAuthenticatedJWTIdentity(
                accessToken: document.accessToken
            )
            guard identity.effectiveTenantID == document.tenantId else {
                throw ValidationError.tenantBindingFailed
            }
        } catch {
            throw ValidationError.tenantBindingFailed
        }

        let normalizedConnectionCode = CrossNetworkWebRTCManager.sanitizeConnectionCodeInput(
            document.connectionCode
        )
        guard normalizedConnectionCode == document.connectionCode,
              CrossNetworkWebRTCManager.canSubmitConnectionCode(document.connectionCode) else {
            throw ValidationError.invalidConnectionCode
        }
        guard isBoundedExactValue(document.peerDeviceId, maximumUTF8Bytes: 256) else {
            throw ValidationError.invalidPeerDeviceID
        }
        guard (1...3).contains(document.peerKEMPublicKeys.count) else {
            throw ValidationError.invalidPeerKEMPublicKeys
        }

        var seenSuiteWireIDs = Set<UInt16>()
        let decodedKeys = try document.peerKEMPublicKeys.map { entry -> KEMPublicKeyInfo in
            guard seenSuiteWireIDs.insert(entry.suiteWireId).inserted,
                  let publicKey = Data(base64Encoded: entry.publicKeyBase64),
                  !publicKey.isEmpty else {
                throw ValidationError.invalidPeerKEMPublicKeys
            }
            return KEMPublicKeyInfo(suiteWireId: entry.suiteWireId, publicKey: publicKey)
        }
        let normalizedKeys = KEMPublicKeyInfo.normalizedValidKeys(decodedKeys)
        guard normalizedKeys.count == decodedKeys.count,
              normalizedKeys.contains(where: { $0.suiteWireId == 0x0001 }) else {
            throw ValidationError.invalidPeerKEMPublicKeys
        }

        return LocalWebRTCSmokeBootstrap(
            runID: document.runId,
            accessToken: document.accessToken,
            tenantID: document.tenantId,
            connectionCode: document.connectionCode,
            peerDeviceID: document.peerDeviceId,
            peerKEMPublicKeys: normalizedKeys
        )
    }

    private static func isSafeRunID(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isBoundedExactValue(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Bytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

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
    private static let bootstrapFileName = "skybridge-webrtc-smoke-bootstrap-v1.json"
    private var smokeAudioReceiver: IOSRealtimeMediaAudioReceiver?
    private var smokeAudioRelayTransport: SkyBridgeUDPRealtimeMediaTransport?
    private var smokeAudioRelayRenewalTask: Task<Void, Never>?
    private var smokeAudioRelayKeepaliveTask: Task<Void, Never>?
    private var smokeAudioDiagnosticsTask: Task<Void, Never>?
    private var smokeAudioRelayRolloverTask: Task<Void, Never>?
    private var smokeAudioRelayRolloverToken: UUID?

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

        let reporter: SmokeStatusReporter
        do {
            reporter = SmokeStatusReporter(statusURL: try statusURL())
            try reporter.reset()
        } catch {
            SkyBridgeLogger.shared.error("WebRTC smoke status sink initialization failed")
            return
        }
        await stopSmokeAudioReceiver()
        let bootstrapRuntime: LocalWebRTCSmokeBootstrap.RuntimeMaterial?
        do {
            if let bootstrap = try await consumeRealDeviceBootstrapIfRequired() {
                let keychainMode = environmentValue("SKYBRIDGE_SMOKE_KEYCHAIN_MODE")
                switch keychainMode {
                case "system":
                    try await AuthenticationManager.instance.validateSystemSmokeRemoteDesktopSession(
                        accessToken: bootstrap.accessToken,
                        effectiveTenantID: bootstrap.tenantID
                    )
                    reporter.append("keychain-proof platform=ios mode=system auth=existing-product-session productBundle=true")
                case "in-memory":
                    try await AuthenticationManager.instance.installSmokeRemoteDesktopSession(
                        accessToken: bootstrap.accessToken,
                        effectiveTenantID: bootstrap.tenantID
                    )
                    reporter.append("keychain-proof platform=ios mode=in-memory auth=diagnostic-bootstrap productBundle=true")
                default:
                    throw LocalWebRTCSmokeBootstrap.ValidationError.malformedDocument
                }
                reporter.append("bootstrap-consumed run=\(Self.sanitize(bootstrap.runID))")
                bootstrapRuntime = bootstrap.runtimeMaterial
            } else {
                bootstrapRuntime = nil
            }
        } catch {
            reporter.append("failed stage=bootstrap-consume error=\(Self.sanitize(error.localizedDescription))")
            return
        }
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
        await preseedPeerKEMTrustIfNeeded(bootstrap: bootstrapRuntime, reporter: reporter)

        let manager = CrossNetworkWebRTCManager.instance
        await manager.disconnect()

        switch role {
        case "ios-client":
            reporter.append("boot role=ios-client")
            let effectiveConnectCode = bootstrapRuntime?.connectionCode ?? connectCode
            guard !effectiveConnectCode.isEmpty else {
                reporter.append("failed stage=bootstrap error=missing_connect_code")
                return
            }
            reporter.append("connect code=<redacted>")
            await manager.connect(withCode: effectiveConnectCode)
        case "ios-host":
            reporter.append("boot role=ios-host")
            guard let code = await manager.generateConnectionCode(), !code.isEmpty else {
                reporter.append("failed stage=bootstrap error=missing_generated_code")
                return
            }
            do {
                try writeGeneratedCode(code)
            } catch {
                reporter.append("failed stage=bootstrap-code-write error=\(Self.sanitize(error.localizedDescription))")
                return
            }
            reporter.append("code=<redacted>")
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
            guard !Task.isCancelled else {
                reporter.append("cancelled stage=ios-smoke-loop")
                return
            }
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
                if case .handshakeComplete(let sessionId, _) = manager.readiness {
                    reporter.append("rekey session=\(sessionId) \(Self.sanitize(rekeyDescription))")
                } else {
                    reporter.append("rekey-pending \(Self.sanitize(rekeyDescription))")
                }
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
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        reporter.append("cancelled stage=ios-smoke-loop")
                        return
                    }
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

            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                reporter.append("cancelled stage=ios-smoke-loop")
                return
            }
        }

        reporter.append("failed stage=timeout error=ios_smoke_timeout")
    }

    private func consumeRealDeviceBootstrapIfRequired() async throws -> LocalWebRTCSmokeBootstrap? {
        guard let expectedRunID = environmentValue("SKYBRIDGE_SMOKE_BOOTSTRAP_RUN_ID") else {
            return nil
        }
        let environment = ProcessInfo.processInfo.environment
        let keychainMode = environment["SKYBRIDGE_SMOKE_KEYCHAIN_MODE"]
        guard role == "ios-client",
              keychainMode == "system" || keychainMode == "in-memory" else {
            throw LocalWebRTCSmokeBootstrap.ValidationError.malformedDocument
        }
        if keychainMode == "in-memory",
           environment["SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN"] != "1" {
            throw LocalWebRTCSmokeBootstrap.ValidationError.malformedDocument
        }
        if keychainMode == "system",
           environment["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1" {
            throw LocalWebRTCSmokeBootstrap.ValidationError.malformedDocument
        }
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw LocalWebRTCSmokeBootstrap.ValidationError.malformedDocument
        }
        let bootstrapURL = cachesURL.appendingPathComponent(Self.bootstrapFileName, isDirectory: false)
        let data = try await Self.consumeBootstrapFile(at: bootstrapURL)
        return try await Task.detached(priority: .userInitiated) {
            try LocalWebRTCSmokeBootstrap.validate(
                data: data,
                expectedRunID: expectedRunID
            )
        }.value
    }

    nonisolated static func consumeBootstrapFile(at url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                let rawErrno = errno
                if rawErrno == ELOOP {
                    throw LocalWebRTCSmokeBootstrap.ConsumptionError.unsafeFile
                }
                throw LocalWebRTCSmokeBootstrap.ConsumptionError.unableToOpen(rawErrno)
            }
            defer { _ = Darwin.close(descriptor) }

            var openedMetadata = stat()
            guard Darwin.fstat(descriptor, &openedMetadata) == 0 else {
                throw LocalWebRTCSmokeBootstrap.ConsumptionError.unableToReadMetadata(errno)
            }
            guard (openedMetadata.st_mode & S_IFMT) == S_IFREG,
                  (openedMetadata.st_mode & 0o077) == 0,
                  openedMetadata.st_uid == geteuid(),
                  openedMetadata.st_nlink == 1,
                  openedMetadata.st_size > 0,
                  openedMetadata.st_size <= LocalWebRTCSmokeBootstrap.maximumEncodedByteCount else {
                throw LocalWebRTCSmokeBootstrap.ConsumptionError.unsafeFile
            }

            let expectedByteCount = Int(openedMetadata.st_size)
            var data = Data(count: expectedByteCount)
            try data.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    throw LocalWebRTCSmokeBootstrap.ConsumptionError.changedWhileReading
                }
                var offset = 0
                while offset < expectedByteCount {
                    let bytesRead = Darwin.read(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        expectedByteCount - offset
                    )
                    if bytesRead > 0 {
                        offset += bytesRead
                    } else if bytesRead == -1, errno == EINTR {
                        continue
                    } else if bytesRead == 0 {
                        throw LocalWebRTCSmokeBootstrap.ConsumptionError.changedWhileReading
                    } else {
                        throw LocalWebRTCSmokeBootstrap.ConsumptionError.unableToRead(errno)
                    }
                }
            }

            var trailingByte: UInt8 = 0
            while true {
                let trailingRead = Darwin.read(descriptor, &trailingByte, 1)
                if trailingRead == 0 {
                    break
                }
                if trailingRead == -1, errno == EINTR {
                    continue
                }
                if trailingRead < 0 {
                    throw LocalWebRTCSmokeBootstrap.ConsumptionError.unableToRead(errno)
                }
                throw LocalWebRTCSmokeBootstrap.ConsumptionError.changedWhileReading
            }

            var finalMetadata = stat()
            guard Darwin.fstat(descriptor, &finalMetadata) == 0 else {
                throw LocalWebRTCSmokeBootstrap.ConsumptionError.unableToReadMetadata(errno)
            }
            guard finalMetadata.st_dev == openedMetadata.st_dev,
                  finalMetadata.st_ino == openedMetadata.st_ino,
                  finalMetadata.st_size == openedMetadata.st_size,
                  finalMetadata.st_mtimespec.tv_sec == openedMetadata.st_mtimespec.tv_sec,
                  finalMetadata.st_mtimespec.tv_nsec == openedMetadata.st_mtimespec.tv_nsec,
                  finalMetadata.st_ctimespec.tv_sec == openedMetadata.st_ctimespec.tv_sec,
                  finalMetadata.st_ctimespec.tv_nsec == openedMetadata.st_ctimespec.tv_nsec else {
                throw LocalWebRTCSmokeBootstrap.ConsumptionError.changedWhileReading
            }

            var pathMetadata = stat()
            guard Darwin.lstat(url.path, &pathMetadata) == 0,
                  (pathMetadata.st_mode & S_IFMT) == S_IFREG,
                  pathMetadata.st_dev == openedMetadata.st_dev,
                  pathMetadata.st_ino == openedMetadata.st_ino else {
                throw LocalWebRTCSmokeBootstrap.ConsumptionError.changedWhileReading
            }
            guard Darwin.unlink(url.path) == 0 else {
                throw LocalWebRTCSmokeBootstrap.ConsumptionError.unableToRemove(errno)
            }
            return data
        }.value
    }

    private func statusURL() throws -> URL {
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let basename = try SmokeArtifactBasename.resolve(
                environmentValue: ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"],
                defaultValue: "skybridge-smoke-status.log"
              ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return basename.url(in: cachesURL)
    }

    private func codeURL() throws -> URL {
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let basename = try SmokeArtifactBasename.resolve(
                environmentValue: ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_CODE_BASENAME"],
                defaultValue: "skybridge-smoke-code.txt"
              ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return basename.url(in: cachesURL)
    }

    private func writeGeneratedCode(_ code: String) throws {
        let codeURL = try codeURL()
        guard let data = code.appending("\n").data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writeProtectedData(data, to: codeURL)
    }

    private func pqcReportURL() throws -> URL? {
        guard let basename = try SmokeArtifactBasename.resolve(
            environmentValue: ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_PQC_REPORT_BASENAME"]
        ) else {
            return nil
        }
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return basename.url(in: cachesURL)
    }

    private func resolvedLocalDeviceID() async throws -> String {
        try await SkyBridgeiOSCore.shared.currentProtocolIdentitySnapshot().deviceId
    }

    private func decodeBase64Key(
        _ name: String,
        expectedByteCount: Int,
        reporter: SmokeStatusReporter
    ) -> Data? {
        guard let raw = environmentValue(name) else { return nil }
        guard raw.utf8.count <= 4_096,
              let data = Data(base64Encoded: raw),
              data.count == expectedByteCount else {
            reporter.append("failed stage=pqc-preseed error=invalid_key_encoding_or_length_\(name)")
            return nil
        }
        return data
    }

    private func preseedPeerKEMTrustIfNeeded(
        bootstrap: LocalWebRTCSmokeBootstrap.RuntimeMaterial?,
        reporter: SmokeStatusReporter
    ) async {
        if let bootstrap {
            await preseedPeerKEMTrust(
                peerDeviceID: bootstrap.peerDeviceID,
                keys: bootstrap.peerKEMPublicKeys,
                reporter: reporter
            )
            return
        }

        guard let peerDeviceID = environmentValue("SKYBRIDGE_PQC_PEER_DEVICE_ID") else {
            return
        }

        var keysBySuite: [UInt16: KEMPublicKeyInfo] = [:]
        if let xwing = decodeBase64Key(
            "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
            expectedByteCount: 1_216,
            reporter: reporter
        ) {
            keysBySuite[Self.xwingSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.xwingSuiteWireID,
                publicKey: xwing
            )
        }
        if let mlkem768 = decodeBase64Key(
            "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
            expectedByteCount: 1_184,
            reporter: reporter
        ) {
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
        if let mlkem768fs = decodeBase64Key(
            "SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64",
            expectedByteCount: 1_184,
            reporter: reporter
        ) {
            keysBySuite[Self.mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.mlkem768FSSuiteWireID,
                publicKey: mlkem768fs
            )
        }

        let keys = keysBySuite.keys.sorted().compactMap { keysBySuite[$0] }
        await preseedPeerKEMTrust(peerDeviceID: peerDeviceID, keys: keys, reporter: reporter)
    }

    private func preseedPeerKEMTrust(
        peerDeviceID: String,
        keys: [KEMPublicKeyInfo],
        reporter: SmokeStatusReporter
    ) async {
        guard !keys.isEmpty else {
            reporter.append("pqc-preseed skipped device=\(Self.sanitize(peerDeviceID)) reason=missing_keys")
            return
        }

        await KEMTrustStore.shared.upsert(deviceId: peerDeviceID, kemPublicKeys: keys)
        let suites = keys.map { String(format: "0x%04x", $0.suiteWireId) }.joined(separator: ",")
        reporter.append("pqc-preseed device=\(Self.sanitize(peerDeviceID)) suites=\(suites)")
    }

    private func exportLocalPQCIdentityIfNeeded(reporter: SmokeStatusReporter) async {
        struct LocalPQCReport: Encodable {
            struct PublicKeyEntry: Encodable {
                let suiteWireId: UInt16
                let publicKeyBase64: String
            }

            let deviceId: String
            let keys: [PublicKeyEntry]
        }

        do {
            guard let reportURL = try pqcReportURL() else { return }
            let keys = try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
            let report = LocalPQCReport(
                deviceId: try await resolvedLocalDeviceID(),
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

    private func stopSmokeAudioReceiver() async {
        CrossNetworkWebRTCManager.instance.smokeMediaHeartbeatDiagnosticsProvider = nil
        let diagnosticsTask = smokeAudioDiagnosticsTask
        let renewalTask = smokeAudioRelayRenewalTask
        let keepaliveTask = smokeAudioRelayKeepaliveTask
        let rolloverTask = smokeAudioRelayRolloverTask
        diagnosticsTask?.cancel()
        renewalTask?.cancel()
        keepaliveTask?.cancel()
        rolloverTask?.cancel()
        smokeAudioDiagnosticsTask = nil
        smokeAudioRelayRenewalTask = nil
        smokeAudioRelayKeepaliveTask = nil
        smokeAudioRelayRolloverTask = nil
        smokeAudioRelayRolloverToken = nil
        let transport = smokeAudioRelayTransport
        let receiver = smokeAudioReceiver
        smokeAudioRelayTransport = nil
        smokeAudioReceiver = nil

        await diagnosticsTask?.value
        await renewalTask?.value
        await keepaliveTask?.value
        await rolloverTask?.value
        await transport?.stop()
        await receiver?.close()
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
        SkyBridgeDiagnosticTrace.appendStatus(line)
        SkyBridgeDiagnosticTrace.append(line)
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
        SkyBridgeDiagnosticTrace.appendMediaDiagnostic(diagnosticFields)
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
                    SkyBridgeDiagnosticTrace.append(
                        "audio-rx relayKeepaliveSent session=\(sessionId) relay=\(relay)"
                    )
                    SkyBridgeDiagnosticTrace.appendMediaDiagnostic(
                        [
                            "kind": "audioRxRelayKeepaliveSent",
                            "session": sessionId,
                            "session_id": sessionId,
                            "relay": relay
                        ]
                    )
                } catch {
                    SkyBridgeDiagnosticTrace.append(
                        "audio-rx relayKeepaliveFailed session=\(sessionId) relay=\(relay) error=\(Self.sanitize(error.localizedDescription))"
                    )
                    SkyBridgeDiagnosticTrace.appendMediaDiagnostic(
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
        SkyBridgeDiagnosticTrace.append(
            "audio-rx relayLeaseRenewalScheduled session=\(sessionId) delayMs=\(delayMs) relay=\(endpoint.host):\(endpoint.port)"
        )
        SkyBridgeDiagnosticTrace.appendMediaDiagnostic(
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
        SkyBridgeDiagnosticTrace.append(
            "audio-rx relayLeaseRenewalStart session=\(sessionId) relay=\(currentEndpoint.host):\(currentEndpoint.port)"
        )
        manager.clearCachedRealtimeMediaRelayEndpointForActiveSession(reason: "smoke-lease-renewal")
        let endpointPair: CrossNetworkWebRTCManager.RealtimeMediaRelayEndpointPair?
        do {
            endpointPair = try await manager.requestRealtimeMediaRelayEndpointForActiveSession()
        } catch {
            guard !Task.isCancelled else { return }
            SkyBridgeDiagnosticTrace.append(
                "audio-rx relayLeaseRenewalFailed session=\(sessionId) stage=lease error=\(Self.sanitize(error.localizedDescription))"
            )
            scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: currentEndpoint)
            return
        }
        guard let endpointPair else {
            let reason = manager.mediaRelayLeaseDiagnosticForActiveSession() ?? "missing_endpoint"
            SkyBridgeDiagnosticTrace.append(
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
            SkyBridgeDiagnosticTrace.append(
                "audio-rx relayLeaseRenewalInPlaceStart session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port) bindPolicy=\(bindPolicyDescription)"
            )
            SkyBridgeDiagnosticTrace.appendMediaDiagnostic(
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
                SkyBridgeDiagnosticTrace.append(
                    "audio-rx relayLeaseRenewed session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port) mode=in-place bindPolicy=\(bindPolicyDescription)"
                )
                SkyBridgeDiagnosticTrace.appendMediaDiagnostic(
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
                guard !Task.isCancelled else { return }
                SkyBridgeDiagnosticTrace.append(
                    "audio-rx relayLeaseRenewalFallback session=\(sessionId) stage=in-place error=\(Self.sanitize(error.localizedDescription))"
                )
            }
        }
        if requiresStrictAudioRelayRenewal,
           sameRelayAddress {
            SkyBridgeDiagnosticTrace.append(
                "audio-rx relayLeaseRenewalRollover session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port) reason=strict-make-before-break"
            )
            SkyBridgeDiagnosticTrace.appendMediaDiagnostic(
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
                SkyBridgeDiagnosticTrace.append(
                    "audio-rx renewalTransportEvent session=\(sessionId) event=\(Self.sanitize(String(describing: event)))"
                )
            }
        )
        do {
            try await relayTransport.start()
        } catch {
            if Task.isCancelled {
                await relayTransport.stop()
                return
            }
            SkyBridgeDiagnosticTrace.append(
                "audio-rx relayLeaseRenewalFailed session=\(sessionId) stage=transport error=\(Self.sanitize(error.localizedDescription))"
            )
            scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: currentEndpoint)
            return
        }

        SkyBridgeDiagnosticTrace.append(
            "audio-rx relayLeaseRenewalRolloverReady session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port)"
        )
        SkyBridgeDiagnosticTrace.appendMediaDiagnostic(
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
            SkyBridgeDiagnosticTrace.append(
                "stream-config audioRenewalSent session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port)"
            )
        } catch {
            if Task.isCancelled {
                await relayTransport.stop()
                return
            }
            SkyBridgeDiagnosticTrace.append(
                "stream-config audioRenewalFailed session=\(sessionId) error=\(Self.sanitize(error.localizedDescription))"
            )
            await relayTransport.stop()
            scheduleSmokeAudioRelayRenewal(
                manager: manager,
                sessionId: sessionId,
                endpoint: currentEndpoint
            )
            return
        }
        await promoteSmokeAudioRelayTransportAfterNewTraffic(
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
    ) async {
        let previousTask = smokeAudioRelayRolloverTask
        previousTask?.cancel()
        await previousTask?.value

        let token = UUID()
        smokeAudioRelayRolloverToken = token
        smokeAudioRelayRolloverTask = Task { @MainActor [weak self] in
            guard let self else {
                await newTransport.stop()
                return
            }
            defer {
                if self.smokeAudioRelayRolloverToken == token {
                    self.smokeAudioRelayRolloverTask = nil
                    self.smokeAudioRelayRolloverToken = nil
                }
            }
            let deadline = Date().addingTimeInterval(Self.audioRelayRolloverTrafficObservationTimeout)
            var observedTotal: UInt64 = 0
            var observedTraffic = false
            while Date() < deadline {
                observedTotal = trafficCounter.snapshot()
                if observedTotal >= Self.audioRelayRolloverMinimumObservedPackets {
                    observedTraffic = true
                    break
                }
                do {
                    try await Task.sleep(
                        nanoseconds: Self.audioRelayRolloverTrafficObservationPollNanoseconds
                    )
                } catch {
                    await newTransport.stop()
                    return
                }
            }

            let relay = "\(newEndpoint.host):\(newEndpoint.port)"
            if observedTraffic {
                if self.smokeAudioRelayTransport === oldTransport {
                    self.smokeAudioRelayTransport = newTransport
                }
                SkyBridgeDiagnosticTrace.append(
                    "audio-rx relayLeaseRenewalTrafficObserved session=\(sessionId) relay=\(relay) newTransportRecvTotal=\(observedTotal)"
                )
                SkyBridgeDiagnosticTrace.appendMediaDiagnostic(
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
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.audioRelayRolloverGraceDelaySeconds * 1_000_000_000)
                    )
                } catch {
                    await oldTransport.stop()
                    return
                }
                if self.smokeAudioRelayTransport !== oldTransport {
                    await oldTransport.stop()
                }
            } else {
                SkyBridgeDiagnosticTrace.append(
                    "audio-rx relayLeaseRenewalTrafficMissing session=\(sessionId) relay=\(relay) newTransportRecvTotal=\(observedTotal)"
                )
                SkyBridgeDiagnosticTrace.appendMediaDiagnostic(
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
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    reporter.append("cancelled stage=audio-relay-bootstrap")
                    return false
                }
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
                        SkyBridgeDiagnosticTrace.append(
                            "audio-rx transportEvent session=\(sessionId) event=\(Self.sanitize(String(describing: event)))"
                        )
                    }
                )
                try await relayTransport.start()
                smokeAudioReceiver = receiver
                smokeAudioRelayTransport = relayTransport
                installSmokeMediaHeartbeatDiagnosticsProvider(manager: manager)
                startSmokeAudioDiagnosticsHeartbeat(receiver: receiver, sessionId: sessionId)
                SkyBridgeDiagnosticTrace.append(
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
#endif
