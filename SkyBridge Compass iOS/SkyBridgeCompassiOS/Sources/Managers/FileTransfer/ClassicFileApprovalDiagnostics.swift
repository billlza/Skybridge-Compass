import Foundation
import SkyBridgeProtocolCore

/// One authenticated receive attempt's diagnostics. Evaluators return their exact input result;
/// they cannot authorize, resolve a prompt, substitute an identity, or change a thrown error.
@MainActor
final class ClassicFileApprovalDiagnostics {
    enum Stage: String {
        case metadataDigest = "metadata_digest"
        case authenticatedSession = "authenticated_session"
        case leaseMatches = "lease_matches"
        case sessionAuthority = "session_authority"
        case authorityGeneration = "authority_generation"
        case fingerprintValid = "fingerprint_valid"
        case sessionReference = "session_reference"
        case materialMatches = "material_matches"
        case senderTrustRecord = "sender_trust_record"
        case fingerprintTrustRecord = "fingerprint_trust_record"
        case bindingValidation = "binding_validation"
        case nativeDecision = "native_decision"
        case cancellationCheck = "cancellation_check"
        case currentMaterial = "current_material"
        case approvedMaterialMatches = "approved_material_matches"
    }

    var stage: Stage = .metadataDigest
    private var checks: [Stage: Bool] = [:]
    private var decisionReason = "not_received"
    private var recorded = false
    private let senderKind: String
    private let senderUUIDValid: Bool

    init(senderDeviceId: String) {
        let canonical = HandshakeConfigurationWire.canonicalDeviceID(senderDeviceId)
        senderUUIDValid = UUID(uuidString: canonical)?.uuidString.lowercased() == canonical
        let lowered = senderDeviceId.lowercased()
        if lowered.hasPrefix("host:") { senderKind = "host" }
        else if lowered.hasPrefix("bonjour:") { senderKind = "bonjour" }
        else if lowered.hasPrefix("peer:") { senderKind = "peer" }
        else if lowered.hasPrefix("id:") { senderKind = "id_wrapped" }
        else { senderKind = senderUUIDValid ? "uuid" : "other" }
    }

    func value<T>(_ stage: Stage, _ evaluate: () -> T?) -> T? {
        self.stage = stage
        let value = evaluate()
        checks[stage] = value != nil
        return value
    }

    func check(_ stage: Stage, _ evaluate: () throws -> Bool) rethrows -> Bool {
        self.stage = stage
        let value = try evaluate()
        checks[stage] = value
        return value
    }

    func note(_ stage: Stage, result: Bool) { checks[stage] = result }

    func noteDecision(rejectedReason: String?) {
        guard let rejectedReason else { decisionReason = "approved"; return }
        let allowed = [
            "inbound_file_transfer_approval_cancelled", "inbound_file_transfer_approval_busy",
            "inbound_file_transfer_approval_timed_out", "inbound_file_transfer_cli_rejected",
            "inbound_file_transfer_cli_approval_unavailable", "inbound_file_transfer_user_rejected",
        ]
        decisionReason = allowed.contains(rejectedReason) ? rejectedReason : "other_rejection"
    }

    func recordFailure(_ error: Error, refusal: ClassicTransferApprovalRefusal, usesApprovalProtocol: Bool) {
        guard !recorded else { return }
        recorded = true
        let remoteError = (error as? RemoteFileApprovalError)?.rawValue ?? "none"
        let observations = checks.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
        let authorityStoreAvailable = TrustedDeviceStore.shared.isAuthorityPersistenceAvailable
        let acceptanceJournalPresent = PairingAcceptanceJournalStore.defaultJournalExists()
        let line = "file-transfer approval-failed stage=\(stage.rawValue) remote_error=\(remoteError) refusal=\(refusal.rawValue) approval_protocol=\(usesApprovalProtocol) decision=\(decisionReason) sender_kind=\(senderKind) sender_uuid_valid=\(senderUUIDValid) authority_store_available=\(authorityStoreAvailable) acceptance_journal_present=\(acceptanceJournalPresent) \(observations)"
        SignedKEMRefreshSmokeStatusWriter.append(line)
        SkyBridgeLogger.shared.error(line)
    }

    static func recordReceivedRefusal(_ refusal: ClassicTransferApprovalRefusal) {
        let line = "file-transfer approval-refused direction=outbound refusal=\(refusal.rawValue)"
        SignedKEMRefreshSmokeStatusWriter.append(line)
        SkyBridgeLogger.shared.warning(line)
    }
}
