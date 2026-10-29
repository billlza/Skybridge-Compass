import CryptoKit
import Foundation

public enum RemoteFileApprovalError: String, Error, Codable, Sendable {
    case invalidRequest = "invalid_file_approval_request"
    case unavailable = "file_approval_unavailable"
    case unauthorized = "file_approval_not_authorized"
    case expired = "file_approval_expired"
    case stale = "file_approval_no_longer_pending"
    case bindingChanged = "file_approval_binding_changed"
    case busy = "file_approval_busy"
}

/// Values must come from authenticated file metadata and the exact session
/// that verified its MAC, never discovery or a freshly resolved peer alias.
public struct RemoteFileApprovalBinding: Codable, Equatable, Sendable {
    public let transferID: String
    public let senderDeviceID: String
    public let senderFingerprint: String
    /// Correlation only. The registry always revalidates the private session key/owner.
    public let sessionReference: String
    public let metadataDigest: String
    public let fileName: String
    public let fileSize: Int64
    public let fileSHA256: String

    public init(transferID: String, senderDeviceID: String, senderFingerprint: String,
                sessionReference: String, metadataDigest: String,
                fileName: String, fileSize: Int64, fileSHA256: String) throws {
        self.transferID = transferID
        self.senderDeviceID = HandshakeConfigurationWire.canonicalDeviceID(senderDeviceID)
        self.senderFingerprint = senderFingerprint.lowercased()
        self.sessionReference = sessionReference; self.metadataDigest = metadataDigest
        self.fileName = fileName; self.fileSize = fileSize; self.fileSHA256 = fileSHA256
        try validate()
    }

    public func validate() throws {
        guard UUID(uuidString: transferID) != nil,
              UUID(uuidString: senderDeviceID)?.uuidString.lowercased() == senderDeviceID,
              HandshakeConfigurationWire.isFingerprint(senderFingerprint),
              P2PEvidenceReference.isValid(sessionReference),
              HandshakeConfigurationWire.isFingerprint(metadataDigest),
              HandshakeConfigurationWire.isFingerprint(fileSHA256),
              !fileName.isEmpty, fileName.utf8.count <= 1024,
              fileSize >= 0, fileSize <= 2 * 1024 * 1024 * 1024 else {
            throw RemoteFileApprovalError.invalidRequest
        }
    }

    public func belongs(to identity: HandshakeManagementIdentity) -> Bool {
        senderDeviceID == identity.deviceID && senderFingerprint == identity.fingerprint
    }
}

public struct RemoteFileApprovalPrompt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let nonce: Data
    public let binding: RemoteFileApprovalBinding
    public let expiresAtMilliseconds: Int64

    public func validate() throws {
        try binding.validate()
        guard nonce.count == 32, expiresAtMilliseconds > 0 else { throw RemoteFileApprovalError.invalidRequest }
    }
}

public struct RemoteFileApprovalDecision: Codable, Equatable, Sendable {
    public let prompt: RemoteFileApprovalPrompt
    public let allow: Bool
    public init(prompt: RemoteFileApprovalPrompt, allow: Bool) { self.prompt = prompt; self.allow = allow }
}

public struct RemoteFileApprovalState: Codable, Equatable, Sendable {
    public let authorized: Bool
    public let pending: [RemoteFileApprovalPrompt]
    public init(authorized: Bool, pending: [RemoteFileApprovalPrompt]) { self.authorized = authorized; self.pending = pending }
}

/// Only owns the remote decision route. The existing native approval service
/// continues to own UI presentation, cancellation and the transfer continuation.
@MainActor
public final class RemoteFileApprovalRegistry {
    public static let shared = RemoteFileApprovalRegistry()
    public typealias Revalidate = @MainActor @Sendable () throws -> Void
    public typealias Authorize = @MainActor @Sendable () async throws -> Void
    /// Return false when the native request has already ended; it is never success.
    public typealias Resolve = @MainActor @Sendable (Bool) -> Bool
    private struct Entry {
        let prompt: RemoteFileApprovalPrompt
        let revalidate: Revalidate
        let resolve: Resolve
        var deciding = false
    }
    private var entries: [UUID: Entry] = [:]
    private let maximumPending: Int

    public init(maximumPending: Int = 8) { self.maximumPending = max(1, min(maximumPending, 128)) }

    public func register(binding: RemoteFileApprovalBinding, nativeRequestID: UUID,
                         expiresAt: Date, now: Date = Date(),
                         revalidate: @escaping Revalidate, resolve: @escaping Resolve) throws -> RemoteFileApprovalPrompt {
        try binding.validate()
        expire(now: now)
        guard entries.count < maximumPending, entries[nativeRequestID] == nil else { throw RemoteFileApprovalError.busy }
        guard expiresAt > now, expiresAt.timeIntervalSince(now) <= 120 else { throw RemoteFileApprovalError.invalidRequest }
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let prompt = RemoteFileApprovalPrompt(id: nativeRequestID, nonce: nonce, binding: binding,
            expiresAtMilliseconds: Int64((expiresAt.timeIntervalSince1970 * 1000).rounded(.down)))
        entries[nativeRequestID] = Entry(prompt: prompt, revalidate: revalidate, resolve: resolve)
        return prompt
    }

    public func pending(for identity: HandshakeManagementIdentity, now: Date = Date()) throws -> [RemoteFileApprovalPrompt] {
        try identity.validate()
        expire(now: now)
        return entries.values.filter { $0.prompt.binding.belongs(to: identity) && !$0.deciding }
            .map(\.prompt).sorted { $0.expiresAtMilliseconds < $1.expiresAtMilliseconds }
    }

    public func remove(nativeRequestID: UUID) { entries.removeValue(forKey: nativeRequestID) }

    public func decide(_ decision: RemoteFileApprovalDecision, requester: HandshakeManagementIdentity,
                       now: Date = Date(), authorize: Authorize = {}) async throws {
        try requester.validate(); try decision.prompt.validate()
        guard decision.prompt.binding.belongs(to: requester) else { throw RemoteFileApprovalError.unauthorized }
        guard decision.prompt.expiresAtMilliseconds > Int64(now.timeIntervalSince1970 * 1000) else {
            expire(now: now); throw RemoteFileApprovalError.expired
        }
        guard var entry = entries[decision.prompt.id] else { throw RemoteFileApprovalError.stale }
        guard entry.prompt == decision.prompt else { throw RemoteFileApprovalError.bindingChanged }
        guard !entry.deciding else { throw RemoteFileApprovalError.busy }
        entry.deciding = true; entries[entry.prompt.id] = entry
        do {
            try Task.checkCancellation()
            try entry.revalidate()
            try await authorize()
            // The authorization check may suspend; validate the exact transfer owner again.
            try entry.revalidate()
            try Task.checkCancellation()
            guard let current = entries[entry.prompt.id], current.prompt == entry.prompt,
                  entry.prompt.expiresAtMilliseconds > Int64(Date().timeIntervalSince1970 * 1000) else {
                throw RemoteFileApprovalError.stale
            }
            entries.removeValue(forKey: entry.prompt.id)
            guard entry.resolve(decision.allow) else { throw RemoteFileApprovalError.stale }
        } catch {
            if entries.removeValue(forKey: entry.prompt.id) != nil { _ = entry.resolve(false) }
            throw error
        }
    }

    private func expire(now: Date) {
        let expired = entries.values.filter { $0.prompt.expiresAtMilliseconds <= Int64(now.timeIntervalSince1970 * 1000) }
        for entry in expired {
            entries.removeValue(forKey: entry.prompt.id)
            _ = entry.resolve(false)
        }
    }
}

/// Passed only by an authenticated receiver, after metadata MAC verification.
public struct RemoteFileApprovalContext: Sendable {
    public let binding: RemoteFileApprovalBinding
    public let revalidate: RemoteFileApprovalRegistry.Revalidate
    public init(binding: RemoteFileApprovalBinding, revalidate: @escaping RemoteFileApprovalRegistry.Revalidate) {
        self.binding = binding; self.revalidate = revalidate
    }
}
