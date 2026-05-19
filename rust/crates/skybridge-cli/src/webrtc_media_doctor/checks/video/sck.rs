use super::super::super::evidence::WebRtcMediaEvidence;
use super::super::latest_counter_value;
use super::optional_f64_label;
use crate::DoctorCheck;

pub(in crate::webrtc_media_doctor) fn classify_webrtc_sck_tx_stage(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
) -> Option<&'static str> {
    let has_sck_evidence = evidence.sck_captured.latest.is_some()
        || evidence.sck_meaningful.latest.is_some()
        || evidence.sck_encoded.latest.is_some()
        || evidence.sck_capture_fps.is_some()
        || evidence.sck_meaningful_fps.is_some()
        || evidence.sck_encoded_fps.is_some()
        || evidence.sck_encode_latency_p95_ms.is_some()
        || evidence.sck_encode_failures.latest.is_some();
    if !has_sck_evidence {
        return None;
    }

    let low_media_fps = evidence
        .lowest_fps
        .as_ref()
        .is_some_and(|fps| fps.value <= 2.0)
        || evidence
            .latest_fps
            .as_ref()
            .is_some_and(|fps| fps.value <= 2.0);

    let capture_missing_or_stalled = latest_counter_value(&evidence.sck_captured) == Some(0)
        || latest_counter_value(&evidence.sck_meaningful) == Some(0)
        || evidence
            .sck_meaningful_fps
            .as_ref()
            .is_some_and(|fps| fps.value <= 2.0);
    if low_media_fps && capture_missing_or_stalled {
        return Some("sck_capture_stalled");
    }

    let capture_flowing = latest_counter_value(&evidence.sck_meaningful)
        .is_some_and(|value| value > 0)
        || evidence
            .sck_meaningful_fps
            .as_ref()
            .is_some_and(|fps| fps.value > 2.0);
    let encode_missing_or_stalled = latest_counter_value(&evidence.sck_encoded) == Some(0)
        || latest_counter_value(&evidence.sck_encode_failures).is_some_and(|value| value > 0)
        || evidence
            .sck_encoded_fps
            .as_ref()
            .is_some_and(|fps| fps.value <= 2.0);
    if low_media_fps && capture_flowing && encode_missing_or_stalled {
        return Some("vt_encode_stalled");
    }

    let media_fps_below_gate = evidence
        .lowest_fps
        .as_ref()
        .is_some_and(|fps| fps.value < min_fps)
        || evidence
            .latest_fps
            .as_ref()
            .is_some_and(|fps| fps.value < min_fps);
    let encode_flowing = latest_counter_value(&evidence.sck_encoded).is_some_and(|value| value > 0)
        || evidence
            .sck_encoded_fps
            .as_ref()
            .is_some_and(|fps| fps.value > 2.0);
    if media_fps_below_gate
        && capture_flowing
        && encode_flowing
        && webrtc_sck_vt_encode_latency_over_budget(evidence, min_fps)
    {
        return Some("vt_encode_slow");
    }

    None
}

fn webrtc_frame_budget_ms(min_fps: f64) -> f64 {
    1_000.0 / min_fps.max(1.0)
}

fn webrtc_sck_vt_encode_latency_over_budget(evidence: &WebRtcMediaEvidence, min_fps: f64) -> bool {
    let budget_ms = webrtc_frame_budget_ms(min_fps);
    let p95_over_budget = evidence
        .sck_encode_latency_p95_ms
        .as_ref()
        .is_some_and(|metric| metric.value > budget_ms * 1.10);
    let max_severely_over_budget = evidence
        .sck_encode_latency_max_ms
        .as_ref()
        .is_some_and(|metric| metric.value > budget_ms * 2.0);
    p95_over_budget || max_severely_over_budget
}

pub(in crate::webrtc_media_doctor) fn check_webrtc_sck_vt_encode_latency(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
    strict_fps_floor: bool,
) -> DoctorCheck {
    let p50 = evidence
        .sck_encode_latency_p50_ms
        .as_ref()
        .map(|metric| metric.value);
    let p95 = evidence
        .sck_encode_latency_p95_ms
        .as_ref()
        .map(|metric| metric.value);
    let max_latency = evidence
        .sck_encode_latency_max_ms
        .as_ref()
        .map(|metric| metric.value);
    let failures = latest_counter_value(&evidence.sck_encode_failures);
    let has_sck_tx_evidence = evidence.sck_captured.latest.is_some()
        || evidence.sck_meaningful.latest.is_some()
        || evidence.sck_encoded.latest.is_some()
        || evidence.sck_encoded_fps.is_some();
    let has_latency_evidence = p50.is_some() || p95.is_some() || max_latency.is_some();
    let strict_latency_gate = strict_fps_floor && min_fps >= 30.0;
    if !has_latency_evidence {
        let failures = failures.unwrap_or(0);
        let missing_detail = if has_sck_tx_evidence {
            "SCK tx telemetry was observed, but VT encode latency fields were not present"
                .to_owned()
        } else {
            "SCK/VT encode latency telemetry was not observed".to_owned()
        };
        let ok = !strict_latency_gate && failures == 0;
        return DoctorCheck {
            name: "sck_vt_encode_latency",
            ok,
            severity: if ok { "info" } else { "error" },
            detail: if strict_latency_gate {
                format!(
                    "strict SCK/VT encode latency gate failed: {missing_detail}; failures={} frameBudgetMs={:.2}",
                    failures,
                    webrtc_frame_budget_ms(min_fps)
                )
            } else {
                format!("{missing_detail}; failures={failures}")
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }

    let failures = failures.unwrap_or(0);
    let over_budget = webrtc_sck_vt_encode_latency_over_budget(evidence, min_fps);
    let ok = failures == 0 && !over_budget;
    let evidence_detail = evidence
        .sck_encode_latency_p95_ms
        .as_ref()
        .or(evidence.sck_encode_latency_max_ms.as_ref())
        .or(evidence.sck_encode_latency_p50_ms.as_ref())
        .map(|metric| metric.evidence.as_str())
        .or_else(|| {
            evidence
                .sck_encode_failures
                .latest
                .as_ref()
                .map(|metric| metric.evidence.as_str())
        })
        .unwrap_or("-");
    DoctorCheck {
        name: "sck_vt_encode_latency",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: format!(
            "SCK/VT encode latency: p50Ms={} p95Ms={} maxMs={} failures={} frameBudgetMs={:.2}; evidence {}",
            optional_f64_label(p50),
            optional_f64_label(p95),
            optional_f64_label(max_latency),
            failures,
            webrtc_frame_budget_ms(min_fps),
            evidence_detail
        ),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}
