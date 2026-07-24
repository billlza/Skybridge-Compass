import XCTest
@testable import SkyBridgeCore

@MainActor
final class FileTransferHistoryPersistenceTests: XCTestCase {
    func testTransferHistoryPersistsAcrossManagerReinitialization() async throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-transfer-history-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("history".utf8).write(to: fileURL, options: .atomic)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: fileURL)) }

        let manager = FileTransferManager(historyStore: historyStore)
        let transferId = UUID().uuidString
        let token = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: transferId,
            fileURL: fileURL,
            fileSize: 7,
            toDeviceId: "peer-device",
            toDeviceName: "Bill iPhone",
            cancellationHandler: {}
        ))

        let active = try XCTUnwrap(manager.activeTransfers[transferId])
        active.scanResult = FileScanResult(
            fileURL: fileURL,
            scanDuration: 0.25,
            verdict: .safe,
            methodsUsed: [.quarantine],
            warnings: [ScanWarning(code: "NOTE", message: "persist", severity: .info)]
        )
        active.receiptDeliveryStatus = .unknown

        manager.completeExternalOutboundTransfer(token: token)
        await manager.awaitHistoryPersistence()

        let reloaded = FileTransferManager(historyStore: historyStore)
        await reloaded.awaitHistoryPersistence()
        XCTAssertEqual(reloaded.transferHistory.count, 1)

        let restored = try XCTUnwrap(reloaded.transferHistory.first)
        XCTAssertEqual(restored.id, transferId)
        XCTAssertEqual(restored.fileName, fileURL.lastPathComponent)
        XCTAssertEqual(restored.deviceName, "Bill iPhone")
        XCTAssertEqual(restored.localPath, fileURL)
        XCTAssertEqual(restored.scanResult?.verdict, .safe)
        XCTAssertEqual(restored.scanResult?.warnings.count, 1)
        XCTAssertEqual(restored.receiptDeliveryStatus, .unknown)

        reloaded.clearHistory()
        await reloaded.awaitHistoryPersistence()

        let cleared = FileTransferManager(historyStore: historyStore)
        await cleared.awaitHistoryPersistence()
        XCTAssertTrue(cleared.transferHistory.isEmpty)
    }

    func testDisabledTransferHistoryDoesNotAppendOrPersistCompletedAndFailedTransfers() async throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-transfer-history-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("history-disabled".utf8).write(to: fileURL, options: .atomic)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: fileURL)) }

        let manager = FileTransferManager(historyStore: historyStore)
        manager.updateSettings(keepTransferHistory: false)

        let completedTransferId = UUID().uuidString
        let completedToken = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: completedTransferId,
            fileURL: fileURL,
            fileSize: 16,
            toDeviceId: "peer-device",
            toDeviceName: "Bill iPhone",
            cancellationHandler: {}
        ))
        manager.completeExternalOutboundTransfer(token: completedToken)

        let failedTransferId = UUID().uuidString
        let failedToken = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: failedTransferId,
            fileURL: fileURL,
            fileSize: 16,
            toDeviceId: "peer-device",
            toDeviceName: "Bill iPhone",
            cancellationHandler: {}
        ))
        manager.failExternalOutboundTransfer(token: failedToken, errorMessage: "network failed")

        XCTAssertTrue(manager.transferHistory.isEmpty)
        XCTAssertTrue(manager.activeTransfers.isEmpty)

        let reloaded = FileTransferManager(historyStore: historyStore)
        await reloaded.awaitHistoryPersistence()
        XCTAssertTrue(reloaded.transferHistory.isEmpty)
    }

    func testCorruptHistoryBlocksAppendWithoutOverwritingBytesUntilExplicitClear() async throws {
        let fixture = try makeDefaultsFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let corruptBytes = Data("{not-json".utf8)
        fixture.defaults.set(corruptBytes, forKey: fixture.key)
        let repository = BoundedCodableHistoryRepository(
            store: fixture.store,
            maximumEntryCount: 100
        )

        do {
            _ = try await repository.load()
            XCTFail("Corrupt history must fail closed")
        } catch {
            XCTAssertNotNil(error as? DecodingError)
        }

        do {
            _ = try await repository.append(makeEntry(id: "blocked"))
            XCTFail("Append must not replace corrupt canonical history")
        } catch {
            XCTAssertNotNil(error as? DecodingError)
        }
        XCTAssertEqual(fixture.defaults.data(forKey: fixture.key), corruptBytes)

        let cleared = try await repository.clear()
        XCTAssertTrue(cleared.entries.isEmpty)
        let recovered = try await repository.append(makeEntry(id: "recovered"))
        XCTAssertEqual(recovered.entries.map(\.id), ["recovered"])
    }

    func testConcurrentRepositoriesDoNotLoseCanonicalAppends() async throws {
        let fixture = try makeDefaultsFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let firstRepository = BoundedCodableHistoryRepository(
            store: fixture.store,
            maximumEntryCount: 100
        )
        let secondRepository = BoundedCodableHistoryRepository(
            store: fixture.store,
            maximumEntryCount: 100
        )

        let firstEntry = makeEntry(id: "first")
        let secondEntry = makeEntry(id: "second")
        async let first = firstRepository.append(firstEntry)
        async let second = secondRepository.append(secondEntry)
        _ = try await (first, second)

        let persisted = try XCTUnwrap(fixture.store.loadOrThrow())
        XCTAssertEqual(Set(persisted.map(\.id)), Set(["first", "second"]))
    }

    func testRepositoryRetainsNewestOneHundredEntries() async throws {
        let fixture = try makeDefaultsFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let repository = BoundedCodableHistoryRepository(
            store: fixture.store,
            maximumEntryCount: 100
        )

        var finalSnapshot: BoundedHistorySnapshot<PersistedFileTransferHistoryEntry>?
        for index in 0..<120 {
            finalSnapshot = try await repository.append(makeEntry(id: "entry-\(index)"))
        }

        let entries = try XCTUnwrap(finalSnapshot?.entries)
        XCTAssertEqual(entries.count, 100)
        XCTAssertEqual(entries.first?.id, "entry-20")
        XCTAssertEqual(entries.last?.id, "entry-119")
        XCTAssertEqual(try fixture.store.loadOrThrow()?.count, 100)
    }

    func testOversizedHistoryFailsBeforeDecodeAndPreservesBytes() async throws {
        let fixture = try makeDefaultsFixture(maximumPayloadBytes: 32)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let oversizedBytes = Data(repeating: 0x41, count: 33)
        fixture.defaults.set(oversizedBytes, forKey: fixture.key)
        let repository = BoundedCodableHistoryRepository(
            store: fixture.store,
            maximumEntryCount: 100
        )

        do {
            _ = try await repository.load()
            XCTFail("Oversized history must fail before decoding")
        } catch let error as CodablePersistenceStoreError {
            XCTAssertEqual(error.errorCode, 1)
        }
        XCTAssertEqual(fixture.defaults.data(forKey: fixture.key), oversizedBytes)
    }

    func testQueuedBootstrapThenClearCannotResurrectPersistedHistory() async throws {
        let fixture = try makeDefaultsFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try fixture.store.save([makeEntry(id: "stale")])

        let manager = FileTransferManager(historyStore: fixture.store)
        manager.clearHistory()
        await manager.awaitHistoryPersistence()

        XCTAssertTrue(manager.transferHistory.isEmpty)
        XCTAssertNil(try fixture.store.loadOrThrow())
        XCTAssertNil(manager.historyPersistenceError)
    }

    private func makeDefaultsFixture(
        maximumPayloadBytes: Int = 2 * 1_024 * 1_024
    ) throws -> (
        suiteName: String,
        key: String,
        defaults: UserDefaults,
        store: CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>
    ) {
        let suiteName = "FileTransferHistoryPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = "history"
        let store = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .userDefaults(key: key),
            rootDirectoryName: "SkyBridgeStateTests",
            defaults: defaults,
            maximumPayloadBytes: maximumPayloadBytes
        )
        return (suiteName, key, defaults, store)
    }

    private func makeEntry(id: String) -> PersistedFileTransferHistoryEntry {
        PersistedFileTransferHistoryEntry(
            FileTransfer(
                id: id,
                fileName: "\(id).bin",
                fileSize: 1,
                deviceId: "peer",
                direction: .outgoing,
                status: .completed,
                createdAt: Date(timeIntervalSince1970: 1)
            )
        )
    }
}
