import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class PeerKEMBootstrapStoreTests: XCTestCase {
    func testLookupAcrossAliasCandidates() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let key257 = KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data([0xAA, 0x01]))
        let key258 = KEMPublicKeyInfo(suiteWireId: 258, publicKey: Data([0xAA, 0x02]))

        await store.upsert(
            deviceIds: ["declared-device-id", "name:iPhone", "bonjour:iPhone@local"],
            kemPublicKeys: [key257, key258]
        )

        let merged = await store.mergedKEMPublicKeys(forCandidates: ["name:iPhone"])
        XCTAssertEqual(merged[257], key257.publicKey)
        XCTAssertEqual(merged[258], key258.publicKey)
        await store.clearForTesting()
    }

    func testUpsertMergesSuitesOnRepeatedWrites() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        await store.upsert(
            deviceIds: ["peer-a"],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data([0x10]))]
        )
        await store.upsert(
            deviceIds: ["peer-a"],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 258, publicKey: Data([0x20]))]
        )

        let merged = await store.mergedKEMPublicKeys(forCandidates: ["peer-a"])
        XCTAssertEqual(Set(merged.keys), Set([257, 258]))
        XCTAssertEqual(merged[257], Data([0x10]))
        XCTAssertEqual(merged[258], Data([0x20]))
        await store.clearForTesting()
    }

    func testLatestWriteReplacesSameSuiteKey() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        await store.upsert(
            deviceIds: ["peer-b"],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data([0x01]))]
        )
        await store.upsert(
            deviceIds: ["peer-b"],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data([0x02]))]
        )

        let merged = await store.mergedKEMPublicKeys(forCandidates: ["peer-b"])
        XCTAssertEqual(merged[257], Data([0x02]))
        await store.clearForTesting()
    }
}
