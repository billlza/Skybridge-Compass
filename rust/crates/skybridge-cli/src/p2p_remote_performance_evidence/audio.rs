use crate::performance_evidence::{extract_text_u64, extract_text_value};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_p2p_remote_audio_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    is_mac: bool,
    is_ios: bool,
) {
    let is_audio_tx_sender_close =
        line.contains("audioTxSenderClose") || line.contains("audioTxSenderClosed");
    if is_mac && is_audio_tx_sender_close {
        evidence.audio_tx_sender_close_samples += 1;
        if !is_expected_terminal_audio_tx_sender_close(evidence) {
            evidence.audio_tx_sender_unexpected_close_samples += 1;
        }
    }
    if is_mac && line.contains("audioTxSubmitDropped") {
        evidence.audio_tx_submit_dropped_samples += 1;
    }
    if is_mac && line.contains("mac-remote-audio-tx") {
        evidence.mac_remote_audio_tx_samples += 1;
        evidence.mac_remote_audio_tx_submitted_payloads +=
            extract_text_u64(line, "submitted").unwrap_or(0);
        evidence.mac_remote_audio_tx_sent_payloads += extract_text_u64(line, "sent").unwrap_or(0);
        evidence.mac_remote_audio_tx_failed_payloads +=
            extract_text_u64(line, "failed").unwrap_or(0);
        evidence.mac_remote_audio_tx_backlog_warnings +=
            extract_text_u64(line, "backlogWarnings").unwrap_or(0);

        match extract_text_value(line, "result").as_deref() {
            Some("send-error") => evidence.mac_remote_audio_tx_send_error_samples += 1,
            Some("queue-cleared") => evidence.mac_remote_audio_tx_queue_cleared_samples += 1,
            Some("rejected") => evidence.mac_remote_audio_tx_rejected_samples += 1,
            _ => {}
        }
    }

    let is_audio_rx_line = line.contains("PQC media audio rx")
        || line.contains("audio-rx")
        || line.contains("audioRxRendererClose")
        || line.contains("audioRxStop");
    if is_ios && (is_audio_rx_line || line.contains("remote-desktop status")) {
        evidence.audio_status_samples += 1;
        if is_audio_rx_line {
            evidence.audio_explicit_rx_samples += 1;
        }
        let is_no_traffic_recovery =
            line.contains("NoTrafficRecovery") || line.contains("noTrafficRecovery");
        if is_no_traffic_recovery {
            evidence.audio_no_traffic_recovery_samples += 1;
            if line.contains("NoTrafficRecoveryExhausted")
                || extract_text_value(line, "action").as_deref() == Some("doctor-fail")
            {
                evidence.audio_no_traffic_recovery_exhausted_samples += 1;
            }
        }
        if extract_text_value(line, "probable").is_some_and(|value| {
            value.contains("zero-rx-after-playback")
                || value.contains("audio-rx-no-positive-evidence")
        }) && !is_expected_terminal_audio_close(evidence, line)
        {
            evidence.audio_zero_rx_after_playback_samples += 1;
        }
        let datagrams = extract_text_u64(line, "audioRxDatagrams")
            .or_else(|| extract_text_u64(line, "datagrams"))
            .or_else(|| extract_text_u64(line, "datagramsSeen"));
        let recv_total = extract_text_u64(line, "recvTotal")
            .or_else(|| extract_text_u64(line, "receivedTotal"))
            .or_else(|| extract_text_u64(line, "audioRxRecv"))
            .or_else(|| extract_text_u64(line, "recv"))
            .unwrap_or(0);
        let decoded_total = extract_text_u64(line, "decodeTotal")
            .or_else(|| extract_text_u64(line, "decodedTotal"))
            .or_else(|| extract_text_u64(line, "audioRxDecoded"))
            .or_else(|| extract_text_u64(line, "decoded"))
            .unwrap_or(0);
        let played_total = extract_text_u64(line, "playTotal")
            .or_else(|| extract_text_u64(line, "playedTotal"))
            .or_else(|| extract_text_u64(line, "audioRxPlayed"))
            .or_else(|| extract_text_u64(line, "played"))
            .unwrap_or(0);
        if datagrams == Some(0)
            && (recv_total > 0 || decoded_total > 0 || played_total > 0)
            && !is_expected_terminal_audio_close(evidence, line)
        {
            evidence.audio_zero_datagram_after_playback_samples += 1;
        }
        evidence.audio_jitter_evicted += extract_text_u64(line, "jitterEvicted")
            .or_else(|| extract_text_u64(line, "audioRxJitterEvicted"))
            .unwrap_or(0);
        evidence.audio_playback_drop += extract_text_u64(line, "playbackDrop")
            .or_else(|| extract_text_u64(line, "audioRxPlaybackDrop"))
            .unwrap_or(0);
        evidence.audio_underflow += extract_text_u64(line, "underflow")
            .or_else(|| extract_text_u64(line, "audioRxUnderflow"))
            .unwrap_or(0);
        evidence.audio_rebuffer += extract_text_u64(line, "rebuffer")
            .or_else(|| extract_text_u64(line, "audioRxRebuffer"))
            .unwrap_or(0);
    }
}

fn is_expected_terminal_audio_close(evidence: &P2pRemotePerformanceEvidence, line: &str) -> bool {
    evidence.smoke_final_success
        && evidence.smoke_final_validated
        && evidence.smoke_capture_source_verified
        && (line.contains("audioRxStop") || line.contains("audioRxRendererClose"))
}

fn is_expected_terminal_audio_tx_sender_close(evidence: &P2pRemotePerformanceEvidence) -> bool {
    evidence.smoke_final_success
        && evidence.smoke_final_validated
        && evidence.smoke_capture_source_verified
}
