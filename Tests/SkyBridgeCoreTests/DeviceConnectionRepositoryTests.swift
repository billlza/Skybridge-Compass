import XCTest
@testable import SkyBridgeCore

@MainActor
final class DeviceConnectionRepositoryTests: XCTestCase {
    func testRepositorySerializesConcurrentCanonicalUpserts() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let firstRepository = DeviceConnectionRepository(
            store: fixture.store,
            legacySuiteName: fixture.suiteName,
            legacyKey: fixture.legacyKey
        )
        let secondRepository = DeviceConnectionRepository(
            store: fixture.store,
            legacySuiteName: fixture.suiteName,
            legacyKey: fixture.legacyKey
        )
        let firstDevice = makeDevice(id: "first")
        let secondDevice = makeDevice(id: "second")

        async let first = firstRepository.upsert(firstDevice)
        async let second = secondRepository.upsert(secondDevice)
        _ = try await (first, second)

        let envelope = try XCTUnwrap(fixture.store.loadOrThrow())
        XCTAssertEqual(Set(envelope.payload.keys), Set(["first", "second"]))
    }

    func testCorruptPrimaryBlocksMutationUntilExplicitClear() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let corruptBytes = Data("{corrupt".utf8)
        fixture.defaults.set(corruptBytes, forKey: fixture.primaryKey)
        let repository = DeviceConnectionRepository(
            store: fixture.store,
            legacySuiteName: fixture.suiteName,
            legacyKey: fixture.legacyKey
        )

        do {
            _ = try await repository.upsert(makeDevice(id: "blocked"))
            XCTFail("Corrupt canonical data must block mutation")
        } catch {
            XCTAssertNotNil(error as? DecodingError)
        }
        XCTAssertEqual(fixture.defaults.data(forKey: fixture.primaryKey), corruptBytes)

        let cleared = try await repository.clear()
        XCTAssertTrue(cleared.devices.isEmpty)
        let recovered = try await repository.upsert(makeDevice(id: "recovered"))
        XCTAssertEqual(recovered.devices.keys.sorted(), ["recovered"])
    }

    func testLegacyDictionaryMigratesExactlyOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        fixture.defaults.set(
            try encoder.encode(["legacy": makeDevice(id: "legacy")]),
            forKey: fixture.legacyKey
        )
        let repository = DeviceConnectionRepository(
            store: fixture.store,
            legacySuiteName: fixture.suiteName,
            legacyKey: fixture.legacyKey
        )

        let snapshot = try await repository.load()

        XCTAssertEqual(snapshot.devices.keys.sorted(), ["legacy"])
        XCTAssertNil(fixture.defaults.data(forKey: fixture.legacyKey))
        XCTAssertEqual(try fixture.store.loadOrThrow()?.schemaVersion, 2)
    }

    func testRepositoryRejectsMismatchedDictionaryIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try fixture.store.save(
            TransferDeviceCacheEnvelope(
                schemaVersion: DeviceConnectionRepository.schemaVersion,
                payload: ["wrong-key": makeDevice(id: "device-id")]
            )
        )
        let repository = DeviceConnectionRepository(
            store: fixture.store,
            legacySuiteName: fixture.suiteName,
            legacyKey: fixture.legacyKey
        )

        do {
            _ = try await repository.load()
            XCTFail("Dictionary identity mismatch must fail closed")
        } catch let error as DeviceConnectionRepositoryError {
            guard case .invalidEntry = error else {
                return XCTFail("Unexpected repository error: \(error)")
            }
        }
    }

    private func makeFixture() throws -> (
        suiteName: String,
        primaryKey: String,
        legacyKey: String,
        defaults: UserDefaults,
        store: CodablePersistenceStore<TransferDeviceCacheEnvelope<[String: DeviceInfo]>>
    ) {
        let suiteName = "DeviceConnectionRepositoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let primaryKey = "primary"
        let legacyKey = "legacy"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let store = CodablePersistenceStore<TransferDeviceCacheEnvelope<[String: DeviceInfo]>>(
            location: .userDefaults(key: primaryKey),
            rootDirectoryName: "SkyBridgeStateTests",
            defaults: defaults,
            encoder: encoder,
            decoder: decoder,
            maximumPayloadBytes: 2 * 1_024 * 1_024
        )
        return (suiteName, primaryKey, legacyKey, defaults, store)
    }

    private func makeDevice(id: String) -> DeviceInfo {
        DeviceInfo(
            id: id,
            name: "Device \(id)",
            ipAddress: "192.0.2.10",
            port: 8_080,
            lastConnected: Date(timeIntervalSince1970: 1_700_000_000),
            connectionStatus: .disconnected
        )
    }
}
