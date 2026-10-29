use super::super::super::evidence::WebRtcMediaEvidence;
use super::super::webrtc_missing_observation_check;
use crate::DoctorCheck;

pub(in crate::webrtc_media_doctor) fn check_webrtc_native_video_receiver(
    evidence: &WebRtcMediaEvidence,
) -> DoctorCheck {
    if let Some(dimensions) = evidence.native_video_receiver_dimensions.as_ref()
        && evidence.native_video_receiver_dimensions_are_visible
    {
        return DoctorCheck {
            name: "native_video_receiver",
            ok: true,
            severity: "info",
            detail: format!(
                "iOS native receiver visible dimensions observed: {}x{}; evidence {}",
                dimensions.value.width, dimensions.value.height, dimensions.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }

    let Some(receiver) = evidence.native_video_receiver_frame.as_ref() else {
        return webrtc_missing_observation_check(
            "native_video_receiver",
            "iOS native receiver/decode frame evidence was not observed",
        );
    };
    DoctorCheck {
        name: "native_video_receiver",
        ok: true,
        severity: "info",
        detail: format!("iOS native receiver evidence observed: {}", receiver.value),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

pub(in crate::webrtc_media_doctor) fn check_webrtc_visible_native_render(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
    strict_native_render_gate: bool,
) -> DoctorCheck {
    let visible_render_gate = min_fps >= 59.0 || (strict_native_render_gate && min_fps >= 30.0);
    let Some(render_frame) = evidence.native_video_render_frame.as_ref() else {
        return DoctorCheck {
            name: "visible_native_render",
            ok: !visible_render_gate,
            severity: if visible_render_gate { "error" } else { "info" },
            detail: if visible_render_gate {
                "iOS RTCMTLVideoView visible render evidence was not observed; native video gate requires real visible rendering, not receiver stats only".to_owned()
            } else {
                "iOS RTCMTLVideoView visible render evidence was not observed; visible-render gate not enforced below 30fps".to_owned()
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    };
    let source = evidence
        .native_video_render_source
        .as_ref()
        .map(|metric| metric.value.as_str())
        .unwrap_or("-");
    let ui_surface = evidence
        .native_video_render_surface
        .as_ref()
        .map(|metric| metric.value.as_str())
        .unwrap_or("-");
    let source_ok = source == "rtc-mtl-video-view" && ui_surface == "remoteDesktopView";
    let dimensions_label = evidence
        .native_video_render_dimensions
        .as_ref()
        .map(|metric| format!("{}x{}", metric.value.width, metric.value.height))
        .unwrap_or_else(|| "-".to_owned());
    DoctorCheck {
        name: "visible_native_render",
        ok: source_ok,
        severity: if source_ok { "info" } else { "error" },
        detail: format!(
            "iOS visible native render source={source} uiSurface={ui_surface} dimensions={dimensions_label}; evidence {}",
            render_frame.evidence
        ),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

pub(in crate::webrtc_media_doctor) fn check_webrtc_visible_render_fps(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
    strict_fps_floor: bool,
) -> DoctorCheck {
    let Some(latest) = evidence.native_video_render_fps.as_ref() else {
        let visible_fps_gate = strict_fps_floor && min_fps >= 30.0;
        return DoctorCheck {
            name: "visible_render_fps",
            ok: !visible_fps_gate,
            severity: if visible_fps_gate { "error" } else { "info" },
            detail: if visible_fps_gate {
                "iOS visible render FPS telemetry was not observed; strict native video gate requires sustained visible render FPS, not one-time render presence only".to_owned()
            } else {
                "iOS visible render FPS telemetry was not observed; falling back to native render presence evidence".to_owned()
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    };
    let lowest = evidence
        .native_video_lowest_render_fps
        .as_ref()
        .map(|metric| metric.value)
        .unwrap_or(latest.value);
    let ok = latest.value >= min_fps && (!strict_fps_floor || lowest >= min_fps);
    DoctorCheck {
        name: "visible_render_fps",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: if ok {
            format!(
                "iOS visible render FPS latest {:.1}, lowest {:.1}; evidence {}",
                latest.value, lowest, latest.evidence
            )
        } else if strict_fps_floor {
            format!(
                "strict iOS visible render FPS floor failed: latest {:.1}, lowest {:.1}, min {:.1}; evidence {}",
                latest.value, lowest, min_fps, latest.evidence
            )
        } else {
            format!(
                "iOS visible render FPS below min: latest {:.1}, lowest {:.1}, min {:.1}; evidence {}",
                latest.value, lowest, min_fps, latest.evidence
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}
