use super::super::evidence::WebRtcMediaEvidence;
use super::{latest_counter_value, webrtc_missing_observation_check};
use crate::DoctorCheck;

mod fps;
mod render;
mod resolution;
mod sck;

pub(in crate::webrtc_media_doctor) use fps::check_webrtc_media_fps;
pub(in crate::webrtc_media_doctor) use render::{
    check_webrtc_native_video_receiver, check_webrtc_visible_native_render,
    check_webrtc_visible_render_fps,
};
pub(in crate::webrtc_media_doctor) use resolution::check_webrtc_video_resolution;
pub(in crate::webrtc_media_doctor) use sck::{
    check_webrtc_sck_vt_encode_latency, classify_webrtc_sck_tx_stage,
};

pub(in crate::webrtc_media_doctor) fn check_webrtc_native_video_health(
    evidence: &WebRtcMediaEvidence,
) -> DoctorCheck {
    if let Some(failure) = evidence.native_video_failure.as_ref() {
        let fallback_healthy = webrtc_fallback_video_is_healthy(evidence);
        return DoctorCheck {
            name: "native_video_health",
            ok: fallback_healthy,
            severity: if fallback_healthy { "warn" } else { "error" },
            detail: if fallback_healthy {
                format!(
                    "nativeVideoHealth entered {}, but fallback video remained healthy; evidence {}",
                    failure.value, failure.evidence
                )
            } else {
                format!(
                    "nativeVideoHealth entered {} and fallback video was not healthy; evidence {}",
                    failure.value, failure.evidence
                )
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    let Some(state) = evidence.native_video_state.as_ref() else {
        return webrtc_missing_observation_check(
            "native_video_health",
            "native-video-health/native-video-tx state was not observed",
        );
    };
    DoctorCheck {
        name: "native_video_health",
        ok: true,
        severity: "info",
        detail: format!("latest native video health state {}", state.value),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn optional_f64_label(value: Option<f64>) -> String {
    value
        .map(|value| format!("{value:.3}"))
        .unwrap_or_else(|| "-".to_owned())
}

fn webrtc_encoder_satisfies_strict_hardware_gate(encoder: &str) -> bool {
    let normalized = encoder.to_ascii_lowercase();
    normalized.contains("videotoolbox") || normalized.contains("hardware")
}

pub(in crate::webrtc_media_doctor) fn check_webrtc_native_video_rtc_stats(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
    strict_native_rtp_gate: bool,
) -> DoctorCheck {
    let native_rtp_gate = min_fps >= 59.0 || (strict_native_rtp_gate && min_fps >= 30.0);
    let has_native_video_evidence = evidence.native_video_state.is_some()
        || evidence.native_video_frames_sent.latest.is_some()
        || evidence.native_video_packets_sent.latest.is_some()
        || evidence.native_video_bytes_sent.latest.is_some();
    if !has_native_video_evidence {
        return DoctorCheck {
            name: "native_video_rtc_stats",
            ok: !native_rtp_gate,
            severity: if native_rtp_gate { "error" } else { "info" },
            detail: if native_rtp_gate {
                format!(
                    "native WebRTC RTP stats were not observed; min_fps={min_fps:.1} requires native RTP evidence"
                )
            } else {
                "native WebRTC RTP stats were not observed; no native video evidence was present"
                    .to_owned()
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }

    let frames_encoded = latest_counter_value(&evidence.native_video_frames_encoded).unwrap_or(0);
    let frames_sent = latest_counter_value(&evidence.native_video_frames_sent).unwrap_or(0);
    let packets_sent = latest_counter_value(&evidence.native_video_packets_sent).unwrap_or(0);
    let bytes_sent = latest_counter_value(&evidence.native_video_bytes_sent).unwrap_or(0);
    let target_bitrate = latest_counter_value(&evidence.native_video_target_bitrate).unwrap_or(0);
    let available_outgoing_bitrate =
        latest_counter_value(&evidence.native_video_available_outgoing_bitrate).unwrap_or(0);
    let codec = evidence
        .native_video_codec
        .as_ref()
        .map(|metric| metric.value.as_str())
        .unwrap_or("-");
    let encoder = evidence
        .native_video_encoder
        .as_ref()
        .map(|metric| metric.value.as_str())
        .unwrap_or("-");
    let quality_limit = evidence
        .native_video_quality_limit
        .as_ref()
        .map(|metric| metric.value.as_str())
        .unwrap_or("-");
    let encode_fps = evidence
        .native_video_encode_fps
        .as_ref()
        .map(|metric| metric.value);
    let current_rtt = evidence
        .native_video_current_rtt
        .as_ref()
        .map(|metric| metric.value);
    let remote_rtt = evidence
        .native_video_remote_rtt
        .as_ref()
        .map(|metric| metric.value);
    let remote_packets_lost = evidence
        .native_video_remote_packets_lost
        .as_ref()
        .map(|metric| metric.value);
    let remote_jitter = evidence
        .native_video_remote_jitter
        .as_ref()
        .map(|metric| metric.value);

    let codec_missing = codec == "-";
    let encoder_missing = encoder == "-";
    let encoder_not_hardware = native_rtp_gate
        && !encoder_missing
        && !webrtc_encoder_satisfies_strict_hardware_gate(encoder);
    let bwe_missing = target_bitrate == 0 && available_outgoing_bitrate == 0;
    let quality_limited = !matches!(quality_limit.to_ascii_lowercase().as_str(), "-" | "none");
    let counters_missing =
        frames_encoded == 0 || frames_sent == 0 || packets_sent == 0 || bytes_sent == 0;
    let encode_fps_below_min = !encode_fps.is_some_and(|fps| fps >= min_fps);
    let native_rtp_ready = !codec_missing
        && !encoder_missing
        && !encoder_not_hardware
        && !bwe_missing
        && !quality_limited
        && !counters_missing;
    let ok = !native_rtp_gate || (native_rtp_ready && !encode_fps_below_min);

    let mut missing = Vec::new();
    if codec_missing {
        missing.push("codec");
    }
    if encoder_missing {
        missing.push("encoder");
    }
    if encoder_not_hardware {
        missing.push("hardwareEncoder");
    }
    if bwe_missing {
        missing.push("targetBitrate/availableOutgoingBitrate");
    }
    if counters_missing {
        missing.push("encoded/sent/rtp counters");
    }
    if quality_limited {
        missing.push("qualityLimit!=none");
    }
    if encode_fps_below_min {
        missing.push("encodeFPS<min");
    }

    DoctorCheck {
        name: "native_video_rtc_stats",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: format!(
            "native RTP stats: framesEncoded={frames_encoded} framesSent={frames_sent} packetsSent={packets_sent} bytesSent={bytes_sent} codec={codec} encoder={encoder} qualityLimit={quality_limit} encodeFPS={} targetBitrate={target_bitrate} availableOutgoingBitrate={available_outgoing_bitrate} currentRTT={} remoteRTT={} remotePacketsLost={} remoteJitter={}{}",
            optional_f64_label(encode_fps),
            optional_f64_label(current_rtt),
            optional_f64_label(remote_rtt),
            optional_f64_label(remote_packets_lost),
            optional_f64_label(remote_jitter),
            if native_rtp_gate && !missing.is_empty() && min_fps >= 59.0 {
                format!("; high-fps missing {}", missing.join(","))
            } else if native_rtp_gate && !missing.is_empty() {
                format!("; native RTP gate missing {}", missing.join(","))
            } else if !native_rtp_gate {
                "; native RTP evidence gate not enforced below 30fps".to_owned()
            } else {
                String::new()
            }
        ),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

pub(in crate::webrtc_media_doctor) fn webrtc_fallback_video_is_healthy(
    evidence: &WebRtcMediaEvidence,
) -> bool {
    evidence
        .latest_fps
        .as_ref()
        .is_some_and(|fps| fps.value > 2.0)
        && evidence.stale_fallback.is_none()
        && evidence.backpressure.is_none()
}
