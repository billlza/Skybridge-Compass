import XCTest
@testable import SkyBridgeCore

@MainActor
final class FileTransferHistoryPersistenceTests: XCTestCase {
    func testTransferHistoryPersistsAcrossManagerReinitialization() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { try? historyStore.remove() }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-transfer-history-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("history".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let manager = FileTransferManager(historyStore: historyStore)
        let transferId = UUID().uuidString
        manager.beginExternalOutboundTransfer(
            transferId: transferId,
            fileURL: fileURL,
            fileSize: 7,
            toDeviceId: "peer-device",
            toDeviceName: "Bill iPhone"
        )

        let active = try XCTUnwrap(manager.activeTransfers[transferId])
        active.scanResult = FileScanResult(
            fileURL: fileURL,
            scanDuration: 0.25,
            verdict: .safe,
            methodsUsed: [.quarantine],
            warnings: [ScanWarning(code: "NOTE", message: "persist", severity: .info)]
        )

        manager.completeExternalOutboundTransfer(transferId: transferId)

        let reloaded = FileTransferManager(historyStore: historyStore)
        XCTAssertEqual(reloaded.transferHistory.count, 1)

        let restored = try XCTUnwrap(reloaded.transferHistory.first)
        XCTAssertEqual(restored.id, transferId)
        XCTAssertEqual(restored.fileName, fileURL.lastPathComponent)
        XCTAssertEqual(restored.deviceName, "Bill iPhone")
        XCTAssertEqual(restored.localPath, fileURL)
        XCTAssertEqual(restored.scanResult?.verdict, .safe)
        XCTAssertEqual(restored.scanResult?.warnings.count, 1)

        reloaded.clearHistory()

        let cleared = FileTransferManager(historyStore: historyStore)
        XCTAssertTrue(cleared.transferHistory.isEmpty)
    }
}
