import XCTest
import CryptoKit
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class SignedKEMRefreshPayloadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let protocolPublicKey = Data(repeating: 0x33, count: 1184)
    private var fingerprint: String {
        ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
    }

    func testRequestCanonicalHashIsStableAcrossSuiteOrdering() {
        let nonce = Data(repeating: 0x44, count: 24)
        let left = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: " ios-1 ",
            targetDeviceId: "mac-1",
            requesterProtocolIdentityFingerprint: fingerprint.uppercased(),
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.mlkem768MLDSA65.wireId, CryptoSuite.xwingMLDSA.wireId],
            nonce: nonce,
            sentAt: now
        )
        let right = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: " ios-1 ",
            targetDeviceId: "mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint.uppercased(),
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId, CryptoSuite.mlkem768MLDSA65.wireId],
            nonce: nonce,
            sentAt: now
        )

        XCTAssertEqual(left.canonicalRequestHashHex, right.canonicalRequestHashHex)
        XCTAssertEqual(left.policyHashHex, left.expectedPolicyHashHex)
        XCTAssertTrue(left.hasExpectedPolicyHash)
        XCTAssertTrue(left.hasRequesterProtocolIdentityFingerprint)
        let preimage = String(data: left.canonicalPreimage, encoding: .utf8) ?? ""
        XCTAssertTrue(preimage.contains("requesterProtocolIdentityFingerprint=\(fingerprint.lowercased())"))
        XCTAssertTrue(preimage.contains("policyAllowClassicFallback=0"))
        XCTAssertTrue(preimage.contains("policyHashHex=\(left.expectedPolicyHashHex)"))

        let tamperedPolicyHash = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: " ios-1 ",
            targetDeviceId: "mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId, CryptoSuite.mlkem768MLDSA65.wireId],
            policyHashHex: String(repeating: "0", count: 64),
            nonce: nonce,
            sentAt: now
        )
        XCTAssertFalse(tamperedPolicyHash.hasExpectedPolicyHash)
        XCTAssertNotEqual(tamperedPolicyHash.canonicalRequestHashHex, left.canonicalRequestHashHex)

        let missingRequesterIdentity = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: " ios-1 ",
            targetDeviceId: "mac-1",
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId, CryptoSuite.mlkem768MLDSA65.wireId],
            nonce: nonce,
            sentAt: now
        )
        XCTAssertFalse(missingRequesterIdentity.hasRequesterProtocolIdentityFingerprint)
    }

    func testKEMRefreshRequestStrictResponderValidationRejectsStaleEmptyAndClassicSuites() throws {
        let valid = validKEMRefreshRequest()
        XCTAssertEqual(
            try valid.validatedStrictResponderSuites(now: now).map(\.wireId),
            [CryptoSuite.xwingMLDSA.wireId]
        )

        let emptySuites = validKEMRefreshRequest(requestedSuiteWireIds: [])
        XCTAssertThrowsError(try emptySuites.validatedStrictResponderSuites(now: now)) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .missingRequestedSuite)
        }

        let expired = validKEMRefreshRequest(sentAt: now.addingTimeInterval(-121))
        XCTAssertThrowsError(try expired.validatedStrictResponderSuites(now: now)) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestExpired)
        }

        let future = validKEMRefreshRequest(sentAt: now.addingTimeInterval(31))
        XCTAssertThrowsError(try future.validatedStrictResponderSuites(now: now)) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestFromFuture)
        }

        let classic = validKEMRefreshRequest(requestedSuiteWireIds: [CryptoSuite.x25519Ed25519.wireId])
        XCTAssertThrowsError(try classic.validatedStrictResponderSuites(now: now)) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .classicSuiteRejected(wireId: CryptoSuite.x25519Ed25519.wireId))
        }

        for wireId in [UInt16(0x0000), UInt16(0xFFFF)] {
            let unknownSuite = validKEMRefreshRequest(requestedSuiteWireIds: [wireId])
            XCTAssertThrowsError(try unknownSuite.validatedStrictResponderSuites(now: now)) { error in
                XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .unknownSuite(wireId: wireId))
            }

            let mixedUnknownSuite = validKEMRefreshRequest(
                requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId, wireId]
            )
            XCTAssertThrowsError(try mixedUnknownSuite.validatedStrictResponderSuites(now: now)) { error in
                XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .unknownSuite(wireId: wireId))
            }
        }
    }

    func testMacResponderRejectsSignedLANRefreshBadPolicyAndUnpinnedRequester() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService+BootstrapControl.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("request.validatedStrictResponderSuites()"))
        XCTAssertTrue(source.contains("policy_hash_mismatch"))
        XCTAssertTrue(source.contains("guard request.requesterProtocolIdentityFingerprint != nil else"))
        XCTAssertTrue(source.contains("requester protocol identity fingerprint missing"))
        XCTAssertTrue(source.contains("missing_requester_protocol_identity"))
        XCTAssertTrue(source.contains("requester protocol identity fingerprint invalid"))
        XCTAssertTrue(source.contains("invalid_requester_protocol_identity"))
        XCTAssertTrue(source.contains("requester protocol identity fingerprint not pinned"))
        XCTAssertTrue(source.contains("requester_protocol_identity_not_pinned"))
        XCTAssertTrue(source.contains("target protocol identity fingerprint invalid"))
        XCTAssertTrue(source.contains("invalid_target_protocol_identity"))
        XCTAssertTrue(source.contains("request replay detected"))
        XCTAssertTrue(source.contains("request_replay_detected"))
        XCTAssertTrue(source.contains("requester rate limited"))
        XCTAssertTrue(source.contains("requester_rate_limited"))
        XCTAssertTrue(source.contains("missing_requested_suite"))
        XCTAssertTrue(source.contains("limitingTo: requestedSuites"))
        XCTAssertTrue(source.contains("responderLatencyMs="))
    }

    func testMacResponderSignedLANRefreshFailsFastBeforeHandshakeFallback() async throws {
        let store = PeerProtocolIdentityBootstrapStore.shared
        await store.clearForTesting()
        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()

        let unknownSuite = validKEMRefreshRequest(
            requestedSuiteWireIds: [UInt16(0x0000)],
            sentAt: Date()
        )
        do {
            _ = try await P2PDiscoveryService.makeSignedKEMRefreshPayload(for: unknownSuite)
            XCTFail("Unknown SKR-1 suite must fail fast before any handshake continuation")
        } catch {
            XCTAssertEqual(P2PDiscoveryService.signedKEMRefreshFailureCode(for: error), "unknown_suite")
            XCTAssertTrue(error.localizedDescription.lowercased().contains("unknown suite"))
        }

        let unpinnedRequester = validKEMRefreshRequest(sentAt: Date())
        do {
            _ = try await P2PDiscoveryService.makeSignedKEMRefreshPayload(for: unpinnedRequester)
            XCTFail("SKR-1 must not serve KEM material to an unpinned requester identity")
        } catch {
            XCTAssertEqual(
                P2PDiscoveryService.signedKEMRefreshFailureCode(for: error),
                "requester_protocol_identity_not_pinned"
            )
            XCTAssertTrue(error.localizedDescription.contains("requester protocol identity fingerprint not pinned"))
        }

        await store.clearForTesting()
        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()
    }

    func testMacResponderSignedLANRefreshRejectsTargetMismatchReplayAndRateLimitBeforeSuccess() async throws {
        let store = PeerProtocolIdentityBootstrapStore.shared
        await store.clearForTesting()
        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()
        await store.upsert(deviceIds: ["id:ios-1"], fingerprints: [fingerprint])

        let mismatchedTarget = String(repeating: "a", count: 64)
        let first = validKEMRefreshRequest(
            targetProtocolIdentityFingerprint: mismatchedTarget,
            sentAt: Date()
        )
        do {
            _ = try await P2PDiscoveryService.makeSignedKEMRefreshPayload(for: first)
            XCTFail("A target protocol identity mismatch must not serve KEM material")
        } catch {
            XCTAssertEqual(
                P2PDiscoveryService.signedKEMRefreshFailureCode(for: error),
                "pinned_protocol_identity_mismatch_requires_oob"
            )
        }

        do {
            _ = try await P2PDiscoveryService.makeSignedKEMRefreshPayload(for: first)
            XCTFail("A repeated SKR-1 request hash must be rejected as replay")
        } catch {
            XCTAssertEqual(
                P2PDiscoveryService.signedKEMRefreshFailureCode(for: error),
                "request_replay_detected"
            )
        }

        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()
        for index in 0..<10 {
            let request = validKEMRefreshRequest(
                nonce: Data(repeating: UInt8(index + 1), count: 24),
                targetProtocolIdentityFingerprint: mismatchedTarget,
                sentAt: Date()
            )
            do {
                _ = try await P2PDiscoveryService.makeSignedKEMRefreshPayload(for: request)
                XCTFail("Target mismatch request \(index) must not serve KEM material")
            } catch {
                XCTAssertEqual(
                    P2PDiscoveryService.signedKEMRefreshFailureCode(for: error),
                    "pinned_protocol_identity_mismatch_requires_oob"
                )
            }
        }

        let rateLimited = validKEMRefreshRequest(
            nonce: Data(repeating: 0x7f, count: 24),
            targetProtocolIdentityFingerprint: mismatchedTarget,
            sentAt: Date()
        )
        do {
            _ = try await P2PDiscoveryService.makeSignedKEMRefreshPayload(for: rateLimited)
            XCTFail("SKR-1 responder must rate-limit repeated requester refresh attempts")
        } catch {
            XCTAssertEqual(
                P2PDiscoveryService.signedKEMRefreshFailureCode(for: error),
                "requester_rate_limited"
            )
        }

        await store.clearForTesting()
        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()
    }

    func testMacResponderProtocolIdentityBindingFailsFastOnNonStrictPolicy() async throws {
        let fallbackAllowed = AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requestedProtocolSigningAlgorithms: [
                ProtocolSigningAlgorithm.mlDSA65.rawValue,
                ProtocolSigningAlgorithm.ed25519.rawValue
            ],
            policyRequirePQC: true,
            policyAllowClassicFallback: true,
            routeScope: "lan",
            bonjourEndpointDigest: String(repeating: "c", count: 64),
            nonce: Data(repeating: 0x66, count: 24),
            sentAt: Date()
        )

        do {
            _ = try await P2PDiscoveryService.makeSignedProtocolIdentityBindingPayload(for: fallbackAllowed)
            XCTFail("PIB-1 must reject non-strict policy before serving identity binding")
        } catch {
            XCTAssertEqual(P2PDiscoveryService.protocolIdentityBindingFailureCode(for: error), "policy_mismatch")
            XCTAssertTrue(error.localizedDescription.contains("policy mismatch"))
        }
    }

    func testSignedKEMRefreshAdmissionGateRejectsReplayAndRateLimit() async {
        let gate = SignedKEMRefreshRequestAdmissionGate(
            ttl: 300,
            rateLimitWindow: 60,
            maxRequestsPerWindow: 2,
            maxEntries: 32
        )

        let requester = "id:ios-1"
        let requesterFingerprint = fingerprint.lowercased()
        let firstAdmission = await gate.admit(
            requestHashHex: String(repeating: "a", count: 64),
            requesterDeviceId: requester,
            requesterFingerprint: requesterFingerprint,
            now: 10
        )
        XCTAssertEqual(firstAdmission, .allowed)

        let replayAdmission = await gate.admit(
            requestHashHex: String(repeating: "a", count: 64),
            requesterDeviceId: requester,
            requesterFingerprint: requesterFingerprint,
            now: 11
        )
        XCTAssertEqual(replayAdmission, .replay)

        let secondAdmission = await gate.admit(
            requestHashHex: String(repeating: "b", count: 64),
            requesterDeviceId: requester,
            requesterFingerprint: requesterFingerprint,
            now: 12
        )
        XCTAssertEqual(secondAdmission, .allowed)

        let rateLimitedAdmission = await gate.admit(
            requestHashHex: String(repeating: "c", count: 64),
            requesterDeviceId: requester,
            requesterFingerprint: requesterFingerprint,
            now: 13
        )
        XCTAssertEqual(rateLimitedAdmission, .rateLimited)
    }

    func testSignaturePreimageNormalizesAliasesAndExcludesSignatureBytes() throws {
        let payloadA = validPayload(
            aliases: [" id:mac-1 ", "bonjour:mac@local.", "id:mac-1"],
            signature: Data(repeating: 0x11, count: 64)
        )
        let payloadB = validPayload(
            aliases: ["bonjour:mac@local.", "id:mac-1"],
            signature: Data(repeating: 0x22, count: 64)
        )

        XCTAssertEqual(payloadA.signaturePreimage, payloadB.signaturePreimage)
        let preimage = try XCTUnwrap(String(data: payloadA.signaturePreimage, encoding: .utf8))
        XCTAssertTrue(preimage.contains("domain=SkyBridge-SKR-1-SignedKEMRefresh"))
        XCTAssertTrue(preimage.contains("aliases=bonjour:mac@local.,id:mac-1"))
        XCTAssertTrue(preimage.contains("suiteNames=X-Wing"))
        XCTAssertTrue(preimage.contains("suiteWireIds=0x0001"))
        XCTAssertTrue(preimage.contains("kemPublicKeyHash="))
        XCTAssertTrue(preimage.contains("keyId=skr-1"))
        XCTAssertTrue(preimage.contains("generation=7"))
        XCTAssertTrue(preimage.contains("requestNonce="))
        XCTAssertTrue(preimage.contains("requestHashHex=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
        XCTAssertTrue(preimage.contains("policyRequirePQC=1"))
        XCTAssertTrue(preimage.contains("policyAllowClassicFallback=0"))
        XCTAssertTrue(preimage.contains("routeScope=lan"))
        XCTAssertTrue(preimage.contains("bonjourEndpointDigest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"))
    }

    func testStrictImportAcceptsPinnedXWingRefresh() throws {
        let validated = try validPayload().validatedForStrictPQCImport(
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )

        XCTAssertEqual(validated.deviceId, "id:mac-1")
        XCTAssertEqual(validated.protocolIdentityFingerprint, fingerprint)
        XCTAssertEqual(validated.kemPublicKeys.map(\.suiteWireId), [CryptoSuite.xwingMLDSA.wireId])
    }

    func testStrictImportBindsOriginalKEMRefreshRequest() throws {
        let request = validKEMRefreshRequest()
        let payload = validPayload(
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex
        )

        let validated = try payload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )
        XCTAssertEqual(validated.requestHashHex, request.canonicalRequestHashHex)

        let unrequestedSuite = validPayload(
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                    publicKey: Data(repeating: 0x66, count: 1184)
                )
            ],
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex
        )
        XCTAssertThrowsError(try unrequestedSuite.validatedForStrictPQCImport(
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

        let wrongNonce = validPayload(
            requestNonce: Data(repeating: 0x45, count: 24),
            requestHashHex: request.canonicalRequestHashHex
        )
        XCTAssertThrowsError(try wrongNonce.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestNonceMismatch)
        }

        let wrongTargetDevice = AppMessage.SignedKEMRefreshPayload(
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
        XCTAssertThrowsError(try wrongTargetDevice.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .targetDeviceIdMismatch)
        }

        let wrongHash = validPayload(
            requestNonce: request.nonce,
            requestHashHex: String(repeating: "e", count: 64)
        )
        XCTAssertThrowsError(try wrongHash.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestHashMismatch)
        }

        let tamperedPolicyHashRequest = validKEMRefreshRequest(
            policyHashHex: String(repeating: "0", count: 64)
        )
        let tamperedPolicyPayload = validPayload(
            requestNonce: tamperedPolicyHashRequest.nonce,
            requestHashHex: tamperedPolicyHashRequest.canonicalRequestHashHex
        )
        XCTAssertThrowsError(try tamperedPolicyPayload.validatedForStrictPQCImport(
            request: tamperedPolicyHashRequest,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .requestPolicyHashMismatch)
        }
    }

    func testStrictImportRejectsUnknownSuiteWireIds() {
        for wireId in [UInt16(0x0000), UInt16(0xFFFF)] {
            let payload = validPayload(kemPublicKeys: [
                KEMPublicKeyInfo(suiteWireId: wireId, publicKey: Data(repeating: 0x55, count: 1216))
            ])

            XCTAssertThrowsError(try payload.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
                XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .unknownSuite(wireId: wireId))
            }
        }
    }

    func testStrictImportRejectsMissingSignatureAndEmptyKEMPublicKeys() {
        let unsigned = validPayload(signature: Data())
        XCTAssertThrowsError(try unsigned.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .missingSignature)
        }

        let emptyKEM = validPayload(kemPublicKeys: [])
        XCTAssertThrowsError(try emptyKEM.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .missingKEMPublicKey)
        }
    }

    func testStrictImportRejectsClassicSuiteAndBadKEMLength() {
        let classic = validPayload(kemPublicKeys: [
            KEMPublicKeyInfo(suiteWireId: CryptoSuite.x25519Ed25519.wireId, publicKey: Data(repeating: 0x55, count: 32))
        ])
        XCTAssertThrowsError(try classic.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .classicSuiteRejected(wireId: CryptoSuite.x25519Ed25519.wireId))
        }

        let shortXWing = validPayload(kemPublicKeys: [
            KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwingMLDSA.wireId, publicKey: Data(repeating: 0x55, count: 32))
        ])
        XCTAssertThrowsError(try shortXWing.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .invalidKEMPublicKeyLength(wireId: CryptoSuite.xwingMLDSA.wireId, expected: 1216, actual: 32)
            )
        }
    }

    func testStrictImportRejectsMissingPinnedIdentityPolicyMismatchAndRollback() {
        XCTAssertThrowsError(try validPayload().validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [])) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .missingPinnedProtocolIdentity)
        }

        let wrongFingerprint = validPayload(protocolIdentityFingerprint: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try wrongFingerprint.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .invalidProtocolIdentityFingerprint)
        }

        let otherProtocolPublicKey = Data(repeating: 0x34, count: 1184)
        let otherFingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: otherProtocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
        let unpinnedIdentity = validPayload(
            protocolIdentityPublicKey: otherProtocolPublicKey,
            protocolIdentityFingerprint: otherFingerprint
        )
        XCTAssertThrowsError(try unpinnedIdentity.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .pinnedProtocolIdentityMismatch(fingerprint: otherFingerprint.lowercased())
            )
        }

        let fallbackAllowed = validPayload(policyAllowClassicFallback: true)
        XCTAssertThrowsError(try fallbackAllowed.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .policyMismatch)
        }

        XCTAssertThrowsError(try validPayload(generation: 6).validatedForStrictPQCImport(
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 7
        )) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .generationRollback(current: 7, incoming: 6))
        }
    }

    func testStrictImportRejectsExpiredRefreshAndShortNonce() {
        let expired = validPayload(
            sentAt: now.addingTimeInterval(-300),
            expiresAt: now.addingTimeInterval(-1)
        )
        XCTAssertThrowsError(try expired.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .expired)
        }

        let shortNonce = validPayload(requestNonce: Data(repeating: 0x01, count: 8))
        XCTAssertThrowsError(try shortNonce.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .invalidRequestNonce)
        }
    }

    func testStrictImportRejectsCanonicalDelimiterInjection() {
        let badDeviceId = AppMessage.SignedKEMRefreshPayload(
            deviceId: "id:mac-1\npolicyAllowClassicFallback=1",
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
            requestNonce: Data(repeating: 0x44, count: 24),
            requestHashHex: String(repeating: "b", count: 64),
            signature: Data(repeating: 0x99, count: 64)
        )
        XCTAssertThrowsError(try badDeviceId.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .invalidDeviceId)
        }

        let badKeyId = validPayload()
        let mutatedKeyId = AppMessage.SignedKEMRefreshPayload(
            deviceId: badKeyId.deviceId,
            aliases: badKeyId.aliases,
            protocolSigningAlgorithm: badKeyId.protocolSigningAlgorithm,
            protocolIdentityPublicKey: badKeyId.protocolIdentityPublicKey,
            protocolIdentityFingerprint: badKeyId.protocolIdentityFingerprint,
            kemPublicKeys: badKeyId.kemPublicKeys,
            keyId: "skr-1=forged",
            generation: badKeyId.generation,
            sentAt: badKeyId.sentAt,
            expiresAt: badKeyId.expiresAt,
            requestNonce: badKeyId.requestNonce,
            requestHashHex: badKeyId.requestHashHex,
            signature: badKeyId.signature
        )
        XCTAssertThrowsError(try mutatedKeyId.validatedForStrictPQCImport(now: now, pinnedProtocolFingerprints: [fingerprint])) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .invalidKeyId)
        }
    }

    func testSignedRefreshSignatureRejectsTamperedPreimageBeforeImport() async throws {
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

        let wrongSigningKey = Curve25519.Signing.PrivateKey()
        let wrongKeyVerification = try await provider.verify(
            signed.signaturePreimage,
            signature: signed.signature,
            publicKey: wrongSigningKey.publicKey.rawRepresentation
        )
        XCTAssertFalse(wrongKeyVerification)
    }

    func testKEMRefreshFailureRoundTripsAsDiagnosticOnly() throws {
        let failure = AppMessage.KEMRefreshFailurePayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            stage: "kem_refresh",
            reasonCode: "pinned_protocol_identity_mismatch_requires_oob",
            reason: "target protocol identity fingerprint mismatch",
            requestHashHex: String(repeating: "d", count: 64),
            sentAt: now
        )

        let encoded = try JSONEncoder().encode(AppMessage.kemRefreshFailure(failure))
        let decoded = try JSONDecoder().decode(AppMessage.self, from: encoded)
        guard case .kemRefreshFailure(let roundTripped) = decoded else {
            return XCTFail("Expected kemRefreshFailure diagnostic response")
        }

        XCTAssertEqual(roundTripped.reasonCode, "pinned_protocol_identity_mismatch_requires_oob")
        XCTAssertEqual(roundTripped.stage, "kem_refresh")
        XCTAssertEqual(roundTripped.requestHashHex, String(repeating: "d", count: 64))
    }

    func testProtocolIdentityBindingRoundTripsAndProducesStableSAS() throws {
        let request = validProtocolIdentityBindingRequest()
        let payload = validProtocolIdentityBindingPayload(request: request)

        let validated = try payload.validatedForOOBBinding(request: request, now: now)
        XCTAssertEqual(validated.protocolIdentityFingerprint, fingerprint)
        XCTAssertEqual(validated.requestHashHex, request.canonicalRequestHashHex)

        let code = validated.shortAuthenticationCode(request: request)
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        XCTAssertEqual(code, payload.shortAuthenticationCode(request: request))

        let encoded = try JSONEncoder().encode(AppMessage.signedProtocolIdentityBinding(payload))
        let decoded = try JSONDecoder().decode(AppMessage.self, from: encoded)
        guard case .signedProtocolIdentityBinding(let roundTripped) = decoded else {
            return XCTFail("Expected signedProtocolIdentityBinding")
        }
        XCTAssertEqual(roundTripped.protocolIdentityFingerprint, payload.protocolIdentityFingerprint)
        XCTAssertEqual(roundTripped.signaturePreimage, payload.signaturePreimage)
    }

    func testProtocolIdentityBindingRequestRequiresRequesterProofAndBindsItIntoSAS() throws {
        let missingProof = AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requestedProtocolSigningAlgorithms: [ProtocolSigningAlgorithm.mlDSA65.rawValue],
            bonjourEndpointDigest: String(repeating: "a", count: 64),
            nonce: Data(repeating: 0x66, count: 24),
            sentAt: now
        )
        XCTAssertThrowsError(try missingProof.validatedRequesterProtocolIdentity()) { error in
            XCTAssertEqual(error as? AppMessage.ProtocolIdentityBindingValidationError, .missingRequesterProtocolIdentity)
        }

        let request = validProtocolIdentityBindingRequest()
        let requesterIdentity = try request.validatedRequesterProtocolIdentity()
        XCTAssertEqual(requesterIdentity.authoritativeFingerprint, fingerprint.lowercased())
        let preimage = String(data: request.canonicalPreimage, encoding: .utf8) ?? ""
        XCTAssertTrue(preimage.contains("requesterProtocolSigningAlgorithm=ML-DSA-65"))
        XCTAssertTrue(preimage.contains("requesterProtocolIdentityFingerprint=\(fingerprint.lowercased())"))

        let payload = validProtocolIdentityBindingPayload(request: request)
        let code = payload.shortAuthenticationCode(request: request)
        let mutatedRequesterSignature = validProtocolIdentityBindingRequest(
            requesterSignature: Data(repeating: 0x78, count: 64)
        )
        XCTAssertNotEqual(code, payload.shortAuthenticationCode(request: mutatedRequesterSignature))
    }

    func testProtocolIdentityBindingRejectsRequestHashMismatchAndFallbackPolicy() {
        let request = validProtocolIdentityBindingRequest()
        let wrongHash = validProtocolIdentityBindingPayload(
            request: request,
            requestHashHex: String(repeating: "e", count: 64)
        )
        XCTAssertThrowsError(try wrongHash.validatedForOOBBinding(request: request, now: now)) { error in
            XCTAssertEqual(error as? AppMessage.ProtocolIdentityBindingValidationError, .requestHashMismatch)
        }

        let fallbackAllowed = validProtocolIdentityBindingPayload(
            request: request,
            policyAllowClassicFallback: true
        )
        XCTAssertThrowsError(try fallbackAllowed.validatedForOOBBinding(request: request, now: now)) { error in
            XCTAssertEqual(error as? AppMessage.ProtocolIdentityBindingValidationError, .policyMismatch)
        }

        let wrongTarget = AppMessage.SignedProtocolIdentityBindingPayload(
            deviceId: "id:other-mac",
            aliases: ["bonjour:other-mac@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: fingerprint.uppercased(),
            deviceName: "Other Mac",
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            routeScope: "lan",
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data(repeating: 0x77, count: 64)
        )
        XCTAssertThrowsError(try wrongTarget.validatedForOOBBinding(request: request, now: now)) { error in
            XCTAssertEqual(error as? AppMessage.ProtocolIdentityBindingValidationError, .targetDeviceIdMismatch)
        }
    }

    private func validPayload(
        aliases: [String] = ["id:mac-1"],
        kemPublicKeys: [KEMPublicKeyInfo]? = nil,
        generation: UInt64 = 7,
        protocolIdentityPublicKey: Data? = nil,
        protocolIdentityFingerprint: String? = nil,
        sentAt: Date? = nil,
        expiresAt: Date? = nil,
        requestNonce: Data = Data(repeating: 0x44, count: 24),
        requestHashHex: String = String(repeating: "b", count: 64),
        policyAllowClassicFallback: Bool = false,
        signature: Data = Data(repeating: 0x99, count: 64)
    ) -> AppMessage.SignedKEMRefreshPayload {
        AppMessage.SignedKEMRefreshPayload(
            deviceId: " id:mac-1 ",
            aliases: aliases,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolIdentityPublicKey ?? self.protocolPublicKey,
            protocolIdentityFingerprint: protocolIdentityFingerprint ?? fingerprint.uppercased(),
            kemPublicKeys: kemPublicKeys ?? [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x55, count: 1216)
                )
            ],
            keyId: "skr-1",
            generation: generation,
            sentAt: sentAt ?? now,
            expiresAt: expiresAt ?? now.addingTimeInterval(300),
            requestNonce: requestNonce,
            requestHashHex: requestHashHex,
            policyAllowClassicFallback: policyAllowClassicFallback,
            bonjourEndpointDigest: String(repeating: "c", count: 64),
            signature: signature
        )
    }

    private func validKEMRefreshRequest(
        nonce: Data = Data(repeating: 0x44, count: 24),
        policyHashHex: String? = nil,
        requestedSuiteWireIds: [UInt16] = [CryptoSuite.xwingMLDSA.wireId],
        targetProtocolIdentityFingerprint: String? = nil,
        sentAt: Date? = nil
    ) -> AppMessage.KEMRefreshRequestPayload {
        AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: " id:mac-1 ",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: targetProtocolIdentityFingerprint ?? fingerprint,
            requestedSuiteWireIds: requestedSuiteWireIds,
            policyHashHex: policyHashHex,
            bonjourEndpointDigest: String(repeating: "c", count: 64),
            nonce: nonce,
            sentAt: sentAt ?? now
        )
    }

    private func validProtocolIdentityBindingRequest(
        nonce: Data = Data(repeating: 0x66, count: 24),
        requesterSignature: Data = Data(repeating: 0x55, count: 64)
    ) -> AppMessage.ProtocolIdentityBindingRequestPayload {
        AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: " id:mac-1 ",
            requestedProtocolSigningAlgorithms: [
                ProtocolSigningAlgorithm.ed25519.rawValue,
                ProtocolSigningAlgorithm.mlDSA65.rawValue
            ],
            requesterProtocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            requesterProtocolIdentityPublicKey: protocolPublicKey,
            requesterProtocolIdentityFingerprint: fingerprint.uppercased(),
            requesterSignature: requesterSignature,
            bonjourEndpointDigest: String(repeating: "a", count: 64),
            nonce: nonce,
            sentAt: now
        )
    }

    private func validProtocolIdentityBindingPayload(
        request: AppMessage.ProtocolIdentityBindingRequestPayload,
        requestHashHex: String? = nil,
        policyAllowClassicFallback: Bool = false,
        signature: Data = Data(repeating: 0x77, count: 64)
    ) -> AppMessage.SignedProtocolIdentityBindingPayload {
        AppMessage.SignedProtocolIdentityBindingPayload(
            deviceId: " id:mac-1 ",
            aliases: ["id:mac-1", "bonjour:mac@local.", "id:mac-1"],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: fingerprint.uppercased(),
            deviceName: "MacBook",
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: requestHashHex ?? request.canonicalRequestHashHex,
            policyAllowClassicFallback: policyAllowClassicFallback,
            routeScope: "lan",
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: signature
        )
    }
}
