use super::super::types::{ObservedMetric, WebRtcMediaEvidence};
use super::metrics::{update_highest_f64, update_latest_metric, update_lowest_f64};
use crate::webrtc_media_parse::{find_webrtc_f64, find_webrtc_u64};

const WEBRTC_AUDIO_SCHEDULE_LEAD_HARD_MIN_MS: f64 = -40.0;
const WEBRTC_AUDIO_ARRIVAL_P95_PRESSURE_MS: f64 = 150.0;
const WEBRTC_AUDIO_ARRIVAL_MAX_SPIKE_MS: f64 = 500.0;
const WEBRTC_AUDIO_PLC_FRAME_PRESSURE_MIN: u64 = 3;
const WEBRTC_AUDIO_PLC_RATIO_PRESSURE: f64 = 0.01;
const WEBRTC_AUDIO_PLC_BURST_FRAME_PRESSURE_MIN: u64 = 8;
const WEBRTC_AUDIO_PLC_BURST_RATIO_PRESSURE: f64 = 0.03;

pub(in crate::webrtc_media_doctor) fn observe_webrtc_audio_playout_pressure(
    evidence: &mut WebRtcMediaEvidence,
    json: Option<&serde_json::Value>,
    text: &str,
    sequence: usize,
    summary: &str,
) {
    let schedule_lead_ms = find_webrtc_f64(json, text, "scheduleLeadMs");
    if let Some(value) = schedule_lead_ms {
        update_lowest_f64(
            &mut evidence.audio_lowest_schedule_lead_ms,
            ObservedMetric {
                value,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    let arrival_p95_ms = find_webrtc_f64(json, text, "audioArrivalP95Ms");
    if let Some(value) = arrival_p95_ms {
        update_highest_f64(
            &mut evidence.audio_highest_arrival_p95_ms,
            ObservedMetric {
                value,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    let arrival_max_ms = find_webrtc_f64(json, text, "audioArrivalMaxMs");
    if let Some(value) = arrival_max_ms {
        update_highest_f64(
            &mut evidence.audio_highest_arrival_max_ms,
            ObservedMetric {
                value,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    let queued_ms = find_webrtc_f64(json, text, "audioQueuedMs")
        .or_else(|| find_webrtc_f64(json, text, "queuedMs"));
    let target_queued_ms = find_webrtc_f64(json, text, "audioTargetQueuedMs")
        .or_else(|| find_webrtc_f64(json, text, "targetQueuedMs"));
    let low_queue_threshold_ms = target_queued_ms
        .map(|value| (value * 0.25).clamp(180.0, 600.0))
        .unwrap_or(180.0);
    let queue_low_water = queued_ms
        .map(|value| value <= low_queue_threshold_ms)
        .unwrap_or(false);
    let jitter_late = find_webrtc_u64(json, text, "jitterLate").unwrap_or(0);
    let plc_frames = find_webrtc_u64(json, text, "plcFrames")
        .or_else(|| find_webrtc_u64(json, text, "plc"))
        .unwrap_or(0);
    let plc_ratio = find_webrtc_f64(json, text, "plcRatio");
    let mut failures = Vec::new();
    if let Some(value) = schedule_lead_ms
        && value <= WEBRTC_AUDIO_SCHEDULE_LEAD_HARD_MIN_MS
        && queue_low_water
    {
        let queue_detail = queued_ms
            .map(|queued| format!(" queuedMs={queued:.0} thresholdMs={low_queue_threshold_ms:.0}"))
            .unwrap_or_default();
        failures.push(format!("scheduleLeadMs={value:.0}{queue_detail}"));
    }
    let arrival_spike_with_playout_pressure = arrival_max_ms
        .map(|value| value >= WEBRTC_AUDIO_ARRIVAL_MAX_SPIKE_MS)
        .unwrap_or(false)
        && (queue_low_water
            || schedule_lead_ms.map(|lead| lead < 0.0).unwrap_or(false)
            || jitter_late > 0);
    if let Some(value) = arrival_max_ms
        && arrival_spike_with_playout_pressure
    {
        failures.push(format!("audioArrivalMaxMs={value:.0}"));
    }
    if let (Some(p95), Some(lead)) = (arrival_p95_ms, schedule_lead_ms)
        && p95 >= WEBRTC_AUDIO_ARRIVAL_P95_PRESSURE_MS
        && lead < 0.0
    {
        failures.push(format!(
            "audioArrivalP95Ms={p95:.0} scheduleLeadMs={lead:.0}"
        ));
    }
    if let Some(lead) = schedule_lead_ms
        && jitter_late > 0
        && lead < 0.0
    {
        failures.push(format!("jitterLate={jitter_late} scheduleLeadMs={lead:.0}"));
    }
    let timing_pressure = queue_low_water
        || arrival_spike_with_playout_pressure
        || matches!(
            (arrival_p95_ms, schedule_lead_ms),
            (Some(p95), Some(lead))
                if p95 >= WEBRTC_AUDIO_ARRIVAL_P95_PRESSURE_MS && lead < 0.0
        )
        || matches!(
            schedule_lead_ms,
            Some(lead) if jitter_late > 0 && lead < 0.0
        );
    if let Some(value) = plc_ratio {
        let sustained_plc_burst = plc_frames >= WEBRTC_AUDIO_PLC_BURST_FRAME_PRESSURE_MIN
            && value >= WEBRTC_AUDIO_PLC_BURST_RATIO_PRESSURE;
        let correlated_plc_pressure = plc_frames >= WEBRTC_AUDIO_PLC_FRAME_PRESSURE_MIN
            && value >= WEBRTC_AUDIO_PLC_RATIO_PRESSURE
            && timing_pressure;
        if sustained_plc_burst || correlated_plc_pressure {
            failures.push(format!("plcFrames={plc_frames} plcRatio={value:.3}"));
        }
    } else if plc_frames >= WEBRTC_AUDIO_PLC_BURST_FRAME_PRESSURE_MIN && timing_pressure {
        failures.push(format!("plcFrames={plc_frames}"));
    }

    if failures.is_empty() {
        return;
    }

    update_latest_metric(
        &mut evidence.audio_playout_pressure,
        ObservedMetric {
            value: failures.join(", "),
            sequence,
            evidence: summary.to_owned(),
        },
    );
}
