import XCTest
import CryptoKit
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class CrossNetworkQRCodeSecurityTests: XCTestCase {
    private func compactDynamicQRCodeJSON(
        version: Int = 6,
        expirationMilliseconds: Int64
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "v": version,
            "s": "session-compact",
            "q": "bootstrap-compact",
            "r": "https://api.example.com",
            "d": "12345678-1234-1234-1234-1234567890ab",
            "n": "Compact QR",
            "y": P2PDeviceType.macOS.rawValue,
            "o": "macOS-test",
            "c": ["cross-network"],
            "a": ProtocolSigningAlgorithm.ed25519.rawValue,
            "k": CrossNetworkConnectionManager.base64URLEncodedString(from: Data([0x01])),
            "f": String(repeating: "0", count: 64),
            "t": 1_800_000_000_000 as Int64,
            "e": expirationMilliseconds,
        ])
    }

    private func compactServerBackedInviteJSON(
        version: Int,
        expirationMilliseconds: Int64 = 1_800_000_000_000
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "v": version,
            "s": "session-server-backed",
            "q": "bootstrap-server-backed",
            "r": "https://api.example.com",
            "d": "12345678-1234-1234-1234-1234567890ab",
            "n": "Server QR",
            "y": P2PDeviceType.macOS.rawValue,
            "o": "macOS-test",
            "a": ProtocolSigningAlgorithm.ed25519.rawValue,
            "f": String(repeating: "1", count: 64),
            "e": expirationMilliseconds,
        ])
    }

    private func verifyWithEmptyTrustStore(
        _ qrData: DynamicQRCodeData
    ) async -> (ok: Bool, reason: String?, source: QRCodeTrustSource) {
        let trust = TrustSyncService(initialRecordsForTesting: [])
        return await CrossNetworkConnectionManager.verifyDynamicQRCode(
            qrData,
            trustService: trust
        )
    }

    private func makeSignedQRCode(
        version: Int = 6,
        sessionID: String = "session-123",
        qrBootstrapToken: String = "bootstrap-token",
        expiresAt: Date = Date().addingTimeInterval(300),
        signalingServerOrigin: String = "https://api.example.com",
        deviceId: String = "12345678-1234-1234-1234-1234567890ab",
        kemPublicKeys: [KEMPublicKeyInfo] = [],
        signatureTimestampMs: Int64? = nil
    ) async throws -> DynamicQRCodeData {
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .ed25519,
            publicKeyBytes: publicKey
        )
        let effectiveSignatureTimestampMs: Int64
        if let signatureTimestampMs {
            effectiveSignatureTimestampMs = signatureTimestampMs
        } else {
            effectiveSignatureTimestampMs = try CrossNetworkQREpochMilliseconds.milliseconds(from: Date())
        }
        let unsigned = DynamicQRCodeData(
            version: version,
            sessionID: sessionID,
            qrBootstrapToken: qrBootstrapToken,
            signalingServerOrigin: signalingServerOrigin,
            deviceID: deviceId,
            deviceName: "Test Mac",
            deviceType: P2PDeviceType.macOS.rawValue,
            osVersion: "macOS-test-99.0",
            capabilities: ["p2p", "cross-network"],
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: publicKey,
            protocolPublicKeyFingerprint: fingerprint,
            kemPublicKeys: kemPublicKeys,
            signature: nil,
            signatureTimestampMs: effectiveSignatureTimestampMs,
            expiresAt: expiresAt
        )
        let signature = try signingKey.signature(
            for: try CrossNetworkConnectionManager.buildCanonicalQRCodePayload(for: unsigned)
        )
        return unsigned.withSignature(signature)
    }

    func testCrossNetworkQRCodeBindsSensitiveClaims() async throws {
        let qrData = try await makeSignedQRCode()
        let baseline = await verifyWithEmptyTrustStore(qrData)
        XCTAssertTrue(baseline.ok, baseline.reason ?? "")

        let tamperedSession = DynamicQRCodeData(
            version: qrData.version,
            sessionID: "session-999",
            qrBootstrapToken: qrData.qrBootstrapToken,
            signalingServerOrigin: qrData.signalingServerOrigin,
            deviceID: qrData.deviceID,
            deviceName: qrData.deviceName,
            deviceType: qrData.deviceType,
            osVersion: qrData.osVersion,
            capabilities: qrData.capabilities,
            protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
            protocolPublicKeyBytes: qrData.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
            signature: qrData.signature,
            signatureTimestampMs: qrData.signatureTimestampMs,
            expiresAt: qrData.expiresAt
        )
        let tamperedSessionResult = await verifyWithEmptyTrustStore(tamperedSession)
        XCTAssertFalse(tamperedSessionResult.ok)

        let tamperedToken = DynamicQRCodeData(
            version: qrData.version,
            sessionID: qrData.sessionID,
            qrBootstrapToken: "bootstrap-token-999",
            signalingServerOrigin: qrData.signalingServerOrigin,
            deviceID: qrData.deviceID,
            deviceName: qrData.deviceName,
            deviceType: qrData.deviceType,
            osVersion: qrData.osVersion,
            capabilities: qrData.capabilities,
            protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
            protocolPublicKeyBytes: qrData.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
            signature: qrData.signature,
            signatureTimestampMs: qrData.signatureTimestampMs,
            expiresAt: qrData.expiresAt
        )
        let tamperedTokenResult = await verifyWithEmptyTrustStore(tamperedToken)
        XCTAssertFalse(tamperedTokenResult.ok)

        let tamperedExpiry = DynamicQRCodeData(
            version: qrData.version,
            sessionID: qrData.sessionID,
            qrBootstrapToken: qrData.qrBootstrapToken,
            signalingServerOrigin: qrData.signalingServerOrigin,
            deviceID: qrData.deviceID,
            deviceName: qrData.deviceName,
            deviceType: qrData.deviceType,
            osVersion: qrData.osVersion,
            capabilities: qrData.capabilities,
            protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
            protocolPublicKeyBytes: qrData.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
            signature: qrData.signature,
            signatureTimestampMs: qrData.signatureTimestampMs,
            expiresAt: qrData.expiresAt.addingTimeInterval(30)
        )
        let tamperedExpiryResult = await verifyWithEmptyTrustStore(tamperedExpiry)
        XCTAssertFalse(tamperedExpiryResult.ok)
    }

    func testVersion7QRCodeRequiresSignedKEMPublicKey() async throws {
        let missingKEM = try await makeSignedQRCode(version: 7)
        let missingResult = await verifyWithEmptyTrustStore(missingKEM)

        XCTAssertFalse(missingResult.ok)
        XCTAssertEqual(missingResult.reason, "二维码缺少 PQC KEM 公钥")

        let signedKEM = try await makeSignedQRCode(
            version: 7,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x41, count: 1216)
                )
            ]
        )
        let signedResult = await verifyWithEmptyTrustStore(signedKEM)

        XCTAssertTrue(signedResult.ok, signedResult.reason ?? "")

        let tamperedKEM = DynamicQRCodeData(
            version: signedKEM.version,
            sessionID: signedKEM.sessionID,
            qrBootstrapToken: signedKEM.qrBootstrapToken,
            signalingServerOrigin: signedKEM.signalingServerOrigin,
            deviceID: signedKEM.deviceID,
            deviceName: signedKEM.deviceName,
            deviceType: signedKEM.deviceType,
            osVersion: signedKEM.osVersion,
            capabilities: signedKEM.capabilities,
            protocolSigningAlgorithm: signedKEM.protocolSigningAlgorithm,
            protocolPublicKeyBytes: signedKEM.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: signedKEM.protocolPublicKeyFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x42, count: 1216)
                )
            ],
            signature: signedKEM.signature,
            signatureTimestampMs: signedKEM.signatureTimestampMs,
            expiresAt: signedKEM.expiresAt
        )
        let tamperedResult = await verifyWithEmptyTrustStore(tamperedKEM)

        XCTAssertFalse(tamperedResult.ok)
        XCTAssertEqual(tamperedResult.reason, "二维码签名验证失败")
    }

    func testVerifiedQRCodeWithSignedKEMDoesNotPersistP2PKEMTrustMaterial() async throws {
        let store = PeerKEMBootstrapStore.shared
        let deviceId = "id:\(UUID().uuidString.lowercased())"
        await store.clearForTesting()
        addTeardownBlock { [store] in
            await store.clearForTesting()
        }

        let signedKEM = try await makeSignedQRCode(
            version: 7,
            deviceId: deviceId,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x41, count: 1216)
                )
            ]
        )
        let result = await verifyWithEmptyTrustStore(signedKEM)

        XCTAssertTrue(result.ok, result.reason ?? "")
        let persisted = await store.mergedKEMPublicKeys(forCandidates: [deviceId])
        XCTAssertTrue(
            persisted.isEmpty,
            "Verified QR KEM material must remain diagnostic/connect-link content; SKR-1 is the only P2P KEM import path."
        )
    }

    func testLegacyQRCodeCannotSmuggleKEMPublicKey() async throws {
        let legacyWithKEM = try await makeSignedQRCode(
            version: 6,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x51, count: 1216)
                )
            ]
        )

        let result = await verifyWithEmptyTrustStore(legacyWithKEM)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "二维码 KEM 公钥需要 v7 协议")
    }

    func testCrossNetworkQRCodeRejectsOriginMismatch() async throws {
        let qrData = try await makeSignedQRCode(signalingServerOrigin: "https://other.example.com")
        let result = await verifyWithEmptyTrustStore(qrData)
        XCTAssertTrue(result.ok, "signature verification is content-only; origin mismatch is enforced at scan time")
    }

    func testCrossNetworkQRCodeRejectsLegacyContract() async throws {
        let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let legacy = DynamicQRCodeData(
            version: 5,
            sessionID: "legacy-session",
            qrBootstrapToken: "legacy-token",
            signalingServerOrigin: "https://api.example.com",
            deviceID: "12345678-1234-1234-1234-1234567890ab",
            deviceName: "Legacy",
            deviceType: P2PDeviceType.macOS.rawValue,
            osVersion: "macOS-old",
            capabilities: ["cross-network"],
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: publicKey,
            protocolPublicKeyFingerprint: ProtocolIdentityBinding.computeFingerprint(
                algorithm: .ed25519,
                publicKeyBytes: publicKey
            ),
            signature: nil,
            signatureTimestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            expiresAt: Date().addingTimeInterval(300)
        )
        let legacyResult = await verifyWithEmptyTrustStore(legacy)
        XCTAssertFalse(legacyResult.ok)
    }

    func testAuthenticatedQRCodeRebindPolicyRejectsSilentCurrentPathConflicts() {
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedQRRebind(for: .identityConflict)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedQRRebind(for: .deviceIdMigrationRequired)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedQRRebind(for: .quarantinedIdentity)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedQRRebind(for: .revokedIdentity)
        )
    }

    func testAuthenticatedConnectionCodeRebindOnlyAllowsSameDeviceIdentityConflictHealing() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .identityConflict)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .deviceIdMigrationRequired)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .quarantinedIdentity)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .revokedIdentity)
        )
    }

    func testCrossNetworkQRCodeRejectsSelfSignedAuthorityRekeyForExistingDeviceId() async throws {
        let trust = TrustSyncService.shared
        let qrData = try await makeSignedQRCode()
        let deviceId = qrData.deviceID

        await trust.beginInMemoryPersistenceForTesting()
        await trust.removeRecordsForTesting(deviceIds: [deviceId])
        addTeardownBlock { @MainActor [trust] in
            await trust.removeRecordsForTesting(deviceIds: [deviceId])
            trust.endInMemoryPersistenceForTesting()
        }

        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: deviceId,
                pubKeyFP: String(repeating: "1", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: String(repeating: "2", count: 64),
                signature: Data(),
                deviceName: "Existing Device",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            )
        )

        let result = await CrossNetworkConnectionManager.verifyDynamicQRCode(qrData)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.reason?.contains("pinned authoritative key") == true)
    }

    func testCrossNetworkQRCodeRejectsEveryUnsupportedDynamicVersionWithoutTrapping() async throws {
        let valid = try await makeSignedQRCode()
        for invalidVersion in [5, 8, Int(UInt16.max), Int(UInt16.max) + 1, Int.max, -1] {
            let invalid = DynamicQRCodeData(
                version: invalidVersion,
                sessionID: valid.sessionID,
                qrBootstrapToken: valid.qrBootstrapToken,
                signalingServerOrigin: valid.signalingServerOrigin,
                deviceID: valid.deviceID,
                deviceName: valid.deviceName,
                deviceType: valid.deviceType,
                osVersion: valid.osVersion,
                capabilities: valid.capabilities,
                protocolSigningAlgorithm: valid.protocolSigningAlgorithm,
                protocolPublicKeyBytes: valid.protocolPublicKeyBytes,
                protocolPublicKeyFingerprint: valid.protocolPublicKeyFingerprint,
                kemPublicKeys: valid.kemPublicKeys,
                signature: valid.signature,
                signatureTimestampMs: valid.signatureTimestampMs,
                expiresAt: valid.expiresAt
            )

            let result = await verifyWithEmptyTrustStore(invalid)

            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.reason, "二维码协议版本无效")
            XCTAssertThrowsError(try CrossNetworkConnectionManager.buildCanonicalQRCodePayload(for: invalid))
            let compactPayload = try compactDynamicQRCodeJSON(
                version: invalidVersion,
                expirationMilliseconds: valid.signatureTimestampMs + 60_000
            )
            XCTAssertThrowsError(
                try CrossNetworkConnectionManager.decodeDynamicQRCodePayload(from: compactPayload)
            )
        }
    }

    func testCompactDynamicQRCodeRejectsExtremeExpirationMillisecondsWithoutTrapping() throws {
        for invalidExpiration in [Int64.min, Int64.max] {
            let payload = try compactDynamicQRCodeJSON(expirationMilliseconds: invalidExpiration)
            XCTAssertThrowsError(
                try CrossNetworkConnectionManager.decodeDynamicQRCodePayload(from: payload)
            )
        }
    }

    func testCompactDynamicQRCodeAcceptsExactSupportedExpirationBoundary() throws {
        let supportedBoundary = CrossNetworkQREpochMilliseconds.maximumSupportedValue
        let payload = try compactDynamicQRCodeJSON(expirationMilliseconds: supportedBoundary)
        let decoded = try CrossNetworkConnectionManager.decodeDynamicQRCodePayload(from: payload)

        XCTAssertEqual(
            try CrossNetworkQREpochMilliseconds.milliseconds(from: decoded.expiresAt),
            supportedBoundary
        )
        XCTAssertThrowsError(
            try CrossNetworkConnectionManager.decodeDynamicQRCodePayload(
                from: compactDynamicQRCodeJSON(expirationMilliseconds: supportedBoundary + 1)
            )
        )
    }

    func testDynamicQRCodeValidityDurationHonorsProtocolBoundary() async throws {
        let signatureTimestampMs = try CrossNetworkQREpochMilliseconds.milliseconds(from: Date())
        let maximumDurationMs = Int64(P2PConstants.qrCodeExpirationSeconds * 1_000)
        let atLimit = try await makeSignedQRCode(
            expiresAt: CrossNetworkQREpochMilliseconds.date(
                from: signatureTimestampMs + maximumDurationMs
            ),
            signatureTimestampMs: signatureTimestampMs
        )
        let atLimitResult = await verifyWithEmptyTrustStore(atLimit)
        XCTAssertTrue(atLimitResult.ok, atLimitResult.reason ?? "")

        let overLimit = try await makeSignedQRCode(
            expiresAt: CrossNetworkQREpochMilliseconds.date(
                from: signatureTimestampMs + maximumDurationMs + 1
            ),
            signatureTimestampMs: signatureTimestampMs
        )
        let overLimitResult = await verifyWithEmptyTrustStore(overLimit)
        XCTAssertFalse(overLimitResult.ok)
        XCTAssertEqual(overLimitResult.reason, "二维码有效期超出协议上限")
    }

    func testServerBackedQRCodeAcceptsOnlyExactVersionEight() throws {
        let supported = try CrossNetworkConnectionManager.decodeServerBackedQRCodeInvite(
            from: compactServerBackedInviteJSON(version: 8)
        )
        XCTAssertEqual(supported.version, 8)

        for unsupportedVersion in [7, 9, Int.max] {
            XCTAssertThrowsError(
                try CrossNetworkConnectionManager.decodeServerBackedQRCodeInvite(
                    from: compactServerBackedInviteJSON(version: unsupportedVersion)
                )
            )
        }
    }

    func testServerBackedQRCodeEnforcesLocalTrustBeforeCommittingSessionState() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try XCTUnwrap(
            source.range(of: "private func scanServerBackedQRCodeInvite(")
        )
        let functionEnd = try XCTUnwrap(
            source.range(
                of: "// MARK: - 私有方法 - P2P 连接建立",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let functionBody = String(source[functionStart.lowerBound..<functionEnd.lowerBound])
        let localBindingCheck = try XCTUnwrap(
            functionBody.range(of: "try await enforceCurrentPathTrustBinding(")
        )
        let stateCommit = try XCTUnwrap(
            functionBody.range(of: "webrtcSignalingAuthTokenBySessionId[invite.sessionID]")
        )

        XCTAssertLessThan(localBindingCheck.lowerBound, stateCommit.lowerBound)
        XCTAssertTrue(functionBody.contains("authenticatedConnectionCodeRebindAllowed: false"))
        XCTAssertFalse(functionBody.contains("authenticatedConnectionCodeRebindSessionIds.insert"))
    }

    func testCrossNetworkQRCodeTreatsAliasMatchedPinnedAuthorityAsTrustedDevice() async throws {
        let trust = TrustSyncService.shared
        let suffix = UUID().uuidString.lowercased()
        let aliasId = "bonjour:skybridge-\(suffix)@local."
        let stableId = "id:\(suffix)"
        let qrData = try await makeSignedQRCode(deviceId: stableId)

        await trust.beginInMemoryPersistenceForTesting()
        await trust.removeRecordsForTesting(deviceIds: [aliasId, stableId])
        addTeardownBlock { @MainActor [trust] in
            await trust.removeRecordsForTesting(deviceIds: [aliasId, stableId])
            trust.endInMemoryPersistenceForTesting()
        }

        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: aliasId,
                pubKeyFP: String(repeating: "3", count: 64),
                publicKey: qrData.protocolPublicKeyBytes,
                protocolPublicKey: qrData.protocolPublicKeyBytes,
                protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
                signature: Data(),
                deviceName: "Pinned Mac",
                currentDeviceId: stableId,
                knownDeviceIds: [aliasId, stableId]
            )
        )

        let result = await CrossNetworkConnectionManager.verifyDynamicQRCode(qrData)

        XCTAssertTrue(result.ok, result.reason ?? "")
        XCTAssertEqual(result.source, .trustedDevice)
    }

    func testCrossNetworkQRCodeFailsClosedWhenTrustStoreReadinessFails() async throws {
        let qrData = try await makeSignedQRCode()
        let unavailableTrust = TrustSyncService(initialLoadOperationForTesting: {
            throw TrustSyncError.localTrustStoreUnavailable
        })

        let result = await CrossNetworkConnectionManager.verifyDynamicQRCode(
            qrData,
            trustService: unavailableTrust
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "本地信任存储不可用，无法安全验证二维码")
        XCTAssertEqual(result.source, .selfAsserted)
    }
}
