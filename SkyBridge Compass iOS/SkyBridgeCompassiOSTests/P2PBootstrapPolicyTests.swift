import XCTest
import CryptoKit
import Network
import enum SkyBridgeProtocolCore.BonjourInteropProtocolContract
import enum SkyBridgeProtocolCore.P2PProtocolIdentityBindingAdmissionPolicy
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class AppMessageStrictDecodingTests: XCTestCase {
    private let message = AppMessage.textMessage(
        .init(
            id: UUID(),
            text: "hello",
            sentAt: Date(timeIntervalSinceReferenceDate: 42)
        )
    )

    func testCanonicalAndExactLegacyRepresentationsDecode() throws {
        let canonicalData = try JSONEncoder().encode(message)
        XCTAssertEqual(try AppMessage.decodeWireMessage(from: canonicalData), message)

        let canonicalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )
        let payload = try XCTUnwrap(canonicalObject["textMessage"])
        let legacyData = try JSONSerialization.data(
            withJSONObject: ["textMessage": ["_0": payload]]
        )

        XCTAssertEqual(try AppMessage.decodeWireMessage(from: legacyData), message)
    }

    func testRejectsMissingUnknownAndMultipleDiscriminators() throws {
        let canonicalData = try JSONEncoder().encode(message)
        var canonicalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )
        let payload = try XCTUnwrap(canonicalObject["textMessage"])

        for object: Any in [
            [:] as [String: Any],
            ["futureMessage": [:]] as [String: Any],
            ["textMessage": payload, "ping": ["id": 7]],
        ] {
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: data))
        }

        canonicalObject["futureMessage"] = [:]
        let data = try JSONSerialization.data(withJSONObject: canonicalObject)
        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: data))
    }

    func testSelectedMalformedPayloadCannotFallThroughToAnotherMessageKind() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "textMessage": ["id": "not-a-uuid", "text": "hello", "sentAt": 42],
                "ping": ["id": 7],
            ]
        )

        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: data))
    }

    func testRejectsPayloadThatMixesCurrentAndLegacyRepresentations() throws {
        let canonicalData = try JSONEncoder().encode(message)
        let canonicalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )
        let payload = try XCTUnwrap(canonicalObject["textMessage"] as? [String: Any])
        var mixedPayload = payload
        mixedPayload["_0"] = payload
        let data = try JSONSerialization.data(
            withJSONObject: ["textMessage": mixedPayload]
        )

        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: data))
    }

    func testWireDecoderRejectsDuplicateDiscriminatorAndNestedPayloadKeys() throws {
        let canonicalData = try JSONEncoder().encode(message)
        let canonicalJSON = try XCTUnwrap(String(data: canonicalData, encoding: .utf8))
        XCTAssertTrue(canonicalJSON.hasPrefix("{"))
        XCTAssertTrue(canonicalJSON.hasSuffix("}"))
        let entry = canonicalJSON.dropFirst().dropLast()
        let duplicateDiscriminator = Data("{\(entry),\(entry)}".utf8)

        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: duplicateDiscriminator))

        let messageID = UUID().uuidString
        let duplicateNestedKey = Data(
            #"{"textMessage":{"id":"\#(messageID)","text":"hello","text":"tampered","sentAt":42}}"#.utf8
        )
        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: duplicateNestedKey))
    }

    func testWireDecoderTreatsEscapedAndLiteralDiscriminatorsAsDuplicate() throws {
        let messageID = UUID().uuidString
        let data = Data(
            #"{"textMessage":{"id":"\#(messageID)","text":"one","sentAt":42},"text\u004dessage":{"id":"\#(messageID)","text":"two","sentAt":42}}"#.utf8
        )

        XCTAssertThrowsError(try AppMessage.decodeWireMessage(from: data))
    }
}

final class BonjourServiceIdentitySanitizerTests: XCTestCase {
    func testRejectsSyntheticBonjourIdentityNames() {
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("id:e0715a9a-d0d3-47e6-b353-de0a30293e1f"))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("bonjour:id:e0715a9a-d0d3-47e6-b353-de0a30293e1f@local."))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("host:fe80::1%en0"))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("E0715A9A-D0D3-47E6-B353-DE0A30293E1F"))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("fe80::ce0:3cf9:13d0:85b3%en0"))
    }

    func testAcceptsAndNormalizesRealBonjourInstanceNames() {
        XCTAssertEqual(
            BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("Lza的MacBook Pro._skybridge._tcp"),
            "Lza的MacBook Pro"
        )
        XCTAssertEqual(
            BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("bonjour:Lza的MacBook Pro@local."),
            "Lza的MacBook Pro"
        )
    }
}

@available(iOS 17.0, *)
@MainActor
final class AuthenticatedPairingIdentityAuthorityTests: XCTestCase {
    private struct Fixture {
        let deviceId: String
        let publicKey: Data
        let fingerprint: String
        let payload: AppMessage.PairingIdentityExchangePayload
        let authority: AuthenticatedRemoteAuthority
    }

    private func fixture(
        deviceId: String = "id:11111111-2222-4333-8444-555555555555"
    ) throws -> Fixture {
        let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let keyInfo = AppMessage.ProtocolIdentityPublicKeyInfo(
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            publicKey: publicKey
        )
        let fingerprint = try XCTUnwrap(keyInfo.authoritativeFingerprint)
        return Fixture(
            deviceId: deviceId,
            publicKey: publicKey,
            fingerprint: fingerprint,
            payload: AppMessage.PairingIdentityExchangePayload(
                deviceId: deviceId,
                kemPublicKeys: [
                    KEMPublicKeyInfo(
                        suiteWireId: CryptoSuite.xwing.wireId,
                        publicKey: Data(repeating: 0x51, count: 1_216)
                    )
                ],
                protocolIdentityPublicKeys: [keyInfo]
            ),
            authority: AuthenticatedRemoteAuthority(
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                protocolPublicKeyFingerprint: fingerprint,
                protocolPublicKeyBytes: publicKey
            )
        )
    }

    func testSOABindingAuthorizesOnlyAliasesWithTheSameCanonicalSOAIdentity() throws {
        let fixture = try fixture()
        let binding = AuthenticatedHandshakePeerBinding(
            authority: fixture.authority,
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(
                from: fixture.deviceId
            )
        )

        let result = try AuthenticatedPairingIdentityAuthorityValidator.issue(
            payload: fixture.payload,
            sessionBinding: binding,
            sessionDeviceIds: [
                "recent:mac:\(fixture.deviceId)",
                "id:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            ],
            operatorApproval: nil
        )

        XCTAssertEqual(result.declaredDeviceId, fixture.deviceId)
        XCTAssertEqual(result.authorizedDeviceIds, [fixture.deviceId])
    }

    func testSOAMismatchRejectsBeforeMutation() async throws {
        let fixture = try fixture()
        let binding = AuthenticatedHandshakePeerBinding(
            authority: fixture.authority,
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(
                from: "id:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )
        )
        var mutationCount = 0

        do {
            _ = try await AuthenticatedPairingIdentityAuthorityValidator
                .performAuthorizedMutation(
                    payload: fixture.payload,
                    sessionBinding: binding,
                    sessionDeviceIds: [fixture.deviceId],
                    operatorApproval: nil
                ) { _, _ in
                    mutationCount += 1
                }
            XCTFail("A mismatched SOA identity must be rejected")
        } catch {
            XCTAssertEqual(
                error as? PairingIdentityAuthorityValidationError,
                .soaDeviceIdentifierMismatch
            )
        }
        XCTAssertEqual(mutationCount, 0)
    }

    func testEndpointDeclaredIdentityRejectsBeforeAuthorityIssuance() throws {
        for endpointDeviceId in [
            "192.168.10.22",
            "id:192.168.10.22",
            "host:192.168.10.22",
            "bonjour:fixture@local.",
            "recent:host:192.168.10.22",
        ] {
            let fixture = try fixture(deviceId: endpointDeviceId)
            let binding = AuthenticatedHandshakePeerBinding(
                authority: fixture.authority,
                authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(
                    from: endpointDeviceId
                )
            )

            XCTAssertThrowsError(
                try AuthenticatedPairingIdentityAuthorityValidator.issue(
                    payload: fixture.payload,
                    sessionBinding: binding,
                    sessionDeviceIds: [endpointDeviceId],
                    operatorApproval: nil
                )
            ) { error in
                XCTAssertEqual(
                    error as? PairingIdentityAuthorityValidationError,
                    .invalidPayload
                )
            }
        }
    }

    func testNoSOARequiresExactPIBOperatorApproval() throws {
        let fixture = try fixture()
        let binding = AuthenticatedHandshakePeerBinding(
            authority: fixture.authority,
            authenticatedRemoteSOAPeerId: nil
        )
        let invalidApproval = PIBOperatorApprovalReceipt(
            declaredDeviceId: fixture.deviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fixture.fingerprint,
            protocolPublicKey: fixture.publicKey,
            pinSource: "authenticated-handshake"
        )

        XCTAssertThrowsError(
            try AuthenticatedPairingIdentityAuthorityValidator.issue(
                payload: fixture.payload,
                sessionBinding: binding,
                sessionDeviceIds: [fixture.deviceId],
                operatorApproval: invalidApproval
            )
        ) { error in
            XCTAssertEqual(
                error as? PairingIdentityAuthorityValidationError,
                .missingExactOperatorApproval
            )
        }

        let exactApproval = PIBOperatorApprovalReceipt(
            declaredDeviceId: fixture.deviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fixture.fingerprint,
            protocolPublicKey: fixture.publicKey,
            pinSource: AuthenticatedPairingIdentityAuthorityValidator
                .pibOperatorApprovalPinSource
        )
        let result = try AuthenticatedPairingIdentityAuthorityValidator.issue(
            payload: fixture.payload,
            sessionBinding: binding,
            sessionDeviceIds: ["id:untrusted-alias"],
            operatorApproval: exactApproval
        )
        XCTAssertEqual(result.authorizedDeviceIds, [fixture.deviceId])
    }

    func testNoSOAAcceptsOnlyExactVerifiedCurrentPathApproval() throws {
        let fixture = try fixture()
        let binding = AuthenticatedHandshakePeerBinding(
            authority: fixture.authority,
            authenticatedRemoteSOAPeerId: nil
        )
        let approval = CurrentPathOperatorApprovalReceipt(
            declaredDeviceId: fixture.deviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fixture.fingerprint,
            protocolPublicKey: fixture.publicKey
        )

        let admitted = try AuthenticatedPairingIdentityAuthorityValidator.issue(
            payload: fixture.payload,
            sessionBinding: binding,
            sessionDeviceIds: ["webrtc-runtime-alias"],
            operatorApproval: nil,
            currentPathApproval: approval
        )
        XCTAssertEqual(admitted.authorizedDeviceIds, [fixture.deviceId])

        let mismatchedApproval = CurrentPathOperatorApprovalReceipt(
            declaredDeviceId: "id:different-device",
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fixture.fingerprint,
            protocolPublicKey: fixture.publicKey
        )
        XCTAssertThrowsError(
            try AuthenticatedPairingIdentityAuthorityValidator.issue(
                payload: fixture.payload,
                sessionBinding: binding,
                sessionDeviceIds: [],
                operatorApproval: nil,
                currentPathApproval: mismatchedApproval
            )
        ) { error in
            XCTAssertEqual(
                error as? PairingIdentityAuthorityValidationError,
                .missingExactOperatorApproval
            )
        }
    }

    func testAcceptedMaterialDigestIgnoresPresentationMetadataButBindsKEMMaterial() throws {
        let fixture = try fixture()
        let binding = AuthenticatedHandshakePeerBinding(
            authority: fixture.authority,
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(
                from: fixture.deviceId
            )
        )
        let authority = try AuthenticatedPairingIdentityAuthorityValidator.issue(
            payload: fixture.payload,
            sessionBinding: binding,
            sessionDeviceIds: [fixture.deviceId],
            operatorApproval: nil
        )
        let authorityWithAdditionalAlias = try AuthenticatedPairingIdentityAuthorityValidator.issue(
            payload: fixture.payload,
            sessionBinding: binding,
            sessionDeviceIds: [
                fixture.deviceId,
                "recent:mac:ID:11111111-2222-4333-8444-555555555555"
            ],
            operatorApproval: nil
        )
        let metadataOnlyUpdate = AppMessage.PairingIdentityExchangePayload(
            deviceId: fixture.deviceId,
            kemPublicKeys: fixture.payload.kemPublicKeys,
            protocolIdentityPublicKeys: fixture.payload.protocolIdentityPublicKeys,
            deviceName: "Renamed Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "26.5",
            capabilities: ["file-transfer"],
            sentAt: Date().addingTimeInterval(10)
        )
        let sentAtOnlyUpdate = AppMessage.PairingIdentityExchangePayload(
            deviceId: fixture.deviceId,
            kemPublicKeys: fixture.payload.kemPublicKeys,
            protocolIdentityPublicKeys: fixture.payload.protocolIdentityPublicKeys,
            sentAt: Date().addingTimeInterval(20)
        )
        let rotatedKEM = AppMessage.PairingIdentityExchangePayload(
            deviceId: fixture.deviceId,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: Data(repeating: 0x52, count: 1_216)
                )
            ],
            protocolIdentityPublicKeys: fixture.payload.protocolIdentityPublicKeys
        )

        let originalDigest = try P2PConnectionManager
            .testOnlyAcceptedPairingIdentityMaterialDigest(
                payload: fixture.payload,
                authority: authority
            )
        let metadataDigest = try P2PConnectionManager
            .testOnlyAcceptedPairingIdentityMaterialDigest(
                payload: metadataOnlyUpdate,
                authority: authority
            )
        let rotatedKEMDigest = try P2PConnectionManager
            .testOnlyAcceptedPairingIdentityMaterialDigest(
                payload: rotatedKEM,
                authority: authority
            )
        let additionalAliasDigest = try P2PConnectionManager
            .testOnlyAcceptedPairingIdentityMaterialDigest(
                payload: fixture.payload,
                authority: authorityWithAdditionalAlias
            )

        XCTAssertEqual(originalDigest, metadataDigest)
        XCTAssertNotEqual(originalDigest, rotatedKEMDigest)
        XCTAssertEqual(originalDigest, additionalAliasDigest)
        XCTAssertTrue(
            P2PConnectionManager.testOnlyPairingIdentityPresentationMaterialChanged(
                from: fixture.payload,
                to: metadataOnlyUpdate
            )
        )
        XCTAssertFalse(
            P2PConnectionManager.testOnlyPairingIdentityPresentationMaterialChanged(
                from: fixture.payload,
                to: sentAtOnlyUpdate
            )
        )
        XCTAssertEqual(
            P2PConnectionManager.testOnlyCanonicalPairingIdentityAuthorityKey(
                fixture.deviceId
            ),
            P2PConnectionManager.testOnlyCanonicalPairingIdentityAuthorityKey(
                " recent:mac:ID:11111111-2222-4333-8444-555555555555 "
            )
        )
        let aliasPayload = AppMessage.PairingIdentityExchangePayload(
            deviceId: "recent:mac:ID:11111111-2222-4333-8444-555555555555",
            kemPublicKeys: fixture.payload.kemPublicKeys,
            protocolIdentityPublicKeys: fixture.payload.protocolIdentityPublicKeys
        )
        XCTAssertEqual(
            P2PConnectionManager.testOnlyStablePairingPolicyKey(for: fixture.payload),
            P2PConnectionManager.testOnlyStablePairingPolicyKey(for: aliasPayload)
        )
    }

    func testConflictingSOANeverFallsBackToValidPIBApproval() throws {
        let fixture = try fixture()
        let binding = AuthenticatedHandshakePeerBinding(
            authority: fixture.authority,
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(
                from: "id:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )
        )
        let approval = PIBOperatorApprovalReceipt(
            declaredDeviceId: fixture.deviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fixture.fingerprint,
            protocolPublicKey: fixture.publicKey,
            pinSource: AuthenticatedPairingIdentityAuthorityValidator
                .pibOperatorApprovalPinSource
        )

        XCTAssertThrowsError(
            try AuthenticatedPairingIdentityAuthorityValidator.issue(
                payload: fixture.payload,
                sessionBinding: binding,
                sessionDeviceIds: [fixture.deviceId],
                operatorApproval: approval
            )
        ) { error in
            XCTAssertEqual(
                error as? PairingIdentityAuthorityValidationError,
                .soaDeviceIdentifierMismatch
            )
        }
    }

    func testInvalidDeviceIdentifiersRejectBeforeMutation() async throws {
        let fixture = try fixture(deviceId: "id:bad\u{0000}device")
        let binding = AuthenticatedHandshakePeerBinding(
            authority: fixture.authority,
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(
                from: fixture.deviceId
            )
        )
        var mutationCount = 0

        do {
            _ = try await AuthenticatedPairingIdentityAuthorityValidator
                .performAuthorizedMutation(
                    payload: fixture.payload,
                    sessionBinding: binding,
                    sessionDeviceIds: [],
                    operatorApproval: nil
                ) { _, _ in
                    mutationCount += 1
                }
            XCTFail("A control-character device identifier must be rejected")
        } catch {
            XCTAssertEqual(
                error as? PairingIdentityAuthorityValidationError,
                .invalidPayload
            )
        }
        XCTAssertEqual(mutationCount, 0)
    }
}

@available(iOS 17.0, *)
@MainActor
final class P2PBootstrapPolicyTests: XCTestCase {
    private func readRepositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return try String(contentsOf: sourceURL, encoding: .utf8)
        }
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip(
            "Repository source files are not mounted inside the physical-device test sandbox; run source-shape regression tests on macOS or iOS Simulator."
        )
        #else
        return try String(contentsOf: sourceURL, encoding: .utf8)
        #endif
    }

    func testProvisionalBootstrapControlCanCoexistWithActiveAuthenticatedSession() {
        XCTAssertTrue(
            P2PConnectionManager.allowsPreHandshakeBootstrapControlRouting(
                isProvisionalConnection: true,
                hasHandshakeDriver: true,
                hasSessionKeys: true
            )
        )
        XCTAssertFalse(
            P2PConnectionManager.allowsPreHandshakeBootstrapControlRouting(
                isProvisionalConnection: false,
                hasHandshakeDriver: true,
                hasSessionKeys: true
            )
        )
        XCTAssertFalse(
            P2PConnectionManager.allowsPreHandshakeBootstrapControlRouting(
                isProvisionalConnection: false,
                hasHandshakeDriver: false,
                hasSessionKeys: true
            )
        )
        XCTAssertTrue(
            P2PConnectionManager.allowsPreHandshakeBootstrapControlRouting(
                isProvisionalConnection: false,
                hasHandshakeDriver: false,
                hasSessionKeys: false
            )
        )
    }

    func testInvalidProvisionalFrameEmitsVisibleClassificationFailure() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("stage=preflight-frame-classification"))
        XCTAssertTrue(source.contains("reason=unsupported_or_malformed"))
        XCTAssertTrue(source.contains("SkyBridgeLogger.shared.warning(line)"))
        XCTAssertTrue(source.contains("SignedKEMRefreshSmokeStatusWriter.append(line)"))
    }

    func testStrictPQCUsesBootstrapWhenPreferredKEMIsMissing() {
        XCTAssertFalse(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [],
                preferredTargetSuite: .xwing
            )
        )
    }

    func testStrictPQCDoesNotBootstrapWhenPreferredKEMExists() {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.xwing, .mlkem768],
                preferredTargetSuite: .xwing
            )
        )
    }

    func testStrictPQCAllowsAnyPQCTrustWhenNoPreferredSuiteIsPinned() {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.mlkem768],
                preferredTargetSuite: nil
            )
        )
    }

    func testStrictPQCRequiresPreferredHybridKEMWhenPinned() {
        XCTAssertFalse(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.mlkem768],
                preferredTargetSuite: .xwing
            )
        )
    }

    func testStrictPQCRequiresSignedRefreshEvidenceByDefault() throws {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.xwing],
                preferredTargetSuite: .xwing
            )
        )
        XCTAssertFalse(
            P2PConnectionManager.signedRefreshEvidenceSatisfiesStrictPQC(
                nil,
                preferredTargetSuite: .xwing
            )
        )

        let evidence = KEMTrustStore.SignedRefreshEvidence(
            deviceId: "id:signed-refresh-peer",
            suiteWireIds: [CryptoSuite.xwing.wireId],
            source: "signed_lan_kem_refresh",
            keyId: "skr1-test",
            generation: 1,
            expiresAt: Date().addingTimeInterval(60),
            protocolIdentityFingerprint: String(repeating: "a", count: 64),
            signingFingerprint: String(repeating: "a", count: 64),
            payloadHashHex: String(repeating: "b", count: 64),
            updatedAt: Date()
        )
        XCTAssertTrue(
            P2PConnectionManager.signedRefreshEvidenceSatisfiesStrictPQC(
                evidence,
                preferredTargetSuite: .xwing
            )
        )

        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        XCTAssertTrue(source.contains("requiresSignedKEMRefreshEvidenceForStrictPQC"))
        XCTAssertFalse(
            source.contains("SKYBRIDGE_STRICT_PQC_ALLOW_UNSIGNED_LEGACY_KEM"),
            "strictPQC must not expose an unsigned legacy KEM bypass that can mask missing SKR-1 evidence."
        )
        XCTAssertTrue(source.contains("return true"))
        XCTAssertTrue(source.contains("signedRefreshEvidenceSuites(initialSignedRefreshEvidence)"))
    }

    func testStrictOutboundHandshakePassesPinnedTrustProviderToFinalDriver() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("stage: \"outbound\""))
        XCTAssertTrue(source.contains("throw P2PError.missingPinnedProtocolIdentity"))
        XCTAssertTrue(source.contains("trustProvider: strictTrustContext?.provider"))
        XCTAssertTrue(
            source.contains("expectedRemoteSOAPeerId: soaPeerIdBytes(for: strictTrustContext?.stablePeerId ?? peerId) ?? remotePeerId")
        )
        XCTAssertFalse(
            source.contains("trustProvider: nil"),
            "strict outbound P2P must not silently fall back to DefaultHandshakeTrustProvider after preflight."
        )
    }

    func testStrictOutboundSOAUsesResolvedStablePeerInsteadOfEndpointAlias() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func performPQCHandshake("))
        let end = try XCTUnwrap(source.range(of: "public func rekeyToPreferPQC(", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        let trustContext = try XCTUnwrap(body.range(of: "let strictTrustContext"))
        let target = try XCTUnwrap(body.range(of: "let outboundSOATargetPeerId = strictTrustContext?.stablePeerId ?? peerId"))
        let shouldAdvertise = try XCTUnwrap(body.range(of: "let shouldAdvertiseSOA = allowSOA && (shouldUseSOA(for: device) || canBindSOATarget)"))
        let outboundSOA = try XCTUnwrap(body.range(of: "let outboundSOA: HandshakeSOAMetadata?"))

        XCTAssertLessThan(trustContext.lowerBound, target.lowerBound)
        XCTAssertLessThan(target.lowerBound, shouldAdvertise.lowerBound)
        XCTAssertLessThan(shouldAdvertise.lowerBound, outboundSOA.lowerBound)
        XCTAssertTrue(body.contains("let remotePeerId = shouldAdvertiseSOA ? soaPeerIdBytes(for: outboundSOATargetPeerId) : nil"))
        XCTAssertFalse(
            body.contains("let remotePeerId = shouldAdvertiseSOA ? soaPeerIdBytes(for: device.id) : nil"),
            "Strict outbound SOA must bind to the resolved stable peer id, not the current host/Bonjour endpoint alias."
        )
    }

    func testStrictPreflightMissingKEMWithPinnedIdentityChoosesPIBBeforeSKR() {
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: nil,
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)],
            preferredTargetSuite: .xwing
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testStrictPreflightMissingKEMWithoutPinnedIdentityChoosesPIBThenSKR() {
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: nil,
            pinnedProtocolFingerprints: [],
            preferredTargetSuite: .xwing
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testStrictPreflightUnsignedLegacyKEMStillRequiresPIBBeforeSignedRefreshEvidence() {
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [.xwing],
            signedRefreshEvidence: nil,
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)],
            preferredTargetSuite: .xwing,
            requiresSignedRefreshEvidence: true
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testStrictPreflightOnlyProceedsAfterSignedLANRefreshEvidenceIsImported() async throws {
        let peerId = "id:mac-skr-chain"
        let now = Date()
        let signingKey = Curve25519.Signing.PrivateKey()
        let protocolPublicKey = signingKey.publicKey.rawRepresentation
        let protocolFingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .ed25519
        ).authoritativeFingerprint

        await KEMTrustStore.shared.clearForTesting()
        await KEMTrustStore.shared.upsert(
            deviceId: peerId,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0xA1, count: 1216)
                )
            ]
        )

        let unsignedEvidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: [peerId])
        let unsignedKeys = await P2PConnectionManager.trustedPeerKEMPublicKeysFromAllStores(forAny: [peerId])
        let unsignedAction = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: Set(unsignedKeys.keys),
            signedRefreshEvidence: unsignedEvidence,
            pinnedProtocolFingerprints: [protocolFingerprint],
            preferredTargetSuite: .xwing,
            requiresSignedRefreshEvidence: true
        )
        XCTAssertEqual(unsignedAction, .attemptOOBProtocolIdentityBindingThenRefresh)

        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-viewer",
            targetDeviceId: peerId,
            requesterProtocolIdentityFingerprint: String(repeating: "b", count: 64),
            targetProtocolIdentityFingerprint: protocolFingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: Data(repeating: 0x44, count: 24),
            sentAt: now
        )
        let unsignedPayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: peerId,
            aliases: [peerId, "bonjour:mac-skr-chain@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: protocolFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1216)
                )
            ],
            keyId: "skr-chain-1",
            generation: 9,
            sentAt: now,
            expiresAt: now.addingTimeInterval(
                P2PProtocolIdentityBindingAdmissionPolicy.maximumTransactionTTLSeconds
            ),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            signature: Data()
        )
        let provider = ClassicSignatureProvider()
        let signature = try await provider.sign(
            unsignedPayload.signaturePreimage,
            key: .softwareKey(signingKey.rawRepresentation)
        )
        let signedPayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: unsignedPayload.deviceId,
            aliases: unsignedPayload.aliases,
            protocolSigningAlgorithm: unsignedPayload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: unsignedPayload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: unsignedPayload.protocolIdentityFingerprint,
            kemPublicKeys: unsignedPayload.kemPublicKeys,
            keyId: unsignedPayload.keyId,
            generation: unsignedPayload.generation,
            sentAt: unsignedPayload.sentAt,
            expiresAt: unsignedPayload.expiresAt,
            requestNonce: unsignedPayload.requestNonce,
            requestHashHex: unsignedPayload.requestHashHex,
            signature: signature
        )

        XCTAssertNoThrow(try signedPayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [protocolFingerprint],
            minimumGeneration: nil
        ))
        let verifiedSignature = try await provider.verify(
            signedPayload.signaturePreimage,
            signature: signedPayload.signature,
            publicKey: protocolPublicKey
        )
        XCTAssertTrue(verifiedSignature)

        try await KEMTrustStore.shared.upsertSignedKEMRefresh(
            deviceIds: [peerId],
            payload: signedPayload,
            request: request,
            pinnedProtocolFingerprints: [protocolFingerprint],
            minimumGeneration: nil
        )

        let maybeSignedEvidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: [peerId])
        let signedEvidence = try XCTUnwrap(maybeSignedEvidence)
        XCTAssertEqual(signedEvidence.source, "signed_lan_kem_refresh")
        XCTAssertEqual(signedEvidence.keyId, "skr-chain-1")
        XCTAssertEqual(signedEvidence.generation, 9)
        XCTAssertEqual(signedEvidence.signingFingerprint, protocolFingerprint.lowercased())
        XCTAssertNotNil(signedEvidence.payloadHashHex)

        let signedKeys = await P2PConnectionManager.trustedPeerKEMPublicKeysFromAllStores(forAny: [peerId])
        let signedAction = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: Set(signedKeys.keys),
            signedRefreshEvidence: signedEvidence,
            pinnedProtocolFingerprints: [protocolFingerprint],
            preferredTargetSuite: .xwing,
            requiresSignedRefreshEvidence: true
        )
        XCTAssertEqual(signedAction, .proceed)

        await KEMTrustStore.shared.clearForTesting()
    }

    func testStrictPreflightSignedRefreshEvidenceAllowsProceed() {
        let evidence = KEMTrustStore.SignedRefreshEvidence(
            deviceId: "id:signed-refresh-peer",
            suiteWireIds: [CryptoSuite.xwing.wireId],
            source: "signed_lan_kem_refresh",
            keyId: "skr1-test",
            generation: 1,
            expiresAt: Date().addingTimeInterval(60),
            protocolIdentityFingerprint: String(repeating: "a", count: 64),
            signingFingerprint: String(repeating: "a", count: 64),
            payloadHashHex: String(repeating: "b", count: 64),
            updatedAt: Date()
        )
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: evidence,
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)],
            preferredTargetSuite: .xwing
        )

        XCTAssertEqual(action, .proceed)
    }

    func testStrictPreflightSignedEvidenceStillRequiresPinnedProtocolIdentity() {
        let evidence = KEMTrustStore.SignedRefreshEvidence(
            deviceId: "id:mac-skr-without-pin",
            suiteWireIds: [CryptoSuite.xwing.wireId],
            source: "signed_lan_kem_refresh",
            keyId: "skr1-test",
            generation: 1,
            expiresAt: Date().addingTimeInterval(60),
            protocolIdentityFingerprint: String(repeating: "a", count: 64),
            signingFingerprint: String(repeating: "a", count: 64),
            payloadHashHex: String(repeating: "b", count: 64),
            updatedAt: Date()
        )
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: evidence,
            pinnedProtocolFingerprints: [],
            preferredTargetSuite: .xwing
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testStrictPreflightSKRIdentityMismatchChoosesPIBThenSKR() {
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: nil,
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)],
            preferredTargetSuite: .xwing,
            signedRefreshFailureReason: "remote rejected SKR-1 stage=kem_refresh reasonCode=pinned_protocol_identity_mismatch_requires_oob"
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testStrictPreflightSKRRequesterNotPinnedChoosesPIBThenSKR() {
        let action = P2PConnectionManager.strictPQCPreflightAction(
            trustedPeerKEMSuites: [],
            signedRefreshEvidence: nil,
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)],
            preferredTargetSuite: .xwing,
            signedRefreshFailureReason: "remote rejected SKR-1 stage=kem_refresh reasonCode=requester_protocol_identity_not_pinned"
        )

        XCTAssertEqual(action, .attemptOOBProtocolIdentityBindingThenRefresh)
    }

    func testDiscoveredDeviceAddUsesDeviceConfirmationPairingInsteadOfDirectTrust() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/SettingsView.swift"
        )

        XCTAssertTrue(source.contains("Section(\"从已发现设备添加\")"))
        XCTAssertFalse(
            source.contains("store.trust(dev)"),
            "Bonjour discovery must not become a TOFU trust source; discovered devices must use the PIB-1 device confirmation path."
        )
        XCTAssertTrue(source.contains("startDeviceConfirmationPairing(dev)"))
        XCTAssertTrue(source.contains("P2PConnectionManager.instance.connect(to: device)"))
        XCTAssertTrue(source.contains("设备确认码配对"))
    }

    func testSettingsSecurityControlsDoNotExposeFakeRuntimeBindings() throws {
        let settingsSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/SettingsView.swift"
        )
        let contentSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/ContentView.swift"
        )

        XCTAssertFalse(settingsSource.contains(".constant(false)"))
        XCTAssertFalse(settingsSource.contains("Toggle(isOn: $settingsManager.requireBiometricAuth)"))
        XCTAssertFalse(settingsSource.contains("Toggle(isOn: $settingsManager.endToEndEncryption)"))
        XCTAssertFalse(settingsSource.contains("Image(systemName: \"checkmark.circle.fill\")\n                        .foregroundColor(.green)"))
        XCTAssertFalse(settingsSource.contains("try? await pqcManager.generateKeyPair()"))
        XCTAssertFalse(settingsSource.contains("try? await pqcManager.regenerateKeyPair()"))
        XCTAssertFalse(contentSource.contains(".sheet(\n            item: Binding(\n                get: { connectionManager.pendingPairingTrustRequest }"))
        XCTAssertTrue(contentSource.contains("PairingTrustPromptWindowPresenter"))
        XCTAssertTrue(contentSource.contains("Button(RuntimeLocalization.string(\"关闭\")) { onDecision(.reject) }"))
    }

    @MainActor
    func testPQCProviderPreferenceDecodingUsesOneDeterministicPriority() throws {
        let suiteName = "P2PBootstrapPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            PQCCryptoManager.currentProviderPreference(userDefaults: defaults),
            .mlkem
        )

        defaults.set(
            true,
            forKey: PQCProviderPreferenceStorageKeys.preferXWingHybrid
        )
        XCTAssertEqual(
            PQCCryptoManager.currentProviderPreference(userDefaults: defaults),
            .xwingHybrid
        )

        defaults.set(
            true,
            forKey: PQCProviderPreferenceStorageKeys.preferQPeriaptBeta
        )
        XCTAssertEqual(
            PQCCryptoManager.currentProviderPreference(userDefaults: defaults),
            .qPeriaptBeta
        )
    }

    @MainActor
    func testPQCProviderAvailabilityDistinguishesEveryVisibleOption() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            hasQPeriapt: false,
            hasAppleXWing: false,
            osVersion: "test"
        )

        XCTAssertTrue(
            PQCCryptoManager.providerAvailability(
                .mlkem,
                capability: capability,
                qPeriaptOSAvailable: true,
                qPeriaptIdentityEligible: true
            ).isAvailable
        )
        XCTAssertFalse(
            PQCCryptoManager.providerAvailability(
                .xwingHybrid,
                capability: capability,
                qPeriaptOSAvailable: true,
                qPeriaptIdentityEligible: true
            ).isAvailable,
            "General Apple PQC availability must not be mistaken for an X-Wing runtime proof."
        )
        XCTAssertFalse(
            PQCCryptoManager.providerAvailability(
                .qPeriaptBeta,
                capability: capability,
                qPeriaptOSAvailable: false,
                qPeriaptIdentityEligible: true
            ).isAvailable
        )
        XCTAssertFalse(
            PQCCryptoManager.providerAvailability(
                .qPeriaptBeta,
                capability: capability,
                qPeriaptOSAvailable: true,
                qPeriaptIdentityEligible: false
            ).isAvailable
        )
        XCTAssertTrue(
            PQCCryptoManager.providerAvailability(
                .qPeriaptBeta,
                capability: capability,
                qPeriaptOSAvailable: true,
                qPeriaptIdentityEligible: true
            ).isAvailable
        )
    }

    func testPQCProviderPreferenceUIUsesTransactionalRuntimeApplication() throws {
        let settingsSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/SettingsView.swift"
        )
        let managerSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/PQCCryptoManager.swift"
        )
        let factorySource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/CryptoProviderFactory.swift"
        )

        XCTAssertTrue(settingsSource.contains("X-Wing 混合加密"))
        XCTAssertTrue(settingsSource.contains("Q-Periapt ABI2（Beta）"))
        XCTAssertTrue(settingsSource.contains("availability.isAvailable ? \"可用\" : \"不可用\""))
        XCTAssertTrue(settingsSource.contains("selectedProviderAvailability.detail"))
        XCTAssertTrue(settingsSource.contains("try await pqcManager.applyProviderPreference(preference)"))
        XCTAssertTrue(managerSource.contains("preference == .xwingHybrid"))
        XCTAssertTrue(managerSource.contains("preference == .qPeriaptBeta"))
        XCTAssertTrue(managerSource.contains("PQCProviderPreferenceError.qPeriaptRequiresMLDSA65"))
        XCTAssertTrue(managerSource.contains("previousXWing"))
        XCTAssertTrue(managerSource.contains("previousQPeriapt"))
        XCTAssertTrue(managerSource.contains("try await initialize()"))
        XCTAssertTrue(managerSource.contains("clearInMemoryKeyMaterial()"))
        XCTAssertEqual(
            factorySource.components(separatedBy: "\"Settings.PreferXWingHybrid\"").count - 1,
            1,
            "The iOS provider preference key must have one source of truth."
        )
        XCTAssertEqual(
            factorySource.components(separatedBy: "\"Settings.PreferQPeriaptBeta\"").count - 1,
            1,
            "The iOS Q-Periapt preference key must have one source of truth."
        )
    }

    func testLegacyPQCVerificationDelegatesToExactAuthenticatedSessionTrustApproval() throws {
        let pqcSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/PQCCryptoManager.swift"
        )
        let p2pSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let trustedStoreSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/TrustedDeviceStore.swift"
        )

        XCTAssertFalse(pqcSource.contains("TrustedDeviceStore.shared.trust(device)"))
        XCTAssertTrue(pqcSource.contains(".approveCurrentAuthenticatedSessionTrust("))
        XCTAssertFalse(pqcSource.contains("TrustedDeviceStore.shared.trustResolvedPeer"))
        XCTAssertFalse(pqcSource.contains("expected=\\(expected)"))
        XCTAssertFalse(pqcSource.contains("got=\\(code)"))

        let approvalStart = try XCTUnwrap(
            p2pSource.range(of: "public func approveCurrentAuthenticatedSessionTrust(")
        )
        let approvalEnd = try XCTUnwrap(
            p2pSource.range(
                of: "private enum SessionTrustApprovalError",
                range: approvalStart.upperBound..<p2pSource.endIndex
            )
        )
        let approvalBody = String(
            p2pSource[approvalStart.lowerBound..<approvalEnd.lowerBound]
        )
        for requiredMarker in [
            "exactAuthenticatedSessionForStableDeviceIdentifier(",
            "!PeerIdentityAliasResolver.isEndpointAlias(device.id)",
            "try requireCurrentAuthenticatedConnection(current.receipt)",
            "Self.constantTimeEqual(verificationCode, expectedCode)",
            "sessionPairingAuthorityByPeerId[current.peerId]",
            ".upsertAuthorityBound(",
            "recordApprovedProtocolIdentityBinding(",
            ".rollbackAuthorityBoundMutation(protocolMutationReceipt)",
        ] {
            XCTAssertTrue(approvalBody.contains(requiredMarker), requiredMarker)
        }
        XCTAssertFalse(
            trustedStoreSource.contains("guard !normalizedDeclaredDeviceId.isEmpty else {\n            trust(device)"),
            "trustResolvedPeer must not fall back to direct discovery trust when the authenticated declared device id is missing."
        )
    }

    func testCryptoKitErrorThreeIsTreatedAsStaleKEMCryptoFailure() {
        let error = NSError(
            domain: "CryptoKit.CryptoKitError",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed. (CryptoKit.CryptoKitError error 3.)"]
        )

        XCTAssertTrue(P2PConnectionManager.isLikelyStalePeerKEMCryptoFailure(error))
    }

    func testMessageBPayloadAuthenticationFailureIsTreatedAsStaleKEMCryptoFailure() {
        let error = HandshakeError.failed(
            .cryptoError(
                "messageBPayloadAuthenticationFailed suite=ML-KEM-768: The operation couldn’t be completed. (CryptoKit.CryptoKitError error 3.)"
            )
        )

        XCTAssertTrue(P2PConnectionManager.isLikelyStalePeerKEMCryptoFailure(error))
        XCTAssertEqual(
            P2PConnectionManager.localizedConnectionErrorMessage(error),
            "安全验证失败：解密认证失败（可能是对端 PQC KEM 公钥已变更或缓存失效）。当前已中止连接，不会降级或假装成功；请重新完成受信任设备验证后重试。"
        )
    }

    func testStaleKEMFailureEntersSignedLANRefreshInsteadOfUserRetry() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("recoverStalePeerKEMWithSignedLANRefresh"))
        XCTAssertTrue(source.contains("stage=stale-kem-refresh"))
        XCTAssertTrue(source.contains("failure=messageBPayloadAuthenticationFailed"))
        XCTAssertFalse(source.contains("请重试连接以触发 SKR-1 signed LAN KEM refresh"))
    }

    func testSignedLANRefreshRemoteFailureIsSurfacedWithReasonCode() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("case .kemRefreshFailure(let failure)"))
        XCTAssertTrue(source.contains("remote rejected SKR-1 stage="))
        XCTAssertTrue(source.contains("reasonCode=\\(failure.reasonCode)"))
    }

    func testSignedLANRefreshUsesCryptographicResponseBudget() throws {
        XCTAssertEqual(
            P2PConnectionManager.signedLANRefreshResponseTimeoutSeconds(),
            30
        )

        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        XCTAssertTrue(
            source.contains(
                "let responseTimeoutSeconds = Self.signedLANRefreshResponseTimeoutSeconds()"
            )
        )
        XCTAssertTrue(source.contains("responseTimeoutSeconds=\\(Int(responseTimeoutSeconds))"))
        XCTAssertTrue(source.contains("timeoutSeconds: responseTimeoutSeconds"))
        XCTAssertFalse(source.contains("timeoutSeconds: 6.0"))
    }

    func testSignedLANRefreshRetriesReuseCompletedSignedResponse() throws {
        let managerSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let gateSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/P2P/SignedKEMRefreshRequestAdmissionGate.swift"
        )
        let cacheLookup = try XCTUnwrap(
            managerSource.range(of: "admissionGate.cachedCompletedResponse(")
        )
        let replayAdmission = try XCTUnwrap(
            managerSource.range(
                of: "let admission = await admissionGate.admit(",
                range: cacheLookup.upperBound..<managerSource.endIndex
            )
        )
        let cacheRecord = try XCTUnwrap(
            managerSource.range(
                of: "await admissionGate.recordCompletedResponse(",
                range: replayAdmission.upperBound..<managerSource.endIndex
            )
        )

        XCTAssertLessThan(cacheLookup.lowerBound, replayAdmission.lowerBound)
        XCTAssertLessThan(replayAdmission.lowerBound, cacheRecord.lowerBound)
        XCTAssertTrue(gateSource.contains("private let maxEntries: Int"))
        XCTAssertTrue(gateSource.contains("completedResponses.removeValue(forKey: key)"))
    }

    func testSignedLANRefreshRequestBindsPolicyHashOnIOS() {
        let fingerprint = String(repeating: "a", count: 64)
        let nonce = Data(repeating: 0x44, count: 24)
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: nonce,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(request.policyHashHex, request.expectedPolicyHashHex)
        XCTAssertTrue(request.hasExpectedPolicyHash)
        XCTAssertTrue(request.hasRequesterProtocolIdentityFingerprint)
        let preimage = String(data: request.canonicalPreimage, encoding: .utf8) ?? ""
        XCTAssertTrue(preimage.contains("requesterProtocolIdentityFingerprint=\(fingerprint.lowercased())"))
        XCTAssertTrue(preimage.contains("policyRequirePQC=1"))
        XCTAssertTrue(preimage.contains("policyAllowClassicFallback=0"))
        XCTAssertTrue(preimage.contains("policyHashHex=\(request.expectedPolicyHashHex)"))

        let tamperedPolicyHash = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            policyHashHex: String(repeating: "0", count: 64),
            nonce: nonce,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(tamperedPolicyHash.hasExpectedPolicyHash)
        XCTAssertNotEqual(tamperedPolicyHash.canonicalRequestHashHex, request.canonicalRequestHashHex)

        let missingRequesterIdentity = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: nonce,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(missingRequesterIdentity.hasRequesterProtocolIdentityFingerprint)
    }

    func testCanonicalMillisecondsRejectNonFiniteAndInt64OverflowOnIOS() {
        let upperBoundExclusive = -Double(Int64.min)

        XCTAssertEqual(AppMessage.canonicalMillisecondsSinceEpoch(milliseconds: 1.999), 1)
        XCTAssertEqual(AppMessage.canonicalMillisecondsSinceEpoch(milliseconds: -0.001), -1)
        XCTAssertEqual(
            AppMessage.canonicalMillisecondsSinceEpoch(milliseconds: Double(Int64.min)),
            Int64.min
        )
        XCTAssertNil(AppMessage.canonicalMillisecondsSinceEpoch(milliseconds: upperBoundExclusive))
        XCTAssertNil(AppMessage.canonicalMillisecondsSinceEpoch(milliseconds: .infinity))
        XCTAssertNil(AppMessage.canonicalMillisecondsSinceEpoch(milliseconds: .nan))
    }

    func testUnrepresentableSKRRequestAndResponseTimestampsFailClosedOnIOS() {
        let hugeDate = Date(timeIntervalSince1970: .greatestFiniteMagnitude)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let protocolPublicKey = Data(repeating: 0x33, count: 1_184)
        let fingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: Data(repeating: 0x44, count: 24),
            sentAt: hugeDate
        )
        XCTAssertNil(request.canonicalRequestHashHexIfRepresentable)
        XCTAssertThrowsError(try request.validatedStrictResponderSuites(now: now)) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .unrepresentableTimestamp
            )
        }

        let response = AppMessage.SignedKEMRefreshPayload(
            deviceId: "id:mac-1",
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: fingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1_216)
                )
            ],
            keyId: "skr-1",
            generation: 1,
            sentAt: now,
            expiresAt: hugeDate,
            requestNonce: Data(repeating: 0x44, count: 24),
            requestHashHex: String(repeating: "a", count: 64),
            signature: Data(repeating: 0x99, count: 64)
        )
        XCTAssertThrowsError(
            try response.validatedForStrictPQCImport(
                now: now,
                pinnedProtocolFingerprints: [fingerprint]
            )
        ) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .unrepresentableTimestamp
            )
        }
    }

    func testSignedLANRefreshRequestCarriesRequesterIdentityAndVerifiesBeforeImport() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("localProtocolIdentityFingerprintForSignedLANRefresh"))
        XCTAssertTrue(source.contains("requesterProtocolIdentityFingerprint: requesterProtocolIdentityFingerprint"))
        guard let verifyRange = source.range(of: "let verified = try await signatureProvider.verify"),
              let upsertRange = source.range(of: "try await KEMTrustStore.shared.upsertSignedKEMRefresh") else {
            XCTFail("SKR-1 verify/upsert path not found")
            return
        }
        XCTAssertLessThan(verifyRange.lowerBound, upsertRange.lowerBound)
        XCTAssertTrue(source.contains("guard verified else"))
        XCTAssertTrue(source.contains("signature verification failed"))
    }

    func testSignedLANRefreshImportBindsOriginalRequestOnIOS() throws {
        let now = Date()
        let protocolPublicKey = Data(repeating: 0x33, count: 1184)
        let fingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: Data(repeating: 0x44, count: 24),
            sentAt: now
        )
        let payload = AppMessage.SignedKEMRefreshPayload(
            deviceId: "id:mac-1",
            aliases: ["id:mac-1"],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: fingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1216)
                )
            ],
            keyId: "skr-1",
            generation: 7,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            signature: Data(repeating: 0x99, count: 64)
        )
        let preimage = String(data: payload.signaturePreimage, encoding: .utf8) ?? ""
        XCTAssertTrue(preimage.contains("suiteNames=X-Wing"))
        XCTAssertTrue(preimage.contains("suiteWireIds=0x0001"))

        XCTAssertNoThrow(try payload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        ))

        let unrequestedSuitePayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: payload.deviceId,
            aliases: payload.aliases,
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: payload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: payload.protocolIdentityFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                    publicKey: Data(repeating: 0x66, count: 1184)
                )
            ],
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: payload.requestNonce,
            requestHashHex: payload.requestHashHex,
            signature: payload.signature
        )
        XCTAssertThrowsError(try unrequestedSuitePayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .responseSuiteNotRequested(wireId: CryptoSuite.mlkem768MLDSA65.wireId)
            )
        }

        let otherProtocolPublicKey = Data(repeating: 0x34, count: 1184)
        let otherFingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: otherProtocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
        let unpinnedPayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: payload.deviceId,
            aliases: payload.aliases,
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: otherProtocolPublicKey,
            protocolIdentityFingerprint: otherFingerprint,
            kemPublicKeys: payload.kemPublicKeys,
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: payload.requestNonce,
            requestHashHex: payload.requestHashHex,
            signature: payload.signature
        )
        XCTAssertThrowsError(try unpinnedPayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .pinnedProtocolIdentityMismatch(fingerprint: otherFingerprint.lowercased())
            )
        }

        let wrongHashPayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: payload.deviceId,
            aliases: payload.aliases,
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: payload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: payload.protocolIdentityFingerprint,
            kemPublicKeys: payload.kemPublicKeys,
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: payload.requestNonce,
            requestHashHex: String(repeating: "e", count: 64),
            signature: payload.signature
        )
        XCTAssertThrowsError(try wrongHashPayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestHashMismatch)
        }

        let wrongNoncePayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: payload.deviceId,
            aliases: payload.aliases,
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: payload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: payload.protocolIdentityFingerprint,
            kemPublicKeys: payload.kemPublicKeys,
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: Data(repeating: 0x45, count: 24),
            requestHashHex: payload.requestHashHex,
            signature: payload.signature
        )
        XCTAssertThrowsError(try wrongNoncePayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestNonceMismatch)
        }

        let wrongTargetPayload = AppMessage.SignedKEMRefreshPayload(
            deviceId: "id:other-mac",
            aliases: ["bonjour:other-mac@local."],
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: payload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: payload.protocolIdentityFingerprint,
            kemPublicKeys: payload.kemPublicKeys,
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: payload.requestNonce,
            requestHashHex: payload.requestHashHex,
            signature: payload.signature
        )
        XCTAssertThrowsError(try wrongTargetPayload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .targetDeviceIdMismatch)
        }

        let wrongPolicyRequest = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: request.requesterDeviceId,
            targetDeviceId: request.targetDeviceId,
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: request.requestedSuiteWireIds,
            policyHashHex: String(repeating: "0", count: 64),
            nonce: request.nonce,
            sentAt: request.sentAt
        )
        XCTAssertThrowsError(try payload.validatedForStrictPQCImport(
            request: wrongPolicyRequest,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestPolicyHashMismatch)
        }
    }

    func testSignedLANRefreshRejectsTamperedSignatureOnIOS() async throws {
        let now = Date()
        let signingKey = Curve25519.Signing.PrivateKey()
        let protocolPublicKey = signingKey.publicKey.rawRepresentation
        let protocolFingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .ed25519
        ).authoritativeFingerprint
        let unsigned = AppMessage.SignedKEMRefreshPayload(
            deviceId: "id:mac-1",
            aliases: ["id:mac-1", "bonjour:mac@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: protocolFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1216)
                )
            ],
            keyId: "skr-1",
            generation: 7,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: Data(repeating: 0x44, count: 24),
            requestHashHex: String(repeating: "b", count: 64),
            signature: Data()
        )
        let provider = ClassicSignatureProvider()
        let signature = try await provider.sign(
            unsigned.signaturePreimage,
            key: .softwareKey(signingKey.rawRepresentation)
        )
        let signed = AppMessage.SignedKEMRefreshPayload(
            deviceId: unsigned.deviceId,
            aliases: unsigned.aliases,
            protocolSigningAlgorithm: unsigned.protocolSigningAlgorithm,
            protocolIdentityPublicKey: unsigned.protocolIdentityPublicKey,
            protocolIdentityFingerprint: unsigned.protocolIdentityFingerprint,
            kemPublicKeys: unsigned.kemPublicKeys,
            keyId: unsigned.keyId,
            generation: unsigned.generation,
            sentAt: unsigned.sentAt,
            expiresAt: unsigned.expiresAt,
            requestNonce: unsigned.requestNonce,
            requestHashHex: unsigned.requestHashHex,
            signature: signature
        )

        XCTAssertNoThrow(try signed.validatedForStrictPQCImport(
            now: now,
            pinnedProtocolFingerprints: [protocolFingerprint],
            minimumGeneration: 7
        ))
        let signedVerification = try await provider.verify(
            signed.signaturePreimage,
            signature: signed.signature,
            publicKey: protocolPublicKey
        )
        XCTAssertTrue(signedVerification)

        let tampered = AppMessage.SignedKEMRefreshPayload(
            deviceId: signed.deviceId,
            aliases: signed.aliases,
            protocolSigningAlgorithm: signed.protocolSigningAlgorithm,
            protocolIdentityPublicKey: signed.protocolIdentityPublicKey,
            protocolIdentityFingerprint: signed.protocolIdentityFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x56, count: 1216)
                )
            ],
            keyId: signed.keyId,
            generation: signed.generation,
            sentAt: signed.sentAt,
            expiresAt: signed.expiresAt,
            requestNonce: signed.requestNonce,
            requestHashHex: signed.requestHashHex,
            signature: signed.signature
        )
        let tamperedVerification = try await provider.verify(
            tampered.signaturePreimage,
            signature: tampered.signature,
            publicKey: protocolPublicKey
        )
        XCTAssertFalse(tamperedVerification)
    }

    func testNonAEADCryptoErrorDoesNotTriggerStaleKEMClearing() {
        let error = HandshakeError.failed(.cryptoError("CryptoKit.CryptoKitError error 0"))

        XCTAssertFalse(P2PConnectionManager.isLikelyStalePeerKEMCryptoFailure(error))
    }

    func testMissingPeerKEMIsProvisioningFailureNotStaleKEMClear() {
        let error = HandshakeError.failed(.missingPeerKEMPublicKey(suite: CryptoSuite.xwing.rawValue))

        XCTAssertFalse(P2PConnectionManager.isLikelyStalePeerKEMCryptoFailure(error))
        XCTAssertEqual(
            P2PConnectionManager.localizedConnectionErrorMessage(error),
            "缺少对端后量子密钥材料（X-Wing），无法建立 PQC 握手。当前已中止连接，不会降级或假装成功；请重新完成受信任设备验证后重试。"
        )
    }

    func testStrictPQCPreflightReadsExpandedKEMTrustAliases() async throws {
        let uuid = "11111111-1111-1111-1111-111111111111"
        let peerId = "id:\(uuid)"
        let alias = uuid
        let key = Data(repeating: 0xAB, count: 1_216)

        await KEMTrustStore.shared.clearForTesting()

        await KEMTrustStore.shared.upsert(
            deviceId: peerId,
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwing.wireId, publicKey: key)]
        )

        let merged = await P2PConnectionManager.trustedPeerKEMPublicKeysFromAllStores(forAny: [alias])
        XCTAssertEqual(merged[.xwing], key)

        await KEMTrustStore.shared.clearForTesting()
    }

    func testProtocolIdentityTrustStoreResolvesPinnedFingerprintDeviceIds() async throws {
        let peerId = "id:stable-p2p-mac"
        let fingerprint = String(repeating: "b", count: 64)

        await ProtocolIdentityTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.upsert(deviceId: peerId, fingerprints: [fingerprint])

        let deviceIds = await ProtocolIdentityTrustStore.shared.deviceIds(containingFingerprint: fingerprint)
        XCTAssertTrue(deviceIds.contains(peerId))
        XCTAssertTrue(deviceIds.contains("stable-p2p-mac"))
        let invalidFingerprintMatches = await ProtocolIdentityTrustStore.shared
            .deviceIds(containingFingerprint: String(repeating: "z", count: 64))
        XCTAssertTrue(invalidFingerprintMatches.isEmpty)

        await ProtocolIdentityTrustStore.shared.clearForTesting()
    }

    func testForgetClearsKEMAndProtocolIdentityCaches() async throws {
        let peerId = "id:forgotten-peer"
        let key = Data(repeating: 0xA1, count: 1_216)
        let fingerprint = String(repeating: "a", count: 64)
        let kemKeys = [KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwing.wireId, publicKey: key)]

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()

        await KEMTrustStore.shared.upsert(deviceId: peerId, kemPublicKeys: kemKeys)
        await ProtocolIdentityTrustStore.shared.upsert(deviceId: peerId, fingerprints: [fingerprint])

        try await P2PConnectionManager.instance.clearTrustMaterialForForgottenDevice(deviceIds: [peerId])

        let clearedKEMKeys = await KEMTrustStore.shared.kemPublicKeys(forAny: [peerId])
        let clearedFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(forAny: [peerId])
        XCTAssertTrue(clearedKEMKeys.isEmpty)
        XCTAssertTrue(clearedFingerprints.isEmpty)

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()
    }

    func testFullForgetDoesNotAllowSKRImportWithoutPinnedProtocolIdentity() async throws {
        let peerId = "id:forgotten-refresh-peer"
        let oldKEM = Data(repeating: 0xA1, count: 1216)
        let oldFingerprint = String(repeating: "a", count: 64)
        let protocolPublicKey = Data(repeating: 0x33, count: 1184)
        let protocolFingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
        let now = Date()

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()

        await KEMTrustStore.shared.upsert(
            deviceId: peerId,
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwingMLDSA.wireId, publicKey: oldKEM)]
        )
        await ProtocolIdentityTrustStore.shared.upsert(deviceId: peerId, fingerprints: [oldFingerprint])

        try await P2PConnectionManager.instance.clearTrustMaterialForForgottenDevice(deviceIds: [peerId])

        let keysAfterForget = await KEMTrustStore.shared.kemPublicKeys(forAny: [peerId])
        let fingerprintsAfterForget = await ProtocolIdentityTrustStore.shared.trustedFingerprints(forAny: [peerId])
        XCTAssertTrue(keysAfterForget.isEmpty)
        XCTAssertTrue(fingerprintsAfterForget.isEmpty)

        let payload = AppMessage.SignedKEMRefreshPayload(
            deviceId: peerId,
            aliases: [peerId, "bonjour:forgotten-refresh-peer@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: protocolFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1216)
                )
            ],
            keyId: "skr-1-after-full-forget",
            generation: 8,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: Data(repeating: 0x44, count: 24),
            requestHashHex: String(repeating: "b", count: 64),
            signature: Data(repeating: 0x99, count: 64)
        )
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-test-requester",
            targetDeviceId: peerId,
            requesterProtocolIdentityFingerprint: protocolFingerprint,
            targetProtocolIdentityFingerprint: protocolFingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            nonce: payload.requestNonce
        )

        do {
            try await KEMTrustStore.shared.upsertSignedKEMRefresh(
                deviceIds: [peerId],
                payload: payload,
                request: request,
                pinnedProtocolFingerprints: [],
                minimumGeneration: nil
            )
            XCTFail("Full forget must not allow SKR-1 import without pinned protocol identity")
        } catch {
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .missingPinnedProtocolIdentity)
        }

        let keysAfterRejectedImport = await KEMTrustStore.shared.kemPublicKeys(forAny: [peerId])
        let evidenceAfterRejectedImport = await KEMTrustStore.shared.signedRefreshEvidence(forAny: [peerId])
        XCTAssertTrue(keysAfterRejectedImport.isEmpty)
        XCTAssertNil(evidenceAfterRejectedImport)

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()
    }

    func testRepairP2PTrustClearsOnlyKEMAndPreservesPinnedProtocolIdentity() async throws {
        let peerId = "id:repair-peer"
        let key = Data(repeating: 0xA1, count: 1_216)
        let fingerprint = String(repeating: "b", count: 64)
        let kemKeys = [KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwing.wireId, publicKey: key)]

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()

        await KEMTrustStore.shared.upsert(deviceId: peerId, kemPublicKeys: kemKeys)
        await ProtocolIdentityTrustStore.shared.upsert(deviceId: peerId, fingerprints: [fingerprint])

        await P2PConnectionManager.instance.repairP2PTrustForTrustedDevice(deviceIds: [peerId])

        let clearedKEMKeys = await KEMTrustStore.shared.kemPublicKeys(forAny: [peerId])
        let preservedFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(forAny: [peerId])
        XCTAssertTrue(clearedKEMKeys.isEmpty)
        XCTAssertEqual(preservedFingerprints, [fingerprint])

        await KEMTrustStore.shared.clearForTesting()
        await ProtocolIdentityTrustStore.shared.clearForTesting()
    }

    func testStrictPQCPreflightSurfacesMissingPinnedIdentityRequiresOOB() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("missing_pinned_identity_requires_oob"))
        XCTAssertTrue(source.contains("short_authentication_string"))
        XCTAssertTrue(source.contains("双端显示同一设备确认码"))
    }

    func testStrictPQCUsesPIB1BeforeSKR1WhenProtocolIdentityNeedsOOB() throws {
        let managerSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let policySource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager+StrictPQCTrustPolicy.swift"
        )
        let source = managerSource + "\n" + policySource

        XCTAssertTrue(source.contains("attemptOOBProtocolIdentityBinding"))
        XCTAssertTrue(source.contains("AppMessage.protocolIdentityBindingRequest"))
        XCTAssertTrue(source.contains("shortAuthenticationCode"))
        XCTAssertTrue(source.contains("installOOBProtocolIdentityBinding"))
        XCTAssertTrue(source.contains("PIB-1 -> SKR-1 recovery completed"))
        XCTAssertTrue(source.contains("requester_protocol_identity_not_pinned"))
        XCTAssertTrue(source.contains("signedRefreshFailureReason = Self.smokeSanitize(error.localizedDescription)"))
        XCTAssertFalse(source.contains("signedRefreshFailureReason = \"preflight-kem-refresh-failed\""))
        XCTAssertFalse(source.contains("policyAllowClassicFallback: true"))
    }

    func testTrustedPeerKEMRequiresStableProtocolIdentityCandidate() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func trustedPeerKEM(for device: DiscoveredDevice)"))
        let end = try XCTUnwrap(source.range(of: "private func peerKEMLookupCandidates", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("guard let stablePeerId = stableProtocolIdentityCandidate(from: candidates)"))
        XCTAssertTrue(body.contains("missing stable protocol identity"))
        XCTAssertTrue(body.contains("refusing endpoint alias target"))
        XCTAssertTrue(body.contains("return nil"))
        XCTAssertTrue(body.contains("return (stablePeerId, keys)"))
        XCTAssertFalse(body.contains("?? candidates.first ?? device.id"))
    }

    func testStableProtocolIdentityCandidateResolvesEndpointAliasesBeforeTrustMaterial() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(
            source.range(of: "private func stableProtocolIdentityCandidate(from candidates: [String])"))
        let end = try XCTUnwrap(
            source.range(
                of: "private func strictInboundHandshakeTrustContext",
                range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("PeerIdentityAliasResolver.persistentDeviceId(from: normalized)"))
        XCTAssertTrue(body.contains("peerAliasToCanonicalDeviceId[normalized]"))
        XCTAssertTrue(body.contains("TrustedDeviceStore.shared.uniqueCanonicalTrustedDeviceId(for: normalized)"))
        XCTAssertTrue(body.contains("lastKnownDevices[normalized]"))
        XCTAssertTrue(body.contains("PeerIdentityAliasResolver.aliasKeys(for: knownDevice)"))
        XCTAssertTrue(body.contains("discoveryManager.discoveredDevices.first"))
        XCTAssertTrue(body.contains("visited.insert(normalized).inserted"))
        XCTAssertFalse(body.contains("return candidates.first"))

        let connectStart = try XCTUnwrap(
            source.range(of: "public func connect(to device: DiscoveredDevice) async throws"))
        let connectEnd = try XCTUnwrap(
            source.range(
                of: "public func disconnect(from device: DiscoveredDevice) async -> Bool",
                range: connectStart.lowerBound..<source.endIndex))
        let connectBody = String(source[connectStart.lowerBound..<connectEnd.lowerBound])
        XCTAssertFalse(connectBody.contains("let stableProtocolPeerId = stableProtocolIdentityCandidate("))
        XCTAssertTrue(
            connectBody.contains(
                "primaryPeerId: preferredTrustedPeerId ?? resolvedTargetDevice.id"
            )
        )
        XCTAssertFalse(connectBody.contains("trustHint: shouldTreatTargetAsTrusted"))

        let canonicalizedStart = try XCTUnwrap(
            source.range(of: "private func canonicalizedDevice(")
        )
        let canonicalizedEnd = try XCTUnwrap(
            source.range(
                of: "private func parseBonjourPeerIdentifier(",
                range: canonicalizedStart.lowerBound..<source.endIndex
            )
        )
        let canonicalizedBody = String(
            source[canonicalizedStart.lowerBound..<canonicalizedEnd.lowerBound]
        )
        XCTAssertTrue(
            canonicalizedBody.contains("currentSessionHasExactActiveAuthority(")
        )
        XCTAssertTrue(canonicalizedBody.contains("isTrusted: effectiveIsTrusted"))
        XCTAssertFalse(canonicalizedBody.contains("isTrusted: device.isTrusted"))
        XCTAssertFalse(canonicalizedBody.contains("let effectiveIsTrusted = device.isTrusted"))
        XCTAssertFalse(canonicalizedBody.contains("TrustedDeviceStore.shared.isTrusted"))
    }

    func testStrictInboundHandshakeUsesMessageASOAStableIdentityCandidates() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let helperStart = try XCTUnwrap(
            source.range(of: "private func stableProtocolIdentityCandidates(from messageA: HandshakeMessageA?)"))
        let helperEnd = try XCTUnwrap(
            source.range(
                of: "private func strictInboundHandshakeTrustContext",
                range: helperStart.lowerBound..<source.endIndex))
        let helperBody = String(source[helperStart.lowerBound..<helperEnd.lowerBound])

        XCTAssertTrue(helperBody.contains("messageA.soaExtension"))
        XCTAssertTrue(helperBody.contains("soa.initiatorPeerId"))
        XCTAssertTrue(helperBody.contains("soaPeerIdBytes(for: normalizedStablePeerId)"))
        XCTAssertTrue(helperBody.contains("TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: fingerprint)"))
        XCTAssertTrue(helperBody.contains("ProtocolIdentityTrustStore.shared.deviceIds(containingFingerprint: fingerprint)"))
        XCTAssertTrue(helperBody.contains("activeAuthoritySnapshot()"))
        XCTAssertTrue(helperBody.contains("return []"))
        XCTAssertFalse(helperBody.contains("TrustedDeviceStore.shared.trustedDevices"))
        XCTAssertTrue(helperBody.contains("PeerIdentityAliasResolver.aliasKeys(for: device)"))
        XCTAssertTrue(helperBody.contains("lastAcceptedPairingIdentityDeviceIdByPeerId"))

        let trustStart = try XCTUnwrap(
            source.range(
                of: "private func strictInboundHandshakeTrustContext",
                range: helperEnd.lowerBound..<source.endIndex))
        let trustEnd = try XCTUnwrap(
            source.range(
                of: "private func preferredStrictPQCHandshakeTargetSuite",
                range: trustStart.lowerBound..<source.endIndex))
        let trustBody = String(source[trustStart.lowerBound..<trustEnd.lowerBound])

        XCTAssertTrue(trustBody.contains("messageA: HandshakeMessageA? = nil"))
        XCTAssertTrue(trustBody.contains("let messageAStableCandidates = await stableProtocolIdentityCandidates(from: messageA)"))
        XCTAssertTrue(trustBody.contains("reason=ambiguous_message_a_soa_identity"))
        XCTAssertTrue(trustBody.contains("let candidates = messageAStableCandidates + [peerId, runtimePeerId, presentationPeerId, canonicalPeerId]"))
        XCTAssertTrue(trustBody.contains("requirePinnedProtocolIdentity: true"))
        XCTAssertTrue(trustBody.contains("resolved stable peer from MessageA SOA"))

        let inboundStart = try XCTUnwrap(
            source.range(of: "private func ensureInboundHandshakeDriverIfNeeded("))
        let inboundEnd = try XCTUnwrap(
            source.range(of: "private func processHandshakeFrame(", range: inboundStart.lowerBound..<source.endIndex))
        let inboundBody = String(source[inboundStart.lowerBound..<inboundEnd.lowerBound])
        XCTAssertTrue(inboundBody.contains("stage: \"inbound-handshake\""))
        XCTAssertTrue(inboundBody.contains("messageA: messageA"))

        let rekeyStart = try XCTUnwrap(
            source.range(of: "private func ensureInboundRekeyDriverIfNeeded("))
        let rekeyEnd = try XCTUnwrap(
            source.range(of: "private func isLikelyHandshakeControlPacket", range: rekeyStart.lowerBound..<source.endIndex))
        let rekeyBody = String(source[rekeyStart.lowerBound..<rekeyEnd.lowerBound])
        XCTAssertTrue(rekeyBody.contains("stage: \"inbound-rekey\""))
        XCTAssertTrue(rekeyBody.contains("messageA: messageA"))
    }

    func testStrictPQCTrustProviderDoesNotUseEndpointAliasesAsPinMaterial() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private struct P2PStoredHandshakeTrustProvider"))
        let end = try XCTUnwrap(
            source.range(
                of: "/// P2P 连接管理器",
                range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("!PeerIdentityAliasResolver.isEndpointAlias(trimmed)"))
        XCTAssertTrue(body.contains("where !PeerIdentityAliasResolver.isEndpointAlias(alias)"))
        XCTAssertTrue(body.contains("requirePinnedProtocolIdentity"))
    }

    func testPIB1RequestRequiresStableProtocolIdentityTarget() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func attemptOOBProtocolIdentityBinding("))
        let end = try XCTUnwrap(source.range(of: "private func localProtocolIdentityProofForProtocolBinding", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("guard let targetProtocolDeviceId = stableProtocolIdentityCandidate(from: candidates)"))
        XCTAssertTrue(body.contains("missing stable protocol identity target"))
        XCTAssertTrue(body.contains("refusing endpoint alias target"))
        XCTAssertTrue(body.contains("targetDeviceId: targetProtocolDeviceId"))
        XCTAssertFalse(body.contains("targetDeviceId: candidates.first ?? device.id"))
    }

    func testPIB1ImporterUsesExistingProtocolIdentityPinAfterVerifiedBinding() {
        let fingerprint = String(repeating: "a", count: 64)

        XCTAssertEqual(
            P2PConnectionManager.protocolIdentityBindingStoredPolicyAction(
                pairingPolicyByPeerId: [:],
                policyCandidates: ["id:mac"],
                trustedProtocolFingerprints: [fingerprint],
                payloadFingerprint: fingerprint,
                hasActiveDurableTrust: true
            ),
            .approve(operatorLabel: "stored-protocol-identity")
        )
        XCTAssertEqual(
            P2PConnectionManager.protocolIdentityBindingStoredPolicyAction(
                pairingPolicyByPeerId: ["id:mac": P2PConnectionManager.PairingTrustDecision.reject.rawValue],
                policyCandidates: ["id:mac"],
                trustedProtocolFingerprints: [],
                payloadFingerprint: fingerprint,
                hasActiveDurableTrust: false
            ),
            .reject
        )
        XCTAssertNil(
            P2PConnectionManager.protocolIdentityBindingStoredPolicyAction(
                pairingPolicyByPeerId: ["id:other": P2PConnectionManager.PairingTrustDecision.alwaysAllow.rawValue],
                policyCandidates: ["id:mac"],
                trustedProtocolFingerprints: [],
                payloadFingerprint: fingerprint,
                hasActiveDurableTrust: false
            )
        )
        XCTAssertNil(
            P2PConnectionManager.protocolIdentityBindingStoredPolicyAction(
                pairingPolicyByPeerId: ["id:mac": P2PConnectionManager.PairingTrustDecision.alwaysAllow.rawValue],
                policyCandidates: ["id:mac"],
                trustedProtocolFingerprints: [],
                payloadFingerprint: fingerprint,
                hasActiveDurableTrust: false
            )
        )
        XCTAssertNil(
            P2PConnectionManager.protocolIdentityBindingStoredPolicyAction(
                pairingPolicyByPeerId: [:],
                policyCandidates: ["id:mac"],
                trustedProtocolFingerprints: [fingerprint],
                payloadFingerprint: fingerprint,
                hasActiveDurableTrust: false
            ),
            "A stale protocol fingerprint must not authorize a revoked or non-durable peer."
        )
    }

    func testCloudMetadataAloneCannotAuthorizePairingIdentityBootstrap() throws {
        let protocolPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let payload = AppMessage.PairingIdentityExchangePayload(
            deviceId: "id:metadata-only-peer",
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: Data(repeating: 0x41, count: 1_216)
                )
            ],
            protocolIdentityPublicKeys: [
                .init(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                    publicKey: protocolPublicKey
                )
            ]
        )

        XCTAssertThrowsError(
            try AuthenticatedPairingIdentityAuthorityValidator.issue(
                payload: payload,
                sessionBinding: nil,
                sessionDeviceIds: [payload.deviceId],
                operatorApproval: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? PairingIdentityAuthorityValidationError,
                .missingSessionAuthority
            )
        }
    }

    func testPairingIdentityBootstrapRequiresExactAuthenticatedProtocolAuthority() throws {
        let authenticatedPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let authenticatedKeyInfo = AppMessage.ProtocolIdentityPublicKeyInfo(
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            publicKey: authenticatedPublicKey
        )
        let authenticatedFingerprint = try XCTUnwrap(
            authenticatedKeyInfo.authoritativeFingerprint
        )
        let untrustedPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let kemPublicKey = Data(repeating: 0x51, count: 1_216)
        let deviceId = "id:11111111-2222-4333-8444-555555555555"
        let mismatchedPayload = AppMessage.PairingIdentityExchangePayload(
            deviceId: deviceId,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: kemPublicKey
                )
            ],
            protocolIdentityPublicKeys: [
                .init(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                    publicKey: untrustedPublicKey
                )
            ]
        )
        let sessionBinding = AuthenticatedHandshakePeerBinding(
            authority: AuthenticatedRemoteAuthority(
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                protocolPublicKeyFingerprint: authenticatedFingerprint,
                protocolPublicKeyBytes: authenticatedPublicKey
            ),
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: deviceId)
        )

        XCTAssertThrowsError(
            try AuthenticatedPairingIdentityAuthorityValidator.issue(
                payload: mismatchedPayload,
                sessionBinding: sessionBinding,
                sessionDeviceIds: [deviceId],
                operatorApproval: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? PairingIdentityAuthorityValidationError,
                .payloadAuthorityMismatch
            )
        }

        let validPayload = AppMessage.PairingIdentityExchangePayload(
            deviceId: "id:pinned-bootstrap-peer",
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: kemPublicKey
                )
            ],
            protocolIdentityPublicKeys: [authenticatedKeyInfo]
        )
        let validBinding = AuthenticatedHandshakePeerBinding(
            authority: sessionBinding.authority,
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(
                from: validPayload.deviceId
            )
        )
        let authority = try AuthenticatedPairingIdentityAuthorityValidator.issue(
            payload: validPayload,
            sessionBinding: validBinding,
            sessionDeviceIds: [validPayload.deviceId],
            operatorApproval: nil
        )
        XCTAssertEqual(authority.protocolPublicKey, authenticatedPublicKey)
        XCTAssertEqual(authority.protocolPublicKeyFingerprint, authenticatedFingerprint)
    }

    func testAllowOnceNeverPersistsPairingPolicy() throws {
        let current = [
            "id:existing-peer": P2PConnectionManager.PairingTrustDecision.reject.rawValue
        ]
        var persistCallCount = 0

        let result = try P2PConnectionManager.testOnlyPersistedPairingPolicyCandidate(
            current: current,
            peerId: "id:one-time-peer",
            decision: .allowOnce,
            persist: { _ in persistCallCount += 1 }
        )

        XCTAssertEqual(result, current)
        XCTAssertEqual(persistCallCount, 0)
        XCTAssertNil(
            P2PConnectionManager.pairingPolicyValueToPersist(for: .allowOnce)
        )
        XCTAssertNil(
            P2PConnectionManager.pairingPolicyValueToPersist(for: .timedOut)
        )
    }

    func testPairingPolicySaveFailureDoesNotPublishCandidate() {
        enum InjectedPersistenceFailure: Error {
            case save
        }

        let current = [
            "id:existing-peer": P2PConnectionManager.PairingTrustDecision.reject.rawValue
        ]
        var attemptedCandidate: [String: String]?

        XCTAssertThrowsError(
            try P2PConnectionManager.testOnlyPersistedPairingPolicyCandidate(
                current: current,
                peerId: "id:new-peer",
                decision: .alwaysAllow,
                persist: { candidate in
                    attemptedCandidate = candidate
                    throw InjectedPersistenceFailure.save
                }
            )
        )

        XCTAssertEqual(
            attemptedCandidate?["id:new-peer"],
            P2PConnectionManager.PairingTrustDecision.alwaysAllow.rawValue
        )
        XCTAssertEqual(
            current,
            ["id:existing-peer": P2PConnectionManager.PairingTrustDecision.reject.rawValue]
        )
    }

    func testPIB1PolicyCandidatesIncludeDevicePayloadAliasesWithoutDuplicates() {
        let payload = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: UUID(),
            deviceId: "id:payload-device",
            aliases: ["bonjour:Bill-iPad@local.", "id:mac"],
            protocolSigningAlgorithm: "ml-dsa-65",
            protocolIdentityPublicKey: Data([1, 2, 3]),
            protocolIdentityFingerprint: String(repeating: "b", count: 64),
            expiresAt: Date().addingTimeInterval(60),
            requestNonce: Data([4, 5, 6]),
            signature: Data([7, 8, 9])
        )
        let device = DiscoveredDevice(
            id: "host:10.0.0.2",
            name: "Bill iPad",
            modelName: "iPad",
            platform: .iPadOS,
            osVersion: "26.5",
            ipAddress: "10.0.0.2"
        )

        let policyCandidates = P2PConnectionManager.protocolIdentityBindingPolicyCandidates(
            for: device,
            candidates: [" id:mac ", "id:mac"],
            payload: payload
        )

        XCTAssertEqual(policyCandidates.first, "id:mac")
        XCTAssertTrue(policyCandidates.contains("host:10.0.0.2"))
        XCTAssertTrue(policyCandidates.contains("id:payload-device"))
        XCTAssertTrue(policyCandidates.contains("bonjour:Bill-iPad@local."))
        XCTAssertEqual(policyCandidates.filter { $0 == "id:mac" }.count, 1)
    }

    func testPIB1ImporterStoredPolicyPathIsNotSmokeFallback() throws {
        let managerSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let policySource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager+StrictPQCTrustPolicy.swift"
        )
        let source = managerSource + "\n" + policySource

        XCTAssertTrue(source.contains("protocolIdentityBindingStoredPolicyAction"))
        XCTAssertTrue(source.contains("ProtocolIdentityTrustStore.shared"))
        XCTAssertTrue(source.contains("TrustedDeviceStore.shared.currentPathFingerprints"))
        XCTAssertTrue(source.contains("operator=\\(operatorLabel)"))
        XCTAssertTrue(source.contains("signedProtocolIdentityBindingFinalAck"))
        XCTAssertTrue(source.contains("final acknowledgement verified and pinned"))
        XCTAssertFalse(source.contains("clearExisting: false"))
        XCTAssertTrue(source.contains("stored-policy"))
        XCTAssertTrue(source.contains("stored-protocol-identity"))
        XCTAssertFalse(source.contains("return .approve(operatorLabel: \"stored-policy\")"))
        XCTAssertFalse(source.contains("SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"))
        XCTAssertFalse(source.contains("operator=smoke-auto-approve"))
    }

    func testSKR1RefreshAcceptsProvenanceBoundBonjourAsDirectLANEndpoint() throws {
        let managerSource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let endpointPolicySource = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionEndpointPolicy.swift"
        )
        let source = managerSource + "\n" + endpointPolicySource
        let skrStart = try XCTUnwrap(managerSource.range(of: "private func attemptSignedLANKEMRefresh("))
        let requestLine = try XCTUnwrap(managerSource.range(of: "let requestLine =", range: skrStart.lowerBound..<managerSource.endIndex))
        let skrBody = String(managerSource[skrStart.lowerBound..<requestLine.lowerBound])

        XCTAssertTrue(skrBody.contains("let routeCandidates = connectionEndpointCandidates(for: device)"))
        XCTAssertFalse(skrBody.contains("preferDirectHostPort"))
        XCTAssertTrue(skrBody.contains("let directEndpoints = routeCandidates.filter"))
        XCTAssertTrue(skrBody.contains("Self.signedLANRefreshEndpointClass($0) == \"direct-host\""))
        XCTAssertTrue(skrBody.contains("let directHostCandidate = !directEndpoints.isEmpty"))
        XCTAssertTrue(skrBody.contains("let bonjourServiceEndpoints = routeCandidates.filter"))
        XCTAssertTrue(skrBody.contains("Self.signedLANRefreshEndpointClass($0) == \"bonjour-service\""))
        XCTAssertTrue(skrBody.contains("let endpoints = directEndpoints + bonjourServiceEndpoints"))
        XCTAssertTrue(skrBody.contains("let directLANCandidate = !endpoints.isEmpty"))
        XCTAssertTrue(skrBody.contains("guard directLANCandidate else"))
        XCTAssertTrue(skrBody.contains("missing provenance-bound direct LAN endpoint candidate"))
        XCTAssertFalse(skrBody.contains("missing direct LAN endpoint candidate"))
        XCTAssertTrue(skrBody.contains("let bonjourServiceCandidateCount = bonjourServiceEndpoints.count"))
        XCTAssertTrue(source.contains("classicFallbackSuppressed=1"))
        XCTAssertTrue(source.contains("bonjourServiceCandidates=\\(bonjourServiceCandidateCount)"))
        XCTAssertTrue(source.contains("bootstrap control connection failed:"))
        XCTAssertFalse(skrBody.contains("establishReadyConnectionWithMetrics(to: routeCandidates"))
        XCTAssertFalse(source.contains("preferDirectHostPort"))
        XCTAssertTrue(endpointPolicySource.contains("liveBonjourControlEndpoints"))
        XCTAssertTrue(endpointPolicySource.contains("discards the"))
        XCTAssertTrue(endpointPolicySource.contains("live result's interface"))
        XCTAssertTrue(
            endpointPolicySource.contains(
                "ApplePeerConnectivityPolicy.orderedEligibleClaimIndices("
            )
        )
        XCTAssertTrue(endpointPolicySource.contains("provenance: .liveBrowser"))
        XCTAssertTrue(source.contains("selectedEndpointClass=\\(selectedEndpointClass)"))
        XCTAssertTrue(source.contains("selectedEndpointDirect=\\(selectedEndpointDirect ? 1 : 0)"))
        XCTAssertTrue(source.contains("selectedEndpointDirectLAN=\\(selectedEndpointDirectLAN ? 1 : 0)"))
        XCTAssertTrue(source.contains("selectedEndpointPeerToPeer=\\(connectionResult.selectedEndpointPeerToPeer ? 1 : 0)"))
        XCTAssertTrue(source.contains("directHostCandidate=\\(directHostCandidate ? 1 : 0)"))
        XCTAssertTrue(source.contains("directLANCandidate=\\(directLANCandidate ? 1 : 0)"))
        XCTAssertTrue(source.contains("private static func signedLANRefreshEndpointClass"))
        XCTAssertTrue(source.contains("private func makeConnectionParameters(for endpoint: NWEndpoint) -> NWParameters"))
        XCTAssertTrue(source.contains("parameters.includePeerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)"))
        XCTAssertTrue(source.contains("private static func shouldIncludePeerToPeer(for endpoint: NWEndpoint) -> Bool"))
        XCTAssertTrue(source.contains("ConnectableAddressCanonicalizer.prefersPeerToPeer(for: String(describing: host))"))
    }

    func testPIB1ApprovalTimeoutIsBoundedAndConfigurableForSmoke() throws {
        let source = try [
            readRepositorySource(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
            ),
            readRepositorySource(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager+StrictPQCTrustPolicy.swift"
            )
        ].joined(separator: "\n")

        XCTAssertTrue(source.contains("SKYBRIDGE_PIB_APPROVAL_TIMEOUT_SECONDS"))
        XCTAssertTrue(source.contains("return min(max(value, 30), 300)"))
        XCTAssertTrue(source.contains("return 180"))
        XCTAssertTrue(source.contains("protocolIdentityBindingResponseTimeoutSeconds"))
        XCTAssertTrue(source.contains("Double(protocolIdentityBindingApprovalTimeoutSeconds() + 15)"))
        XCTAssertTrue(source.contains("responseTimeoutSeconds=\\(Int(responseTimeoutSeconds))"))
        XCTAssertTrue(source.contains("case timedOut"))
        XCTAssertTrue(source.contains("operator approval timed out for PIB-1 verification code"))
        XCTAssertTrue(source.contains("identity-oob>awaiting-approval"))
        XCTAssertTrue(source.contains("lifecycle=identity-oob>timeout"))
        XCTAssertTrue(source.contains("timeoutSeconds=\\(approvalTimeoutSeconds)"))
        XCTAssertTrue(source.contains("let policyCandidates = Self.protocolIdentityBindingPolicyCandidates"))
        XCTAssertEqual(
            source.components(separatedBy: "candidates: policyCandidates").count - 1,
            1,
            "PIB-1 candidate approval must not install a pin before the signed final acknowledgement."
        )
        XCTAssertFalse(source.contains("SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"))
    }

    func testPIB1StatusLinesRedactVerificationSecrets() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("protocolIdentityLogRedaction"))
        XCTAssertTrue(source.contains("code=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(source.contains("fingerprint=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(
            source.contains("verificationCode: verificationCode"),
            "The operator-facing pending approval state must keep the SAS even though logs redact it."
        )

        [
            "code=\\(code)",
            "code=\\(verificationCode)",
            "code=\\(context.verificationCode)",
            "fingerprint=\\(validated.protocolIdentityFingerprint)",
            "fingerprint=\\(payload.protocolIdentityFingerprint)",
            "fingerprint=\\(context.payload.protocolIdentityFingerprint)",
            "fingerprint=\\(context.requesterProtocolIdentityFingerprint)",
            "fingerprint=\\(requesterFingerprint)",
            "fingerprint=\\(authority.protocolPublicKeyFingerprint)",
            "PIB-1 protocol identity binding served: requester=\\(request.requesterDeviceId)",
            "PIB-1 protocol identity binding rejected: requester=\\(request.requesterDeviceId)",
            "PIB-1 requester protocol identity awaiting operator approval: requester=\\(stableRequesterId)",
            "deviceId=\\(payload.deviceId)"
        ].forEach { forbidden in
            XCTAssertFalse(
                source.contains(forbidden),
                "PIB-1 status/log lines must not persist raw protocol identity secrets: \(forbidden)"
            )
        }
    }

    func testSKR1InboundStatusLinesRedactRequestIdentifiersAndFailureReasons() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func makeInboundBootstrapControlResponse"))
        let end = try XCTUnwrap(
            source.range(
                of: "private func makeInboundSignedKEMRefreshPayload",
                range: start.lowerBound..<source.endIndex
            )
        )
        let reviewedStatusBuilder = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(reviewedStatusBuilder.contains("SKR-1 signed LAN KEM refresh served"))
        XCTAssertTrue(reviewedStatusBuilder.contains("SKR-1 signed LAN KEM refresh rejected"))
        XCTAssertTrue(reviewedStatusBuilder.contains("let reasonCode = Self.signedKEMRefreshFailureCode(for: error)"))
        XCTAssertTrue(reviewedStatusBuilder.contains("reasonCode: reasonCode"))
        XCTAssertTrue(reviewedStatusBuilder.contains("reason: reasonCode"))
        XCTAssertFalse(reviewedStatusBuilder.contains("reason: error.localizedDescription"))
        XCTAssertTrue(reviewedStatusBuilder.contains("reason=%@ responderLatencyMs"))
        XCTAssertTrue(reviewedStatusBuilder.contains(
            "let requestHashHex = request.canonicalRequestHashHexIfRepresentable"
        ))
        XCTAssertTrue(reviewedStatusBuilder.contains("requestHashHex: requestHashHex"))
        XCTAssertTrue(reviewedStatusBuilder.contains("requesterDeviceId: request.requesterDeviceId"))
        XCTAssertTrue(reviewedStatusBuilder.contains("targetDeviceId: request.targetDeviceId"))
        XCTAssertTrue(reviewedStatusBuilder.contains("""
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    requestReference,
                    payloadReference,
                    Self.protocolIdentityLogRedaction,
"""))
        XCTAssertTrue(reviewedStatusBuilder.contains("""
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    failure.reasonCode,
                    Self.protocolIdentityLogRedaction,
"""))

        [
            "payload.keyId,",
            "\n                    error.localizedDescription,\n"
        ].forEach { forbidden in
            XCTAssertFalse(
                reviewedStatusBuilder.contains(forbidden),
                "SKR-1 inbound status/failure paths must not expose raw request identifiers or local error details: \(forbidden)"
            )
        }
    }

    func testSKR1OutboundFailurePreservesOnlyAValidatedDiagnosticReasonCode() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("reasonCode: failure.reasonCode"))
        XCTAssertTrue(
            source.contains(
                "summary += \" remote_reason_code=\\(reasonCode)\""
            )
        )
        XCTAssertTrue(source.contains("value.utf8.count <= 64"))
        XCTAssertTrue(
            source.contains("(97...122).contains($0)")
        )

        let validError = P2PConnectionManager.signedLANRefreshFailure(
            "remote detail remains private",
            reasonCode: "LOCAL_PQC_KEM_UNAVAILABLE"
        )
        XCTAssertEqual(
            validError.userInfo["SkyBridgeSignedLANRefreshReasonCode"] as? String,
            "local_pqc_kem_unavailable"
        )

        let invalidError = P2PConnectionManager.signedLANRefreshFailure(
            "remote detail remains private",
            reasonCode: "bad\ninjected=value"
        )
        XCTAssertNil(
            invalidError.userInfo["SkyBridgeSignedLANRefreshReasonCode"]
        )

        let nonASCIIError = P2PConnectionManager.signedLANRefreshFailure(
            "remote detail remains private",
            reasonCode: "local_pqc_不可用"
        )
        XCTAssertNil(
            nonASCIIError.userInfo["SkyBridgeSignedLANRefreshReasonCode"]
        )
    }

    func testPairingIdentityExchangeDiagnosticsRedactStableIdentifiersAndErrors() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "public func resolvePairingTrustRequest"))
        let end = try XCTUnwrap(
            source.range(
                of: "public func waitForPairingIdentityExchangeActivity",
                range: start.lowerBound..<source.endIndex
            )
        )
        let reviewedPairingDiagnostics = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(source.contains("diagnosticErrorSummary(_ error: Error)"))
        XCTAssertTrue(source.contains("error_domain=\\(nsError.domain) code=\\(nsError.code)"))
        XCTAssertTrue(reviewedPairingDiagnostics.contains("peer=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(reviewedPairingDiagnostics.contains("declaredDeviceId=\\(Self.protocolIdentityLogRedaction)"))

        [
            "Pairing/trust request rejected: peer=\\(peerId)",
            "Pairing/trust request timed out: peer=\\(peerId)",
            "Pairing/trust request auto-rejected: peer=\\(peerId)",
            "UI prompt already pending; ignoring duplicate. peer=\\(peerId)",
            "忽略无效 pairingIdentityExchange: peer=\\(runtimePeerId)",
            "已保存对端 KEM 公钥：peer=\\(peerId) declaredDeviceId=\\(declaredDeviceId)",
            "已加入受信任设备：\\(device.name) peerId=\\(peerId)",
            "pairingIdentityExchange replied to peer=\\(peerId)",
            "pairingIdentityExchange reply failed (ignored): \\(error.localizedDescription)",
            "cleared stale rekey marker before pairingIdentityExchange: peer=\\(deviceId)",
            "pairingIdentityExchange delayed during active rekey: peer=\\(deviceId)",
            "pairingIdentityExchange sent: peer=\\(deviceId)"
        ].forEach { forbidden in
            XCTAssertFalse(
                reviewedPairingDiagnostics.contains(forbidden),
                "pairingIdentityExchange diagnostics must not expose stable identifiers or raw local errors: \(forbidden)"
            )
        }

        XCTAssertTrue(
            reviewedPairingDiagnostics.contains("deviceId: localId"),
            "Protocol payloads must keep the raw local device id; redaction is limited to diagnostics."
        )
        XCTAssertTrue(
            reviewedPairingDiagnostics.contains("AuthorityBoundPairingIdentityPersistence"),
            "Pairing persistence must pass through the authority-bound transaction."
        )
    }

    func testP2PDiagnosticTraceRedactsRuntimeIdentifiersAndEndpointDetails() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let inboundStart = try XCTUnwrap(source.range(of: "private func handleIncomingConnection"))
        let inboundEnd = try XCTUnwrap(
            source.range(
                of: "private func isLikelyHandshakeControlPacket",
                range: inboundStart.lowerBound..<source.endIndex
            )
        )
        let inboundDiagnostics = String(source[inboundStart.lowerBound..<inboundEnd.lowerBound])

        XCTAssertTrue(source.contains("diagnosticConnectionState(_ state: NWConnection.State)"))
        XCTAssertTrue(source.contains("diagnosticHandshakeFailureCode(_ reason: HandshakeFailureReason)"))
        XCTAssertTrue(inboundDiagnostics.contains("p2p-inbound handle-start peer=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(inboundDiagnostics.contains("p2p-inbound strict-trust-ready peer=\\(Self.protocolIdentityLogRedaction) stable=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(inboundDiagnostics.contains("p2p-inbound handshake-failed peer=\\(Self.protocolIdentityLogRedaction) reason=\\(Self.diagnosticHandshakeFailureCode(reason))"))
        XCTAssertTrue(inboundDiagnostics.contains("error=\\(Self.diagnosticErrorSummary(error))"))

        [
            "Self.smokeSanitize(peerId)",
            "Self.smokeSanitize(canonicalPeerId)",
            "Self.smokeSanitize(context.stablePeerId)",
            "peer=\\(peerId)",
            "处理入站连接: \\(peerId)",
            "等待来自 \\(canonicalPeerId)",
            "from \\(peerId)",
            "header=0x\\(headerHex)",
            "String(describing: reason)",
            "error=\\(Self.smokeSanitize(error.localizedDescription))",
            "error=\\(Self.smokeSanitize(error2.localizedDescription))"
        ].forEach { forbidden in
            XCTAssertFalse(
                inboundDiagnostics.contains(forbidden),
                "P2P inbound trace/log diagnostics must redact runtime identifiers and raw local details: \(forbidden)"
            )
        }

        let endpointStart = try XCTUnwrap(source.range(of: "private func establishReadyConnectionWithMetrics"))
        let endpointEnd = try XCTUnwrap(
            source.range(
                of: "private static func attemptDurationJitterMs",
                range: endpointStart.lowerBound..<source.endIndex
            )
        )
        let endpointDiagnostics = String(source[endpointStart.lowerBound..<endpointEnd.lowerBound])
        XCTAssertTrue(endpointDiagnostics.contains("endpoint=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertFalse(endpointDiagnostics.contains("endpointDescription"))
        XCTAssertFalse(endpointDiagnostics.contains("String(describing: endpoint)"))
        XCTAssertFalse(endpointDiagnostics.contains("\\(device.name) endpoint="))

        let stateStart = try XCTUnwrap(source.range(of: "private func handleConnectionStateChange"))
        let stateEnd = try XCTUnwrap(
            source.range(
                of: "private func scheduleReconnectIfNeeded",
                range: stateStart.lowerBound..<source.endIndex
            )
        )
        let stateDiagnostics = String(source[stateStart.lowerBound..<stateEnd.lowerBound])
        XCTAssertTrue(stateDiagnostics.contains("state=\\(Self.diagnosticConnectionState(state))"))
        XCTAssertFalse(stateDiagnostics.contains("String(describing: state)"))
        XCTAssertFalse(stateDiagnostics.contains("effectiveDevice.name"))
        XCTAssertFalse(stateDiagnostics.contains("runtimePeerId)) state="))
    }

    func testInboundConnectionRemainsProvisionalUntilFirstProtocolFrame() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        func slice(from start: String, to end: String) throws -> String {
            let startRange = try XCTUnwrap(source.range(of: start))
            let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
            return String(source[startRange.lowerBound..<endRange.lowerBound])
        }

        let inboundOwnerAndReceive = try slice(
            from: "private func startInboundControlSession(",
            to: "/// 开始从连接接收消息"
        )
        let outboundReceiveBody = try slice(
            from: "private func startReceivingOutboundFrames(",
            to: "private func promoteInboundConnectionForFirstFrame"
        )
        let promoteBody = try slice(
            from: "private func promoteInboundConnectionForFirstFrame",
            to: "private func handleControlReceiveFailure"
        )
        let receiveFailureBody = try slice(
            from: "private func handleControlReceiveFailure",
            to: "private func prepareProvisionalInboundHandshakeDriver"
        )
        let bootstrapControlBody = try slice(
            from: "private func handlePreHandshakeBootstrapControlMessage(",
            to: "private func makeInboundBootstrapControlResponse"
        )

        XCTAssertTrue(inboundOwnerAndReceive.contains("inboundControlSessionTasks[identifier]"))
        XCTAssertTrue(inboundOwnerAndReceive.contains("token: token"))
        XCTAssertTrue(
            inboundOwnerAndReceive.contains(
                "inboundControlSessionTasks[identifier]?.token == token"
            )
        )
        XCTAssertTrue(inboundOwnerAndReceive.contains("Self.inboundFramedReader(for: connection)"))
        XCTAssertTrue(inboundOwnerAndReceive.contains("beginProcessingProvisionalInboundConnection("))
        XCTAssertTrue(inboundOwnerAndReceive.contains("stage: .initialHandshake"))
        XCTAssertTrue(inboundOwnerAndReceive.contains("handlePreHandshakeBootstrapControlMessage("))
        XCTAssertTrue(inboundOwnerAndReceive.contains("over: connection"))
        XCTAssertTrue(inboundOwnerAndReceive.contains("p2p-inbound provisional-bootstrap-control-consumed"))
        XCTAssertTrue(inboundOwnerAndReceive.contains("ifOwnedBy: processingLease"))
        XCTAssertTrue(inboundOwnerAndReceive.contains("prepareProvisionalInboundHandshakeDriver("))
        XCTAssertTrue(inboundOwnerAndReceive.contains("hasActiveAuthenticatedSession("))
        XCTAssertTrue(inboundOwnerAndReceive.contains("reason: \"入站连接首帧不是有效握手协议帧\""))
        XCTAssertTrue(
            inboundOwnerAndReceive.contains("let payload = try await reader.receiveFrame()")
        )
        XCTAssertTrue(inboundOwnerAndReceive.contains("handleControlReceiveFailure("))
        XCTAssertFalse(inboundOwnerAndReceive.contains("startReceivingOutboundFrames("))
        XCTAssertFalse(outboundReceiveBody.contains("promoteInboundDevice"))
        XCTAssertFalse(outboundReceiveBody.contains("prepareProvisionalInboundHandshakeDriver("))
        XCTAssertFalse(outboundReceiveBody.contains("provisional-bootstrap-control-consumed"))
        XCTAssertTrue(promoteBody.contains("lastKnownDevices[canonicalPeerId] = canonicalDevice"))
        XCTAssertTrue(promoteBody.contains("connectionStatusByDeviceId[canonicalPeerId] = .connecting"))
        XCTAssertTrue(
            promoteBody.contains("let connectionLease = try installTrackedConnection("),
            "Inbound promotion must install a generation-aware lease before observers can mutate peer state."
        )
        XCTAssertTrue(promoteBody.contains("for: canonicalPeerId"))
        XCTAssertFalse(
            promoteBody.contains("connections[canonicalPeerId] = connection"),
            "Inbound promotion must not bypass generation-aware connection ownership."
        )
        let leaseInstall = try XCTUnwrap(
            promoteBody.range(of: "let connectionLease = try installTrackedConnection(")
        )
        let observerInstall = try XCTUnwrap(
            promoteBody.range(of: "installConnectionObservers(connectionLease, for: canonicalDevice)")
        )
        XCTAssertLessThan(
            leaseInstall.lowerBound,
            observerInstall.lowerBound,
            "Inbound observers must never be installed before the connection has an owned lease."
        )
        XCTAssertTrue(promoteBody.contains("guard await transport.setConnection("))
        XCTAssertTrue(promoteBody.contains("leaseSequence: connectionLease.sequence"))
        XCTAssertTrue(
            promoteBody.contains("connections.isCurrent(connectionLease, for: canonicalPeerId)")
        )
        XCTAssertTrue(promoteBody.contains("p2p-inbound promoted-active"))
        XCTAssertTrue(receiveFailureBody.contains("if !isTrackedConnection(connection)"))
        XCTAssertTrue(receiveFailureBody.contains("p2p-inbound provisional-closed"))
        XCTAssertTrue(bootstrapControlBody.contains("over provisionalConnection: NWConnection? = nil"))
        XCTAssertTrue(bootstrapControlBody.contains("allowsPreHandshakeBootstrapControlRouting("))
        XCTAssertTrue(bootstrapControlBody.contains("isProvisionalConnection: provisionalConnection != nil"))
        XCTAssertTrue(bootstrapControlBody.contains("hasHandshakeDriver: handshakeDrivers[peerId] != nil"))
        XCTAssertTrue(bootstrapControlBody.contains("hasSessionKeys: sessionKeys[peerId] != nil"))
        XCTAssertTrue(
            bootstrapControlBody.contains(
                "case .kemRefreshRequest, .protocolIdentityBindingRequest, .protocolIdentityBindingConfirm:"
            ),
            "Only the three authenticated bootstrap-control message families may coexist with an active session."
        )
        XCTAssertTrue(bootstrapControlBody.contains("provisionalConnection ?? connections[peerId]"))

        let provisionalGuardBody = try slice(
            from: "private func prepareProvisionalInboundHandshakeDriver",
            to: "private func looksLikeTLSRecordHeader"
        )
        XCTAssertTrue(provisionalGuardBody.contains("HandshakeMessageA.decode"))
        XCTAssertTrue(provisionalGuardBody.contains("!messageA.supportedSuites.isEmpty"))
        XCTAssertTrue(provisionalGuardBody.contains("ensureInboundRekeyDriverIfNeeded"))
        XCTAssertTrue(provisionalGuardBody.contains("ensureInboundHandshakeDriverIfNeeded"))
        XCTAssertTrue(provisionalGuardBody.contains("reason=invalid-first-frame"))
    }

    func testStrictPQCFailureStatusLinesRedactPeerIdentitySecrets() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let strictTrustStart = try XCTUnwrap(
            source.range(of: "private func strictInboundHandshakeTrustContext")
        )
        let strictTrustEnd = try XCTUnwrap(
            source.range(
                of: "private func preferredStrictPQCHandshakeTargetSuite",
                range: strictTrustStart.lowerBound..<source.endIndex
            )
        )
        let oobStart = try XCTUnwrap(
            source.range(of: "private func attemptOOBProtocolIdentityBinding(")
        )
        let oobEnd = try XCTUnwrap(
            source.range(
                of: "private func requestOOBProtocolIdentityApproval",
                range: oobStart.lowerBound..<source.endIndex
            )
        )
        let reviewedFailurePaths = String(source[strictTrustStart.lowerBound..<strictTrustEnd.lowerBound])
            + "\n"
            + String(source[oobStart.lowerBound..<oobEnd.lowerBound])

        XCTAssertTrue(reviewedFailurePaths.contains("reason=ambiguous_message_a_soa_identity"))
        XCTAssertTrue(reviewedFailurePaths.contains("reason=missing_stable_protocol_identity"))
        XCTAssertTrue(reviewedFailurePaths.contains("reason=missing_pinned_protocol_identity"))
        XCTAssertTrue(reviewedFailurePaths.contains("reasonCode=\\(failure.reasonCode) reason=redacted"))
        XCTAssertTrue(reviewedFailurePaths.contains("matchCount=\\(messageAStableCandidates.count)"))

        [
            "peer=\\(peerId)",
            "stablePeer=\\(stablePeerId)",
            "matches=\\(messageAStableCandidates.joined",
            "reason=\\(failure.reason)",
            "reason=\\(error.localizedDescription)"
        ].forEach { forbidden in
            XCTAssertFalse(
                reviewedFailurePaths.contains(forbidden),
                "Strict PQC/PIB failure status lines must not persist raw peer ids or remote reason text: \(forbidden)"
            )
        }
    }

    func testIOSBonjourDiscoveryDoesNotAcceptKEMFromTXT() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )

        let createStart = try XCTUnwrap(
            source.range(of: "private func createDevice(")
        )
        let createEnd = try XCTUnwrap(
            source.range(
                of: "private func isUnknownValue(",
                range: createStart.upperBound..<source.endIndex
            )
        )
        let createDeviceSlice = source[createStart.lowerBound..<createEnd.lowerBound]
        XCTAssertTrue(createDeviceSlice.contains("publicKey: nil"))
        XCTAssertFalse(createDeviceSlice.localizedCaseInsensitiveContains("KEMTrustStore"))
        XCTAssertFalse(createDeviceSlice.localizedCaseInsensitiveContains("PeerKEMBootstrapStore"))
        XCTAssertFalse(createDeviceSlice.localizedCaseInsensitiveContains("kemPublic"))
        XCTAssertFalse(createDeviceSlice.contains("KEMPublicKeyInfo"))
        XCTAssertTrue(createDeviceSlice.contains("let isTrusted = false"))
        XCTAssertFalse(
            createDeviceSlice.contains("TrustedDeviceStore.shared.isTrusted")
        )
        let extractionStart = try XCTUnwrap(
            source.range(of: "private func extractTXTRecord(")
        )
        let extractionEnd = try XCTUnwrap(
            source.range(
                of: "private func identityAliases",
                range: extractionStart.upperBound..<source.endIndex
            )
        )
        let extractionSlice = source[extractionStart.lowerBound..<extractionEnd.lowerBound]
        XCTAssertTrue(extractionSlice.contains("BonjourInteropProtocolContract.decodeAdvertisement("))
        XCTAssertTrue(extractionSlice.contains("let projection = decoded.discoveryProjection"))
        XCTAssertTrue(createDeviceSlice.contains("advertisement.skyBridgeProjection?.deviceId"))
        XCTAssertTrue(createDeviceSlice.contains("let advertisedCaps: [String] = []"))
        XCTAssertTrue(createDeviceSlice.contains("let portMap: [String: UInt16] = [:]"))
        XCTAssertFalse(extractionSlice.localizedCaseInsensitiveContains("kemPublic"))
        XCTAssertFalse(extractionSlice.localizedCaseInsensitiveContains("kemKeyDigest"))
        XCTAssertFalse(extractionSlice.localizedCaseInsensitiveContains("suiteWireId"))
    }

    func testIOSDiscoveryUIRequiresAuthenticatedSessionTrustProjection() throws {
        let discovery = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )
        let row = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/Dashboard/Components/DeviceRowView.swift"
        )
        let settings = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/SettingsView.swift"
        )

        let livenessStart = try XCTUnwrap(
            discovery.range(of: "public func setConnectionLiveness(")
        )
        let livenessEnd = try XCTUnwrap(
            discovery.range(
                of: "private func resolveBonjourServiceIPAddress(",
                range: livenessStart.upperBound..<discovery.endIndex
            )
        )
        let liveness = discovery[livenessStart.lowerBound..<livenessEnd.lowerBound]
        XCTAssertTrue(
            liveness.contains("DiscoveryConnectionLivenessProjectionPolicy.projection(")
        )
        XCTAssertTrue(liveness.contains("cached.isTrusted = projection.isTrusted"))
        XCTAssertFalse(liveness.contains("identityAliasToDeviceId"))
        XCTAssertFalse(liveness.contains("canonicalDiscoveredDevice"))
        XCTAssertTrue(row.contains("if device.isTrusted"))
        XCTAssertFalse(row.contains("trustedStore.isTrusted(deviceId: device.id)"))
        XCTAssertTrue(
            settings.contains(
                "discoveryManager.discoveredDevices.filter { !$0.isTrusted }"
            )
        )
    }

    func testIOSP2PUsesSharedExactFramedReaderBeforeBootstrapClassification() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let receiveStart = try XCTUnwrap(
            source.range(of: "private func handleIncomingConnection(")
        )
        let receiveEnd = try XCTUnwrap(
            source.range(
                of: "/// 开始从连接接收消息",
                range: receiveStart.upperBound..<source.endIndex
            )
        )
        let receive = String(source[receiveStart.lowerBound..<receiveEnd.lowerBound])
        let framedRead = try XCTUnwrap(
            receive.range(of: "let payload = try await reader.receiveFrame()")
        )
        let classification = try XCTUnwrap(
            receive.range(of: "let classification = await Task.detached")
        )

        XCTAssertLessThan(framedRead.lowerBound, classification.lowerBound)
        XCTAssertTrue(receive.contains("Self.inboundFramedReader(for: connection)"))
        XCTAssertFalse(receive.contains("minimumIncompleteLength: 4"))
    }

    func testIOSVersion2BonjourDecoderRejectsInjectedKEMMaterial() async throws {
        var txtRecord = NWTXTRecord()
        txtRecord["version"] = "2"
        txtRecord["deviceId"] = "id:malicious-mac"
        txtRecord["pubKeyFP"] = String(repeating: "a", count: 64)
        txtRecord["platform"] = "macos"
        txtRecord["hs_soa"] = "1"
        txtRecord["kemRefreshVersion"] = "1"
        txtRecord["kemKeyDigest"] = String(repeating: "c", count: 64)
        txtRecord["kemPublicKey"] = "malicious-kem-public-key"
        txtRecord["kemPublicKeys"] = "0x0001:malicious-kem-public-key"
        txtRecord["suiteWireId"] = "0x0001"
        txtRecord["publicKey"] = "malicious-public-key"

        await KEMTrustStore.shared.clearForTesting()
        XCTAssertThrowsError(
            try BonjourInteropProtocolContract.decodeAdvertisement(
                txtRecord.data,
                role: .control
            )
        ) { error in
            XCTAssertEqual(
                error as? BonjourInteropProtocolContract.AdvertisementError,
                .invalidVersion2FieldSet
            )
        }
        let trustedKeys = await KEMTrustStore.shared.kemPublicKeys(forAny: ["id:malicious-mac"])
        XCTAssertTrue(trustedKeys.isEmpty)

        await KEMTrustStore.shared.clearForTesting()
    }

    func testPIB1V3CandidatePhaseCannotPromptOrInstallTrust() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(
            source.range(of: "private func makeInboundSignedProtocolIdentityBindingPayload(")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "private func stageInboundRequesterProtocolIdentityApproval(",
                range: start.upperBound..<source.endIndex
            )
        )
        let candidatePhase = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(candidatePhase.contains("ProtocolIdentityBindingV3StateStore.shared.registerCandidate"))
        XCTAssertFalse(candidatePhase.contains("stageInboundRequesterProtocolIdentityApproval"))
        XCTAssertFalse(candidatePhase.contains("installInboundRequesterProtocolIdentityBinding"))
        XCTAssertFalse(candidatePhase.contains("installOOBProtocolIdentityBinding"))
    }

    func testPIB1V3ConfirmCallerConsumesOnlyAdmittedValidatedHash() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(
            source.range(of: "private func makeInboundSignedProtocolIdentityBindingFinalAck(")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "private static func inboundBootstrapDeviceIdCandidates(",
                range: start.upperBound..<source.endIndex
            )
        )
        let confirmPhase = String(source[start.lowerBound..<end.lowerBound])
        let admission = try XCTUnwrap(
            confirmPhase.range(
                of: "ProtocolIdentityBindingV3StateStore.shared.beginConfirm(confirm)"
            )
        )
        let beforeAdmission = confirmPhase[..<admission.lowerBound]

        XCTAssertFalse(beforeAdmission.contains("canonicalConfirmHashHex"))
        XCTAssertTrue(confirmPhase.contains("validatedConfirm = admittedConfirm.validatedConfirm"))
        XCTAssertTrue(confirmPhase.contains("confirmHashHex = admittedConfirm.confirmHashHex"))
        XCTAssertFalse(confirmPhase.contains("let validatedConfirm = try confirm.validatedForCandidate"))
    }

    func testPIB1V3RequesterPinsOnlyAfterVerifiedFinalAckOnNewConnection() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func attemptOOBProtocolIdentityBinding("))
        let end = try XCTUnwrap(
            source.range(
                of: "private func clearPendingPairingApprovalState(",
                range: start.upperBound..<source.endIndex
            )
        )
        let requesterFlow = String(source[start.lowerBound..<end.lowerBound])
        let releaseMarker = try XCTUnwrap(
            requesterFlow.range(of: "PIB-1 v3 deliberately releases the candidate connection")
        )
        let releaseCandidateConnection = try XCTUnwrap(
            requesterFlow.range(
                of: "connection.cancel()",
                range: releaseMarker.upperBound..<requesterFlow.endIndex
            )
        )
        let operatorApproval = try XCTUnwrap(requesterFlow.range(of: "requestOOBProtocolIdentityApproval"))
        let newConnection = try XCTUnwrap(requesterFlow.range(of: "let confirmConnectionResult"))
        let finalSignatureVerified = try XCTUnwrap(requesterFlow.range(of: "guard finalAckVerified else"))
        let pinInstall = try XCTUnwrap(requesterFlow.range(of: "installOOBProtocolIdentityBinding"))

        XCTAssertLessThan(releaseCandidateConnection.lowerBound, operatorApproval.lowerBound)
        XCTAssertLessThan(operatorApproval.lowerBound, newConnection.lowerBound)
        XCTAssertLessThan(newConnection.lowerBound, finalSignatureVerified.lowerBound)
        XCTAssertLessThan(finalSignatureVerified.lowerBound, pinInstall.lowerBound)
        XCTAssertTrue(requesterFlow.contains("confirmConnection !== connection"))
    }

}

@available(iOS 17.0, *)
@MainActor
final class ProtocolIdentityBindingV3Tests: XCTestCase {
    private typealias Transcript = (
        request: AppMessage.ProtocolIdentityBindingRequestPayload,
        candidate: AppMessage.SignedProtocolIdentityBindingPayload,
        requesterKey: Curve25519.Signing.PrivateKey,
        responderKey: Curve25519.Signing.PrivateKey,
        requesterFingerprint: String,
        responderFingerprint: String
    )

    private func fingerprint(for publicKey: Data) throws -> String {
        try XCTUnwrap(
            AppMessage.ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                publicKey: publicKey
            ).authoritativeFingerprint
        )
    }

    private func makeTranscript(
        transactionId: UUID = UUID(),
        requestVersion: Int = AppMessage.ProtocolIdentityBindingRequestPayload.currentVersion,
        requestedProtocolSigningAlgorithms: [String] = [
            ProtocolSigningAlgorithm.ed25519.rawValue
        ],
        requesterKey suppliedRequesterKey: Curve25519.Signing.PrivateKey? = nil,
        responderKey suppliedResponderKey: Curve25519.Signing.PrivateKey? = nil,
        now: Date = Date()
    ) throws -> Transcript {
        let requesterKey = suppliedRequesterKey ?? Curve25519.Signing.PrivateKey()
        let responderKey = suppliedResponderKey ?? Curve25519.Signing.PrivateKey()
        let requesterPublicKey = requesterKey.publicKey.rawRepresentation
        let responderPublicKey = responderKey.publicKey.rawRepresentation
        let requesterFingerprint = try fingerprint(for: requesterPublicKey)
        let responderFingerprint = try fingerprint(for: responderPublicKey)
        let nonce = Data(repeating: 0xA1, count: 24)
        let unsignedRequest = AppMessage.ProtocolIdentityBindingRequestPayload(
            version: requestVersion,
            transactionId: transactionId,
            requesterDeviceId: "requester-device",
            targetDeviceId: "responder-device",
            requestedProtocolSigningAlgorithms: requestedProtocolSigningAlgorithms,
            requesterProtocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            requesterProtocolIdentityPublicKey: requesterPublicKey,
            requesterProtocolIdentityFingerprint: requesterFingerprint,
            requesterSignature: Data(),
            nonce: nonce,
            sentAt: now
        )
        let requestSignature = try requesterKey.signature(for: unsignedRequest.canonicalPreimage)
        let request = AppMessage.ProtocolIdentityBindingRequestPayload(
            version: requestVersion,
            transactionId: transactionId,
            requesterDeviceId: unsignedRequest.requesterDeviceId,
            targetDeviceId: unsignedRequest.targetDeviceId,
            requestedProtocolSigningAlgorithms: unsignedRequest.requestedProtocolSigningAlgorithms,
            requesterProtocolSigningAlgorithm: unsignedRequest.requesterProtocolSigningAlgorithm,
            requesterProtocolIdentityPublicKey: unsignedRequest.requesterProtocolIdentityPublicKey,
            requesterProtocolIdentityFingerprint: unsignedRequest.requesterProtocolIdentityFingerprint,
            requesterSignature: requestSignature,
            nonce: nonce,
            sentAt: now
        )
        let unsignedCandidate = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: transactionId,
            deviceId: "responder-device",
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolIdentityPublicKey: responderPublicKey,
            protocolIdentityFingerprint: responderFingerprint,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: nonce,
            requestHashHex: request.canonicalRequestHashHex,
            signature: Data()
        )
        let candidateSignature = try responderKey.signature(for: unsignedCandidate.signaturePreimage)
        let candidate = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: transactionId,
            deviceId: unsignedCandidate.deviceId,
            protocolSigningAlgorithm: unsignedCandidate.protocolSigningAlgorithm,
            protocolIdentityPublicKey: unsignedCandidate.protocolIdentityPublicKey,
            protocolIdentityFingerprint: unsignedCandidate.protocolIdentityFingerprint,
            sentAt: unsignedCandidate.sentAt,
            expiresAt: unsignedCandidate.expiresAt,
            requestNonce: unsignedCandidate.requestNonce,
            requestHashHex: unsignedCandidate.requestHashHex,
            signature: candidateSignature
        )
        return (
            request,
            candidate,
            requesterKey,
            responderKey,
            requesterFingerprint,
            responderFingerprint
        )
    }

    private func makeConfirm(
        transcript: Transcript,
        confirmationNonce: Data = Data(repeating: 0xB2, count: 24),
        now: Date = Date()
    ) throws -> AppMessage.ProtocolIdentityBindingConfirmPayload {
        let unsigned = AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: transcript.request.transactionId,
            requesterDeviceId: transcript.request.requesterDeviceId,
            responderDeviceId: transcript.candidate.deviceId,
            requesterProtocolIdentityFingerprint: transcript.requesterFingerprint,
            responderProtocolIdentityFingerprint: transcript.responderFingerprint,
            requestNonce: transcript.request.nonce,
            requestHashHex: transcript.request.canonicalRequestHashHex,
            candidateHashHex: transcript.candidate.canonicalCandidateHashHex,
            sasTranscriptHashHex: transcript.candidate.sasTranscriptHashHex(request: transcript.request),
            confirmationNonce: confirmationNonce,
            sentAt: now,
            expiresAt: P2PProtocolIdentityBindingAdmissionPolicy.boundedChildExpiry(
                parentExpiry: transcript.candidate.expiresAt,
                issuedAt: now
            ),
            requesterSignature: Data()
        )
        return AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: unsigned.transactionId,
            requesterDeviceId: unsigned.requesterDeviceId,
            responderDeviceId: unsigned.responderDeviceId,
            requesterProtocolIdentityFingerprint: unsigned.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint: unsigned.responderProtocolIdentityFingerprint,
            requestNonce: unsigned.requestNonce,
            requestHashHex: unsigned.requestHashHex,
            candidateHashHex: unsigned.candidateHashHex,
            sasTranscriptHashHex: unsigned.sasTranscriptHashHex,
            confirmationNonce: unsigned.confirmationNonce,
            sentAt: unsigned.sentAt,
            expiresAt: unsigned.expiresAt,
            requesterSignature: try transcript.requesterKey.signature(for: unsigned.signaturePreimage)
        )
    }

    private func makeFinalAck(
        transcript: Transcript,
        confirm: AppMessage.ProtocolIdentityBindingConfirmPayload,
        accepted: Bool = true,
        now: Date = Date()
    ) throws -> AppMessage.SignedProtocolIdentityBindingFinalAckPayload {
        let unsigned = AppMessage.SignedProtocolIdentityBindingFinalAckPayload(
            transactionId: transcript.request.transactionId,
            requesterDeviceId: transcript.request.requesterDeviceId,
            responderDeviceId: transcript.candidate.deviceId,
            requesterProtocolIdentityFingerprint: transcript.requesterFingerprint,
            responderProtocolIdentityFingerprint: transcript.responderFingerprint,
            requestNonce: transcript.request.nonce,
            confirmationNonce: confirm.confirmationNonce,
            requestHashHex: transcript.request.canonicalRequestHashHex,
            candidateHashHex: transcript.candidate.canonicalCandidateHashHex,
            confirmHashHex: confirm.canonicalConfirmHashHex,
            sasTranscriptHashHex: transcript.candidate.sasTranscriptHashHex(request: transcript.request),
            accepted: accepted,
            sentAt: now,
            expiresAt: P2PProtocolIdentityBindingAdmissionPolicy.boundedChildExpiry(
                parentExpiry: confirm.expiresAt,
                issuedAt: now
            ),
            responderSignature: Data()
        )
        return AppMessage.SignedProtocolIdentityBindingFinalAckPayload(
            transactionId: unsigned.transactionId,
            requesterDeviceId: unsigned.requesterDeviceId,
            responderDeviceId: unsigned.responderDeviceId,
            requesterProtocolIdentityFingerprint: unsigned.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint: unsigned.responderProtocolIdentityFingerprint,
            requestNonce: unsigned.requestNonce,
            confirmationNonce: unsigned.confirmationNonce,
            requestHashHex: unsigned.requestHashHex,
            candidateHashHex: unsigned.candidateHashHex,
            confirmHashHex: unsigned.confirmHashHex,
            sasTranscriptHashHex: unsigned.sasTranscriptHashHex,
            accepted: unsigned.accepted,
            sentAt: unsigned.sentAt,
            expiresAt: unsigned.expiresAt,
            responderSignature: try transcript.responderKey.signature(for: unsigned.signaturePreimage)
        )
    }

    func testV3TranscriptRoundTripsAndValidatesBothSignatures() throws {
        let transcript = try makeTranscript()
        let candidate = try transcript.candidate.validatedForOOBBinding(request: transcript.request)
        XCTAssertTrue(
            transcript.responderKey.publicKey.isValidSignature(
                candidate.signature,
                for: candidate.signaturePreimage
            )
        )
        let confirm = try makeConfirm(transcript: transcript)
        XCTAssertNoThrow(
            try confirm.validatedForCandidate(
                request: transcript.request,
                candidate: candidate
            )
        )
        XCTAssertTrue(
            transcript.requesterKey.publicKey.isValidSignature(
                confirm.requesterSignature,
                for: confirm.signaturePreimage
            )
        )
        let finalAck = try makeFinalAck(transcript: transcript, confirm: confirm)
        XCTAssertNoThrow(
            try finalAck.validatedForFinalization(
                request: transcript.request,
                candidate: candidate,
                confirm: confirm
            )
        )
        XCTAssertTrue(
            transcript.responderKey.publicKey.isValidSignature(
                finalAck.responderSignature,
                for: finalAck.signaturePreimage
            )
        )

        for message in [
            AppMessage.protocolIdentityBindingRequest(transcript.request),
            .signedProtocolIdentityBinding(candidate),
            .protocolIdentityBindingConfirm(confirm),
            .signedProtocolIdentityBindingFinalAck(finalAck)
        ] {
            XCTAssertEqual(
                try JSONDecoder().decode(AppMessage.self, from: JSONEncoder().encode(message)),
                message
            )
        }
    }

    func testPIB1RequestRejectsEmptyUnknownMixedDuplicateAndNoncanonicalAlgorithms() throws {
        let invalidRequests: [[String]] = [
            [],
            ["Unknown-Signature"],
            [ProtocolSigningAlgorithm.ed25519.rawValue, "Unknown-Signature"],
            [
                ProtocolSigningAlgorithm.ed25519.rawValue,
                ProtocolSigningAlgorithm.ed25519.rawValue
            ],
            [" \(ProtocolSigningAlgorithm.ed25519.rawValue) "]
        ]

        for requestedAlgorithms in invalidRequests {
            let transcript = try makeTranscript(
                requestedProtocolSigningAlgorithms: requestedAlgorithms
            )
            XCTAssertThrowsError(
                try transcript.candidate.validatedForOOBBinding(
                    request: transcript.request
                )
            ) { error in
                XCTAssertEqual(
                    error as? AppMessage.ProtocolIdentityBindingValidationError,
                    .invalidRequestedSignatureAlgorithms
                )
            }
        }
    }

    func testPIB1ResponseAlgorithmMustBelongToRequest() throws {
        let transcript = try makeTranscript(
            requestedProtocolSigningAlgorithms: [
                ProtocolSigningAlgorithm.mlDSA65.rawValue
            ]
        )

        XCTAssertThrowsError(
            try transcript.candidate.validatedForOOBBinding(
                request: transcript.request
            )
        ) { error in
            XCTAssertEqual(
                error as? AppMessage.ProtocolIdentityBindingValidationError,
                .unrequestedSignatureAlgorithm
            )
        }
    }

    func testUnrepresentablePIBNetworkTimestampsFailClosedOnIOS() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hugeDate = Date(timeIntervalSince1970: .greatestFiniteMagnitude)
        let transcript = try makeTranscript(now: now)
        let request = AppMessage.ProtocolIdentityBindingRequestPayload(
            version: transcript.request.version,
            transactionId: transcript.request.transactionId,
            requesterDeviceId: transcript.request.requesterDeviceId,
            targetDeviceId: transcript.request.targetDeviceId,
            requestedProtocolSigningAlgorithms: transcript.request.requestedProtocolSigningAlgorithms,
            requesterProtocolSigningAlgorithm: transcript.request.requesterProtocolSigningAlgorithm,
            requesterProtocolIdentityPublicKey: transcript.request.requesterProtocolIdentityPublicKey,
            requesterProtocolIdentityFingerprint: transcript.request.requesterProtocolIdentityFingerprint,
            requesterSignature: transcript.request.requesterSignature,
            nonce: transcript.request.nonce,
            sentAt: hugeDate
        )
        XCTAssertNil(request.canonicalRequestHashHexIfRepresentable)

        let candidate = AppMessage.SignedProtocolIdentityBindingPayload(
            version: transcript.candidate.version,
            transactionId: transcript.candidate.transactionId,
            deviceId: transcript.candidate.deviceId,
            aliases: transcript.candidate.aliases,
            protocolSigningAlgorithm: transcript.candidate.protocolSigningAlgorithm,
            protocolIdentityPublicKey: transcript.candidate.protocolIdentityPublicKey,
            protocolIdentityFingerprint: transcript.candidate.protocolIdentityFingerprint,
            deviceName: transcript.candidate.deviceName,
            sentAt: transcript.candidate.sentAt,
            expiresAt: hugeDate,
            requestNonce: transcript.candidate.requestNonce,
            requestHashHex: transcript.candidate.requestHashHex,
            signature: transcript.candidate.signature
        )
        XCTAssertThrowsError(
            try candidate.validatedForOOBBinding(request: transcript.request, now: now)
        ) { error in
            XCTAssertEqual(
                error as? AppMessage.ProtocolIdentityBindingValidationError,
                .unrepresentableTimestamp
            )
        }

        let validConfirm = try makeConfirm(transcript: transcript, now: now)
        let confirm = AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: validConfirm.transactionId,
            requesterDeviceId: validConfirm.requesterDeviceId,
            responderDeviceId: validConfirm.responderDeviceId,
            requesterProtocolIdentityFingerprint: validConfirm.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint: validConfirm.responderProtocolIdentityFingerprint,
            requestNonce: validConfirm.requestNonce,
            requestHashHex: validConfirm.requestHashHex,
            candidateHashHex: validConfirm.candidateHashHex,
            sasTranscriptHashHex: validConfirm.sasTranscriptHashHex,
            confirmationNonce: validConfirm.confirmationNonce,
            sentAt: hugeDate,
            expiresAt: validConfirm.expiresAt,
            requesterSignature: validConfirm.requesterSignature
        )
        XCTAssertThrowsError(
            try confirm.validatedForCandidate(
                request: transcript.request,
                candidate: transcript.candidate,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? AppMessage.ProtocolIdentityBindingValidationError,
                .unrepresentableTimestamp
            )
        }

        let validAck = try makeFinalAck(
            transcript: transcript,
            confirm: validConfirm,
            now: now
        )
        let finalAck = AppMessage.SignedProtocolIdentityBindingFinalAckPayload(
            version: validAck.version,
            transactionId: validAck.transactionId,
            requesterDeviceId: validAck.requesterDeviceId,
            responderDeviceId: validAck.responderDeviceId,
            requesterProtocolIdentityFingerprint: validAck.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint: validAck.responderProtocolIdentityFingerprint,
            requestNonce: validAck.requestNonce,
            confirmationNonce: validAck.confirmationNonce,
            requestHashHex: validAck.requestHashHex,
            candidateHashHex: validAck.candidateHashHex,
            confirmHashHex: validAck.confirmHashHex,
            sasTranscriptHashHex: validAck.sasTranscriptHashHex,
            accepted: validAck.accepted,
            sentAt: validAck.sentAt,
            expiresAt: hugeDate,
            responderSignature: validAck.responderSignature
        )
        XCTAssertThrowsError(
            try finalAck.validatedForFinalization(
                request: transcript.request,
                candidate: transcript.candidate,
                confirm: validConfirm,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? AppMessage.ProtocolIdentityBindingValidationError,
                .unrepresentableTimestamp
            )
        }
    }

    func testV3CrossPlatformGoldenVectorMatchesMacOS() {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let transactionId = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let request = AppMessage.ProtocolIdentityBindingRequestPayload(
            transactionId: transactionId,
            requesterDeviceId: "id:ios-golden",
            targetDeviceId: "id:mac-golden",
            requestedProtocolSigningAlgorithms: ["Ed25519"],
            requesterProtocolSigningAlgorithm: "Ed25519",
            requesterProtocolIdentityPublicKey: Data(repeating: 0x22, count: 32),
            requesterProtocolIdentityFingerprint: String(repeating: "a", count: 64),
            requesterSignature: Data(repeating: 0x11, count: 64),
            bonjourEndpointDigest: String(repeating: "c", count: 64),
            nonce: Data((0..<24).map(UInt8.init)),
            sentAt: fixedDate
        )
        let candidate = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: transactionId,
            deviceId: "id:mac-golden",
            aliases: ["id:mac-golden", "bonjour:mac-golden@local."],
            protocolSigningAlgorithm: "Ed25519",
            protocolIdentityPublicKey: Data(repeating: 0x44, count: 32),
            protocolIdentityFingerprint: String(repeating: "b", count: 64),
            deviceName: "Golden Mac",
            sentAt: fixedDate,
            expiresAt: fixedDate.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data(repeating: 0x33, count: 64)
        )
        let confirm = AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: transactionId,
            requesterDeviceId: request.requesterDeviceId,
            responderDeviceId: candidate.deviceId,
            requesterProtocolIdentityFingerprint: String(repeating: "a", count: 64),
            responderProtocolIdentityFingerprint: String(repeating: "b", count: 64),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            candidateHashHex: candidate.canonicalCandidateHashHex,
            sasTranscriptHashHex: candidate.sasTranscriptHashHex(request: request),
            confirmationNonce: Data(repeating: 0x55, count: 24),
            sentAt: fixedDate,
            expiresAt: fixedDate.addingTimeInterval(300),
            requesterSignature: Data(repeating: 0x66, count: 64)
        )
        let ack = AppMessage.SignedProtocolIdentityBindingFinalAckPayload(
            transactionId: transactionId,
            requesterDeviceId: request.requesterDeviceId,
            responderDeviceId: candidate.deviceId,
            requesterProtocolIdentityFingerprint: request.requesterProtocolIdentityFingerprint ?? "",
            responderProtocolIdentityFingerprint: candidate.protocolIdentityFingerprint,
            requestNonce: request.nonce,
            confirmationNonce: confirm.confirmationNonce,
            requestHashHex: request.canonicalRequestHashHex,
            candidateHashHex: candidate.canonicalCandidateHashHex,
            confirmHashHex: confirm.canonicalConfirmHashHex,
            sasTranscriptHashHex: candidate.sasTranscriptHashHex(request: request),
            accepted: true,
            sentAt: fixedDate,
            expiresAt: fixedDate.addingTimeInterval(300),
            responderSignature: Data(repeating: 0x77, count: 64)
        )
        let ackPreimageHash = SHA256.hash(data: ack.signaturePreimage)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(request.canonicalRequestHashHex, "0b57a8713f6eba3c41061d38c1b33dcfa11750885976f0d5828916d3ac8f01ad")
        XCTAssertEqual(candidate.canonicalCandidateHashHex, "4cbf643a7041361d658f6ba4d7960ec42a962e76275e38098de6a09ebf581e1a")
        XCTAssertEqual(candidate.sasTranscriptHashHex(request: request), "724f79895460bfcb6e7136e637998b22285dca087573ed257678293c95ecd950")
        XCTAssertEqual(confirm.canonicalConfirmHashHex, "78a1f5b29b7535479de0ea576fb778624b5bab359483e3024bbb61acf223566a")
        XCTAssertEqual(ackPreimageHash, "f6edad1347d9b1bd805e326491ca5a4fe52870dbfed233af6fc56ee38a89f760")
    }

    func testV2RequestAndNegativeFinalAckFailClosed() throws {
        let v2Transcript = try makeTranscript(requestVersion: 2)
        XCTAssertThrowsError(
            try v2Transcript.candidate.validatedForOOBBinding(request: v2Transcript.request)
        ) { error in
            XCTAssertEqual(error as? AppMessage.ProtocolIdentityBindingValidationError, .invalidVersion)
        }

        var legacyWire = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    AppMessage.protocolIdentityBindingRequest(v2Transcript.request)
                )
            ) as? [String: Any]
        )
        var legacyRequest = try XCTUnwrap(
            legacyWire["protocolIdentityBindingRequest"] as? [String: Any]
        )
        legacyRequest.removeValue(forKey: "transactionId")
        legacyWire["protocolIdentityBindingRequest"] = legacyRequest
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AppMessage.self,
                from: JSONSerialization.data(withJSONObject: legacyWire)
            )
        )

        let transcript = try makeTranscript()
        let confirm = try makeConfirm(transcript: transcript)
        let rejectedAck = try makeFinalAck(
            transcript: transcript,
            confirm: confirm,
            accepted: false
        )
        XCTAssertThrowsError(
            try rejectedAck.validatedForFinalization(
                request: transcript.request,
                candidate: transcript.candidate,
                confirm: confirm
            )
        )
    }

    func testResponderStateIsBoundedExpiringAndIdempotent() async throws {
        let now = Date()
        let store = ProtocolIdentityBindingV3StateStore(ttl: 900, maximumEntries: 2)
        let transcript = try makeTranscript(now: now)
        let context = ProtocolIdentityBindingV3ResponderContext(
            request: transcript.request,
            candidate: transcript.candidate,
            requesterProtocolSigningAlgorithm: .ed25519,
            requesterProtocolIdentityPublicKey: transcript.requesterKey.publicKey.rawRepresentation,
            requesterProtocolIdentityFingerprint: transcript.requesterFingerprint,
            responderProtocolSigningKeyHandle: .softwareKey(
                transcript.responderKey.rawRepresentation
            ),
            peerId: "peer",
            expiresAt: now.addingTimeInterval(900)
        )
        guard case .stored = await store.registerCandidate(context, now: now) else {
            return XCTFail("First candidate must be stored")
        }
        guard case .replay(let replayed) = await store.registerCandidate(context, now: now) else {
            return XCTFail("Exact candidate replay must be idempotent")
        }
        XCTAssertEqual(replayed.candidate, transcript.candidate)

        let confirm = try makeConfirm(transcript: transcript, now: now)
        guard case .allowed = await store.beginConfirm(confirm, now: now) else {
            return XCTFail("Matching confirm must be admitted once")
        }
        let finalAck = try makeFinalAck(transcript: transcript, confirm: confirm, now: now)
        let completed = await store.completeConfirm(
            transactionId: transcript.request.transactionId,
            confirmHashHex: confirm.canonicalConfirmHashHex,
            finalAck: finalAck
        )
        XCTAssertTrue(completed)
        guard case .replay(let replayedAck) = await store.beginConfirm(confirm, now: now) else {
            return XCTFail("Completed confirm replay must return the same signed finalAck")
        }
        XCTAssertEqual(replayedAck, finalAck)

        let second = try makeTranscript(now: now)
        let secondContext = ProtocolIdentityBindingV3ResponderContext(
            request: second.request,
            candidate: second.candidate,
            requesterProtocolSigningAlgorithm: .ed25519,
            requesterProtocolIdentityPublicKey: second.requesterKey.publicKey.rawRepresentation,
            requesterProtocolIdentityFingerprint: second.requesterFingerprint,
            responderProtocolSigningKeyHandle: .softwareKey(
                second.responderKey.rawRepresentation
            ),
            peerId: "peer-2",
            expiresAt: now.addingTimeInterval(900)
        )
        guard case .stored = await store.registerCandidate(secondContext, now: now) else {
            return XCTFail("Second candidate must fit the configured cap")
        }
        let third = try makeTranscript(now: now)
        let thirdContext = ProtocolIdentityBindingV3ResponderContext(
            request: third.request,
            candidate: third.candidate,
            requesterProtocolSigningAlgorithm: .ed25519,
            requesterProtocolIdentityPublicKey: third.requesterKey.publicKey.rawRepresentation,
            requesterProtocolIdentityFingerprint: third.requesterFingerprint,
            responderProtocolSigningKeyHandle: .softwareKey(
                third.responderKey.rawRepresentation
            ),
            peerId: "peer-3",
            expiresAt: now.addingTimeInterval(900)
        )
        guard case .capacityExceeded = await store.registerCandidate(thirdContext, now: now) else {
            return XCTFail("Third live candidate must fail closed at the configured cap")
        }
        let liveCount = await store.entryCountForTesting(now: now.addingTimeInterval(299))
        let expiredCount = await store.entryCountForTesting(now: now.addingTimeInterval(301))
        XCTAssertEqual(liveCount, 2)
        XCTAssertEqual(expiredCount, 0)
    }

    func testResponderBeginConfirmRejectsHugeFiniteDateBeforeHashAndReturnsCallerSafeAdmission() async throws {
        let now = Date()
        let store = ProtocolIdentityBindingV3StateStore(ttl: 300, maximumEntries: 2)
        let transcript = try makeTranscript(now: now)
        let context = ProtocolIdentityBindingV3ResponderContext(
            request: transcript.request,
            candidate: transcript.candidate,
            requesterProtocolSigningAlgorithm: .ed25519,
            requesterProtocolIdentityPublicKey: transcript.requesterKey.publicKey.rawRepresentation,
            requesterProtocolIdentityFingerprint: transcript.requesterFingerprint,
            responderProtocolSigningKeyHandle: .softwareKey(
                transcript.responderKey.rawRepresentation
            ),
            peerId: "peer",
            expiresAt: now.addingTimeInterval(300)
        )
        guard case .stored = await store.registerCandidate(context, now: now) else {
            return XCTFail("Candidate must be stored before confirm admission")
        }

        let validConfirm = try makeConfirm(transcript: transcript, now: now)
        let unrepresentableConfirm = AppMessage.ProtocolIdentityBindingConfirmPayload(
            version: validConfirm.version,
            transactionId: validConfirm.transactionId,
            requesterDeviceId: validConfirm.requesterDeviceId,
            responderDeviceId: validConfirm.responderDeviceId,
            requesterProtocolIdentityFingerprint: validConfirm.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint: validConfirm.responderProtocolIdentityFingerprint,
            requestNonce: validConfirm.requestNonce,
            requestHashHex: validConfirm.requestHashHex,
            candidateHashHex: validConfirm.candidateHashHex,
            sasTranscriptHashHex: validConfirm.sasTranscriptHashHex,
            confirmationNonce: validConfirm.confirmationNonce,
            sentAt: Date(timeIntervalSince1970: .greatestFiniteMagnitude),
            expiresAt: validConfirm.expiresAt,
            requesterSignature: validConfirm.requesterSignature
        )
        guard case .rejected = await store.beginConfirm(unrepresentableConfirm, now: now) else {
            return XCTFail("An unrepresentable confirm timestamp must reject before hashing")
        }

        let admitted: ProtocolIdentityBindingV3AdmittedConfirm
        switch await store.beginConfirm(validConfirm, now: now) {
        case .allowed(let value):
            admitted = value
        default:
            return XCTFail("A valid confirm must remain admissible after the rejected input")
        }
        XCTAssertEqual(admitted.context.request.transactionId, transcript.request.transactionId)
        XCTAssertEqual(admitted.validatedConfirm, validConfirm)
        XCTAssertEqual(admitted.confirmHashHex, validConfirm.canonicalConfirmHashHex)

        guard case .inFlight = await store.beginConfirm(validConfirm, now: now) else {
            return XCTFail("An identical admitted confirm must preserve in-flight idempotence")
        }
        let conflictingConfirm = AppMessage.ProtocolIdentityBindingConfirmPayload(
            version: validConfirm.version,
            transactionId: validConfirm.transactionId,
            requesterDeviceId: validConfirm.requesterDeviceId,
            responderDeviceId: validConfirm.responderDeviceId,
            requesterProtocolIdentityFingerprint: validConfirm.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint: validConfirm.responderProtocolIdentityFingerprint,
            requestNonce: validConfirm.requestNonce,
            requestHashHex: validConfirm.requestHashHex,
            candidateHashHex: validConfirm.candidateHashHex,
            sasTranscriptHashHex: validConfirm.sasTranscriptHashHex,
            confirmationNonce: validConfirm.confirmationNonce,
            sentAt: validConfirm.sentAt,
            expiresAt: validConfirm.expiresAt,
            requesterSignature: Data(repeating: 0xEE, count: validConfirm.requesterSignature.count)
        )
        guard case .rejected = await store.beginConfirm(conflictingConfirm, now: now) else {
            return XCTFail("A conflicting in-flight confirm must remain rejected")
        }

        await store.abortConfirm(
            transactionId: transcript.request.transactionId,
            confirmHashHex: admitted.confirmHashHex,
            now: now
        )
    }

    func testResponderInFlightConfirmSuspendsExpiryCleanupUntilCompletion() async throws {
        let now = Date()
        let store = ProtocolIdentityBindingV3StateStore(ttl: 300, maximumEntries: 2)
        let transcript = try makeTranscript(now: now)
        let context = ProtocolIdentityBindingV3ResponderContext(
            request: transcript.request,
            candidate: transcript.candidate,
            requesterProtocolSigningAlgorithm: .ed25519,
            requesterProtocolIdentityPublicKey: transcript.requesterKey.publicKey.rawRepresentation,
            requesterProtocolIdentityFingerprint: transcript.requesterFingerprint,
            responderProtocolSigningKeyHandle: .softwareKey(
                transcript.responderKey.rawRepresentation
            ),
            peerId: "peer",
            expiresAt: now.addingTimeInterval(300)
        )
        guard case .stored = await store.registerCandidate(context, now: now) else {
            return XCTFail("Candidate must be stored")
        }
        let cleanupScheduledBeforeConfirm = await store.cleanupIsScheduledForTesting()
        XCTAssertTrue(cleanupScheduledBeforeConfirm)

        let confirm = try makeConfirm(transcript: transcript, now: now)
        guard case .allowed = await store.beginConfirm(confirm, now: now) else {
            return XCTFail("Matching confirm must enter the bounded in-flight state")
        }
        let cleanupScheduledDuringConfirm = await store.cleanupIsScheduledForTesting()
        XCTAssertFalse(
            cleanupScheduledDuringConfirm,
            "An in-flight operator/crypto task owns expiry; a zero-delay cleanup task must not spin."
        )
        let retainedInFlightCount = await store.entryCountForTesting(
            now: now.addingTimeInterval(301)
        )
        XCTAssertEqual(
            retainedInFlightCount,
            1,
            "Expiry pruning must retain the exact in-flight transaction until its owner completes or aborts."
        )

        await store.abortConfirm(
            transactionId: transcript.request.transactionId,
            confirmHashHex: confirm.canonicalConfirmHashHex,
            now: now.addingTimeInterval(301)
        )
        let countAfterAbort = await store.entryCountForTesting(
            now: now.addingTimeInterval(301)
        )
        let cleanupScheduledAfterAbort = await store.cleanupIsScheduledForTesting()
        XCTAssertEqual(countAfterAbort, 0)
        XCTAssertFalse(cleanupScheduledAfterAbort)
    }

    func testResponderAdmissionAppliesSharedRequesterQuotaAndRateWindow() async throws {
        let base = Date()
        let requesterKey = Curve25519.Signing.PrivateKey()
        let store = ProtocolIdentityBindingV3StateStore(
            ttl: P2PProtocolIdentityBindingAdmissionPolicy.maximumTransactionTTLSeconds,
            maximumEntries: P2PProtocolIdentityBindingAdmissionPolicy.maximumTransactions
        )

        for index in 0..<P2PProtocolIdentityBindingAdmissionPolicy
            .maximumTransactionsPerRequester {
            let transcript = try makeTranscript(
                requesterKey: requesterKey,
                now: base.addingTimeInterval(TimeInterval(index) / 100)
            )
            let context = ProtocolIdentityBindingV3ResponderContext(
                request: transcript.request,
                candidate: transcript.candidate,
                requesterProtocolSigningAlgorithm: .ed25519,
                requesterProtocolIdentityPublicKey: transcript.requesterKey.publicKey.rawRepresentation,
                requesterProtocolIdentityFingerprint: transcript.requesterFingerprint,
                responderProtocolSigningKeyHandle: .softwareKey(
                    transcript.responderKey.rawRepresentation
                ),
                peerId: "same-requester",
                expiresAt: base.addingTimeInterval(30)
            )
            guard case .stored = await store.registerCandidate(context, now: base) else {
                return XCTFail("Shared per-requester quota must admit its configured prefix")
            }
        }

        let quotaTranscript = try makeTranscript(
            requesterKey: requesterKey,
            now: base
        )
        let quotaContext = ProtocolIdentityBindingV3ResponderContext(
            request: quotaTranscript.request,
            candidate: quotaTranscript.candidate,
            requesterProtocolSigningAlgorithm: .ed25519,
            requesterProtocolIdentityPublicKey: quotaTranscript.requesterKey.publicKey.rawRepresentation,
            requesterProtocolIdentityFingerprint: quotaTranscript.requesterFingerprint,
            responderProtocolSigningKeyHandle: .softwareKey(
                quotaTranscript.responderKey.rawRepresentation
            ),
            peerId: "same-requester",
            expiresAt: base.addingTimeInterval(30)
        )
        guard case .requesterQuotaExceeded = await store.registerCandidate(
            quotaContext,
            now: base
        ) else {
            return XCTFail("The fifth active transaction from one authority must fail closed")
        }

        await store.clearForTesting()
        for index in 0..<P2PProtocolIdentityBindingAdmissionPolicy
            .maximumAdmissionsPerRequesterPerWindow {
            let admissionNow = base.addingTimeInterval(TimeInterval(index))
            let transcript = try makeTranscript(
                requesterKey: requesterKey,
                now: admissionNow
            )
            let context = ProtocolIdentityBindingV3ResponderContext(
                request: transcript.request,
                candidate: transcript.candidate,
                requesterProtocolSigningAlgorithm: .ed25519,
                requesterProtocolIdentityPublicKey: transcript.requesterKey.publicKey.rawRepresentation,
                requesterProtocolIdentityFingerprint: transcript.requesterFingerprint,
                responderProtocolSigningKeyHandle: .softwareKey(
                    transcript.responderKey.rawRepresentation
                ),
                peerId: "same-requester",
                expiresAt: admissionNow.addingTimeInterval(0.5)
            )
            guard case .stored = await store.registerCandidate(
                context,
                now: admissionNow
            ) else {
                return XCTFail("Short-lived transactions must admit up to the shared rate limit")
            }
        }
        let limitedNow = base.addingTimeInterval(8)
        let limitedTranscript = try makeTranscript(
            requesterKey: requesterKey,
            now: limitedNow
        )
        let limitedContext = ProtocolIdentityBindingV3ResponderContext(
            request: limitedTranscript.request,
            candidate: limitedTranscript.candidate,
            requesterProtocolSigningAlgorithm: .ed25519,
            requesterProtocolIdentityPublicKey: limitedTranscript.requesterKey.publicKey.rawRepresentation,
            requesterProtocolIdentityFingerprint: limitedTranscript.requesterFingerprint,
            responderProtocolSigningKeyHandle: .softwareKey(
                limitedTranscript.responderKey.rawRepresentation
            ),
            peerId: "same-requester",
            expiresAt: limitedNow.addingTimeInterval(0.5)
        )
        guard case .requesterRateLimited = await store.registerCandidate(
            limitedContext,
            now: limitedNow
        ) else {
            return XCTFail("The shared ten-second requester admission rate must fail closed")
        }
    }
}

@available(iOS 17.0, *)
@MainActor
final class P2PBootstrapRekeyTargetTests: XCTestCase {
    private func readRepositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try readRepositorySourceForSourceShapeTests(
            at: repoRoot.appendingPathComponent(relativePath))
    }

    func testHandshakeFrameProcessorOnlyOwnsResponderTerminalCommit() {
        XCTAssertFalse(
            P2PHandshakeOperationCompletionAuthority
                .initiatingTask
                .frameProcessorOwnsTerminalCommit
        )
        XCTAssertTrue(
            P2PHandshakeOperationCompletionAuthority
                .inboundFrameProcessor
                .frameProcessorOwnsTerminalCommit
        )
        XCTAssertEqual(
            P2PHandshakeOperationCompletionAuthority.initiatingTask
                .frameProcessorPostAwaitAction(isCurrent: true),
            .returnWithoutDriverMutation
        )
        XCTAssertEqual(
            P2PHandshakeOperationCompletionAuthority.initiatingTask
                .frameProcessorPostAwaitAction(isCurrent: false),
            .returnWithoutDriverMutation
        )
        XCTAssertEqual(
            P2PHandshakeOperationCompletionAuthority.inboundFrameProcessor
                .frameProcessorPostAwaitAction(isCurrent: true),
            .continueResponderTerminalProcessing
        )
        XCTAssertEqual(
            P2PHandshakeOperationCompletionAuthority.inboundFrameProcessor
                .frameProcessorPostAwaitAction(isCurrent: false),
            .returnWithoutDriverMutation
        )
    }

    func testPairingIdentityBootstrapReadinessRequiresExactObservationAndTrustMaterial() {
        XCTAssertFalse(
            P2PConnectionManager.isPairingIdentityBootstrapReady(
                hasCurrentSessionObservation: false,
                hasStrictPQCTrustMaterial: false
            )
        )
        XCTAssertFalse(
            P2PConnectionManager.isPairingIdentityBootstrapReady(
                hasCurrentSessionObservation: true,
                hasStrictPQCTrustMaterial: false
            )
        )
        XCTAssertFalse(
            P2PConnectionManager.isPairingIdentityBootstrapReady(
                hasCurrentSessionObservation: false,
                hasStrictPQCTrustMaterial: true
            )
        )
        XCTAssertTrue(
            P2PConnectionManager.isPairingIdentityBootstrapReady(
                hasCurrentSessionObservation: true,
                hasStrictPQCTrustMaterial: true
            )
        )
    }

    func testPairingIdentityBootstrapReceiptSurvivesExactReplayAndRejectsAuthorityMutation() {
        let generation = UUID()
        let fingerprint = String(repeating: "a", count: 64)
        let acceptedMaterialDigest = Data(repeating: 0x11, count: 32)
        let receipt = P2PPairingIdentityBootstrapReadinessReceipt(
            peerId: "id:remote-authority",
            connectionGeneration: generation,
            sessionId: "session-a",
            declaredDeviceId: "id:remote-authority",
            protocolPublicKeyFingerprint: fingerprint,
            acceptedMaterialDigest: acceptedMaterialDigest
        )

        XCTAssertTrue(
            receipt.matches(
                peerId: "id:remote-authority",
                connectionGeneration: generation,
                sessionId: "session-a",
                declaredDeviceId: "id:remote-authority",
                protocolPublicKeyFingerprint: fingerprint,
                acceptedMaterialDigest: acceptedMaterialDigest
            )
        )
        XCTAssertFalse(
            receipt.matches(
                peerId: "id:remote-authority",
                connectionGeneration: UUID(),
                sessionId: "session-a",
                declaredDeviceId: "id:remote-authority",
                protocolPublicKeyFingerprint: fingerprint,
                acceptedMaterialDigest: acceptedMaterialDigest
            )
        )
        XCTAssertFalse(
            receipt.matches(
                peerId: "id:remote-authority",
                connectionGeneration: generation,
                sessionId: "session-b",
                declaredDeviceId: "id:remote-authority",
                protocolPublicKeyFingerprint: fingerprint,
                acceptedMaterialDigest: acceptedMaterialDigest
            )
        )
        XCTAssertTrue(
            receipt.matches(
                peerId: "id:remote-authority",
                connectionGeneration: generation,
                sessionId: "session-a",
                declaredDeviceId: "id:remote-authority",
                protocolPublicKeyFingerprint: fingerprint,
                acceptedMaterialDigest: acceptedMaterialDigest
            ),
            "A repeated exact authority observation must not revoke a current-session receipt"
        )
        XCTAssertFalse(
            receipt.matches(
                peerId: "id:remote-authority",
                connectionGeneration: generation,
                sessionId: "session-a",
                declaredDeviceId: "id:other-authority",
                protocolPublicKeyFingerprint: fingerprint,
                acceptedMaterialDigest: acceptedMaterialDigest
            )
        )
        XCTAssertFalse(
            receipt.matches(
                peerId: "id:remote-authority",
                connectionGeneration: generation,
                sessionId: "session-a",
                declaredDeviceId: "id:remote-authority",
                protocolPublicKeyFingerprint: String(repeating: "b", count: 64),
                acceptedMaterialDigest: acceptedMaterialDigest
            )
        )
        XCTAssertFalse(
            receipt.matches(
                peerId: "id:remote-authority",
                connectionGeneration: generation,
                sessionId: "session-a",
                declaredDeviceId: "id:remote-authority",
                protocolPublicKeyFingerprint: fingerprint,
                acceptedMaterialDigest: Data(repeating: 0x22, count: 32)
            )
        )
    }

    func testPairingIdentityBootstrapEvidenceClassifierSeparatesReplayMissingAndConflict() {
        let generation = UUID()
        let fingerprint = String(repeating: "a", count: 64)
        let acceptedMaterialDigest = Data(repeating: 0x11, count: 32)
        let receipt = P2PPairingIdentityBootstrapReadinessReceipt(
            peerId: "id:remote-authority",
            connectionGeneration: generation,
            sessionId: "session-a",
            declaredDeviceId: "id:remote-authority",
            protocolPublicKeyFingerprint: fingerprint,
            acceptedMaterialDigest: acceptedMaterialDigest
        )
        let exactReplay = P2PPairingIdentityBootstrapEvidence(
            connectionGeneration: generation,
            sessionId: "session-a",
            declaredDeviceId: "id:remote-authority",
            protocolPublicKeyFingerprint: fingerprint,
            acceptedMaterialDigest: acceptedMaterialDigest
        )
        let olderSession = P2PPairingIdentityBootstrapEvidence(
            connectionGeneration: UUID(),
            sessionId: "session-old",
            declaredDeviceId: "id:remote-authority",
            protocolPublicKeyFingerprint: fingerprint,
            acceptedMaterialDigest: acceptedMaterialDigest
        )
        let changedAuthority = P2PPairingIdentityBootstrapEvidence(
            connectionGeneration: generation,
            sessionId: "session-a",
            declaredDeviceId: "id:remote-authority",
            protocolPublicKeyFingerprint: fingerprint,
            acceptedMaterialDigest: Data(repeating: 0x22, count: 32)
        )

        XCTAssertEqual(receipt.evidenceState(for: [exactReplay]), .current)
        XCTAssertEqual(
            receipt.evidenceState(for: [olderSession, exactReplay]),
            .current,
            "An old connection alias must not pollute exact-session evidence"
        )
        XCTAssertEqual(receipt.evidenceState(for: []), .missing)
        XCTAssertEqual(receipt.evidenceState(for: [olderSession]), .missing)
        XCTAssertEqual(
            receipt.evidenceState(for: [exactReplay, changedAuthority]),
            .authorityConflict,
            "One conflicting alias must invalidate the entire exact-session evidence set"
        )
    }

    func testPairingIdentityBootstrapReadinessReusesExactCurrentObservationBeforeSending() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(
            source.range(of: "func requestPairingIdentityExchangeBootstrapReadiness(")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "private func pairingIdentityBootstrapReceipt(",
                range: start.upperBound..<source.endIndex
            )
        )
        let body = String(source[start.lowerBound..<end.lowerBound])
        let existingObservation = try XCTUnwrap(body.range(of: "since: .distantPast"))
        let strictTrust = try XCTUnwrap(
            body.range(of: "await hasStrictPQCTrustBootstrapMaterial(for: observation)")
        )
        let send = try XCTUnwrap(
            body.range(of: "let sendOutcome = try await sendPairingIdentityExchange(")
        )

        XCTAssertLessThan(existingObservation.lowerBound, strictTrust.lowerBound)
        XCTAssertLessThan(strictTrust.lowerBound, send.lowerBound)
        XCTAssertTrue(body.contains("case .journalBusy:"))
        XCTAssertTrue(body.contains("case .current:"))
    }

    func testOutboundInitiatorRetainsExactHandshakeOwnerUntilItsCommitCompletes() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let inboundCreationStart = try XCTUnwrap(
            source.range(of: "private func ensureInboundHandshakeDriverIfNeeded(")
        )
        let inboundCreationEnd = try XCTUnwrap(
            source.range(
                of: "private func processHandshakeFrame(",
                range: inboundCreationStart.lowerBound..<source.endIndex
            )
        )
        let inboundCreationBody = String(
            source[inboundCreationStart.lowerBound..<inboundCreationEnd.lowerBound]
        )
        XCTAssertTrue(inboundCreationBody.contains("completionAuthority: .inboundFrameProcessor"))

        let processStart = inboundCreationEnd
        let processEnd = try XCTUnwrap(
            source.range(
                of: "private func ensureInboundRekeyDriverIfNeeded(",
                range: processStart.lowerBound..<source.endIndex
            )
        )
        let processBody = String(source[processStart.lowerBound..<processEnd.lowerBound])
        let exactOwnerLookup = try XCTUnwrap(
            processBody.range(of: "handshakeOperationOwnerByPeerId[peerId]")
        )
        let postAwaitAuthorityGate = try XCTUnwrap(
            processBody.range(
                of: "operationOwner.completionAuthority.frameProcessorPostAwaitAction"
            )
        )
        let messageDelivery = try XCTUnwrap(
            processBody.range(of: "await activeDriver.handleMessage(frame, from: peer)")
        )
        let stateRead = try XCTUnwrap(
            processBody.range(of: "let state = await activeDriver.getCurrentState()")
        )
        let terminalSwitch = try XCTUnwrap(processBody.range(of: "switch state"))
        let driverDetach = try XCTUnwrap(
            processBody.range(of: "detachHandshakeDriverIfOwned(")
        )
        let ownerFinish = try XCTUnwrap(
            processBody.range(of: "finishHandshakeOperation(operationOwner)")
        )

        XCTAssertLessThan(exactOwnerLookup.lowerBound, messageDelivery.lowerBound)
        XCTAssertLessThan(messageDelivery.lowerBound, postAwaitAuthorityGate.lowerBound)
        XCTAssertLessThan(postAwaitAuthorityGate.lowerBound, stateRead.lowerBound)
        XCTAssertLessThan(stateRead.lowerBound, terminalSwitch.lowerBound)
        XCTAssertGreaterThanOrEqual(
            processBody.components(separatedBy: "frameProcessorPostAwaitAction").count - 1,
            2,
            "Both driver awaits must re-enter through the exact completion-authority decision."
        )
        XCTAssertLessThan(terminalSwitch.lowerBound, driverDetach.lowerBound)
        XCTAssertLessThan(driverDetach.lowerBound, ownerFinish.lowerBound)
        XCTAssertFalse(
            processBody.contains(
                "let operationOwner = HandshakeOperationOwner("
            ),
            "The receive path must preserve completion authority from the exact registry owner."
        )

        let performStart = try XCTUnwrap(
            source.range(of: "private func performPQCHandshake(")
        )
        let performEnd = try XCTUnwrap(
            source.range(
                of: "/// 强制用 preferPQC=true",
                range: performStart.lowerBound..<source.endIndex
            )
        )
        let performBody = String(source[performStart.lowerBound..<performEnd.lowerBound])
        XCTAssertTrue(performBody.contains("completionAuthority: .initiatingTask"))
        XCTAssertTrue(performBody.contains("finishHandshakeOperation(operationOwner)"))
        XCTAssertTrue(performBody.contains("try requireCurrentHandshakeOperation(operationOwner)"))

        let rekeyStart = try XCTUnwrap(
            source.range(of: "public func rekeyToPreferPQC(")
        )
        let rekeyBody = String(source[rekeyStart.lowerBound...])
        XCTAssertTrue(rekeyBody.contains("completionAuthority: .initiatingTask"))

        let inboundRekeyStart = processEnd
        let inboundRekeyEnd = try XCTUnwrap(
            source.range(
                of: "private func isLikelyHandshakeControlPacket(",
                range: inboundRekeyStart.lowerBound..<source.endIndex
            )
        )
        let inboundRekeyBody = String(
            source[inboundRekeyStart.lowerBound..<inboundRekeyEnd.lowerBound]
        )
        XCTAssertTrue(inboundRekeyBody.contains("completionAuthority: .inboundFrameProcessor"))
    }

    func testStrictPQCRecognizesCanonicalMLKEMAsSatisfyingForwardSecureTarget() {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.mlkem768],
                preferredTargetSuite: .mlkem768fs
            )
        )
    }

    func testSuiteSupportsTargetKEMTreatsFSAndCanonicalMLKEMAsEquivalent() {
        XCTAssertTrue(P2PConnectionManager.suiteSupportsTargetKEM(.mlkem768, target: .mlkem768fs))
        XCTAssertTrue(P2PConnectionManager.suiteSupportsTargetKEM(.mlkem768fs, target: .mlkem768))
        XCTAssertFalse(P2PConnectionManager.suiteSupportsTargetKEM(.xwing, target: .mlkem768fs))
    }

    func testInboundResponderRequiresXWingRuntimeSupportForXWingOnlyPeer() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/CryptoProviderFactory.swift"
        )
        let branchStart = try XCTUnwrap(source.range(of: "case (true, false):"))
        let branchEnd = try XCTUnwrap(source.range(of: "case (false, true):", range: branchStart.lowerBound..<source.endIndex))
        let xwingOnlyBranch = String(source[branchStart.lowerBound..<branchEnd.lowerBound])

        XCTAssertTrue(xwingOnlyBranch.contains("guard isAppleXWingAvailable() else"))
        XCTAssertTrue(xwingOnlyBranch.contains("return UnavailablePQCProvider()"))
        XCTAssertTrue(xwingOnlyBranch.contains("return AppleXWingCryptoProvider()"))
    }

    func testPreferredBootstrapRekeyTargetMatchesPreparedHandshakeOfferOrder() throws {
        let provider = CryptoProviderFactory.make(policy: .requirePQC)
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider,
            pqcOfferMode: .preferredSingle
        )

        XCTAssertEqual(
            P2PConnectionManager.preferredBootstrapRekeyTargetSuite(using: provider),
            preparation.offeredSuites.first
        )
    }

    func testP2PInboundPublishesConnectedStateOnlyAfterActualAuthorityDurableCommit() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let processStart = try XCTUnwrap(source.range(of: "private func processHandshakeFrame("))
        let processEnd = try XCTUnwrap(
            source.range(
                of: "private func ensureInboundRekeyDriverIfNeeded(",
                range: processStart.lowerBound..<source.endIndex
            )
        )
        let body = String(source[processStart.lowerBound..<processEnd.lowerBound])
        let commit = try XCTUnwrap(
            body.range(of: "persistedAuthority = try persistAuthenticatedRemoteAuthority(")
        )
        let sessionKeyPublish = try XCTUnwrap(body.range(of: "guard setSessionKeys("))
        let sessionAuthorityInstall = try XCTUnwrap(
            body.range(of: "try installSessionPairingAuthority(")
        )
        let connectedPublish = try XCTUnwrap(body.range(of: "connectionStatusByDeviceId[peerId] = .connected"))
        let heartbeatStart = try XCTUnwrap(body.range(of: "startHeartbeatIfNeeded(deviceId: peerId)"))

        XCTAssertLessThan(commit.lowerBound, sessionKeyPublish.lowerBound)
        XCTAssertLessThan(sessionKeyPublish.lowerBound, sessionAuthorityInstall.lowerBound)
        XCTAssertLessThan(sessionAuthorityInstall.lowerBound, connectedPublish.lowerBound)
        XCTAssertLessThan(commit.lowerBound, connectedPublish.lowerBound)
        XCTAssertLessThan(commit.lowerBound, heartbeatStart.lowerBound)
        XCTAssertFalse(
            body.contains("finishProvisionalInboundConnection("),
            "The handshake worker must not release admission before its caller observes an active authenticated session."
        )
        XCTAssertTrue(body.contains("cleanupBrokenInboundConnection("))
        XCTAssertFalse(
            body.contains("await transport?.removeConnection(for: peerId)"),
            "Late failure cleanup must not broadly remove a replacement transport connection."
        )

        let inboundStart = try XCTUnwrap(source.range(of: "private func handleIncomingConnection("))
        let inboundEnd = try XCTUnwrap(
            source.range(
                of: "/// 开始从连接接收消息",
                range: inboundStart.lowerBound..<source.endIndex
            )
        )
        let inboundBody = String(source[inboundStart.lowerBound..<inboundEnd.lowerBound])
        let messageHandling = try XCTUnwrap(
            inboundBody.range(of: "await handleReceivedMessage(")
        )
        let authenticatedSessionGate = try XCTUnwrap(
            inboundBody.range(
                of: "hasActiveAuthenticatedSession(for: canonicalPeerId)",
                range: messageHandling.upperBound..<inboundBody.endIndex
            )
        )
        let exactAdmissionRelease = try XCTUnwrap(
            inboundBody.range(
                of: "finishProvisionalInboundConnection(",
                range: authenticatedSessionGate.upperBound..<inboundBody.endIndex
            )
        )

        XCTAssertLessThan(messageHandling.lowerBound, authenticatedSessionGate.lowerBound)
        XCTAssertLessThan(authenticatedSessionGate.lowerBound, exactAdmissionRelease.lowerBound)
        XCTAssertTrue(
            inboundBody[exactAdmissionRelease.lowerBound...].contains("ifOwnedBy: processingLease")
        )
    }

    func testP2POutboundCapturesActualAuthorityBeforePublishingHandshakeKeys() throws {
        let source = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let start = try XCTUnwrap(source.range(of: "private func performPQCHandshake("))
        let end = try XCTUnwrap(
            source.range(of: "public func rekeyToPreferPQC(", range: start.lowerBound..<source.endIndex)
        )
        let body = String(source[start.lowerBound..<end.lowerBound])
        let commit = try XCTUnwrap(
            body.range(of: "persistedAuthority = try persistAuthenticatedRemoteAuthority(")
        )
        let sessionKeyPublish = try XCTUnwrap(body.range(of: "guard setSessionKeys("))

        XCTAssertLessThan(commit.lowerBound, sessionKeyPublish.lowerBound)
        XCTAssertFalse(
            body.contains("expectedStableDeviceId:"),
            "A peer-claimed stable id must not select the durable authority row."
        )
        XCTAssertTrue(body.contains("if let publishedSessionId"))
        XCTAssertTrue(
            body.contains(
                "sessionKeyConnectionGenerationByPeerId[peerId]"
            )
        )
        XCTAssertTrue(body.contains("sessionKeys[peerId]?.sessionId == publishedSessionId"))
        XCTAssertTrue(body.contains("cleanupBrokenInboundConnection("))
        XCTAssertFalse(
            body.contains("await transport?.removeConnection(for: device.id)"),
            "Rekey failure cleanup must remain bound to the exact failed connection."
        )

        let authorityHelperStart = try XCTUnwrap(
            source.range(of: "private func persistAuthenticatedRemoteAuthority(")
        )
        let authorityHelperEnd = try XCTUnwrap(
            source.range(of: "private func restoreActiveSessionAfterRekeyFailure(", range: authorityHelperStart.lowerBound..<source.endIndex)
        )
        let authorityHelper = String(source[authorityHelperStart.lowerBound..<authorityHelperEnd.lowerBound])
        XCTAssertTrue(
            source.contains("driver.getAuthenticatedHandshakePeerBinding()")
        )
        XCTAssertTrue(
            authorityHelper.contains("uniqueExactActiveProtocolIdentityAuthorityDeviceId(")
        )
        XCTAssertTrue(authorityHelper.contains("protocolSigningAlgorithm: authority.protocolSigningAlgorithm"))
        XCTAssertTrue(authorityHelper.contains("protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint"))
    }

    func testPairingVerificationCodeIsDeterministicAndTranscriptBound() {
        let firstTranscript = Data(repeating: 0x31, count: 32)
        let secondTranscript = Data(repeating: 0x32, count: 32)

        let first = P2PConnectionManager.pairingVerificationCode(
            transcriptHash: firstTranscript
        )
        let repeated = P2PConnectionManager.pairingVerificationCode(
            transcriptHash: firstTranscript
        )
        let second = P2PConnectionManager.pairingVerificationCode(
            transcriptHash: secondTranscript
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 6)
        XCTAssertTrue(first.allSatisfy(\.isNumber))
    }

    func testManualSASApprovalConsumesOneExactAuthenticatedAuthority() throws {
        let manager = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let approvalStart = try XCTUnwrap(
            manager.range(of: "public func approveCurrentAuthenticatedSessionTrust(")
        )
        let approvalEnd = try XCTUnwrap(
            manager.range(
                of: "private enum SessionTrustApprovalError",
                range: approvalStart.upperBound..<manager.endIndex
            )
        )
        let approval = String(
            manager[approvalStart.lowerBound..<approvalEnd.lowerBound]
        )

        XCTAssertTrue(approval.contains("exactAuthenticatedSessionForStableDeviceIdentifier("))
        XCTAssertTrue(approval.contains("requireCurrentAuthenticatedConnection(current.receipt)"))
        XCTAssertTrue(approval.contains("sessionPairingAuthorityByPeerId[current.peerId]"))
        XCTAssertTrue(approval.contains("protocolPublicKeyBytes"))
        XCTAssertTrue(approval.contains("upsertAuthorityBound("))
        XCTAssertTrue(approval.contains("recordApprovedProtocolIdentityBinding("))
        XCTAssertTrue(approval.contains("rollbackAuthorityBoundMutation("))
        XCTAssertFalse(approval.contains("lookupCandidates("))
        XCTAssertFalse(approval.contains("currentAuthenticatedSession("))
        XCTAssertFalse(approval.contains("trustedFingerprints("))

        let protocolProjection = try XCTUnwrap(
            approval.range(of: ".upsertAuthorityBound(")
        )
        let postAwaitReceiptCheck = try XCTUnwrap(
            approval.range(
                of: "try requireCurrentAuthenticatedConnection(current.receipt)",
                range: protocolProjection.upperBound..<approval.endIndex
            )
        )
        let durableActivation = try XCTUnwrap(
            approval.range(of: "recordApprovedProtocolIdentityBinding(")
        )
        XCTAssertLessThan(protocolProjection.lowerBound, postAwaitReceiptCheck.lowerBound)
        XCTAssertLessThan(postAwaitReceiptCheck.lowerBound, durableActivation.lowerBound)

        let cryptoManager = try readRepositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/PQCCryptoManager.swift"
        )
        let verifyStart = try XCTUnwrap(
            cryptoManager.range(of: "public func verifyDevice(")
        )
        let verifyEnd = try XCTUnwrap(
            cryptoManager.range(
                of: "public var providerInfo",
                range: verifyStart.upperBound..<cryptoManager.endIndex
            )
        )
        let verify = String(cryptoManager[verifyStart.lowerBound..<verifyEnd.lowerBound])
        XCTAssertTrue(verify.contains("approveCurrentAuthenticatedSessionTrust("))
        XCTAssertFalse(verify.contains("lookupCandidates("))
        XCTAssertFalse(verify.contains("trustedFingerprints("))
        XCTAssertFalse(verify.contains("trustResolvedPeer("))
    }
}
