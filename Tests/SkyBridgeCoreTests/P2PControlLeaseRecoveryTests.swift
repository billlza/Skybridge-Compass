import Foundation
import Network
import SkyBridgeProtocolCore
@testable import SkyBridgeCore
import XCTest

@MainActor
final class P2PControlLeaseRecoveryTests: XCTestCase {
    private actor StartGate {
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() { opened = true; waiter?.resume(); waiter = nil }
    }
    private func keys(session: String = "recovery-session", sendByte: UInt8 = 1,
                      receiveByte: UInt8 = 2, transcriptByte: UInt8 = 3) -> SessionKeys {
        SessionKeys(sendKey: Data(repeating: sendByte, count: 32),
                    receiveKey: Data(repeating: receiveByte, count: 32),
                    negotiatedSuite: .x25519Ed25519, role: .initiator,
                    transcriptHash: Data(repeating: transcriptByte, count: 32), sessionId: session)
    }

    private func connection(installFinished: Bool = true) throws -> P2PConnection {
        let local = try ProtocolIdentityBinding(deviceId: "recovery-local-device", protocolSigningAlgorithm: .ed25519,
                                               protocolPublicKeyBytes: Data(repeating: 0x31, count: 32))
        let peer = try ProtocolIdentityBinding(deviceId: "recovery-remote-device", protocolSigningAlgorithm: .ed25519,
                                              protocolPublicKeyBytes: Data(repeating: 0x41, count: 32))
        let binding = AuthenticatedHandshakePeerBinding(authority: .init(protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: peer.protocolPublicKeyFingerprint, protocolPublicKey: peer.protocolPublicKeyBytes),
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: peer.deviceId))
        let device = P2PDevice(id: peer.deviceId, name: "Recovery test peer", type: .iOS,
                              address: "127.0.0.1", port: 1, osVersion: "test", capabilities: [],
                              publicKey: Data(), lastSeen: Date())
        // Never start this native carrier. These tests exercise ownership before
        // any side effect; the signed product is tested separately on the iPad.
        let native = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let connection = P2PConnection(device: device, connection: native, controlTransport: .usb)
        if installFinished {
            _ = try connection.testingInstallAudioEpoch(keys: keys(), peerBinding: binding, local: local, peer: peer)
        }
        return connection
    }

    func testRecoveryRequiresAnExistingFinishedBoundOwner() async throws {
        let connection = try connection(installFinished: false)
        XCTAssertThrowsError(try connection.testingPrepareClassicTransferSessionRecovery(keys: keys())) {
            guard case P2PConnectionError.staleAuthenticatedFrame = $0 else {
                return XCTFail("Unexpected recovery error: \($0)")
            }
        }
        XCTAssertEqual(connection.testingAudioPairingOperationSequence, 0)
        await connection.disconnectAndWait()
    }

    func testStaleSessionOrKeyMaterialCannotReserveRecoveryForCurrentPeer() async throws {
        let connection = try connection()
        for stale in [keys(session: "older-session"), keys(sendByte: 9), keys(receiveByte: 9), keys(transcriptByte: 9)] {
            XCTAssertThrowsError(try connection.testingPrepareClassicTransferSessionRecovery(keys: stale)) {
                guard case P2PConnectionError.staleAuthenticatedFrame = $0 else {
                    return XCTFail("Unexpected recovery error: \($0)")
                }
            }
            XCTAssertEqual(connection.testingAudioPairingOperationSequence, 0)
        }
        let current = try connection.testingPrepareClassicTransferSessionRecovery(keys: keys())
        XCTAssertTrue(connection.testingOwnsClassicTransferSessionRecovery(current))
        await connection.disconnectAndWait()
    }

    func testRecoveryReservesOneRekeyAndDisconnectPermanentlyRevokesIt() async throws {
        let connection = try connection()
        let operation = try connection.testingPrepareClassicTransferSessionRecovery(keys: keys())
        XCTAssertEqual(operation.kind, .outboundRekey)
        XCTAssertTrue(connection.testingOwnsClassicTransferSessionRecovery(operation))
        XCTAssertThrowsError(try connection.testingPrepareClassicTransferSessionRecovery(keys: keys())) {
            guard case P2PConnectionError.handshakeOperationInProgress = $0 else {
                return XCTFail("Unexpected concurrent recovery result: \($0)")
            }
        }
        XCTAssertEqual(connection.testingAudioPairingOperationSequence, operation.operationSequence)
        await connection.disconnectAndWait()
        XCTAssertFalse(connection.testingOwnsClassicTransferSessionRecovery(operation))
        XCTAssertThrowsError(try connection.testingPrepareClassicTransferSessionRecovery(keys: keys()))
        XCTAssertEqual(connection.status, .disconnected)
    }

    func testCancelledRecoveryClosesInsteadOfRestoringExpiredOwner() async throws {
        let connection = try connection()
        connection.testingSetStatus(.authenticated)
        let operation = try connection.testingPrepareClassicTransferSessionRecovery(keys: keys())
        let gate = StartGate()
        let task = Task {
            await gate.wait()
            try await connection.testingRunClassicTransferSessionRecovery(operation)
        }
        task.cancel()
        await gate.open()
        do { try await task.value; XCTFail("Cancelled recovery succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await connection.disconnectAndWait()
        XCTAssertEqual(connection.status, .disconnected)
        XCTAssertFalse(connection.testingOwnsClassicTransferSessionRecovery(operation))
        XCTAssertThrowsError(try connection.testingPrepareClassicTransferSessionRecovery(keys: keys()))
    }
}
