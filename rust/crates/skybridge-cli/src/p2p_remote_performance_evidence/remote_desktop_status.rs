use crate::performance_evidence::{
    extract_text_f64, extract_text_u64, update_max_u64, update_min_f64, update_min_u64,
};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_p2p_remote_remote_desktop_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    is_ios: bool,
) {
    if is_ios && line.contains("remote-desktop") {
        if line.contains("remote-desktop-pass") || extract_text_u64(line, "pass") == Some(1) {
            evidence.remote_desktop_pass = true;
        }
        if line.contains("remote-desktop status") || line.contains("remote-desktop-pass") {
            if let Some(fps) = extract_text_f64(line, "fps") {
                evidence.latest_ios_fps = Some(fps);
            }
            if let Some(fps) = extract_text_f64(line, "rxFps") {
                evidence.latest_ios_rx_fps = Some(fps);
            }
            if extract_text_f64(line, "windowSeconds").is_some_and(|seconds| seconds >= 2.0) {
                if let Some(fps) = extract_text_f64(line, "windowFPS") {
                    evidence.latest_window_fps = Some(fps);
                    update_min_f64(&mut evidence.min_window_fps, Some(fps));
                }
                if let Some(fps) = extract_text_f64(line, "windowRxFps") {
                    evidence.latest_window_rx_fps = Some(fps);
                    update_min_f64(&mut evidence.min_window_rx_fps, Some(fps));
                }
            }
            let cadence_line_has_window = extract_text_f64(line, "windowSeconds")
                .is_some_and(|seconds| seconds >= 2.0)
                || line.contains("remote-desktop-pass")
                || extract_text_u64(line, "pass") == Some(1);
            if cadence_line_has_window {
                let required = extract_text_u64(line, "twoSecondRequiredFrames");
                let display = extract_text_u64(line, "min2sDisplayFrames")
                    .or_else(|| extract_text_u64(line, "last2sDisplayFrames"));
                let rx = extract_text_u64(line, "min2sRxFrames")
                    .or_else(|| extract_text_u64(line, "last2sRxFrames"));
                let rolling_display = extract_text_u64(line, "rollingDisplayCadencePass")
                    .or_else(|| extract_text_u64(line, "rollingCadencePass"));
                let rolling_rx = extract_text_u64(line, "rollingRxCadencePass");
                let rolling = extract_text_u64(line, "rollingCombinedCadencePass").or_else(|| {
                    rolling_display
                        .zip(rolling_rx)
                        .map_or(rolling_display, |(display, rx)| {
                            Some(if display == 1 && rx == 1 { 1 } else { 0 })
                        })
                });
                if required.is_some() || display.is_some() || rx.is_some() || rolling.is_some() {
                    evidence.ios_cadence_samples += 1;
                    update_min_u64(&mut evidence.ios_min_2s_display_frames_min, display);
                    update_min_u64(&mut evidence.ios_min_2s_rx_frames_min, rx);
                    update_max_u64(&mut evidence.ios_two_second_required_frames_max, required);
                    let cadence_ok = rolling == Some(1)
                        && required.is_some()
                        && display
                            .zip(required)
                            .is_some_and(|(frames, required)| frames >= required)
                        && rx
                            .zip(required)
                            .is_some_and(|(frames, required)| frames >= required);
                    if !cadence_ok {
                        evidence.ios_cadence_failures += 1;
                    }
                }
            }
        }
    }
}
