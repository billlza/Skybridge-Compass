import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
@MainActor
final class InboundFileTransferApprovalServiceTests: XCTestCase {
    private let service = InboundFileTransferApprovalService(decisionTimeout: .milliseconds(50))

    func testExplicitApprovalResumesExactlyTheDisplayedRequest() async throws {
        let request = makeRequest(transferId: UUID().uuidString)
        let decisionTask = Task { @MainActor in
            await service.decide(for: request)
        }

        let pending = try await waitForPendingRequest()
        XCTAssertEqual(pending.request, request)
        service.approve(pending)

        let decision = await decisionTask.value
        XCTAssertEqual(decision, .approved)
        XCTAssertNil(service.pendingRequest)
    }

    func testConcurrentApprovalRequestFailsClosedWithoutReplacingPrompt() async throws {
        let first = makeRequest(transferId: UUID().uuidString)
        let firstTask = Task { @MainActor in
            await service.decide(for: first)
        }
        let pending = try await waitForPendingRequest()

        let second = makeRequest(transferId: UUID().uuidString)
        let secondDecision = await service.decide(for: second)
        XCTAssertEqual(
            secondDecision,
            .rejected(reason: "inbound_file_transfer_approval_busy")
        )
        XCTAssertEqual(service.pendingRequest, pending)

        service.reject(pending)
        let firstDecision = await firstTask.value
        XCTAssertEqual(
            firstDecision,
            .rejected(reason: "inbound_file_transfer_user_rejected")
        )
    }

    func testCancelledApprovalResumesOnceAndClearsPrompt() async throws {
        let request = makeRequest(transferId: UUID().uuidString)
        let decisionTask = Task { @MainActor in
            await service.decide(for: request)
        }

        _ = try await waitForPendingRequest()
        decisionTask.cancel()
        let decision = await decisionTask.value

        XCTAssertEqual(
            decision,
            .rejected(reason: "inbound_file_transfer_approval_cancelled")
        )
        XCTAssertNil(service.pendingRequest)
    }

    func testApprovalTimeoutResumesOnceAndClearsPrompt() async throws {
        let request = makeRequest(transferId: UUID().uuidString)
        let decisionTask = Task { @MainActor in
            await service.decide(for: request)
        }

        _ = try await waitForPendingRequest()
        let decision = await decisionTask.value

        XCTAssertEqual(
            decision,
            .rejected(reason: "inbound_file_transfer_approval_timed_out")
        )
        XCTAssertNil(service.pendingRequest)
    }

    private func waitForPendingRequest() async throws -> InboundFileTransferApprovalService.PendingRequest {
        for _ in 0..<100 {
            if let pendingRequest = service.pendingRequest {
                return pendingRequest
            }
            await Task.yield()
        }
        return try XCTUnwrap(
            service.pendingRequest,
            "Approval task did not publish its prompt"
        )
    }

    private func makeRequest(
        transferId: String
    ) -> CrossNetworkWebRTCManager.InboundFileTransferApprovalRequest {
        CrossNetworkWebRTCManager.InboundFileTransferApprovalRequest(
            transferId: transferId,
            fileName: "report.pdf",
            fileSize: 1_024,
            chunkSize: 512,
            totalChunks: 2,
            senderDeviceId: "authenticated-device",
            senderDeviceName: "Known Mac"
        )
    }
}
