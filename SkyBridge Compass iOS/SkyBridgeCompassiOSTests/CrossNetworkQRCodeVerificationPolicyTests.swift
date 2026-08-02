import CryptoKit
import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class CrossNetworkQRCodeVerificationPolicyTests: XCTestCase {
    func testProtocolIdentityFingerprintMatchesCrossPlatformVectors() {
        let vectors: [(ProtocolSigningAlgorithm, Data, String)] = [
            (
                .ed25519,
                Data((0..<32).map(UInt8.init)),
                "09d14ebcd4f85644dbb1957e4b5bcf4501953e8ff2a96a6debcc1c9e5ef25de6"
            ),
            (
                .mlDSA65,
                Data(repeating: 0x65, count: 1_952),
                "1fdfd364181724c0cc67300bef7bdf2b555614b550785781d9fb3ef6de0e26d4"
            ),
            (
                .mlDSA87,
                Data(repeating: 0x87, count: 2_592),
                "49fa4ab724c2d05fb329373c72d899767f4cdb95f18dd497a36714aea3ee32c4"
            ),
        ]

        for (algorithm, publicKey, expected) in vectors {
            XCTAssertEqual(
                CurrentPathSecurityCompat.computeFingerprint(
                    algorithm: algorithm,
                    publicKeyBytes: publicKey
                ),
                expected
            )
        }
    }

    func testIdentityRotationTranscriptMatchesCrossPlatformV1Vector() {
        let bytes = DeviceIdentityRotationTranscriptCompat.canonicalEncoded(
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

        XCTAssertEqual(bytes.count, 417)
        XCTAssertEqual(
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "f33084af88048c4e9c73253469396b2ca4f6d4adf13a5c0be8a231321234435b"
        )
        XCTAssertEqual(
            bytes.base64EncodedString(),
            "AAAAIFNreUJyaWRnZS5EZXZpY2VJZGVudGl0eVJvdGF0aW9uAAEADQAAACQxMTExMTExMS0yMjIyLTQzMzMtODQ0NC01NTU1NTU1NTU1NTUAAAAgAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8AAAAIAAABl3Qg3HsAAAAkYWFhYWFhYWEtYWFhYS00YWFhLThhYWEtYWFhYWFhYWFhYWFhAAAAJGJiYmJiYmJiLWJiYmItNGJiYi04YmJiLWJiYmJiYmJiYmJiYgAAABtkZXZpY2Utcm90YXRpb24tdmVjdG9yLTAwMDEAAAAIAAAAAAAAAAcAAAAHRWQyNTUxOQAAACAREREREREREREREREREREREREREREREREREREREREREQAAACAiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIgAAAAdFZDI1NTE5AAAAIDMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzAAAAIERERERERERERERERERERERERERERERERERERERERERE"
        )
    }

    func testIdentityRotationRequestJournalBindsAuthAndIdempotencyScope() throws {
        let oldKey = Data(repeating: 0x21, count: 32)
        let newKey = Data(repeating: 0x43, count: 32)
        let request = IOSPendingDeviceIdentityRotationRequest(
            version: IOSPendingDeviceIdentityRotationRequest.currentVersion,
            requestID: "11111111-2222-4333-8444-555555555555",
            expectedTenantID: "tenant-rotation-test",
            expectedUserID: "user-rotation-test",
            deviceID: "device-rotation-test-0001",
            oldAlgorithm: .ed25519,
            oldProtection: .softwareKeychain,
            oldFingerprint: CurrentPathSecurityCompat.computeFingerprint(
                algorithm: .ed25519,
                publicKeyBytes: oldKey
            ),
            oldPublicKey: oldKey,
            newAlgorithm: .ed25519,
            newProtection: .softwareKeychain,
            newFingerprint: CurrentPathSecurityCompat.computeFingerprint(
                algorithm: .ed25519,
                publicKeyBytes: newKey
            ),
            newPublicKey: newKey
        )
        let decoded = try JSONDecoder().decode(
            IOSPendingDeviceIdentityRotationRequest.self,
            from: JSONEncoder().encode(request)
        )
        let bindings = try decoded.bindings()

        XCTAssertEqual(decoded.requestID, request.requestID)
        XCTAssertEqual(decoded.expectedTenantID, request.expectedTenantID)
        XCTAssertEqual(decoded.expectedUserID, request.expectedUserID)
        XCTAssertEqual(bindings.old.protocolPublicKeyBytes, oldKey)
        XCTAssertEqual(bindings.new.protocolPublicKeyBytes, newKey)
    }

    func testIdentityRotationExpiryClassificationIsExact() {
        XCTAssertTrue(SignalServerClientCompat.isUncommittedIdentityRotationExpired(
            SignalServerClientCompat.ClientError.serverRejected(
                410,
                #"{"bodyBytes":32,"error":"rotation_expired"}"#
            )
        ))
        XCTAssertFalse(SignalServerClientCompat.isUncommittedIdentityRotationExpired(
            SignalServerClientCompat.ClientError.serverRejected(
                503,
                #"{"bodyBytes":32,"error":"rotation_expired"}"#
            )
        ))
        XCTAssertFalse(SignalServerClientCompat.isUncommittedIdentityRotationExpired(
            SignalServerClientCompat.ClientError.serverRejected(
                410,
                #"{"bodyBytes":32,"error":"rotation_state_conflict"}"#
            )
        ))
    }

    func testIdentityRotationPersistsBeforeNetworkAndCommitsRemoteBeforeLocal() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CurrentPathDeviceIdentityRotationCoordinator.swift"
            )
        )
        let settings = try readRepositorySourceForSourceShapeTests(
            at: root.appendingPathComponent(
                "SkyBridgeCompassiOS/Sources/Views/SettingsView.swift"
            )
        )
        let start = try XCTUnwrap(coordinator.range(of: "private func completePendingRequest("))
        let end = try XCTUnwrap(coordinator.range(
            of: "private func commitIdentityRotationPreservingOnlyRecoverableState(",
            range: start.upperBound..<coordinator.endIndex
        ))
        let body = String(coordinator[start.lowerBound..<end.lowerBound])
        let journalSave = try XCTUnwrap(body.range(of: "journalStore.save(pending)"))
        let remoteCommit = try XCTUnwrap(body.range(
            of: "commitIdentityRotationPreservingOnlyRecoverableState("
        ))
        let localCommit = try XCTUnwrap(body.range(
            of: "commitPreparedProtocolSigningIdentity(prepared)"
        ))

        XCTAssertLessThan(journalSave.lowerBound, remoteCommit.lowerBound)
        XCTAssertLessThan(remoteCommit.lowerBound, localCommit.lowerBound)
        XCTAssertTrue(coordinator.contains("requestJournalStore.save(request)"))
        XCTAssertTrue(coordinator.contains("idempotencyKey: request.requestID"))
        XCTAssertTrue(coordinator.contains("authenticatedIdentityRotationScope()"))
        XCTAssertTrue(settings.contains(
            "IOSCurrentPathDeviceIdentityRotationCoordinator.shared.rotate("
        ))
        XCTAssertFalse(settings.contains(
            "SkyBridgeiOSCore.shared.configureProtocolSigningIdentity("
        ))
        XCTAssertTrue(settings.contains(
            "跨网络会话要求对端精确绑定原始 87 公钥"
        ))
        XCTAssertTrue(settings.contains(
            "if protocolIdentityRuntimeIsActive"
        ))
        XCTAssertTrue(settings.contains(
            "已配置 ML-DSA-87 主身份；运行时恢复密钥并完成签名自检后才会激活"
        ))
        XCTAssertTrue(settings.contains("独立的 65 兼容身份"))
        XCTAssertFalse(settings.contains("protocolIdentityNeedsPeerRepin"))
    }

    func testAcceptsSignedV7QRCodeWithValidKEMKey() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let qr = try signedQRCode(now: now)

        let result = try await CrossNetworkQRCodeVerificationPolicy.verify(qr, now: now)

        XCTAssertTrue(result.ok)
        XCTAssertNil(result.reason)
    }

    func testRejectsV7QRCodeWithoutKEMKeyBeforeSignatureWork() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let qr = try signedQRCode(now: now, kemPublicKeys: [])

        let result = try await CrossNetworkQRCodeVerificationPolicy.verify(qr, now: now)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "二维码缺少 PQC KEM 公钥")
    }

    func testRejectsLegacyQRCodeThatCarriesKEMKey() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let qr = try signedQRCode(version: 6, now: now)

        let result = try await CrossNetworkQRCodeVerificationPolicy.verify(qr, now: now)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "二维码 KEM 公钥需要 v7 协议")
    }

    func testRejectsProtocolFingerprintMismatch() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let qr = try signedQRCode(
            now: now,
            protocolPublicKeyFingerprintOverride: String(repeating: "0", count: 64)
        )

        let result = try await CrossNetworkQRCodeVerificationPolicy.verify(qr, now: now)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "二维码长期协议公钥指纹不匹配")
    }

    func testRejectsExpiredQRCodeOutsideClockSkew() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let qr = try signedQRCode(
            now: now,
            expiresAt: now.addingTimeInterval(-121)
        )

        let result = try await CrossNetworkQRCodeVerificationPolicy.verify(qr, now: now)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "二维码已过期")
    }

    private func signedQRCode(
        version: Int = 7,
        now: Date,
        expiresAt: Date? = nil,
        kemPublicKeys: [KEMPublicKeyInfo]? = nil,
        protocolPublicKeyFingerprintOverride: String? = nil
    ) throws -> DynamicQRCodeData {
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation
        let fingerprint = CurrentPathSecurityCompat.computeFingerprint(
            algorithm: .ed25519,
            publicKeyBytes: publicKey
        )
        let timestampMs = Int64(now.timeIntervalSince1970 * 1000)
        let unsigned = DynamicQRCodeData(
            version: version,
            sessionID: "session-qr-policy-0001",
            qrBootstrapToken: "bootstrap-token-qr-policy",
            signalingServerOrigin: "https://signal.example.com",
            deviceID: "id:qr-policy-device-0001",
            deviceName: "Policy Mac",
            deviceType: "mac",
            osVersion: "macOS 26.5",
            capabilities: ["cross-network"],
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: publicKey,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprintOverride ?? fingerprint,
            kemPublicKeys: kemPublicKeys ?? [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: Data(repeating: 0x42, count: 1_216)
                )
            ],
            signature: nil,
            signatureTimestampMs: timestampMs,
            expiresAt: expiresAt ?? now.addingTimeInterval(300)
        )
        let signature = try signingKey.signature(for: unsigned.canonicalSignaturePayload)
        return DynamicQRCodeData(
            version: unsigned.version,
            sessionID: unsigned.sessionID,
            qrBootstrapToken: unsigned.qrBootstrapToken,
            signalingServerOrigin: unsigned.signalingServerOrigin,
            deviceID: unsigned.deviceID,
            deviceName: unsigned.deviceName,
            deviceType: unsigned.deviceType,
            osVersion: unsigned.osVersion,
            capabilities: unsigned.capabilities,
            protocolSigningAlgorithm: unsigned.protocolSigningAlgorithm,
            protocolPublicKeyBytes: unsigned.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: unsigned.protocolPublicKeyFingerprint,
            kemPublicKeys: unsigned.kemPublicKeys,
            signature: signature,
            signatureTimestampMs: unsigned.signatureTimestampMs,
            expiresAt: unsigned.expiresAt
        )
    }
}
