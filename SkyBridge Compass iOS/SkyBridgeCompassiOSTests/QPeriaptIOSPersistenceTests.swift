import CryptoKit
import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class QPeriaptIOSPersistenceTests: XCTestCase {
    func testIdentityEnvelopeDecodesDirectlyIntoSecureBytes() throws {
        let rootFingerprint = randomFingerprint()
        let material = makeIdentityMaterial(seed: 0x31)
        defer { material.privateKey.zeroize() }
        var encoded = try QPeriaptKEMIdentityEnvelope.encode(
            rootFingerprint: rootFingerprint,
            publicKey: material.publicKey,
            privateKey: material.privateKey
        )
        defer { encoded.resetBytes(in: 0..<encoded.count) }

        let decoded = try QPeriaptKEMIdentityEnvelope.decode(
            &encoded,
            expectedRootFingerprint: rootFingerprint
        )
        defer { decoded.privateKey.zeroize() }
        XCTAssertEqual(decoded.publicKey, material.publicKey)
        XCTAssertEqual(
            decoded.privateKey.byteCount,
            QPeriaptKEMIdentityEnvelope.privateKeyLength
        )
        var decodedBytes = decoded.privateKey.copyData()
        defer { decodedBytes.resetBytes(in: 0..<decodedBytes.count) }
        XCTAssertEqual(decodedBytes.suffix(material.publicKey.count), material.publicKey)
    }

    func testIdentityEnvelopeRejectsCorruptChecksumAndTruncation() throws {
        var fixture = try makeEncodedIdentity(seed: 0x41)
        defer {
            fixture.privateKey.zeroize()
            fixture.encoded.resetBytes(in: 0..<fixture.encoded.count)
        }

        var corruptChecksum = fixture.encoded
        corruptChecksum[corruptChecksum.index(before: corruptChecksum.endIndex)] ^= 0x01
        defer { corruptChecksum.resetBytes(in: 0..<corruptChecksum.count) }
        XCTAssertThrowsError(
            try QPeriaptKEMIdentityEnvelope.decode(
                &corruptChecksum,
                expectedRootFingerprint: fixture.rootFingerprint
            )
        )

        var truncated = Data(fixture.encoded.prefix(40))
        defer { truncated.resetBytes(in: 0..<truncated.count) }
        XCTAssertThrowsError(
            try QPeriaptKEMIdentityEnvelope.decode(
                &truncated,
                expectedRootFingerprint: fixture.rootFingerprint
            )
        )
    }

    func testIdentityEnvelopeRejectsRootSuiteAndEmbeddedPublicKeyMismatch() throws {
        var fixture = try makeEncodedIdentity(seed: 0x51)
        defer {
            fixture.privateKey.zeroize()
            fixture.encoded.resetBytes(in: 0..<fixture.encoded.count)
        }

        var wrongRoot = fixture.encoded
        defer { wrongRoot.resetBytes(in: 0..<wrongRoot.count) }
        XCTAssertThrowsError(
            try QPeriaptKEMIdentityEnvelope.decode(
                &wrongRoot,
                expectedRootFingerprint: randomFingerprint()
            )
        )

        var wrongSuite = fixture.encoded
        wrongSuite[6] ^= 0x01
        rewriteEnvelopeChecksum(&wrongSuite)
        defer { wrongSuite.resetBytes(in: 0..<wrongSuite.count) }
        XCTAssertThrowsError(
            try QPeriaptKEMIdentityEnvelope.decode(
                &wrongSuite,
                expectedRootFingerprint: fixture.rootFingerprint
            )
        )

        var wrongEmbeddedPublicKey = fixture.encoded
        let embeddedPublicKeyOffset = 47 + QPeriaptKEMIdentityEnvelope.privateKeyLength
        wrongEmbeddedPublicKey[embeddedPublicKeyOffset] ^= 0x01
        rewriteEnvelopeChecksum(&wrongEmbeddedPublicKey)
        defer {
            wrongEmbeddedPublicKey.resetBytes(in: 0..<wrongEmbeddedPublicKey.count)
        }
        XCTAssertThrowsError(
            try QPeriaptKEMIdentityEnvelope.decode(
                &wrongEmbeddedPublicKey,
                expectedRootFingerprint: fixture.rootFingerprint
            )
        )
    }

    func testIdentityEnvelopeAddOnlyCASHasOneWinner() async throws {
        let rootFingerprint = randomFingerprint()
        var first = try makeEncodedIdentity(rootFingerprint: rootFingerprint, seed: 0x61)
        var second = try makeEncodedIdentity(rootFingerprint: rootFingerprint, seed: 0x71)
        var candidates = [first.encoded, second.encoded]
        defer {
            first.privateKey.zeroize()
            second.privateKey.zeroize()
            first.encoded.resetBytes(in: 0..<first.encoded.count)
            second.encoded.resetBytes(in: 0..<second.encoded.count)
            for index in candidates.indices {
                candidates[index].resetBytes(in: 0..<candidates[index].count)
            }
        }

        let results = try await withThrowingTaskGroup(
            of: IOSKeychainInsertResult.self,
            returning: [IOSKeychainInsertResult].self
        ) { group in
            for candidate in candidates {
                group.addTask {
                    try KeychainManager.shared.insertQPeriaptIdentityEnvelopeIfAbsent(
                        candidate,
                        rootFingerprint: rootFingerprint,
                        suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId,
                        formatVersion: QPeriaptKEMIdentityEnvelope.formatVersion
                    )
                }
            }
            var values: [IOSKeychainInsertResult] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { $0 == .inserted }.count, 1)
        XCTAssertEqual(results.filter { $0 == .alreadyExists }.count, 1)

        var stored = try XCTUnwrap(
            KeychainManager.shared.loadQPeriaptIdentityEnvelope(
                rootFingerprint: rootFingerprint,
                suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId,
                formatVersion: QPeriaptKEMIdentityEnvelope.formatVersion
            )
        )
        defer { stored.resetBytes(in: 0..<stored.count) }
        let winner = try QPeriaptKEMIdentityEnvelope.decode(
            &stored,
            expectedRootFingerprint: rootFingerprint
        )
        defer { winner.privateKey.zeroize() }
        XCTAssertTrue([first.publicKey, second.publicKey].contains(winner.publicKey))
    }

    func testTrustedStateConcurrentSameExpectedHasOneWinnerAndWrongExpectedLoses() async throws {
        let rootFingerprint = randomFingerprint()
        let candidates = (1...16).map(trustedState)
        let results = try await withThrowingTaskGroup(
            of: Bool.self,
            returning: [Bool].self
        ) { group in
            for candidate in candidates {
                group.addTask {
                    try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
                        expectedPreviousState: nil,
                        newState: candidate,
                        rootFingerprint: rootFingerprint
                    )
                }
            }
            var values: [Bool] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)

        let winner = try XCTUnwrap(
            KeychainManager.shared.loadQPeriaptTrustedState(
                rootFingerprint: rootFingerprint
            )
        )
        XCTAssertTrue(candidates.contains(winner))
        XCTAssertTrue(
            try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
                expectedPreviousState: winner,
                newState: winner,
                rootFingerprint: rootFingerprint
            ),
            "Replaying the already-current state must be an idempotent success"
        )
        XCTAssertEqual(
            try KeychainManager.shared.loadQPeriaptTrustedState(
                rootFingerprint: rootFingerprint
            ),
            winner
        )
        XCTAssertFalse(
            try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
                expectedPreviousState: trustedState(999),
                newState: trustedState(1_000),
                rootFingerprint: rootFingerprint
            )
        )
    }

    func testTrustedStateRejectsCorruptTransitionAndCycle() throws {
        let corruptRoot = randomFingerprint()
        XCTAssertEqual(
            try KeychainManager.shared.insertQPeriaptTrustedStateTransitionForTesting(
                rootFingerprint: corruptRoot,
                expectedState: nil,
                storedState: Data(repeating: 0xA5, count: 35)
            ),
            .inserted
        )
        XCTAssertThrowsError(
            try KeychainManager.shared.loadQPeriaptTrustedState(
                rootFingerprint: corruptRoot
            )
        ) { error in
            guard case KeychainError.immutableStateCorrupt = error else {
                return XCTFail("Expected immutableStateCorrupt, got \(error)")
            }
        }

        let cycleRoot = randomFingerprint()
        let stateA = trustedState(1)
        let stateB = trustedState(2)
        XCTAssertTrue(try cas(nil, stateA, root: cycleRoot))
        XCTAssertTrue(try cas(stateA, stateB, root: cycleRoot))
        XCTAssertThrowsError(
            try cas(stateB, stateA, root: cycleRoot)
        ) { error in
            guard case KeychainError.immutableStateCycleRejected = error else {
                return XCTFail("Expected pre-insert cycle rejection, got \(error)")
            }
        }
        XCTAssertEqual(
            try KeychainManager.shared.loadQPeriaptTrustedState(
                rootFingerprint: cycleRoot
            ),
            stateB,
            "Rejected cycle must not mutate the durable append-only chain"
        )
    }

    func testTrustedStateAllows64TransitionsAndRejects65thBeforeInsert() throws {
        let rootFingerprint = randomFingerprint()
        var previous: Data?
        for index in 1...64 {
            let next = trustedState(index)
            XCTAssertTrue(try cas(previous, next, root: rootFingerprint))
            previous = next
        }
        XCTAssertEqual(
            try KeychainManager.shared.loadQPeriaptTrustedState(
                rootFingerprint: rootFingerprint
            ),
            previous
        )

        XCTAssertThrowsError(
            try cas(previous, trustedState(65), root: rootFingerprint)
        ) { error in
            guard case KeychainError.immutableStateTransitionLimitExceeded(let maximum) = error else {
                return XCTFail("Expected transition limit, got \(error)")
            }
            XCTAssertEqual(maximum, 64)
        }
        XCTAssertEqual(
            try KeychainManager.shared.loadQPeriaptTrustedState(
                rootFingerprint: rootFingerprint
            ),
            previous
        )
    }

    private func cas(_ previous: Data?, _ next: Data, root: Data) throws -> Bool {
        try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
            expectedPreviousState: previous,
            newState: next,
            rootFingerprint: root
        )
    }

    private func trustedState(_ value: Int) -> Data {
        var state = Data(repeating: 0, count: 36)
        var encoded = UInt64(value).bigEndian
        withUnsafeBytes(of: &encoded) { state.replaceSubrange(0..<8, with: $0) }
        return state
    }

    private func randomFingerprint() -> Data {
        Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
    }

    private func makeIdentityMaterial(
        seed: UInt8
    ) -> (publicKey: Data, privateKey: SecureBytes) {
        let publicKey = Data(
            (0..<QPeriaptKEMIdentityEnvelope.publicKeyLength).map {
                seed &+ UInt8(truncatingIfNeeded: $0)
            }
        )
        let privateKey = SecureBytes(count: QPeriaptKEMIdentityEnvelope.privateKeyLength)
        privateKey.withUnsafeMutableBytes { privateRaw in
            for index in 0..<privateRaw.count {
                privateRaw[index] = seed ^ UInt8(truncatingIfNeeded: index)
            }
            publicKey.withUnsafeBytes { publicRaw in
                let suffixOffset = privateRaw.count - publicRaw.count
                for index in 0..<publicRaw.count {
                    privateRaw[suffixOffset + index] = publicRaw[index]
                }
            }
        }
        return (publicKey, privateKey)
    }

    private func makeEncodedIdentity(
        rootFingerprint: Data? = nil,
        seed: UInt8
    ) throws -> (
        rootFingerprint: Data,
        publicKey: Data,
        privateKey: SecureBytes,
        encoded: Data
    ) {
        let rootFingerprint = rootFingerprint ?? randomFingerprint()
        let material = makeIdentityMaterial(seed: seed)
        do {
            let encoded = try QPeriaptKEMIdentityEnvelope.encode(
                rootFingerprint: rootFingerprint,
                publicKey: material.publicKey,
                privateKey: material.privateKey
            )
            return (rootFingerprint, material.publicKey, material.privateKey, encoded)
        } catch {
            material.privateKey.zeroize()
            throw error
        }
    }

    private func rewriteEnvelopeChecksum(_ encoded: inout Data) {
        let checksumLength = SHA256.byteCount
        let payloadEnd = encoded.count - checksumLength
        let checksum = SHA256.hash(data: encoded.prefix(payloadEnd))
        checksum.withUnsafeBytes { checksumBytes in
            encoded.replaceSubrange(
                payloadEnd..<encoded.count,
                with: checksumBytes
            )
        }
    }
}
