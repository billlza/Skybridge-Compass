import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class InboundFileTransferApprovalServiceTests: XCTestCase {
    func testApprovalWaitsForOperatorDecisionAndClearsPrompt() async throws {
        let service = InboundFileTransferApprovalService.shared
        service.userDismissedCurrentPrompt()

        let request = Self.request()
        let approvalTask = Task { @MainActor in
            await service.decide(for: request)
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        let pending = try XCTUnwrap(service.pendingRequest)
        XCTAssertEqual(pending.transferId, request.transferId)

        service.resolve(pending, decision: .allowOnce)

        let decision = await approvalTask.value
        XCTAssertEqual(decision, .allowOnce)
        XCTAssertNil(service.pendingRequest)
    }

    func testSecondDistinctRequestFailsClosedWhilePromptIsPending() async throws {
        let service = InboundFileTransferApprovalService.shared
        service.userDismissedCurrentPrompt()

        let first = Self.request(transferId: UUID().uuidString)
        let firstTask = Task { @MainActor in
            await service.decide(for: first)
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        let secondDecision = await service.decide(for: Self.request(transferId: UUID().uuidString))
        XCTAssertEqual(secondDecision, .reject)

        let pending = try XCTUnwrap(service.pendingRequest)
        service.resolve(pending, decision: .reject)
        let firstDecision = await firstTask.value
        XCTAssertEqual(firstDecision, .reject)
    }

    private static func request(transferId: String = UUID().uuidString) -> InboundFileTransferApprovalService.Request {
        InboundFileTransferApprovalService.Request(
            transferId: transferId,
            fileName: "payload.bin",
            fileSize: 4,
            chunkSize: 4,
            totalChunks: 1,
            senderDeviceId: "sender",
            senderDeviceName: "Sender",
            endpointDescription: "endpoint",
            destinationDirectoryPath: "/tmp/SkyBridge",
            proposedSavePath: "/tmp/SkyBridge/payload.bin"
        )
    }
}
