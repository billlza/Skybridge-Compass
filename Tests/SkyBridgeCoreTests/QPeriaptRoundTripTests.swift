import CryptoKit
import Foundation
import os
import XCTest
@testable import SkyBridgeCore

#if canImport(CQPeriapt)
import CQPeriapt

@available(macOS 14.0, iOS 17.0, *)
final class QPeriaptRoundTripTests: XCTestCase {
    private enum ExpectedPolicyBoundaryFailure {
        case emptyPolicy
        case oversizedPolicy(actual: Int)
        case signatureLength(actual: Int)
        case verificationKeyLength(actual: Int)
        case pinLength(actual: Int)
        case trustedStateLength(actual: Int)
    }

    private struct SignedPolicyVector: Decodable {
        let schemaVersion: Int
        let algorithm: String
        let policyTOML: String
        let verificationKey: String
        let signature: String
        let policyVersion: UInt32
        let decisionVersion: UInt8
        let selectedSuiteCode: UInt8
        let selectedProfileCode: UInt8
        let selectedKeyFormatCode: UInt8
        let policyDigest: String
        let lastTrustedVersionAccept: UInt32
        let lastTrustedVersionReject: UInt32
        let tamperSignatureByte: Int

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case algorithm
            case policyTOML = "policy_toml"
            case verificationKey = "verification_key"
            case signature
            case policyVersion = "policy_version"
            case decisionVersion = "decision_version"
            case selectedSuiteCode = "selected_suite_code"
            case selectedProfileCode = "selected_profile_code"
            case selectedKeyFormatCode = "selected_key_format_code"
            case policyDigest = "policy_digest"
            case lastTrustedVersionAccept = "last_trusted_version_accept"
            case lastTrustedVersionReject = "last_trusted_version_reject"
            case tamperSignatureByte = "tamper_signature_byte"
        }
    }

    private actor InMemoryTrustedStateStore: QPeriaptTrustedStateStore {
        private static let fixtureTrustRootIdentifier = "test/q-periapt/abi2/upstream-vector"

        private var stateByTrustRoot: [String: Data]
        private let forceCASConflict: Bool
        private let compareAndSwapBarrier: AdmissionOperationBarrier?
        private var compareAndSwapCalls = 0

        init(
            initialState: Data? = nil,
            forceCASConflict: Bool = false,
            compareAndSwapBarrier: AdmissionOperationBarrier? = nil
        ) {
            if let initialState {
                self.stateByTrustRoot = [Self.fixtureTrustRootIdentifier: initialState]
            } else {
                self.stateByTrustRoot = [:]
            }
            self.forceCASConflict = forceCASConflict
            self.compareAndSwapBarrier = compareAndSwapBarrier
        }

        func loadTrustedState(trustRootIdentifier: String) async throws -> Data? {
            stateByTrustRoot[trustRootIdentifier]
        }

        func compareAndSwapTrustedState(
            expectedPreviousState: Data?,
            newState: Data,
            trustRootIdentifier: String
        ) async throws -> Bool {
            compareAndSwapCalls += 1
            if let compareAndSwapBarrier {
                await compareAndSwapBarrier.suspendUntilReleased()
            }
            guard !forceCASConflict,
                  stateByTrustRoot[trustRootIdentifier] == expectedPreviousState else {
                return false
            }
            stateByTrustRoot[trustRootIdentifier] = newState
            return true
        }

        func currentState(
            trustRootIdentifier: String = fixtureTrustRootIdentifier
        ) -> Data? {
            stateByTrustRoot[trustRootIdentifier]
        }

        func compareAndSwapCallCount() -> Int {
            compareAndSwapCalls
        }
    }

    private actor AdmissionOperationBarrier {
        private var didEnter = false
        private var isReleased = false
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func suspendUntilReleased() async {
            precondition(!didEnter)
            didEnter = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                precondition(releaseContinuation == nil)
                releaseContinuation = continuation
            }
        }

        func waitUntilEntered() async {
            guard !didEnter else { return }
            await withCheckedContinuation { continuation in
                precondition(enteredContinuation == nil)
                enteredContinuation = continuation
            }
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private struct FixedKEMIdentityStore: HandshakeKEMIdentityStore, Sendable {
        let publicKey: Data
        let privateKey: Data

        func getOrCreateKEMIdentityKey(
            for suite: CryptoSuite,
            provider: any CryptoProvider
        ) async throws -> HandshakeKEMIdentityMaterial {
            guard suite == .qperiaptABI2PolicyBound,
                  provider.supportsSuite(.qperiaptABI2PolicyBound) else {
                throw CryptoProviderError.unsupportedAlgorithm(suite.rawValue)
            }
            guard publicKey.count == QPeriaptNativeAdapter.publicKeyLength,
                  privateKey.count == QPeriaptNativeAdapter.privateKeyLength else {
                throw CryptoProviderError.operationFailed(
                    "Q-Periapt E2E fixture contains malformed KEM identity material"
                )
            }
            return HandshakeKEMIdentityMaterial(
                publicKey: publicKey,
                privateKey: SecureBytes(data: privateKey)
            )
        }
    }

    func testQPeriaptRuntimeMetadataMatchesFrozenABI2Contract() throws {
        XCTAssertEqual(q_periapt_abi_version(), QPeriaptRuntimeContract.expectedABIVersion)
        let versionPointer = try XCTUnwrap(q_periapt_version())
        XCTAssertEqual(String(cString: versionPointer), QPeriaptRuntimeContract.expectedRuntimeVersion)
        XCTAssertEqual(Int(q_periapt_fixed_suite_id_len()), QPeriaptRuntimeContract.expectedSuiteID.count)
        XCTAssertTrue(QPeriaptRuntimeContract.isCompatible)
        XCTAssertNoThrow(try QPeriaptRuntimeContract.requireCompatible())

        let suitePointer = try XCTUnwrap(q_periapt_fixed_suite_id())
        let exportedSuite = Data(
            bytes: suitePointer,
            count: Int(q_periapt_fixed_suite_id_len())
        )
        XCTAssertEqual(exportedSuite, Data(QPeriaptRuntimeContract.expectedSuiteID))
    }

    func testSignedPolicyFixtureIsExactUpstreamReleaseVector() throws {
        let fixtureData = try loadFixtureData()
        XCTAssertEqual(
            Data(SHA256.hash(data: fixtureData)).hexString,
            "83110fa4c73679e7b4b8d117cffe4f8388408500de2a354fb3d7982a129382f5"
        )

        let vector = try decodeFixture(fixtureData)
        XCTAssertEqual(vector.schemaVersion, 1)
        XCTAssertEqual(vector.algorithm, "ML-DSA-65")
        XCTAssertEqual(vector.policyVersion, 2)
        XCTAssertEqual(vector.decisionVersion, UInt8(Q_PERIAPT_POLICY_DECISION_VERSION))
        XCTAssertEqual(vector.selectedSuiteCode, UInt8(Q_PERIAPT_SUITE_MLKEM768_X25519))
        XCTAssertEqual(vector.selectedProfileCode, UInt8(Q_PERIAPT_PROFILE_CONTEXT_BOUND))
        XCTAssertEqual(vector.selectedKeyFormatCode, UInt8(Q_PERIAPT_KEY_FORMAT_EXPANDED))
    }

    func testSignedPolicyResolutionCommitsStateBeforePublishingSession() async throws {
        let vector = try loadFixture()
        let store = InMemoryTrustedStateStore()
        let material = try makeMaterial(vector: vector)
        let session = try await QPeriaptPolicyRuntime().resolveSession(
            material: material,
            enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
            trustedStateStore: store
        )

        let expectedDigest = try XCTUnwrap(Data(hexString: vector.policyDigest))
        XCTAssertEqual(session.policyVersion, vector.policyVersion)
        XCTAssertEqual(session.policyDigest, expectedDigest)
        XCTAssertEqual(session.trustRootIdentifier, "test/q-periapt/abi2/upstream-vector")
        XCTAssertEqual(session.trustRootFingerprint, material.verificationKeySHA256Pin)
        let registryIdentifierDigest = Data(
            SHA256.hash(data: Data(session.trustRootIdentifier.utf8))
        ).hexString
        XCTAssertEqual(
            session.authProfile,
            "q-periapt-abi2-policy-v1/\(material.verificationKeySHA256Pin.hexString)/\(registryIdentifierDigest)/\(vector.policyVersion)/\(vector.policyDigest)"
        )

        let currentState = await store.currentState()
        let persistedState = try XCTUnwrap(currentState)
        XCTAssertEqual(persistedState.count, Int(Q_PERIAPT_TRUSTED_POLICY_STATE_LEN))
        XCTAssertEqual(persistedState, session.trustedState)
    }

    func testCancellationAfterNativeDecisionDoesNotAttemptTrustedStateCommit() async throws {
        let vector = try loadFixture()
        let material = try makeMaterial(vector: vector)
        let preCommitBarrier = AdmissionOperationBarrier()
        let store = InMemoryTrustedStateStore()
        let runtime = QPeriaptPolicyRuntime(afterDecisionBeforeCommitForTesting: {
            await preCommitBarrier.suspendUntilReleased()
        })
        let resolution = Task {
            try await runtime.resolveSession(
                material: material,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: store
            )
        }

        await preCommitBarrier.waitUntilEntered()
        resolution.cancel()
        await preCommitBarrier.release()
        do {
            _ = try await resolution.value
            XCTFail("A policy cancelled after native verification must not enter CAS")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let compareAndSwapCalls = await store.compareAndSwapCallCount()
        let currentState = await store.currentState()
        XCTAssertEqual(compareAndSwapCalls, 0)
        XCTAssertNil(currentState)
    }

    func testCancellationAfterCASBeginsPreservesKnownCommittedResult() async throws {
        let vector = try loadFixture()
        let material = try makeMaterial(vector: vector)
        let commitBarrier = AdmissionOperationBarrier()
        let store = InMemoryTrustedStateStore(compareAndSwapBarrier: commitBarrier)
        let resolution = Task {
            try await QPeriaptPolicyRuntime().resolveSession(
                material: material,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: store
            )
        }

        await commitBarrier.waitUntilEntered()
        resolution.cancel()
        await commitBarrier.release()
        let session = try await resolution.value

        let compareAndSwapCalls = await store.compareAndSwapCallCount()
        let currentState = await store.currentState()
        XCTAssertEqual(compareAndSwapCalls, 1)
        XCTAssertEqual(currentState, session.trustedState)
    }

    func testExistingEnrollmentRejectsMissingTrustedState() async throws {
        let vector = try loadFixture()
        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: try makeMaterial(vector: vector),
                enrollmentMode: .existingEnrollment,
                trustedStateStore: InMemoryTrustedStateStore()
            )
            XCTFail("existing enrollment must not reinterpret missing state as first use")
        } catch QPeriaptPolicyRuntimeError.missingTrustedState {
            // Expected fail-closed boundary.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSignedPolicyRejectsVerificationKeyPinMismatch() async throws {
        let vector = try loadFixture()
        var material = try makeMaterial(vector: vector)
        material = QPeriaptSignedPolicyMaterial(
            policyTOML: material.policyTOML,
            detachedSignature: material.detachedSignature,
            verificationKey: material.verificationKey,
            verificationKeySHA256Pin: Data(repeating: 0xA5, count: SHA256.byteCount),
            trustRootIdentifier: material.trustRootIdentifier
        )

        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: material,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: InMemoryTrustedStateStore()
            )
            XCTFail("a verification key that misses its independent pin must be rejected")
        } catch QPeriaptPolicyRuntimeError.verificationKeyPinMismatch {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSignedPolicyRejectsTamperedSignature() async throws {
        let vector = try loadFixture()
        let validMaterial = try makeMaterial(vector: vector)
        var tamperedSignature = validMaterial.detachedSignature
        tamperedSignature[vector.tamperSignatureByte] ^= 0x01
        let tamperedMaterial = QPeriaptSignedPolicyMaterial(
            policyTOML: validMaterial.policyTOML,
            detachedSignature: tamperedSignature,
            verificationKey: validMaterial.verificationKey,
            verificationKeySHA256Pin: validMaterial.verificationKeySHA256Pin,
            trustRootIdentifier: validMaterial.trustRootIdentifier
        )

        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: tamperedMaterial,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: InMemoryTrustedStateStore()
            )
            XCTFail("tampered signed policy must not produce a runtime session")
        } catch QPeriaptPolicyRuntimeError.nativePolicyRejected(let status, _) {
            XCTAssertEqual(status, Int32(Q_PERIAPT_ERR_POLICY))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPolicyRollbackAndConcurrentStateChangeAreRejected() async throws {
        let vector = try loadFixture()
        let digest = try XCTUnwrap(Data(hexString: vector.policyDigest))
        let rollbackState = trustedState(version: vector.lastTrustedVersionReject, digest: digest)

        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: try makeMaterial(vector: vector),
                enrollmentMode: .existingEnrollment,
                trustedStateStore: InMemoryTrustedStateStore(initialState: rollbackState)
            )
            XCTFail("policy rollback must be rejected by the native ABI2 decision boundary")
        } catch QPeriaptPolicyRuntimeError.nativePolicyRejected(let status, _) {
            XCTAssertEqual(status, Int32(Q_PERIAPT_ERR_POLICY))
        } catch {
            XCTFail("unexpected rollback error: \(error)")
        }

        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: try makeMaterial(vector: vector),
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: InMemoryTrustedStateStore(forceCASConflict: true)
            )
            XCTFail("a concurrent trusted-state change must prevent session publication")
        } catch QPeriaptPolicyRuntimeError.trustedStateChangedConcurrently {
            // Expected.
        } catch {
            XCTFail("unexpected CAS error: \(error)")
        }
    }

    func testQPeriaptKEMRoundTripIsBoundToExplicitApplicationContext() async throws {
        let session = try await makeSession()
        let provider = QPeriaptCryptoProvider(session: session)
        XCTAssertEqual(provider.tier, CryptoTier.qperiaptPQC)
        XCTAssertEqual(provider.activeSuite, CryptoSuite.qperiaptABI2PolicyBound)

        let keyPair = try await provider.generateKeyPair(for: KeyUsage.keyExchange)
        XCTAssertEqual(keyPair.publicKey.bytes.count, QPeriaptNativeAdapter.publicKeyLength)
        XCTAssertEqual(keyPair.privateKey.bytes.count, QPeriaptNativeAdapter.privateKeyLength)

        let context = Data("skybridge/qperiapt/abi2/roundtrip-context/v1".utf8)
        let encapsulated = try await provider.kemEncapsulate(
            recipientPublicKey: keyPair.publicKey.bytes,
            applicationContext: context
        )
        XCTAssertEqual(encapsulated.encapsulatedKey.count, QPeriaptNativeAdapter.encapsulatedKeyLength)

        let recipientPrivateKey = SecureBytes(data: keyPair.privateKey.bytes)
        let decapsulated = try await provider.kemDecapsulate(
            encapsulatedKey: encapsulated.encapsulatedKey,
            privateKey: recipientPrivateKey,
            applicationContext: context
        )
        var senderSecret = encapsulated.sharedSecret.copyData()
        var recipientSecret = decapsulated.copyData()
        defer {
            senderSecret.resetBytes(in: 0..<senderSecret.count)
            recipientSecret.resetBytes(in: 0..<recipientSecret.count)
        }
        XCTAssertEqual(senderSecret.count, QPeriaptNativeAdapter.sharedSecretLength)
        XCTAssertEqual(senderSecret, recipientSecret)
        XCTAssertNotEqual(senderSecret, Data(repeating: 0, count: senderSecret.count))

        let wrongContextSecret = try await provider.kemDecapsulate(
            encapsulatedKey: encapsulated.encapsulatedKey,
            privateKey: recipientPrivateKey,
            applicationContext: Data("skybridge/qperiapt/abi2/wrong-context/v1".utf8)
        )
        var wrongContextData = wrongContextSecret.copyData()
        defer { wrongContextData.resetBytes(in: 0..<wrongContextData.count) }
        XCTAssertNotEqual(senderSecret, wrongContextData)
    }

    func testCoreFacadeMapsEveryMalformedQPeriaptKEMBoundary() async throws {
        let session = try await makeSession()
        let adapter = QPeriaptNativeAdapter(session: session)

        let context = Data("skybridge/qperiapt/abi2/length-validation/v1".utf8)
        for invalidPublicKeyLength in [
            QPeriaptNativeAdapter.publicKeyLength - 1,
            QPeriaptNativeAdapter.publicKeyLength + 1
        ] {
            do {
                _ = try await requirePromptCompletion {
                    try await adapter.encapsulate(
                        recipientPublicKey: Data(repeating: 0xA5, count: invalidPublicKeyLength),
                        applicationContext: context
                    )
                }
                XCTFail("Malformed Q-Periapt public keys must fail before admission")
            } catch CryptoProviderError.invalidKeyLength(
                let expected,
                let actual,
                _,
                .keyExchange
            ) {
                XCTAssertEqual(expected, QPeriaptNativeAdapter.publicKeyLength)
                XCTAssertEqual(actual, invalidPublicKeyLength)
            } catch {
                XCTFail("Unexpected public-key length error: \(error)")
            }
        }

        for invalidPrivateKeyLength in [
            QPeriaptNativeAdapter.privateKeyLength - 1,
            QPeriaptNativeAdapter.privateKeyLength + 1
        ] {
            let privateKey = try SecureBytes(count: invalidPrivateKeyLength)
            defer { privateKey.zeroize() }
            do {
                _ = try await requirePromptCompletion {
                    try await adapter.decapsulate(
                        encapsulatedKey: Data(
                            repeating: 0x5A,
                            count: QPeriaptNativeAdapter.encapsulatedKeyLength
                        ),
                        privateKey: privateKey,
                        applicationContext: context
                    )
                }
                XCTFail("Malformed Q-Periapt private keys must fail before admission")
            } catch CryptoProviderError.invalidKeyLength(
                let expected,
                let actual,
                _,
                .keyExchange
            ) {
                XCTAssertEqual(expected, QPeriaptNativeAdapter.privateKeyLength)
                XCTAssertEqual(actual, invalidPrivateKeyLength)
            } catch {
                XCTFail("Unexpected private-key length error: \(error)")
            }
        }

        for invalidCiphertextLength in [
            QPeriaptNativeAdapter.encapsulatedKeyLength - 1,
            QPeriaptNativeAdapter.encapsulatedKeyLength + 1
        ] {
            let privateKey = try SecureBytes(
                count: QPeriaptNativeAdapter.privateKeyLength
            )
            defer { privateKey.zeroize() }
            do {
                _ = try await requirePromptCompletion {
                    try await adapter.decapsulate(
                        encapsulatedKey: Data(repeating: 0x3C, count: invalidCiphertextLength),
                        privateKey: privateKey,
                        applicationContext: context
                    )
                }
                XCTFail("Malformed Q-Periapt ciphertexts must fail before admission")
            } catch CryptoProviderError.operationFailed(let reason) {
                XCTAssertTrue(reason.contains("ciphertext length"))
            } catch {
                XCTFail("Unexpected ciphertext length error: \(error)")
            }
        }

        let validPublicKey = Data(
            repeating: 0x7E,
            count: QPeriaptNativeAdapter.publicKeyLength
        )
        for invalidContext in [
            Data(),
            Data(
                repeating: 0x01,
                count: QPeriaptNativeAdapter.maximumApplicationContextLength + 1
            )
        ] {
            do {
                _ = try await requirePromptCompletion {
                    try await adapter.encapsulate(
                        recipientPublicKey: validPublicKey,
                        applicationContext: invalidContext
                    )
                }
                XCTFail("Malformed Q-Periapt application contexts must fail before admission")
            } catch CryptoProviderError.operationFailed(let reason) {
                XCTAssertTrue(reason.contains("application context"))
            } catch CryptoProviderError.lengthExceeded(let field, let actual, let maximum) {
                XCTAssertEqual(field, "Q-Periapt application context")
                XCTAssertEqual(actual, invalidContext.count)
                XCTAssertEqual(maximum, QPeriaptNativeAdapter.maximumApplicationContextLength)
            } catch {
                XCTFail("Unexpected application-context error: \(error)")
            }
        }
    }

    func testCoreFacadeMapsEveryQPeriaptPolicyBoundary() async throws {
        let validMaterial = try makeMaterial(vector: loadFixture())

        let signatureLength = validMaterial.detachedSignature.count
        let verificationKeyLength = validMaterial.verificationKey.count
        let malformedMaterials: [(QPeriaptSignedPolicyMaterial, ExpectedPolicyBoundaryFailure)] = [
            (
                replacing(validMaterial, policyTOML: Data()),
                .emptyPolicy
            ),
            (
                replacing(
                    validMaterial,
                    policyTOML: Data(
                        repeating: 0x20,
                        count: Int(Q_PERIAPT_MAX_SIGNED_POLICY_BYTES) + 1
                    )
                ),
                .oversizedPolicy(actual: Int(Q_PERIAPT_MAX_SIGNED_POLICY_BYTES) + 1)
            ),
            (
                replacing(
                    validMaterial,
                    detachedSignature: Data(repeating: 0x11, count: signatureLength - 1)
                ),
                .signatureLength(actual: signatureLength - 1)
            ),
            (
                replacing(
                    validMaterial,
                    detachedSignature: Data(repeating: 0x11, count: signatureLength + 1)
                ),
                .signatureLength(actual: signatureLength + 1)
            ),
            (
                replacing(
                    validMaterial,
                    verificationKey: Data(repeating: 0x22, count: verificationKeyLength - 1)
                ),
                .verificationKeyLength(actual: verificationKeyLength - 1)
            ),
            (
                replacing(
                    validMaterial,
                    verificationKey: Data(repeating: 0x22, count: verificationKeyLength + 1)
                ),
                .verificationKeyLength(actual: verificationKeyLength + 1)
            ),
            (
                replacing(validMaterial, verificationKeySHA256Pin: Data(repeating: 0x33, count: 31)),
                .pinLength(actual: 31)
            ),
            (
                replacing(validMaterial, verificationKeySHA256Pin: Data(repeating: 0x33, count: 33)),
                .pinLength(actual: 33)
            )
        ]

        for (material, expectedFailure) in malformedMaterials {
            await assertPolicyBoundaryFailure(
                material: material,
                store: InMemoryTrustedStateStore(),
                expected: expectedFailure
            )
        }

        for invalidTrustedStateLength in [
            Int(Q_PERIAPT_TRUSTED_POLICY_STATE_LEN) - 1,
            Int(Q_PERIAPT_TRUSTED_POLICY_STATE_LEN) + 1
        ] {
            await assertPolicyBoundaryFailure(
                material: validMaterial,
                store: InMemoryTrustedStateStore(
                    initialState: Data(repeating: 0x44, count: invalidTrustedStateLength)
                ),
                expected: .trustedStateLength(actual: invalidTrustedStateLength),
                enrollmentMode: .existingEnrollment
            )
        }
    }

    func testContextFreeKEMSurfacesFailClosed() async throws {
        let session = try await makeSession()
        let provider = QPeriaptCryptoProvider(session: session)
        let keyPair = try await provider.generateKeyPair(for: KeyUsage.keyExchange)

        do {
            _ = try await provider.kemEncapsulate(recipientPublicKey: keyPair.publicKey.bytes)
            XCTFail("context-free Q-Periapt encapsulation must be unavailable")
        } catch CryptoProviderError.operationFailed(let reason) {
            XCTAssertTrue(reason.contains("application context"))
        } catch {
            XCTFail("unexpected context-free encapsulation error: \(error)")
        }

        do {
            _ = try await provider.kemDecapsulate(
                encapsulatedKey: Data(),
                privateKey: SecureBytes(data: keyPair.privateKey.bytes)
            )
            XCTFail("context-free Q-Periapt decapsulation must be unavailable")
        } catch CryptoProviderError.operationFailed(let reason) {
            XCTAssertTrue(reason.contains("application context"))
        } catch {
            XCTFail("unexpected context-free decapsulation error: \(error)")
        }

        XCTAssertThrowsError(
            try QPeriaptKEMProvider(session: session, applicationContext: Data())
        ) { error in
            guard case CryptoProviderError.operationFailed(let reason) = error else {
                return XCTFail("unexpected empty-context error: \(error)")
            }
            XCTAssertTrue(reason.contains("non-empty application context"))
        }
    }

    func testGenericHPKEAndKEMDEMSurfacesFailClosed() async throws {
        let provider = QPeriaptCryptoProvider(session: try await makeSession())
        let keyPair = try await provider.generateKeyPair(for: KeyUsage.keyExchange)
        let plaintext = Data("generic surfaces must not bypass MessageA context binding".utf8)
        let info = Data("skybridge/qperiapt/abi2/generic-surface-denied/v1".utf8)
        let sealedBox = HPKESealedBox(
            encapsulatedKey: Data(),
            nonce: Data(repeating: 0, count: 12),
            ciphertext: Data(),
            tag: Data(repeating: 0, count: 16)
        )
        let privateKey = SecureBytes(data: keyPair.privateKey.bytes)

        await assertGenericQPeriaptSurfaceFailsClosed {
            _ = try await provider.hpkeSeal(
                plaintext: plaintext,
                recipientPublicKey: keyPair.publicKey.bytes,
                info: info
            )
        }
        await assertGenericQPeriaptSurfaceFailsClosed {
            _ = try await provider.kemDemSeal(
                plaintext: plaintext,
                recipientPublicKey: keyPair.publicKey.bytes,
                info: info
            )
        }
        await assertGenericQPeriaptSurfaceFailsClosed {
            _ = try await provider.kemDemSealWithSecret(
                plaintext: plaintext,
                recipientPublicKey: keyPair.publicKey.bytes,
                info: info
            )
        }
        await assertGenericQPeriaptSurfaceFailsClosed {
            _ = try await provider.hpkeOpen(
                sealedBox: sealedBox,
                privateKey: keyPair.privateKey.bytes,
                info: info
            )
        }
        await assertGenericQPeriaptSurfaceFailsClosed {
            _ = try await provider.hpkeOpen(
                sealedBox: sealedBox,
                privateKey: privateKey,
                info: info
            )
        }
        await assertGenericQPeriaptSurfaceFailsClosed {
            _ = try await provider.kemDemOpen(
                sealedBox: sealedBox,
                privateKey: keyPair.privateKey.bytes,
                info: info
            )
        }
        await assertGenericQPeriaptSurfaceFailsClosed {
            _ = try await provider.kemDemOpen(
                sealedBox: sealedBox,
                privateKey: privateKey,
                info: info
            )
        }
        await assertGenericQPeriaptSurfaceFailsClosed {
            _ = try await provider.kemDemOpenWithSecret(
                sealedBox: sealedBox,
                privateKey: privateKey,
                info: info
            )
        }
    }

    func testNativeRuntimeProbePassesWithAuthenticatedSession() async throws {
        #if DEBUG || SKYBRIDGE_TESTING
        let tracker = SecureBytesWipeTracker()
        let originalWipingFunction = SecureBytes.wipingFunction
        SecureBytes.wipingFunction = tracker.makeWipingFunction()
        defer { SecureBytes.wipingFunction = originalWipingFunction }
        #endif

        let session = try await makeSession()
        let probePassed = try await QPeriaptCryptoProvider.quickRuntimeProbe(session: session)
        XCTAssertTrue(probePassed)

        #if DEBUG || SKYBRIDGE_TESTING
        XCTAssertGreaterThanOrEqual(
            tracker.wipeCount,
            3,
            "runtime probe must explicitly wipe the private key and both shared secrets"
        )
        #endif
    }

    func testHandshakePeerEligibilityRequiresExactAuthenticatedPolicyIdentity() async throws {
        let session = try await makeSession()
        let exactCapabilities = CryptoCapabilities(
            supportedKEM: [P2PCryptoAlgorithm.qperiaptABI2PolicyBound.rawValue],
            supportedSignature: [P2PCryptoAlgorithm.mlDSA65.rawValue],
            supportedAuthProfiles: [session.authProfile],
            supportedAEAD: [P2PCryptoAlgorithm.aes256GCM.rawValue],
            pqcAvailable: true,
            platformVersion: "macOS 26.0",
            providerType: .qPeriapt
        )
        XCTAssertTrue(QPeriaptPlatformPolicy.isHandshakePeerEligible(exactCapabilities, for: session))

        let wrongPolicy = CryptoCapabilities(
            supportedKEM: exactCapabilities.supportedKEM,
            supportedSignature: exactCapabilities.supportedSignature,
            supportedAuthProfiles: [session.authProfile + "-different"],
            supportedAEAD: exactCapabilities.supportedAEAD,
            pqcAvailable: true,
            platformVersion: exactCapabilities.platformVersion,
            providerType: .qPeriapt
        )
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(wrongPolicy, for: session))

        let wrongProvider = CryptoCapabilities(
            supportedKEM: exactCapabilities.supportedKEM,
            supportedSignature: exactCapabilities.supportedSignature,
            supportedAuthProfiles: exactCapabilities.supportedAuthProfiles,
            supportedAEAD: exactCapabilities.supportedAEAD,
            pqcAvailable: true,
            platformVersion: exactCapabilities.platformVersion,
            providerType: .cryptoKitPQC
        )
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(wrongProvider, for: session))

        let aliasedKEM = CryptoCapabilities(
            supportedKEM: ["qperiaptabi2policybound"],
            supportedSignature: exactCapabilities.supportedSignature,
            supportedAuthProfiles: exactCapabilities.supportedAuthProfiles,
            supportedAEAD: exactCapabilities.supportedAEAD,
            pqcAvailable: true,
            platformVersion: exactCapabilities.platformVersion,
            providerType: .qPeriapt
        )
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(aliasedKEM, for: session))

        let aliasedSignature = CryptoCapabilities(
            supportedKEM: exactCapabilities.supportedKEM,
            supportedSignature: ["mldsa65"],
            supportedAuthProfiles: exactCapabilities.supportedAuthProfiles,
            supportedAEAD: exactCapabilities.supportedAEAD,
            pqcAvailable: true,
            platformVersion: exactCapabilities.platformVersion,
            providerType: .qPeriapt
        )
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(aliasedSignature, for: session))

        let missingAEAD = CryptoCapabilities(
            supportedKEM: exactCapabilities.supportedKEM,
            supportedSignature: exactCapabilities.supportedSignature,
            supportedAuthProfiles: exactCapabilities.supportedAuthProfiles,
            supportedAEAD: [],
            pqcAvailable: true,
            platformVersion: exactCapabilities.platformVersion,
            providerType: .qPeriapt
        )
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(missingAEAD, for: session))

        let malformedPlatform = CryptoCapabilities(
            supportedKEM: exactCapabilities.supportedKEM,
            supportedSignature: exactCapabilities.supportedSignature,
            supportedAuthProfiles: exactCapabilities.supportedAuthProfiles,
            supportedAEAD: exactCapabilities.supportedAEAD,
            pqcAvailable: true,
            platformVersion: "proxy macOS 26.0",
            providerType: .qPeriapt
        )
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(malformedPlatform, for: session))
    }

    func testDirectQResponderWithImplicitOffersRejectsClassicMessageA() async throws {
        let classicProvider = ClassicCryptoProvider()
        let classicInitiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: classicProvider
        )
        let signingKey = try await classicProvider.generateKeyPair(for: .signing)
        let classicMessageA = try await classicInitiator.buildMessageA(
            identityKeyHandle: .softwareKey(signingKey.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(signingKey.publicKey.bytes)
        )

        let qProvider = QPeriaptCryptoProvider(session: try await makeSession())
        let qResponder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: qProvider,
            signatureProvider: classicProvider,
            offeredSuites: nil,
            activeProtocolSigningAlgorithm: .mlDSA65
        )
        addTeardownBlock {
            await classicInitiator.zeroize()
            await qResponder.zeroize()
        }

        do {
            try await qResponder.processMessageA(classicMessageA)
            XCTFail("a Q-bound responder must never select a classic suite")
        } catch HandshakeError.failed(let reason) {
            XCTAssertEqual(reason, .suiteNegotiationFailed)
        }

        let negotiatedSuite = await qResponder.negotiatedSuite
        let isZeroized = await qResponder.isZeroized
        XCTAssertNil(negotiatedSuite)
        XCTAssertTrue(isZeroized)
    }

    func testDirectQContextRejectsMLDSA87IdentityBeforeHandshakeWork() async throws {
        let qProvider = QPeriaptCryptoProvider(session: try await makeSession())

        do {
            _ = try await HandshakeContext.create(
                role: .responder,
                cryptoProvider: qProvider,
                offeredSuites: nil,
                activeProtocolSigningAlgorithm: .mlDSA87
            )
            XCTFail("Q-Periapt ABI2 must not bind to an ML-DSA-87 protocol identity")
        } catch HandshakeError.invalidState(let reason) {
            XCTAssertTrue(reason.contains("ML-DSA-65"))
        }
    }

    func testAuthenticatedABI2SessionCompletesNativeHandshakeContextEndToEnd() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw XCTSkip("Q-Periapt runtime admission is intentionally unavailable before Apple OS 26.")
        }
        await HandshakeReplayCache.shared.clearForTesting()
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()

        let requestEnvironmentKey = "SB_ENABLE_QPERIAPT"
        let previousRequestValue = ProcessInfo.processInfo.environment[requestEnvironmentKey]
        setenv(requestEnvironmentKey, "1", 1)
        defer {
            if let previousRequestValue {
                setenv(requestEnvironmentKey, previousRequestValue, 1)
            } else {
                unsetenv(requestEnvironmentKey)
            }
            QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        }

        let session = try await makeSession()
        try await QPeriaptPlatformPolicy.activateRuntimeSession(session)
        XCTAssertTrue(QPeriaptPlatformPolicy.isEnabledForLocalRuntime())
        XCTAssertEqual(QPeriaptPlatformPolicy.authProfile, session.authProfile)

        let provider = QPeriaptCryptoProvider(session: session)
        let responderKEMKeyPair = try await provider.generateKeyPair(for: .keyExchange)
        let responderKEMStore = FixedKEMIdentityStore(
            publicKey: responderKEMKeyPair.publicKey.bytes,
            privateKey: responderKEMKeyPair.privateKey.bytes
        )
        let initiatorSigningKeyPair = try await provider.generateKeyPair(for: .signing)
        let responderSigningKeyPair = try await provider.generateKeyPair(for: .signing)
        let signatureProvider = PQCSignatureProvider(backend: .oqs)
        let handshakePolicy = HandshakePolicy(
            requirePQC: true,
            allowClassicFallback: false,
            minimumTier: .qperiaptPQC
        )
        let cryptoPolicy = CryptoPolicy(
            minimumSecurityTier: .hybridPreferred,
            allowExperimentalHybrid: true,
            advertiseHybrid: true,
            requireHybridIfAvailable: true
        )

        let initiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            cryptoPolicy: cryptoPolicy,
            peerKEMPublicKeys: [
                .qperiaptABI2PolicyBound: responderKEMKeyPair.publicKey.bytes
            ]
        )
        let responder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            cryptoPolicy: cryptoPolicy,
            kemIdentityStore: responderKEMStore
        )
        addTeardownBlock {
            await initiator.zeroize()
            await responder.zeroize()
        }

        let initiatorIdentity = encodeIdentityPublicKey(
            initiatorSigningKeyPair.publicKey.bytes,
            algorithm: .mlDSA65
        )
        let responderIdentity = encodeIdentityPublicKey(
            responderSigningKeyPair.publicKey.bytes,
            algorithm: .mlDSA65
        )
        let extensionValue = Data("qperiapt-native-handshake-e2e/v1".utf8)
        var extensionBinding = Data([0xEF, 0xBE])
        var extensionLength = UInt16(extensionValue.count).littleEndian
        withUnsafeBytes(of: &extensionLength) { extensionBinding.append(contentsOf: $0) }
        extensionBinding.append(extensionValue)

        let outboundMessageA = try await initiator.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorSigningKeyPair.privateKey.bytes),
            identityPublicKey: initiatorIdentity,
            policy: handshakePolicy,
            offeredSuites: [.qperiaptABI2PolicyBound],
            extensionsRaw: extensionBinding
        )
        let messageA = try HandshakeMessageA.decode(from: outboundMessageA.encoded)

        XCTAssertEqual(messageA.supportedSuites, [.qperiaptABI2PolicyBound])
        XCTAssertEqual(messageA.keyShares.count, 1)
        XCTAssertEqual(
            messageA.keyShares[0].shareBytes.count,
            QPeriaptNativeAdapter.encapsulatedKeyLength
        )
        XCTAssertEqual(messageA.extensionsRaw, extensionBinding)
        XCTAssertEqual(messageA.capabilities.providerType, .qPeriapt)
        XCTAssertEqual(messageA.capabilities.supportedAuthProfiles.first, session.authProfile)

        try await responder.processMessageA(messageA, policy: handshakePolicy)
        let outboundResponse = try await responder.buildMessageB(
            identityKeyHandle: .softwareKey(responderSigningKeyPair.privateKey.bytes),
            identityPublicKey: responderIdentity,
            policy: handshakePolicy
        )
        let messageB = try HandshakeMessageB.decode(from: outboundResponse.message.encoded)

        XCTAssertEqual(messageB.selectedSuite, .qperiaptABI2PolicyBound)
        XCTAssertTrue(messageB.responderShare.isEmpty)
        XCTAssertTrue(messageB.encryptedPayload.encapsulatedKey.isEmpty)

        let initiatorKeys = try await initiator.processMessageB(
            messageB,
            policy: handshakePolicy
        )
        let responderKeys = try await responder.finalizeResponderSessionKeys(
            sharedSecret: outboundResponse.sharedSecret
        )

        XCTAssertEqual(initiatorKeys.negotiatedSuite, .qperiaptABI2PolicyBound)
        XCTAssertEqual(responderKeys.negotiatedSuite, .qperiaptABI2PolicyBound)
        XCTAssertEqual(initiatorKeys.role, .initiator)
        XCTAssertEqual(responderKeys.role, .responder)
        XCTAssertEqual(initiatorKeys.sendKey, responderKeys.receiveKey)
        XCTAssertEqual(initiatorKeys.receiveKey, responderKeys.sendKey)
        XCTAssertEqual(initiatorKeys.transcriptHash, responderKeys.transcriptHash)
        XCTAssertEqual(initiatorKeys.sessionId, responderKeys.sessionId)

        await initiator.zeroize()
        await responder.zeroize()
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        XCTAssertFalse(QPeriaptPlatformPolicy.isLocalRuntimeSupported)
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(messageA.capabilities))
    }

    private func assertGenericQPeriaptSurfaceFailsClosed(
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail(
                "generic Q-Periapt crypto surface must be unavailable",
                file: file,
                line: line
            )
        } catch CryptoProviderError.operationFailed(let reason) {
            XCTAssertEqual(
                reason,
                "Q-Periapt ABI2 is available only through the canonical MessageA application-context KEM surface",
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected generic surface error: \(error)", file: file, line: line)
        }
    }

    private func requirePromptCompletion<T: Sendable>(
        timeout: Duration = .milliseconds(250),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let operationTask = Task {
            try await operation()
        }
        let deadlineTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            operationTask.cancel()
        }
        defer { deadlineTask.cancel() }
        return try await operationTask.value
    }

    private func replacing(
        _ material: QPeriaptSignedPolicyMaterial,
        policyTOML: Data? = nil,
        detachedSignature: Data? = nil,
        verificationKey: Data? = nil,
        verificationKeySHA256Pin: Data? = nil
    ) -> QPeriaptSignedPolicyMaterial {
        QPeriaptSignedPolicyMaterial(
            policyTOML: policyTOML ?? material.policyTOML,
            detachedSignature: detachedSignature ?? material.detachedSignature,
            verificationKey: verificationKey ?? material.verificationKey,
            verificationKeySHA256Pin: verificationKeySHA256Pin ?? material.verificationKeySHA256Pin,
            trustRootIdentifier: material.trustRootIdentifier
        )
    }

    private func assertPolicyBoundaryFailure(
        material: QPeriaptSignedPolicyMaterial,
        store: InMemoryTrustedStateStore,
        expected: ExpectedPolicyBoundaryFailure,
        enrollmentMode: QPeriaptEnrollmentMode = .explicitlyAuthorizedFirstEnrollment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await requirePromptCompletion {
                try await QPeriaptPolicyRuntime().resolveSession(
                    material: material,
                    enrollmentMode: enrollmentMode,
                    trustedStateStore: store
                )
            }
            XCTFail("Malformed Q-Periapt policy material must fail before admission", file: file, line: line)
        } catch let error as QPeriaptPolicyRuntimeError {
            switch (expected, error) {
            case (.emptyPolicy, .emptyPolicy):
                break
            case let (.oversizedPolicy(actual), .policyTooLarge(errorActual, maximum)):
                XCTAssertEqual(errorActual, actual, file: file, line: line)
                XCTAssertEqual(maximum, Int(Q_PERIAPT_MAX_SIGNED_POLICY_BYTES), file: file, line: line)
            case let (.signatureLength(actual), .invalidSignatureLength(errorActual, expectedLength)):
                XCTAssertEqual(errorActual, actual, file: file, line: line)
                XCTAssertEqual(expectedLength, 3_309, file: file, line: line)
            case let (.verificationKeyLength(actual), .invalidVerificationKeyLength(errorActual, expectedLength)):
                XCTAssertEqual(errorActual, actual, file: file, line: line)
                XCTAssertEqual(expectedLength, 1_952, file: file, line: line)
            case let (.pinLength(actual), .invalidVerificationKeyPinLength(errorActual, expectedLength)):
                XCTAssertEqual(errorActual, actual, file: file, line: line)
                XCTAssertEqual(expectedLength, SHA256.byteCount, file: file, line: line)
            case let (.trustedStateLength(actual), .invalidTrustedStateLength(errorActual, expectedLength)):
                XCTAssertEqual(errorActual, actual, file: file, line: line)
                XCTAssertEqual(
                    expectedLength,
                    Int(Q_PERIAPT_TRUSTED_POLICY_STATE_LEN),
                    file: file,
                    line: line
                )
            default:
                XCTFail("Unexpected Q-Periapt policy boundary error: \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected Q-Periapt policy boundary error: \(error)", file: file, line: line)
        }
    }

    private func makeSession() async throws -> QPeriaptRuntimeSession {
        let vector = try loadFixture()
        return try await QPeriaptPolicyRuntime().resolveSession(
            material: try makeMaterial(vector: vector),
            enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
            trustedStateStore: InMemoryTrustedStateStore()
        )
    }

    private func makeMaterial(vector: SignedPolicyVector) throws -> QPeriaptSignedPolicyMaterial {
        let verificationKey = try XCTUnwrap(Data(hexString: vector.verificationKey))
        return QPeriaptSignedPolicyMaterial(
            policyTOML: Data(vector.policyTOML.utf8),
            detachedSignature: try XCTUnwrap(Data(hexString: vector.signature)),
            verificationKey: verificationKey,
            verificationKeySHA256Pin: Data(SHA256.hash(data: verificationKey)),
            trustRootIdentifier: "test/q-periapt/abi2/upstream-vector"
        )
    }

    private func trustedState(version: UInt32, digest: Data) -> Data {
        var state = Data([
            UInt8((version >> 24) & 0xFF),
            UInt8((version >> 16) & 0xFF),
            UInt8((version >> 8) & 0xFF),
            UInt8(version & 0xFF)
        ])
        state.append(digest)
        return state
    }

    private func loadFixture() throws -> SignedPolicyVector {
        try decodeFixture(loadFixtureData())
    }

    private func decodeFixture(_ data: Data) throws -> SignedPolicyVector {
        try JSONDecoder().decode(SignedPolicyVector.self, from: data)
    }

    private func loadFixtureData() throws -> Data {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(forResource: "signed-policy-vectors", withExtension: "json")
        )
        return try Data(contentsOf: fixtureURL, options: [.mappedIfSafe])
    }
}
#endif
