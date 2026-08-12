import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class KEMTrustStoreTests: XCTestCase {
    func testPersistAndRestoreKEMTrustStore() async throws {
        let suiteName = "KEMTrustStoreTests.\(UUID().uuidString)"
        guard let cleanupDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        cleanupDefaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.tests.v1"
        let deviceId = "peer-\(UUID().uuidString)"
        let keyInfo = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0xA5, count: 32)
        )

        guard let writerDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create writer UserDefaults suite")
            return
        }
        let writerStore = KEMTrustStore(storageKey: storageKey, userDefaults: writerDefaults)
        await writerStore.upsert(deviceId: deviceId, kemPublicKeys: [keyInfo])

        guard let readerDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create reader UserDefaults suite")
            return
        }
        let readerStore = KEMTrustStore(storageKey: storageKey, userDefaults: readerDefaults)
        let restored = await readerStore.kemPublicKeys(for: deviceId)

        XCTAssertEqual(restored[.mlkem768], keyInfo.publicKey)

        await readerStore.clear(deviceId: deviceId)
        let cleared = await readerStore.kemPublicKeys(for: deviceId)
        XCTAssertTrue(cleared.isEmpty)
    }

    func testLookupSupportsDiscoveryAndDeclaredIdentityAliases() async throws {
        let suiteName = "KEMTrustStoreAliasTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.alias.tests.v1"
        let rawDeviceId = UUID().uuidString.lowercased()
        let discoveryDeviceId = "id:\(rawDeviceId)"
        let endpointAlias = "host:192.168.10.22"
        let keyInfo = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x5A, count: 32)
        )

        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        await store.upsert(deviceId: rawDeviceId, kemPublicKeys: [keyInfo])
        await store.upsert(deviceId: endpointAlias, kemPublicKeys: [keyInfo])

        let fromDiscoveryId = await store.kemPublicKeys(for: discoveryDeviceId)
        let fromRawId = await store.kemPublicKeys(for: rawDeviceId)
        let fromEndpointAlias = await store.kemPublicKeys(for: endpointAlias)

        XCTAssertEqual(fromDiscoveryId[.mlkem768], keyInfo.publicKey)
        XCTAssertEqual(fromRawId[.mlkem768], keyInfo.publicKey)
        XCTAssertEqual(fromEndpointAlias[.mlkem768], keyInfo.publicKey)
    }

    func testExactExistingAdmissionDoesNotRewritePersistentStore() async throws {
        let suiteName = "KEMTrustStoreReadOnlyTests.\(UUID().uuidString)"
        guard let writerDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        writerDefaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.read_only.tests.v1"
        let deviceId = "peer-\(UUID().uuidString)"
        let keyInfo = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.xwing.wireId,
            publicKey: Data(repeating: 0xC3, count: 64)
        )
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: writerDefaults)
        await store.upsert(deviceId: deviceId, kemPublicKeys: [keyInfo])
        guard let beforeDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to reopen isolated UserDefaults suite")
            return
        }
        let persistedBefore = beforeDefaults.data(forKey: storageKey)

        try await store.requireExactExisting(deviceId: deviceId, kemPublicKeys: [keyInfo])
        await store.upsert(deviceId: deviceId, kemPublicKeys: [keyInfo])

        guard let afterDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to reopen isolated UserDefaults suite")
            return
        }
        XCTAssertEqual(afterDefaults.data(forKey: storageKey), persistedBefore)
    }

    func testExactExistingAdmissionRejectsMissingAndChangedKeys() async throws {
        let suiteName = "KEMTrustStoreAdmissionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let store = KEMTrustStore(
            storageKey: "kem_trust_store.admission.tests.v1",
            userDefaults: defaults
        )
        let deviceId = "peer-\(UUID().uuidString)"
        let trusted = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.xwing.wireId,
            publicKey: Data(repeating: 0x11, count: 64)
        )
        await store.upsert(deviceId: deviceId, kemPublicKeys: [trusted])

        do {
            try await store.requireExactExisting(
                deviceId: deviceId,
                kemPublicKeys: [
                    KEMPublicKeyInfo(
                        suiteWireId: CryptoSuite.xwing.wireId,
                        publicKey: Data(repeating: 0x22, count: 64)
                    )
                ]
            )
            XCTFail("Expected a changed key to fail closed")
        } catch {
            XCTAssertEqual(
                error as? KEMTrustStore.ExistingTrustAdmissionError,
                .storedKeyMismatch(CryptoSuite.xwing.wireId)
            )
        }

        do {
            try await store.requireExactExisting(
                deviceId: deviceId,
                kemPublicKeys: [
                    KEMPublicKeyInfo(
                        suiteWireId: CryptoSuite.mlkem768.wireId,
                        publicKey: Data(repeating: 0x33, count: 64)
                    )
                ]
            )
            XCTFail("Expected a missing suite key to fail closed")
        } catch {
            XCTAssertEqual(
                error as? KEMTrustStore.ExistingTrustAdmissionError,
                .storedKeySetMismatch
            )
        }
    }

    func testExactExistingAdmissionRejectsPresentedKeySubset() async throws {
        let suiteName = "KEMTrustStoreSubsetAdmissionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let store = KEMTrustStore(
            storageKey: "kem_trust_store.subset.admission.tests.v1",
            userDefaults: defaults
        )
        let deviceId = "peer-\(UUID().uuidString)"
        let xwing = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.xwing.wireId,
            publicKey: Data(repeating: 0x41, count: 64)
        )
        let mlkem = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x42, count: 64)
        )
        await store.upsert(deviceId: deviceId, kemPublicKeys: [xwing, mlkem])

        do {
            try await store.requireExactExisting(
                deviceId: deviceId,
                kemPublicKeys: [xwing]
            )
            XCTFail("Expected a reduced key set to fail closed")
        } catch {
            XCTAssertEqual(
                error as? KEMTrustStore.ExistingTrustAdmissionError,
                .storedKeySetMismatch
            )
        }
    }
}
