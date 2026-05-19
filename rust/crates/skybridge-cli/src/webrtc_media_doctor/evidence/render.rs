use super::super::line_extract::{
    find_webrtc_fallback_producer_failure_reason, find_webrtc_native_video_receiver_frame,
    find_webrtc_native_video_render_dimensions, find_webrtc_native_video_render_frame,
    find_webrtc_strict_media_failure_reason, is_backpressure_line, is_stale_fallback_line,
    is_webrtc_native_video_receiver_line, is_webrtc_native_video_render_line,
    is_webrtc_visible_native_render_fps_line,
};
use super::observation::{update_latest_metric, update_lowest_f64};
use super::types::{ObservedMetric, WebRtcMediaEvidence};
use crate::webrtc_media_dimensions::{
    VideoDimensions, find_webrtc_native_video_receiver_dimensions,
};
use crate::webrtc_media_parse::{
    find_webrtc_f64_any, find_webrtc_string, find_webrtc_string_any, find_webrtc_u64,
};

pub(in crate::webrtc_media_doctor) fn observe_webrtc_render_evidence(
    evidence: &mut WebRtcMediaEvidence,
    json: Option<&serde_json::Value>,
    trimmed: &str,
    sequence: usize,
    summary: &str,
) {
    if is_webrtc_native_video_receiver_line(trimmed, json)
        && let Some(receiver_dimensions) =
            find_webrtc_native_video_receiver_dimensions(json, trimmed)
    {
        let should_update_dimensions = receiver_dimensions.explicit_visible
            || !evidence.native_video_receiver_dimensions_are_visible;
        if should_update_dimensions {
            update_latest_metric(
                &mut evidence.native_video_receiver_dimensions,
                ObservedMetric {
                    value: receiver_dimensions.dimensions,
                    sequence,
                    evidence: summary.to_owned(),
                },
            );
            if receiver_dimensions.explicit_visible {
                evidence.native_video_receiver_dimensions_are_visible = true;
            }
        }
    }

    if let Some(receiver) = find_webrtc_native_video_receiver_frame(json, trimmed) {
        update_latest_metric(
            &mut evidence.native_video_receiver_frame,
            ObservedMetric {
                value: receiver,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    if is_webrtc_native_video_render_line(trimmed, json) {
        let render_frame = find_webrtc_native_video_render_frame(json, trimmed);
        if let Some(render_frame) = render_frame {
            update_latest_metric(
                &mut evidence.native_video_render_frame,
                ObservedMetric {
                    value: render_frame,
                    sequence,
                    evidence: summary.to_owned(),
                },
            );
            if let Some(render_dimensions) =
                find_webrtc_native_video_render_dimensions(json, trimmed)
            {
                let should_update_dimensions = render_dimensions.explicit_visible
                    || !evidence.native_video_render_dimensions_are_visible;
                if should_update_dimensions {
                    update_latest_metric(
                        &mut evidence.native_video_render_dimensions,
                        ObservedMetric {
                            value: render_dimensions.dimensions,
                            sequence,
                            evidence: summary.to_owned(),
                        },
                    );
                    if render_dimensions.explicit_visible {
                        evidence.native_video_render_dimensions_are_visible = true;
                    }
                }
            }
            if let Some(surface) = find_webrtc_string_any(json, trimmed, &["uiSurface", "surface"])
            {
                update_latest_metric(
                    &mut evidence.native_video_render_surface,
                    ObservedMetric {
                        value: surface,
                        sequence,
                        evidence: summary.to_owned(),
                    },
                );
            }
        }
        if let Some(source) =
            find_webrtc_string_any(json, trimmed, &["nativeRenderEvidenceSource", "source"])
        {
            update_latest_metric(
                &mut evidence.native_video_render_source,
                ObservedMetric {
                    value: source,
                    sequence,
                    evidence: summary.to_owned(),
                },
            );
        }
    }

    if is_webrtc_visible_native_render_fps_line(trimmed, json)
        && let Some(fps) = find_webrtc_f64_any(
            json,
            trimmed,
            &[
                "viewerDisplayFPS",
                "displayFPS",
                "visibleRenderFPS",
                "renderFPS",
            ],
        )
    {
        let observed = ObservedMetric {
            value: fps,
            sequence,
            evidence: summary.to_owned(),
        };
        update_latest_metric(&mut evidence.native_video_render_fps, observed.clone());
        update_lowest_f64(&mut evidence.native_video_lowest_render_fps, observed);
        let source = find_webrtc_string(json, trimmed, "source").unwrap_or_default();
        let ui_surface = find_webrtc_string(json, trimmed, "uiSurface")
            .or_else(|| find_webrtc_string(json, trimmed, "surface"))
            .unwrap_or_default();
        if !source.is_empty() {
            update_latest_metric(
                &mut evidence.native_video_render_source,
                ObservedMetric {
                    value: source.clone(),
                    sequence,
                    evidence: summary.to_owned(),
                },
            );
        }
        if !ui_surface.is_empty() {
            update_latest_metric(
                &mut evidence.native_video_render_surface,
                ObservedMetric {
                    value: ui_surface.clone(),
                    sequence,
                    evidence: summary.to_owned(),
                },
            );
        }
        if let (Some(width), Some(height)) = (
            find_webrtc_u64(json, trimmed, "visibleWidth"),
            find_webrtc_u64(json, trimmed, "visibleHeight"),
        ) && width > 0
            && height > 0
        {
            update_latest_metric(
                &mut evidence.native_video_render_dimensions,
                ObservedMetric {
                    value: VideoDimensions {
                        width: width as u32,
                        height: height as u32,
                    },
                    sequence,
                    evidence: summary.to_owned(),
                },
            );
            evidence.native_video_render_dimensions_are_visible = true;
        }
        if source == "rtc-mtl-video-view" && ui_surface == "remoteDesktopView" {
            update_latest_metric(
                &mut evidence.native_video_render_frame,
                ObservedMetric {
                    value: format!(
                        "source={source} uiSurface={ui_surface} visibleRenderFPS={fps:.1}"
                    ),
                    sequence,
                    evidence: summary.to_owned(),
                },
            );
        }
    }

    if let Some(reason) = find_webrtc_strict_media_failure_reason(json, trimmed) {
        update_latest_metric(
            &mut evidence.strict_media_failure,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    if is_stale_fallback_line(json, trimmed) {
        update_latest_metric(
            &mut evidence.stale_fallback,
            ObservedMetric {
                value: "forbidden_fallback".to_owned(),
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }
    if let Some(reason) = find_webrtc_fallback_producer_failure_reason(json, trimmed) {
        update_latest_metric(
            &mut evidence.fallback_producer_failure,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }
    if is_backpressure_line(json, trimmed) {
        update_latest_metric(
            &mut evidence.backpressure,
            ObservedMetric {
                value: "backpressure".to_owned(),
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }
}
