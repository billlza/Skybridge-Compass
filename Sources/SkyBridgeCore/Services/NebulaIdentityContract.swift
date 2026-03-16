import Foundation

public enum NebulaIdentitySyncPhase: String, Sendable, Equatable {
    case idle
    case deferred
    case loading
    case hydrated
}

public enum NebulaIdentityContract {
    public static func normalizedNebulaId(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static func isCanonicalNebulaId(_ value: String?) -> Bool {
        guard let normalized = normalizedNebulaId(value) else { return false }
        return normalized.hasPrefix("NEBULA-")
    }

    public static func displayedNebulaId(
        resolvedNebulaId: String?,
        sessionNebulaId: String?,
        sessionUserIdentifier: String?,
        unsyncedText: String = "未同步"
    ) -> String {
        if let resolved = normalizedNebulaId(resolvedNebulaId) {
            return resolved
        }
        if let sessionNebulaId = normalizedNebulaId(sessionNebulaId) {
            return sessionNebulaId
        }
        if isCanonicalNebulaId(sessionUserIdentifier),
           let sessionUserIdentifier = normalizedNebulaId(sessionUserIdentifier) {
            return sessionUserIdentifier
        }
        return unsyncedText
    }

    public static func recommendedPhase(
        accessToken: String,
        isSupabaseSession: Bool,
        isSupabaseConfigured: Bool,
        resolvedNebulaId: String?,
        sessionNebulaId: String?
    ) -> NebulaIdentitySyncPhase {
        if normalizedNebulaId(resolvedNebulaId) != nil || normalizedNebulaId(sessionNebulaId) != nil {
            return .hydrated
        }
        guard accessToken != "pending_verification", isSupabaseSession else {
            return .idle
        }
        return isSupabaseConfigured ? .loading : .deferred
    }

    public static func shouldApplyAsyncResult(
        expectedGeneration: Int,
        currentGeneration: Int,
        expectedSessionKey: String,
        currentSessionKey: String?
    ) -> Bool {
        expectedGeneration == currentGeneration && expectedSessionKey == currentSessionKey
    }
}
