import CryptoKit
import Foundation
import XCTest
@testable import SkyBridgeQPeriaptRuntime

final class QPeriaptRuntimeSessionRegistryTests: XCTestCase {
    func testRegistryLoadsInstalledSnapshotAndAcceptsIdempotentInstall() throws {
        let registry = QPeriaptRuntimeSessionRegistry()
        XCTAssertNil(registry.snapshot())

        let session = try makeSession(version: 7, digestByte: 0x11)
        try registry.install(session)
        try registry.install(session)

        XCTAssertEqual(registry.snapshot(), session)
    }

    func testRegistryRejectsDifferentRootFingerprintUnderSameIdentifier() throws {
        let registry = QPeriaptRuntimeSessionRegistry()
        try registry.install(try makeSession(version: 7, digestByte: 0x11))

        XCTAssertThrowsError(
            try registry.install(
                makeSession(
                    version: 8,
                    digestByte: 0x22,
                    rootFingerprintByte: 0xB2
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? QPeriaptRuntimeSessionRegistryError,
                .trustRootReplacementRejected
            )
        }
    }

    func testRegistryRejectsDifferentIdentifierUnderSameRootFingerprint() throws {
        let registry = QPeriaptRuntimeSessionRegistry()
        try registry.install(try makeSession(version: 7, digestByte: 0x11))

        XCTAssertThrowsError(
            try registry.install(
                makeSession(
                    version: 8,
                    digestByte: 0x22,
                    trustRootIdentifier: "release/q-periapt/secondary"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? QPeriaptRuntimeSessionRegistryError,
                .trustRootReplacementRejected
            )
        }
    }

    func testRegistryRejectsRollback() throws {
        let registry = QPeriaptRuntimeSessionRegistry()
        try registry.install(try makeSession(version: 7, digestByte: 0x11))

        XCTAssertThrowsError(
            try registry.install(makeSession(version: 6, digestByte: 0x22))
        ) { error in
            XCTAssertEqual(
                error as? QPeriaptRuntimeSessionRegistryError,
                .policyRollbackRejected(installed: 7, proposed: 6)
            )
        }
    }

    func testRegistryRejectsSameVersionWithDifferentDigest() throws {
        let registry = QPeriaptRuntimeSessionRegistry()
        try registry.install(try makeSession(version: 7, digestByte: 0x11))

        XCTAssertThrowsError(
            try registry.install(makeSession(version: 7, digestByte: 0x22))
        ) { error in
            XCTAssertEqual(
                error as? QPeriaptRuntimeSessionRegistryError,
                .policyVersionDigestConflict(version: 7)
            )
        }
    }

    func testAuthProfileBindsCanonicalTrustRootFingerprint() throws {
        let primary = try makeSession(version: 7, digestByte: 0x11)
        let secondary = try makeSession(
            version: 7,
            digestByte: 0x11,
            trustRootIdentifier: "release/q-periapt/secondary",
            rootFingerprintByte: 0xB2
        )

        XCTAssertNotEqual(primary.trustRootFingerprint, secondary.trustRootFingerprint)
        XCTAssertNotEqual(primary.trustRootIdentifierSHA256, secondary.trustRootIdentifierSHA256)
        XCTAssertNotEqual(primary.authProfile, secondary.authProfile)
        XCTAssertTrue(primary.authProfile.contains(primary.trustRootFingerprint.hexString))
        XCTAssertTrue(primary.authProfile.contains(primary.trustRootIdentifierSHA256.hexString))
    }

    func testPolicyRuntimeRejectsNonCanonicalOrPathTraversalRootIdentifiers() async throws {
        let verificationKey = Data(repeating: 0x42, count: 1_952)
        let pin = Data(SHA256.hash(data: verificationKey))

        for identifier in [
            "../escape",
            "release/../escape",
            "/release/root",
            "release/root/",
            "release//root",
            "release\\root",
            "rélease/root",
            " release/root"
        ] {
            let material = QPeriaptSignedPolicyMaterial(
                policyTOML: Data("version = 1".utf8),
                detachedSignature: Data(repeating: 0x24, count: 3_309),
                verificationKey: verificationKey,
                verificationKeySHA256Pin: pin,
                trustRootIdentifier: identifier
            )

            do {
                _ = try await QPeriaptPolicyRuntime().resolveSession(
                    material: material,
                    enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                    trustedStateStore: UnreachableTrustedStateStore()
                )
                XCTFail("non-canonical trust-root identifier was accepted: \(identifier)")
            } catch QPeriaptPolicyRuntimeError.invalidTrustRootIdentifier {
                // Expected before any store or native operation.
            } catch {
                XCTFail("unexpected error for \(identifier): \(error)")
            }
        }
    }

    private func makeSession(
        version: UInt32,
        digestByte: UInt8,
        trustRootIdentifier: String = "release/q-periapt/primary",
        rootFingerprintByte: UInt8 = 0xA1
    ) throws -> QPeriaptRuntimeSession {
        var encoded = Data([1, 1, 2, 1])
        var bigEndianVersion = version.bigEndian
        withUnsafeBytes(of: &bigEndianVersion) { encoded.append(contentsOf: $0) }
        encoded.append(Data(repeating: digestByte, count: 32))
        return try QPeriaptRuntimeSession(
            decision: try QPeriaptPolicyDecision(validating: encoded),
            trustRootIdentifier: trustRootIdentifier,
            trustRootFingerprint: Data(repeating: rootFingerprintByte, count: 32)
        )
    }
}

private struct UnreachableTrustedStateStore: QPeriaptTrustedStateStore {
    func loadTrustedState(trustRootIdentifier: String) async throws -> Data? {
        XCTFail("identifier validation must run before trusted-state load")
        return nil
    }

    func compareAndSwapTrustedState(
        expectedPreviousState: Data?,
        newState: Data,
        trustRootIdentifier: String
    ) async throws -> Bool {
        XCTFail("identifier validation must run before trusted-state commit")
        return false
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
