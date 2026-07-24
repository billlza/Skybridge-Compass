import XCTest

final class FileTransferProgressTruthSourceContractTests: XCTestCase {
    func testMacFileTransferViewObservesRuntimeProgressObjects() throws {
        let source = try repositorySource("Sources/SkyBridgeUI/FileTransfer/FileTransferView.swift")

        XCTAssertTrue(
            source.contains("private var hasActiveTransfers: Bool"),
            "The file-transfer page should show active transfer state from activeTransfers, not the dashboard grace flag."
        )
        XCTAssertTrue(
            source.contains("@ObservedObject private var transfer: FileTransfer"),
            "File transfer rows must observe the runtime FileTransfer object so @Published progress/status redraw the row."
        )
        XCTAssertTrue(
            source.contains("ProgressView(value: transfer.progress)"),
            "The visible row progress bar must be bound to the real FileTransfer.progress value."
        )
        XCTAssertFalse(
            source.contains("Timer.publish"),
            "The mac file-transfer page must not synthesize transfer progress with a UI timer."
        )
    }

    func testMacProgressPublisherUsesRealByteCounts() throws {
        let managerSource = try repositorySource("Sources/SkyBridgeCore/FileTransfer/FileTransferManager.swift")
        let webRTCSource = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCFileTransfer.swift"
        )

        XCTAssertTrue(
            managerSource.contains("private func publishActiveTransferProgress(_ transfer: FileTransfer, transferredBytes: Int64)")
        )
        XCTAssertTrue(
            managerSource.contains("transfer.updateProgress(transferredBytes: transferredBytes)")
        )
        XCTAssertTrue(
            managerSource.contains("activeTransfers[transfer.id] = transfer"),
            "Updating an ObservableObject inside a dictionary must also republish the dictionary for parent views."
        )
        XCTAssertTrue(
            managerSource.contains("\"transferredBytes\": transferredBytes")
        )
        XCTAssertTrue(
            managerSource.contains("\"totalBytes\": transfer.fileSize")
        )
        XCTAssertTrue(
            managerSource.contains("Double(transferredBytes) / Double(totalBytes)"),
            "Aggregate progress should be weighted by bytes instead of averaging per-transfer percentages."
        )
        XCTAssertTrue(
            webRTCSource.contains("let expectedReceivedBytes = sentBytes + Int64(data.count)")
        )
        XCTAssertTrue(
            webRTCSource.contains("validateChunkAck("),
            "Outbound WebRTC progress must advance only after an exact cumulative-byte ACK."
        )
        XCTAssertFalse(
            webRTCSource.contains("let progressed = ack.receivedBytes"),
            "A receiver must not be able to skip unsent source bytes by reporting progress ahead of the current chunk."
        )
        XCTAssertTrue(
            webRTCSource.contains("FileTransferManager.shared.updateExternalOutboundProgress")
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
