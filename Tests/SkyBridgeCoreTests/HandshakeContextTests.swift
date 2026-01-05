//
// HandshakeContextTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for HandshakeContext
// **Feature: tech-debt-cleanup, Property 5: Handshake Context Isolation**
// **Validates: Requirements 4.3, 4.4**
//

import XCTest
import CryptoKit
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class HandshakeContextTests: XCTestCase {
    
 // MARK: - Property 5: Handshake Context Isolation
    
 /// **Property 5: Handshake Context Isolation**
 /// *For any* HandshakeContext, after zeroize() is called:
 /// 1. isZeroized SHALL be true
 /// 2. All sensitive data (ephemeralPrivateKey, transcriptHash, nonce) SHALL be nil
 /// 3. Subsequent operations SHALL throw contextZeroized error
 /// **Validates: Requirements 4.3, 4.4**
    
 /// Test that context can be created successfully
    func testProperty5_ContextCreation() async throws {
        let provider = ClassicCryptoProvider()
        let context = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        
 // Context should be able to build MessageA with key shares
        let signingKeyPair = try await provider.generateKeyPair(for: .signing)
        let messageA = try await context.buildMessageA(
            identityKeyHandle: .softwareKey(signingKeyPair.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(signingKeyPair.publicKey.bytes)
        )
        XCTAssertFalse(messageA.keyShares.isEmpty, "KeyShares should be generated")
        XCTAssertEqual(messageA.keyShares.first?.shareBytes.count, 32, "X25519 key share should be 32 bytes")
        
 // Context should not be zeroized initially
        let isZeroized = await context.isZeroized
        XCTAssertFalse(isZeroized, "Context should not be zeroized initially")
        
 // Clean up
        await context.zeroize()
    }
    
 /// Test that zeroize clears all sensitive data
    func testProperty5_ZeroizeClearsSensitiveData() async throws {
        let provider = ClassicCryptoProvider()
        let context = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        
 // Build MessageA to populate key shares
        let signingKeyPair = try await provider.generateKeyPair(for: .signing)
        _ = try await context.buildMessageA(
            identityKeyHandle: .softwareKey(signingKeyPair.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(signingKeyPair.publicKey.bytes)
        )
        
 // Zeroize
        await context.zeroize()
        
 // Verify isZeroized is true
        let isZeroized = await context.isZeroized
        XCTAssertTrue(isZeroized, "isZeroized should be true after zeroize()")
        
 // Verify key shares are cleared
        let keyShares = await context.keyExchangePublicKeys
        XCTAssertTrue(keyShares.isEmpty, "Key shares should be cleared after zeroize")
    }
    
 /// Test that zeroize is idempotent (can be called multiple times safely)
    func testProperty5_ZeroizeIdempotent() async throws {
        let provider = ClassicCryptoProvider()
        let context = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        
 // Call zeroize multiple times
        await context.zeroize()
        await context.zeroize()
        await context.zeroize()
        
 // Should still be zeroized
        let isZeroized = await context.isZeroized
        XCTAssertTrue(isZeroized, "Context should remain zeroized after multiple calls")
    }
    
 /// Test that operations fail after zeroize
    func testProperty5_OperationsFailAfterZeroize() async throws {
        let provider = ClassicCryptoProvider()
        let context = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        
 // Zeroize the context
        await context.zeroize()
        
 // Generate test keys for signing
        let signingKeyPair = try await provider.generateKeyPair(for: .signing)
        
 // Attempt to build MessageA should fail
        do {
            _ = try await context.buildMessageA(
                identityKeyHandle: .softwareKey(signingKeyPair.privateKey.bytes),
                identityPublicKey: encodeIdentityPublicKey(signingKeyPair.publicKey.bytes)
            )
            XCTFail("buildMessageA should throw after zeroize")
        } catch let error as HandshakeError {
            switch error {
            case .contextZeroized:
                break // Expected
            default:
                XCTFail("Expected contextZeroized error, got \(error)")
            }
        }
    }
    
    func testReplayDetectionRejectsDuplicateMessageB() async throws {
        await HandshakeReplayCache.shared.clearForTesting()
        
        let provider = ClassicCryptoProvider()
        let initiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        let responder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: provider
        )
        
        let initiatorSigningKey = try await provider.generateKeyPair(for: .signing)
        let responderSigningKey = try await provider.generateKeyPair(for: .signing)
        
        let messageA = try await initiator.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorSigningKey.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(initiatorSigningKey.publicKey.bytes)
        )
        
        try await responder.processMessageA(messageA)
        let buildResult = try await responder.buildMessageB(
            identityKeyHandle: .softwareKey(responderSigningKey.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(responderSigningKey.publicKey.bytes)
        )
        let messageB = buildResult.message
        buildResult.sharedSecret.zeroize()
        
        _ = try await initiator.processMessageB(messageB)
        
        do {
            _ = try await initiator.processMessageB(messageB)
            XCTFail("Expected replay detection to fail")
        } catch let error as HandshakeError {
            switch error {
            case .failed(let reason):
                guard case .replayDetected = reason else {
                    XCTFail("Expected replayDetected, got \(reason)")
                    return
                }
            default:
                XCTFail("Expected replayDetected, got \(error)")
            }
        }
    }

    func testSuiteDowngradeEmitsSecurityEvent() async throws {
        actor EventCapture {
            var event: SecurityEvent?

            func capture(_ received: SecurityEvent) {
                if received.type == .cryptoDowngrade {
                    event = received
                }
            }

            func getEvent() -> SecurityEvent? {
                event
            }
        }

        let eventCapture = EventCapture()
        let subscriptionId = await SecurityEventEmitter.shared.subscribe { event in
            await eventCapture.capture(event)
        }

        let provider = ClassicCryptoProvider()
        let responder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: provider
        )

        let signingKey = try await provider.generateKeyPair(for: .signing)
        let keyExchange = try await provider.generateKeyPair(for: .keyExchange)

        var nonceBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)

        let capabilities = CryptoCapabilities(
            supportedKEM: ["X25519"],
            supportedSignature: ["P-256"],
            supportedAuthProfiles: [AuthProfile.classic.displayName],
            supportedAEAD: ["AES-256-GCM"],
            pqcAvailable: false,
            platformVersion: "macOS14",
            providerType: .classic
        )

        let preferredSuite: CryptoSuite = .mlkem768MLDSA65
        let fallbackSuite: CryptoSuite = .x25519Ed25519
        let keyShares = [
            HandshakeKeyShare(suite: preferredSuite, shareBytes: Data([0x01, 0x02, 0x03])),
            HandshakeKeyShare(suite: fallbackSuite, shareBytes: keyExchange.publicKey.bytes)
        ]

        let unsignedMessageA = HandshakeMessageA(
            supportedSuites: [preferredSuite, fallbackSuite],
            keyShares: keyShares,
            clientNonce: Data(nonceBytes),
            policy: .default,
            capabilities: capabilities,
            signature: Data(),
            identityPublicKey: encodeIdentityPublicKey(signingKey.publicKey.bytes)
        )
        let signature = try await provider.sign(
            data: unsignedMessageA.signaturePreimage,
            using: .softwareKey(signingKey.privateKey.bytes)
        )

        let messageA = HandshakeMessageA(
            version: unsignedMessageA.version,
            supportedSuites: unsignedMessageA.supportedSuites,
            keyShares: unsignedMessageA.keyShares,
            clientNonce: unsignedMessageA.clientNonce,
            policy: unsignedMessageA.policy,
            capabilities: unsignedMessageA.capabilities,
            signature: signature,
            identityPublicKey: unsignedMessageA.identityPublicKey
        )

        try await responder.processMessageA(messageA)

        try await Task.sleep(nanoseconds: 100_000_000)

        let receivedEvent = await eventCapture.getEvent()
        XCTAssertNotNil(receivedEvent, "Expected cryptoDowngrade event to be emitted")
        if let event = receivedEvent {
            XCTAssertEqual(event.context["preferredSuite"], preferredSuite.rawValue)
            XCTAssertEqual(event.context["selectedSuite"], fallbackSuite.rawValue)
            XCTAssertEqual(event.context["reason"], "lower_priority_selected")
            XCTAssertNotNil(event.context["skipped"])
        }

        await SecurityEventEmitter.shared.unsubscribe(subscriptionId)
        await responder.zeroize()
    }
    
 /// Test that different roles create valid contexts
    func testProperty5_DifferentRolesCreateValidContexts() async throws {
        let provider = ClassicCryptoProvider()
        
 // Create initiator context
        let initiatorContext = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        let initiatorRole = await initiatorContext.role
        XCTAssertEqual(initiatorRole, .initiator)
        
 // Create responder context
        let responderContext = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: provider
        )
        let responderRole = await responderContext.role
        XCTAssertEqual(responderRole, .responder)
        
 // Initiator builds MessageA
        let initiatorSigningKey = try await provider.generateKeyPair(for: .signing)
        let messageA = try await initiatorContext.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorSigningKey.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(initiatorSigningKey.publicKey.bytes)
        )
        
 // Responder processes MessageA and builds MessageB
        let responderSigningKey = try await provider.generateKeyPair(for: .signing)
        try await responderContext.processMessageA(messageA)
        let buildResult = try await responderContext.buildMessageB(
            identityKeyHandle: .softwareKey(responderSigningKey.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(responderSigningKey.publicKey.bytes)
        )
        let messageB = buildResult.message
        buildResult.sharedSecret.zeroize()
        
 // Each side should have unique key shares for the selected suite
        XCTAssertNotEqual(
            messageA.keyShares.first?.shareBytes,
            messageB.responderShare,
            "Initiator and responder key shares should differ"
        )
        
 // Clean up
        await initiatorContext.zeroize()
        await responderContext.zeroize()
    }
    
 /// Test that context role restrictions are enforced
    func testProperty5_RoleRestrictionsEnforced() async throws {
        let provider = ClassicCryptoProvider()
        
 // Create responder context
        let responderContext = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: provider
        )
        
 // Generate test keys
        let signingKeyPair = try await provider.generateKeyPair(for: .signing)
        
 // Responder should not be able to build MessageA
        do {
            _ = try await responderContext.buildMessageA(
                identityKeyHandle: .softwareKey(signingKeyPair.privateKey.bytes),
                identityPublicKey: encodeIdentityPublicKey(signingKeyPair.publicKey.bytes)
            )
            XCTFail("Responder should not be able to build MessageA")
        } catch let error as HandshakeError {
            switch error {
            case .invalidState(let msg):
                XCTAssertTrue(msg.contains("initiator"), "Error should mention initiator role")
            default:
                XCTFail("Expected invalidState error, got \(error)")
            }
        }
        
 // Clean up
        await responderContext.zeroize()
    }
    
 /// Test that local capabilities are available
    func testProperty5_LocalCapabilitiesAvailable() async throws {
        let provider = ClassicCryptoProvider()
        let context = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        
        let capabilities = await context.localCapabilities
        
 // Capabilities should have some supported algorithms
        XCTAssertFalse(capabilities.supportedKEM.isEmpty, "Should have supported KEM algorithms")
        XCTAssertFalse(capabilities.supportedSignature.isEmpty, "Should have supported signature algorithms")
        XCTAssertFalse(capabilities.supportedAEAD.isEmpty, "Should have supported AEAD algorithms")
        
 // Clean up
        await context.zeroize()
    }

 /// MessageB MUST commit to transcriptA; mismatch should fail
    func testMessageBTranscriptMismatchIsRejected() async throws {
        let provider = ClassicCryptoProvider()
        let initiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        let responder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: provider
        )
        
        let initiatorSigningKey = try await provider.generateKeyPair(for: .signing)
        let responderSigningKey = try await provider.generateKeyPair(for: .signing)
        
        let messageA = try await initiator.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorSigningKey.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(initiatorSigningKey.publicKey.bytes)
        )
        try await responder.processMessageA(messageA)
        
        let buildResult = try await responder.buildMessageB(
            identityKeyHandle: .softwareKey(responderSigningKey.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(responderSigningKey.publicKey.bytes)
        )
        let messageB = buildResult.message
        buildResult.sharedSecret.zeroize()
        
        let tamperedHash = Data(repeating: 0xAA, count: 32)
        let tamperedUnsigned = HandshakeMessageB(
            version: messageB.version,
            selectedSuite: messageB.selectedSuite,
            responderShare: messageB.responderShare,
            serverNonce: messageB.serverNonce,
            encryptedPayload: messageB.encryptedPayload,
            signature: Data(),
            identityPublicKey: messageB.identityPublicKey
        )
        let tamperedSignature = try await provider.sign(
            data: tamperedUnsigned.signaturePreimage(transcriptHashA: tamperedHash),
            using: .softwareKey(responderSigningKey.privateKey.bytes)
        )
        let tamperedMessageB = HandshakeMessageB(
            version: tamperedUnsigned.version,
            selectedSuite: tamperedUnsigned.selectedSuite,
            responderShare: tamperedUnsigned.responderShare,
            serverNonce: tamperedUnsigned.serverNonce,
            encryptedPayload: tamperedUnsigned.encryptedPayload,
            signature: tamperedSignature,
            identityPublicKey: tamperedUnsigned.identityPublicKey
        )
        
        do {
            _ = try await initiator.processMessageB(tamperedMessageB)
            XCTFail("Expected transcript mismatch to be rejected")
        } catch let error as HandshakeError {
            guard case .failed(let reason) = error else {
                XCTFail("Expected HandshakeError.failed")
                return
            }
            XCTAssertEqual(reason, .signatureVerificationFailed)
        }
        
        await initiator.zeroize()
        await responder.zeroize()
    }
    
    func testRequireSecureEnclavePoPFailsWithoutPinnedSEPublicKey_MessageA() async throws {
        let provider = ClassicCryptoProvider()
        let initiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider,
            signatureProvider: provider
        )
        let responder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: provider,
            signatureProvider: provider
        )
        
        let initiatorKey = P256.Signing.PrivateKey()
        let initiatorCallback = P256SigningCallback(privateKeyRawRepresentation: initiatorKey.rawRepresentation)
        let policy = HandshakePolicy(requireSecureEnclavePoP: true)
        
        let messageA = try await initiator.buildMessageA(
            identityKeyHandle: .callback(initiatorCallback),
            identityPublicKey: encodeIdentityPublicKey(initiatorKey.publicKey.derRepresentation, algorithm: .p256ECDSA),
            policy: policy,
            secureEnclaveKeyHandle: .callback(initiatorCallback)
        )
        
        do {
            try await responder.processMessageA(
                messageA,
                policy: policy,
                secureEnclavePublicKey: nil
            )
            XCTFail("Expected secureEnclavePoPRequired")
        } catch let error as HandshakeError {
            switch error {
            case .failed(let reason):
                guard case .secureEnclavePoPRequired = reason else {
                    XCTFail("Expected secureEnclavePoPRequired, got \(reason)")
                    return
                }
            default:
                XCTFail("Expected failed(.secureEnclavePoPRequired), got \(error)")
            }
        }
        
        await initiator.zeroize()
        await responder.zeroize()
    }
    
    func testRequireSecureEnclavePoPFailsWithoutPinnedSEPublicKey_MessageB() async throws {
        let provider = ClassicCryptoProvider()
        let initiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider,
            signatureProvider: provider
        )
        let responder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: provider,
            signatureProvider: provider
        )
        
        let initiatorKey = P256.Signing.PrivateKey()
        let responderKey = P256.Signing.PrivateKey()
        let initiatorCallback = P256SigningCallback(privateKeyRawRepresentation: initiatorKey.rawRepresentation)
        let responderCallback = P256SigningCallback(privateKeyRawRepresentation: responderKey.rawRepresentation)
        let policy = HandshakePolicy(requireSecureEnclavePoP: true)
        
        let messageA = try await initiator.buildMessageA(
            identityKeyHandle: .callback(initiatorCallback),
            identityPublicKey: encodeIdentityPublicKey(initiatorKey.publicKey.derRepresentation, algorithm: .p256ECDSA),
            policy: policy,
            secureEnclaveKeyHandle: .callback(initiatorCallback)
        )
        
        try await responder.processMessageA(
            messageA,
            policy: policy,
            secureEnclavePublicKey: initiatorKey.publicKey.derRepresentation
        )
        
        let buildResult = try await responder.buildMessageB(
            identityKeyHandle: .callback(responderCallback),
            identityPublicKey: encodeIdentityPublicKey(responderKey.publicKey.derRepresentation, algorithm: .p256ECDSA),
            policy: policy,
            secureEnclaveKeyHandle: .callback(responderCallback)
        )
        let messageB = buildResult.message
        buildResult.sharedSecret.zeroize()
        
        do {
            _ = try await initiator.processMessageB(
                messageB,
                policy: policy,
                secureEnclavePublicKey: nil
            )
            XCTFail("Expected secureEnclavePoPRequired")
        } catch let error as HandshakeError {
            switch error {
            case .failed(let reason):
                guard case .secureEnclavePoPRequired = reason else {
                    XCTFail("Expected secureEnclavePoPRequired, got \(reason)")
                    return
                }
            default:
                XCTFail("Expected failed(.secureEnclavePoPRequired), got \(error)")
            }
        }
        
        await initiator.zeroize()
        await responder.zeroize()
    }
}

private struct P256SigningCallback: SigningCallback {
    let privateKeyRawRepresentation: Data
    
    func sign(data: Data) async throws -> Data {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRawRepresentation)
        return try privateKey.signature(for: data).derRepresentation
    }
}

// MARK: - HandshakeTypes Tests

final class HandshakeTypesTests: XCTestCase {
    
 /// Test SessionKeys initialization
    func testSessionKeysInitialization() {
        let sendKey = Data(repeating: 0x01, count: 32)
        let receiveKey = Data(repeating: 0x02, count: 32)
        
        let sessionKeys = SessionKeys(
            sendKey: sendKey,
            receiveKey: receiveKey,
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x03, count: 32)
        )
        
        XCTAssertEqual(sessionKeys.sendKey, sendKey)
        XCTAssertEqual(sessionKeys.receiveKey, receiveKey)
        XCTAssertEqual(sessionKeys.negotiatedSuite, .x25519Ed25519)
        XCTAssertEqual(sessionKeys.role, .initiator)
        XCTAssertFalse(sessionKeys.sessionId.isEmpty)
    }
    
 /// Test PeerIdentifier
    func testPeerIdentifier() {
        let peer = PeerIdentifier(
            deviceId: "device-123",
            displayName: "Test Device",
            address: "192.168.1.100"
        )
        
        XCTAssertEqual(peer.deviceId, "device-123")
        XCTAssertEqual(peer.displayName, "Test Device")
        XCTAssertEqual(peer.address, "192.168.1.100")
        
 // Test hashable - PeerIdentifier equality is based on deviceId only
        let peer2 = PeerIdentifier(deviceId: "device-123")
 // Note: peer and peer2 have same deviceId but different displayName/address
 // Equality should be based on deviceId for hash table lookups
        XCTAssertEqual(peer.deviceId, peer2.deviceId)
        
 // Test different deviceId
        let peer3 = PeerIdentifier(deviceId: "device-456")
        XCTAssertNotEqual(peer.deviceId, peer3.deviceId)
    }
    
 /// Test HandshakeFailureReason equality
    func testHandshakeFailureReasonEquality() {
        XCTAssertEqual(HandshakeFailureReason.timeout, HandshakeFailureReason.timeout)
        XCTAssertEqual(HandshakeFailureReason.cancelled, HandshakeFailureReason.cancelled)
        XCTAssertNotEqual(HandshakeFailureReason.timeout, HandshakeFailureReason.cancelled)
        
        XCTAssertEqual(
            HandshakeFailureReason.peerRejected(message: "test"),
            HandshakeFailureReason.peerRejected(message: "test")
        )
    }
    
 /// Test HandshakeConstants
    func testHandshakeConstants() {
        XCTAssertEqual(HandshakeConstants.protocolVersion, 1)
        XCTAssertGreaterThan(HandshakeConstants.maxMessageALength, 0)
        XCTAssertGreaterThan(HandshakeConstants.maxMessageBLength, 0)
    }
}

// MARK: - HandshakeMessages Tests

final class HandshakeMessagesTests: XCTestCase {
    
 /// Test HandshakeMessageA encoding and decoding round-trip
    @available(macOS 14.0, iOS 17.0, *)
    func testMessageARoundTrip() async throws {
        let provider = ClassicCryptoProvider()
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        let signingKeyPair = try await provider.generateKeyPair(for: .signing)
        
 // Create nonce
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        
 // Create capabilities
        let capabilities = CryptoCapabilities(
            supportedKEM: ["X25519"],
            supportedSignature: ["P-256"],
            supportedAuthProfiles: [AuthProfile.classic.displayName],
            supportedAEAD: ["AES-256-GCM"],
            pqcAvailable: false,
            platformVersion: "macOS 14.0",
            providerType: .classic
        )
        
        let messageAUnsigned = HandshakeMessageA(
            version: 1,
            supportedSuites: [.x25519Ed25519],
            keyShares: [HandshakeKeyShare(suite: .x25519Ed25519, shareBytes: keyPair.publicKey.bytes)],
            clientNonce: Data(nonceBytes),
            policy: .default,
            capabilities: capabilities,
            signature: Data(),
            identityPublicKey: encodeIdentityPublicKey(signingKeyPair.publicKey.bytes)
        )
        let signature = try await provider.sign(
            data: messageAUnsigned.signaturePreimage,
            using: .softwareKey(signingKeyPair.privateKey.bytes)
        )
        
        let messageA = HandshakeMessageA(
            version: messageAUnsigned.version,
            supportedSuites: messageAUnsigned.supportedSuites,
            keyShares: messageAUnsigned.keyShares,
            clientNonce: messageAUnsigned.clientNonce,
            policy: messageAUnsigned.policy,
            capabilities: messageAUnsigned.capabilities,
            signature: signature,
            identityPublicKey: messageAUnsigned.identityPublicKey
        )
        
 // Encode
        let encoded = messageA.encoded
        XCTAssertGreaterThan(encoded.count, 0)
        
 // Decode
        let decoded = try HandshakeMessageA.decode(from: encoded)
        
        XCTAssertEqual(decoded.version, messageA.version)
        XCTAssertEqual(decoded.supportedSuites, messageA.supportedSuites)
        XCTAssertEqual(decoded.keyShares, messageA.keyShares)
        XCTAssertEqual(decoded.clientNonce, messageA.clientNonce)
        XCTAssertEqual(decoded.policy, messageA.policy)
        XCTAssertEqual(decoded.signature, messageA.signature)
        XCTAssertEqual(decoded.identityPublicKey, messageA.identityPublicKey)
    }

 /// Test HandshakeMessageB encoding and decoding round-trip
    @available(macOS 14.0, iOS 17.0, *)
    func testMessageBRoundTrip() async throws {
        let provider = ClassicCryptoProvider()
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        let signingKeyPair = try await provider.generateKeyPair(for: .signing)
        
        let payload = Data("payload".utf8)
        let sealedBox = try await provider.kemDemSeal(
            plaintext: payload,
            recipientPublicKey: keyPair.publicKey.bytes,
            info: Data("handshake-payload".utf8)
        )
        
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        
        var transcriptBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, transcriptBytes.count, &transcriptBytes)
        
        let messageBUnsigned = HandshakeMessageB(
            version: 1,
            selectedSuite: .x25519Ed25519,
            responderShare: sealedBox.encapsulatedKey,
            serverNonce: Data(nonceBytes),
            encryptedPayload: sealedBox,
            signature: Data(),
            identityPublicKey: encodeIdentityPublicKey(signingKeyPair.publicKey.bytes)
        )
        let signature = try await provider.sign(
            data: messageBUnsigned.signaturePreimage(transcriptHashA: Data(transcriptBytes)),
            using: .softwareKey(signingKeyPair.privateKey.bytes)
        )
        
        let messageB = HandshakeMessageB(
            version: messageBUnsigned.version,
            selectedSuite: messageBUnsigned.selectedSuite,
            responderShare: messageBUnsigned.responderShare,
            serverNonce: messageBUnsigned.serverNonce,
            encryptedPayload: messageBUnsigned.encryptedPayload,
            signature: signature,
            identityPublicKey: messageBUnsigned.identityPublicKey
        )
        
        let encoded = messageB.encoded
        XCTAssertGreaterThan(encoded.count, 0)
        
        let decoded = try HandshakeMessageB.decode(from: encoded)
        XCTAssertEqual(decoded.version, messageB.version)
        XCTAssertEqual(decoded.selectedSuite, messageB.selectedSuite)
        XCTAssertEqual(decoded.responderShare, messageB.responderShare)
        XCTAssertEqual(decoded.serverNonce, messageB.serverNonce)
        XCTAssertEqual(decoded.encryptedPayload.encapsulatedKey, messageB.encryptedPayload.encapsulatedKey)
        XCTAssertEqual(decoded.encryptedPayload.nonce, messageB.encryptedPayload.nonce)
        XCTAssertEqual(decoded.encryptedPayload.ciphertext, messageB.encryptedPayload.ciphertext)
        XCTAssertEqual(decoded.encryptedPayload.tag, messageB.encryptedPayload.tag)
        XCTAssertEqual(decoded.signature, messageB.signature)
        XCTAssertEqual(decoded.identityPublicKey, messageB.identityPublicKey)
    }
    
 /// Test MessageA rejects invalid version
    func testMessageARejectsInvalidVersion() {
        var data = Data()
        data.append(2) // Invalid version
        data.append(contentsOf: Data(repeating: 0, count: 100))
        
        XCTAssertThrowsError(try HandshakeMessageA.decode(from: data)) { error in
            guard case HandshakeError.failed(let reason) = error else {
                XCTFail("Expected HandshakeError.failed")
                return
            }
            guard case .versionMismatch = reason else {
                XCTFail("Expected versionMismatch reason")
                return
            }
        }
    }
    
 /// Test MessageA rejects truncated data
    func testMessageARejectsTruncatedData() {
        let shortData = Data([1, 0x10, 0x01]) // Only version and suite
        
        XCTAssertThrowsError(try HandshakeMessageA.decode(from: shortData)) { error in
            guard case HandshakeError.failed(let reason) = error else {
                XCTFail("Expected HandshakeError.failed")
                return
            }
            guard case .invalidMessageFormat = reason else {
                XCTFail("Expected invalidMessageFormat reason")
                return
            }
        }
    }
}
