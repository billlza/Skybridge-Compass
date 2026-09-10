import CryptoKit
import XCTest
@testable import SkyBridgeCore

private enum DelayedIdentityFailure: Error {
    case unavailable
    case repeatedResolution
    case waitExpired
}

@available(macOS 14.0, iOS 17.0, *)
private actor DelayedResponderIdentity: HandshakeIdentityProvider {
    private let identity: ResolvedHandshakeIdentity
    private var continuation: CheckedContinuation<ResolvedHandshakeIdentity, any Error>?
    private(set) var calls = 0

    init() {
        let key = Curve25519.Signing.PrivateKey()
        identity = ResolvedHandshakeIdentity(
            identityPublicKey: IdentityPublicKeys(
                protocolPublicKey: key.publicKey.rawRepresentation,
                protocolAlgorithm: .ed25519
            ).encoded,
            identityKeyHandle: .softwareKey(key.rawRepresentation),
            sigAAlgorithm: .ed25519
        )
    }

    func resolveIdentity() async throws -> ResolvedHandshakeIdentity {
        calls += 1
        guard calls == 1 else { throw DelayedIdentityFailure.repeatedResolution }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(succeed: Bool) {
        guard let pending = continuation else { return }
        continuation = nil
        if succeed { pending.resume(returning: identity) }
        else { pending.resume(throwing: DelayedIdentityFailure.unavailable) }
    }
}

@available(macOS 14.0, iOS 17.0, *)
private actor IdentityCancellationTransport: DiscoveryTransport {
    private var messages: [Data] = []
    private let blockFirstSend: Bool
    private var firstSend: CheckedContinuation<Void, any Error>?
    init(blockFirstSend: Bool = false) { self.blockFirstSend = blockFirstSend }
    func send(to peer: PeerIdentifier, data: Data) async throws {
        guard messages.count < 2 else { throw DelayedIdentityFailure.repeatedResolution }
        messages.append(data)
        if blockFirstSend && messages.count == 1 {
            try await withCheckedThrowingContinuation { firstSend = $0 }
        }
    }
    func captured() -> [Data] { messages }
    func completeFirstSend(succeed: Bool) {
        guard let pending = firstSend else { return }
        firstSend = nil
        if succeed { pending.resume() }
        else { pending.resume(throwing: DelayedIdentityFailure.unavailable) }
    }
}

@available(macOS 14.0, iOS 17.0, *)
final class HandshakeResponderIdentityCancellationTests: XCTestCase {
    func testCancelledIdentitySuccessCannotSendMessageBOrReviveResponder() async throws {
        try await exercise(succeed: true, duplicate: false)
    }

    func testCancelledIdentityFailureCannotReplaceCancellation() async throws {
        try await exercise(succeed: false, duplicate: false)
    }

    func testSecondMessageACannotStartAnotherIdentityResolution() async throws {
        try await exercise(succeed: true, duplicate: true)
    }

    func testCancelledMessageBSuccessCannotSendFinished() async throws {
        try await exerciseMessageB(succeed: true)
    }

    func testCancelledMessageBFailureCannotReplaceCancellation() async throws {
        try await exerciseMessageB(succeed: false)
    }

    private func exerciseMessageB(succeed: Bool) async throws {
        let outgoing = IdentityCancellationTransport()
        let incoming = IdentityCancellationTransport(blockFirstSend: true)
        func driver(_ transport: IdentityCancellationTransport) throws -> HandshakeDriver {
            let key = Curve25519.Signing.PrivateKey()
            return try HandshakeDriver(
                transport: transport, cryptoProvider: ClassicCryptoProvider(),
                protocolSignatureProvider: ClassicSignatureProvider(),
                protocolSigningKeyHandle: .softwareKey(key.rawRepresentation),
                sigAAlgorithm: .ed25519,
                identityPublicKey: IdentityPublicKeys(
                    protocolPublicKey: key.publicKey.rawRepresentation, protocolAlgorithm: .ed25519
                ).encoded,
                offeredSuites: [.x25519Ed25519]
            )
        }
        let initiator = try driver(outgoing)
        let responder = try driver(incoming)
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
            let messagesBeforeCancel = await incoming.captured()
            XCTAssertEqual(messagesBeforeCancel.count, 1)
            await responder.cancel()
            await incoming.completeFirstSend(succeed: succeed)
            await inbound?.value
            if case .failed(.cancelled) = await responder.getCurrentState() {} else {
                XCTFail("A late MessageB send must preserve cancellation")
            }
            let messagesAfterCancel = await incoming.captured()
            XCTAssertEqual(messagesAfterCancel.count, 1, "A cancelled MessageB send cannot start Finished delivery")
        } catch {
            await responder.cancel()
            await incoming.completeFirstSend(succeed: false)
            await inbound?.value
            await initiator.cancel()
            _ = await outbound.result
            throw error
        }
        await responder.cancel()
        await incoming.completeFirstSend(succeed: false)
        await inbound?.value
        await initiator.cancel()
        _ = await outbound.result
    }

    private func exercise(succeed: Bool, duplicate: Bool) async throws {
        let identity = DelayedResponderIdentity()
        let outgoing = IdentityCancellationTransport()
        let incoming = IdentityCancellationTransport()
        let key = Curve25519.Signing.PrivateKey()
        let initiator = try HandshakeDriver(
            transport: outgoing, cryptoProvider: ClassicCryptoProvider(),
            protocolSignatureProvider: ClassicSignatureProvider(),
            protocolSigningKeyHandle: .softwareKey(key.rawRepresentation),
            sigAAlgorithm: .ed25519,
            identityPublicKey: IdentityPublicKeys(
                protocolPublicKey: key.publicKey.rawRepresentation,
                protocolAlgorithm: .ed25519
            ).encoded,
            offeredSuites: [.x25519Ed25519]
        )
        let responder = try HandshakeDriver(
            transport: incoming, cryptoProvider: ClassicCryptoProvider(),
            protocolSignatureProvider: ClassicSignatureProvider(),
            identityProvider: identity, sigAAlgorithm: .ed25519,
            offeredSuites: [.x25519Ed25519]
        )
        let peer = PeerIdentifier(deviceId: "identity-cancellation-\(UUID().uuidString)")
        let outbound = Task { try await initiator.initiateHandshake(with: peer) }
        var inbound: Task<Void, Never>?
        do {
            let deadline = ContinuousClock.now + .seconds(3)
            var frames: [Data] = []
            while ContinuousClock.now < deadline {
                frames = await outgoing.captured()
                if !frames.isEmpty { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let messageA = try XCTUnwrap(frames.first)
            inbound = Task { await responder.handleMessage(messageA, from: peer) }
            while await identity.calls == 0 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard await identity.calls == 1 else { throw DelayedIdentityFailure.waitExpired }
            if duplicate {
                await responder.handleMessage(messageA, from: peer)
                let calls = await identity.calls
                XCTAssertEqual(calls, 1, "A suspended responder must own MessageA before the first actor hop")
            }
            await responder.cancel()
            await identity.complete(succeed: succeed)
            await inbound?.value
            let state = await responder.getCurrentState()
            guard case .failed(.cancelled) = state else {
                XCTFail("Late identity completion replaced cancellation")
                await initiator.cancel()
                await responder.cancel()
                _ = await outbound.result
                return
            }
            let framesAfterCancel = await incoming.captured()
            XCTAssertTrue(framesAfterCancel.isEmpty, "Cancelled identity work must not send MessageB or Finished")
            let authority = await responder.getAuthenticatedRemoteAuthority()
            XCTAssertNil(authority)
        } catch {
            await responder.cancel()
            await identity.complete(succeed: false)
            await inbound?.value
            await initiator.cancel()
            _ = await outbound.result
            throw error
        }
        await responder.cancel()
        await identity.complete(succeed: false)
        await inbound?.value
        await initiator.cancel()
        _ = await outbound.result
    }
}
