import Foundation

public enum PolicyMode: String, CaseIterable, Sendable, Codable {
    case strict
    case prefer
    case classic
}

public enum PeerCapabilityVisibility: String, CaseIterable, Sendable, Codable {
    case pqcVisible = "pqc_visible"
    case classicOnly = "classic_only"
    case unknown
}

public enum TrustStoreState: String, CaseIterable, Sendable, Codable {
    case trusted
    case untrusted
}

public enum BootstrapRekeyState: String, CaseIterable, Sendable, Codable {
    case bootstrap
    case rekey
}

public enum PolicyDecisionEventCode: String, CaseIterable, Sendable, Codable {
    case strictPQCProviderUnavailable = "strict.pqc_provider_unavailable"
    case strictPeerCapabilityMismatch = "strict.peer_capability_mismatch"
    case strictPQCSelected = "strict.pqc_selected"
    case preferClassicSelectedLocalCapability = "prefer.classic_selected_local_capability"
    case preferClassicFallbackAllowed = "prefer.classic_fallback_allowed"
    case preferClassicFallbackDenied = "prefer.classic_fallback_denied"
    case preferPQCSelected = "prefer.pqc_selected"
    case classicSelected = "classic.selected"
}

public enum PolicyDecisionUIErrorCategory: String, CaseIterable, Sendable, Codable {
    case none
    case classicOnlyPath = "classic_only_path"
    case recoverableClassicFallback = "recoverable_classic_fallback"
    case downgradeBlocked = "downgrade_blocked"
    case pqcRequiredUnavailable = "pqc_required_unavailable"
    case peerCapabilityMismatch = "peer_capability_mismatch"
}

public struct PolicyDecisionInput: Sendable, Equatable, Codable {
    public let policy: PolicyMode
    public let peer_capability_visibility: PeerCapabilityVisibility
    public let local_has_apple_provider: Bool
    public let local_has_liboqs_provider: Bool
    public let compile_time_has_apple_pqc_sdk: Bool
    public let trust_store_state: TrustStoreState
    public let bootstrap_rekey_state: BootstrapRekeyState

    public init(
        policy: PolicyMode,
        peer_capability_visibility: PeerCapabilityVisibility,
        local_has_apple_provider: Bool,
        local_has_liboqs_provider: Bool,
        compile_time_has_apple_pqc_sdk: Bool,
        trust_store_state: TrustStoreState,
        bootstrap_rekey_state: BootstrapRekeyState
    ) {
        self.policy = policy
        self.peer_capability_visibility = peer_capability_visibility
        self.local_has_apple_provider = local_has_apple_provider
        self.local_has_liboqs_provider = local_has_liboqs_provider
        self.compile_time_has_apple_pqc_sdk = compile_time_has_apple_pqc_sdk
        self.trust_store_state = trust_store_state
        self.bootstrap_rekey_state = bootstrap_rekey_state
    }
}

public struct PolicyDecisionSnapshot: Sendable, Equatable, Codable {
    public let policy: String
    public let selected_tier: String
    public let selected_suite_wire_id: UInt16
    public let fallback_allowed: Bool
    public let event_code: String
    public let ui_error_category: String

    public init(
        policy: String,
        selected_tier: String,
        selected_suite_wire_id: UInt16,
        fallback_allowed: Bool,
        event_code: String,
        ui_error_category: String
    ) {
        self.policy = policy
        self.selected_tier = selected_tier
        self.selected_suite_wire_id = selected_suite_wire_id
        self.fallback_allowed = fallback_allowed
        self.event_code = event_code
        self.ui_error_category = ui_error_category
    }

    public var telemetry_fields: [String: String] {
        [
            "policy": policy,
            "selected_tier": selected_tier,
            "selected_suite_wire_id": String(selected_suite_wire_id),
            "fallback_allowed": fallback_allowed ? "1" : "0",
            "event_code": event_code,
            "ui_error_category": ui_error_category
        ]
    }

    public static var required_telemetry_keys: Set<String> {
        [
            "policy",
            "selected_tier",
            "selected_suite_wire_id",
            "fallback_allowed",
            "event_code",
            "ui_error_category"
        ]
    }
}

public enum PolicyDecisionContract {
    public static var compiled_with_has_apple_pqc_sdk: Bool {
        #if HAS_APPLE_PQC_SDK
        return true
        #else
        return false
        #endif
    }

    public static func evaluate(_ input: PolicyDecisionInput) -> PolicyDecisionSnapshot {
        let hasApple = input.compile_time_has_apple_pqc_sdk && input.local_has_apple_provider
        let hasLiboqs = input.local_has_liboqs_provider
        let hasPQC = hasApple || hasLiboqs

        let selectedTier: CryptoTier
        if input.policy == .classic {
            selectedTier = .classic
        } else if hasApple {
            selectedTier = .nativePQC
        } else if hasLiboqs {
            selectedTier = .liboqsPQC
        } else {
            selectedTier = .classic
        }

        let selectedSuiteWireID: UInt16
        if selectedTier == .classic {
            selectedSuiteWireID = CryptoSuite.x25519Ed25519.wireId
        } else {
            selectedSuiteWireID = CryptoSuite.mlkem768MLDSA65.wireId
        }

        let fallbackCandidate = input.policy == .prefer
            && selectedTier != .classic
            && input.peer_capability_visibility != .pqcVisible
        let fallbackAllowed = fallbackCandidate
            && input.trust_store_state == .trusted
            && input.bootstrap_rekey_state == .rekey

        let eventCode: PolicyDecisionEventCode
        let uiErrorCategory: PolicyDecisionUIErrorCategory

        switch input.policy {
        case .strict:
            if !hasPQC {
                eventCode = .strictPQCProviderUnavailable
                uiErrorCategory = .pqcRequiredUnavailable
            } else if input.peer_capability_visibility == .classicOnly {
                eventCode = .strictPeerCapabilityMismatch
                uiErrorCategory = .peerCapabilityMismatch
            } else {
                eventCode = .strictPQCSelected
                uiErrorCategory = .none
            }

        case .prefer:
            if selectedTier == .classic {
                eventCode = .preferClassicSelectedLocalCapability
                uiErrorCategory = .classicOnlyPath
            } else if fallbackAllowed {
                eventCode = .preferClassicFallbackAllowed
                uiErrorCategory = .recoverableClassicFallback
            } else if fallbackCandidate {
                eventCode = .preferClassicFallbackDenied
                uiErrorCategory = .downgradeBlocked
            } else {
                eventCode = .preferPQCSelected
                uiErrorCategory = .none
            }

        case .classic:
            eventCode = .classicSelected
            uiErrorCategory = .none
        }

        return PolicyDecisionSnapshot(
            policy: input.policy.rawValue,
            selected_tier: selectedTier.rawValue,
            selected_suite_wire_id: selectedSuiteWireID,
            fallback_allowed: fallbackAllowed,
            event_code: eventCode.rawValue,
            ui_error_category: uiErrorCategory.rawValue
        )
    }
}
