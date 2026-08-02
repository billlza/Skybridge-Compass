import Foundation
import Darwin
import AppKit
import CryptoKit
import Dispatch
@_spi(SkyBridgeSmokeDiagnostics) import SkyBridgeCore
import SkyBridgeSmokeSupport
import SkyBridgeUI

@MainActor
private final class LocalLanInteropHostCoordinator {
    private let p2pDiscoveryService = P2PDiscoveryService.shared
    private let fileTransferManager = FileTransferManager.shared
    private let remoteControlManager = RemoteControlManager()
    private lazy var reporter = SmokeStatusReporter(statusURL: self.statusURL())
    private var monitorTask: Task<Void, Never>?

    private lazy var fileTransferListener = FileTransferListenerService(manager: fileTransferManager)
    private lazy var remoteControlServer = RemoteControlServer(manager: remoteControlManager)

    private var expectsFileTransferSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_FILE_TRANSFER"] == "1"
    }

    private var expectedHandshakeSuite: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "X-Wing"
    }

    private var fileTransferRunID: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "default"
    }

    func start() async throws {
        reporter.reset()
        do {
            if let localization = try validateEmbeddedRemoteControlLocalizationIfRequired() {
                reporter.append(
                    "remote-control-localization requiredKeys=\(localization.requiredKeyCount) "
                        + "embeddedRawKeys=0 managerRawKeys=0 source=embedded-signed-core "
                        + "locale=\(sanitize(localization.locale))"
                )
            }
        } catch {
            reporter.append(
                "failed stage=remote-control-localization reason=embedded-signed-core-invalid "
                    + "error=\(sanitize(error.localizedDescription))"
            )
            throw error
        }
        reporter.append("boot role=mac-host")
        reporter.append(
            "discovery-profile compatibilityMode="
                + (UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode") ? "1" : "0")
                + " source=volatile-argument-domain"
        )
        let identityStorage = DeviceIdentityKeyManager.usesEphemeralIdentityStoreForCurrentProcess
            ? "ephemeral-process"
            : "persistent-keychain"
        reporter.append("identity start storage=\(identityStorage)")
        do {
            let identityManager = DeviceIdentityKeyManager.shared
            _ = try await identityManager.getOrCreateIdentityKey()
            guard let residueStatus = await identityManager
                .lastLegacyResidueInspectionStatus() else {
                reporter.append(
                    "failed stage=identity code=legacy-residue-inspection-missing"
                )
                throw HostStartupError.identityUnavailable(
                    "legacy-residue-inspection-missing"
                )
            }
            let residueReason = residueStatus.failureReason?.rawValue ?? "none"
            let residueConflicts = residueStatus.hasConflicts.map { $0 ? "1" : "0" }
                ?? "unknown"
            reporter.append(
                "identity legacyResidueInspectionComplete="
                    + (residueStatus.inspectionComplete ? "1" : "0")
                    + " conflicts=\(residueConflicts) reason=\(residueReason)"
            )
            guard residueStatus.inspectionComplete else {
                let code = "legacy-residue-inspection-\(residueReason)"
                reporter.append("failed stage=identity code=\(code)")
                throw HostStartupError.identityUnavailable(code)
            }
        } catch {
            if let startupError = error as? HostStartupError {
                throw startupError
            }
            let code = Self.identityFailureCode(error)
            reporter.append("failed stage=identity code=\(code)")
            throw HostStartupError.identityUnavailable(code)
        }
        let protocolDeviceId = try await SelfIdentityProvider.shared
            .protocolIdentityDeviceId(allowCreate: true)
        reporter.append("identity ready device=\(sanitize(protocolDeviceId))")
        configureRemoteControlNoticeIdentity(protocolDeviceId: protocolDeviceId)
        guard await p2pDiscoveryService.waitUntilInitialized(timeout: 5.0) else {
            throw HostStartupError.initializationTimedOut("P2PDiscoveryService")
        }
        guard await fileTransferManager.waitUntilInitialized(timeout: 5.0) else {
            throw HostStartupError.initializationTimedOut("FileTransferManager")
        }

        let inboundDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/SkyBridgeInteropInbox", isDirectory: true)
        fileTransferManager.setReceiveBaseDirectory(inboundDirectory)

        try await fileTransferManager.start()
        try await fileTransferListener.start()
        try await remoteControlServer.start()
        let remoteControlPort = try remoteControlListenerPort()
        try await p2pDiscoveryService.ensureStartedAndScanning()
        try await exportLocalPQCIdentityIfRequested(reporter: reporter)
        let controlPort = try await waitForControlAdvertisementPort()

        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.SkyBridge.Compass/settings.json")

        emit("LocalLanInteropHost ready.")
        emit("Discovery/control: _skybridge._tcp on \(controlPort)")
        emit("File transfer: \(fileTransferListener.activePort ?? 8080)")
        emit("Remote desktop: \(remoteControlPort)")
        emit("Inbound files: \(inboundDirectory.path)")
        emit("Settings reference: \(settingsPath.path)")
        emit("Keep this process running while Azure relay and Windows client are active.")

        reporter.append("ready remote=_skybridge-rd._tcp port=\(remoteControlPort)")
        reporter.append("ready discovery=_skybridge._tcp port=\(controlPort)")
        monitorPresence()
    }

    private func validateEmbeddedRemoteControlLocalizationIfRequired() throws -> (
        requiredKeyCount: Int,
        locale: String
    )? {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_EMBEDDED_CORE_RESOURCES"] == "1" else {
            return nil
        }

        let requiredKeys = RemoteControlSecurityNoticeLocalizationContract.requiredKeys
        guard requiredKeys.count == 20, Set(requiredKeys).count == 20 else {
            throw HostStartupError.embeddedLocalizationInvalid("required-key-contract-invalid")
        }

        let bundleURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("SkyBridgeCompassApp_SkyBridgeCore.bundle", isDirectory: true)
        let bundleContentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourceRootURL = bundleContentsURL.appendingPathComponent("Resources", isDirectory: true)
        for url in [bundleURL, bundleContentsURL, resourceRootURL] {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw HostStartupError.embeddedLocalizationInvalid("resource-layout-invalid")
            }
        }
        guard let resourceBundle = Bundle(url: bundleURL),
              resourceBundle.bundleURL.standardizedFileURL == bundleURL.standardizedFileURL else {
            throw HostStartupError.embeddedLocalizationInvalid("resource-bundle-unavailable")
        }

        let rawKeys = requiredKeys.filter { key in
            resourceBundle.localizedString(forKey: key, value: key, table: nil) == key
        }
        guard rawKeys.isEmpty else {
            throw HostStartupError.embeddedLocalizationInvalid("embedded-raw-key-count-\(rawKeys.count)")
        }
        let managerRawKeys = requiredKeys.filter { key in
            LocalizationManager.shared.localizedString(key) == key
        }
        guard managerRawKeys.isEmpty else {
            throw HostStartupError.embeddedLocalizationInvalid("manager-raw-key-count-\(managerRawKeys.count)")
        }

        let locale = resourceBundle.preferredLocalizations.first
            ?? resourceBundle.developmentLocalization
            ?? "unknown"
        return (requiredKeys.count, locale)
    }

    private static func identityFailureCode(_ error: Error) -> String {
        guard let identityError = error as? DeviceIdentityKeyError else {
            return "identity-unavailable"
        }
        switch identityError {
        case .keyGenerationFailed:
            return "key-generation-failed"
        case .keyNotFound:
            return "key-not-found"
        case .keyAccessDenied:
            return "key-access-denied"
        case .secureEnclaveNotAvailable:
            return "secure-enclave-unavailable"
        case .invalidKeyData:
            return "invalid-key-data"
        case .incompleteKeyMaterial:
            return "incomplete-key-material"
        case .keychainError:
            return "keychain-error"
        case .signatureFailed:
            return "signature-failed"
        case .verificationFailed:
            return "verification-failed"
        case .keyRotationFailed:
            return "rotation-required"
        case .authorityConflict:
            return "authority-conflict"
        case .corruptIdentityAuthority:
            return "authority-corrupt"
        case .identityMigrationRequired:
            return "migration-required"
        case .identityMigrationRequiresRotationAndRepinning:
            return "migration-requires-rotation-and-repinning"
        }
    }

    private func configureRemoteControlNoticeIdentity(protocolDeviceId: String) {
        let environment = ProcessInfo.processInfo.environment
        let account = environment["SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let nebulaId = environment["SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        guard account != nil || nebulaId != nil else {
            if environment["SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE"] == "1" {
                reporter.append(
                    "failed stage=remote-control-notice phase=identity reason=missing-smoke-identity-env"
                )
            }
            RemoteControlSecurityNoticeCenter.shared.setLocalIdentityProvider(nil)
            return
        }

        let deviceName = Host.current().localizedName
        RemoteControlSecurityNoticeCenter.shared.setLocalIdentityProvider {
            RemoteControlSecurityIdentity(
                accountDisplayName: account,
                nebulaId: nebulaId,
                deviceId: protocolDeviceId,
                deviceName: deviceName
            )
        }
        _ = RemoteControlSecurityNoticeCenter.shared.localIdentitySnapshot()
        reporter.append(
            """
            remote-control-notice-identity account=\(sanitize(account ?? "missing")) \
            nebula=\(sanitize(nebulaId ?? "missing")) device=\(sanitize(protocolDeviceId))
            """
        )
    }

    private func waitForControlAdvertisementPort(timeout: TimeInterval = 20.0) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let snapshot = await ServiceAdvertiserCenter.shared.advertisementSnapshot(for: "_skybridge._tcp")
            if snapshot.isConnectable, let port = snapshot.port, port > 0 {
                return port
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline

        reporter.append("failed stage=mac-host phase=advertise_control reason=control_port_unavailable")
        throw HostStartupError.advertisementPortUnavailable("_skybridge._tcp")
    }

    private func remoteControlListenerPort() throws -> UInt16 {
        guard let port = remoteControlServer.activePort, port > 0 else {
            reporter.append("failed stage=mac-host phase=remote_control_listener reason=remote_port_unavailable")
            throw HostStartupError.advertisementPortUnavailable("_skybridge-rd._tcp")
        }
        return port
    }

    private func emit(_ line: String) {
        let data = Data((line + "\n").utf8)
        FileHandle.standardOutput.write(data)
    }

    private func monitorPresence() {
        monitorTask?.cancel()
        let expectsPQCRekey = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"

        monitorTask = Task { @MainActor in
            var lastSuite = ""
            var lastRekey = ""
            var sawClassicHandshake = false
            var sawRekey = false
            var inferredRekeyLogged = false
            var suiteStableSince: Date?
            let expectedNormalizedSuite = expectedHandshakeSuite.uppercased()

            while !Task.isCancelled {
                let newestConnection = ConnectionPresenceService.shared.activeConnections
                    .sorted { $0.connectedAt > $1.connectedAt }
                    .first

                if let newestConnection {
                    let suite = newestConnection.suite.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !suite.isEmpty, suite != lastSuite {
                        lastSuite = suite
                        suiteStableSince = Date()
                        reporter.append(
                            "suite peer=\(sanitize(newestConnection.id)) suite=\(sanitize(suite))"
                        )

                        let normalizedSuite = suite.uppercased()
                        if normalizedSuite.contains("X25519") {
                            sawClassicHandshake = true
                        } else if normalizedSuite == "X-WING" {
                            if expectsPQCRekey && sawClassicHandshake && !sawRekey && !inferredRekeyLogged {
                                sawRekey = true
                                inferredRekeyLogged = true
                                reporter.append("rekey inferred X25519-Ed25519 -> X-Wing")
                            }
                        }
                    }
                }

                let newestRekey = ConnectionPresenceService.shared.rekeyStatusByPeerId.values
                    .sorted { $0.startedAt > $1.startedAt }
                    .first
                if let newestRekey {
                    let description = "\(newestRekey.fromSuite)->\(newestRekey.toSuite)"
                    if description != lastRekey {
                        lastRekey = description
                        sawRekey = true
                        reporter.append(
                            "rekey \(sanitize(newestRekey.fromSuite)) -> \(sanitize(newestRekey.toSuite))"
                        )
                    }
                } else if !lastRekey.isEmpty {
                    lastRekey = ""
                    reporter.append("rekey cleared")
                }

                if let newestConnection {
                    let normalizedSuite = newestConnection.suite.uppercased()
                    if expectsPQCRekey {
                        if sawClassicHandshake && sawRekey && normalizedSuite == "X-WING" {
                            if expectsFileTransferSmoke {
                                do {
                                    try await performBidirectionalFileTransferSmoke(reporter: reporter)
                                    reporter.append(
                                        "success peer=\(sanitize(newestConnection.id)) suite=X-Wing bootstrapRekey=1 fileTransfer=1"
                                    )
                                } catch {
                                    reporter.append(fileTransferFailureLine(for: error))
                                }
                            } else {
                                reporter.append(
                                    "success peer=\(sanitize(newestConnection.id)) suite=X-Wing bootstrapRekey=1"
                                )
                            }
                            return
                        }
                    } else if normalizedSuite == expectedNormalizedSuite,
                              !sawRekey,
                              let stableSince = suiteStableSince,
                              Date().timeIntervalSince(stableSince) >= 1.0 {
                        if expectsFileTransferSmoke {
                            do {
                                try await performBidirectionalFileTransferSmoke(reporter: reporter)
                                reporter.append(
                                    "success peer=\(sanitize(newestConnection.id)) suite=\(sanitize(newestConnection.suite)) handshakeOnly=1 fileTransfer=1"
                                )
                            } catch {
                                reporter.append(fileTransferFailureLine(for: error))
                            }
                        } else {
                            reporter.append(
                                "success peer=\(sanitize(newestConnection.id)) suite=\(sanitize(newestConnection.suite)) handshakeOnly=1"
                            )
                        }
                        return
                    }
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func exportLocalPQCIdentityIfRequested(
        reporter: SmokeStatusReporter
    ) async throws {
        guard let reportURL = pqcReportURL() else { return }

        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        let deviceId = try await DeviceIdentityKeyManager.shared.getDeviceId()
        let keys = try await DeviceIdentityKeyManager.shared.pairingIdentityKEMPublicKeys(
            using: provider
        )
        let report = LocalPQCReport(
            deviceId: deviceId,
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
            "pqc-report device=\(sanitize(deviceId)) keys=\(report.keys.count) file=\(sanitize(reportURL.lastPathComponent))"
        )
    }

    private func statusURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private func pqcReportURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_PQC_REPORT_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private func sanitizePhase(_ value: String) -> String {
        let sanitized = value.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." {
                return character
            }
            return "_"
        }
        let phase = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return phase.isEmpty ? "unknown" : phase
    }

    private func fileTransferFailureLine(for error: Error) -> String {
        let phase = fileTransferFailurePhase(for: error)
        let category = fileTransferFailureCategory(for: error, phase: phase)
        return "failed stage=file-transfer phase=\(sanitizePhase(phase)) category=\(sanitizePhase(category)) error=\(sanitize(error.localizedDescription))"
    }

    private func fileTransferFailureCategory(for error: Error, phase: String) -> String {
        let normalizedPhase = phase.lowercased()
        if error is P2PDiscoveryError {
            return "discovery"
        }
        if let transferError = error as? FileTransferError {
            switch transferError {
            case .secureSessionRequired,
                 .securityThreatDetected,
                 .securityScanReviewRequired,
                 .securityScanIncomplete,
                 .receiverNotConfirmed,
                 .receiverRejected:
                return "auth_policy"
            case .invalidHeader,
                 .inboundInvalidInitialHeader,
                 .integrityCheckFailed,
                 .transferCancelled,
                 .connectionClosed,
                 .inboundConnectionClosedBeforeMetadata,
                 .fileNotFound,
                 .timeout,
                 .receiptWaitFailed,
                 .partialFileCleanupFailed,
                 .sourceFileCloseFailed,
                 .committedFileReleaseFailed,
                 .resumeStatePersistenceFailed,
                 .resumeStateCleanupFailed,
                 .automaticResumeFailed,
                 .capacityExceeded,
                 .deliveryConfirmationUnknown,
                 .invalidTransferState:
                return "payload_framing"
            case .ambiguousTarget, .invalidPort:
                return "discovery"
            }
        }
        let nsError = error as NSError
        if nsError.domain == "SkyBridge.Smoke" {
            switch nsError.code {
            case 2010, 2011, 2012, 2013:
                return "discovery"
            default:
                return "payload_framing"
            }
        }
        if normalizedPhase.contains("secure_channel")
            || normalizedPhase.contains("encryption")
            || normalizedPhase.contains("decrypt") {
            return "secure_channel"
        }
        if normalizedPhase.contains("secure_session")
            || normalizedPhase.contains("security")
            || normalizedPhase.contains("receiver_rejected")
            || normalizedPhase.contains("receiver_not_confirmed") {
            return "auth_policy"
        }
        if normalizedPhase.contains("connect")
            || normalizedPhase.contains("handshake") {
            return "handshake"
        }
        if normalizedPhase.contains("discovery")
            || normalizedPhase.contains("route") {
            return "discovery"
        }
        return "payload_framing"
    }

    private func fileTransferFailurePhase(for error: Error) -> String {
        if let discoveryError = error as? P2PDiscoveryError {
            switch discoveryError {
            case .noConnectableEndpoint:
                return "mac_smoke_reconnect_control_endpoint_missing"
            case .deviceNotConnected:
                return "mac_smoke_reconnect_device_not_connected"
            case .connectionCancelled:
                return "mac_smoke_reconnect_connection_cancelled"
            case .timeout:
                return "mac_smoke_reconnect_control_timeout"
            case .scanningFailed:
                return "mac_smoke_reconnect_scanning_failed"
            case .localNetworkPermissionDenied:
                return "mac_smoke_reconnect_local_network_permission_denied"
            case .strictPQCTrustPreflightFailed:
                return "mac_smoke_reconnect_strict_pqc_trust_preflight_failed"
            }
        }

        if let transferError = error as? FileTransferError {
            switch transferError {
            case .invalidHeader:
                return "mac_file_transfer_invalid_header"
            case .inboundInvalidInitialHeader:
                return "mac_file_transfer_initial_header_rejected"
            case .integrityCheckFailed:
                return "mac_file_transfer_integrity_check_failed"
            case .transferCancelled:
                return "mac_file_transfer_cancelled"
            case .connectionClosed:
                return "mac_file_transfer_connection_closed"
            case .inboundConnectionClosedBeforeMetadata:
                return "mac_file_transfer_inbound_pre_metadata_closed"
            case .fileNotFound:
                return "mac_file_transfer_file_not_found"
            case .timeout:
                return "mac_file_transfer_timeout"
            case .receiptWaitFailed(let stage, _):
                return "mac_file_transfer_receipt_\(stage.rawValue)"
            case .receiverNotConfirmed:
                return "mac_file_transfer_receiver_not_confirmed"
            case .receiverRejected:
                return "mac_file_transfer_receiver_rejected"
            case .secureSessionRequired:
                return "mac_file_transfer_secure_session_required"
            case .securityThreatDetected:
                return "mac_file_transfer_security_threat_detected"
            case .securityScanReviewRequired:
                return "mac_file_transfer_security_scan_review_required"
            case .securityScanIncomplete:
                return "mac_file_transfer_security_scan_incomplete"
            case .partialFileCleanupFailed:
                return "mac_file_transfer_partial_cleanup_failed"
            case .sourceFileCloseFailed:
                return "mac_file_transfer_source_close_failed"
            case .committedFileReleaseFailed:
                return "mac_file_transfer_committed_file_release_failed"
            case .resumeStatePersistenceFailed:
                return "mac_file_transfer_resume_state_persistence_failed"
            case .resumeStateCleanupFailed:
                return "mac_file_transfer_resume_state_cleanup_failed"
            case .automaticResumeFailed:
                return "mac_file_transfer_automatic_resume_failed"
            case .capacityExceeded:
                return "mac_file_transfer_capacity_exceeded"
            case .ambiguousTarget:
                return "mac_file_transfer_ambiguous_target"
            case .invalidPort:
                return "mac_file_transfer_invalid_port"
            case .deliveryConfirmationUnknown:
                return "mac_file_transfer_delivery_confirmation_unknown"
            case .invalidTransferState:
                return "mac_file_transfer_invalid_transfer_state"
            }
        }

        let nsError = error as NSError
        if nsError.domain == "SkyBridge.Smoke" {
            switch nsError.code {
            case 2000:
                return "mac_smoke_wait_completed_transfer_timeout"
            case 2001:
                return "mac_smoke_inbound_file_missing"
            case 2002:
                return "mac_smoke_payload_validation_failed"
            case 2010:
                return "mac_smoke_reconnect_discovery_timeout"
            case 2011:
                return "mac_smoke_stale_inbound_presence_route"
            case 2012:
                return "mac_smoke_reconnect_stable_identity_missing"
            case 2013:
                return "mac_smoke_reconnect_transfer_route_timeout"
            default:
                return "mac_smoke_error_code_\(nsError.code)"
            }
        }

        return "mac_smoke_unclassified_\(sanitizePhase(nsError.domain))_\(nsError.code)"
    }

    private func performBidirectionalFileTransferSmoke(
        reporter: SmokeStatusReporter
    ) async throws {
        let inboundName = "ios-smoke-\(fileTransferRunID).txt"
        let outboundName = "mac-smoke-\(fileTransferRunID).txt"

        let inboundTransfer = try await waitForCompletedTransfer(
            fileName: inboundName,
            direction: .incoming,
            timeoutSeconds: 90
        )
        guard let inboundPath = inboundTransfer.localPath?.path,
              FileManager.default.fileExists(atPath: inboundPath) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 2001,
                userInfo: [NSLocalizedDescriptionKey: "mac smoke 未找到接收到的文件 \(inboundName)"]
            )
        }
        let inboundURL = URL(fileURLWithPath: inboundPath)
        try validateSmokePayload(
            at: inboundURL,
            expectedRole: "ios",
            fileName: inboundName
        )
        let inboundHash = try Self.sha256Hex(url: inboundURL)
        reporter.append("file-transfer inbound-complete name=\(sanitize(inboundName)) sha256=\(inboundHash)")

        let outboundURL = try makeSmokeTransferFile(
            fileName: outboundName,
            contents: """
            role=mac
            run=\(fileTransferRunID)
            sentAt=\(ISO8601DateFormatter().string(from: Date()))
            """
        )
        let outboundHash = try Self.sha256Hex(url: outboundURL)
        reporter.append("file-transfer outbound-start name=\(sanitize(outboundName))")
        let targetDeviceId = Self.stableBonjourTargetDeviceId(inboundTransfer.deviceId)
        guard let route = await BonjourFileTransferRouteResolver().resolve(
            targetDeviceId: targetDeviceId,
            preferredName: inboundTransfer.deviceName,
            timeoutSeconds: 6.0
        ) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 2002,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "未发现匹配 \(inboundTransfer.deviceId) 的 _skybridge-xfer._tcp Bonjour 路由"
                ]
            )
        }
        reporter.append(
            "file-transfer outbound-route source=bonjour-transfer device=\(sanitize(route.deviceId ?? inboundTransfer.deviceId)) host=\(sanitize(route.host)) port=\(route.port)"
        )
        try await fileTransferManager.sendFile(
            at: outboundURL,
            to: inboundTransfer.deviceId,
            deviceName: route.name,
            ipAddress: route.host,
            port: route.port
        )
        reporter.append("file-transfer outbound-complete name=\(sanitize(outboundName)) sha256=\(outboundHash)")
    }

    private static func stableBonjourTargetDeviceId(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        guard !lowered.hasPrefix("peer:"),
              !lowered.hasPrefix("host:"),
              !lowered.hasPrefix("bonjour:") else {
            return nil
        }
        if lowered.hasPrefix("id:") {
            return String(trimmed.dropFirst("id:".count))
        }
        return trimmed
    }

    private func makeSmokeTransferFile(fileName: String, contents: String) throws -> URL {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SkyBridgeSmokeTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory.appendingPathComponent(fileName, isDirectory: false)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func validateSmokePayload(at url: URL, expectedRole: String, fileName: String) throws {
        let payload = try String(contentsOf: url, encoding: .utf8)
        guard payload.contains("role=\(expectedRole)"),
              payload.contains("run=\(fileTransferRunID)") else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 2002,
                userInfo: [
                    NSLocalizedDescriptionKey: "mac smoke 收到的文件不是当前真实 run: \(fileName)"
                ]
            )
        }
    }

    private nonisolated static func sha256Hex(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func waitForCompletedTransfer(
        fileName: String,
        direction: TransferDirection,
        timeoutSeconds: TimeInterval
    ) async throws -> FileTransfer {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let transfer = fileTransferManager.transferHistory.first(where: { transfer in
                transfer.fileName == fileName
                    && transfer.status == .completed
                    && transfer.direction == direction
            }) {
                return transfer
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        throw NSError(
            domain: "SkyBridge.Smoke",
            code: 2000,
            userInfo: [NSLocalizedDescriptionKey: "等待传输完成超时: \(fileName)"]
        )
    }
}

private struct BonjourFileTransferRoute {
    let name: String
    let host: String
    let port: Int
    let deviceId: String?
    let platform: String?
}

@MainActor
private final class BonjourFileTransferRouteResolver: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let serviceType = "_skybridge-xfer._tcp."
    private let serviceDomain = "local."
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var candidates: [BonjourFileTransferRoute] = []
    private var continuation: CheckedContinuation<BonjourFileTransferRoute?, Never>?
    private var targetDeviceId: String?
    private var preferredName: String?
    private var finished = false

    func resolve(
        targetDeviceId: String?,
        preferredName: String?,
        timeoutSeconds: TimeInterval
    ) async -> BonjourFileTransferRoute? {
        self.targetDeviceId = Self.normalizedDeviceId(targetDeviceId)
        self.preferredName = preferredName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let browser = NetServiceBrowser()
            self.browser = browser
            browser.delegate = self
            browser.searchForServices(ofType: serviceType, inDomain: serviceDomain)

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0.5, timeoutSeconds)))
                guard let self else { return }
                self.finish(with: self.bestCandidate())
            }
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        services.append(service)
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 2.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let route = makeRoute(from: sender) else { return }
        candidates.append(route)

        if let targetDeviceId,
           let candidateDeviceId = Self.normalizedDeviceId(route.deviceId),
           candidateDeviceId == targetDeviceId {
            finish(with: route)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        sender.stop()
    }

    private func makeRoute(from service: NetService) -> BonjourFileTransferRoute? {
        let txt = service.txtRecordData().map(Self.parseTXTRecord(_:)) ?? [:]
        let advertisedPort = Self.intValue(
            txt["fileTransferPort"] ?? txt["transferPort"] ?? txt["file_transfer_port"] ?? txt["port"]
        )
        let port = service.port > 0 ? service.port : advertisedPort
        guard (1...65535).contains(port) else { return nil }

        let host = service.hostName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? Self.firstUsableAddress(from: service.addresses)
        guard let host, !host.isEmpty else { return nil }

        let deviceId = txt["deviceId"] ?? txt["id"] ?? txt["deviceID"] ?? txt["device_id"]
        let name = txt["name"] ?? txt["device"] ?? service.name
        let platform = txt["platform"] ?? txt["os"]
        return BonjourFileTransferRoute(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? service.name,
            host: host,
            port: port,
            deviceId: deviceId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            platform: platform?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func bestCandidate() -> BonjourFileTransferRoute? {
        if let targetDeviceId {
            return candidates.first { candidate in
                Self.normalizedDeviceId(candidate.deviceId) == targetDeviceId
            }
        }

        if let preferredName {
            let named = candidates.filter { route in
                route.name.lowercased().contains(preferredName)
            }
            if named.count == 1 {
                return named.first
            }
        }

        let iOSCandidates = candidates.filter { route in
            route.platform?.lowercased().contains("ios") == true
                || route.name.lowercased().contains("ipad")
                || route.name.lowercased().contains("iphone")
        }
        if iOSCandidates.count == 1 {
            return iOSCandidates.first
        }

        return candidates.count == 1 ? candidates.first : nil
    }

    private func finish(with route: BonjourFileTransferRoute?) {
        guard !finished else { return }
        finished = true
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        for service in services {
            service.stop()
            service.delegate = nil
            service.remove(from: .main, forMode: .common)
        }
        services.removeAll()
        continuation?.resume(returning: route)
        continuation = nil
    }

    private static func parseTXTRecord(_ data: Data) -> [String: String] {
        NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { result, pair in
            guard let value = String(data: pair.value, encoding: .utf8) else { return }
            result[pair.key] = value
        }
    }

    private static func normalizedDeviceId(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("id:") {
            value.removeFirst("id:".count)
        }
        return value
    }

    private static func intValue(_ raw: String?) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return 0 }
        return Int(raw) ?? 0
    }

    private static func firstUsableAddress(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        var linkLocalIPv6: String?
        for data in addresses {
            let address = extractAddress(from: data)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, address != "未知地址" else { continue }
            let lower = address.lowercased()
            if lower.contains("."),
               !lower.hasPrefix("127."),
               !lower.hasPrefix("169.254") {
                return address
            }
            if lower.hasPrefix("fe80:"), lower.contains("%"), linkLocalIPv6 == nil {
                linkLocalIPv6 = address
            } else if lower.contains(":"),
                      !lower.hasPrefix("fe80:") {
                return address
            }
        }
        return linkLocalIPv6
    }

    private static func extractAddress(from data: Data) -> String {
        data.withUnsafeBytes { bytes in
            guard bytes.count >= MemoryLayout<sockaddr>.size,
                  let sockaddr = bytes.bindMemory(to: sockaddr.self).baseAddress else {
                return ""
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(sockaddr.pointee.sa_len)
            let flags = NI_NUMERICHOST
            guard getnameinfo(sockaddr, length, &host, socklen_t(host.count), nil, 0, flags) == 0 else {
                return ""
            }
            let data = Data(bytes: host, count: host.count)
            let trimmed = data.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
        }
    }
}

@MainActor
private enum LocalLanInteropHostLifetime {
    static var coordinator: LocalLanInteropHostCoordinator?
    static var pairingTrustApprovalWindowController: PairingTrustApprovalWindowController?
    static var remoteControlSecurityNoticePanelController: RemoteControlSecurityNoticePanelController?

    static func stopApprovalPresentation() {
        remoteControlSecurityNoticePanelController?.stop()
        remoteControlSecurityNoticePanelController = nil
        pairingTrustApprovalWindowController?.stop()
        pairingTrustApprovalWindowController = nil
    }
}

private enum HostStartupError: LocalizedError {
    case initializationTimedOut(String)
    case advertisementPortUnavailable(String)
    case embeddedLocalizationInvalid(String)
    case identityUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .initializationTimedOut(let component):
            return "\(component) did not finish initialization before the host timeout."
        case .advertisementPortUnavailable(let serviceType):
            return "\(serviceType) did not publish a connectable listener port before the host timeout."
        case .embeddedLocalizationInvalid(let reason):
            return "Embedded remote-control localization validation failed: \(reason)."
        case .identityUnavailable(let code):
            return "Device identity is unavailable (code=\(code))."
        }
    }
}

@main
struct LocalLanInteropHostMain {
    @MainActor
    static func main() {
        setenv("SKYBRIDGE_SMOKE_ROLE", "mac-host", 1)
        switch ProcessInfo.processInfo.environment[
            "SKYBRIDGE_SMOKE_IDENTITY_AUDIT_ONLY"
        ] {
        case nil, "0":
            break
        case "1":
            runIdentityAuditAndExit()
        default:
            fputs(
                "LocalLanInteropHost failed: invalid identity-audit mode.\n",
                stderr
            )
            Foundation.exit(2)
        }
        let enableCompatibilityBootstrap =
            ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ENABLE_COMPATIBILITY_MODE"] == "1"
            || ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"
        // A smoke run must not inherit the user's persisted compatibility setting. Use the
        // volatile argument domain for both true and false so the lab browser set is explicit,
        // deterministic, and leaves the user's settings untouched.
        var smokeDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        smokeDefaults["Settings.EnableCompatibilityMode"] = enableCompatibilityBootstrap
        UserDefaults.standard.setVolatileDomain(smokeDefaults, forName: UserDefaults.argumentDomain)

        let application = NSApplication.shared
        if application.activationPolicy() != .regular {
            _ = application.setActivationPolicy(.regular)
        }
        guard application.activationPolicy() == .regular else {
            fputs("LocalLanInteropHost failed: unable to activate the explicit approval UI.\n", stderr)
            Foundation.exit(1)
        }
        application.finishLaunching()

        Task { @MainActor in
            let approvalWindowController = PairingTrustApprovalWindowController()
            approvalWindowController.start()
            LocalLanInteropHostLifetime.pairingTrustApprovalWindowController = approvalWindowController

            let remoteControlSecurityNoticePanelController = RemoteControlSecurityNoticePanelController.shared
            remoteControlSecurityNoticePanelController.start()
            LocalLanInteropHostLifetime.remoteControlSecurityNoticePanelController =
                remoteControlSecurityNoticePanelController

            let coordinator = LocalLanInteropHostCoordinator()
            LocalLanInteropHostLifetime.coordinator = coordinator
            do {
                try await coordinator.start()
            } catch {
                LocalLanInteropHostLifetime.stopApprovalPresentation()
                fputs("LocalLanInteropHost failed: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }

        application.run()
        LocalLanInteropHostLifetime.stopApprovalPresentation()
    }

    @MainActor
    private static func runIdentityAuditAndExit() -> Never {
        Task { @MainActor in
            do {
                let report = try await DeviceIdentityKeyManager.shared
                    .legacyIdentityAuditReport()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var encoded = try encoder.encode(report)
                encoded.append(0x0A)
                try FileHandle.standardOutput.write(contentsOf: encoded)
                Foundation.exit(0)
            } catch {
                // The audit output is intentionally less descriptive than the
                // internal error: Keychain tags and scope details must never
                // cross this diagnostic boundary.
                fputs(
                    "LocalLanInteropHost identity audit failed: read-only-audit-error.\n",
                    stderr
                )
                Foundation.exit(1)
            }
        }
        dispatchMain()
    }
}

private struct LocalPQCReport: Encodable {
    struct PublicKeyEntry: Encodable {
        let suiteWireId: UInt16
        let publicKeyBase64: String
    }

    let deviceId: String
    let keys: [PublicKeyEntry]
}

private struct SmokeStatusReporter {
    let statusURL: URL?

    func reset() {
        guard let statusURL else { return }
        try? SmokeStatusFileAppender.reset(
            at: statusURL,
            protection: .completeUntilFirstUserAuthentication
        )
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        let formatted = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = formatted.data(using: .utf8) else { return }
        try? SmokeStatusFileAppender.append(
            data,
            to: statusURL,
            protection: .completeUntilFirstUserAuthentication
        )
    }
}

private func writeProtectedData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: url.path) {
        try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
    } else {
        FileManager.default.createFile(atPath: url.path, contents: data)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
