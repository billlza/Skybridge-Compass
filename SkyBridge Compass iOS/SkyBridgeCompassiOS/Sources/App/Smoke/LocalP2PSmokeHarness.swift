#if DEBUG || SKYBRIDGE_TESTING
import CryptoKit
import Foundation
import Network
import SkyBridgeProtocolCore

@available(iOS 17.0, *)
@MainActor
final class LocalP2PSmokeHarness {
    static let shared = LocalP2PSmokeHarness()
    private static let xwingSuiteWireID: UInt16 = 0x0001
    private static let mlkem768SuiteWireID: UInt16 = 0x0101
    private static let mlkem768FSSuiteWireID: UInt16 = 0x0102
    private static let controlRouteEvidenceKey = SymmetricKey(size: .bits256)
    private var didStart = false
    private let runStartedAt = Date()

    private init() {}

    var isEnabled: Bool {
        role == "ios-p2p-client"
    }

    private var role: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var targetDeviceID: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TARGET_DEVICE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var targetDeviceName: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TARGET_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var expectsPQCRekey: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"
    }

    private var expectsFileTransferSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_FILE_TRANSFER"] == "1"
    }

    private var expectsMacInitiatedReconnectSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_MAC_INITIATED_RECONNECT"] == "1"
    }

    private var expectsRemoteDesktopSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_REMOTE_DESKTOP"] == "1"
    }

    private var requiresAudio: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_AUDIO"] == "1"
    }

    private var requiresVisibleRemoteView: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW"] == "1"
    }

    private var requiresExtremeMediaValidation: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXTREME_MEDIA"] == "1"
            || ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_EXTREME_MEDIA"] == "1"
            || ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK"] == "1"
    }

    private var expectedHandshakeSuite: String {
        environmentValue("SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE") ?? "X-Wing"
    }

    private var fileTransferRunID: String {
        environmentValue("SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID") ?? "default"
    }

    private var usesOOBQRBootstrap: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_USE_OOB_QR_BOOTSTRAP"] == "1"
    }

    private var requiresSignedKEMRefresh: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH"] == "1"
    }

    private var forcesSignedKEMRefresh: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH"] == "1"
            || requiresSignedKEMRefresh
    }

    private var allowsPersistentTrustMutation: Bool {
        ProcessInfo.processInfo.environment[
            "SKYBRIDGE_SMOKE_ALLOW_PERSISTENT_TRUST_MUTATION"
        ] == "1"
    }

    private var hasInjectedPeerKEMMaterial: Bool {
        environmentValue("SKYBRIDGE_PQC_PEER_DEVICE_ID") != nil
            || environmentValue("SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64") != nil
            || environmentValue("SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64") != nil
            || environmentValue("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64") != nil
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

    private func positiveEnvironmentDouble(_ name: String) -> Double? {
        guard let raw = environmentValue(name),
              let value = Double(raw),
              value > 0 else {
            return nil
        }
        return value
    }

    func startIfNeeded() async {
        guard isEnabled, !didStart else { return }
        didStart = true
        defer { SkyBridgeDiagnosticTrace.flush() }

        let reporter: SmokeStatusReporter
        do {
            reporter = SmokeStatusReporter(statusURL: try statusURL())
            try reporter.reset()
        } catch {
            SkyBridgeLogger.shared.error("P2P smoke status sink initialization failed")
            return
        }
        PQCCryptoManager.instance.allowClassicFallbackForCompatibility = false
        reporter.append(
            """
            pqc policy strict=\(PQCCryptoManager.instance.enforcePQCHandshake ? 1 : 0) \
            allowClassicFallback=0 currentTier=\(PQCCryptoManager.instance.currentTier.rawValue) \
            currentSuite=\(Self.sanitize(PQCCryptoManager.instance.currentSuite.rawValue)) \
            expectRekey=\(expectsPQCRekey ? 1 : 0) preferred=\(Self.sanitize(environmentValue("SB_PQC_PREFERRED_SUITE") ?? "default"))
            """
        )
        await exportLocalPQCIdentityIfNeeded(reporter: reporter)
        if expectsPQCRekey {
            reporter.append("failed stage=pqc-policy error=classic_bootstrap_rekey_disabled_strict_pqc")
            return
        }
        guard rejectOOBQRBootstrapIfRequested(reporter: reporter) else {
            return
        }
        if hasInjectedPeerKEMMaterial && !allowsPersistentTrustMutation {
            reporter.append(
                "failed stage=trust-mutation error=injected_peer_kem_requires_explicit_persistent_trust_mutation_approval"
            )
            return
        }
        if !requiresSignedKEMRefresh && allowsPersistentTrustMutation {
            await preseedPeerKEMTrustIfNeeded(reporter: reporter)
        }

        guard !targetDeviceID.isEmpty else {
            reporter.append("failed stage=bootstrap error=missing_target_device_id")
            return
        }

        let discoveryManager = DeviceDiscoveryManager.instance
        let connectionManager = P2PConnectionManager.instance
        reporter.append(
            "boot role=ios-p2p-client target=\(Self.sanitize(targetDeviceID)) name=\(Self.sanitize(targetDeviceName))"
        )

        do {
            try await discoveryManager.startDiscovery(mode: .skybridgeOnly)
            reporter.append("discovery started")
        } catch {
            reporter.append("failed stage=discovery error=\(Self.sanitize(error.localizedDescription))")
            return
        }

        let timeoutSeconds = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 90
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        var selectedDevice: DiscoveredDevice?
        var connectAttempted = false
        var connectFailure = ""
        var lastHandshakeState = ""
        var lastError = ""
        var lastSuite = ""
        var lastRekey = ""
        var sawClassicHandshake = false
        var sawRekey = false
        var suiteStableSince: Date?
        var didPreseedResolvedTarget = false
        var didForceSignedKEMRefreshClear = false
        var lastDiscoverySummary = ""
        var lastDiscoveryHealAt = Date.distantPast
        let expectedNormalizedSuite = expectedHandshakeSuite.uppercased()

        while Date() < deadline {
            let handshakeState = connectionManager.currentHandshakeState
            if handshakeState != lastHandshakeState {
                lastHandshakeState = handshakeState
                reporter.append("state \(Self.sanitize(handshakeState))")
            }

            let discoveredSummary = summarizeDiscoveredDevices(discoveryManager.discoveredDevices)
            if discoveredSummary != lastDiscoverySummary {
                lastDiscoverySummary = discoveredSummary
                reporter.append("discovered \(discoveredSummary)")
            }

            let latestError = connectionManager.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !latestError.isEmpty, latestError != lastError {
                lastError = latestError
                reporter.append("error \(Self.sanitize(latestError))")
            }

            if selectedDevice == nil,
               let target = resolveTargetDevice(from: discoveryManager.discoveredDevices) {
                let hydratedTarget: DiscoveredDevice
                let hydrationStartedAt = Date()
                let targetStrongID = P2PConnectionEndpointPolicy.normalizedStrongDeviceId(for: target)
                reporter.append(
                    "control-route hydration=started policy=selected-discovery-target timeoutSeconds=15"
                )
                do {
                    hydratedTarget = try await connectionManager
                        .resolveConnectableDeviceAwaitingControlRoute(
                            from: target,
                            mode: .selectedDiscoveryTarget
                        )
                } catch is CancellationError {
                    reporter.append("cancelled stage=control-route")
                    return
                } catch {
                    reporter.append(
                        "failed stage=control-route error=route_hydration_wait_failed"
                    )
                    return
                }
                let hydrationElapsedMilliseconds = max(
                    0,
                    Int(Date().timeIntervalSince(hydrationStartedAt) * 1_000)
                )
                let hydratedStrongID = P2PConnectionEndpointPolicy.normalizedStrongDeviceId(
                    for: hydratedTarget
                )
                let hydratedStrongIDMatches = targetStrongID != nil && targetStrongID == hydratedStrongID
                reporter.append(
                    "control-route hydration=finished elapsedMs=\(hydrationElapsedMilliseconds) " +
                    "targetStrongIdPresent=\(targetStrongID == nil ? 0 : 1) " +
                    "hydratedStrongIdSame=\(hydratedStrongIDMatches ? 1 : 0)"
                )
                guard hydratedStrongIDMatches else {
                    reporter.append(
                        "failed stage=control-route error=strong_identity_changed_during_hydration"
                    )
                    return
                }
                guard verifyDiscoveredControlRoute(hydratedTarget, reporter: reporter) else {
                    return
                }
                selectedDevice = hydratedTarget
                reporter.append(
                    "target id=\(Self.sanitize(hydratedTarget.id)) name=\(Self.sanitize(hydratedTarget.name))"
                )
            }

            if !didForceSignedKEMRefreshClear, let target = selectedDevice {
                didForceSignedKEMRefreshClear = true
                guard await forceSignedKEMRefreshBeforeConnectIfNeeded(
                    target: target,
                    reporter: reporter
                ) else {
                    return
                }
            }

            if !didPreseedResolvedTarget, let target = selectedDevice {
                didPreseedResolvedTarget = true
                if !requiresSignedKEMRefresh && allowsPersistentTrustMutation {
                    await preseedResolvedTargetKEMTrustIfNeeded(target: target, reporter: reporter)
                }
            }

            if !connectAttempted, let target = selectedDevice {
                connectAttempted = true
                reporter.append("connect \(Self.sanitize(target.id))")
                Task { @MainActor in
                    do {
                        _ = expectsPQCRekey
                        try await connectionManager.connect(to: target)
                    } catch {
                        connectFailure = connectionManager.resolvedConnectionError(for: target)
                            ?? P2PConnectionManager.localizedConnectionErrorMessage(error)
                    }
                }
            }

            if !connectFailure.isEmpty {
                let failureContext = [connectFailure, lastError, lastHandshakeState]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: " | ")
                let failureStage = Self.p2pConnectFailureStage(failureContext)
                let failureDetail = Self.p2pConnectFailureDetail(
                    connectFailure: connectFailure,
                    lastError: lastError,
                    lastHandshakeState: lastHandshakeState,
                    stage: failureStage
                )
                reporter.append("failed stage=\(failureStage) error=\(Self.sanitize(failureDetail))")
                return
            }

            if selectedDevice == nil,
               Date().timeIntervalSince(lastDiscoveryHealAt) >= 5 {
                lastDiscoveryHealAt = Date()
                discoveryManager.retryAuthorizationBlockedBrowsers()
                await discoveryManager.refresh()
                reporter.append(
                    "discovery-heal count=\(discoveryManager.discoveredDevices.count)"
                )
            }

            if let target = selectedDevice {
                if let suite = connectionManager.getNegotiatedSuite(for: target.id)?.rawValue,
                   suite != lastSuite {
                    lastSuite = suite
                    suiteStableSince = Date()
                    reporter.append("suite \(Self.sanitize(suite))")

                    let normalizedSuite = suite.uppercased()
                    if normalizedSuite.contains("X25519") {
                        sawClassicHandshake = true
                    }
                }

                if let rekey = connectionManager.resolvedRekeyStatus(for: target) {
                    let description = "\(rekey.fromSuite)->\(rekey.toSuite)"
                    if description != lastRekey {
                        lastRekey = description
                        sawRekey = true
                        reporter.append(
                            "rekey \(Self.sanitize(rekey.fromSuite)) -> \(Self.sanitize(rekey.toSuite))"
                        )
                    }
                } else if !lastRekey.isEmpty {
                    lastRekey = ""
                    reporter.append("rekey cleared")
                }

                if let suite = connectionManager.getNegotiatedSuite(for: target.id)?.rawValue {
                    let normalizedSuite = suite.uppercased()

	                    if expectsPQCRekey {
	                        if sawClassicHandshake && sawRekey && normalizedSuite == "X-WING" {
	                            if expectsRemoteDesktopSmoke {
	                                do {
	                                    try await assertSignedKEMRefreshIfRequired(for: target, reporter: reporter)
	                                    try await performRemoteDesktopSmoke(
	                                        to: target,
	                                        suite: "X-Wing",
                                        reporter: reporter
                                    )
                                    reporter.append("success suite=X-Wing bootstrapRekey=1 remoteDesktop=1")
                                } catch {
                                    reporter.append(Self.remoteDesktopFailureLine(for: error))
                                }
                            } else if expectsFileTransferSmoke {
                                do {
                                    try await assertSignedKEMRefreshIfRequired(for: target, reporter: reporter)
                                    try await performBidirectionalFileTransferSmoke(
                                        to: target,
                                        reporter: reporter
                                    )
                                if expectsMacInitiatedReconnectSmoke {
                                    try await waitForMacInitiatedReconnectTransfer(reporter: reporter)
                                }
                                reporter.append(
                                    "success suite=X-Wing bootstrapRekey=1 fileTransfer=1 macReconnect=\(expectsMacInitiatedReconnectSmoke ? 1 : 0)"
                                )
                            } catch {
                                reporter.append(Self.fileTransferFailureLine(for: error))
                            }
                        } else {
                            reporter.append("success suite=X-Wing bootstrapRekey=1")
                            }
                            return
                        }
                    } else {
                        let hasExpectedPQCHandshake = normalizedSuite == expectedNormalizedSuite && !sawRekey
                        let hasStableExpectedPQCHandshake = hasExpectedPQCHandshake
                            && suiteStableSince.map { Date().timeIntervalSince($0) >= 1.0 } == true
                        let canStartRemoteDesktopSmoke = expectsRemoteDesktopSmoke && hasExpectedPQCHandshake
                        guard canStartRemoteDesktopSmoke || hasStableExpectedPQCHandshake else {
                            try? await Task.sleep(for: .milliseconds(250))
                            continue
                        }
	                        if expectsRemoteDesktopSmoke {
	                            do {
	                                try await assertSignedKEMRefreshIfRequired(for: target, reporter: reporter)
	                                try await performRemoteDesktopSmoke(
	                                    to: target,
	                                    suite: suite,
                                    reporter: reporter
                                )
                                reporter.append(
                                    "success suite=\(Self.sanitize(suite)) handshakeOnly=1 remoteDesktop=1"
                                )
                            } catch {
                                reporter.append(Self.remoteDesktopFailureLine(for: error))
                            }
                        } else if expectsFileTransferSmoke {
                            do {
                                try await assertSignedKEMRefreshIfRequired(for: target, reporter: reporter)
                                try await performBidirectionalFileTransferSmoke(
                                    to: target,
                                    reporter: reporter
                                )
                                if expectsMacInitiatedReconnectSmoke {
                                    try await waitForMacInitiatedReconnectTransfer(reporter: reporter)
                                }
                                reporter.append(
                                    "success suite=\(Self.sanitize(suite)) handshakeOnly=1 fileTransfer=1 macReconnect=\(expectsMacInitiatedReconnectSmoke ? 1 : 0)"
                                )
                            } catch {
                                reporter.append(Self.fileTransferFailureLine(for: error))
                            }
                        } else {
                            reporter.append("success suite=\(Self.sanitize(suite)) handshakeOnly=1")
                        }
                        return
                    }
                }
            }

            if connectAttempted,
               (handshakeState.contains("握手失败") || handshakeState.contains("rekey失败")) {
                reporter.append("failed stage=handshake error=\(Self.sanitize(handshakeState))")
                return
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        reporter.append("failed stage=timeout error=ios_local_p2p_smoke_timeout")
    }

    private func forceSignedKEMRefreshBeforeConnectIfNeeded(
        target: DiscoveredDevice,
        reporter: SmokeStatusReporter
    ) async -> Bool {
        guard forcesSignedKEMRefresh else { return true }
        guard allowsPersistentTrustMutation else {
            reporter.append(
                "failed stage=trust-mutation error=forced_signed_kem_refresh_requires_explicit_persistent_trust_mutation_approval"
            )
            return false
        }
        let candidates = smokeKEMCandidates(for: target)
        for candidate in candidates {
            await KEMTrustStore.shared.clear(deviceId: candidate)
        }
        reporter.append(
            """
            SKR-1 signed LAN KEM refresh forced: peer=\(Self.sanitize(target.id)) \
            candidates=\(Self.sanitize(candidates.prefix(6).joined(separator: ","))) \
            clearedKEM=1 preserveProtocolIdentity=1 lifecycle=force-missing-kem
            """
        )
        return true
    }

    private func assertSignedKEMRefreshIfRequired(
        for target: DiscoveredDevice,
        reporter: SmokeStatusReporter
    ) async throws {
        guard requiresSignedKEMRefresh else { return }
        let candidates = smokeKEMCandidates(for: target)
        guard let evidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: candidates) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 4101,
                userInfo: [
                    NSLocalizedDescriptionKey: "required signed LAN KEM refresh evidence is missing"
                ]
            )
        }
        if expectedHandshakeSuite.uppercased() == "X-WING",
           !evidence.suiteWireIds.contains(Self.xwingSuiteWireID) {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 4102,
                userInfo: [
                    NSLocalizedDescriptionKey: "signed LAN KEM refresh evidence does not contain X-Wing"
                ]
            )
        }
        guard let payloadHashHex = evidence.payloadHashHex,
              let payloadReference = P2PEvidenceReference.payloadHash(payloadHashHex) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 4103,
                userInfo: [
                    NSLocalizedDescriptionKey: "signed LAN KEM refresh evidence has no valid payload reference"
                ]
            )
        }
        guard let requestHashHex = evidence.requestHashHex,
              let requestReference = P2PEvidenceReference.requestHash(requestHashHex),
              let recoveryReference = evidence.recoveryEvidenceReference,
              P2PEvidenceReference.isValid(recoveryReference) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 4104,
                userInfo: [
                    NSLocalizedDescriptionKey: "signed LAN KEM refresh evidence is not linked to its PIB/SKR operation"
                ]
            )
        }
        guard let connectionEvidence = await P2PConnectionManager.instance
            .authenticatedConnectionEvidence(for: target.id),
              connectionEvidence.signedKEMRequestReference == requestReference,
              connectionEvidence.signedKEMPayloadReference == payloadReference,
              connectionEvidence.recoveryReference == recoveryReference else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 4105,
                userInfo: [
                    NSLocalizedDescriptionKey: "current authenticated connection is not bound to the signed KEM refresh evidence"
                ]
            )
        }

        let suites = evidence.suiteWireIds
            .map { String(format: "0x%04X", $0) }
            .joined(separator: ",")
        reporter.append(
            """
            SKR-1 signed LAN KEM refresh smoke-evidence: peer=\(Self.sanitize(target.id)) \
            source=\(Self.sanitize(evidence.source ?? "-")) suites=\(Self.sanitize(suites)) \
            payload_ref=\(payloadReference) \
            keyId=\(Self.sanitize(evidence.keyId ?? "-")) \
            generation=\(evidence.generation.map { String($0) } ?? "-") \
            signingFingerprint=\(Self.sanitize(evidence.signingFingerprint ?? "-")) \
            pinnedProtocolIdentity=1 signature=verified requestHash=bound \
            strictXWingEstablished=1 \
            payloadHash=\(Self.sanitize(evidence.payloadHashHex ?? "-")) \
            lifecycle=verified>smoke-proof
            """
        )
        reporter.append(
            """
            p2p-evidence-link session_ref=\(connectionEvidence.sessionReference) \
            pib_ref=\(recoveryReference) skr_ref=\(requestReference) \
            payload_ref=\(payloadReference) suite=\(Self.sanitize(connectionEvidence.negotiatedSuite))
            """
        )
    }

    private func smokeKEMCandidates(for target: DiscoveredDevice) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            for candidate in [trimmed] + PeerIdentityAliasResolver.lookupCandidates(for: trimmed) {
                guard seen.insert(candidate).inserted else { continue }
                ordered.append(candidate)
            }
        }

        append(targetDeviceID)
        append(target.id)
        append(target.bonjourServiceName)
        return ordered
    }

    private nonisolated static func p2pConnectFailureStage(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("strictpqc trust preflight failed")
            || normalized.contains("missing peer kem")
            || normalized.contains("missingpeerkempublickey")
            || (message.contains("缺少对端") && normalized.contains("kem"))
            || (message.contains("缺少对端") && message.contains("后量子密钥材料"))
            || (normalized.contains("pqc kem") && message.contains("疑似已变更")) {
            return "pqc-trust-preflight"
        }
        return "connect"
    }

    private nonisolated static func p2pConnectFailureDetail(
        connectFailure: String,
        lastError: String,
        lastHandshakeState: String,
        stage: String
    ) -> String {
        guard stage == "pqc-trust-preflight" else {
            return connectFailure
        }

        for candidate in [lastError, lastHandshakeState, connectFailure] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if p2pConnectFailureStage(trimmed) == "pqc-trust-preflight" {
                return trimmed
            }
        }
        return connectFailure
    }

    private func rejectOOBQRBootstrapIfRequested(reporter: SmokeStatusReporter) -> Bool {
        guard !usesOOBQRBootstrap else {
            reporter.append(
                "failed stage=bootstrap error=qr_bootstrap_removed_use_pib1_sas_then_skr1"
            )
            return false
        }
        return true
    }

    private func summarizeDiscoveredDevices(_ devices: [DiscoveredDevice]) -> String {
        guard !devices.isEmpty else { return "count=0" }

        let preview = devices
            .prefix(3)
            .map { device in
                "\(Self.sanitize(device.id))|\(Self.sanitize(device.name))"
            }
            .joined(separator: ",")
        let suffix = devices.count > 3 ? ",more=\(devices.count - 3)" : ""
        return "count=\(devices.count) peers=\(preview)\(suffix)"
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

    private func resolveTargetDevice(from devices: [DiscoveredDevice]) -> DiscoveredDevice? {
        let normalizedTarget = targetDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTarget.isEmpty else { return nil }
        for device in devices {
            let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
                .union(PeerIdentityAliasResolver.aliasKeys(for: device))
                .union([device.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()])
            if aliases.contains(normalizedTarget) || aliases.contains("id:\(normalizedTarget)") {
                return device
            }
        }
        return nil
    }

    private func verifyDiscoveredControlRoute(
        _ target: DiscoveredDevice,
        reporter: SmokeStatusReporter
    ) -> Bool {
        let liveEndpoints = DeviceDiscoveryManager.instance.liveBonjourServiceEndpoints(
            for: target,
            serviceType: .skybridge
        )
        let endpoints = P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: target,
            liveBonjourControlEndpoints: liveEndpoints
        )
        reporter.append(
            "control-route evidence liveEndpointCount=\(liveEndpoints.count) " +
            "eligibleEndpointCount=\(endpoints.count) " +
            "ignoredLiveEndpointCount=\(max(0, liveEndpoints.count - endpoints.count)) " +
            "liveRoutes=\(Self.summarizeControlEndpoints(liveEndpoints)) " +
            "eligibleRoutes=\(Self.summarizeControlEndpoints(endpoints))"
        )
        guard !endpoints.isEmpty,
              case .service(let name, let type, let domain, let interface) = endpoints[0],
              type == DiscoveryServiceType.skybridge.rawValue else {
            reporter.append(
                "failed stage=control-route error=missing_provenance_bound_bonjour_service_endpoint"
            )
            return false
        }

        let observedInterfaces = endpoints.compactMap { endpoint -> String? in
            guard case .service(_, _, _, let interface) = endpoint else { return nil }
            return interface?.name
        }
        let selectedRouteReference = Self.controlRouteEvidenceReference(
            name: name,
            type: type,
            domain: domain,
            interface: interface
        )

        reporter.append(
            """
            control-route source=bonjour-service serviceRef=\(selectedRouteReference) \
            type=\(Self.sanitize(type)) domain=\(Self.sanitize(domain)) includePeerToPeer=1 \
            routeCount=\(endpoints.count) preferredInterface=\(Self.sanitize(interface?.name ?? "unspecified")) \
            observedInterfaces=\(Self.sanitize(observedInterfaces.joined(separator: ",")))
            """
        )
        return true
    }

    private static func summarizeControlEndpoints(
        _ endpoints: [NWEndpoint]
    ) -> String {
        let maximumReportedEndpoints = 8
        let summaries = endpoints.prefix(maximumReportedEndpoints).map { endpoint -> String in
            guard case .service(let name, let type, let domain, let interface) = endpoint else {
                return "non-service"
            }
            let reference = controlRouteEvidenceReference(
                name: name,
                type: type,
                domain: domain,
                interface: interface
            )
            return "service[ref=\(reference)|\(sanitize(type))|\(sanitize(domain))|" +
                "\(sanitize(interface?.name ?? "unspecified"))]"
        }
        let omitted = endpoints.count - summaries.count
        let suffix = omitted > 0 ? ",more=\(omitted)" : ""
        return sanitize(summaries.joined(separator: ";") + suffix)
    }

    private static func controlRouteEvidenceReference(
        name: String,
        type: String,
        domain: String,
        interface: NWInterface?
    ) -> String {
        let material = [name, type, domain, interface?.name ?? "unspecified"]
            .joined(separator: "\u{0}")
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(material.utf8),
            using: controlRouteEvidenceKey
        )
        return authenticationCode.prefix(8).map { String(format: "%02x", $0) }.joined()
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

    private func preseedPeerKEMTrustIfNeeded(reporter: SmokeStatusReporter) async {
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

    private func preseedResolvedTargetKEMTrustIfNeeded(
        target: DiscoveredDevice,
        reporter: SmokeStatusReporter
    ) async {
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
        guard !keys.isEmpty else { return }

        await KEMTrustStore.shared.upsert(deviceId: target.id, kemPublicKeys: keys)
        reporter.append("pqc-preseed target-alias id=\(Self.sanitize(target.id))")
    }

    private func performRemoteDesktopSmoke(
        to target: DiscoveredDevice,
        suite: String,
        reporter: SmokeStatusReporter
    ) async throws {
        let manager = RemoteDesktopManager.instance
        guard let connectionEvidence = await P2PConnectionManager.instance
            .authenticatedConnectionEvidence(for: target.id) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 4201,
                userInfo: [
                    NSLocalizedDescriptionKey: "current authenticated P2P connection has no exact evidence receipt"
                ]
            )
        }
        reporter.append(
            "p2p-session-link session_ref=\(connectionEvidence.sessionReference) suite=\(Self.sanitize(connectionEvidence.negotiatedSuite))"
        )
        let minFPS = positiveEnvironmentDouble("SKYBRIDGE_SMOKE_MIN_FPS")
            ?? (requiresExtremeMediaValidation ? 59.0 : 30.0)
        let passSeconds = max(
            1.0,
            positiveEnvironmentDouble("SKYBRIDGE_SMOKE_MIN_PASS_SECONDS")
                ?? positiveEnvironmentDouble("SKYBRIDGE_SMOKE_SOAK_SECONDS")
                ?? 10.0
        )
        let timeoutSeconds = positiveEnvironmentDouble("SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS")
            ?? positiveEnvironmentDouble("SKYBRIDGE_SMOKE_TIMEOUT_SECONDS")
            ?? 120.0
        let requestedSize = requestedSmokeVideoSize()
        let expectedSize = requestedSize.map { size in
            requiresExtremeMediaValidation ? size : Self.normalizedVideoSizeForEncoder(size)
        }
        let expectedRenderOrientation = RemoteDesktopRenderOrientation(
            rawValue: environmentValue("SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION") ?? "upright"
        ) ?? .upright
        let requestedSizeLabel = requestedSize.map { "\($0.width)x\($0.height)" } ?? "auto"
        let expectedSizeLabel = expectedSize.map { "\($0.width)x\($0.height)" } ?? "auto"

        reporter.append(
            """
            remote-desktop start target=\(Self.sanitize(target.id)) suite=\(Self.sanitize(suite)) \
            minFps=\(String(format: "%.1f", minFPS)) passSeconds=\(Int(passSeconds.rounded())) \
            requested=\(requestedSizeLabel) expected=\(expectedSizeLabel) audio=\(requiresAudio ? 1 : 0) \
            visibleRemoteView=\(requiresVisibleRemoteView ? 1 : 0) expectedRenderOrientation=\(expectedRenderOrientation.rawValue)
            """
        )
        reporter.append("remote-desktop p2p-active \(Self.sanitize(activeP2PSmokeSummary()))")

        if requiresVisibleRemoteView {
            reporter.append("remote-desktop ui-gate waiting-for-RemoteDesktopView")
        } else {
            try await manager.connect(
                to: target,
                routeIntent: .directLAN
            )
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var passStartedAt: Date?
        var passStartedReceivedFrames = 0
        var passStartedDisplayedFrames = 0
        var passMinTwoSecondReceivedFrames: Int?
        var passMinTwoSecondDisplayedFrames: Int?
        var lastDiagnosticAt = Date.distantPast
        var lastSummary = "remote desktop did not produce diagnostics"

        while Date() < deadline {
            let now = Date()
            let snapshot = await manager.smokeDiagnosticSnapshot()
            let audio = snapshot.realtimeAudio
            let audioPass = !requiresAudio || (
                (audio?.datagramsSeen ?? 0) > 0
                    && (audio?.receivedPackets ?? 0) > 0
                    && (audio?.decodedPackets ?? 0) > 0
                    && (audio?.playedPackets ?? 0) > 0
                    && (audio?.renderedFrames ?? 0) > 0
                    && (snapshot.audioChannelCount ?? 0) >= 2
                    && (audio?.rejectedPackets ?? 0) == 0
                    && (audio?.replayRejectedPackets ?? 0) == 0
                    && (audio?.jitterEvictedPackets ?? 0) == 0
                    && (audio?.playbackDroppedPackets ?? 0) == 0
                    && (audio?.underflowEvents ?? 0) == 0
                    && (audio?.rebufferEvents ?? 0) == 0
            )
            let resolutionPass: Bool = {
                guard let expectedSize else {
                    return snapshot.resolutionWidth > 0 && snapshot.resolutionHeight > 0
                }
                return snapshot.resolutionWidth == expectedSize.width
                    && snapshot.resolutionHeight == expectedSize.height
            }()
            let pipelinePass: Bool = {
                switch snapshot.renderPipeline {
                case .metalRenderer:
                    return true
                case .sampleBufferDisplayLayer:
                    return !self.requiresExtremeMediaValidation
                case .waiting, .webrtcNativeVideo, .stillImageFallback:
                    return false
                }
            }()
            let renderOrientationPass = snapshot.renderPipeline != .metalRenderer
                || snapshot.renderOrientation == expectedRenderOrientation
            let recentFramePass = (snapshot.lastDisplayedFrameAgeSeconds ?? .infinity) < 2.5
                || (snapshot.lastFrameArrivalAgeSeconds ?? .infinity) < 2.5
            let metalFrameAgeBudgetMs = 100
            let metalLatencyPass = !requiresExtremeMediaValidation
                || snapshot.renderPipeline != .metalRenderer
                || (snapshot.metalFrameAgeMaxInLastTwoSecondsMs ?? Int.max) <= metalFrameAgeBudgetMs
            let uiPass = !requiresVisibleRemoteView || snapshot.hasActivePresentationOwner
            let corePass = snapshot.isStreaming
                && !snapshot.isUsingCrossNetworkTransport
                && uiPass
                && snapshot.receivedFramesInStream > 0
                && snapshot.displayedFramesInStream > 0
                && resolutionPass
                && pipelinePass
                && renderOrientationPass
                && recentFramePass
                && metalLatencyPass
                && audioPass
            var passWindowJustStarted = false
            var passWindowResetReason: String?
            if corePass {
                if passStartedAt == nil {
                    passStartedAt = now
                    passStartedReceivedFrames = snapshot.receivedFramesInStream
                    passStartedDisplayedFrames = snapshot.displayedFramesInStream
                    passMinTwoSecondReceivedFrames = nil
                    passMinTwoSecondDisplayedFrames = nil
                    passWindowJustStarted = true
                }
            } else {
                if passStartedAt != nil {
                    if !metalLatencyPass {
                        passWindowResetReason = "metal-frame-age"
                    } else if !pipelinePass {
                        passWindowResetReason = "render-pipeline"
                    } else if !audioPass {
                        passWindowResetReason = "audio"
                    } else {
                        passWindowResetReason = "core"
                    }
                }
                passStartedAt = nil
                passStartedReceivedFrames = 0
                passStartedDisplayedFrames = 0
                passMinTwoSecondReceivedFrames = nil
                passMinTwoSecondDisplayedFrames = nil
            }

            let windowSeconds = passStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
            let windowReceivedFrames = passStartedAt == nil
                ? 0
                : max(0, snapshot.receivedFramesInStream - passStartedReceivedFrames)
            let windowDisplayedFrames = passStartedAt == nil
                ? 0
                : max(0, snapshot.displayedFramesInStream - passStartedDisplayedFrames)
            let windowReceivedFPS = windowSeconds > 0 ? Double(windowReceivedFrames) / windowSeconds : 0
            let windowDisplayedFPS = windowSeconds > 0 ? Double(windowDisplayedFrames) / windowSeconds : 0
            let twoSecondFrameRequirement = Int(ceil(minFPS * 2.0))
            let currentTwoSecondDisplayCadencePass = !requiresExtremeMediaValidation
                || windowSeconds < 2.0
                || snapshot.displayedFramesInLastTwoSeconds >= twoSecondFrameRequirement
            let currentTwoSecondRxCadencePass = !requiresExtremeMediaValidation
                || windowSeconds < 2.0
                || snapshot.receivedFramesInLastTwoSeconds >= twoSecondFrameRequirement
            let currentTwoSecondCombinedCadencePass = !requiresExtremeMediaValidation
                || windowSeconds < 2.0
                || (
                    snapshot.displayedFramesInLastTwoSeconds >= twoSecondFrameRequirement
                        && snapshot.receivedFramesInLastTwoSeconds >= twoSecondFrameRequirement
                )
            let currentTwoSecondCadencePass = currentTwoSecondCombinedCadencePass
            if corePass && windowSeconds >= 2.0 {
                passMinTwoSecondReceivedFrames = min(
                    passMinTwoSecondReceivedFrames ?? snapshot.receivedFramesInLastTwoSeconds,
                    snapshot.receivedFramesInLastTwoSeconds
                )
                passMinTwoSecondDisplayedFrames = min(
                    passMinTwoSecondDisplayedFrames ?? snapshot.displayedFramesInLastTwoSeconds,
                    snapshot.displayedFramesInLastTwoSeconds
                )
            }
            let rollingDisplayCadencePass = !requiresExtremeMediaValidation
                || (
                    windowSeconds >= 2.0
                        && (passMinTwoSecondDisplayedFrames ?? 0) >= twoSecondFrameRequirement
                )
            let rollingRxCadencePass = !requiresExtremeMediaValidation
                || (
                    windowSeconds >= 2.0
                        && (passMinTwoSecondReceivedFrames ?? 0) >= twoSecondFrameRequirement
                )
            let rollingCombinedCadencePass = rollingDisplayCadencePass && rollingRxCadencePass
            let rollingCadencePass = rollingCombinedCadencePass
            let aggregateRatePass = windowDisplayedFPS >= minFPS && windowReceivedFPS >= minFPS
            let pass = corePass
                && windowSeconds >= passSeconds
                && aggregateRatePass
                && rollingCombinedCadencePass
            let shouldResetPassWindow = corePass
                && !pass
                && (
                    (windowSeconds >= 2.0 && !currentTwoSecondCombinedCadencePass)
                        || (windowSeconds >= passSeconds && !aggregateRatePass)
                )

            lastSummary = """
            fps=\(String(format: "%.1f", snapshot.frameRate)) rxFps=\(String(format: "%.1f", snapshot.receivedFrameRate)) \
            windowSeconds=\(String(format: "%.2f", windowSeconds)) \
            windowFPS=\(String(format: "%.1f", windowDisplayedFPS)) windowRxFps=\(String(format: "%.1f", windowReceivedFPS)) \
            windowDisplayedFrames=\(windowDisplayedFrames) windowReceivedFrames=\(windowReceivedFrames) \
            min2sDisplayFrames=\(passMinTwoSecondDisplayedFrames ?? 0) min2sRxFrames=\(passMinTwoSecondReceivedFrames ?? 0) \
            twoSecondRequiredFrames=\(twoSecondFrameRequirement) last2sDisplayFrames=\(snapshot.displayedFramesInLastTwoSeconds) \
            last2sRxFrames=\(snapshot.receivedFramesInLastTwoSeconds) \
            last2sSocketRxFrames=\(snapshot.socketArrivalFramesInLastTwoSeconds) \
            last2sSourceFrames=\(snapshot.sourceCadenceFramesInLastTwoSeconds) \
            last2sMetalDeliveryFrames=\(snapshot.metalDeliveryFramesInLastTwoSeconds) \
            rxFrameClock=\(snapshot.receivedFrameClock) current2sCadencePass=\(currentTwoSecondCadencePass ? 1 : 0) \
            current2sDisplayCadencePass=\(currentTwoSecondDisplayCadencePass ? 1 : 0) current2sRxCadencePass=\(currentTwoSecondRxCadencePass ? 1 : 0) \
            current2sCombinedCadencePass=\(currentTwoSecondCombinedCadencePass ? 1 : 0) rollingDisplayCadencePass=\(rollingDisplayCadencePass ? 1 : 0) \
            rollingRxCadencePass=\(rollingRxCadencePass ? 1 : 0) rollingCombinedCadencePass=\(rollingCombinedCadencePass ? 1 : 0) \
            rollingCadencePass=\(rollingCadencePass ? 1 : 0) aggregateRatePass=\(aggregateRatePass ? 1 : 0) \
            metalFrameAge2sMs=\(snapshot.metalFrameAgeMaxInLastTwoSecondsMs.map(String.init) ?? "-") \
            metalFrameAgeBudgetMs=\(metalFrameAgeBudgetMs) metalLatencyPass=\(metalLatencyPass ? 1 : 0) \
            frame=\(snapshot.resolutionWidth)x\(snapshot.resolutionHeight) \
            pipeline=\(snapshot.renderPipeline.rawValue) renderOrientation=\(snapshot.renderOrientation.rawValue) streaming=\(snapshot.isStreaming ? 1 : 0) \
            crossNetwork=\(snapshot.isUsingCrossNetworkTransport ? 1 : 0) state=\(Self.sanitize(snapshot.stateDescription)) \
            recvFrames=\(snapshot.receivedFramesInStream) displayedFrames=\(snapshot.displayedFramesInStream) \
            uiSurface=\(snapshot.hasActivePresentationOwner ? "remoteDesktopView" : "none") uiOwnerCount=\(snapshot.presentationOwnerCount) \
            audioRxRecv=\(audio?.receivedPackets ?? 0) audioRxDecoded=\(audio?.decodedPackets ?? 0) \
            audioRxPlayed=\(audio?.playedPackets ?? 0) audioRxRendered=\(audio?.renderedFrames ?? 0) \
            audioChannels=\(snapshot.audioChannelCount ?? 0) \
            audioRxRejected=\(audio?.rejectedPackets ?? 0) audioRxPlaybackDrop=\(audio?.playbackDroppedPackets ?? 0) \
            audioRxReplayRejected=\(audio?.replayRejectedPackets ?? 0) audioRxJitterEvicted=\(audio?.jitterEvictedPackets ?? 0) \
            audioRxUnderflow=\(audio?.underflowEvents ?? 0) audioRxRebuffer=\(audio?.rebufferEvents ?? 0)
            """

            if now.timeIntervalSince(lastDiagnosticAt) >= 1.0 {
                lastDiagnosticAt = now
                reporter.append("remote-desktop status \(lastSummary) corePass=\(corePass ? 1 : 0) pass=\(pass ? 1 : 0)")
            }

            if snapshot.stateDescription.lowercased().contains("error") {
                let message = "P2P 远控媒体主路径失败: \(lastSummary)"
                reporter.append("failed stage=remote-desktop phase=media_main_path_error error=\(Self.sanitize(message))")
                throw NSError(
                    domain: "SkyBridge.Smoke",
                    code: 1201,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }

            if passWindowJustStarted {
                reporter.append("remote-desktop pass-window-start \(lastSummary)")
            }
            if let passWindowResetReason {
                reporter.append("remote-desktop pass-window-reset reason=\(passWindowResetReason) \(lastSummary)")
            }
            if pass {
                reporter.append(
                    "remote-desktop-pass seconds=\(Int(windowSeconds.rounded())) requestedSeconds=\(Int(passSeconds.rounded())) \(lastSummary)"
                )
                return
            }
            if shouldResetPassWindow {
                reporter.append("remote-desktop pass-window-reset reason=cadence \(lastSummary)")
                passStartedAt = nil
                passStartedReceivedFrames = 0
                passStartedDisplayedFrames = 0
                passMinTwoSecondReceivedFrames = nil
                passMinTwoSecondDisplayedFrames = nil
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        throw NSError(
            domain: "SkyBridge.Smoke",
            code: 1200,
            userInfo: [NSLocalizedDescriptionKey: "P2P 远控 smoke 超时: \(lastSummary)"]
        )
    }

    private func requestedSmokeVideoSize() -> (width: Int, height: Int)? {
        guard let width = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_WIDTH"),
              let height = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_HEIGHT") else {
            return nil
        }
        return (width, height)
    }

    private static func normalizedVideoSizeForEncoder(
        _ size: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        func evenDimension(_ value: Int) -> Int {
            let clamped = max(2, value)
            return clamped.isMultiple(of: 2) ? clamped : clamped - 1
        }
        return (evenDimension(size.width), evenDimension(size.height))
    }

    @MainActor
    private func activeP2PSmokeSummary() -> String {
        let connections = P2PConnectionManager.instance.activeConnections
        guard !connections.isEmpty else { return "none" }
        return connections.map { connection in
            [
                "id=\(connection.device.id)",
                "name=\(connection.device.name)",
                "status=\(connection.status.rawValue)",
                "ip=\(connection.device.ipAddress ?? "-")",
                "remotePort=\(connection.device.remoteControlPort.map(String.init) ?? "-")"
            ].joined(separator: ",")
        }.joined(separator: ";")
    }

    private func performBidirectionalFileTransferSmoke(
        to target: DiscoveredDevice,
        reporter: SmokeStatusReporter
    ) async throws {
        try await FileTransferRuntime.shared.ensureHealthy()

        let outboundName = "ios-smoke-\(fileTransferRunID).txt"
        let inboundName = "mac-smoke-\(fileTransferRunID).txt"
        let outboundURL = try makeSmokeTransferFile(
            fileName: outboundName,
            contents: """
            role=ios
            run=\(fileTransferRunID)
            sentAt=\(ISO8601DateFormatter().string(from: Date()))
            target=\(target.id)
            """
        )
        let outboundHash = try Self.sha256Hex(url: outboundURL)

        reporter.append("file-transfer outbound-start name=\(Self.sanitize(outboundName))")
        try await FileTransferManager.instance.sendFile(
            at: outboundURL,
            to: target,
            routeIntent: .directLAN
        )
        reporter.append("file-transfer outbound-complete name=\(Self.sanitize(outboundName)) sha256=\(outboundHash)")

        let inboundTransfer = try await waitForCompletedTransfer(
            fileName: inboundName,
            isIncoming: true,
            timeoutSeconds: 90
        )
        guard let localURL = try await FileTransferManager.instance.resolveExistingLocalFileURL(for: inboundTransfer),
              FileManager.default.fileExists(atPath: localURL.path) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "iOS smoke 未找到接收到的文件 \(inboundName)"]
            )
        }
        try validateSmokePayload(
            at: localURL,
            expectedRole: "mac",
            fileName: inboundName
        )
        let inboundHash = try Self.sha256Hex(url: localURL)

        reporter.append(
            "file-transfer inbound-complete name=\(Self.sanitize(inboundName)) path=\(Self.sanitize(localURL.lastPathComponent)) sha256=\(inboundHash)"
        )
    }

    private func waitForMacInitiatedReconnectTransfer(reporter: SmokeStatusReporter) async throws {
        let inboundName = "mac-reconnect-smoke-\(fileTransferRunID).txt"
        reporter.append("mac-reconnect wait-inbound name=\(Self.sanitize(inboundName))")

        let inboundTransfer = try await waitForCompletedTransfer(
            fileName: inboundName,
            isIncoming: true,
            timeoutSeconds: 120
        )
        guard let localURL = try await FileTransferManager.instance.resolveExistingLocalFileURL(for: inboundTransfer),
              FileManager.default.fileExists(atPath: localURL.path) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 1010,
                userInfo: [NSLocalizedDescriptionKey: "iOS smoke 未找到 Mac 主动回连文件 \(inboundName)"]
            )
        }
        try validateSmokePayload(
            at: localURL,
            expectedRole: "mac-reconnect",
            fileName: inboundName
        )
        let inboundHash = try Self.sha256Hex(url: localURL)
        reporter.append(
            "mac-reconnect inbound-complete name=\(Self.sanitize(inboundName)) path=\(Self.sanitize(localURL.lastPathComponent)) sha256=\(inboundHash)"
        )
    }

    private func makeSmokeTransferFile(fileName: String, contents: String) throws -> URL {
        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmokeTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = contents.data(using: .utf8) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "无法编码 iOS smoke 文件内容"]
            )
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func waitForCompletedTransfer(
        fileName: String,
        isIncoming: Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> FileTransfer {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let transfer = FileTransferManager.instance.transferHistory.first(where: { transfer in
                transfer.fileName == fileName
                    && transfer.isIncoming == isIncoming
                    && transfer.status == .completed
                    && transfer.timestamp >= runStartedAt
            }) {
                return transfer
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        throw NSError(
            domain: "SkyBridge.Smoke",
            code: 1000,
            userInfo: [NSLocalizedDescriptionKey: "等待传输完成超时: \(fileName)"]
        )
    }

    private func validateSmokePayload(at url: URL, expectedRole: String, fileName: String) throws {
        let payload = try String(contentsOf: url, encoding: .utf8)
        guard payload.contains("role=\(expectedRole)"),
              payload.contains("run=\(fileTransferRunID)") else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 1003,
                userInfo: [
                    NSLocalizedDescriptionKey: "iOS smoke 收到的文件不是当前真实 run: \(fileName)"
                ]
            )
        }
    }

    private nonisolated static func sha256Hex(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private nonisolated static func smokePhaseName(from phaseField: String) -> String {
        guard phaseField.hasPrefix("phase=") else { return phaseField }
        return String(phaseField.dropFirst("phase=".count))
    }

    private nonisolated static func fileTransferFailureLine(for error: Error) -> String {
        if let transferError = error as? FileTransferError {
            switch transferError {
            case .networkStageFailed(let stage, let endpoint, let details):
                let endpointField = endpoint.map { " endpoint=\(Self.sanitize($0))" } ?? ""
                return fileTransferFailureLine(
                    phase: stage,
                    category: fileTransferFailureCategory(forNetworkStage: stage),
                    error: details,
                    extraFields: endpointField
                )
            case .receiptWaitFailed(let stage, let details):
                let detailField = details.map { " detail=\(Self.sanitize($0))" } ?? ""
                return fileTransferFailureLine(
                    phase: "receipt_\(stage.rawValue)",
                    category: "payload_framing",
                    error: transferError.localizedDescription,
                    extraFields: detailField
                )
            case .networkError(let reason):
                return fileTransferFailureLine(
                    phase: "network_error",
                    category: "payload_framing",
                    error: reason
                )
            case .transferFailed(let reason):
                return fileTransferFailureLine(
                    phase: "transfer_failed",
                    category: "payload_framing",
                    error: reason
                )
            case .invalidDestination:
                return fileTransferFailureLine(
                    phase: "route_resolution_invalid_destination",
                    category: "discovery",
                    error: transferError.localizedDescription
                )
            case .connectionFailed:
                return fileTransferFailureLine(
                    phase: "connect_failed",
                    category: "handshake",
                    error: transferError.localizedDescription
                )
            case .timeout:
                return fileTransferFailureLine(
                    phase: "timeout",
                    category: "payload_framing",
                    error: transferError.localizedDescription
                )
            case .invalidMetadata:
                return fileTransferFailureLine(
                    phase: "invalid_metadata",
                    category: "payload_framing",
                    error: transferError.localizedDescription
                )
            case .checksumMismatch:
                return fileTransferFailureLine(
                    phase: "checksum_mismatch",
                    category: "payload_framing",
                    error: transferError.localizedDescription
                )
            case .secureSessionRequired:
                return fileTransferFailureLine(
                    phase: "secure_session_required",
                    category: "auth_policy",
                    error: transferError.localizedDescription
                )
            case .fileNotFound:
                return fileTransferFailureLine(
                    phase: "file_not_found",
                    category: "payload_framing",
                    error: transferError.localizedDescription
                )
            case .transferCancelled:
                return fileTransferFailureLine(
                    phase: "transfer_cancelled",
                    category: "payload_framing",
                    error: transferError.localizedDescription
                )
            case .diskFull:
                return fileTransferFailureLine(
                    phase: "disk_full",
                    category: "payload_framing",
                    error: transferError.localizedDescription
                )
            case .permissionDenied:
                return fileTransferFailureLine(
                    phase: "permission_denied",
                    category: "auth_policy",
                    error: transferError.localizedDescription
                )
            case .encryptionFailed:
                return fileTransferFailureLine(
                    phase: "encryption_failed",
                    category: "secure_channel",
                    error: transferError.localizedDescription
                )
            case .capacityExceeded:
                return fileTransferFailureLine(
                    phase: "capacity_exceeded",
                    category: "resource_policy",
                    error: transferError.localizedDescription
                )
            case .invalidTransferState:
                return fileTransferFailureLine(
                    phase: "invalid_transfer_state",
                    category: "resource_policy",
                    error: transferError.localizedDescription
                )
            case .deliveryConfirmationUnknown:
                return fileTransferFailureLine(
                    phase: "delivery_confirmation_unknown",
                    category: "payload_framing",
                    error: transferError.localizedDescription
                )
            case .partialFileCleanupFailed:
                return fileTransferFailureLine(
                    phase: "partial_file_cleanup_failed",
                    category: "resource_policy",
                    error: transferError.localizedDescription
                )
            case .committedFileReleaseFailed:
                return fileTransferFailureLine(
                    phase: "committed_file_release_failed",
                    category: "resource_policy",
                    error: transferError.localizedDescription
                )
            }
        }
        let nsError = error as NSError
        let signedKEMRefreshEvidenceMissingPhaseField = "phase=signed_kem_refresh_evidence_missing"
        let signedKEMRefreshWrongSuitePhaseField = "phase=signed_kem_refresh_wrong_suite"
        if nsError.domain == "SkyBridge.Smoke" {
            switch nsError.code {
            case 4101:
                return fileTransferFailureLine(
                    phase: Self.smokePhaseName(from: signedKEMRefreshEvidenceMissingPhaseField),
                    category: "auth_policy",
                    error: error.localizedDescription
                )
            case 4102:
                return fileTransferFailureLine(
                    phase: Self.smokePhaseName(from: signedKEMRefreshWrongSuitePhaseField),
                    category: "auth_policy",
                    error: error.localizedDescription
                )
            default:
                break
            }
        }
        return fileTransferFailureLine(
            phase: "unknown",
            category: "payload_framing",
            error: error.localizedDescription
        )
    }

    private nonisolated static func fileTransferFailureLine(
        phase: String,
        category: String,
        error: String,
        extraFields: String = ""
    ) -> String {
        "failed stage=file-transfer phase=\(Self.sanitize(phase)) category=\(Self.sanitize(category))\(extraFields) error=\(Self.sanitize(error))"
    }

    private nonisolated static func fileTransferFailureCategory(forNetworkStage stage: String) -> String {
        let normalized = stage.lowercased()
        if normalized.contains("secure_channel")
            || normalized.contains("encryption")
            || normalized.contains("decrypt") {
            return "secure_channel"
        }
        if normalized.contains("secure_session")
            || normalized.contains("security")
            || normalized.contains("permission")
            || normalized.contains("signed_kem") {
            return "auth_policy"
        }
        if normalized.contains("connect")
            || normalized.contains("handshake") {
            return "handshake"
        }
        if normalized.contains("route")
            || normalized.contains("discovery")
            || normalized.contains("destination") {
            return "discovery"
        }
        return "payload_framing"
    }

    private nonisolated static func remoteDesktopFailureLine(for error: Error) -> String {
        let nsError = error as NSError
        let message = error.localizedDescription
        let normalized = message.lowercased()
        let phase: String
        if nsError.domain == "SkyBridge.Smoke", nsError.code == 1200 {
            phase = "performance_window_timeout"
        } else if nsError.domain == "SkyBridge.Smoke", nsError.code == 1201 {
            phase = "media_main_path_error"
        } else if normalized.contains("timeout") || message.contains("超时") {
            phase = "performance_window_timeout"
        } else if normalized.contains("already_connected") {
            phase = "already_connected"
        } else if normalized.contains("media") || message.contains("媒体主路径") {
            phase = "media_main_path_error"
        } else {
            phase = "remote_desktop_error"
        }
        return "failed stage=remote-desktop phase=\(phase) domain=\(Self.sanitize(nsError.domain)) code=\(nsError.code) error=\(Self.sanitize(message))"
    }

}
#endif
