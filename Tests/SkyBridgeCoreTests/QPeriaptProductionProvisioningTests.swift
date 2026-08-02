#if os(macOS)
import CryptoKit
import Foundation
import XCTest

@testable import SkyBridgeCore

#if canImport(CQPeriapt)
import CQPeriapt

/// Proves the compiled-in production trust root is exactly the ceremony
/// output and that the full macOS provisioning chain — signed-policy
/// verification, durable Keychain CAS, native round-trip probe, immutable
/// registry install — activates it end to end.
@available(macOS 14.0, *)
final class QPeriaptProductionProvisioningTests: XCTestCase {
    override func setUp() {
        super.setUp()
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
    }

    override func tearDown() {
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        super.tearDown()
    }

    // MARK: - Registry material contract

    func testProductionRegistryShipsExactlyOneWellFormedRoot() throws {
        let entries = QPeriaptProductionTrustRootRegistry.entries
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)

        XCTAssertEqual(
            entry.material.trustRootIdentifier,
            "skybridge/qperiapt/production-root/v1"
        )
        XCTAssertEqual(entry.material.detachedSignature.count, 3_309)
        XCTAssertEqual(entry.material.verificationKey.count, 1_952)
        XCTAssertEqual(entry.material.verificationKeySHA256Pin.count, 32)
        // The pin constant must be the digest of the shipped verification key;
        // the policy runtime re-checks this at every activation.
        XCTAssertEqual(
            Data(SHA256.hash(data: entry.material.verificationKey)),
            entry.material.verificationKeySHA256Pin
        )
        // The signed bytes are newline-terminated exactly as the ceremony
        // emitted them; a drifted literal would break signature verification.
        let policyText = try XCTUnwrap(
            String(data: entry.material.policyTOML, encoding: .utf8)
        )
        XCTAssertTrue(policyText.hasSuffix("\n"))
        XCTAssertTrue(policyText.contains("policy_version = 1"))
        XCTAssertTrue(policyText.contains("allowed_sigs = [\"ML-DSA-65\"]"))
    }

    func testProductionMaterialMatchesCanonicalProvisioningRecord() throws {
        let record = try Self.loadProvisioningRecord()
        let entry = try XCTUnwrap(QPeriaptProductionTrustRootRegistry.entries.first)

        XCTAssertEqual(record.trustRootIdentifier, entry.material.trustRootIdentifier)
        XCTAssertEqual(Data(record.policyTOML.utf8), entry.material.policyTOML)
        XCTAssertEqual(record.detachedSignatureHex, entry.material.detachedSignature.hexString)
        XCTAssertEqual(record.verificationKeyHex, entry.material.verificationKey.hexString)
        XCTAssertEqual(
            record.verificationKeySHA256PinHex,
            entry.material.verificationKeySHA256Pin.hexString
        )
        XCTAssertEqual(record.algorithm, "ML-DSA-65")
        XCTAssertEqual(record.policyVersion, 1)
    }

    // MARK: - Full production activation chain

    func testProductionSessionActivatesVerifiesAndPersistsTrustedState() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Q-Periapt runtime admission is intentionally unavailable before macOS 26.")
        }
        let record = try Self.loadProvisioningRecord()

        let firstOutcome = try await QPeriaptProductionRuntime.prepareProductionSession()
        XCTAssertEqual(firstOutcome, .activated)
        XCTAssertTrue(QPeriaptPlatformPolicy.isLocalRuntimeSupported)

        // The published admission identity is derived from the verified
        // production material, not from any placeholder.
        let entry = try XCTUnwrap(QPeriaptProductionTrustRootRegistry.entries.first)
        let session = try XCTUnwrap(QPeriaptPlatformPolicy.currentRuntimeSession())
        XCTAssertEqual(session.policyVersion, 1)
        XCTAssertEqual(session.trustRootFingerprint, entry.material.verificationKeySHA256Pin)
        XCTAssertEqual(session.policyDigest.hexString, record.policyDigestSHA256Hex)
        XCTAssertTrue(
            session.authProfile.hasPrefix(
                "q-periapt-abi2-policy-v1/\(record.verificationKeySHA256PinHex)/"
            )
        )
        XCTAssertTrue(session.authProfile.hasSuffix("/1/\(record.policyDigestSHA256Hex)"))

        // The monotonic trusted state was durably committed for this root:
        // 4-byte big-endian version 1 followed by the 32-byte policy digest.
        let persisted = try XCTUnwrap(
            KeychainManager.shared.loadQPeriaptTrustedState(
                rootFingerprint: entry.material.verificationKeySHA256Pin
            )
        )
        XCTAssertEqual(persisted.count, 36)
        XCTAssertEqual(persisted.prefix(4), Data([0, 0, 0, 1]))
        XCTAssertEqual(persisted.dropFirst(4).hexString, record.policyDigestSHA256Hex)

        // Re-preparation is idempotent within one process lifetime.
        let secondOutcome = try await QPeriaptProductionRuntime.prepareProductionSession()
        XCTAssertEqual(secondOutcome, .alreadyActive)

        // The settings entry point reports support only through this chain.
        let supported = await QPeriaptPlatformPolicy.prepareLocalRuntimeSupport()
        XCTAssertTrue(supported)
    }

    func testSecondActivationAfterRegistryResetReplaysExistingEnrollment() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Q-Periapt runtime admission is intentionally unavailable before macOS 26.")
        }
        _ = try await QPeriaptProductionRuntime.prepareProductionSession()
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()

        // A relaunch (fresh registry, persisted Keychain state) replays the
        // same enrollment: CAS finds the identical trusted state and treats
        // the transition as an idempotent success.
        let outcome = try await QPeriaptProductionRuntime.prepareProductionSession()
        XCTAssertEqual(outcome, .activated)
        XCTAssertTrue(QPeriaptPlatformPolicy.isLocalRuntimeSupported)
    }

    // MARK: - Keychain monotonic CAS boundary

    func testTrustedStateCASIsMonotonicCycleRejectingAndIdempotent() throws {
        var fingerprintBytes = [UInt8](repeating: 0, count: 32)
        for index in fingerprintBytes.indices {
            fingerprintBytes[index] = UInt8.random(in: .min ... .max)
        }
        let fingerprint = Data(fingerprintBytes)
        let stateA = Self.trustedState(version: 1, fill: 0xA1)
        let stateB = Self.trustedState(version: 2, fill: 0xB2)

        XCTAssertNil(
            try KeychainManager.shared.loadQPeriaptTrustedState(rootFingerprint: fingerprint)
        )

        // First enrollment commits from the empty state.
        XCTAssertTrue(
            try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
                expectedPreviousState: nil,
                newState: stateA,
                rootFingerprint: fingerprint
            )
        )
        XCTAssertEqual(
            try KeychainManager.shared.loadQPeriaptTrustedState(rootFingerprint: fingerprint),
            stateA
        )

        // A stale expectation loses the CAS without corrupting the chain.
        XCTAssertFalse(
            try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
                expectedPreviousState: nil,
                newState: stateB,
                rootFingerprint: fingerprint
            )
        )

        // Replaying the current state is an idempotent success.
        XCTAssertTrue(
            try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
                expectedPreviousState: stateA,
                newState: stateA,
                rootFingerprint: fingerprint
            )
        )

        // Monotonic upgrade succeeds.
        XCTAssertTrue(
            try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
                expectedPreviousState: stateA,
                newState: stateB,
                rootFingerprint: fingerprint
            )
        )
        XCTAssertEqual(
            try KeychainManager.shared.loadQPeriaptTrustedState(rootFingerprint: fingerprint),
            stateB
        )

        // Returning to any previously visited state is a rejected rollback.
        XCTAssertThrowsError(
            try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
                expectedPreviousState: stateB,
                newState: stateA,
                rootFingerprint: fingerprint
            )
        ) { error in
            guard case KeychainError.immutableStateCycleRejected = error else {
                return XCTFail("Expected a cycle rejection, got \(error)")
            }
        }
    }

    func testTrustedStateChainFailsClosedOnCorruptTransitionLength() throws {
        var fingerprintBytes = [UInt8](repeating: 0, count: 32)
        for index in fingerprintBytes.indices {
            fingerprintBytes[index] = UInt8.random(in: .min ... .max)
        }
        let fingerprint = Data(fingerprintBytes)

        _ = try KeychainManager.shared.insertQPeriaptTrustedStateTransitionForTesting(
            rootFingerprint: fingerprint,
            expectedState: nil,
            storedState: Data([0xEE, 0xEE])
        )
        XCTAssertThrowsError(
            try KeychainManager.shared.loadQPeriaptTrustedState(rootFingerprint: fingerprint)
        ) { error in
            guard case KeychainError.immutableStateCorrupt = error else {
                return XCTFail("Expected corruption rejection, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private struct ProvisioningRecord: Decodable {
        let algorithm: String
        let trustRootIdentifier: String
        let policyTOML: String
        let policyVersion: UInt32
        let policyDigestSHA256Hex: String
        let detachedSignatureHex: String
        let verificationKeyHex: String
        let verificationKeySHA256PinHex: String

        enum CodingKeys: String, CodingKey {
            case algorithm
            case trustRootIdentifier = "trust_root_identifier"
            case policyTOML = "policy_toml"
            case policyVersion = "policy_version"
            case policyDigestSHA256Hex = "policy_digest_sha256_hex"
            case detachedSignatureHex = "detached_signature_hex"
            case verificationKeyHex = "verification_key_hex"
            case verificationKeySHA256PinHex = "verification_key_sha256_pin_hex"
        }
    }

    private static func loadProvisioningRecord() throws -> ProvisioningRecord {
        let recordURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Config/qperiapt-production-trust-root.json")
        let data = try Data(contentsOf: recordURL)
        return try JSONDecoder().decode(ProvisioningRecord.self, from: data)
    }

    private static func trustedState(version: UInt32, fill: UInt8) -> Data {
        var state = Data([
            UInt8(truncatingIfNeeded: version >> 24),
            UInt8(truncatingIfNeeded: version >> 16),
            UInt8(truncatingIfNeeded: version >> 8),
            UInt8(truncatingIfNeeded: version),
        ])
        state.append(Data(repeating: fill, count: 32))
        return state
    }
}
#endif
#endif
