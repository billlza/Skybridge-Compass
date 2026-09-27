import Foundation
import Combine

/// Platform UI presents this request; dismissal, cancellation and timeout deny.
@MainActor
public final class HandshakeConfigurationApproval: ObservableObject {
    public static let shared = HandshakeConfigurationApproval()
    public struct Request: Identifiable, Sendable {
        public let id: UUID
        public let identity: HandshakeManagementIdentity
        public let profile: HandshakeProfile?
    }
    @Published public private(set) var pending: Request?
    private var continuation: CheckedContinuation<HandshakeConfigurationService.Decision, Never>?
    private var timeout: Task<Void, Never>?

    public func decide(_ identity: HandshakeManagementIdentity, profile: HandshakeProfile?, requestID: UUID = UUID()) async -> HandshakeConfigurationService.Decision {
        guard pending == nil, !Task.isCancelled else { return .reject }
        let request = Request(id: requestID, identity: identity, profile: profile)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                pending = request
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch is CancellationError { return }
                    catch { self?.resolve(request.id, decision: .reject); return }
                    self?.resolve(request.id, decision: .reject)
                }
                if Task.isCancelled { resolve(request.id, decision: .reject) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(request.id, decision: .reject) }
        }
    }
    public func resolve(_ id: UUID, decision: HandshakeConfigurationService.Decision) {
        guard pending?.id == id else { return }
        let completed = continuation
        continuation = nil; pending = nil
        timeout?.cancel(); timeout = nil
        completed?.resume(returning: decision)
    }
}

public struct HandshakeManagementGrant: Codable {
    public let identityKey: String
    public let allowed: Bool
    public init(identityKey: String, allowed: Bool) { self.identityKey = identityKey; self.allowed = allowed }
    public static let service = "SkyBridge.HandshakeManagement.v1"
    public static func account(_ key: String) -> String { HandshakeConfigurationWire.hash(Data(key.utf8)) }
    public static func decode(_ data: Data?, key: String) throws -> Bool {
        guard let data else { return false }
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard record.identityKey == key else { throw HandshakeConfigurationError.storageUnavailable }
        return record.allowed
    }
}
