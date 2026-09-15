import CryptoKit
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
private enum FinishedDeliveryTestFailure: Error {
    case sendFailed
    case duplicateSend
    case timedOutWaitingForTransport
}

@available(macOS 14.0, iOS 17.0, *)
private actor ControlledFinishedTransport: DiscoveryTransport {
    private let suspendsFinished: Bool
    private var messages: [Data] = []
    private var finishedSend: CheckedContinuation<Void, any Error>?

    init(suspendsFinished: Bool) {
        self.suspendsFinished = suspendsFinished
    }

    func send(to peer: PeerIdentifier, data: Data) async throws {
        _ = peer
        guard messages.count < 2 else {
            throw FinishedDeliveryTestFailure.duplicateSend
        }
        messages.append(data)
        let unwrapped = HandshakePadding.unwrapIfNeeded(data, label: "test")
        guard suspendsFinished,
              (try? HandshakeFinished.decode(from: unwrapped)) != nil else {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            finishedSend = continuation
        }
    }

    func capturedMessages() -> [Data] {
        messages
    }

    @discardableResult
    func resumeFinished(_ result: Result<Void, FinishedDeliveryTestFailure>) -> Bool {
        guard let continuation = finishedSend else { return false }
        finishedSend = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
        return true
    }
}

@available(macOS 14.0, iOS 17.0, *)
final class HandshakeFinishedDeliveryTests: XCTestCase {
    func testResponderDoesNotPublishBeforeItsFinishedSendSucceeds() async throws {
        try await withBlockedResponderFinished { responder, transport, peerFinished, peer, receiveTask in
            await responder.handleMessage(peerFinished, from: peer)

            let beforeSendCompletion = await responder.getCurrentState()
            guard case .waitingFinished(_, let waitingKeys, _) = beforeSendCompletion else {
                XCTFail("A verified peer Finished must not establish a session while local send is suspended")
                await transport.resumeFinished(.success(()))
                await receiveTask.value
                return
            }
            let authority = await responder.getAuthenticatedRemoteAuthority()
            let binding = await responder.getAuthenticatedHandshakePeerBinding()
            XCTAssertNil(authority)
            XCTAssertNil(binding)
            let pendingConfirmation = await responder.authenticatedFinishedConfirmation(matching: waitingKeys)
            XCTAssertNil(pendingConfirmation)

            let resumed = await transport.resumeFinished(.success(()))
            XCTAssertTrue(resumed)
            await receiveTask.value

            let afterSendCompletion = await responder.getCurrentState()
            guard case .established(let keys) = afterSendCompletion else {
                XCTFail("The verified peer Finished must commit after the exact local send succeeds")
                return
            }
            let confirmation = await responder.authenticatedFinishedConfirmation(matching: keys)
            XCTAssertEqual(confirmation?.sessionId, keys.sessionId)
            XCTAssertEqual(confirmation?.suite, keys.negotiatedSuite)

            let differentSession = SessionKeys(
                sendKey: keys.sendKey, receiveKey: keys.receiveKey,
                negotiatedSuite: keys.negotiatedSuite, role: keys.role,
                transcriptHash: keys.transcriptHash, sessionId: keys.sessionId + "-different"
            )
            let differentKey = SessionKeys(
                sendKey: Data(keys.sendKey.map { $0 ^ 1 }), receiveKey: keys.receiveKey,
                negotiatedSuite: keys.negotiatedSuite, role: keys.role,
                transcriptHash: keys.transcriptHash, sessionId: keys.sessionId
            )
            for mismatch in [differentSession, differentKey] {
                let rejected = await responder.authenticatedFinishedConfirmation(matching: mismatch)
                XCTAssertNil(rejected)
            }
        }
    }

    func testResponderSendFailureCannotPublishAnEarlyFinished() async throws {
        try await withBlockedResponderFinished { responder, transport, peerFinished, peer, receiveTask in
            await responder.handleMessage(peerFinished, from: peer)
            if case .established = await responder.getCurrentState() {
                XCTFail("A pending transport operation must not publish session keys")
            }

            let resumed = await transport.resumeFinished(.failure(.sendFailed))
            XCTAssertTrue(resumed)
            await receiveTask.value

            let state = await responder.getCurrentState()
            guard case .failed(.transportError) = state else {
                XCTFail("The failed local Finished send must fail the handshake")
                return
            }
            let authority = await responder.getAuthenticatedRemoteAuthority()
            let binding = await responder.getAuthenticatedHandshakePeerBinding()
            XCTAssertNil(authority)
            XCTAssertNil(binding)
        }
    }

    func testCancellationRetiresBothSuccessfulAndFailedLateSends() async throws {
        let outcomes: [Result<Void, FinishedDeliveryTestFailure>] = [
            .success(()), .failure(.sendFailed)
        ]
        for outcome in outcomes {
            try await withBlockedResponderFinished { responder, transport, peerFinished, peer, receiveTask in
                await responder.handleMessage(peerFinished, from: peer)
                await responder.cancel()
                let resumed = await transport.resumeFinished(outcome)
                XCTAssertTrue(resumed)
                await receiveTask.value
                guard case .failed(.cancelled) = await responder.getCurrentState() else {
                    XCTFail("A late send result must preserve cancellation")
                    return
                }
                let authority = await responder.getAuthenticatedRemoteAuthority()
                let binding = await responder.getAuthenticatedHandshakePeerBinding()
                XCTAssertNil(authority)
                XCTAssertNil(binding)
            }
        }
    }

    func testDuplicateEarlyFinishedFailsBeforeDeliveryCanPublish() async throws {
        try await withBlockedResponderFinished { responder, transport, peerFinished, peer, receiveTask in
            await responder.handleMessage(peerFinished, from: peer)
            await responder.handleMessage(peerFinished, from: peer)
            let resumed = await transport.resumeFinished(.success(()))
            XCTAssertTrue(resumed)
            await receiveTask.value
            guard case .failed(.invalidMessageFormat(let reason)) = await responder.getCurrentState() else {
                XCTFail("A second pending Finished must fail its exact handshake")
                return
            }
            XCTAssertEqual(reason, "Duplicate pending Finished")
            let authority = await responder.getAuthenticatedRemoteAuthority()
            XCTAssertNil(authority)
        }
    }

    func testTimeoutRetiresASuspendedFinishedSend() async throws {
        try await withBlockedResponderFinished(responderTimeout: .seconds(1)) {
            responder, transport, peerFinished, peer, receiveTask in
            await responder.handleMessage(peerFinished, from: peer)
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                if case .failed(.timeout) = await responder.getCurrentState() { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard case .failed(.timeout) = await responder.getCurrentState() else {
                XCTFail("The handshake timeout must include local Finished delivery")
                return
            }
            let resumed = await transport.resumeFinished(.success(()))
            XCTAssertTrue(resumed)
            await receiveTask.value
            guard case .failed(.timeout) = await responder.getCurrentState() else {
                XCTFail("A successful late send must not revive an expired session")
                return
            }
            let authority = await responder.getAuthenticatedRemoteAuthority()
            XCTAssertNil(authority)
        }
    }

    private func withBlockedResponderFinished(
        responderTimeout: Duration = .seconds(30),
        _ body: (
            HandshakeDriver,
            ControlledFinishedTransport,
            Data,
            PeerIdentifier,
            Task<Void, Never>
        ) async throws -> Void
    ) async throws {
        let initiatorTransport = ControlledFinishedTransport(suspendsFinished: false)
        let responderTransport = ControlledFinishedTransport(suspendsFinished: true)
        let initiator = try makeDriver(transport: initiatorTransport)
        let responder = try makeDriver(transport: responderTransport, timeout: responderTimeout)
        let peer = PeerIdentifier(deviceId: "finished-delivery-\(UUID().uuidString)")
        let initiation = Task {
            try await initiator.initiateHandshake(with: peer)
        }
        var reception: Task<Void, Never>?

        do {
            let messageA = try await waitForMessages(1, transport: initiatorTransport)[0]
            let receiveTask = Task {
                await responder.handleMessage(messageA, from: peer)
            }
            reception = receiveTask
            let responderMessages = try await waitForMessages(2, transport: responderTransport)
            await initiator.handleMessage(responderMessages[0], from: peer)
            await initiator.handleMessage(responderMessages[1], from: peer)
            let initiatorKeys = try await initiation.value
            XCTAssertEqual(initiatorKeys.negotiatedSuite, .x25519Ed25519)
            let initiatorMessages = try await waitForMessages(2, transport: initiatorTransport)
            try await body(responder, responderTransport, initiatorMessages[1], peer, receiveTask)
        } catch {
            await initiator.cancel()
            await responder.cancel()
            await responderTransport.resumeFinished(.failure(.sendFailed))
            _ = await initiation.result
            await reception?.value
            throw error
        }

        await initiator.cancel()
        await responder.cancel()
        await responderTransport.resumeFinished(.failure(.sendFailed))
        _ = await initiation.result
        await reception?.value
    }

    private func makeDriver(
        transport: any DiscoveryTransport,
        timeout: Duration = .seconds(30)
    ) throws -> HandshakeDriver {
        let identity = Curve25519.Signing.PrivateKey()
        return try HandshakeDriver(
            transport: transport,
            cryptoProvider: ClassicCryptoProvider(),
            protocolSignatureProvider: ClassicSignatureProvider(),
            protocolSigningKeyHandle: .softwareKey(identity.rawRepresentation),
            sigAAlgorithm: .ed25519,
            identityPublicKey: IdentityPublicKeys(
                protocolPublicKey: identity.publicKey.rawRepresentation,
                protocolAlgorithm: .ed25519
            ).encoded,
            offeredSuites: [.x25519Ed25519],
            timeout: timeout
        )
    }

    private func waitForMessages(
        _ count: Int,
        transport: ControlledFinishedTransport
    ) async throws -> [Data] {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let messages = await transport.capturedMessages()
            if messages.count == count { return messages }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The actual handshake did not reach the controlled transport boundary")
        throw FinishedDeliveryTestFailure.timedOutWaitingForTransport
    }
}
