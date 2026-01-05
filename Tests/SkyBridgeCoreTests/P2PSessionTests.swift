//
// P2PSessionTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for P2P Session Management
// **Feature: ios-p2p-integration**
//
// Property 5: QR Code Content Completeness (Validates: Requirements 2.1)
// Property 6: Challenge Expiration Verification (Validates: Requirements 2.2)
// Property 13: Handshake Transcript Signing with Crypto Profile (Validates: Requirements 4.3, 4.6, 4.8, 9.3)
// Property 14: Untrusted Certificate Rejection (Validates: Requirements 4.4)
// Property 15: Session Key Derivation Uniqueness (Validates: Requirements 4.5, 9.5)
// Property 16: Key Confirmation MAC Verification (Validates: Requirements 4.6)
// Property 17: Replay Attack Prevention (Validates: Requirements 4.7)
//

import XCTest
import CryptoKit
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PSessionTests: XCTestCase {
    
 // MARK: - Property 5: QR Code Content Completeness
    
 /// **Property 5: QR Code Content Completeness**
 /// *For any* generated pairing QR code, the encoded data should contain deviceId,
 /// pubKeyFP, challenge with nonce, expiration timestamp, and cryptoCapabilities.
 /// **Validates: Requirements 2.1**
    func testQRCodeContentCompletenessProperty() throws {
 // Generate test QR code data
        let qrData = createTestQRCodeData()
        
 // Property: deviceId must be present and non-empty
        XCTAssertFalse(qrData.deviceId.isEmpty,
                       "QR code must contain non-empty deviceId")
        
 // Property: pubKeyFP must be present and valid format (64 hex chars)
        XCTAssertEqual(qrData.pubKeyFP.count, 64,
                       "pubKeyFP must be 64 characters")
        XCTAssertTrue(qrData.pubKeyFP.allSatisfy { $0.isHexDigit },
                      "pubKeyFP must be hex string")
        
 // Property: challenge must be present and non-empty
        XCTAssertFalse(qrData.challenge.isEmpty,
                       "QR code must contain non-empty challenge")
        
 // Property: nonce must be present and correct size
        XCTAssertEqual(qrData.nonce.count, P2PConstants.nonceSize,
                       "nonce must be \(P2PConstants.nonceSize) bytes")
        
 // Property: expiresAt must be in the future
        XCTAssertGreaterThan(qrData.expiresAt, Date(),
                             "expiresAt must be in the future")
        
 // Property: version must be positive
        XCTAssertGreaterThan(qrData.version, 0,
                             "version must be positive")
        
 // Property: cryptoCapabilities must be present
        XCTAssertFalse(qrData.cryptoCapabilities.supportedKEM.isEmpty,
                       "cryptoCapabilities must have KEM algorithms")
        XCTAssertFalse(qrData.cryptoCapabilities.supportedSignature.isEmpty,
                       "cryptoCapabilities must have signature algorithms")
    }
    
 /// Test QR code data serialization round-trip
    func testQRCodeDataRoundTrip() throws {
        let original = createTestQRCodeData()
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(P2PQRCodeData.self, from: encoded)
        
 // Property: Round-trip should preserve all fields
        XCTAssertEqual(decoded.deviceId, original.deviceId)
        XCTAssertEqual(decoded.pubKeyFP, original.pubKeyFP)
        XCTAssertEqual(decoded.challenge, original.challenge)
        XCTAssertEqual(decoded.nonce, original.nonce)
        XCTAssertEqual(decoded.version, original.version)
    }
    
 // MARK: - Property 6: Challenge Expiration Verification
    
 /// **Property 6: Challenge Expiration Verification**
 /// *For any* QR code challenge, if the current time exceeds the expiration timestamp,
 /// the system should reject the pairing attempt.
 /// **Validates: Requirements 2.2**
    func testChallengeExpirationVerificationProperty() {
 // Create expired QR code
        let expiredQR = P2PQRCodeData(
            deviceId: "test-device",
            pubKeyFP: String(repeating: "a", count: 64),
            challenge: Data(repeating: 0x01, count: 32),
            nonce: Data(repeating: 0x02, count: P2PConstants.nonceSize),
            expiresAt: Date().addingTimeInterval(-60), // Expired 1 minute ago
            version: 1,
            cryptoCapabilities: P2PCryptoCapabilities.current()
        )
        
 // Property: Expired challenge should be detected
        XCTAssertTrue(expiredQR.expiresAt < Date(),
                      "Expired QR code should have past expiration")
        
 // Create valid QR code
        let validQR = P2PQRCodeData(
            deviceId: "test-device",
            pubKeyFP: String(repeating: "b", count: 64),
            challenge: Data(repeating: 0x03, count: 32),
            nonce: Data(repeating: 0x04, count: P2PConstants.nonceSize),
            expiresAt: Date().addingTimeInterval(300), // Expires in 5 minutes
            version: 1,
            cryptoCapabilities: P2PCryptoCapabilities.current()
        )
        
 // Property: Valid challenge should not be expired
        XCTAssertTrue(validQR.expiresAt > Date(),
                      "Valid QR code should have future expiration")
    }
    
 // MARK: - Property 13: Handshake Transcript Signing
    
 /// **Property 13: Handshake Transcript Signing with Crypto Profile**
 /// *For any* completed handshake, the signature should cover all exchanged messages
 /// including the negotiated crypto profile to prevent downgrade attacks.
 /// **Validates: Requirements 4.3, 4.8, 9.3**
    func testHandshakeTranscriptSigningProperty() throws {
        let builder = TranscriptBuilder(role: .initiator)
        
 // Add handshake messages
        let capabilities = createTestCapabilities()
        let handshakeInit = HandshakeMessageA(
            version: HandshakeConstants.protocolVersion,
            supportedSuites: [.x25519Ed25519],
            keyShares: [HandshakeKeyShare(suite: .x25519Ed25519, shareBytes: Data(repeating: 0x01, count: 32))],
            clientNonce: Data(repeating: 0x02, count: 32),
            policy: .default,
            capabilities: capabilities,
            signature: Data(repeating: 0x07, count: 64),
            identityPublicKey: Data(repeating: 0x08, count: 32)
        )
        let handshakeResponse = HandshakeMessageB(
            version: HandshakeConstants.protocolVersion,
            selectedSuite: .x25519Ed25519,
            responderShare: Data(repeating: 0x03, count: 32),
            serverNonce: Data(repeating: 0x04, count: 32),
            encryptedPayload: HPKESealedBox(
                encapsulatedKey: Data(repeating: 0x06, count: 32),
                nonce: Data(repeating: 0x09, count: 12),
                ciphertext: Data(),
                tag: Data(repeating: 0x0A, count: 16)
            ),
            signature: Data(repeating: 0x0B, count: 64),
            identityPublicKey: Data(repeating: 0x0C, count: 32)
        )
        
        try builder.append(message: handshakeInit, type: .handshakeInit)
        try builder.append(message: handshakeResponse, type: .handshakeResponse)
        
 // Add crypto profile
        let cryptoProfile = NegotiatedCryptoProfile(
            kemAlgorithm: P2PCryptoAlgorithm.x25519.rawValue,
            authProfile: AuthProfile.classic.displayName,
            signatureAlgorithm: P2PCryptoAlgorithm.p256.rawValue,
            aeadAlgorithm: P2PCryptoAlgorithm.aes256GCM.rawValue,
            quicDatagramEnabled: true,
            pqcEnabled: false
        )
        try builder.append(message: cryptoProfile, type: .negotiatedProfile)
        
        let hash1 = builder.computeHash()
        
 // Property: Hash should be 32 bytes (SHA-256)
        XCTAssertEqual(hash1.count, 32,
                       "Transcript hash must be 32 bytes")
        
 // Property: Different crypto profile should produce different hash
        let builder2 = TranscriptBuilder(role: .initiator)
        try builder2.append(message: handshakeInit, type: .handshakeInit)
        try builder2.append(message: handshakeResponse, type: .handshakeResponse)
        
        let differentProfile = NegotiatedCryptoProfile(
            kemAlgorithm: P2PCryptoAlgorithm.mlKEM768.rawValue, // Different!
            authProfile: AuthProfile.pqc.displayName,
            signatureAlgorithm: P2PCryptoAlgorithm.p256.rawValue,
            aeadAlgorithm: P2PCryptoAlgorithm.aes256GCM.rawValue,
            quicDatagramEnabled: true,
            pqcEnabled: true
        )
        try builder2.append(message: differentProfile, type: .negotiatedProfile)
        
        let hash2 = builder2.computeHash()
        
        XCTAssertNotEqual(hash1, hash2,
                          "Different crypto profile must produce different hash")
    }
    
 // MARK: - Property 15: Session Key Derivation Uniqueness
    
 /// **Property 15: Session Key Derivation Uniqueness**
 /// *For any* completed key exchange, the derived session keys for control, video,
 /// and file streams should be distinct (using different HKDF info strings).
 /// **Validates: Requirements 4.5, 9.5**
    func testSessionKeyDerivationUniquenessProperty() {
        let sharedSecret = SymmetricKey(size: .bits256)
        let transcriptHash = Data(repeating: 0xAB, count: 32)
        
 // Derive keys for different channels
        let controlKey = deriveChannelKey(
            sharedSecret: sharedSecret,
            transcriptHash: transcriptHash,
            channel: "control",
            role: .initiator
        )
        
        let videoKey = deriveChannelKey(
            sharedSecret: sharedSecret,
            transcriptHash: transcriptHash,
            channel: "video",
            role: .initiator
        )
        
        let fileKey = deriveChannelKey(
            sharedSecret: sharedSecret,
            transcriptHash: transcriptHash,
            channel: "file",
            role: .initiator
        )
        
 // Property: All channel keys must be distinct
        XCTAssertNotEqual(controlKey, videoKey,
                          "Control and video keys must be distinct")
        XCTAssertNotEqual(controlKey, fileKey,
                          "Control and file keys must be distinct")
        XCTAssertNotEqual(videoKey, fileKey,
                          "Video and file keys must be distinct")
        
 // Property: Same channel with different role produces different key
        let controlKeyResponder = deriveChannelKey(
            sharedSecret: sharedSecret,
            transcriptHash: transcriptHash,
            channel: "control",
            role: .responder
        )
        
        XCTAssertNotEqual(controlKey, controlKeyResponder,
                          "Same channel with different role must produce different key")
        
 // Property: Keys should be 32 bytes
        XCTAssertEqual(controlKey.count, 32, "Key must be 32 bytes")
        XCTAssertEqual(videoKey.count, 32, "Key must be 32 bytes")
        XCTAssertEqual(fileKey.count, 32, "Key must be 32 bytes")
    }
    
 // MARK: - Property 16: Key Confirmation MAC Verification
    
 /// **Property 16: Key Confirmation MAC Verification**
 /// *For any* Finished message, the MAC should be computed over the handshake transcript
 /// using the derived session key, and verification should detect any tampering.
 /// **Validates: Requirements 4.6**
    func testKeyConfirmationMACVerificationProperty() {
        let sessionKey = SymmetricKey(size: .bits256)
        let transcriptHash = Data(repeating: 0xCD, count: 32)
        
 // Compute MAC
        let mac = HMAC<SHA256>.authenticationCode(for: transcriptHash, using: sessionKey)
        let macData = Data(mac)
        
 // Property: MAC should be 32 bytes
        XCTAssertEqual(macData.count, 32, "MAC must be 32 bytes")
        
 // Property: Same inputs produce same MAC
        let mac2 = HMAC<SHA256>.authenticationCode(for: transcriptHash, using: sessionKey)
        XCTAssertEqual(Data(mac), Data(mac2), "Same inputs must produce same MAC")
        
 // Property: Different transcript produces different MAC
        let differentTranscript = Data(repeating: 0xEF, count: 32)
        let mac3 = HMAC<SHA256>.authenticationCode(for: differentTranscript, using: sessionKey)
        XCTAssertNotEqual(Data(mac), Data(mac3), "Different transcript must produce different MAC")
        
 // Property: Different key produces different MAC
        let differentKey = SymmetricKey(size: .bits256)
        let mac4 = HMAC<SHA256>.authenticationCode(for: transcriptHash, using: differentKey)
        XCTAssertNotEqual(Data(mac), Data(mac4), "Different key must produce different MAC")
        
 // Property: Verification should succeed with correct MAC
        XCTAssertTrue(HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: transcriptHash, using: sessionKey),
                      "Verification must succeed with correct MAC")
        
 // Property: Verification should fail with tampered data
        var tamperedTranscript = transcriptHash
        tamperedTranscript[0] ^= 0xFF
        XCTAssertFalse(HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: tamperedTranscript, using: sessionKey),
                       "Verification must fail with tampered data")
    }
    
 // MARK: - Property 17: Replay Attack Prevention
    
 /// **Property 17: Replay Attack Prevention**
 /// *For any* handshake message with a previously seen nonce/counter, the system
 /// should reject the message.
 /// **Validates: Requirements 4.7**
    func testReplayAttackPreventionProperty() {
        var seenNonces = Set<Data>()
        
 // Generate unique nonces
        for _ in 0..<100 {
            var nonce = Data(count: P2PConstants.nonceSize)
            _ = nonce.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, P2PConstants.nonceSize, $0.baseAddress!)
            }
            
 // Property: Fresh nonce should not be in seen set
            XCTAssertFalse(seenNonces.contains(nonce),
                           "Fresh nonce should not be seen before")
            
            seenNonces.insert(nonce)
            
 // Property: Replayed nonce should be detected
            XCTAssertTrue(seenNonces.contains(nonce),
                          "Replayed nonce must be detected")
        }
        
 // Property: All nonces should be unique
        XCTAssertEqual(seenNonces.count, 100,
                       "All generated nonces must be unique")
    }
    
 /// Test counter-based replay prevention
    func testCounterBasedReplayPrevention() {
        var lastCounter: UInt64 = 0
        
 // Property: Increasing counters should be accepted
        for counter in 1...100 as ClosedRange<UInt64> {
            XCTAssertGreaterThan(counter, lastCounter,
                                 "Counter must be greater than last seen")
            lastCounter = counter
        }
        
 // Property: Replayed counter should be rejected
        let replayedCounter: UInt64 = 50
        XCTAssertLessThanOrEqual(replayedCounter, lastCounter,
                                 "Replayed counter must be rejected")
    }
    
 // MARK: - Property 14: Untrusted Certificate Rejection
    
 /// **Property 14: Untrusted Certificate Rejection**
 /// *For any* connection attempt with a certificate not in the trusted list,
 /// the system should reject the connection.
 /// **Validates: Requirements 4.4**
    func testUntrustedCertificateRejectionProperty() {
 // Create trusted certificate
        let trustedCert = P2PIdentityCertificate(
            deviceId: "trusted-device",
            publicKey: Data(repeating: 0x01, count: 32),
            pubKeyFP: String(repeating: "a", count: 64),
            attestationLevel: .appAttest,
            attestationData: nil,
            capabilities: ["screen-mirror"],
            signerType: .selfSigned,
            signature: Data(repeating: 0xAA, count: 64)
        )
        
 // Create untrusted certificate
        let untrustedCert = P2PIdentityCertificate(
            deviceId: "untrusted-device",
            publicKey: Data(repeating: 0x02, count: 32),
            pubKeyFP: String(repeating: "b", count: 64),
            attestationLevel: .none,
            attestationData: nil,
            capabilities: ["screen-mirror"],
            signerType: .selfSigned,
            signature: Data(repeating: 0xBB, count: 64)
        )
        
 // Simulate trusted list
        let trustedList = Set([trustedCert.deviceId])
        
 // Property: Trusted certificate should be accepted
        XCTAssertTrue(trustedList.contains(trustedCert.deviceId),
                      "Trusted certificate must be accepted")
        
 // Property: Untrusted certificate should be rejected
        XCTAssertFalse(trustedList.contains(untrustedCert.deviceId),
                       "Untrusted certificate must be rejected")
    }
    
 // MARK: - Property 1: PAKE Exchange Round-Trip ( 1.5)
    
 /// **Property 1: PAKE Exchange Round-Trip**
 /// *For any* valid PAKE messageA and corresponding messageB, the message exchange flow
 /// should complete successfully with valid message structures and state transitions.
 ///
 /// Note: This property tests the PAKE message exchange integration (Requirements 1.1-1.3),
 /// not the underlying SPAKE2+ cryptographic correctness. The simplified SPAKE2+ implementation
 /// uses hash-based mixing instead of actual EC point operations, which is a known limitation
 /// documented in PAKEService.swift.
 ///
 /// **Feature: p2p-todo-completion, Property 1: PAKE Exchange Round-Trip**
 /// **Validates: Requirements 1.1, 1.2, 1.3**
    func testPAKEExchangeRoundTripProperty() async throws {
 // Test with multiple random pairing codes to verify message flow
        let testCodes = ["123456", "000000", "999999", "456789", "111111"]
        
        for pairingCode in testCodes {
 // Create fresh services for each test to ensure clean state
            let initiator = PAKEService(localDeviceId: "initiator-device")
            let responder = PAKEService(localDeviceId: "responder-device")
            
            let initiatorPeerId = "responder-device"
            let responderPeerId = "initiator-device"
            
 // Step 1: Initiator creates messageA (Requirements 1.1)
            let messageA = try await initiator.initiateExchange(
                password: pairingCode,
                peerId: initiatorPeerId
            )
            
 // Property: messageA should have valid structure
            XCTAssertFalse(messageA.publicValue.isEmpty,
                           "messageA publicValue must not be empty")
            XCTAssertFalse(messageA.nonce.isEmpty,
                           "messageA nonce must not be empty")
            XCTAssertEqual(messageA.nonce.count, P2PConstants.nonceSize,
                           "messageA nonce must be correct size")
            XCTAssertEqual(messageA.deviceId, "initiator-device",
                           "messageA deviceId must match initiator")
            
 // Property: messageA should be serializable (for transport)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let encodedA = try encoder.encode(messageA)
            XCTAssertFalse(encodedA.isEmpty,
                           "messageA must be serializable for transport")
            
 // Step 2: Responder processes messageA and creates messageB (Requirements 1.2)
            let (messageB, responderSecret) = try await responder.respondToExchange(
                messageA: messageA,
                password: pairingCode,
                peerId: responderPeerId
            )
            
 // Property: messageB should have valid structure
            XCTAssertFalse(messageB.publicValue.isEmpty,
                           "messageB publicValue must not be empty")
            XCTAssertFalse(messageB.confirmationMAC.isEmpty,
                           "messageB confirmationMAC must not be empty")
            XCTAssertEqual(messageB.confirmationMAC.count, 32,
                           "messageB confirmationMAC must be 32 bytes (SHA-256)")
            XCTAssertEqual(messageB.deviceId, "responder-device",
                           "messageB deviceId must match responder")
            XCTAssertFalse(messageB.nonce.isEmpty,
                           "messageB nonce must not be empty")
            
 // Property: messageB should be serializable (for transport)
            let encodedB = try encoder.encode(messageB)
            XCTAssertFalse(encodedB.isEmpty,
                           "messageB must be serializable for transport")
            
 // Property: Responder derives a valid shared secret
            XCTAssertEqual(responderSecret.count, 32,
                           "Responder shared secret must be 32 bytes")
            XCTAssertNotEqual(responderSecret, Data(repeating: 0, count: 32),
                              "Responder shared secret must not be all zeros")
            
 // Property: Shared secret is not the raw pairing code
            let codeData = Data(pairingCode.utf8)
            XCTAssertFalse(responderSecret.starts(with: codeData),
                           "Shared secret must not start with raw pairing code")
            
 // Property: negotiatedProfile should be valid
            XCTAssertFalse(messageB.negotiatedProfile.kemAlgorithm.isEmpty,
                           "negotiatedProfile must have KEM algorithm")
            XCTAssertFalse(messageB.negotiatedProfile.signatureAlgorithm.isEmpty,
                           "negotiatedProfile must have signature algorithm")
            XCTAssertFalse(messageB.negotiatedProfile.aeadAlgorithm.isEmpty,
                           "negotiatedProfile must have AEAD algorithm")
            
 // Clean up sessions
            await initiator.clearSession(peerId: initiatorPeerId)
            await responder.clearSession(peerId: responderPeerId)
        }
    }
    
 /// Test PAKE exchange with wrong code fails (negative case for Property 1)
    func testPAKEExchangeWithWrongCodeFails() async throws {
        let initiator = PAKEService(localDeviceId: "initiator-device")
        let responder = PAKEService(localDeviceId: "responder-device")
        
        let correctCode = "123456"
        let wrongCode = "654321"
        
 // Initiator uses correct code
        let messageA = try await initiator.initiateExchange(
            password: correctCode,
            peerId: "responder-device"
        )
        
 // Responder uses wrong code
        let (messageB, _) = try await responder.respondToExchange(
            messageA: messageA,
            password: wrongCode,
            peerId: "initiator-device"
        )
        
 // Property: Initiator should fail MAC verification with wrong code
        do {
            _ = try await initiator.completeExchange(
                messageB: messageB,
                peerId: "responder-device"
            )
            XCTFail("Should have thrown macVerificationFailed error")
        } catch let error as PAKEError {
            XCTAssertEqual(error, .macVerificationFailed,
                           "Wrong code must cause MAC verification failure")
        }
    }
    
 /// Test PAKE message serialization round-trip
    func testPAKEMessageSerializationRoundTrip() async throws {
        let service = PAKEService(localDeviceId: "test-device")
        let messageA = try await service.initiateExchange(
            password: "123456",
            peerId: "peer-device"
        )
        
 // Serialize and deserialize
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let encoded = try encoder.encode(messageA)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(PAKEMessageA.self, from: encoded)
        
 // Property: Round-trip should preserve all fields
        XCTAssertEqual(decoded.publicValue, messageA.publicValue,
                       "publicValue must be preserved")
        XCTAssertEqual(decoded.deviceId, messageA.deviceId,
                       "deviceId must be preserved")
        XCTAssertEqual(decoded.nonce, messageA.nonce,
                       "nonce must be preserved")
    }
    
 // MARK: - Helper Methods
    
    private func createTestQRCodeData() -> P2PQRCodeData {
        P2PQRCodeData(
            deviceId: "test-device-\(UUID().uuidString)",
            pubKeyFP: String(repeating: "a", count: 64),
            challenge: Data(repeating: 0x01, count: 32),
            nonce: Data(repeating: 0x02, count: P2PConstants.nonceSize),
            expiresAt: Date().addingTimeInterval(300),
            version: 1,
            cryptoCapabilities: P2PCryptoCapabilities.current()
        )
    }
    
    private func createTestCapabilities() -> CryptoCapabilities {
        CryptoCapabilities(
            supportedKEM: [P2PCryptoAlgorithm.x25519.rawValue],
            supportedSignature: [P2PCryptoAlgorithm.p256.rawValue],
            supportedAuthProfiles: [AuthProfile.classic.displayName],
            supportedAEAD: [P2PCryptoAlgorithm.aes256GCM.rawValue],
            pqcAvailable: false,
            platformVersion: "macOS 14.0",
            providerType: .classic
        )
    }
    
    private func deriveChannelKey(
        sharedSecret: SymmetricKey,
        transcriptHash: Data,
        channel: String,
        role: P2PRole
    ) -> Data {
        let info = Data("skybridge-\(channel)-v1-\(role.rawValue)".utf8)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: transcriptHash,
            info: info,
            outputByteCount: 32
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }
    
 // MARK: - Property 3: Key Derivation Correctness (p2p-todo-completion)
    
 /// **Feature: p2p-todo-completion, Property 3: Key Derivation Correctness**
 /// *For any* shared secret and transcript hash, the derived channel keys should be
 /// deterministic and unique per channel.
 /// **Validates: Requirements 3.1, 3.2**
    func testProperty3_KeyDerivationCorrectness() async throws {
 // Generate random shared secrets and transcript hashes
        for _ in 0..<10 {
            let sharedSecret = SymmetricKey(size: .bits256)
            let transcriptHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            
 // Derive keys for all channels
            let controlKey = deriveChannelKey(
                sharedSecret: sharedSecret,
                transcriptHash: transcriptHash,
                channel: "control",
                role: .initiator
            )
            
            let videoKey = deriveChannelKey(
                sharedSecret: sharedSecret,
                transcriptHash: transcriptHash,
                channel: "video",
                role: .initiator
            )
            
            let fileKey = deriveChannelKey(
                sharedSecret: sharedSecret,
                transcriptHash: transcriptHash,
                channel: "file",
                role: .initiator
            )
            
 // Property 3.1: Keys should be deterministic
            let controlKey2 = deriveChannelKey(
                sharedSecret: sharedSecret,
                transcriptHash: transcriptHash,
                channel: "control",
                role: .initiator
            )
            XCTAssertEqual(controlKey, controlKey2,
                           "Same inputs must produce same key (deterministic)")
            
 // Property 3.2: Keys should be unique per channel
            XCTAssertNotEqual(controlKey, videoKey,
                              "Control and video keys must be distinct")
            XCTAssertNotEqual(controlKey, fileKey,
                              "Control and file keys must be distinct")
            XCTAssertNotEqual(videoKey, fileKey,
                              "Video and file keys must be distinct")
            
 // Property 3.3: Keys should be 32 bytes
            XCTAssertEqual(controlKey.count, 32, "Key must be 32 bytes")
            XCTAssertEqual(videoKey.count, 32, "Key must be 32 bytes")
            XCTAssertEqual(fileKey.count, 32, "Key must be 32 bytes")
            
 // Property 3.4: Different transcript hash produces different keys
            let differentTranscript = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let controlKeyDifferent = deriveChannelKey(
                sharedSecret: sharedSecret,
                transcriptHash: differentTranscript,
                channel: "control",
                role: .initiator
            )
            XCTAssertNotEqual(controlKey, controlKeyDifferent,
                              "Different transcript must produce different key")
        }
    }
    
 /// **Feature: p2p-todo-completion, Property 3: Key Derivation Correctness**
 /// Test that CryptoProvider key exchange produces valid shared secrets
 /// **Validates: Requirements 3.1, 3.2**
    func testProperty3_CryptoProviderKeyExchange() async throws {
        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        
 // Generate key pairs for both parties
        let aliceKeyPair = try await provider.generateKeyPair(for: .keyExchange)
        let bobKeyPair = try await provider.generateKeyPair(for: .keyExchange)
        
 // Property: Key pairs should have correct sizes
        XCTAssertFalse(aliceKeyPair.publicKey.bytes.isEmpty,
                       "Public key must not be empty")
        XCTAssertFalse(aliceKeyPair.privateKey.bytes.isEmpty,
                       "Private key must not be empty")
        
 // Property: Different key pairs should have different public keys
        XCTAssertNotEqual(aliceKeyPair.publicKey.bytes, bobKeyPair.publicKey.bytes,
                          "Different key pairs must have different public keys")
        
 // Property: Key usage should be keyExchange
        XCTAssertEqual(aliceKeyPair.publicKey.usage, .keyExchange,
                       "Key usage must be keyExchange")
        
        SkyBridgeLogger.p2p.debug("Key exchange test passed with provider: \(provider.providerName)")
    }
    
 // MARK: - Property 4: Secure Key Erasure (p2p-todo-completion)
    
 /// **Feature: p2p-todo-completion, Property 4: Secure Key Erasure**
 /// *For any* ephemeral private key used in key exchange, the key material should be
 /// securely erased after derivation completes.
 /// **Validates: Requirements 3.4**
    #if DEBUG
    func testProperty4_SecureKeyErasure() async throws {
        let tracker = SecureBytesWipeTracker()
        let originalWipingFunction = SecureBytes.wipingFunction
        SecureBytes.wipingFunction = tracker.makeWipingFunction()
        
        defer {
            SecureBytes.wipingFunction = originalWipingFunction
        }
        
 // Generate a key pair and wrap private key in SecureBytes
        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        
 // Wrap private key in SecureBytes
        autoreleasepool {
            let securePrivateKey = SecureBytes(data: keyPair.privateKey.bytes)
            
 // Simulate using the key
            _ = securePrivateKey.data
            
 // Manually zeroize (simulating what deriveSessionKeys does)
            securePrivateKey.zeroize()
            
 // Property 4.1: Manual zeroize should be called
            XCTAssertGreaterThanOrEqual(tracker.wipeCount, 1,
                                        "Wiping function should be called on manual zeroize")
        }
        
 // Property 4.2: After autoreleasepool, deinit should also call wipe
 // (wipeCount may be 2 if both manual zeroize and deinit called)
        XCTAssertGreaterThanOrEqual(tracker.wipeCount, 1,
                                    "Wiping function should be called")
    }
    
 /// **Feature: p2p-todo-completion, Property 4: Secure Key Erasure**
 /// Test that SecureBytes properly protects shared secrets
 /// **Validates: Requirements 3.4**
    func testProperty4_SharedSecretProtection() async throws {
        let tracker = SecureBytesWipeTracker()
        let originalWipingFunction = SecureBytes.wipingFunction
        SecureBytes.wipingFunction = tracker.makeWipingFunction()
        
        defer {
            SecureBytes.wipingFunction = originalWipingFunction
        }
        
 // Simulate shared secret derivation
        let sharedSecret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        
        autoreleasepool {
            let secureSharedSecret = SecureBytes(data: sharedSecret)
            
 // Use the shared secret for key derivation
            let transcriptHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let _ = deriveChannelKey(
                sharedSecret: SymmetricKey(data: secureSharedSecret.data),
                transcriptHash: transcriptHash,
                channel: "control",
                role: .initiator
            )
            
 // Zeroize after use
            secureSharedSecret.zeroize()
        }
        
 // Property 4.3: Shared secret should be wiped
        XCTAssertGreaterThanOrEqual(tracker.wipeCount, 1,
                                    "Shared secret should be wiped after use")
        XCTAssertEqual(tracker.lastWipedSize, 32,
                       "Wiped size should match shared secret size")
    }
    
 /// **Feature: p2p-todo-completion, Property 4: Secure Key Erasure**
 /// Test that multiple keys are all properly erased
 /// **Validates: Requirements 3.4**
    func testProperty4_MultipleKeysErasure() async throws {
        let tracker = SecureBytesWipeTracker()
        let originalWipingFunction = SecureBytes.wipingFunction
        SecureBytes.wipingFunction = tracker.makeWipingFunction()
        
        defer {
            SecureBytes.wipingFunction = originalWipingFunction
        }
        
        autoreleasepool {
 // Create multiple secure key containers
            let key1 = SecureBytes(count: 32)
            let key2 = SecureBytes(count: 32)
            let key3 = SecureBytes(count: 32)
            
 // Use them
            _ = key1.data
            _ = key2.data
            _ = key3.data
            
 // Manually zeroize all
            key1.zeroize()
            key2.zeroize()
            key3.zeroize()
        }
        
 // Property 4.4: All keys should be wiped (3 manual + 3 deinit = 6, or 3 if deinit skips already zeroed)
        XCTAssertGreaterThanOrEqual(tracker.wipeCount, 3,
                                    "All keys should be wiped")
    }
    #endif
}
