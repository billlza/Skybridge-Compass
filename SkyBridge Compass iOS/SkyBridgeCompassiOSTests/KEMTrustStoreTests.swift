import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class KEMTrustStoreTests: XCTestCase {
    func testPersistAndRestoreKEMTrustStore() async throws {
        let suiteName = "KEMTrustStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.tests.v1"
        let deviceId = "peer-\(UUID().uuidString)"
        let keyInfo = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0xA5, count: 32)
        )

        let writerStore = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        await writerStore.upsert(deviceId: deviceId, kemPublicKeys: [keyInfo])

        let readerStore = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        let restored = await readerStore.kemPublicKeys(for: deviceId)

        XCTAssertEqual(restored[.mlkem768], keyInfo.publicKey)

        await readerStore.clear(deviceId: deviceId)
        let cleared = await readerStore.kemPublicKeys(for: deviceId)
        XCTAssertTrue(cleared.isEmpty)
    }
}
