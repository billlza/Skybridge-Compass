import XCTest
import Network
import CryptoKit
@testable import SkyBridgeCore

@MainActor
final class FileTransferManagerSecurityTests: XCTestCase {
    func testResumeTransferOnlyUnpausesActiveTransfer() async {
        let manager = FileTransferManager()
        let transfer = FileTransfer(
            id: UUID().uuidString,
            fileName: "report.txt",
            fileSize: 1024,
            deviceId: "peer-device",
            direction: .outgoing,
            status: .paused
        )
        manager.activeTransfers[transfer.id] = transfer

        await manager.resumeTransfer(UUID(uuidString: transfer.id)!)

        XCTAssertEqual(manager.activeTransfers[transfer.id]?.status, .transferring)
    }

    func testClassicTransferPeerResolutionPrefersDeclaredSenderDeviceId() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: "id:trusted-peer",
            endpointHostOrIP: "192.168.31.20",
            peerLabel: "MacBook Pro",
            transferId: "transfer-1"
        )
        let peers = [
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:trusted-peer",
                resolvedPeerDeviceId: "id:trusted-peer",
                aliases: ["id:trusted-peer", "trusted-peer", "host:192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: [ClassicTransferCapability.classicResume]
            ),
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:other-peer",
                resolvedPeerDeviceId: "id:other-peer",
                aliases: ["id:other-peer", "other-peer"],
                endpointHostOrIP: "192.168.31.30",
                capabilities: []
            )
        ]

        let resolved = ClassicTransferPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertEqual(resolved?.matchDeviceId, "id:trusted-peer")
        XCTAssertEqual(resolved?.matchedBy, .declaredSenderDeviceId)
        XCTAssertTrue(resolved?.supportsClassicResume == true)
    }

    func testClassicTransferPeerResolutionFallsBackToEndpointHostOrIP() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: "host:stale-peer",
            endpointHostOrIP: "192.168.31.20",
            peerLabel: "MacBook Pro",
            transferId: "transfer-2"
        )
        let peers = [
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:trusted-peer",
                resolvedPeerDeviceId: "id:trusted-peer",
                aliases: ["id:trusted-peer", "trusted-peer", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            )
        ]

        let resolved = ClassicTransferPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertEqual(resolved?.matchDeviceId, "id:trusted-peer")
        XCTAssertEqual(resolved?.matchedBy, .endpointHostOrIP)
    }

    func testClassicTransferPeerResolutionDoesNotGuessWhenMultiplePeersMatchEndpoint() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: nil,
            endpointHostOrIP: "192.168.31.20",
            peerLabel: "MacBook Pro",
            transferId: "transfer-3"
        )
        let peers = [
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:peer-a",
                resolvedPeerDeviceId: "id:peer-a",
                aliases: ["id:peer-a", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            ),
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:peer-b",
                resolvedPeerDeviceId: "id:peer-b",
                aliases: ["id:peer-b", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            )
        ]

        let resolved = ClassicTransferPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertNil(resolved)
    }

    func testClassicTransferPeerResolutionDoesNotUseSingleFallbackWhenHintsMismatch() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: "id:offline-ios",
            endpointHostOrIP: "192.168.31.20",
            peerLabel: "iPhone",
            transferId: "transfer-mismatch"
        )
        let peers = [
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:stale-mac",
                resolvedPeerDeviceId: "id:stale-mac",
                aliases: ["id:stale-mac", "host:10.0.0.44", "10.0.0.44"],
                endpointHostOrIP: "10.0.0.44",
                capabilities: []
            )
        ]

        let resolved = ClassicTransferPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertNil(
            resolved,
            "Outgoing file transfer must not reuse the only authenticated session when the selected device/id/address hints point elsewhere."
        )
    }

    func testClassicTransferPeerResolutionRequiresExplicitPeerEvidenceEvenWithSingleAuthenticatedPeer() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: nil,
            endpointHostOrIP: nil,
            peerLabel: "iPad",
            transferId: "transfer-no-hints"
        )
        let peers = [
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:only-peer",
                resolvedPeerDeviceId: "id:only-peer",
                aliases: ["id:only-peer", "only-peer", "host:192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: [ClassicTransferCapability.classicResume]
            )
        ]

        let resolved = ClassicTransferPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertNil(
            resolved,
            "Classic file transfer must fail closed when metadata provides no sender id or endpoint evidence; a single authenticated connection is not enough to guess the target."
        )
    }

    func testClassicTransferRegistryRemovesSessionSnapshotsByPeerKeys() async {
        let sessionId = "registry-session-\(UUID().uuidString)"
        let registry = ClassicTransferSessionRegistry.shared
        await registry.remove(sessionId: sessionId)
        defer {
            Task {
                await registry.remove(sessionId: sessionId)
            }
        }

        let snapshot = ClassicTransferSessionSnapshot(
            sessionId: sessionId,
            matchDeviceId: "id:ios-peer",
            resolvedPeerDeviceId: "id:ios-peer",
            aliases: ["id:ios-peer", "ios-peer", "host:192.168.31.20", "192.168.31.20"],
            endpointHostOrIP: "192.168.31.20",
            capabilities: [],
            sessionKeys: Self.mockSessionKeys(sessionId: sessionId)
        )

        await registry.upsert(session: snapshot)
        var sessions = await registry.activeSessions()
        XCTAssertTrue(sessions.contains(where: { $0.sessionId == sessionId }))

        await registry.remove(peerKeys: ["id:ios-peer"])

        sessions = await registry.activeSessions()
        XCTAssertFalse(
            sessions.contains(where: { $0.sessionId == sessionId }),
            "Disconnect cleanup must remove detached classic session snapshots as well as live P2PConnection indexes."
        )
    }

    func testClassicTransferRegistryReturnsNewestLiveSnapshotAndPrunesStaleOnes() async {
        let oldSessionId = "registry-old-\(UUID().uuidString)"
        let freshSessionId = "registry-fresh-\(UUID().uuidString)"
        let staleSessionId = "registry-stale-\(UUID().uuidString)"
        let registry = ClassicTransferSessionRegistry.shared
        await registry.remove(sessionId: oldSessionId)
        await registry.remove(sessionId: freshSessionId)
        await registry.remove(sessionId: staleSessionId)
        defer {
            Task {
                await registry.remove(sessionId: oldSessionId)
                await registry.remove(sessionId: freshSessionId)
                await registry.remove(sessionId: staleSessionId)
            }
        }

        let now = Date()
        let oldSnapshot = ClassicTransferSessionSnapshot(
            sessionId: oldSessionId,
            matchDeviceId: "id:ios-peer",
            resolvedPeerDeviceId: "id:ios-peer",
            aliases: ["id:ios-peer", "host:192.168.31.20", "192.168.31.20"],
            endpointHostOrIP: "192.168.31.20",
            capabilities: ["fileTransferPort=8080"],
            sessionKeys: Self.mockSessionKeys(sessionId: oldSessionId),
            lastSeenAt: now.addingTimeInterval(-30)
        )
        let freshSnapshot = ClassicTransferSessionSnapshot(
            sessionId: freshSessionId,
            matchDeviceId: "id:ios-peer",
            resolvedPeerDeviceId: "id:ios-peer",
            aliases: ["id:ios-peer", "host:192.168.31.20", "192.168.31.20"],
            endpointHostOrIP: "192.168.31.20",
            capabilities: ["fileTransferPort=8080"],
            sessionKeys: Self.mockSessionKeys(sessionId: freshSessionId),
            lastSeenAt: now
        )
        let staleSnapshot = ClassicTransferSessionSnapshot(
            sessionId: staleSessionId,
            matchDeviceId: "id:ios-peer",
            resolvedPeerDeviceId: "id:ios-peer",
            aliases: ["id:ios-peer", "host:192.168.31.20", "192.168.31.20"],
            endpointHostOrIP: "192.168.31.20",
            capabilities: ["fileTransferPort=8080"],
            sessionKeys: Self.mockSessionKeys(sessionId: staleSessionId),
            lastSeenAt: now.addingTimeInterval(-(ClassicTransferSessionRegistry.sessionSnapshotTimeToLive + 1))
        )

        await registry.upsert(session: oldSnapshot)
        await registry.upsert(session: freshSnapshot)
        await registry.upsert(session: staleSnapshot)

        let sessions = await registry.activeSessions(now: now)

        XCTAssertEqual(sessions.first?.sessionId, freshSessionId)
        XCTAssertTrue(sessions.contains(where: { $0.sessionId == oldSessionId }))
        XCTAssertFalse(sessions.contains(where: { $0.sessionId == staleSessionId }))
    }

    func testClassicTransferSessionSourceResolutionPrefersFreshLiveConnectionOverOlderSnapshot() {
        let transferId = "transfer-\(UUID().uuidString)"
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: "id:ios-peer",
            endpointHostOrIP: "fe80::bc:dca9:7759:5a45%en0",
            peerLabel: "iPhone",
            transferId: transferId
        )
        let now = Date()
        let staleKey = SymmetricKey(data: Data(repeating: 0x41, count: 32))
        let freshKey = SymmetricKey(data: Data(repeating: 0x7A, count: 32))
        let aliases = [
            "id:ios-peer",
            "ios-peer",
            "host:fe80::bc:dca9:7759:5a45%en0",
            "fe80::bc:dca9:7759:5a45%en0"
        ]
        let staleSnapshot = ClassicTransferAuthenticatedSessionSource(
            candidate: .init(
                matchDeviceId: "id:ios-peer",
                resolvedPeerDeviceId: "id:ios-peer",
                aliases: aliases,
                endpointHostOrIP: "fe80::bc:dca9:7759:5a45%en0",
                capabilities: ["fileTransferPort=8080"]
            ),
            transferKey: staleKey,
            lastSeenAt: now.addingTimeInterval(-30),
            sourceKind: .sessionSnapshot
        )
        let freshLiveConnection = ClassicTransferAuthenticatedSessionSource(
            candidate: .init(
                matchDeviceId: "id:ios-peer",
                resolvedPeerDeviceId: "id:ios-peer",
                aliases: aliases,
                endpointHostOrIP: "fe80::bc:dca9:7759:5a45%en0",
                capabilities: ["fileTransferPort=8080"]
            ),
            transferKey: freshKey,
            lastSeenAt: now,
            sourceKind: .liveConnection
        )

        let resolved = ClassicTransferPeerResolutionPolicy.resolveSessionSource(
            peerContext: peerContext,
            authenticatedSources: [staleSnapshot, freshLiveConnection]
        )

        let probe = Data("receipt-probe".utf8)
        let selectedTag = resolved.map { Data(HMAC<SHA256>.authenticationCode(for: probe, using: $0.source.transferKey)) }
        let freshTag = Data(HMAC<SHA256>.authenticationCode(for: probe, using: freshKey))
        XCTAssertEqual(resolved?.source.sourceKind, .liveConnection)
        XCTAssertEqual(selectedTag, freshTag)
        XCTAssertEqual(resolved?.resolution.matchedBy, .declaredSenderDeviceId)
    }

    func testClassicTransferCandidateForReconnectConnectionCarriesStableIdentityAndResolvedEndpoint() {
        let device = P2PDevice(
            id: "bonjour:iPhone@local.",
            name: "iPhone",
            type: .iOS,
            address: "iPhone.local.",
            port: 50873,
            osVersion: "iOS 26.5",
            capabilities: ["_skybridge._tcp"],
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: ["iPhone._skybridge._tcp.local."]
        )
        let connection = P2PConnection(
            device: device,
            connection: NWConnection(
                host: NWEndpoint.Host("fe80::bc:dca9:7759:5a45%en0"),
                port: 50873,
                using: .tcp
            )
        )
        connection.testingSetHandshakePeerDeviceId("id:31bb9d78-11f6-4843-91ee-0a0c4c003632")
        connection.testingSetClassicTransferRemoteIdentity(
            deviceId: "31BB9D78-11F6-4843-91EE-0A0C4C003632",
            fileTransferPort: 8080,
            capabilities: [ClassicTransferCapability.classicResume]
        )
        defer { connection.disconnect() }

        let candidate = FileTransferManager.classicTransferAuthenticatedPeerCandidate(for: connection)
        let aliases = Set(candidate.aliases.map { $0.lowercased() })

        XCTAssertEqual(candidate.matchDeviceId.lowercased(), "31bb9d78-11f6-4843-91ee-0a0c4c003632")
        XCTAssertEqual(candidate.resolvedPeerDeviceId, "id:31bb9d78-11f6-4843-91ee-0a0c4c003632")
        XCTAssertTrue(aliases.contains("id:31bb9d78-11f6-4843-91ee-0a0c4c003632"))
        XCTAssertTrue(aliases.contains("bonjour:iphone@local."))
        XCTAssertTrue(aliases.contains("fe80::bc:dca9:7759:5a45%en0"))
        XCTAssertTrue(aliases.contains("host:fe80::bc:dca9:7759:5a45"))
        XCTAssertEqual(candidate.endpointHostOrIP, "fe80::bc:dca9:7759:5a45%en0")
        XCTAssertTrue(candidate.capabilities.contains("fileTransferPort=8080"))
    }

    func testResolvedReceiveDirectoryFallsBackWhenPreferredDirectoryIsNotWritable() throws {
        let manager = FileTransferManager()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let readOnly = parent.appendingPathComponent("read-only", isDirectory: true)

        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
            try? FileManager.default.removeItem(at: parent)
        }

        let resolved = manager.resolvedReceiveDirectoryForTesting(from: readOnly)

        XCTAssertNotEqual(resolved.standardizedFileURL.path, readOnly.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: resolved.path))
    }

    func testClassicTransferSecurityContextCountsDiscoveryAuthenticatedConnections() async {
        let manager = FileTransferManager()
        let discovery = P2PDiscoveryService.shared
        let peer = P2PDevice(
            id: "discovery-peer",
            name: "Discovery Peer",
            type: .macOS,
            address: "10.0.0.9",
            port: 9527,
            osVersion: "26.4.1",
            capabilities: ["file_transfer"],
            publicKey: Data(),
            lastSeen: Date(),
            persistentDeviceId: "id:550E8400-E29B-41D4-A716-446655440010"
        )
        let connection = NWConnection(
            host: "127.0.0.1",
            port: 9,
            using: .tcp
        )
        let authenticated = P2PConnection(device: peer, connection: connection)
        authenticated.testingSetStatus(P2PConnectionStatus.authenticated)
        discovery.testingReplaceAuthenticatedConnections([peer.deviceId: authenticated])
        defer {
            discovery.testingReplaceAuthenticatedConnections([:])
            connection.cancel()
        }

        let count = await manager.testingAuthenticatedClassicTransferSourceCount()

        XCTAssertEqual(count, 1)
    }

    func testInboundPreMetadataDisconnectClassifierOnlyMatchesTransportClosure() {
        XCTAssertTrue(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(FileTransferError.connectionClosed))
        XCTAssertTrue(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(NWError.posix(.ENOTCONN)))
        XCTAssertTrue(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(NWError.posix(.ECONNRESET)))
        XCTAssertFalse(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(FileTransferError.invalidHeader))
        XCTAssertFalse(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(FileTransferError.inboundInvalidInitialHeader))
        XCTAssertFalse(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(FileTransferError.secureSessionRequired))
    }

    func testInboundPreMetadataRejectsAreNonFatalSmokeDiagnostics() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/FileTransfer/FileTransferManager.swift"),
            encoding: .utf8
        )
        let listenerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/FileTransfer/FileTransferListenerService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(managerSource.contains("zeroByteDisconnectError: .inboundConnectionClosedBeforeMetadata"))
        XCTAssertTrue(managerSource.contains("throw FileTransferError.inboundInvalidInitialHeader"))
        XCTAssertTrue(managerSource.contains("accumulator.count() == 0"))
        XCTAssertTrue(managerSource.contains("return zeroByteDisconnectError"))
        XCTAssertFalse(
            managerSource.contains(
                "let payload = try await receiveData(length: header.length, from: connection, zeroByteDisconnectError: .inboundConnectionClosedBeforeMetadata)"
            ),
            "Only a zero-byte close before the initial header is non-fatal; metadata payload closes must stay fatal."
        )
        XCTAssertTrue(listenerSource.contains("catch FileTransferError.inboundConnectionClosedBeforeMetadata"))
        XCTAssertTrue(listenerSource.contains("file-transfer inbound-pre-metadata-disconnect"))
        XCTAssertTrue(listenerSource.contains("fatal=0 phase=initial_header bytesRead=0"))
        XCTAssertTrue(listenerSource.contains("catch FileTransferError.inboundInvalidInitialHeader"))
        XCTAssertTrue(listenerSource.contains("file-transfer inbound-rejected"))
        XCTAssertTrue(listenerSource.contains("fatal=0 phase=initial_header reason=invalid_header"))
        XCTAssertTrue(listenerSource.contains("failed stage=file-transfer phase=\\(phase)"))
        XCTAssertTrue(listenerSource.contains("mac_receive_file_connection_closed"))
        let benignCatch = try XCTUnwrap(
            listenerSource.range(of: "catch FileTransferError.inboundConnectionClosedBeforeMetadata")
        )
        let fatalLog = try XCTUnwrap(
            listenerSource.range(of: "failed stage=file-transfer phase=\\(phase)")
        )
        XCTAssertLessThan(
            benignCatch.lowerBound,
            fatalLog.lowerBound,
            "The listener must classify metadata-free connection aborts before the generic fatal mac_receive_file failure path."
        )
        let invalidHeaderCatch = try XCTUnwrap(
            listenerSource.range(of: "catch FileTransferError.inboundInvalidInitialHeader")
        )
        XCTAssertLessThan(
            invalidHeaderCatch.lowerBound,
            fatalLog.lowerBound,
            "The listener must classify invalid initial headers as non-fatal inbound rejects before the generic fatal file-transfer path."
        )
    }

    private static func mockSessionKeys(sessionId: String) -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x33, count: 32),
            sessionId: sessionId,
            createdAt: Date()
        )
    }
}
