import CryptoKit
import Network
import os
import XCTest
@testable import SkyBridgeCompass_iOS

final class AppleMobileDeviceIdentityTests: XCTestCase {
    private enum ListenerIdentityFailure: Error {
        case unavailable
        case factoryCalled
    }

    func testSmokeIdentityOverrideRequiresAllowlistedRoleAndDedicatedAuthorization() throws {
        XCTAssertNil(
            try ProtocolDeviceIdentity.validatedExplicitSmokeOverrideDeviceId(
                environment: [:]
            )
        )
        XCTAssertThrowsError(
            try ProtocolDeviceIdentity.validatedExplicitSmokeOverrideDeviceId(
                environment: [
                    "SKYBRIDGE_SMOKE_ROLE": "ios-client",
                    "SKYBRIDGE_DEVICE_ID": "smoke-device"
                ]
            )
        )
        XCTAssertThrowsError(
            try ProtocolDeviceIdentity.validatedExplicitSmokeOverrideDeviceId(
                environment: [
                    "SKYBRIDGE_SMOKE_ROLE": "unknown-smoke",
                    "SKYBRIDGE_SMOKE_ALLOW_IDENTITY_OVERRIDE": "1",
                    "SKYBRIDGE_DEVICE_ID": "smoke-device"
                ]
            )
        )
        XCTAssertThrowsError(
            try ProtocolDeviceIdentity.validatedExplicitSmokeOverrideDeviceId(
                environment: [
                    "SKYBRIDGE_SMOKE_ROLE": " ios-client ",
                    "SKYBRIDGE_SMOKE_ALLOW_IDENTITY_OVERRIDE": "1",
                    "SKYBRIDGE_DEVICE_ID": "smoke-device"
                ]
            )
        )
        XCTAssertEqual(
            try ProtocolDeviceIdentity.validatedExplicitSmokeOverrideDeviceId(
                environment: [
                    "SKYBRIDGE_SMOKE_ROLE": "ios-p2p-client",
                    "SKYBRIDGE_SMOKE_ALLOW_IDENTITY_OVERRIDE": "1",
                    "SKYBRIDGE_DEVICE_ID": "smoke-device"
                ]
            ),
            "smoke-device"
        )
    }

    func testDefaultAppEntitlementsDoNotRequestUserAssignedDeviceNameAccess() throws {
        for fileName in [
            "SkyBridgeCompass-iOSDebug.entitlements",
            "SkyBridgeCompass-iOSRelease.entitlements"
        ] {
            let entitlements = try loadEntitlements(named: fileName)
            XCTAssertNil(
                entitlements["com.apple.developer.device-information.user-assigned-device-name"],
                "\(fileName) must not request Apple's restricted user-assigned device-name entitlement by default; ordinary development profiles cannot sign it."
            )
        }
    }

    func testProtocolIdentitySharedKeychainEntitlementIsPresentInAllConfigurations() throws {
        for fileName in [
            "SkyBridgeCompass-iOSDebug.entitlements",
            "SkyBridgeCompass-iOSRelease.entitlements"
        ] {
            let entitlements = try loadEntitlements(named: fileName)
            let groups = try XCTUnwrap(entitlements["keychain-access-groups"] as? [String])
            XCTAssertTrue(
                groups.contains("$(AppIdentifierPrefix)group.com.skybridge.compass"),
                "\(fileName) must authorize the app/extension shared identity namespace"
            )
        }
    }

    func testSecurityConsumersCannotBypassBoundProtocolIdentitySnapshot() throws {
        let platform = try loadSource(
            "SkyBridgeCompassiOS/Sources/Core/Platform/PlatformAdapter.swift"
        )
        XCTAssertTrue(platform.contains("@MainActor\npublic final class SkyBridgeiOSCore"))
        XCTAssertFalse(platform.contains("SkyBridgeiOSCore: @unchecked Sendable"))
        XCTAssertTrue(
            platform.contains("identitySnapshot.signingPublicKey == publicKey"),
            "Every handshake driver must validate the complete signing snapshot"
        )

        let discovery = try loadSource(
            "SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )
        XCTAssertTrue(discovery.contains("currentProtocolIdentitySnapshot()"))
        XCTAssertTrue(discovery.contains("record[\"protocolSigningAlgorithm\"]"))
        XCTAssertTrue(discovery.contains("record[\"identityFingerprint\"]"))

        let transfer = try loadSource(
            "SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift"
        )
        XCTAssertTrue(transfer.contains("currentProtocolIdentitySnapshot()"))
        XCTAssertTrue(transfer.contains("protocolIdentityFingerprint:"))
        let transferIdentityOffset = try XCTUnwrap(
            transfer.range(of: "currentProtocolIdentitySnapshot()")?.lowerBound
        )
        let transferListenerOffset = try XCTUnwrap(
            transfer.range(of: "listener = try listenerFactory(")?.lowerBound
        )
        XCTAssertLessThan(
            transferIdentityOffset,
            transferListenerOffset,
            "Cancellation or identity failure must occur before listener allocation"
        )

        let models = try loadSource("SkyBridgeCompassiOS/Sources/Models.swift")
        XCTAssertFalse(
            models.contains("stableDeviceId"),
            "Presentation metadata must not expose a second protocol identity source"
        )
    }

    func testFileTransferIdentityFailureDoesNotAllocateOrStartListener() async {
        let listenerFactoryCalls = OSAllocatedUnfairLock(initialState: 0)
        let service = FileTransferNetworkService(
            port: 0,
            protocolIdentityResolver: {
                throw ListenerIdentityFailure.unavailable
            },
            listenerFactory: { _, _ in
                listenerFactoryCalls.withLock { $0 += 1 }
                throw ListenerIdentityFailure.factoryCalled
            }
        )

        do {
            try await service.startListening()
            XCTFail("Identity failure must abort listener startup")
        } catch ListenerIdentityFailure.unavailable {
            // Expected: authority resolution is the first fallible side effect.
        } catch {
            XCTFail("Unexpected startup error: \(error)")
        }

        XCTAssertEqual(listenerFactoryCalls.withLock { $0 }, 0)
        let isHealthy = await service.isHealthy()
        XCTAssertFalse(isHealthy)
    }

    func testRegistrationFingerprintUsesVersionedAuthorityTuple() {
        let first = AuthenticationManager.registrationDeviceFingerprint(
            deviceId: "device-a",
            signingPublicKeyFingerprint: String(repeating: "a", count: 64)
        )
        let same = AuthenticationManager.registrationDeviceFingerprint(
            deviceId: "device-a",
            signingPublicKeyFingerprint: String(repeating: "a", count: 64)
        )
        let differentKey = AuthenticationManager.registrationDeviceFingerprint(
            deviceId: "device-a",
            signingPublicKeyFingerprint: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(first, same)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, differentKey)
    }

    func testRegistrationRiskAuditAndMetadataReuseOneAuthorityFingerprint() throws {
        let authentication = try loadSource(
            "SkyBridgeCompassiOS/Sources/Managers/AuthenticationManager.swift"
        )
        XCTAssertTrue(authentication.contains("currentProtocolIdentitySnapshot()"))
        XCTAssertTrue(authentication.contains("com.skybridge.registration-device-fingerprint.v1"))
        XCTAssertTrue(authentication.contains("let deviceFingerprint: String"))
        XCTAssertTrue(authentication.contains("deviceFingerprint: riskOutcome.deviceFingerprint"))
        XCTAssertTrue(authentication.contains("\"device_fingerprint\": riskOutcome.deviceFingerprint"))
        XCTAssertFalse(authentication.contains("UIDevice.current.identifierForVendor"))
        XCTAssertFalse(authentication.contains("\"unknown-vendor\""))
    }

    func testPresentationMapsKnownIPhoneModelIdentifier() {
        let presentation = AppleMobileDeviceIdentity.presentation(
            forModelIdentifier: "iPhone17,1",
            platform: .iOS
        )

        XCTAssertEqual(presentation.modelName, "iPhone 16 Pro")
        XCTAssertEqual(presentation.chip, "A18 Pro")
    }

    func testPresentationMapsKnownIPadModelIdentifier() {
        let presentation = AppleMobileDeviceIdentity.presentation(
            forModelIdentifier: "iPad16,3",
            platform: .iPadOS
        )

        XCTAssertEqual(presentation.modelName, "iPad Pro 11-inch (M4)")
        XCTAssertEqual(presentation.chip, "M4")
    }

    func testUnknownMobileIdentifierFallsBackToIdentifierAndGenericSoC() {
        let presentation = AppleMobileDeviceIdentity.presentation(
            forModelIdentifier: "iPad99,9",
            platform: .iPadOS
        )

        XCTAssertEqual(presentation.modelName, "iPad99,9")
        XCTAssertEqual(presentation.chip, "Apple SoC")
    }

    func testGenericIPadDeviceNameFallsBackToModelPresentation() {
        let displayName = AppleMobileDeviceIdentity.displayDeviceName(
            rawDeviceName: "iPad",
            platform: .iPadOS,
            modelName: "iPad Pro 11-inch (M4)"
        )

        XCTAssertEqual(displayName, "iPad Pro 11-inch (M4)")
    }

    func testPersonalizedDeviceNameIsPreservedWhenAvailable() {
        let displayName = AppleMobileDeviceIdentity.displayDeviceName(
            rawDeviceName: "Bill's iPad",
            platform: .iPadOS,
            modelName: "iPad Pro 11-inch (M4)"
        )

        XCTAssertEqual(displayName, "Bill's iPad")
    }

    private func loadEntitlements(named fileName: String) throws -> [String: Any] {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementURL = projectURL.appendingPathComponent(fileName)
        // 借助共享 helper：真机沙箱无仓库文件时 XCTSkip，而非误报失败。
        let data = Data(try readRepositorySourceForSourceShapeTests(at: entitlementURL).utf8)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(plist as? [String: Any])
    }

    private func loadSource(_ relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try readRepositorySourceForSourceShapeTests(
            at: projectURL.appendingPathComponent(relativePath)
        )
    }
}

@available(iOS 17.0, *)
final class ProtocolDeviceIdentityAuthorityTests: XCTestCase {
    private enum TestFailure: Error {
        case generatedUnexpectedly
        case invalidKeyMaterial
    }

    func testFiftyConcurrentResolutionsGenerateOnceAndReturnOneTuple() async throws {
        let store = ProtocolIdentityTestStore(
            defaultsDeviceIds: ["ios-concurrent-device"]
        )
        let authority = ProtocolDeviceIdentityAuthority {
            store
        }
        let generationCount = OSAllocatedUnfairLock(initialState: 0)
        let generated = Self.ed25519Material()

        let results = try await withThrowingTaskGroup(
            of: ResolvedProtocolSigningIdentity.self
        ) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await authority.resolveSigningIdentity(
                        for: .ed25519,
                        generate: {
                            generationCount.withLock { $0 += 1 }
                            return generated
                        },
                        validate: Self.validateEd25519,
                        decodeLegacy: Self.decodeLegacyEd25519
                    )
                }
            }
            var values: [ResolvedProtocolSigningIdentity] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(results.count, 50)
        XCTAssertEqual(Set(results.map(\.snapshot.deviceId)), ["ios-concurrent-device"])
        XCTAssertEqual(Set(results.map(\.snapshot.signingPublicKeyFingerprint)).count, 1)
        XCTAssertTrue(results.allSatisfy { $0.material == generated })
        XCTAssertEqual(generationCount.withLock { $0 }, 1)
        XCTAssertEqual(store.snapshot().deviceAuthorityInsertCount, 1)
        XCTAssertEqual(store.snapshot().signingKeyInsertCount, 1)
        XCTAssertEqual(store.snapshot().signingAuthorityInsertCount, 1)
    }

    func testDuplicateSigningCASReloadsCompetingWinner() async throws {
        let competingWinner = Self.ed25519Material()
        let store = ProtocolIdentityTestStore(
            defaultsDeviceIds: ["ios-cas-device"],
            forcedSigningWinner: try Self.encode(competingWinner)
        )
        let authority = ProtocolDeviceIdentityAuthority { store }
        let localCandidate = Self.ed25519Material()

        let resolved = try await authority.resolveSigningIdentity(
            for: .ed25519,
            generate: { localCandidate },
            validate: Self.validateEd25519,
            decodeLegacy: Self.decodeLegacyEd25519
        )

        XCTAssertEqual(resolved.material, competingWinner)
        XCTAssertNotEqual(resolved.material, localCandidate)
        XCTAssertEqual(resolved.snapshot.deviceId, "ios-cas-device")
        XCTAssertEqual(store.snapshot().signingKeyInsertCount, 1)
        XCTAssertEqual(store.snapshot().signingAuthorityInsertCount, 1)
    }

    func testConflictingLegacyDeviceIdsFailWithoutMutation() async throws {
        let store = ProtocolIdentityTestStore(
            defaultsDeviceIds: ["legacy-a", "legacy-b"]
        )
        let authority = ProtocolDeviceIdentityAuthority { store }

        do {
            _ = try await authority.resolveDeviceId()
            XCTFail("Conflicting legacy authorities must fail closed")
        } catch let error as ProtocolDeviceIdentityError {
            XCTAssertEqual(error, .conflictingLegacyDeviceIds)
        }

        let state = store.snapshot()
        XCTAssertNil(state.deviceAuthority)
        XCTAssertEqual(state.deviceAuthorityInsertCount, 0)
        XCTAssertEqual(state.cleanupCount, 0)
        XCTAssertEqual(state.mirrorPublishCount, 0)
    }

    func testMatchingLegacyDeviceIdCleansOnlyAfterAuthorityCAS() async throws {
        let legacy = ProtocolIdentityLegacyItem(
            location: .persistentReference(Data([0xA1])),
            data: Data("legacy-device".utf8)
        )
        let store = ProtocolIdentityTestStore(
            defaultsDeviceIds: ["legacy-device"],
            legacyDeviceItems: [legacy]
        )
        let authority = ProtocolDeviceIdentityAuthority { store }

        let resolvedDeviceId = try await authority.resolveDeviceId()
        XCTAssertEqual(resolvedDeviceId, "legacy-device")

        let state = store.snapshot()
        XCTAssertNotNil(state.deviceAuthority)
        XCTAssertEqual(state.cleanupCount, 1)
        XCTAssertTrue(state.legacyDeviceItems.isEmpty)
        XCTAssertEqual(state.publishedMirror, "legacy-device")
        XCTAssertEqual(state.mirrorPublishCount, 1)
    }

    func testCancelledWaiterDoesNotAdvertiseButSharedConvergenceCompletes() async throws {
        let store = ProtocolIdentityTestStore(
            defaultsDeviceIds: ["ios-cancel-device"]
        )
        let authority = ProtocolDeviceIdentityAuthority { store }
        let gate = ProtocolIdentityTestGate()
        let material = Self.ed25519Material()
        let advertisementCount = OSAllocatedUnfairLock(initialState: 0)

        let cancelledWaiter = Task.detached { @Sendable in
            let resolved = try await authority.resolveSigningIdentity(
                for: .ed25519,
                generate: {
                    await gate.wait()
                    return material
                },
                validate: Self.validateEd25519,
                decodeLegacy: Self.decodeLegacyEd25519
            )
            advertisementCount.withLock { $0 += 1 }
            return resolved
        }

        await gate.waitUntilStarted()
        cancelledWaiter.cancel()
        await gate.open()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("A cancelled waiter must not receive an identity for advertisement")
        } catch is CancellationError {
            // Expected: the shared transaction completes, then this waiter is
            // rejected before its advertisement closure can run.
        }

        let next = try await authority.resolveSigningIdentity(
            for: .ed25519,
            generate: { throw TestFailure.generatedUnexpectedly },
            validate: Self.validateEd25519,
            decodeLegacy: Self.decodeLegacyEd25519
        )
        XCTAssertEqual(next.material, material)
        XCTAssertEqual(advertisementCount.withLock { $0 }, 0)
        XCTAssertNotNil(store.snapshot().signingAuthority)
    }

    func testCanonicalSigningIdentityCleansMatchingLegacyRemnantOnRetry() async throws {
        let store = ProtocolIdentityTestStore(
            defaultsDeviceIds: ["ios-signing-migration-device"]
        )
        let material = Self.ed25519Material()
        let firstAuthority = ProtocolDeviceIdentityAuthority { store }
        _ = try await firstAuthority.resolveSigningIdentity(
            for: .ed25519,
            generate: { material },
            validate: Self.validateEd25519,
            decodeLegacy: Self.decodeLegacyEd25519
        )

        var legacyEncoding = material.privateKey
        legacyEncoding.append(material.publicKey)
        store.installLegacySigningItems([
            ProtocolIdentityLegacyItem(
                location: .persistentReference(Data([0xB1])),
                data: legacyEncoding
            )
        ])

        let retryAuthority = ProtocolDeviceIdentityAuthority { store }
        let retried = try await retryAuthority.resolveSigningIdentity(
            for: .ed25519,
            generate: { throw TestFailure.generatedUnexpectedly },
            validate: Self.validateEd25519,
            decodeLegacy: Self.decodeLegacyEd25519
        )
        XCTAssertEqual(retried.material, material)
        XCTAssertTrue(store.snapshot().legacySigningItems.isEmpty)
        XCTAssertEqual(store.snapshot().cleanupCount, 1)
    }

    func testConflictingLegacySigningNamespacesDoNotPublishSigningAuthority() async throws {
        let store = ProtocolIdentityTestStore(
            defaultsDeviceIds: ["ios-signing-conflict-device"]
        )
        let deviceAuthority = ProtocolDeviceIdentityAuthority { store }
        _ = try await deviceAuthority.resolveDeviceId()

        let first = Self.ed25519Material()
        let second = Self.ed25519Material()
        func legacyEncoding(_ material: ProtocolSigningIdentityMaterial) -> Data {
            var encoded = material.privateKey
            encoded.append(material.publicKey)
            return encoded
        }
        store.installLegacySigningItems([
            ProtocolIdentityLegacyItem(
                location: .persistentReference(Data([0xC1])),
                data: legacyEncoding(first)
            ),
            ProtocolIdentityLegacyItem(
                location: .persistentReference(Data([0xC2])),
                data: legacyEncoding(second)
            )
        ])

        let signingAuthority = ProtocolDeviceIdentityAuthority { store }
        do {
            _ = try await signingAuthority.resolveSigningIdentity(
                for: .ed25519,
                generate: { throw TestFailure.generatedUnexpectedly },
                validate: Self.validateEd25519,
                decodeLegacy: Self.decodeLegacyEd25519
            )
            XCTFail("Conflicting signing namespaces must fail closed")
        } catch let error as ProtocolDeviceIdentityError {
            XCTAssertEqual(error, .legacySigningIdentityConflict(.ed25519))
        }

        let state = store.snapshot()
        XCTAssertNil(state.signingKey)
        XCTAssertNil(state.signingAuthority)
        XCTAssertEqual(state.signingKeyInsertCount, 0)
        XCTAssertEqual(state.signingAuthorityInsertCount, 0)
        XCTAssertEqual(state.cleanupCount, 0)
    }

    func testSmokeOverrideIsMemoryOnlyAndCannotBeInstalledLate() async throws {
        let factoryCount = OSAllocatedUnfairLock(initialState: 0)
        let store = ProtocolIdentityTestStore()
        let authority = ProtocolDeviceIdentityAuthority {
            factoryCount.withLock { $0 += 1 }
            return store
        }
        try await authority.configureSmokeOverride("smoke-ios-device")

        let resolved = try await authority.resolveSigningIdentity(
            for: .ed25519,
            generate: { Self.ed25519Material() },
            validate: Self.validateEd25519,
            decodeLegacy: Self.decodeLegacyEd25519
        )
        XCTAssertEqual(resolved.snapshot.deviceId, "smoke-ios-device")
        XCTAssertEqual(factoryCount.withLock { $0 }, 0)
        XCTAssertEqual(store.snapshot().totalMutationCount, 0)

        do {
            try await authority.configureSmokeOverride("other-smoke-device")
            XCTFail("A late smoke override must fail closed")
        } catch let error as ProtocolDeviceIdentityError {
            XCTAssertEqual(error, .smokeOverrideAfterResolution)
        }
    }

    private static func ed25519Material() -> ProtocolSigningIdentityMaterial {
        let privateKey = Curve25519.Signing.PrivateKey()
        return ProtocolSigningIdentityMaterial(
            algorithm: .ed25519,
            privateKey: privateKey.rawRepresentation,
            publicKey: privateKey.publicKey.rawRepresentation
        )
    }

    private static let validateEd25519: @Sendable (
        ProtocolSigningIdentityMaterial
    ) async throws -> Void = { material in
        guard material.algorithm == .ed25519,
              let privateKey = try? Curve25519.Signing.PrivateKey(
                  rawRepresentation: material.privateKey
              ),
              privateKey.publicKey.rawRepresentation == material.publicKey else {
            throw TestFailure.invalidKeyMaterial
        }
    }

    private static let decodeLegacyEd25519: @Sendable (
        Data
    ) throws -> ProtocolSigningIdentityMaterial = { data in
        guard data.count == 64 else { throw TestFailure.invalidKeyMaterial }
        return ProtocolSigningIdentityMaterial(
            algorithm: .ed25519,
            privateKey: Data(data.prefix(32)),
            publicKey: Data(data.suffix(32))
        )
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

@available(iOS 17.0, *)
private actor ProtocolIdentityTestGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@available(iOS 17.0, *)
private struct ProtocolIdentityTestStore: ProtocolIdentityPersistence, Sendable {
    struct State: Sendable {
        var deviceAuthority: Data?
        var signingKey: Data?
        var signingAuthority: Data?
        var defaultsDeviceIds: [String]
        var legacyDeviceItems: [ProtocolIdentityLegacyItem]
        var legacySigningItems: [ProtocolIdentityLegacyItem]
        var forcedSigningWinner: Data?
        var publishedMirror: String?
        var deviceAuthorityInsertCount = 0
        var signingKeyInsertCount = 0
        var signingAuthorityInsertCount = 0
        var cleanupCount = 0
        var mirrorPublishCount = 0

        var totalMutationCount: Int {
            deviceAuthorityInsertCount + signingKeyInsertCount
                + signingAuthorityInsertCount + cleanupCount + mirrorPublishCount
        }
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        defaultsDeviceIds: [String] = [],
        legacyDeviceItems: [ProtocolIdentityLegacyItem] = [],
        legacySigningItems: [ProtocolIdentityLegacyItem] = [],
        forcedSigningWinner: Data? = nil
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                defaultsDeviceIds: defaultsDeviceIds,
                legacyDeviceItems: legacyDeviceItems,
                legacySigningItems: legacySigningItems,
                forcedSigningWinner: forcedSigningWinner
            )
        )
    }

    func snapshot() -> State { state.withLock { $0 } }

    func installLegacySigningItems(_ items: [ProtocolIdentityLegacyItem]) {
        state.withLock { $0.legacySigningItems = items }
    }

    func loadDeviceAuthority() throws -> Data? {
        state.withLock { $0.deviceAuthority }
    }

    func insertDeviceAuthorityIfAbsent(_ data: Data) throws -> IOSKeychainInsertResult {
        state.withLock { value in
            value.deviceAuthorityInsertCount += 1
            guard value.deviceAuthority == nil else { return .alreadyExists }
            value.deviceAuthority = data
            return .inserted
        }
    }

    func loadSigningKey(for algorithm: ProtocolSigningAlgorithm) throws -> Data? {
        _ = algorithm
        return state.withLock { $0.signingKey }
    }

    func insertSigningKeyIfAbsent(
        _ data: Data,
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> IOSKeychainInsertResult {
        _ = algorithm
        return state.withLock { value in
            value.signingKeyInsertCount += 1
            guard value.signingKey == nil else { return .alreadyExists }
            if let forced = value.forcedSigningWinner {
                value.signingKey = forced
                return .alreadyExists
            }
            value.signingKey = data
            return .inserted
        }
    }

    func loadSigningAuthority(for algorithm: ProtocolSigningAlgorithm) throws -> Data? {
        _ = algorithm
        return state.withLock { $0.signingAuthority }
    }

    func insertSigningAuthorityIfAbsent(
        _ data: Data,
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> IOSKeychainInsertResult {
        _ = algorithm
        return state.withLock { value in
            value.signingAuthorityInsertCount += 1
            guard value.signingAuthority == nil else { return .alreadyExists }
            value.signingAuthority = data
            return .inserted
        }
    }

    func legacyDeviceIdCandidates() throws -> [ProtocolIdentityLegacyItem] {
        state.withLock { $0.legacyDeviceItems }
    }

    func legacySigningKeyCandidates(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> [ProtocolIdentityLegacyItem] {
        _ = algorithm
        return state.withLock { $0.legacySigningItems }
    }

    func deleteLegacyItemIfUnchanged(_ item: ProtocolIdentityLegacyItem) throws {
        state.withLock { value in
            if let index = value.legacyDeviceItems.firstIndex(of: item) {
                value.legacyDeviceItems.remove(at: index)
                value.cleanupCount += 1
                return
            }
            if let index = value.legacySigningItems.firstIndex(of: item) {
                value.legacySigningItems.remove(at: index)
                value.cleanupCount += 1
            }
        }
    }

    func legacyDefaultsDeviceIds() -> [String] {
        state.withLock { $0.defaultsDeviceIds }
    }

    func publishDeviceIdMirrors(_ deviceId: String) {
        state.withLock { value in
            value.publishedMirror = deviceId
            value.mirrorPublishCount += 1
        }
    }
}
