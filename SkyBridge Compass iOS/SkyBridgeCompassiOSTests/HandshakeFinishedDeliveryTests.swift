import CryptoKit
import XCTest
@testable import SkyBridgeCompass_iOS

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
    private enum PublicationOutcome { case published, replaced, cancelled, corruptCiphertext }

    func testFirstAuthenticatedControlWaitsForInitiatorPublication() async throws {
        try await exercisePublication(.published)
    }

    func testConnectionReplacementReleasesAndDiscardsPendingFirstFrame() async throws {
        try await exercisePublication(.replaced)
    }

    func testCancelledPublicationWaitCannotDispatchTheFirstFrame() async throws {
        try await exercisePublication(.cancelled)
    }

    func testReleasedFirstFrameStillRequiresValidAEAD() async throws {
        try await exercisePublication(.corruptCiphertext)
    }

    private func exercisePublication(_ outcome: PublicationOutcome) async throws {
        try await withBlockedResponderFinished(inspectInitiator: { driver, keys in
            try await Self.exercisePendingPublication(driver: driver, keys: keys, outcome: outcome)
        }) { responder, transport, peerFinished, peer, receiveTask in
            await responder.handleMessage(peerFinished, from: peer)
            await transport.resumeFinished(.success(()))
            await receiveTask.value
        }
    }

    @MainActor
    private static func exercisePendingPublication(driver: HandshakeDriver, keys: SessionKeys,
                                                   outcome: PublicationOutcome) async throws {
        let manager = P2PConnectionManager.instance
        let peerID = UUID().uuidString
        defer { manager.testSimulateTerminalCleanup(runtimePeerId: peerID) }
        manager.installTestPeerRuntimeState(runtimePeerId: peerID, name: "Before publication")
        let token = try manager.testInstallPendingHandshakePublication(driver: driver, keys: keys, for: peerID)
        let message = AppMessage.heartbeat(.init(deviceName: "Authenticated first frame"))
        var sealed = try XCTUnwrap(AES.GCM.seal(JSONEncoder().encode(message),
            using: SymmetricKey(data: keys.receiveKey)).combined)
        if outcome == .corruptCiphertext { sealed[sealed.index(before: sealed.endIndex)] ^= 1 }
        let frame = sealed
        var receiveReturned = false
        let receive = Task {
            try await manager.testReceiveEstablishedControlFrame(frame, for: peerID)
            receiveReturned = true
        }
        defer { receive.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while manager.testHandshakePublicationWaiterCount(for: peerID) == 0 && !receiveReturned,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(receiveReturned, "The first encrypted control must not be consumed by the completed handshake driver")
        XCTAssertEqual(manager.testHandshakePublicationWaiterCount(for: peerID), 1)
        XCTAssertEqual(manager.activeConnections.first(where: { $0.device.id == peerID })?.device.name,
                       "Before publication", "Pending publication must not authorize app effects")
        switch outcome {
        case .published, .corruptCiphertext:
            try manager.testFinishHandshakePublication(for: peerID, token: token)
        case .replaced:
            try manager.testInstallAuthenticatedSession(keys.negotiatedSuite, for: peerID)
        case .cancelled:
            receive.cancel()
        }
        try await receive.value
        switch outcome {
        case .published:
            XCTAssertEqual(manager.activeConnections.first(where: { $0.device.id == peerID })?.device.name,
                           "Authenticated first frame", "The retained frame must pass through real AEAD and app dispatch")
        case .replaced:
            let replacement = manager.activeConnections.first(where: { $0.device.id == peerID })
            XCTAssertEqual(replacement?.device.name, "Before publication", "The old frame cannot mutate its replacement")
            XCTAssertEqual(replacement?.status, .connected, "Old cleanup cannot retire the replacement")
        case .cancelled, .corruptCiphertext:
            XCTAssertFalse(manager.activeConnections.contains(where: { $0.device.id == peerID }),
                           "A cancelled wait or invalid ciphertext must retire the exact connection")
        }
        XCTAssertEqual(manager.testHandshakePublicationWaiterCount(for: peerID), 0)
    }

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

    func testAudioIdentityIsActualSignedKeyAndPublishedOnlyAfterBothFinished() async throws {
        try await withBlockedResponderFinished(audioIdentity: true) { responder, transport, peerFinished, peer, receiveTask in
            await responder.handleMessage(peerFinished, from: peer)
            guard case .waitingFinished(_, let pendingKeys, _) = await responder.getCurrentState() else {
                throw FinishedDeliveryTestFailure.sendFailed
            }
            let before = await responder.getAuthenticatedAudioHandshakeBinding(matching: pendingKeys)
            XCTAssertNil(before)
            await transport.resumeFinished(.success(())); await receiveTask.value
            guard case .established(let keys) = await responder.getCurrentState() else {
                throw FinishedDeliveryTestFailure.sendFailed
            }
            let audio = await responder.getAuthenticatedAudioHandshakeBinding(matching: keys)
            let messages = await transport.capturedMessages()
            let wireB = try HandshakeMessageB.decode(from: HandshakePadding.unwrapIfNeeded(messages[0], label: "audio-test"))
            let actual = try wireB.decodedIdentityPublicKeys()
            XCTAssertEqual(audio?.local.deviceId, Self.responderID)
            XCTAssertEqual(audio?.local.protocolSigningAlgorithm, .ed25519)
            XCTAssertEqual(audio?.local.protocolPublicKeyBytes, actual.protocolPublicKey)
            XCTAssertEqual(audio?.peer.authenticatedRemoteSOAPeerId, PeerSessionArbiter.soaPeerId(from: Self.initiatorID))
            let wrong = SessionKeys(sendKey: Data(keys.sendKey.map { $0 ^ 1 }), receiveKey: keys.receiveKey,
                negotiatedSuite: keys.negotiatedSuite, role: keys.role, transcriptHash: keys.transcriptHash, sessionId: keys.sessionId)
            let stale = await responder.getAuthenticatedAudioHandshakeBinding(matching: wrong)
            XCTAssertNil(stale)
            await responder.cancel()
            let cancelled = await responder.getAuthenticatedAudioHandshakeBinding(matching: keys)
            XCTAssertNil(cancelled)
        }
    }

    func testAudioIdentityRejectsDeviceIdNotBoundToSignedSOA() async throws {
        try await withBlockedResponderFinished(audioIdentity: true, mismatchedLocalID: true) { responder, transport, peerFinished, peer, receiveTask in
            await responder.handleMessage(peerFinished, from: peer)
            await transport.resumeFinished(.success(())); await receiveTask.value
            guard case .established(let keys) = await responder.getCurrentState() else {
                throw FinishedDeliveryTestFailure.sendFailed
            }
            let audio = await responder.getAuthenticatedAudioHandshakeBinding(matching: keys)
            let diagnostic = await responder.audioLocalIdentityCaptureDiagnostic()
            XCTAssertNil(audio)
            XCTAssertEqual(diagnostic, "local_device_soa_mismatch")
        }
    }

    func testAudioIdentityRemainsUnavailableWithoutSOA() async throws {
        try await withBlockedResponderFinished { responder, transport, peerFinished, peer, receiveTask in
            await responder.handleMessage(peerFinished, from: peer)
            await transport.resumeFinished(.success(())); await receiveTask.value
            guard case .established(let keys) = await responder.getCurrentState() else {
                throw FinishedDeliveryTestFailure.sendFailed
            }
            let audio = await responder.getAuthenticatedAudioHandshakeBinding(matching: keys)
            XCTAssertNil(audio)
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
        audioIdentity: Bool = false, mismatchedLocalID: Bool = false,
        inspectInitiator: ((HandshakeDriver, SessionKeys) async throws -> Void)? = nil,
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
        let initiatorSOA = PeerSessionArbiter.soaPeerId(from: Self.initiatorID)
        let responderSOA = PeerSessionArbiter.soaPeerId(from: Self.responderID)
        let soa = audioIdentity ? try HandshakeSOAMetadata(initiatorPeerId: initiatorSOA,
            targetPeerId: responderSOA, attemptId: Data(repeating: 0x56, count: 16)) : nil
        let initiator = try makeDriver(transport: initiatorTransport,
            localID: audioIdentity ? Self.initiatorID : nil, localSOA: audioIdentity ? initiatorSOA : nil,
            remoteSOA: audioIdentity ? responderSOA : nil, soa: soa)
        let responder = try makeDriver(transport: responderTransport, timeout: responderTimeout,
            localID: audioIdentity ? (mismatchedLocalID ? Self.initiatorID : Self.responderID) : nil,
            localSOA: audioIdentity ? responderSOA : nil, remoteSOA: audioIdentity ? initiatorSOA : nil)
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
            try await inspectInitiator?(initiator, initiatorKeys)
            if audioIdentity {
                let binding = await initiator.getAuthenticatedAudioHandshakeBinding(matching: initiatorKeys)
                XCTAssertEqual(binding?.local.deviceId, Self.initiatorID)
                XCTAssertEqual(binding?.peer.authenticatedRemoteSOAPeerId, responderSOA)
            }
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

    private static let initiatorID = "id:11111111-1111-1111-1111-111111111111"
    private static let responderID = "id:22222222-2222-2222-2222-222222222222"
    private func makeDriver(
        transport: any DiscoveryTransport,
        timeout: Duration = .seconds(30),
        localID: String? = nil, localSOA: Data? = nil, remoteSOA: Data? = nil,
        soa: HandshakeSOAMetadata? = nil
    ) throws -> HandshakeDriver {
        let identity = Curve25519.Signing.PrivateKey()
        return HandshakeDriver(
            transport: transport,
            cryptoProvider: ClassicCryptoProvider(),
            protocolSignatureProvider: ClassicSignatureProvider(),
            identityKeyHandle: .softwareKey(identity.rawRepresentation),
            sigAAlgorithm: .ed25519,
            protocolSigningKeyProtection: .softwareKeychain,
            // The iOS driver builds the identity wire envelope from the raw key.
            identityPublicKey: identity.publicKey.rawRepresentation,
            offeredSuites: [.x25519Ed25519],
            timeout: timeout, soaMetadata: soa,
            localSOAPeerId: localSOA, localProtocolDeviceId: localID,
            expectedRemoteSOAPeerId: remoteSOA, sessionArbiter: PeerSessionArbiter()
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

@available(iOS 17.0, *)
private actor PendingMessageBTransport: DiscoveryTransport {
    private let blockFirst: Bool
    private var messages: [Data] = []
    private var pending: CheckedContinuation<Void, any Error>?
    init(blockFirst: Bool = false) { self.blockFirst = blockFirst }
    func send(to peer: PeerIdentifier, data: Data) async throws {
        guard messages.count < 2 else { throw FinishedDeliveryTestFailure.duplicateSend }
        messages.append(data)
        if blockFirst && messages.count == 1 {
            try await withCheckedThrowingContinuation { pending = $0 }
        }
    }
    func captured() -> [Data] { messages }
    func complete(succeed: Bool) {
        guard let continuation = pending else { return }
        pending = nil
        if succeed { continuation.resume() }
        else { continuation.resume(throwing: FinishedDeliveryTestFailure.sendFailed) }
    }
}

@available(iOS 17.0, *)
final class HandshakeMessageBCancellationTests: XCTestCase {
    func testLateMessageBSuccessCannotSendFinishedAfterCancel() async throws {
        try await exercise(succeed: true)
    }
    func testLateMessageBFailureCannotReplaceCancellation() async throws {
        try await exercise(succeed: false)
    }
    private func exercise(succeed: Bool) async throws {
        let outgoing = PendingMessageBTransport()
        let incoming = PendingMessageBTransport(blockFirst: true)
        func driver(_ transport: PendingMessageBTransport) -> HandshakeDriver {
            let key = Curve25519.Signing.PrivateKey()
            return HandshakeDriver(
                transport: transport, cryptoProvider: ClassicCryptoProvider(),
                protocolSignatureProvider: ClassicSignatureProvider(),
                identityKeyHandle: .softwareKey(key.rawRepresentation), sigAAlgorithm: .ed25519,
                protocolSigningKeyProtection: .softwareKeychain,
                identityPublicKey: key.publicKey.rawRepresentation,
                offeredSuites: [.x25519Ed25519]
            )
        }
        let initiator = driver(outgoing)
        let responder = driver(incoming)
        let peer = PeerIdentifier(deviceId: "message-b-cancellation-\(UUID().uuidString)")
        let outbound = Task { try await initiator.initiateHandshake(with: peer) }
        var inbound: Task<Void, Never>?
        do {
            let deadline = ContinuousClock.now + .seconds(3)
            while await outgoing.captured().isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let frames = await outgoing.captured()
            let message = try XCTUnwrap(frames.first)
            inbound = Task { await responder.handleMessage(message, from: peer) }
            while await incoming.captured().isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let before = await incoming.captured()
            XCTAssertEqual(before.count, 1)
            await responder.cancel()
            await incoming.complete(succeed: succeed)
            await inbound?.value
            if case .failed(.cancelled) = await responder.getCurrentState() {} else {
                XCTFail("A late MessageB send must preserve cancellation")
            }
            let after = await incoming.captured()
            XCTAssertEqual(after.count, 1, "A cancelled MessageB send cannot start Finished delivery")
        } catch {
            await responder.cancel()
            await incoming.complete(succeed: false)
            await inbound?.value
            await initiator.cancel()
            _ = await outbound.result
            throw error
        }
        await responder.cancel()
        await incoming.complete(succeed: false)
        await inbound?.value
        await initiator.cancel()
        _ = await outbound.result
    }
}
