import AppKit
import XCTest
@testable import SkyBridgeCore
@testable import SkyBridgeUI

@available(macOS 14.0, *)
@MainActor
final class InboundFileTransferApprovalWindowControllerTests: XCTestCase {
    func testConsecutiveFilesReplaceResolvedWindowAndClosingRejectsOnlyCurrentFile() async throws {
        _ = NSApplication.shared
        let service = InboundFileTransferApprovalService.shared
        service.userDismissedCurrentPrompt()
        let controller = InboundFileTransferApprovalWindowController(
            approvalService: service,
            applicationActivator: {}
        )
        controller.start()
        defer {
            controller.stop()
            service.userDismissedCurrentPrompt()
        }

        let first = Self.request(name: "first.bin", bytes: 1)
        let firstTask = Task { @MainActor in await service.decide(for: first) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.presentedRequestIDForTesting, first.id)
        service.resolve(first, decision: .allowOnce)
        let firstDecision = await firstTask.value
        XCTAssertEqual(firstDecision, .allowOnce)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.presentedRequestIDForTesting)

        let second = Self.request(name: "empty.bin", bytes: 0)
        let secondTask = Task { @MainActor in await service.decide(for: second) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.presentedRequestIDForTesting, second.id)
        service.resolve(first, decision: .allowOnce)
        XCTAssertEqual(service.pendingRequest?.id, second.id)
        controller.closePresentedWindowForTesting()
        let secondDecision = await secondTask.value
        XCTAssertEqual(secondDecision, .reject)
        XCTAssertNil(service.pendingRequest)
    }

    private static func request(name: String, bytes: Int64) -> InboundFileTransferApprovalService.Request {
        InboundFileTransferApprovalService.Request(
            transferId: UUID().uuidString,
            fileName: name,
            fileSize: bytes,
            chunkSize: 65_536,
            totalChunks: bytes == 0 ? 0 : 1,
            senderDeviceId: "authenticated-peer",
            senderDeviceName: "Peer",
            endpointDescription: "127.0.0.1",
            destinationDirectoryPath: "/tmp/SkyBridge",
            proposedSavePath: "/tmp/SkyBridge/\(name)"
        )
    }
}
