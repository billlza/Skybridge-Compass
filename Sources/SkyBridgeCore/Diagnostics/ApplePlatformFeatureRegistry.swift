import Foundation

public enum SkyBridgeApplePlatformFeatureID: String, CaseIterable, Sendable {
    case cryptokitPQCStable = "cryptokit-pqc-v1"
    case cryptokitPQCOS27Beta = "cryptokit-pqc-os27-v1"
    case networkTLSPQCProbe = "network-tls-pqc-v1"
    case deviceHubDiagnostics = "device-hub-diagnostics"
    case liquidGlassWrapper = "liquid-glass-wrapper"
    case foundationModelsAdvisory = "foundation-models-advisory"
    case coreAIAdvisory = "core-ai-advisory"
    case appIntentsPendingConfirmation = "app-intents-pending-confirmation"
}

public struct SkyBridgeApplePlatformFeatureRecord: Equatable, Sendable {
    public let id: SkyBridgeApplePlatformFeatureID
    public let proofScope: String
    public let status: String
    public let releaseEligible: Bool
    public let securityBoundary: String
}

public enum SkyBridgeApplePlatformFeatureRegistry {
    public static let features: [SkyBridgeApplePlatformFeatureRecord] = [
        SkyBridgeApplePlatformFeatureRecord(
            id: .cryptokitPQCStable,
            proofScope: "stable_release_symbol_probe_and_runtime_proof",
            status: "release_baseline_only",
            releaseEligible: true,
            securityBoundary: "Requires negotiated suite and runtime proof before user-visible PQC claims."
        ),
        SkyBridgeApplePlatformFeatureRecord(
            id: .cryptokitPQCOS27Beta,
            proofScope: "os27_beta_symbol_probe_and_runtime_self_test",
            status: "compatibility_evidence_only",
            releaseEligible: false,
            securityBoundary: "Beta SDK validation never changes stable release eligibility."
        ),
        SkyBridgeApplePlatformFeatureRecord(
            id: .networkTLSPQCProbe,
            proofScope: "transport_sdk_public_api_surface_only",
            status: "diagnostic_only",
            releaseEligible: false,
            securityBoundary: "Transport probe requires server support and cannot select SkyBridge wire suites, affect session status, or prove session PQC."
        ),
        SkyBridgeApplePlatformFeatureRecord(
            id: .deviceHubDiagnostics,
            proofScope: "manual_device_diagnostics_only",
            status: "workflow_assistance_only",
            releaseEligible: false,
            securityBoundary: "Device Hub and devicectl visibility cannot prove PQC runtime, Mac-iPad live interop, or release eligibility."
        ),
        SkyBridgeApplePlatformFeatureRecord(
            id: .liquidGlassWrapper,
            proofScope: "compatibility_wrapper_with_old_os_fallback",
            status: "progressive_design_enhancement",
            releaseEligible: false,
            securityBoundary: "Design APIs must stay behind wrappers and cannot raise deployment targets."
        ),
        SkyBridgeApplePlatformFeatureRecord(
            id: .foundationModelsAdvisory,
            proofScope: "redacted_advisory_dto_only",
            status: "no_production_framework_import",
            releaseEligible: false,
            securityBoundary: "Model output cannot affect trust, PQC policy, key material, sessions, or release gates."
        ),
        SkyBridgeApplePlatformFeatureRecord(
            id: .coreAIAdvisory,
            proofScope: "redacted_advisory_dto_only",
            status: "not_adopted",
            releaseEligible: false,
            securityBoundary: "Core AI experiments must stay outside protocol, crypto, and media hot paths."
        ),
        SkyBridgeApplePlatformFeatureRecord(
            id: .appIntentsPendingConfirmation,
            proofScope: "siri_pending_request_and_widget_navigation_only",
            status: "control_surface_requires_in_app_confirmation",
            releaseEligible: false,
            securityBoundary: "Intent handlers cannot call session, trust, keychain, PQC, file transfer, remote desktop, or release authority paths."
        )
    ]

    public static func feature(
        id: SkyBridgeApplePlatformFeatureID
    ) -> SkyBridgeApplePlatformFeatureRecord? {
        features.first { $0.id == id }
    }
}
