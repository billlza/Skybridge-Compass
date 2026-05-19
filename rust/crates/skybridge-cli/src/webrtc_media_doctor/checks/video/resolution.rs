use super::super::super::evidence::WebRtcMediaEvidence;
use crate::DoctorCheck;

pub(in crate::webrtc_media_doctor) fn check_webrtc_video_resolution(
    evidence: &WebRtcMediaEvidence,
    min_width: u32,
    min_height: u32,
    exact_video_size: bool,
) -> DoctorCheck {
    let receiver_observed = evidence.native_video_receiver_dimensions.as_ref();
    let render_observed = evidence
        .native_video_render_dimensions
        .as_ref()
        .filter(|_| evidence.native_video_render_dimensions_are_visible);

    let exact_receiver_visible_observed = receiver_observed
        .filter(|_| exact_video_size && evidence.native_video_receiver_dimensions_are_visible);
    let (observed, observed_is_visible) =
        if let Some(receiver_observed) = exact_receiver_visible_observed {
            (Some(receiver_observed), true)
        } else if let Some(render_observed) = render_observed {
            (Some(render_observed), true)
        } else {
            (
                receiver_observed,
                evidence.native_video_receiver_dimensions_are_visible,
            )
        };
    let Some(observed) = observed else {
        let mode = if exact_video_size {
            "exactly"
        } else {
            "at least"
        };
        return DoctorCheck {
            name: "video_resolution",
            ok: false,
            severity: "error",
            detail: format!(
                "no iOS visible render or native receiver dimensions were observed; required {mode} {min_width}x{min_height}"
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    };
    let dimensions = observed.value;
    let dimensions_match = dimensions.width == min_width && dimensions.height == min_height;
    let ok = if exact_video_size {
        dimensions_match && observed_is_visible
    } else {
        dimensions.width >= min_width && dimensions.height >= min_height
    };
    DoctorCheck {
        name: "video_resolution",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: if ok && exact_video_size {
            format!(
                "iOS visible render/receiver dimensions {}x{} match exact target {}x{}",
                dimensions.width, dimensions.height, min_width, min_height
            )
        } else if exact_video_size && dimensions_match && !observed_is_visible {
            format!(
                "iOS receiver dimensions {}x{} match exact target {}x{} but were not reported as explicit visible dimensions; evidence {}",
                dimensions.width, dimensions.height, min_width, min_height, observed.evidence
            )
        } else if ok {
            format!(
                "iOS visible render/receiver dimensions {}x{} meet minimum {}x{}",
                dimensions.width, dimensions.height, min_width, min_height
            )
        } else if exact_video_size {
            format!(
                "iOS receiver dimensions {}x{} do not match exact target {}x{}; evidence {}",
                dimensions.width, dimensions.height, min_width, min_height, observed.evidence
            )
        } else {
            format!(
                "iOS receiver dimensions {}x{} below minimum {}x{}; evidence {}",
                dimensions.width, dimensions.height, min_width, min_height, observed.evidence
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}
