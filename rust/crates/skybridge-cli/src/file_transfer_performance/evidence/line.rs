use super::FileTransferPerformanceEvidence;
use crate::performance_evidence::{
    extract_text_value, is_p2p_remote_fallback_failure_line, is_unknown_suite_rejection_line,
    update_signed_kem_refresh_evidence,
};

pub(crate) fn update_file_transfer_evidence(
    evidence: &mut FileTransferPerformanceEvidence,
    line: &str,
    is_mac: bool,
    is_ios: bool,
) {
    let lower = line.to_ascii_lowercase();
    let line_sequence = update_signed_kem_refresh_evidence(
        &mut evidence.signed_kem_refresh,
        line,
        &lower,
        is_mac,
        is_ios,
        None,
    );
    if is_mac && (line.contains("boot role=mac-p2p-host") || line.contains("boot role=mac-host")) {
        evidence.mac_boot = true;
    }
    if is_ios && line.contains("boot role=ios-p2p-client") {
        evidence.ios_boot = true;
    }
    evidence.unknown_suite_rejected |= is_unknown_suite_rejection_line(line, &lower);
    evidence.fallback_detected |= is_p2p_remote_fallback_failure_line(line, &lower)
        || lower.contains("compatibility fallback")
        || lower.contains("legacyfallback=true")
        || lower.contains("classic fallback");
    evidence.xwing_suite_seen |= line.contains("suite=X-Wing") || lower.contains("suite=x-wing");
    let xwing_success_event = lower.contains("success")
        && lower.contains("suite=x-wing")
        && lower.contains("filetransfer=1")
        && is_ios;
    if xwing_success_event
        && evidence
            .signed_kem_refresh
            .verified_imported_sequence
            .is_some_and(|verified| line_sequence > verified)
    {
        evidence
            .signed_kem_refresh
            .strict_xwing_established_after_refresh = true;
        evidence
            .signed_kem_refresh
            .strict_xwing_established_sequence
            .get_or_insert(line_sequence);
    }
    evidence.qr_connect_link_seen |= line.contains("qr-connect-link")
        && (line.contains("mode=offline-p2p-kem") || line.contains("suites=0x0001"));
    evidence.pqc_preseed_seen |= line.contains("pqc-preseed");
    if line.contains("file-transfer-route")
        || line.contains("file-transfer-route-ready")
        || line.contains("file-transfer outbound-route-probe")
    {
        evidence.route_evidence_samples += 1;
    }
    if line.contains("success ") && line.contains("fileTransfer=1") {
        evidence.mac_success |= is_mac;
        evidence.ios_success |= is_ios;
        if line.contains("macReconnect=1") || line.contains("macInitiatedTransfer=1") {
            evidence.mac_reconnect_required = true;
        }
    }
    evidence.mac_inbound_complete |=
        is_mac && line.contains("file-transfer inbound-complete name=ios-smoke-");
    evidence.ios_outbound_complete |=
        is_ios && line.contains("file-transfer outbound-complete name=ios-smoke-");
    evidence.mac_outbound_complete |=
        is_mac && line.contains("file-transfer outbound-complete name=mac-smoke-");
    evidence.ios_inbound_complete |=
        is_ios && line.contains("file-transfer inbound-complete name=mac-smoke-");
    evidence.mac_reconnect_outbound_complete |=
        is_mac && line.contains("mac-reconnect outbound-complete name=mac-reconnect-smoke-");
    evidence.ios_reconnect_inbound_complete |=
        is_ios && line.contains("mac-reconnect inbound-complete name=mac-reconnect-smoke-");
    update_payload_digest_evidence(evidence, line, is_mac, is_ios);
    if line.contains("failed stage=") {
        evidence.failed_stage_count += 1;
        if line.contains("stage=file-transfer phase=unknown") {
            evidence.unknown_phase_count += 1;
        }
        if line.contains("stage=file-transfer") && !line.contains("phase=") {
            evidence.missing_file_transfer_phase_count += 1;
        }
        if evidence.first_failure.is_none() {
            evidence.first_failure = Some(line.trim().to_owned());
        }
    }
}

fn update_payload_digest_evidence(
    evidence: &mut FileTransferPerformanceEvidence,
    line: &str,
    is_mac: bool,
    is_ios: bool,
) {
    let Some(name) = extract_text_value(line, "name") else {
        return;
    };
    let Some(sha256) = extract_text_value(line, "sha256") else {
        return;
    };
    if !is_sha256_hex(&sha256) {
        return;
    }

    let sender = (is_ios && line.contains("file-transfer outbound-complete name=ios-smoke-"))
        || (is_mac && line.contains("file-transfer outbound-complete name=mac-smoke-"))
        || (is_mac && line.contains("mac-reconnect outbound-complete name=mac-reconnect-smoke-"));
    let receiver = (is_mac && line.contains("file-transfer inbound-complete name=ios-smoke-"))
        || (is_ios && line.contains("file-transfer inbound-complete name=mac-smoke-"))
        || (is_ios && line.contains("mac-reconnect inbound-complete name=mac-reconnect-smoke-"));

    if sender {
        evidence
            .payload_digests
            .record_sender(name.clone(), sha256.clone());
    }
    if receiver {
        evidence.payload_digests.record_receiver(name, sha256);
    }
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}
