import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class QPeriaptABI2AdmissionBoundaryTests: XCTestCase {
    func testHandshakeContextRejectsExplicitLegacySuiteBeforeCryptoWork() async throws {
        let probe = QPeriaptCryptoOperationProbe()
        let provider = LegacyAdvertisingCryptoProvider(
            supportedSuites: [.qperiaptContextBound],
            probe: probe
        )
        let context = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider,
            cryptoPolicy: .init(
                minimumSecurityTier: .hybridPreferred,
                allowExperimentalHybrid: true,
                advertiseHybrid: true
            ),
            peerKEMPublicKeys: [
                .qperiaptContextBound: Data(
                    repeating: 0x11,
                    count: QPeriaptPlatformPolicy.publicKeyLength
                )
            ]
        )

        await assertSuiteNegotiationFailure {
            _ = try await context.buildMessageA(
                identityKeyHandle: nil,
                identityPublicKey: Data(),
                offeredSuites: [.qperiaptContextBound]
            )
        }
        let operationCount = await probe.operationCount()
        XCTAssertEqual(operationCount, 0)
    }

    func testHandshakeContextRejectsMixedLegacyAndABI2ListWithoutDowngrade() async throws {
        let probe = QPeriaptCryptoOperationProbe()
        let provider = LegacyAdvertisingCryptoProvider(
            supportedSuites: [.qperiaptContextBound, .qperiaptABI2PolicyBound],
            probe: probe
        )
        let context = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider,
            cryptoPolicy: .init(
                minimumSecurityTier: .hybridPreferred,
                allowExperimentalHybrid: true,
                advertiseHybrid: true
            ),
            peerKEMPublicKeys: [
                .qperiaptContextBound: Data(
                    repeating: 0x12,
                    count: QPeriaptPlatformPolicy.publicKeyLength
                ),
                .qperiaptABI2PolicyBound: Data(
                    repeating: 0x13,
                    count: QPeriaptPlatformPolicy.publicKeyLength
                )
            ]
        )

        await assertSuiteNegotiationFailure {
            _ = try await context.buildMessageA(
                identityKeyHandle: nil,
                identityPublicKey: Data(),
                offeredSuites: [.qperiaptContextBound, .qperiaptABI2PolicyBound]
            )
        }
        let operationCount = await probe.operationCount()
        XCTAssertEqual(operationCount, 0)
    }

    func testHandshakeContextRejectsImplicitLegacyOnlyProviderBeforeCryptoWork() async throws {
        let probe = QPeriaptCryptoOperationProbe()
        let provider = LegacyAdvertisingCryptoProvider(
            supportedSuites: [.qperiaptContextBound],
            probe: probe
        )
        let context = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider,
            cryptoPolicy: .init(
                minimumSecurityTier: .hybridPreferred,
                allowExperimentalHybrid: true,
                advertiseHybrid: true
            ),
            peerKEMPublicKeys: [
                .qperiaptContextBound: Data(
                    repeating: 0x14,
                    count: QPeriaptPlatformPolicy.publicKeyLength
                )
            ]
        )

        await assertSuiteNegotiationFailure {
            _ = try await context.buildMessageA(
                identityKeyHandle: nil,
                identityPublicKey: Data()
            )
        }
        let operationCount = await probe.operationCount()
        XCTAssertEqual(operationCount, 0)
    }

    func testHandshakeDriverRejectsLegacySuiteAtInitializerBoundary() {
        let provider = LegacyAdvertisingCryptoProvider(
            supportedSuites: [.qperiaptContextBound],
            probe: QPeriaptCryptoOperationProbe()
        )

        XCTAssertThrowsError(
            try HandshakeDriver(
                transport: MockDiscoveryTransport(),
                cryptoProvider: provider,
                protocolSignatureProvider: PQCSignatureProvider(backend: .oqs),
                protocolSigningKeyHandle: .softwareKey(Data(repeating: 0x21, count: 64)),
                sigAAlgorithm: .mlDSA65,
                identityPublicKey: encodeIdentityPublicKey(
                    Data(repeating: 0x22, count: 1_952),
                    algorithm: .mlDSA65
                ),
                offeredSuites: [.qperiaptContextBound]
            )
        ) { error in
            guard case HandshakeError.failed(.suiteNotSupported) = error else {
                XCTFail("Expected suiteNotSupported, got \(error)")
                return
            }
        }
    }

    func testProviderCapabilityExportExcludesLegacySuite() {
        let provider = LegacyAdvertisingCryptoProvider(
            supportedSuites: [
                .qperiaptContextBound,
                .qperiaptABI2PolicyBound,
                .mlkem768MLDSA65
            ],
            probe: QPeriaptCryptoOperationProbe()
        )

        XCTAssertEqual(
            CryptoProviderFactory.handshakeOfferedPQCSuites(using: provider).map(\.wireId),
            [
                CryptoSuite.qperiaptABI2PolicyBound.wireId,
                CryptoSuite.mlkem768MLDSA65.wireId
            ]
        )
    }

    func testQPeriaptKEMIdentityLengthContractIsABI2AndProviderBound() {
        XCTAssertNil(
            KEMIdentityKeyLengthContract.resolve(
                suite: .qperiaptContextBound,
                providerTier: .qperiaptPQC
            )
        )
        XCTAssertEqual(
            KEMIdentityKeyLengthContract.resolve(
                suite: .qperiaptABI2PolicyBound,
                providerTier: .qperiaptPQC
            ),
            .init(
                publicKeyLength: QPeriaptPlatformPolicy.publicKeyLength,
                privateKeyLength: QPeriaptPlatformPolicy.privateKeyLength
            )
        )
        XCTAssertNil(
            KEMIdentityKeyLengthContract.resolve(
                suite: .qperiaptABI2PolicyBound,
                providerTier: .liboqsPQC
            )
        )
    }

    private func assertSuiteNegotiationFailure(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected suite negotiation failure", file: file, line: line)
        } catch HandshakeError.failed(.suiteNegotiationFailed) {
            return
        } catch {
            XCTFail("Expected suiteNegotiationFailed, got \(error)", file: file, line: line)
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
private actor QPeriaptCryptoOperationProbe {
    private var operations = 0

    func recordOperation() {
        operations += 1
    }

    func operationCount() -> Int {
        operations
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct LegacyAdvertisingCryptoProvider: CryptoProvider, Sendable {
    let providerName = "LegacyAdvertisingCryptoProvider"
    let tier: CryptoTier = .qperiaptPQC
    let activeSuite: CryptoSuite
    let supportedSuites: [CryptoSuite]
    let probe: QPeriaptCryptoOperationProbe

    init(
        supportedSuites: [CryptoSuite],
        probe: QPeriaptCryptoOperationProbe
    ) {
        precondition(!supportedSuites.isEmpty)
        activeSuite = supportedSuites[0]
        self.supportedSuites = supportedSuites
        self.probe = probe
    }

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains { $0.wireId == suite.wireId }
    }

    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        try await unexpectedOperation("hpkeSeal")
    }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        try await unexpectedOperation("hpkeOpen")
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        try await unexpectedOperation("sign")
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        try await unexpectedOperation("verify")
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        try await unexpectedOperation("generateKeyPair")
    }

    private func unexpectedOperation<T>(_ name: String) async throws -> T {
        await probe.recordOperation()
        throw CryptoProviderError.operationFailed(
            "Unexpected crypto operation before Q-Periapt ABI admission: \(name)"
        )
    }
}
