use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;
use crate::{DoctorCheck, simple_doctor_check};

pub(crate) fn check_p2p_remote_timing_correlation(
    evidence: &P2pRemotePerformanceEvidence,
    min_fps: f64,
) -> DoctorCheck {
    let frame_budget_ms = 1_000.0 / min_fps.max(1.0);
    let uses_final_window =
        evidence.mac_final_window_tx_samples > 0 || evidence.final_ios_source_samples > 0;
    let schedule_gap = if uses_final_window {
        evidence
            .mac_final_window_schedule_gap_max_ms
            .unwrap_or(f64::INFINITY)
    } else {
        evidence.mac_schedule_gap_max_ms.unwrap_or(f64::INFINITY)
    };
    let schedule_jitter = if uses_final_window {
        evidence
            .mac_final_window_schedule_jitter_max_ms
            .unwrap_or(f64::INFINITY)
    } else {
        evidence.mac_schedule_jitter_max_ms.unwrap_or(f64::INFINITY)
    };
    let completion_gap = if uses_final_window {
        evidence
            .mac_final_window_completion_gap_max_ms
            .unwrap_or(f64::INFINITY)
    } else {
        evidence.mac_completion_gap_max_ms.unwrap_or(f64::INFINITY)
    };
    let content_callback_gap = evidence
        .mac_final_window_content_callback_gap_max_ms
        .filter(|_| uses_final_window)
        .or(evidence.mac_content_callback_gap_max_ms)
        .unwrap_or(completion_gap);
    let content_actor_hop = if uses_final_window {
        evidence
            .mac_final_window_content_actor_hop_max_ms
            .unwrap_or(0.0)
    } else {
        evidence.mac_content_actor_hop_max_ms.unwrap_or(0.0)
    };
    let clock_fire_to_drain = if uses_final_window {
        evidence
            .mac_final_window_clock_fire_to_drain_max_ms
            .unwrap_or(0.0)
    } else {
        evidence.mac_clock_fire_to_drain_max_ms.unwrap_or(0.0)
    };
    let encoded_to_submit = if uses_final_window {
        evidence
            .mac_final_window_encoded_to_submit_max_ms
            .unwrap_or(f64::INFINITY)
    } else {
        evidence
            .mac_encoded_to_submit_max_ms
            .unwrap_or(f64::INFINITY)
    };
    let submit_gap = if uses_final_window {
        evidence
            .mac_final_window_submit_gap_max_ms
            .unwrap_or(f64::INFINITY)
    } else {
        evidence.mac_submit_gap_max_ms.unwrap_or(f64::INFINITY)
    };
    let source_samples = if uses_final_window {
        evidence.final_ios_source_samples
    } else {
        evidence.ios_source_samples
    };
    let source_gap = if uses_final_window {
        evidence
            .final_ios_source_gap_max_ms
            .unwrap_or(f64::INFINITY)
    } else {
        evidence.ios_source_gap_max_ms.unwrap_or(f64::INFINITY)
    };
    let source_to_read = if uses_final_window {
        evidence
            .final_ios_source_to_read_max_ms
            .unwrap_or(f64::INFINITY)
    } else {
        evidence.ios_source_to_read_max_ms.unwrap_or(f64::INFINITY)
    };
    let source_to_read_unsynced_clock_samples = if uses_final_window {
        evidence.final_ios_source_to_read_unsynced_clock_samples
    } else {
        evidence.ios_source_to_read_unsynced_clock_samples
    };
    let max_allowed_source_gap_ms = 100.0;
    let tx_samples = if uses_final_window {
        evidence.mac_final_window_tx_samples
    } else {
        evidence.mac_tx_samples
    };
    let direct_pump_samples = if uses_final_window {
        evidence.mac_final_window_direct_pump_handoff_samples
    } else {
        evidence.mac_direct_pump_handoff_samples
    };
    let writer_clock_samples = if uses_final_window {
        evidence.mac_final_window_writer_clock_dispatch_samples
    } else {
        evidence.mac_writer_clock_dispatch_samples
    };
    let send_scheduler_samples = if uses_final_window {
        evidence.mac_final_window_send_scheduler_dispatch_samples
    } else {
        evidence.mac_send_scheduler_dispatch_samples
    };
    let direct_pump_all = tx_samples > 0 && direct_pump_samples == tx_samples;
    let writer_clock_all = tx_samples > 0 && writer_clock_samples == tx_samples;
    let send_scheduler_all = tx_samples > 0 && send_scheduler_samples == tx_samples;
    let ok = source_samples > 0
        && direct_pump_all
        && writer_clock_all
        && send_scheduler_all
        && schedule_gap <= frame_budget_ms * 3.0
        && schedule_jitter <= frame_budget_ms * 3.0
        && completion_gap <= 80.0
        && content_callback_gap <= 80.0
        && content_actor_hop <= 25.0
        && clock_fire_to_drain <= 25.0
        && encoded_to_submit <= 100.0
        && submit_gap <= frame_budget_ms * 4.0
        && source_gap <= max_allowed_source_gap_ms
        && (source_to_read <= 100.0 || source_to_read_unsynced_clock_samples > 0);
    simple_doctor_check(
        "p2p_remote_timing_correlation",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "finalWindow={} macDirectPumpSamples={}/{} macWriterClockSamples={}/{} macSendSchedulerSamples={}/{} macScheduleGapMaxMs={:.1} macScheduleJitterMaxMs={:.1} macCompletionGapMaxMs={:.1} macContentCallbackGapMaxMs={:.1} macContentActorHopMaxMs={:.1} macClockFireToDrainMaxMs={:.1} macEncodedToSubmitMaxMs={:.1} macSubmitGapMaxMs={:.1} iosSourceSamples={} iosSourceGapMaxMs={:.1} maxAllowedSourceGapMs={:.1} iosSourceToReadMaxMs={:.1} iosSourceToReadUnsyncedClockSamples={} frameBudgetMs={:.1}",
            uses_final_window,
            direct_pump_samples,
            tx_samples,
            writer_clock_samples,
            tx_samples,
            send_scheduler_samples,
            tx_samples,
            schedule_gap,
            schedule_jitter,
            completion_gap,
            content_callback_gap,
            content_actor_hop,
            clock_fire_to_drain,
            encoded_to_submit,
            submit_gap,
            source_samples,
            source_gap,
            max_allowed_source_gap_ms,
            source_to_read,
            source_to_read_unsynced_clock_samples,
            frame_budget_ms
        ),
    )
}
