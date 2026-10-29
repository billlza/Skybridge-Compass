use super::super::super::evidence::WebRtcMediaEvidence;
use super::super::{latest_counter_value, webrtc_missing_observation_check};
use crate::DoctorCheck;

pub(in crate::webrtc_media_doctor) fn check_webrtc_media_fps(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
    require_audio: bool,
    strict_fps_floor: bool,
) -> DoctorCheck {
    let has_native_video_evidence = evidence.native_video_state.is_some()
        || evidence.native_video_submitted.latest.is_some()
        || evidence.native_video_frames_encoded.latest.is_some()
        || evidence.native_video_frames_sent.latest.is_some()
        || evidence.native_video_packets_sent.latest.is_some()
        || evidence.native_video_bytes_sent.latest.is_some()
        || evidence.native_video_encode_fps.is_some();
    if strict_fps_floor && min_fps >= 30.0 {
        if has_native_video_evidence {
            return check_webrtc_native_video_encode_fps_floor(evidence, min_fps, true);
        }
        return DoctorCheck {
            name: "video_fps",
            ok: false,
            severity: "error",
            detail: format!(
                "strict native RTP fps floor failed: no native RTP video evidence was observed; min={min_fps:.1}"
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    if !require_audio
        && webrtc_native_video_rtp_is_flowing(evidence)
        && evidence.latest_fps.is_none()
    {
        return check_webrtc_native_video_encode_fps_floor(evidence, min_fps, false);
    }
    let Some(lowest) = evidence.lowest_fps.as_ref() else {
        return webrtc_missing_observation_check(
            "video_fps",
            "no native RTP encodeFPS or stream-stats fps sample was observed for this session",
        );
    };
    let latest_value = evidence
        .latest_fps
        .as_ref()
        .map(|value| value.value)
        .unwrap_or(lowest.value);
    let latest = format!("{latest_value:.1}");
    let ok = lowest.value > 2.0
        && latest_value >= min_fps
        && (!strict_fps_floor || lowest.value >= min_fps);
    DoctorCheck {
        name: "video_fps",
        ok,
        severity: if ok {
            "info"
        } else if lowest.value <= 2.0 {
            "error"
        } else {
            "warn"
        },
        detail: if ok {
            if lowest.value >= min_fps {
                format!(
                    "lowest recent fps {:.1} meets min {:.1}; latest fps {latest}",
                    lowest.value, min_fps
                )
            } else {
                format!(
                    "latest fps {latest} meets min {:.1}; lowest transient fps {:.1}; evidence {}",
                    min_fps, lowest.value, lowest.evidence
                )
            }
        } else if lowest.value <= 2.0 {
            format!(
                "critically low fps {:.1} (<=2.0); latest fps {latest}; evidence {}",
                lowest.value, lowest.evidence
            )
        } else if strict_fps_floor && lowest.value < min_fps {
            format!(
                "strict fps floor failed: lowest recent fps {:.1} below min {:.1}; latest fps {latest}; evidence {}",
                lowest.value, min_fps, lowest.evidence
            )
        } else {
            format!(
                "fps {:.1} below min {:.1}; latest fps {latest}; evidence {}",
                lowest.value, min_fps, lowest.evidence
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_native_video_encode_fps_floor(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
    strict_fps_floor: bool,
) -> DoctorCheck {
    if webrtc_native_video_rtp_is_flowing(evidence) {
        let submitted = latest_counter_value(&evidence.native_video_submitted).unwrap_or(0);
        let frames_encoded =
            latest_counter_value(&evidence.native_video_frames_encoded).unwrap_or(0);
        let frames_sent = latest_counter_value(&evidence.native_video_frames_sent).unwrap_or(0);
        let packets_sent = latest_counter_value(&evidence.native_video_packets_sent).unwrap_or(0);
        let bytes_sent = latest_counter_value(&evidence.native_video_bytes_sent).unwrap_or(0);
        let state = evidence
            .native_video_state
            .as_ref()
            .map(|state| state.value.as_str())
            .unwrap_or("-");
        let Some(native_latest) = evidence.native_video_encode_fps.as_ref() else {
            let hard_native_fps_gate = strict_fps_floor || min_fps >= 59.0;
            return DoctorCheck {
                name: "video_fps",
                ok: !hard_native_fps_gate,
                severity: if hard_native_fps_gate {
                    "error"
                } else {
                    "info"
                },
                detail: format!(
                    "native RTP is flowing without stream-stats or encodeFPS sample; min={min_fps:.1} state={state} submitted={submitted} framesEncoded={frames_encoded} framesSent={frames_sent} packetsSent={packets_sent} bytesSent={bytes_sent}"
                ),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            };
        };
        let native_lowest = evidence
            .native_video_lowest_encode_fps
            .as_ref()
            .unwrap_or(native_latest);
        let ok = native_lowest.value > 2.0
            && native_latest.value >= min_fps
            && (!strict_fps_floor || native_lowest.value >= min_fps);
        return DoctorCheck {
            name: "video_fps",
            ok,
            severity: if ok {
                "info"
            } else if native_lowest.value <= 2.0 {
                "error"
            } else {
                "warn"
            },
            detail: if ok {
                format!(
                    "native RTP encodeFPS meets min {min_fps:.1}; lowest {:.1} latest {:.1} state={state} submitted={submitted} framesEncoded={frames_encoded} framesSent={frames_sent} packetsSent={packets_sent} bytesSent={bytes_sent}",
                    native_lowest.value, native_latest.value
                )
            } else if strict_fps_floor && native_lowest.value < min_fps {
                format!(
                    "strict native RTP encodeFPS floor failed: lowest {:.1} below min {min_fps:.1}; latest {:.1}; evidence {}",
                    native_lowest.value, native_latest.value, native_lowest.evidence
                )
            } else {
                format!(
                    "native RTP encodeFPS {:.1} below min {min_fps:.1}; lowest {:.1}; evidence {}",
                    native_latest.value, native_lowest.value, native_latest.evidence
                )
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    let state = evidence
        .native_video_state
        .as_ref()
        .map(|state| state.value.as_str())
        .unwrap_or("-");
    DoctorCheck {
        name: "video_fps",
        ok: false,
        severity: "error",
        detail: format!(
            "native RTP was observed but is not flowing; min={min_fps:.1} state={state} submitted={} framesSent={} packetsSent={} bytesSent={}",
            latest_counter_value(&evidence.native_video_submitted).unwrap_or(0),
            latest_counter_value(&evidence.native_video_frames_sent).unwrap_or(0),
            latest_counter_value(&evidence.native_video_packets_sent).unwrap_or(0),
            latest_counter_value(&evidence.native_video_bytes_sent).unwrap_or(0)
        ),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn webrtc_native_video_rtp_is_flowing(evidence: &WebRtcMediaEvidence) -> bool {
    let state_flowing = evidence
        .native_video_state
        .as_ref()
        .is_some_and(|state| matches!(state.value.as_str(), "rtpFlowing" | "rendered" | "active"));
    let submitted =
        latest_counter_value(&evidence.native_video_submitted).is_some_and(|value| value > 0);
    let media_sent = latest_counter_value(&evidence.native_video_frames_sent)
        .is_some_and(|value| value > 0)
        || latest_counter_value(&evidence.native_video_packets_sent).is_some_and(|value| value > 0)
        || latest_counter_value(&evidence.native_video_bytes_sent).is_some_and(|value| value > 0);
    state_flowing && submitted && media_sent
}
