import Foundation
import XCTest
@testable import SkyBridgeCore

@MainActor
final class HandshakeTransferBusyTests: XCTestCase {
    func testPresentationGraceDoesNotOwnTransportButPreRecordOperationDoes() throws {
        let store = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: "HandshakeBusyTests/\(UUID().uuidString).json"),
            rootDirectoryName: "SkyBridgeStateTests")
        defer { XCTAssertNoThrow(try store.remove()) }
        let manager = FileTransferManager(historyStore: store)
        manager.isTransferring = true // Dashboard's existing 12-second completion grace.
        XCTAssertFalse(manager.hasActiveTransferWork)
        let token = try XCTUnwrap(manager.beginExternalTransportOperation(cancellationHandler: {}))
        XCTAssertTrue(manager.activeTransfers.isEmpty, "Operation can own resources before a UI row exists")
        XCTAssertTrue(manager.hasActiveTransferWork)
        manager.endExternalTransportOperation(token)
        XCTAssertTrue(manager.isTransferring, "Presentation grace remains available to the UI")
        XCTAssertFalse(manager.hasActiveTransferWork, "Released resource ownership does not inherit the UI delay")
    }
}
