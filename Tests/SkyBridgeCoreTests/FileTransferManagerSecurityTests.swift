import XCTest
@testable import SkyBridgeCore

@MainActor
final class FileTransferManagerSecurityTests: XCTestCase {
    func testResumeTransferOnlyUnpausesActiveTransfer() async {
        let manager = FileTransferManager()
        let transfer = FileTransfer(
            id: UUID().uuidString,
            fileName: "report.txt",
            fileSize: 1024,
            deviceId: "peer-device",
            direction: .outgoing,
            status: .paused
        )
        manager.activeTransfers[transfer.id] = transfer

        await manager.resumeTransfer(UUID(uuidString: transfer.id)!)

        XCTAssertEqual(manager.activeTransfers[transfer.id]?.status, .transferring)
    }
}
