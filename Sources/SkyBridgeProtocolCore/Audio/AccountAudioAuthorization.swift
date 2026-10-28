import Foundation
import os

/// Publication lifetime of the local authenticated account, separate from JWT
/// expiry and from the shorter, independently expiring device-membership lease.
public final class AccountAudioAuthorization: Sendable {
    public let loginID: UUID
    public init(loginID: UUID = UUID()) { self.loginID = loginID }
    private let revoked = OSAllocatedUnfairLock(initialState: false)
    public var isCurrent: Bool { revoked.withLock { !$0 } }
    public func revoke() { revoked.withLock { $0 = true } }
}

/// Owned by AuthenticationService. An interrupted replacement cannot recreate an
/// epoch from the old session still visible to UI. Only successful publication can.
@MainActor
public final class AccountAudioAuthorizationState {
    public init() {}
    public private(set) var current: AccountAudioAuthorization?

    public func beginMutation() {
        current?.revoke()
        current = nil
    }

    public func publishAuthenticatedSession(loginID: UUID = UUID()) {
        beginMutation()
        current = AccountAudioAuthorization(loginID: loginID)
    }

    /// A validated refresh preserves the publication epoch. Its caller has already
    /// checked the exact source revision, subject and tenant before publication.
    public func requireCurrent(_ expected: AccountAudioAuthorization) throws {
        guard current === expected, expected.isCurrent else {
            throw AudioMembershipLeaseFailure.accountChanged
        }
    }
}

public enum AudioAccountRefreshFailurePolicy {
    /// Refresh endpoint errors only. Transport, throttling, malformed payloads and
    /// generic 400 responses do not establish that the underlying session was revoked.
    public static func invalidatesAuthorization(status: Int, body: String?) -> Bool {
        guard (400..<500).contains(status), status != 429,
              let data = body?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let codes = [object["code"], object["error_code"]].compactMap { $0 as? String }
        return codes.contains { ["refresh_token_not_found", "refresh_token_already_used",
            "session_not_found", "session_expired", "user_banned", "user_not_found"].contains($0) }
    }
}
