import XCTest
@_spi(SkyBridgeSmokeDiagnostics) @testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class ExistingOnlyIdentityRuntimeTests: XCTestCase {
    func testReleasePolicyCompilesExistingOnlySmokeRuntimeOutOfSkyBridgeCore() throws {
        let package = try repositorySource("Package.swift")
        let manager = try repositorySource(
            "Sources/SkyBridgeCore/P2P/DeviceIdentityKeyManager.swift"
        )
        let policyBlock = try sourceSlice(
            manager,
            from: "#if SKYBRIDGE_RELEASE_EXCLUDES_SMOKE_IDENTITY_RUNTIME",
            to: "private nonisolated(unsafe) static var inMemoryStore"
        )

        XCTAssertTrue(
            package.contains(
                "let excludeSmokeSupportFromRelease = shouldExcludeSmokeSupportFromRelease()"
            )
        )
        XCTAssertTrue(
            package.contains(
                "excludeSmokeSupportFromRelease ? [] : [\"SkyBridgeSmokeSupport\"]"
            )
        )
        XCTAssertTrue(
            package.contains(
                ".define(\"SKYBRIDGE_RELEASE_EXCLUDES_SMOKE_IDENTITY_RUNTIME\")"
            )
        )
        XCTAssertTrue(
            package.contains("+ smokeIdentityRuntimeProductionSwiftSettings")
        )
        XCTAssertTrue(
            policyBlock.contains(
                "nonisolated static let requiresExistingOnlyIdentityRuntime = false"
            )
        )
        let shippingBranch = try sourceSlice(
            String(policyBlock),
            from: "#if SKYBRIDGE_RELEASE_EXCLUDES_SMOKE_IDENTITY_RUNTIME",
            to: "#else"
        )
        XCTAssertFalse(shippingBranch.contains("SKYBRIDGE_SMOKE_IDENTITY_EXISTING_ONLY"))
        XCTAssertFalse(shippingBranch.contains("SKYBRIDGE_SMOKE_ROLE"))
        XCTAssertFalse(
            shippingBranch.contains(
                "activateExistingOnlyIdentityRuntimeForSmokeDiagnostics"
            )
        )
    }

    func testNormalTestAndSmokeHostBuildsRetainExistingOnlyDiagnosticSPI() throws {
        XCTAssertEqual(
            DeviceIdentityKeyManager.existingOnlySmokeEnvironmentKey,
            "SKYBRIDGE_SMOKE_IDENTITY_EXISTING_ONLY"
        )
        let activation: () throws -> Void =
            DeviceIdentityKeyManager.activateExistingOnlyIdentityRuntimeForSmokeDiagnostics
        _ = activation
        _ = DeviceIdentityKeyManager.usesExistingOnlyIdentityRuntimeForCurrentProcess

        let host = try repositorySource("Sources/LocalLanInteropHost/main.swift")
        XCTAssertTrue(host.contains("@_spi(SkyBridgeSmokeDiagnostics) import SkyBridgeCore"))
        XCTAssertTrue(
            host.contains(
                "DeviceIdentityKeyManager.activateExistingOnlyIdentityRuntimeForSmokeDiagnostics()"
            )
        )
        XCTAssertTrue(
            host.contains("DeviceIdentityKeyManager.existingOnlySmokeEnvironmentKey")
        )
    }

    func testStrictKEMLoaderDoesNotGenerateWhenCanonicalIdentityIsMissing() async throws {
        let context = try DeviceIdentityKeychainTestContext()
        defer { try? context.reset() }
        let provider = NoGenerationKEMProvider()

        let identity = try await context.manager.existingKEMIdentityKeyStrict(
            for: .mlkem768MLDSA65,
            provider: provider
        )

        XCTAssertNil(identity)
        let stored = try await context.manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
            tier: .nativePQC
        )
        XCTAssertNil(stored)
    }

    func testStrictKEMLoaderReturnsTheExactTieredCanonicalIdentity() async throws {
        let context = try DeviceIdentityKeychainTestContext()
        defer { try? context.reset() }
        let keyPair = try Self.nativeMLKEMKeyPair(
            publicByte: 0xA5,
            privateByte: 0x5A
        )
        let provider = DeterministicExistingOnlyKEMProvider(
            generatedKeyPair: keyPair
        )
        _ = try await context.manager.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65,
            provider: provider
        )

        let identity = try await context.manager.existingKEMIdentityKeyStrict(
            for: .mlkem768MLDSA65,
            provider: NoGenerationKEMProvider()
        )

        XCTAssertEqual(identity?.publicKey, keyPair.publicKey.bytes)
        XCTAssertEqual(identity?.privateKey.data, keyPair.privateKey.bytes)
    }

    func testStrictKEMLoaderRejectsUntieredLegacyWithoutMigratingOrDeleting() async throws {
        let context = try DeviceIdentityKeychainTestContext()
        let manager = context.manager
        defer { try? context.reset() }
        let canonicalKeyPair = try Self.nativeMLKEMKeyPair(
            publicByte: 0xA5,
            privateByte: 0x5A
        )
        let provider = DeterministicExistingOnlyKEMProvider(
            generatedKeyPair: canonicalKeyPair
        )
        _ = try await manager.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65,
            provider: provider
        )
        let legacyRecord = KEMIdentityKeyRecord(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
            publicKey: Data(repeating: 0x31, count: 1_184),
            privateKey: Data(repeating: 0x42, count: 2_400),
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        try await manager.seedUntieredKEMIdentityRecordForTesting(legacyRecord)

        do {
            _ = try await manager.existingKEMIdentityKeyStrict(
                for: .mlkem768MLDSA65,
                provider: provider
            )
            XCTFail("Untiered KEM identity state must require explicit migration")
        } catch DeviceIdentityKeyError.incompleteKeyMaterial(let reason) {
            XCTAssertTrue(reason.contains("Untiered KEM identity"))
        }

        let survivingCanonical = try await manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
            tier: .nativePQC
        )
        let survivingLegacy = try await manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
            tier: nil
        )
        XCTAssertEqual(survivingCanonical?.publicKey, canonicalKeyPair.publicKey.bytes)
        XCTAssertEqual(survivingLegacy, legacyRecord)
    }

    @MainActor
    func testSettingsExistingOnlyStartupKeepsQPeriaptDarkAndDoesNotWriteIdentityMirror()
        async throws {
        let suiteName = "ExistingOnlyIdentityRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mirrorKey = "Settings.PQCSignatureAlgorithm"
        let mirrorSentinel = "pre-existing-mirror-must-not-change"
        defaults.set(mirrorSentinel, forKey: mirrorKey)
        let qPeriaptProbe = QPeriaptRuntimePreparationProbe()
        let environmentProbe = QPeriaptEnvironmentPreferenceProbe()
        let manager = SettingsManager(
            testingUserDefaults: defaults,
            existingOnlyIdentityRuntime: true,
            qPeriaptRuntimeSupportPreparer: {
                await qPeriaptProbe.prepare()
            },
            qPeriaptEnvironmentPreferenceApplier: {
                environmentProbe.apply($0)
            }
        )

        await manager.waitForStartupTasksForTesting()

        let qPeriaptPreparationCalls = await qPeriaptProbe.callCount()
        XCTAssertEqual(qPeriaptPreparationCalls, 0)
        XCTAssertFalse(environmentProbe.appliedValues.isEmpty)
        XCTAssertTrue(environmentProbe.appliedValues.allSatisfy { !$0 })
        XCTAssertFalse(manager.qPeriaptRuntimeSupported)
        XCTAssertEqual(
            manager.protocolIdentityConfigurationState,
            .requiresExplicitConfirmation
        )
        XCTAssertTrue(
            manager.protocolIdentityConfigurationError?.contains(
                "requires a committed v2 protocol identity configuration"
            ) == true
        )
        XCTAssertNil(
            defaults.data(
                forKey: SettingsStorageKeys.protocolIdentityConfigurationV2
            )
        )
        XCTAssertEqual(defaults.string(forKey: mirrorKey), mirrorSentinel)
    }

    @MainActor
    func testSettingsNormalStartupPreservesQPeriaptPreparationAndIdentityMirror()
        async throws {
        let suiteName = "ExistingOnlyIdentityRuntimeTests.normal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mirrorKey = "Settings.PQCSignatureAlgorithm"
        defaults.set("stale-normal-mode-mirror", forKey: mirrorKey)
        defaults.set(
            Data([0xFF]),
            forKey: SettingsStorageKeys.protocolIdentityConfigurationV2
        )
        let qPeriaptProbe = QPeriaptRuntimePreparationProbe()
        let environmentProbe = QPeriaptEnvironmentPreferenceProbe()
        let manager = SettingsManager(
            testingUserDefaults: defaults,
            existingOnlyIdentityRuntime: false,
            qPeriaptRuntimeSupportPreparer: {
                await qPeriaptProbe.prepare(result: true)
            },
            qPeriaptEnvironmentPreferenceApplier: {
                environmentProbe.apply($0)
            }
        )

        await manager.waitForStartupTasksForTesting()

        let qPeriaptPreparationCalls = await qPeriaptProbe.callCount()
        XCTAssertEqual(qPeriaptPreparationCalls, 1)
        XCTAssertTrue(manager.qPeriaptRuntimeSupported)
        XCTAssertFalse(environmentProbe.appliedValues.isEmpty)
        XCTAssertTrue(environmentProbe.appliedValues.allSatisfy { !$0 })
        XCTAssertEqual(
            manager.protocolIdentityConfigurationState,
            .requiresExplicitConfirmation
        )
        XCTAssertEqual(defaults.string(forKey: mirrorKey), "ML-DSA-65")
    }

    func testHostActivatesExistingOnlyPolicyBeforeApplicationAndServices() throws {
        let host = try repositorySource("Sources/LocalLanInteropHost/main.swift")
        let activation = try XCTUnwrap(
            host.range(
                of: ".activateExistingOnlyIdentityRuntimeForSmokeDiagnostics()"
            )?.lowerBound
        )
        let application = try XCTUnwrap(
            host.range(of: "let application = NSApplication.shared")?.lowerBound
        )
        let coordinator = try XCTUnwrap(
            host.range(of: "let coordinator = LocalLanInteropHostCoordinator()")?
                .lowerBound
        )

        XCTAssertLessThan(activation, application)
        XCTAssertLessThan(activation, coordinator)
        XCTAssertTrue(host.contains("invalid existing-only identity mode"))
        XCTAssertTrue(
            host.contains(
                "identity-policy mode=existing-only mutation=denied source=explicit-smoke-environment"
            )
        )
        XCTAssertTrue(host.contains(".existingIdentityKeyInfoStrict()"))
        XCTAssertTrue(host.contains("CommittedLocalProtocolIdentitySnapshot.loadActive("))
    }

    func testExistingOnlyRoutesAreCanonicalAndSettingsRestoreDoesNotPersist() throws {
        let manager = try repositorySource(
            "Sources/SkyBridgeCore/P2P/DeviceIdentityKeyManager.swift"
        )
        let store = try repositorySource(
            "Sources/SkyBridgeCore/Security/PQCKeyPairStore.swift"
        )
        let settings = try repositorySource(
            "Sources/SkyBridgeCore/Settings/SettingsManager.swift"
        )
        let selfIdentity = try repositorySource(
            "Sources/SkyBridgeCore/Utilities/SelfIdentityProvider.swift"
        )
        let callback = try repositorySource(
            "Sources/SkyBridgeCore/P2P/SecureEnclaveMLDSAIdentity.swift"
        )

        let strictKEMBody = try sourceSlice(
            manager,
            from: "public func existingKEMIdentityKeyStrict(",
            to: "/// \u{83b7}\u{53d6} KEM \u{8eab}\u{4efd}\u{516c}\u{94a5}"
        )
        for forbidden in [
            "generateKeyPair",
            "saveKEMKeyRecord",
            "deleteGenericPasswordItems",
            "loadKEMKeyRecord(suiteWireId:"
        ] {
            XCTAssertFalse(strictKEMBody.contains(forbidden))
        }
        XCTAssertTrue(strictKEMBody.contains("includeLegacyMigration: false"))
        XCTAssertTrue(strictKEMBody.contains("rejectLegacyKEMIdentityState("))
        let strictStoreBody = try sourceSlice(
            store,
            from: "static func loadExistingAuthoritativeOnly(",
            to: "private static func load("
        )
        XCTAssertTrue(strictStoreBody.contains("includeLegacyKeychain: false"))
        for forbidden in [
            "insertKeyIfAbsent",
            "deleteLegacyGenericPasswordCandidate",
            "reconcileLegacy",
            "loadOrMigrateLegacy",
            "requireAuthority("
        ] {
            XCTAssertFalse(strictStoreBody.contains(forbidden))
        }
        XCTAssertTrue(manager.contains("allowLegacyMigration: !existingOnly"))
        XCTAssertTrue(manager.contains("existingSigningPublicKeyStrict("))
        XCTAssertTrue(store.contains("static func loadExistingAuthoritativeOnly("))
        XCTAssertTrue(
            settings.contains(
                "Existing-only runtime requires a committed v2 protocol identity configuration"
            )
        )
        XCTAssertTrue(settings.contains("if !existingOnly {\n                try persistProtocolIdentityConfiguration"))
        let qPeriaptPreparation = try sourceSlice(
            settings,
            from: "private func prepareQPeriaptRuntimeSupport() async {",
            to: "private func applyWeatherRuntimeSetting("
        )
        let qPeriaptGuard = try XCTUnwrap(
            qPeriaptPreparation.range(
                of: "guard !requiresExistingOnlyIdentityRuntime else"
            )?.lowerBound
        )
        let qPeriaptProvisioning = try XCTUnwrap(
            qPeriaptPreparation.range(
                of: "await qPeriaptRuntimeSupportPreparer()"
            )?.lowerBound
        )
        XCTAssertLessThan(qPeriaptGuard, qPeriaptProvisioning)
        let pqcSignatureSink = try sourceSlice(
            settings,
            from: "$pqcSignatureAlgorithm.sink",
            to: "$enablePQCHybridTLS.sink"
        )
        XCTAssertTrue(
            pqcSignatureSink.contains(
                "guard !self.requiresExistingOnlyIdentityRuntime else { return }"
            )
        )
        XCTAssertTrue(
            selfIdentity.contains(
                "!DeviceIdentityKeyManager.requiresExistingOnlyIdentityRuntime"
            )
        )
        XCTAssertTrue(callback.contains("OQSBridge.signExistingOnly("))
    }

    private static func nativeMLKEMKeyPair(
        publicByte: UInt8,
        privateByte: UInt8
    ) throws -> KeyPair {
        try KeyPair(
            publicKey: KeyMaterial(
                suite: .mlkem768MLDSA65,
                usage: .keyExchange,
                bytes: Data(repeating: publicByte, count: 1_184)
            ),
            privateKey: KeyMaterial(
                suite: .mlkem768MLDSA65,
                usage: .keyExchange,
                bytes: Data(repeating: privateByte, count: 96)
            )
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSlice(
        _ source: String,
        from start: String,
        to end: String
    ) throws -> Substring {
        let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
        let endIndex = try XCTUnwrap(
            source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound
        )
        return source[startIndex..<endIndex]
    }
}

private actor QPeriaptRuntimePreparationProbe {
    private var calls = 0

    func prepare(result: Bool = true) -> Bool {
        calls += 1
        return result
    }

    func callCount() -> Int {
        calls
    }
}

@MainActor
private final class QPeriaptEnvironmentPreferenceProbe {
    private(set) var appliedValues: [Bool] = []

    func apply(_ enabled: Bool) {
        appliedValues.append(enabled)
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct NoGenerationKEMProvider: CryptoProvider, Sendable {
    let providerName = "NoGenerationKEM"
    let tier = CryptoTier.nativePQC
    let activeSuite = CryptoSuite.mlkem768MLDSA65
    let supportedSuites = [CryptoSuite.mlkem768MLDSA65]

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains { $0.wireId == suite.wireId }
    }

    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        throw CryptoProviderError.notImplemented("NoGenerationKEM.hpkeSeal")
    }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        throw CryptoProviderError.notImplemented("NoGenerationKEM.hpkeOpen")
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.notImplemented("NoGenerationKEM.sign")
    }

    func verify(
        data: Data,
        signature: Data,
        publicKey: Data
    ) async throws -> Bool {
        throw CryptoProviderError.notImplemented("NoGenerationKEM.verify")
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw CryptoProviderError.notImplemented(
            "Strict existing-only KEM loading must not generate key material"
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct DeterministicExistingOnlyKEMProvider: CryptoProvider, Sendable {
    let providerName = "DeterministicExistingOnlyKEM"
    let tier = CryptoTier.nativePQC
    let activeSuite = CryptoSuite.mlkem768MLDSA65
    let supportedSuites = [CryptoSuite.mlkem768MLDSA65]
    let generatedKeyPair: KeyPair

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains { $0.wireId == suite.wireId }
    }

    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        throw CryptoProviderError.notImplemented(
            "DeterministicExistingOnlyKEM.hpkeSeal"
        )
    }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        throw CryptoProviderError.notImplemented(
            "DeterministicExistingOnlyKEM.hpkeOpen"
        )
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.notImplemented(
            "DeterministicExistingOnlyKEM.sign"
        )
    }

    func verify(
        data: Data,
        signature: Data,
        publicKey: Data
    ) async throws -> Bool {
        throw CryptoProviderError.notImplemented(
            "DeterministicExistingOnlyKEM.verify"
        )
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        generatedKeyPair
    }
}
