import Combine
import Foundation
import OSLog

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
    private var continuationByRequestId: [UUID: [CheckedContinuation<Decision, Never>]] = [:]

    private init() {}

    public func decide(for request: Request) async -> Decision {
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_AUTO_APPROVE_INBOUND_FILE_TRANSFER"] == "1" {
            logger.info("Smoke auto-approving inbound file transfer transferId=\(request.transferId, privacy: .private)")
            return .allowOnce
        }

        if let pendingRequest {
            if isSameTransferRequest(pendingRequest, request) {
                logger.info("Inbound file transfer approval coalesced transferId=\(request.transferId, privacy: .private)")
                return await withCheckedContinuation { continuation in
                    continuationByRequestId[pendingRequest.id, default: []].append(continuation)
                }
            }
            logger.warning("Inbound file transfer rejected because another approval prompt is pending transferId=\(request.transferId, privacy: .private)")
            return .reject
        }

        pendingRequest = request
        logger.info(
            "Inbound file transfer approval required transferId=\(request.transferId, privacy: .private) fileName=\(request.fileName, privacy: .private) sender=\(request.senderDeviceId, privacy: .private)"
        )

        return await withCheckedContinuation { continuation in
            continuationByRequestId[request.id, default: []].append(continuation)
        }
    }

    public func resolve(_ request: Request, decision: Decision) {
        guard pendingRequest?.id == request.id else { return }
        let continuations = continuationByRequestId.removeValue(forKey: request.id) ?? []
        pendingRequest = nil

        logger.info("Inbound file transfer decision=\(decision.rawValue, privacy: .public) transferId=\(request.transferId, privacy: .private)")
        for continuation in continuations {
            continuation.resume(returning: decision)
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
}
