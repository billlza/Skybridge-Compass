import CryptoKit
import Foundation
import Testing
@testable import SkyBridgeProtocolCore

@Suite("Device identity rotation transcript")
struct DeviceIdentityRotationTranscriptTests {
    @Test("Canonical transcript matches the cross-language v1 vector")
    func canonicalVector() {
        let bytes = DeviceIdentityRotationTranscript.canonicalEncoded(
            rotationID: "11111111-2222-4333-8444-555555555555",
            nonce: Data(0..<32),
            expiresAtMilliseconds: 1_750_000_000_123,
            tenantID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            userID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            deviceID: "device-rotation-vector-0001",
            oldGeneration: 7,
            oldAlgorithm: "Ed25519",
            oldFingerprintBytes: Data(repeating: 0x11, count: 32),
            oldPublicKey: Data(repeating: 0x22, count: 32),
            newAlgorithm: "Ed25519",
            newFingerprintBytes: Data(repeating: 0x33, count: 32),
            newPublicKey: Data(repeating: 0x44, count: 32)
        )

        #expect(bytes.count == 417)
        #expect(
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                == "f33084af88048c4e9c73253469396b2ca4f6d4adf13a5c0be8a231321234435b"
        )
        #expect(
            bytes.base64EncodedString()
                == "AAAAIFNreUJyaWRnZS5EZXZpY2VJZGVudGl0eVJvdGF0aW9uAAEADQAAACQxMTExMTExMS0yMjIyLTQzMzMtODQ0NC01NTU1NTU1NTU1NTUAAAAgAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8AAAAIAAABl3Qg3HsAAAAkYWFhYWFhYWEtYWFhYS00YWFhLThhYWEtYWFhYWFhYWFhYWFhAAAAJGJiYmJiYmJiLWJiYmItNGJiYi04YmJiLWJiYmJiYmJiYmJiYgAAABtkZXZpY2Utcm90YXRpb24tdmVjdG9yLTAwMDEAAAAIAAAAAAAAAAcAAAAHRWQyNTUxOQAAACAREREREREREREREREREREREREREREREREREREREREREQAAACAiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIgAAAAdFZDI1NTE5AAAAIDMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzAAAAIERERERERERERERERERERERERERERERERERERERERERE"
        )
    }

    @Test("Server commitment must match the exact requested identities")
    func validatesExactServerCommitment() throws {
        let deviceID = "device-rotation-test-0001"
        let oldIdentity = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x21, count: 32)
        )
        let newIdentity = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x43, count: 32)
        )
        let transcript = try DeviceIdentityRotationTranscript(
            rotationID: "11111111-2222-4333-8444-555555555555",
            nonce: Data(0..<32),
            expiresAtMilliseconds: 1_750_000_000_123,
            tenantID: "tenant-rotation-test",
            userID: "user-rotation-test",
            deviceID: deviceID,
            oldGeneration: 9,
            oldIdentity: oldIdentity,
            newIdentity: newIdentity
        )

        try transcript.validateServerCommitment(
            transcriptBase64: transcript.encoded.base64EncodedString(),
            transcriptHash: transcript.sha256Hex
        )
        #expect(throws: CurrentPathSecurityError.self) {
            try transcript.validateServerCommitment(
                transcriptBase64: Data("substituted".utf8).base64EncodedString(),
                transcriptHash: transcript.sha256Hex
            )
        }
    }

    @Test("Rotation rejects a fingerprint substituted for the candidate key")
    func rejectsMismatchedFingerprint() throws {
        let deviceID = "device-rotation-test-0002"
        let oldIdentity = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x12, count: 32)
        )
        let mismatchedNewIdentity = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x34, count: 32),
            protocolPublicKeyFingerprint: String(repeating: "a", count: 64)
        )

        #expect(throws: CurrentPathSecurityError.self) {
            _ = try DeviceIdentityRotationTranscript(
                rotationID: "11111111-2222-4333-8444-555555555555",
                nonce: Data(0..<32),
                expiresAtMilliseconds: 1_750_000_000_123,
                tenantID: "tenant-rotation-test",
                userID: "user-rotation-test",
                deviceID: deviceID,
                oldGeneration: 1,
                oldIdentity: oldIdentity,
                newIdentity: mismatchedNewIdentity
            )
        }
    }

    @Test("Rotation nonce uses canonical unpadded Base64URL")
    func canonicalNonce() throws {
        let encoded = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let decoded = try DeviceIdentityRotationTranscript
            .decodeCanonicalBase64URLNonce(encoded)
        #expect(decoded == Data(0..<32))
        #expect(DeviceIdentityRotationTranscript.canonicalBase64URL(decoded) == encoded)
        #expect(throws: CurrentPathSecurityError.self) {
            _ = try DeviceIdentityRotationTranscript
                .decodeCanonicalBase64URLNonce(encoded + "=")
        }
    }
}
