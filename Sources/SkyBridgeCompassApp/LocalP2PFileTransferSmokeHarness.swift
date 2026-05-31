import AppKit
import CryptoKit
import Darwin
import Foundation
import SkyBridgeCore
import SkyBridgeSmokeSupport

@available(macOS 14.0, *)
@MainActor
final class LocalP2PFileTransferSmokeHarness {
    private struct MacInitiatedReconnectSmokeResult {
        let route: String
        let controlReconnect: Bool
    }

    private var didStart = false
    private lazy var fileTransferManager = FileTransferManager.shared
    private let runStartedAt = Date()

    var isEnabledForCurrentEnvironment: Bool {
        role == "mac-p2p-host"
    }

    private var role: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var expectsFileTransferSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_FILE_TRANSFER"] == "1"
    }

    private var requiresMacInitiatedReconnectSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_MAC_INITIATED_RECONNECT"] == "1"
    }

    private var expectedHandshakeSuite: String {
        environmentValue("SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE") ?? "X-Wing"
    }

    private var fileTransferRunID: String {
        environmentValue("SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID") ?? "default"
    }

    func startIfNeeded() async {
        guard isEnabledForCurrentEnvironment, !didStart else { return }
        didStart = true

        let reporter = LocalP2PSmokeStatusReporter(statusURL: statusURL())
        reporter.reset()
        reporter.append("boot role=mac-p2p-host")

        do {
            try await prepareHost(reporter: reporter)
        } catch {
            reporter.append("failed stage=host-start error=\(Self.sanitize(error.localizedDescription))")
            terminateIfNeeded()
            return
        }

        monitorPresence(reporter: reporter)
    }

    private func prepareHost(reporter: LocalP2PSmokeStatusReporter) async throws {
        let inboundDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/SkyBridgeInteropInbox", isDirectory: true)
        fileTransferManager.setReceiveBaseDirectory(inboundDirectory)

        reporter.append("identity start storage=signed-app-keychain")
        _ = try await DeviceIdentityKeyManager.shared.getOrCreateIdentityKey()
        let protocolDeviceId = await SelfIdentityProvider.shared.protocolIdentityDeviceId(allowCreate: true)
        reporter.append("identity ready device=\(Self.sanitize(protocolDeviceId))")

        reporter.append("services start")
        try await LocalPeerServiceCoordinator.shared.ensureHealthy()
        try await exportLocalPQCIdentityIfRequested(reporter: reporter)

        let endpoints = ServiceEndpointRegistry.shared.snapshot()
        reporter.append(
            """
            ready discovery=_skybridge._tcp transfer=\(endpoints.fileTransferPort.map(String.init) ?? "-") \
            remote=\(endpoints.remoteControlPort.map(String.init) ?? "-") inbox=\(Self.sanitize(inboundDirectory.path))
            """
        )
    }

    private func monitorPresence(reporter: LocalP2PSmokeStatusReporter) {
        let timeoutSeconds = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 90
        let expectsPQCRekey = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let expectedNormalizedSuite = expectedHandshakeSuite.uppercased()

        Task { @MainActor in
            var lastSuite = ""
            var lastRekey = ""
            var sawClassicHandshake = false
            var sawRekey = false
            var inferredRekeyLogged = false
            var suiteStableSince: Date?

            while Date() < deadline {
                let newestConnection = ConnectionPresenceService.shared.activeConnections
                    .filter { $0.connectedAt >= runStartedAt }
                    .sorted { $0.connectedAt > $1.connectedAt }
                    .first

                if let newestConnection {
                    let suite = newestConnection.suite.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !suite.isEmpty, suite != lastSuite {
                        lastSuite = suite
                        suiteStableSince = Date()
                        reporter.append(
                            "suite peer=\(Self.sanitize(newestConnection.id)) suite=\(Self.sanitize(suite))"
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
                    .filter { $0.startedAt >= runStartedAt }
                    .sorted { $0.startedAt > $1.startedAt }
                    .first
                if let newestRekey {
                    let description = "\(newestRekey.fromSuite)->\(newestRekey.toSuite)"
                    if description != lastRekey {
                        lastRekey = description
                        sawRekey = true
                        reporter.append(
                            "rekey \(Self.sanitize(newestRekey.fromSuite)) -> \(Self.sanitize(newestRekey.toSuite))"
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
                            await finishHandshake(
                                newestConnection,
                                suiteLabel: "X-Wing",
                                successSuffix: "bootstrapRekey=1",
                                reporter: reporter
                            )
                            return
                        }
                    } else if normalizedSuite == expectedNormalizedSuite,
                              !sawRekey,
                              let stableSince = suiteStableSince,
                              Date().timeIntervalSince(stableSince) >= 1.0 {
                        await finishHandshake(
                            newestConnection,
                            suiteLabel: newestConnection.suite,
                            successSuffix: "handshakeOnly=1",
                            reporter: reporter
                        )
                        return
                    }
                }

                try? await Task.sleep(for: .milliseconds(250))
            }

            reporter.append("failed stage=timeout error=mac_p2p_file_transfer_smoke_timeout")
            terminateIfNeeded()
        }
    }

    private func finishHandshake(
        _ connection: ConnectionPresenceService.ActiveConnection,
        suiteLabel: String,
        successSuffix: String,
        reporter: LocalP2PSmokeStatusReporter
    ) async {
        guard expectsFileTransferSmoke else {
            reporter.append(
                "success peer=\(Self.sanitize(connection.id)) suite=\(Self.sanitize(suiteLabel)) \(successSuffix)"
            )
            terminateIfNeeded()
            return
        }

        do {
            let peer = try await performBidirectionalFileTransferSmoke(reporter: reporter)
            let reconnectResult: MacInitiatedReconnectSmokeResult?
            if requiresMacInitiatedReconnectSmoke {
                reconnectResult = try await performMacInitiatedReconnectSmoke(peer: peer, reporter: reporter)
            } else {
                reconnectResult = nil
            }
            let reconnectSuffix: String
            if let reconnectResult {
                reconnectSuffix = " macInitiatedTransfer=1 macReconnect=\(reconnectResult.controlReconnect ? 1 : 0) macReconnectControl=\(reconnectResult.controlReconnect ? 1 : 0) macReconnectRoute=\(Self.sanitize(reconnectResult.route))"
            } else {
                reconnectSuffix = " macInitiatedTransfer=0 macReconnect=0 macReconnectControl=0 macReconnectRoute=none"
            }
            reporter.append(
                """
                success peer=\(Self.sanitize(connection.id)) suite=\(Self.sanitize(suiteLabel)) \
                \(successSuffix) fileTransfer=1\(reconnectSuffix)
                """
            )
        } catch {
            reporter.append(Self.fileTransferFailureLine(for: error))
        }
        terminateIfNeeded()
    }

    private func exportLocalPQCIdentityIfRequested(
        reporter: LocalP2PSmokeStatusReporter
    ) async throws {
        guard let reportURL = pqcReportURL() else { return }

        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        let deviceId = await DeviceIdentityKeyManager.shared.getDeviceId()
        let keys = try await DeviceIdentityKeyManager.shared.pairingIdentityKEMPublicKeys(
            using: provider
        )
        let report = LocalP2PSmokePQCReport(
            deviceId: deviceId,
            keys: keys.map { key in
                LocalP2PSmokePQCReport.PublicKeyEntry(
                    suiteWireId: key.suiteWireId,
                    publicKeyBase64: key.publicKey.base64EncodedString()
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try LocalP2PSmokeFiles.writeProtectedData(data, to: reportURL)
        reporter.append(
            "pqc-report device=\(Self.sanitize(deviceId)) keys=\(report.keys.count) file=\(Self.sanitize(reportURL.lastPathComponent))"
        )
    }

    private func performBidirectionalFileTransferSmoke(
        reporter: LocalP2PSmokeStatusReporter
    ) async throws -> LocalP2PSmokePeerContext {
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
        try validateSmokePayload(
            at: URL(fileURLWithPath: inboundPath),
            expectedRole: "ios",
            fileName: inboundName
        )
        let inboundHash = try Self.sha256Hex(url: URL(fileURLWithPath: inboundPath))
        reporter.append("file-transfer inbound-complete name=\(Self.sanitize(inboundName)) sha256=\(inboundHash)")

        let outboundURL = try makeSmokeTransferFile(
            fileName: outboundName,
            contents: """
            role=mac
            run=\(fileTransferRunID)
            sentAt=\(ISO8601DateFormatter().string(from: Date()))
            """
        )
        let outboundHash = try Self.sha256Hex(url: outboundURL)
        reporter.append("file-transfer outbound-start name=\(Self.sanitize(outboundName))")
        let targetDeviceId = Self.stableBonjourTargetDeviceId(inboundTransfer.deviceId)
        if let route = await LocalP2PBonjourFileTransferRouteResolver().resolve(
            targetDeviceId: targetDeviceId,
            preferredName: inboundTransfer.deviceName,
            timeoutSeconds: 6.0
        ) {
            reporter.append(
                "file-transfer outbound-route-probe source=bonjour-transfer device=\(Self.sanitize(route.deviceId ?? inboundTransfer.deviceId)) host=\(Self.sanitize(route.host)) port=\(route.port)"
            )
        } else {
            reporter.append(
                "file-transfer outbound-route-probe missing device=\(Self.sanitize(inboundTransfer.deviceId))"
            )
        }

        try await fileTransferManager.sendFileToActivePeer(
            at: outboundURL,
            matchingPeerIds: [
                inboundTransfer.deviceId,
                targetDeviceId
            ].compactMap { $0 },
            preferredDeviceName: inboundTransfer.deviceName
        )
        reporter.append("file-transfer outbound-complete name=\(Self.sanitize(outboundName)) sha256=\(outboundHash)")

        return LocalP2PSmokePeerContext(
            deviceId: inboundTransfer.deviceId,
            deviceName: inboundTransfer.deviceName
        )
    }

    private func performMacInitiatedReconnectSmoke(
        peer: LocalP2PSmokePeerContext,
        reporter: LocalP2PSmokeStatusReporter
    ) async throws -> MacInitiatedReconnectSmokeResult {
        let outboundName = "mac-reconnect-smoke-\(fileTransferRunID).txt"
        reporter.append(
            "mac-reconnect discovery-start peer=\(Self.sanitize(peer.deviceId)) name=\(Self.sanitize(peer.deviceName ?? "-"))"
        )

        _ = P2PDiscoveryService.shared.disconnectFromDevice(peer.deviceId)
        try await Task.sleep(for: .seconds(2))

        if let target = try await waitForReconnectTarget(peer: peer, timeoutSeconds: 30) {
            do {
                let controlResult = try await performMacInitiatedControlReconnectTransfer(
                    peer: peer,
                    target: target,
                    outboundName: outboundName,
                    reporter: reporter
                )
                return controlResult
            } catch {
                guard Self.shouldFallbackToTransferRouteAfterControlReconnectFailure(error) else {
                    throw error
                }
                reporter.append(
                    """
                    mac-reconnect control-connect-unavailable \
                    phase=\(Self.sanitizePhase(Self.fileTransferFailurePhase(for: error))) \
                    peer=\(Self.sanitize(peer.deviceId)) error=\(Self.sanitize(error.localizedDescription))
                    """
                )
                let transferRouteResult = try await performMacInitiatedTransferRouteReconnect(
                    peer: peer,
                    outboundName: outboundName,
                    reporter: reporter
                )
                return transferRouteResult
            }
        }

        reporter.append(
            "mac-reconnect control-discovery-timeout peer=\(Self.sanitize(peer.deviceId))"
        )
        return try await performMacInitiatedTransferRouteReconnect(
            peer: peer,
            outboundName: outboundName,
            reporter: reporter
        )
    }

    private func performMacInitiatedControlReconnectTransfer(
        peer: LocalP2PSmokePeerContext,
        target: DiscoveredDevice,
        outboundName: String,
        reporter: LocalP2PSmokeStatusReporter
    ) async throws -> MacInitiatedReconnectSmokeResult {
        reporter.append(
            """
            mac-reconnect target id=\(target.id.uuidString) deviceId=\(Self.sanitize(target.deviceId ?? "-")) \
            unique=\(Self.sanitize(target.uniqueIdentifier ?? "-")) name=\(Self.sanitize(target.name))
            """
        )
        reporter.append("mac-reconnect connect-start")
        try await connectToDeviceForMacReconnect(target, peer: peer, reporter: reporter)
        reporter.append("mac-reconnect connected")

        let outboundURL = try makeSmokeTransferFile(
            fileName: outboundName,
            contents: """
            role=mac-reconnect
            run=\(fileTransferRunID)
            sentAt=\(ISO8601DateFormatter().string(from: Date()))
            target=\(target.deviceId ?? target.uniqueIdentifier ?? target.id.uuidString)
            """
        )
        let outboundHash = try Self.sha256Hex(url: outboundURL)
        let reconnectPeerIds = Self.reconnectPeerIds(peer: peer, target: target)
        let routeProbe = await waitForActiveRouteProbe(
            matchingPeerIds: reconnectPeerIds,
            preferredDeviceName: target.name,
            timeoutSeconds: 15.0,
            disallowedRouteSource: "presence:inbound"
        )
        if let routeProbe {
            reporter.append(
                """
                mac-reconnect outbound-route-probe source=\(Self.sanitize(routeProbe.routeSource)) \
                device=\(Self.sanitize(routeProbe.deviceId)) host=\(Self.sanitize(routeProbe.ipAddress)) port=\(routeProbe.port)
                """
            )
            if routeProbe.routeSource == "presence:inbound" {
                throw NSError(
                    domain: "SkyBridge.Smoke",
                    code: 2011,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Mac 重连后的首选文件路由仍是旧 inbound presence，拒绝伪通过"
                    ]
                )
            }
        } else {
            reporter.append("mac-reconnect outbound-route-probe missing")
        }

        try await fileTransferManager.sendFileToActivePeer(
            at: outboundURL,
            matchingPeerIds: reconnectPeerIds,
            preferredDeviceName: target.name
        )
        reporter.append("mac-reconnect outbound-complete name=\(Self.sanitize(outboundName)) sha256=\(outboundHash)")
        return MacInitiatedReconnectSmokeResult(
            route: "control:\(routeProbe?.routeSource ?? "active-peer")",
            controlReconnect: true
        )
    }

    private func connectToDeviceForMacReconnect(
        _ target: DiscoveredDevice,
        peer: LocalP2PSmokePeerContext,
        reporter: LocalP2PSmokeStatusReporter
    ) async throws {
        let maxAttempts = 6
        var lastAlreadyConnected: Error?
        for attempt in 1...maxAttempts {
            do {
                try await P2PDiscoveryService.shared.connectToDevice(target)
                return
            } catch {
                guard Self.isAlreadyConnectedHandshakeRejection(error) else {
                    throw error
                }
                lastAlreadyConnected = error
                reporter.append(
                    """
                    mac-reconnect already-connected \
                    peer=\(Self.sanitize(peer.deviceId)) action=wait-remote-cleanup attempt=\(attempt)
                    """
                )
                if attempt < maxAttempts {
                    try await Task.sleep(for: .seconds(2))
                }
            }
        }
        throw lastAlreadyConnected ?? HandshakeError.failed(.peerRejected(message: "already_connected"))
    }

    private func performMacInitiatedTransferRouteReconnect(
        peer: LocalP2PSmokePeerContext,
        outboundName: String,
        reporter: LocalP2PSmokeStatusReporter
    ) async throws -> MacInitiatedReconnectSmokeResult {
        guard let stablePeerDeviceId = Self.stableBonjourTargetDeviceId(peer.deviceId) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 2012,
                userInfo: [
                    NSLocalizedDescriptionKey: "Mac 主动回连缺少稳定 iOS deviceId，拒绝使用弱 Bonjour/name 路由: \(peer.deviceId)"
                ]
            )
        }

        reporter.append(
            "mac-reconnect transfer-route-discovery-start device=\(Self.sanitize(stablePeerDeviceId)) name=\(Self.sanitize(peer.deviceName ?? "-"))"
        )
        guard let transferRoute = await LocalP2PBonjourFileTransferRouteResolver().resolve(
            targetDeviceId: stablePeerDeviceId,
            preferredName: nil,
            timeoutSeconds: 12.0
        ) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 2013,
                userInfo: [
                    NSLocalizedDescriptionKey: "Mac 主动回连未发现带稳定 deviceId 的 iOS 文件传输路由: \(stablePeerDeviceId)"
                ]
            )
        }

        let routeDeviceId = transferRoute.deviceId ?? stablePeerDeviceId
        reporter.append(
            """
            mac-reconnect transfer-route-target source=bonjour-transfer \
            device=\(Self.sanitize(routeDeviceId)) host=\(Self.sanitize(transferRoute.host)) \
            port=\(transferRoute.port) name=\(Self.sanitize(transferRoute.name))
            """
        )

        let outboundURL = try makeSmokeTransferFile(
            fileName: outboundName,
            contents: """
            role=mac-reconnect
            run=\(fileTransferRunID)
            sentAt=\(ISO8601DateFormatter().string(from: Date()))
            target=\(peer.deviceId)
            routeSource=bonjour-transfer
            """
        )
        let outboundHash = try Self.sha256Hex(url: outboundURL)
        reporter.append(
            """
            mac-reconnect outbound-route-probe source=bonjour-transfer \
            device=\(Self.sanitize(routeDeviceId)) host=\(Self.sanitize(transferRoute.host)) port=\(transferRoute.port)
            """
        )
        try await fileTransferManager.sendFile(
            at: outboundURL,
            to: peer.deviceId,
            deviceName: transferRoute.name,
            ipAddress: transferRoute.host,
            port: transferRoute.port
        )
        reporter.append("mac-reconnect outbound-complete name=\(Self.sanitize(outboundName)) sha256=\(outboundHash)")
        return MacInitiatedReconnectSmokeResult(route: "bonjour-transfer", controlReconnect: false)
    }

    private func waitForActiveRouteProbe(
        matchingPeerIds peerIds: [String],
        preferredDeviceName: String?,
        timeoutSeconds: TimeInterval,
        disallowedRouteSource: String? = nil
    ) async -> FileTransferManager.ActivePeerRoute? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastDisallowedRoute: FileTransferManager.ActivePeerRoute?
        while Date() < deadline {
            let route = await fileTransferManager.resolveActivePeerRoutes(
                matchingPeerIds: peerIds,
                preferredDeviceName: preferredDeviceName
            ).first
            if let route {
                if let disallowedRouteSource, route.routeSource == disallowedRouteSource {
                    lastDisallowedRoute = route
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                return route
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return lastDisallowedRoute
    }

    private func waitForReconnectTarget(
        peer: LocalP2PSmokePeerContext,
        timeoutSeconds: TimeInterval
    ) async throws -> DiscoveredDevice? {
        P2PDiscoveryService.shared.startDiscovery()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let target = Self.bestReconnectTarget(
                from: P2PDiscoveryService.shared.discoveredDevices,
                peer: peer
            ) {
                return target
            }
            await P2PDiscoveryService.shared.refreshDevices()
            try? await Task.sleep(for: .milliseconds(750))
        }
        return nil
    }

    private func makeSmokeTransferFile(fileName: String, contents: String) throws -> URL {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SkyBridgeSmokeTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory.appendingPathComponent(fileName, isDirectory: false)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func waitForCompletedTransfer(
        fileName: String,
        direction: TransferDirection,
        timeoutSeconds: TimeInterval
    ) async throws -> FileTransfer {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let transfer = fileTransferManager.transferHistory.first(where: { transfer in
                let finishedAt = transfer.completedAt ?? transfer.createdAt
                return transfer.fileName == fileName
                    && transfer.status == .completed
                    && transfer.direction == direction
                    && finishedAt >= runStartedAt
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

    private static func fileTransferFailureLine(for error: Error) -> String {
        let phase = fileTransferFailurePhase(for: error)
        let category = fileTransferFailureCategory(for: error, phase: phase)
        return "failed stage=file-transfer phase=\(sanitizePhase(phase)) category=\(sanitizePhase(category)) error=\(sanitize(error.localizedDescription))"
    }

    private static func fileTransferFailureCategory(for error: Error, phase: String) -> String {
        let normalizedPhase = phase.lowercased()
        if error is P2PDiscoveryError {
            return "discovery"
        }
        if let transferError = error as? FileTransferError {
            switch transferError {
            case .secureSessionRequired, .securityThreatDetected, .receiverNotConfirmed, .receiverRejected:
                return "auth_policy"
            case .invalidHeader,
                 .inboundInvalidInitialHeader,
                 .integrityCheckFailed,
                 .transferCancelled,
                 .connectionClosed,
                 .inboundConnectionClosedBeforeMetadata,
                 .fileNotFound,
                 .timeout,
                 .receiptWaitFailed:
                return "payload_framing"
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

    private static func fileTransferFailurePhase(for error: Error) -> String {
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

    private static func shouldFallbackToTransferRouteAfterControlReconnectFailure(_ error: Error) -> Bool {
        guard let discoveryError = error as? P2PDiscoveryError else { return false }
        if case .noConnectableEndpoint = discoveryError {
            return true
        }
        return false
    }

    private static func isAlreadyConnectedHandshakeRejection(_ error: Error) -> Bool {
        guard let handshakeError = error as? HandshakeError,
              case .failed(.peerRejected(let message)) = handshakeError else {
            return false
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines) == "already_connected"
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

    private func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func terminateIfNeeded() {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_AUTO_EXIT"] == "1" else { return }
        NSApp.terminate(nil)
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

    private static func reconnectPeerIds(
        peer: LocalP2PSmokePeerContext,
        target: DiscoveredDevice
    ) -> [String] {
        let stableInboundPeerId = stableBonjourTargetDeviceId(peer.deviceId)
        let stableTargetDeviceId = stableBonjourTargetDeviceId(target.deviceId ?? "")
        let candidates: [String?] = [
            stableInboundPeerId,
            stableTargetDeviceId,
            target.uniqueIdentifier,
            target.id.uuidString
        ]
        return candidates.compactMap { raw -> String? in
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }
    }

    private static func bestReconnectTarget(
        from devices: [DiscoveredDevice],
        peer: LocalP2PSmokePeerContext
    ) -> DiscoveredDevice? {
        let peerAliases = Set(
            reconnectAliasCandidates(for: peer.deviceId)
                + reconnectAliasCandidates(for: stableBonjourTargetDeviceId(peer.deviceId))
        )
        let name = normalizedDeviceName(peer.deviceName)
        let eligible = devices.filter { !$0.isLocalDevice }

        let idMatches = eligible.filter { device in
            !peerAliases.isDisjoint(with: reconnectAliasCandidates(for: device.deviceId)
                + reconnectAliasCandidates(for: device.uniqueIdentifier)
                + reconnectAliasCandidates(for: device.id.uuidString)
                + reconnectAliasCandidates(for: device.ipv4)
                + reconnectAliasCandidates(for: device.ipv6))
        }
        if let match = preferredConnectableDevice(from: idMatches) {
            return match
        }

        guard peerAliases.isEmpty else {
            return nil
        }

        guard let name else { return nil }
        let nameMatches = eligible.filter { normalizedDeviceName($0.name) == name }
        return preferredConnectableDevice(from: nameMatches)
    }

    private static func preferredConnectableDevice(from devices: [DiscoveredDevice]) -> DiscoveredDevice? {
        devices
            .sorted { left, right in
                let leftScore = reconnectTargetScore(left)
                let rightScore = reconnectTargetScore(right)
                if leftScore != rightScore { return leftScore > rightScore }
                return left.name < right.name
            }
            .first
    }

    private static func reconnectTargetScore(_ device: DiscoveredDevice) -> Int {
        var score = 0
        if device.services.contains("_skybridge._tcp") { score += 100 }
        if device.portMap["_skybridge._tcp"] != nil { score += 50 }
        if device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { score += 25 }
        if device.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { score += 10 }
        if device.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { score += 5 }
        if device.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { score += 5 }
        return score
    }

    private static func reconnectAliasCandidates(for raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return []
        }

        var values: [String] = []
        func append(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return
            }
            values.append(value.lowercased())
        }

        append(raw)
        let lowered = raw.lowercased()
        if lowered.hasPrefix("id:") {
            append(String(raw.dropFirst(3)))
        } else {
            append("id:\(raw)")
        }
        if lowered.hasPrefix("recent:") {
            append(String(raw.dropFirst("recent:".count)))
        }
        if lowered.hasPrefix("host:") {
            append(String(raw.dropFirst("host:".count)).split(separator: "%", maxSplits: 1).first.map(String.init))
        } else if raw.contains(":") || raw.split(separator: ".").count == 4 {
            append("host:\(raw)")
            append("host:\(raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw)")
        }
        return Array(Set(values))
    }

    private static func normalizedDeviceName(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        for suffix in [" 📱", " 🍎"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value.lowercased()
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func sanitizePhase(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                return String(scalar)
            }
            return "_"
        }
        let sanitized = scalars.joined().trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return sanitized.isEmpty ? "mac_smoke_unclassified" : sanitized
    }
}

private struct LocalP2PSmokePeerContext {
    let deviceId: String
    let deviceName: String?
}

private struct LocalP2PSmokePQCReport: Encodable {
    struct PublicKeyEntry: Encodable {
        let suiteWireId: UInt16
        let publicKeyBase64: String
    }

    let deviceId: String
    let keys: [PublicKeyEntry]
}

private struct LocalP2PSmokeStatusReporter {
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

private enum LocalP2PSmokeFiles {
    static func writeProtectedData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

private struct LocalP2PBonjourFileTransferRoute {
    let name: String
    let host: String
    let port: Int
    let deviceId: String?
    let platform: String?
}

@available(macOS 14.0, *)
@MainActor
private final class LocalP2PBonjourFileTransferRouteResolver: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let serviceType = "_skybridge-transfer._tcp."
    private let serviceDomain = "local."
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var candidates: [LocalP2PBonjourFileTransferRoute] = []
    private var continuation: CheckedContinuation<LocalP2PBonjourFileTransferRoute?, Never>?
    private var targetDeviceId: String?
    private var preferredName: String?
    private var finished = false

    func resolve(
        targetDeviceId: String?,
        preferredName: String?,
        timeoutSeconds: TimeInterval
    ) async -> LocalP2PBonjourFileTransferRoute? {
        self.targetDeviceId = Self.normalizedDeviceId(targetDeviceId)
        self.preferredName = Self.trimmedNonEmpty(preferredName)?.lowercased()

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

    private func makeRoute(from service: NetService) -> LocalP2PBonjourFileTransferRoute? {
        let txt = service.txtRecordData().map(Self.parseTXTRecord(_:)) ?? [:]
        let advertisedPort = Self.intValue(
            txt["fileTransferPort"] ?? txt["transferPort"] ?? txt["file_transfer_port"] ?? txt["port"]
        )
        let port = service.port > 0 ? service.port : advertisedPort
        guard (1...65535).contains(port) else { return nil }

        let host = Self.trimmedNonEmpty(service.hostName)
            ?? Self.firstUsableAddress(from: service.addresses)
        guard let host, !host.isEmpty else { return nil }

        let deviceId = txt["deviceId"] ?? txt["id"] ?? txt["deviceID"] ?? txt["device_id"]
        let name = txt["name"] ?? txt["device"] ?? service.name
        let platform = txt["platform"] ?? txt["os"]
        return LocalP2PBonjourFileTransferRoute(
            name: Self.trimmedNonEmpty(name) ?? service.name,
            host: host,
            port: port,
            deviceId: Self.trimmedNonEmpty(deviceId),
            platform: Self.trimmedNonEmpty(platform)
        )
    }

    private func bestCandidate() -> LocalP2PBonjourFileTransferRoute? {
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

    private func finish(with route: LocalP2PBonjourFileTransferRoute?) {
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
        guard var value = trimmedNonEmpty(raw)?.lowercased() else {
            return nil
        }
        if value.hasPrefix("id:") {
            value.removeFirst("id:".count)
        }
        return value
    }

    private static func intValue(_ raw: String?) -> Int {
        guard let raw = trimmedNonEmpty(raw) else { return 0 }
        return Int(raw) ?? 0
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
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
