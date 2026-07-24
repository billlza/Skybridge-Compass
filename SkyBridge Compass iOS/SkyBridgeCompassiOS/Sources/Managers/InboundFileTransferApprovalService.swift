import Foundation

@available(iOS 17.0, *)
@MainActor
final class InboundFileTransferApprovalService: ObservableObject {
    static let shared = InboundFileTransferApprovalService()

    struct PendingRequest: Identifiable, Equatable {
        let id: UUID
        let request: CrossNetworkWebRTCManager.InboundFileTransferApprovalRequest
    }

    @Published private(set) var pendingRequest: PendingRequest?

    private struct PendingDecision {
        let id: UUID
        let continuation: CheckedContinuation<
            CrossNetworkWebRTCManager.InboundFileTransferApprovalDecision,
            Never
        >
        let timeoutTask: Task<Void, Never>
    }

    private var pendingDecision: PendingDecision?
    private let decisionTimeout: Duration

    init(decisionTimeout: Duration = .seconds(60)) {
        self.decisionTimeout = decisionTimeout
    }

    func decide(
        for request: CrossNetworkWebRTCManager.InboundFileTransferApprovalRequest
    ) async -> CrossNetworkWebRTCManager.InboundFileTransferApprovalDecision {
        guard !Task.isCancelled else {
            return .rejected(reason: "inbound_file_transfer_approval_cancelled")
        }
        guard pendingDecision == nil else {
            return .rejected(reason: "inbound_file_transfer_approval_busy")
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(for: self.decisionTimeout)
                    } catch {
                        return
                    }
                    self.resolve(
                        id: id,
                        decision: .rejected(reason: "inbound_file_transfer_approval_timed_out")
                    )
                }
                pendingDecision = PendingDecision(
                    id: id,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                pendingRequest = PendingRequest(id: id, request: request)
                if Task.isCancelled {
                    resolve(
                        id: id,
                        decision: .rejected(reason: "inbound_file_transfer_approval_cancelled")
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(
                    id: id,
                    decision: .rejected(reason: "inbound_file_transfer_approval_cancelled")
                )
            }
        }
    }

    func approve(_ request: PendingRequest) {
        resolve(id: request.id, decision: .approved)
    }

    func reject(_ request: PendingRequest) {
        resolve(id: request.id, decision: .rejected(reason: "inbound_file_transfer_user_rejected"))
    }

    func rejectPendingRequestBecausePresentationEnded() {
        guard let pendingRequest else { return }
        reject(pendingRequest)
    }

    private func resolve(
        id: UUID,
        decision: CrossNetworkWebRTCManager.InboundFileTransferApprovalDecision
    ) {
        guard let pendingDecision, pendingDecision.id == id else { return }
        self.pendingDecision = nil
        pendingRequest = nil
        pendingDecision.timeoutTask.cancel()
        pendingDecision.continuation.resume(returning: decision)
    }
}
