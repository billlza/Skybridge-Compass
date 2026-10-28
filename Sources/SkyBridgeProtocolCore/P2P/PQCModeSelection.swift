import Foundation
import CoreFoundation

/// Local policy for the existing three negotiated PQC suites. It is not a wire
/// advertisement or evidence of a peer's capabilities.
public struct PQCModeSelection: Sendable, Equatable {
    public enum Preference: UInt16, Sendable, CaseIterable {
        case qperiapt = 0x0012
        case xwing = 0x0001
        case mlkem = 0x0101
    }

    public let preference: Preference
    public let strictlyMatchSelectedMode: Bool

    public init(preference: Preference, strictlyMatchSelectedMode: Bool) {
        self.preference = preference
        self.strictlyMatchSelectedMode = strictlyMatchSelectedMode
    }

    public var permittedSuiteWireIds: [UInt16] {
        strictlyMatchSelectedMode ? [preference.rawValue] : SignedKEMRefreshNegotiation.preferenceOrder
    }

    public func locallyReadySuites(_ runtimeSuites: [UInt16]) -> [UInt16] {
        permittedSuiteWireIds.filter { runtimeSuites.contains($0) }
    }

    /// Preparation must preserve the selected singleton instead of reapplying
    /// global native preferences or expanding the provider's family list.
    public static func frozenHandshakeOffer(selected: UInt16, providerSuites: [UInt16], signingAlgorithm: String) throws -> [UInt16] {
        guard SignedKEMRefreshNegotiation.preferenceOrder.contains(selected), providerSuites.contains(selected),
              signingAlgorithm == "ML-DSA-65" || signingAlgorithm == "ML-DSA-87",
              selected != 0x0012 || signingAlgorithm == "ML-DSA-65" else { throw PQCModeSelectionError.invalidCapabilities }
        return [selected]
    }

    public func select(fromVerifiedIntersection suites: [UInt16]) throws -> UInt16 {
        guard Set(suites).count == suites.count,
              suites.allSatisfy({ SignedKEMRefreshNegotiation.preferenceOrder.contains($0) }) else {
            throw PQCModeSelectionError.invalidCapabilities
        }
        guard let selected = SignedKEMRefreshNegotiation.preferenceOrder.first(where: {
            permittedSuiteWireIds.contains($0) && suites.contains($0)
        }) else { throw PQCModeSelectionError.noCommonSuite }
        return selected
    }
}

public enum PQCModeSelectionError: String, Error, Sendable, LocalizedError {
    case invalidStoredPolicy = "invalid_stored_pqc_policy"
    case policyChanged = "pqc_policy_changed"
    case persistenceFailed = "pqc_policy_persistence_failed"
    case invalidCapabilities = "invalid_pqc_capabilities"
    case noCommonSuite = "no_common_authenticated_pqc_suite"
    case negotiatedEvidenceRequired = "signed_skr3_negotiation_required"
    case unavailableRuntime = "selected_pqc_runtime_unavailable"

    public var errorDescription: String? { rawValue }
}

/// One process's policy revision, used only for in-flight work. The settings
/// remain in the existing UserDefaults keys; no peer or trust state lives here.
public struct PQCModePolicySnapshot: Sendable, Equatable {
    public let selection: PQCModeSelection
    public let revision: UUID
}

/// Serializes the existing preference writes with synchronous handshake
/// publication. Callers must not suspend inside withCurrent. Every product
/// write goes through this owner, including legacy preference bindings, so an
/// A -> B -> A change cannot revive an earlier attempt's revision.
public final class PQCModePolicyStore: @unchecked Sendable {
    public static let standard = PQCModePolicyStore()
    public static let preferQKey = "Settings.PreferQPeriaptBeta"
    public static let preferXWingKey = "Settings.PreferXWingHybrid"
    public static let strictMatchKey = "Settings.StrictlyMatchSelectedPQCMode"

    private let defaults: UserDefaults
    private let environment: [String: String]
    private let lock = NSRecursiveLock()
    private var lastSnapshot: PQCModePolicySnapshot?

    public init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        self.environment = environment
    }

    public func snapshot() throws -> PQCModePolicySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return try snapshotLocked()
    }

    public func withCurrent<T>(_ expected: PQCModePolicySnapshot, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard try snapshotLocked() == expected else { throw PQCModeSelectionError.policyChanged }
        return try operation()
    }

    @discardableResult
    public func setPreference(_ preference: PQCModeSelection.Preference) throws -> PQCModePolicySnapshot {
        lock.lock()
        defer { lock.unlock() }
        let previous = try readStoredSelection()
        return try writeLocked(preferQ: preference == .qperiapt, preferX: preference == .xwing,
                               strict: previous.strictlyMatchSelectedMode)
    }

    @discardableResult
    public func setStrictMatch(_ strict: Bool) throws -> PQCModePolicySnapshot {
        lock.lock()
        defer { lock.unlock() }
        _ = try readStoredSelection()
        return try writeLocked(preferQ: Self.readBoolean(defaults.object(forKey: Self.preferQKey)) ?? false,
                               preferX: Self.readBoolean(defaults.object(forKey: Self.preferXWingKey)) ?? false,
                               strict: strict)
    }

    /// Keeps existing individual bindings functional without turning an
    /// intermediate X/Q write into an untracked policy change.
    @discardableResult
    public func setLegacyPreferenceFlag(preferQ: Bool? = nil, preferXWing: Bool? = nil) throws -> PQCModePolicySnapshot {
        lock.lock()
        defer { lock.unlock() }
        let previous = try readStoredSelection()
        return try writeLocked(preferQ: preferQ ?? (Self.readBoolean(defaults.object(forKey: Self.preferQKey)) ?? false),
                               preferX: preferXWing ?? (Self.readBoolean(defaults.object(forKey: Self.preferXWingKey)) ?? false),
                               strict: previous.strictlyMatchSelectedMode)
    }

    private func writeLocked(preferQ: Bool, preferX: Bool, strict: Bool) throws -> PQCModePolicySnapshot {
        let before = [Self.preferQKey, Self.preferXWingKey, Self.strictMatchKey].map { defaults.object(forKey: $0) }
        let expected = PQCModeSelection(preference: preferQ ? .qperiapt : (preferX ? .xwing : .mlkem),
                                        strictlyMatchSelectedMode: strict)
        defaults.set(strict, forKey: Self.strictMatchKey)
        defaults.set(preferQ, forKey: Self.preferQKey)
        defaults.set(preferX, forKey: Self.preferXWingKey)
        do {
            guard try readStoredSelection() == expected,
                  Self.readBoolean(defaults.object(forKey: Self.preferQKey)) == preferQ,
                  Self.readBoolean(defaults.object(forKey: Self.preferXWingKey)) == preferX,
                  Self.readBoolean(defaults.object(forKey: Self.strictMatchKey)) == strict else {
                throw PQCModeSelectionError.persistenceFailed
            }
        } catch {
            for (key, value) in zip([Self.preferQKey, Self.preferXWingKey, Self.strictMatchKey], before) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            throw error
        }
        return try snapshotLocked()
    }

    private func snapshotLocked() throws -> PQCModePolicySnapshot {
        let stored = try readStoredSelection()
        // Existing explicit process-level Q requests remain hard requirements.
        // Ordinary UI operation does not install or alter these environment flags.
        let qRequested = ["SB_ENABLE_QPERIAPT"].contains {
            ["1", "true", "yes", "on"].contains(environment[$0]?.lowercased() ?? "")
        } || ["SB_PQC_PREFERRED_SUITE", "SKYBRIDGE_PQC_PREFERRED_SUITE"].contains {
            ["q-periapt", "qperiapt"].contains(environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
        }
        let selection = qRequested ? PQCModeSelection(preference: .qperiapt, strictlyMatchSelectedMode: true) : stored
        if let lastSnapshot, lastSnapshot.selection == selection { return lastSnapshot }
        let snapshot = PQCModePolicySnapshot(selection: selection, revision: UUID())
        lastSnapshot = snapshot
        return snapshot
    }

    private func readStoredSelection() throws -> PQCModeSelection {
        func boolean(_ key: String) throws -> Bool? {
            guard let raw = defaults.object(forKey: key) else { return nil }
            guard let value = Self.readBoolean(raw) else { throw PQCModeSelectionError.invalidStoredPolicy }
            return value
        }
        let q = try boolean(Self.preferQKey) ?? false
        let x = try boolean(Self.preferXWingKey) ?? false
        // Old Q was a hard requirement. Persisted X/ML were preferences within
        // PQC, so only a previously requested Q migrates missing strict -> true.
        let strict = try boolean(Self.strictMatchKey) ?? q
        return PQCModeSelection(preference: q ? .qperiapt : (x ? .xwing : .mlkem),
                                strictlyMatchSelectedMode: strict)
    }

    private static func readBoolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
