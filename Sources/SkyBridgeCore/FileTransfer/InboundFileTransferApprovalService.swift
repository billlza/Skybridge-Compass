import Combine
import Foundation
import OSLog
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class InboundFileTransferApprovalService: ObservableObject {
    public static let shared = InboundFileTransferApprovalService()

    public enum Decision: String, Sendable, Equatable {
        case allowOnce
        case reject
    }

    public struct Request: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let transferId: String
        public let fileName: String
        public let fileSize: Int64
        public let chunkSize: Int
        public let totalChunks: Int
        public let senderDeviceId: String
        public let senderDeviceName: String
        public let endpointDescription: String
        public let destinationDirectoryPath: String
        public let proposedSavePath: String
        public let receivedAt: Date

        public init(
            id: UUID = UUID(),
            transferId: String,
            fileName: String,
            fileSize: Int64,
            chunkSize: Int,
            totalChunks: Int,
            senderDeviceId: String,
            senderDeviceName: String,
            endpointDescription: String,
            destinationDirectoryPath: String,
            proposedSavePath: String,
            receivedAt: Date = Date()
        ) {
            self.id = id
            self.transferId = transferId
            self.fileName = fileName
            self.fileSize = fileSize
            self.chunkSize = chunkSize
            self.totalChunks = totalChunks
            self.senderDeviceId = senderDeviceId
            self.senderDeviceName = senderDeviceName
            self.endpointDescription = endpointDescription
            self.destinationDirectoryPath = destinationDirectoryPath
            self.proposedSavePath = proposedSavePath
            self.receivedAt = receivedAt
        }
    }

    @Published public private(set) var pendingRequest: Request?

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "InboundFileTransferApproval")
    private struct Waiter {
        let continuation: CheckedContinuation<Decision, Never>
        let timeoutTask: Task<Void, Never>
    }
    private static let maximumCoalescedWaiters = 8
    private let decisionTimeout: Duration
    private let remoteRegistry: RemoteFileApprovalRegistry
    private var remoteBinding: RemoteFileApprovalBinding?
    private var waitersByRequestId: [UUID: [UUID: Waiter]] = [:]
    private var earlyDecisionByRequestId: [UUID: Decision] = [:]

    init(decisionTimeout: Duration = .seconds(60), remoteRegistry: RemoteFileApprovalRegistry = .shared) {
        self.decisionTimeout = decisionTimeout
        self.remoteRegistry = remoteRegistry
    }

    public func decide(for request: Request, remoteApproval: RemoteFileApprovalContext? = nil) async -> Decision {
        guard !Task.isCancelled else { return .reject }
        if let binding = remoteApproval?.binding {
            do { try binding.validate() }
            catch {
                logger.error("Inbound CLI file approval binding is invalid")
                return .reject
            }
            guard binding.transferID == request.transferId,
                  binding.senderDeviceID == request.senderDeviceId.lowercased(),
                  binding.fileName == request.fileName, binding.fileSize == request.fileSize else {
                logger.error("Inbound CLI file approval does not match the native request")
                return .reject
            }
        }
        if let pendingRequest {
            if isSameTransferRequest(pendingRequest, request), remoteBinding == remoteApproval?.binding {
                guard (waitersByRequestId[pendingRequest.id]?.count ?? 0)
                        < Self.maximumCoalescedWaiters else {
                    logger.warning("Inbound file transfer approval waiter limit reached")
                    return .reject
                }
                logger.info("Inbound file transfer approval coalesced transferId=\(request.transferId, privacy: .private)")
                return await waitForDecision(requestId: pendingRequest.id)
            }
            logger.warning("Inbound file transfer rejected because another approval prompt is pending transferId=\(request.transferId, privacy: .private)")
            return .reject
        }

        pendingRequest = request
        remoteBinding = remoteApproval?.binding
        if let remoteApproval {
            do {
                let components = decisionTimeout.components
                let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
                _ = try remoteRegistry.register(
                    binding: remoteApproval.binding, nativeRequestID: request.id,
                    expiresAt: Date().addingTimeInterval(seconds),
                    revalidate: remoteApproval.revalidate,
                    resolve: { [weak self] allowed in
                        guard let self, self.pendingRequest?.id == request.id else { return false }
                        self.resolve(request, decision: allowed ? .allowOnce : .reject)
                        return true
                    }
                )
            } catch {
                logger.error("Inbound CLI file approval registration failed: \(error.localizedDescription, privacy: .public)")
                pendingRequest = nil
                remoteBinding = nil
                return .reject
            }
        }
        logger.info(
            "Inbound file transfer approval required transferId=\(request.transferId, privacy: .private) fileName=\(request.fileName, privacy: .private) sender=\(request.senderDeviceId, privacy: .private)"
        )

        return await waitForDecision(requestId: request.id)
    }

    public func resolve(_ request: Request, decision: Decision) {
        guard pendingRequest?.id == request.id else { return }
        remoteRegistry.remove(nativeRequestID: request.id)
        remoteBinding = nil
        let waiters = waitersByRequestId
            .removeValue(forKey: request.id)
            .map { Array($0.values) }
            ?? []
        if waiters.isEmpty {
            earlyDecisionByRequestId = [request.id: decision]
        }
        pendingRequest = nil

        logger.info("Inbound file transfer decision=\(decision.rawValue, privacy: .public) transferId=\(request.transferId, privacy: .private)")
        for waiter in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: decision)
        }
    }

    public func userDismissedCurrentPrompt() {
        guard let request = pendingRequest else { return }
        resolve(request, decision: .reject)
    }

    private func isSameTransferRequest(_ lhs: Request, _ rhs: Request) -> Bool {
        lhs.transferId == rhs.transferId
            && lhs.senderDeviceId == rhs.senderDeviceId
            && lhs.proposedSavePath == rhs.proposedSavePath
    }

    private func waitForDecision(requestId: UUID) async -> Decision {
        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let earlyDecision = earlyDecisionByRequestId.removeValue(forKey: requestId) {
                    continuation.resume(returning: earlyDecision)
                    return
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(for: self.decisionTimeout)
                    } catch {
                        return
                    }
                    self.finishWaiter(
                        requestId: requestId,
                        waiterId: waiterId,
                        decision: .reject
                    )
                }
                waitersByRequestId[requestId, default: [:]][waiterId] = Waiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWaiter(
                    requestId: requestId,
                    waiterId: waiterId,
                    decision: .reject
                )
            }
        }
    }

    private func finishWaiter(
        requestId: UUID,
        waiterId: UUID,
        decision: Decision
    ) {
        guard var waiters = waitersByRequestId[requestId],
              let waiter = waiters.removeValue(forKey: waiterId) else { return }
        waiter.timeoutTask.cancel()
        if waiters.isEmpty {
            waitersByRequestId.removeValue(forKey: requestId)
            if pendingRequest?.id == requestId {
                remoteRegistry.remove(nativeRequestID: requestId)
                remoteBinding = nil
                pendingRequest = nil
            }
        } else {
            waitersByRequestId[requestId] = waiters
        }
        waiter.continuation.resume(returning: decision)
    }
}
