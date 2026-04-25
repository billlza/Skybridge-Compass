import XCTest
import Network
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
            FileTransferManager.ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:trusted-peer",
                resolvedPeerDeviceId: "id:trusted-peer",
                aliases: ["id:trusted-peer", "trusted-peer", "host:192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: [ClassicTransferCapability.classicResume]
            ),
            FileTransferManager.ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:other-peer",
                resolvedPeerDeviceId: "id:other-peer",
                aliases: ["id:other-peer", "other-peer"],
                endpointHostOrIP: "192.168.31.30",
                capabilities: []
            )
        ]

        let resolved = FileTransferManager.resolveClassicTransferPeer(
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
            FileTransferManager.ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:trusted-peer",
                resolvedPeerDeviceId: "id:trusted-peer",
                aliases: ["id:trusted-peer", "trusted-peer", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            )
        ]

        let resolved = FileTransferManager.resolveClassicTransferPeer(
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
            FileTransferManager.ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:peer-a",
                resolvedPeerDeviceId: "id:peer-a",
                aliases: ["id:peer-a", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            ),
            FileTransferManager.ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:peer-b",
                resolvedPeerDeviceId: "id:peer-b",
                aliases: ["id:peer-b", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            )
        ]

        let resolved = FileTransferManager.resolveClassicTransferPeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertNil(resolved)
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
}
