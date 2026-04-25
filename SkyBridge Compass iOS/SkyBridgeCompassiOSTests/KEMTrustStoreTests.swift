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

    func testRebindCanonicalDeviceIdPrefersNewestKeyMaterial() async throws {
        let suiteName = "KEMTrustStoreRebindTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.rebind.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let legacyAlias = "bonjour:lza的macbook pro@local."
        let oldKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x11, count: 32)
        )
        let newKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x22, count: 32)
        )

        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        await store.upsert(deviceId: canonicalId, kemPublicKeys: [oldKey])
        try await Task.sleep(for: .milliseconds(20))
        await store.upsert(deviceId: legacyAlias, kemPublicKeys: [newKey])

        await store.rebindCanonicalDeviceId(canonicalId, legacyIdentifiers: [legacyAlias])

        let rebound = await store.kemPublicKeys(for: canonicalId)
        let legacy = await store.kemPublicKeys(for: legacyAlias)

        XCTAssertEqual(rebound[.mlkem768], newKey.publicKey)
        XCTAssertTrue(legacy.isEmpty)
    }
}
