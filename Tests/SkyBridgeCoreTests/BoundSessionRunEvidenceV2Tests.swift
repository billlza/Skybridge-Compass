import Foundation
import SkyBridgeProtocolCore
import XCTest

@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class BoundSessionRunEvidenceV2Tests: XCTestCase {
    func testFrozenV2ClosureStatementsRegistriesAndPreimagesMatchByteForByte() throws {
        let vector = try loadFrozenVector()
        let closure = try BoundSessionClaimCriticalClosureEncoderV2.encode(makeClosureInput())
        XCTAssertEqual(closure.exactBytes, try decodeHex(vector["claim_closure_encoding"]))
        XCTAssertEqual(closure.sha256, try decodeHex(vector["claim_critical_closure_sha256"]))

        let registryA = try BoundSessionIdentityRegistryEncoderV2.encode(
            endpointIdentifier: "apple_endpoint",
            publicVerificationKey: Data(repeating: 0xA1, count: 1_952)
        )
        let registryB = try BoundSessionIdentityRegistryEncoderV2.encode(
            endpointIdentifier: "android_endpoint",
            publicVerificationKey: Data(repeating: 0xB2, count: 1_952)
        )
        XCTAssertEqual(registryA.exactBytes, try decodeHex(vector["registry_a"]))
        XCTAssertEqual(registryB.exactBytes, try decodeHex(vector["registry_b"]))
        XCTAssertEqual(registryA.endpointIdentifierDigest, try decodeHex(vector["endpoint_a_digest"]))
        XCTAssertEqual(registryB.endpointIdentifierDigest, try decodeHex(vector["endpoint_b_digest"]))
        XCTAssertEqual(registryA.identityFingerprint, try decodeHex(vector["identity_a_fingerprint"]))
        XCTAssertEqual(registryB.identityFingerprint, try decodeHex(vector["identity_b_fingerprint"]))

        let directions = makeDirections(
            initiatorIdentity: registryA.identityFingerprint,
            responderIdentity: registryB.identityFingerprint
        )
        let statementA = try BoundSessionRunStatementEncoderV2.encode(
            makeStatementInput(
                registry: registryA,
                closure: closure,
                productBase: 0x14,
                directions: directions
            )
        )
        let statementB = try BoundSessionRunStatementEncoderV2.encode(
            makeStatementInput(
                registry: registryB,
                closure: closure,
                productBase: 0x24,
                directions: directions
            )
        )
        XCTAssertEqual(statementA, try decodeHex(vector["statement_a"]))
        XCTAssertEqual(statementB, try decodeHex(vector["statement_b"]))
        XCTAssertEqual(
            try BoundSessionRunStatementEncoderV2.signaturePreimage(for: statementA),
            try decodeHex(vector["statement_a_preimage"])
        )
        XCTAssertEqual(
            try BoundSessionRunStatementEncoderV2.signaturePreimage(for: statementB),
            try decodeHex(vector["statement_b_preimage"])
        )

        XCTAssertEqual(statementA.count, 1_552)
        XCTAssertEqual(statementA.prefix(8), Data("BSRUNV2\0".utf8))
        XCTAssertEqual(statementA.subdata(in: 176..<208), closure.sha256)
        XCTAssertEqual(statementA.subdata(in: 372..<376), Data(repeating: 0, count: 4))
        XCTAssertEqual(statementA.subdata(in: 964..<968), Data(repeating: 0, count: 4))
        XCTAssertEqual(registryA.exactBytes.count, 2_064)
        XCTAssertEqual(registryA.exactBytes.prefix(8), Data("BSREGV2\0".utf8))
        XCTAssertEqual(registryA.exactBytes.suffix(32), Data(repeating: 0, count: 32))

        for kind in BoundSessionWebRTCRecordKindV1.allCases {
            XCTAssertThrowsError(
                try BoundSessionWebRTCCarrierPolicyV1.validateRecordEnvelope(
                    statementA,
                    expectedRecordKind: kind
                )
            )
            XCTAssertThrowsError(
                try BoundSessionWebRTCCarrierPolicyV1.validateRecordEnvelope(
                    registryA.exactBytes,
                    expectedRecordKind: kind
                )
            )
        }
    }

    func testClosureEncoderSortsSetsAndDescriptorsButRejectsExcludedOrAmbiguousInputs() throws {
        let canonical = makeClosureInput()
        let reordered = BoundSessionClaimCriticalClosureInputV2(
            evidenceIdentifier: canonical.evidenceIdentifier,
            evidenceClass: canonical.evidenceClass,
            claimEligible: canonical.claimEligible,
            relatedClaimIDs: Array(canonical.relatedClaimIDs.reversed()),
            claimedClaimIDs: Array(canonical.claimedClaimIDs.reversed()),
            runStartedAt: canonical.runStartedAt,
            runCompletedAt: canonical.runCompletedAt,
            cleanup: canonical.cleanup,
            endpoints: canonical.endpoints,
            unsupportedClaims: Array(canonical.unsupportedClaims.reversed()),
            limitations: canonical.limitations,
            preSignatureArtifacts: Array(canonical.preSignatureArtifacts.reversed())
        )
        XCTAssertEqual(
            try BoundSessionClaimCriticalClosureEncoderV2.encode(canonical),
            try BoundSessionClaimCriticalClosureEncoderV2.encode(reordered)
        )

        let postSignatureArtifact = replacingArtifacts(
            canonical,
            artifacts: [
                BoundSessionEvidenceArtifactDescriptorV2(
                    identifier: "statement",
                    kind: .runEvidenceStatement,
                    relativePath: "signed/statement.bin",
                    sha256: repeated(0x91),
                    sizeBytes: 1_552,
                    mediaType: "application/octet-stream"
                )
            ]
        )
        XCTAssertThrowsError(try BoundSessionClaimCriticalClosureEncoderV2.encode(postSignatureArtifact)) {
            XCTAssertEqual(
                $0 as? BoundSessionRunEvidenceV2Error,
                .excludedArtifactKind(.runEvidenceStatement)
            )
        }

        let reversedEndpoints = replacingEndpoints(
            canonical,
            endpoints: Array(canonical.endpoints.reversed())
        )
        XCTAssertThrowsError(try BoundSessionClaimCriticalClosureEncoderV2.encode(reversedEndpoints)) {
            XCTAssertEqual($0 as? BoundSessionRunEvidenceV2Error, .invalidEndpointOrder)
        }

        let duplicateLimitation = replacingLimitations(
            canonical,
            limitations: ["duplicate", "duplicate"]
        )
        XCTAssertThrowsError(try BoundSessionClaimCriticalClosureEncoderV2.encode(duplicateLimitation)) {
            XCTAssertEqual($0 as? BoundSessionRunEvidenceV2Error, .duplicateValue("limitation"))
        }

        XCTAssertThrowsError(
            try BoundSessionIdentityRegistryEncoderV2.encode(
                endpointIdentifier: "apple_endpoint",
                publicVerificationKey: Data(repeating: 0xA1, count: 1_951)
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundSessionRunEvidenceV2Error,
                .invalidIdentityPublicKeyLength(1_951)
            )
        }
    }

    func testStatementRejectsOpaqueHeaderMutationAndCrossDirectionAliases() throws {
        let closure = try BoundSessionClaimCriticalClosureEncoderV2.encode(makeClosureInput())
        let registryA = try BoundSessionIdentityRegistryEncoderV2.encode(
            endpointIdentifier: "apple_endpoint",
            publicVerificationKey: Data(repeating: 0xA1, count: 1_952)
        )
        let registryB = try BoundSessionIdentityRegistryEncoderV2.encode(
            endpointIdentifier: "android_endpoint",
            publicVerificationKey: Data(repeating: 0xB2, count: 1_952)
        )
        let directions = makeDirections(
            initiatorIdentity: registryA.identityFingerprint,
            responderIdentity: registryB.identityFingerprint
        )
        let validInput = makeStatementInput(
            registry: registryA,
            closure: closure,
            productBase: 0x14,
            directions: directions
        )
        let aliasedReverse = replacingDirection(
            directions.1,
            peerSessionID: directions.0.peerSessionID
        )
        let aliasedInput = replacingDirections(validInput, reverse: aliasedReverse)
        XCTAssertThrowsError(try BoundSessionRunStatementEncoderV2.encode(aliasedInput)) { error in
            XCTAssertEqual(
                error as? BoundSessionRunEvidenceV2Error,
                .duplicateDirectionEvidence("peer session ID")
            )
        }

        var statement = try BoundSessionRunStatementEncoderV2.encode(validInput)
        statement[7] = 0x31
        XCTAssertThrowsError(try BoundSessionRunStatementEncoderV2.signaturePreimage(for: statement)) {
            XCTAssertEqual($0 as? BoundSessionRunEvidenceV2Error, .invalidStatementHeader)
        }
    }

    private func makeClosureInput() -> BoundSessionClaimCriticalClosureInputV2 {
        BoundSessionClaimCriticalClosureInputV2(
            evidenceIdentifier: "physical-fixture-v2",
            evidenceClass: .physicalProductInterop,
            claimEligible: true,
            relatedClaimIDs: [.fileDurableReceipt, .nonAppleInterop],
            claimedClaimIDs: [.fileDurableReceipt, .nonAppleInterop],
            runStartedAt: "2026-08-30T10:00:00Z",
            runCompletedAt: "2026-08-30T11:00:00Z",
            cleanup: BoundSessionEvidenceCleanupProjectionV2(
                ownershipVerified: true,
                sessionTerminated: true,
                foreignResourcesTouched: false
            ),
            endpoints: [
                BoundSessionEvidenceEndpointDescriptorV2(
                    identifier: "apple_endpoint",
                    role: .initiator,
                    platform: .ios,
                    deviceClass: .phone,
                    executionEnvironment: .physicalDevice,
                    devicePseudonymSHA256: repeated(0x16)
                ),
                BoundSessionEvidenceEndpointDescriptorV2(
                    identifier: "android_endpoint",
                    role: .responder,
                    platform: .android,
                    deviceClass: .phone,
                    executionEnvironment: .physicalDevice,
                    devicePseudonymSHA256: repeated(0x26)
                ),
            ],
            unsupportedClaims: [
                BoundSessionEvidenceUnsupportedClaimV2(
                    feature: .messages,
                    reason: "fixture scope"
                ),
                BoundSessionEvidenceUnsupportedClaimV2(
                    feature: .remoteDesktop,
                    reason: "fixture scope"
                ),
            ],
            limitations: ["frozen fixture"],
            preSignatureArtifacts: [
                BoundSessionEvidenceArtifactDescriptorV2(
                    identifier: "android-device",
                    kind: .deviceRecord,
                    relativePath: "raw/android-device.json",
                    sha256: repeated(0x92),
                    sizeBytes: 223,
                    mediaType: "application/json"
                ),
                BoundSessionEvidenceArtifactDescriptorV2(
                    identifier: "apple-device",
                    kind: .deviceRecord,
                    relativePath: "raw/apple-device.json",
                    sha256: repeated(0x91),
                    sizeBytes: 211,
                    mediaType: "application/json"
                ),
            ]
        )
    }

    private func makeDirections(
        initiatorIdentity: Data,
        responderIdentity: Data
    ) -> (BoundSessionDirectionEvidenceV2, BoundSessionDirectionEvidenceV2) {
        (
            makeDirection(
                direction: .initiatorToResponder,
                base: 0x30,
                initiatorIdentity: initiatorIdentity,
                responderIdentity: responderIdentity,
                fileBytes: 17
            ),
            makeDirection(
                direction: .responderToInitiator,
                base: 0x70,
                initiatorIdentity: initiatorIdentity,
                responderIdentity: responderIdentity,
                fileBytes: 19
            )
        )
    }

    private func makeDirection(
        direction: BoundSessionEvidenceDirectionV2,
        base: UInt8,
        initiatorIdentity: Data,
        responderIdentity: Data,
        fileBytes: UInt64
    ) -> BoundSessionDirectionEvidenceV2 {
        BoundSessionDirectionEvidenceV2(
            direction: direction,
            peerSessionID: repeated(base),
            contextDigest: repeated(base &+ 1),
            transcriptDigest: repeated(base &+ 2),
            sharedGrantID: repeated(base &+ 3),
            bilateralReadyDigest: repeated(base &+ 4),
            policySHA3Digest: repeated(base &+ 5),
            policyRootKeyFingerprint: repeated(base &+ 6),
            wireDecisionDigest: repeated(base &+ 7),
            recipientKEMPublicKeyDigest: repeated(base &+ 8),
            initiatorIdentityFingerprint: initiatorIdentity,
            responderIdentityFingerprint: responderIdentity,
            messageAWireSHA256: repeated(base &+ 9),
            messageBWireSHA256: repeated(base &+ 10),
            transferID: repeated(base &+ 11),
            fileContentSHA256: repeated(base &+ 12),
            authorityOperationID: repeated(base &+ 13),
            durableFileEffectDigest: repeated(base &+ 14),
            effectReceiptWireSHA256: repeated(base &+ 15),
            positiveFileByteCount: fileBytes
        )
    }

    private func makeStatementInput(
        registry: BoundSessionEncodedIdentityRegistryV2,
        closure: BoundSessionEncodedClaimCriticalClosureV2,
        productBase: UInt8,
        directions: (BoundSessionDirectionEvidenceV2, BoundSessionDirectionEvidenceV2)
    ) -> BoundSessionRunStatementInputV2 {
        BoundSessionRunStatementInputV2(
            signerRegistry: registry,
            runBindingSHA256: repeated(0x11),
            transportBindingSHA256: repeated(0x12),
            researchSourceFreezeArtifactSHA256: repeated(0x13),
            claimCriticalClosure: closure,
            signerProductSourceIdentitySHA256: repeated(productBase),
            signerProductBinarySHA256: repeated(productBase &+ 1),
            signerDevicePseudonymSHA256: repeated(productBase &+ 2),
            signerJournalInstanceSHA256: repeated(productBase &+ 3),
            signerJournalFinalEventSHA256: repeated(productBase &+ 4),
            initiatorToResponder: directions.0,
            responderToInitiator: directions.1
        )
    }

    private func replacingArtifacts(
        _ input: BoundSessionClaimCriticalClosureInputV2,
        artifacts: [BoundSessionEvidenceArtifactDescriptorV2]
    ) -> BoundSessionClaimCriticalClosureInputV2 {
        BoundSessionClaimCriticalClosureInputV2(
            evidenceIdentifier: input.evidenceIdentifier,
            evidenceClass: input.evidenceClass,
            claimEligible: input.claimEligible,
            relatedClaimIDs: input.relatedClaimIDs,
            claimedClaimIDs: input.claimedClaimIDs,
            runStartedAt: input.runStartedAt,
            runCompletedAt: input.runCompletedAt,
            cleanup: input.cleanup,
            endpoints: input.endpoints,
            unsupportedClaims: input.unsupportedClaims,
            limitations: input.limitations,
            preSignatureArtifacts: artifacts
        )
    }

    private func replacingEndpoints(
        _ input: BoundSessionClaimCriticalClosureInputV2,
        endpoints: [BoundSessionEvidenceEndpointDescriptorV2]
    ) -> BoundSessionClaimCriticalClosureInputV2 {
        BoundSessionClaimCriticalClosureInputV2(
            evidenceIdentifier: input.evidenceIdentifier,
            evidenceClass: input.evidenceClass,
            claimEligible: input.claimEligible,
            relatedClaimIDs: input.relatedClaimIDs,
            claimedClaimIDs: input.claimedClaimIDs,
            runStartedAt: input.runStartedAt,
            runCompletedAt: input.runCompletedAt,
            cleanup: input.cleanup,
            endpoints: endpoints,
            unsupportedClaims: input.unsupportedClaims,
            limitations: input.limitations,
            preSignatureArtifacts: input.preSignatureArtifacts
        )
    }

    private func replacingLimitations(
        _ input: BoundSessionClaimCriticalClosureInputV2,
        limitations: [String]
    ) -> BoundSessionClaimCriticalClosureInputV2 {
        BoundSessionClaimCriticalClosureInputV2(
            evidenceIdentifier: input.evidenceIdentifier,
            evidenceClass: input.evidenceClass,
            claimEligible: input.claimEligible,
            relatedClaimIDs: input.relatedClaimIDs,
            claimedClaimIDs: input.claimedClaimIDs,
            runStartedAt: input.runStartedAt,
            runCompletedAt: input.runCompletedAt,
            cleanup: input.cleanup,
            endpoints: input.endpoints,
            unsupportedClaims: input.unsupportedClaims,
            limitations: limitations,
            preSignatureArtifacts: input.preSignatureArtifacts
        )
    }

    private func replacingDirections(
        _ input: BoundSessionRunStatementInputV2,
        reverse: BoundSessionDirectionEvidenceV2
    ) -> BoundSessionRunStatementInputV2 {
        BoundSessionRunStatementInputV2(
            signerRegistry: input.signerRegistry,
            runBindingSHA256: input.runBindingSHA256,
            transportBindingSHA256: input.transportBindingSHA256,
            researchSourceFreezeArtifactSHA256: input.researchSourceFreezeArtifactSHA256,
            claimCriticalClosure: input.claimCriticalClosure,
            signerProductSourceIdentitySHA256: input.signerProductSourceIdentitySHA256,
            signerProductBinarySHA256: input.signerProductBinarySHA256,
            signerDevicePseudonymSHA256: input.signerDevicePseudonymSHA256,
            signerJournalInstanceSHA256: input.signerJournalInstanceSHA256,
            signerJournalFinalEventSHA256: input.signerJournalFinalEventSHA256,
            initiatorToResponder: input.initiatorToResponder,
            responderToInitiator: reverse
        )
    }

    private func replacingDirection(
        _ input: BoundSessionDirectionEvidenceV2,
        peerSessionID: Data
    ) -> BoundSessionDirectionEvidenceV2 {
        BoundSessionDirectionEvidenceV2(
            direction: input.direction,
            peerSessionID: peerSessionID,
            contextDigest: input.contextDigest,
            transcriptDigest: input.transcriptDigest,
            sharedGrantID: input.sharedGrantID,
            bilateralReadyDigest: input.bilateralReadyDigest,
            policySHA3Digest: input.policySHA3Digest,
            policyRootKeyFingerprint: input.policyRootKeyFingerprint,
            wireDecisionDigest: input.wireDecisionDigest,
            recipientKEMPublicKeyDigest: input.recipientKEMPublicKeyDigest,
            initiatorIdentityFingerprint: input.initiatorIdentityFingerprint,
            responderIdentityFingerprint: input.responderIdentityFingerprint,
            messageAWireSHA256: input.messageAWireSHA256,
            messageBWireSHA256: input.messageBWireSHA256,
            transferID: input.transferID,
            fileContentSHA256: input.fileContentSHA256,
            authorityOperationID: input.authorityOperationID,
            durableFileEffectDigest: input.durableFileEffectDigest,
            effectReceiptWireSHA256: input.effectReceiptWireSHA256,
            positiveFileByteCount: input.positiveFileByteCount
        )
    }

    private func loadFrozenVector() throws -> [String: String] {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "bound-session-run-evidence-v2",
                withExtension: "txt"
            )
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for line in source.split(separator: "\n", omittingEmptySubsequences: true) {
            let components = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard components.count == 2,
                !components[0].isEmpty,
                !components[1].isEmpty,
                values[String(components[0])] == nil
            else {
                throw VectorError.invalidLine(String(line))
            }
            values[String(components[0])] = String(components[1])
        }
        let expectedKeys: Set<String> = [
            "format",
            "statement_bytes",
            "registry_bytes",
            "endpoint_a_digest",
            "endpoint_b_digest",
            "identity_a_fingerprint",
            "identity_b_fingerprint",
            "claim_closure_encoding",
            "claim_critical_closure_sha256",
            "statement_a",
            "statement_b",
            "statement_a_preimage",
            "statement_b_preimage",
            "registry_a",
            "registry_b",
        ]
        guard Set(values.keys) == expectedKeys,
            values["format"] == "bound-session-run-evidence-v2",
            values["statement_bytes"] == "1552",
            values["registry_bytes"] == "2064"
        else {
            throw VectorError.invalidKeySet
        }
        return values
    }

    private func decodeHex(_ value: String?) throws -> Data {
        guard let value else { throw VectorError.invalidHex("missing") }
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2) else { throw VectorError.invalidHex(value) }
        var decoded = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = hexadecimalNibble(bytes[index]),
                let low = hexadecimalNibble(bytes[index + 1])
            else {
                throw VectorError.invalidHex(value)
            }
            decoded.append((high << 4) | low)
            index += 2
        }
        return decoded
    }

    private func hexadecimalNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private func repeated(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }
}

private enum VectorError: Error {
    case invalidLine(String)
    case invalidKeySet
    case invalidHex(String)
}
