use std::cmp::Ordering;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use time::OffsetDateTime;

use super::line_extract::*;
use crate::webrtc_media_artifacts::{
    collect_webrtc_media_source_candidates, safe_webrtc_session_id,
};
use crate::webrtc_media_parse::{find_webrtc_f64_any, parse_webrtc_diagnostic_timestamp};
use crate::webrtc_media_summary::summarize_webrtc_evidence_line;

mod audio;
mod observation;
mod render;
mod types;
mod video;

use audio::observe_webrtc_audio_evidence;
#[cfg(test)]
pub(super) use observation::observe_webrtc_counter;
use observation::{
    is_webrtc_diagnostic_recent, update_latest_metric, update_lowest_f64,
    update_webrtc_gate_freshness_markers,
};
use render::observe_webrtc_render_evidence;
pub(super) use types::{CounterObservation, ObservedMetric, WebRtcMediaEvidence};
use video::observe_webrtc_video_evidence;

#[derive(Debug)]
struct WebRtcMediaRawLine {
    source: PathBuf,
    line_number: usize,
    line: String,
    source_is_session_specific: bool,
    observed_at: Option<OffsetDateTime>,
    source_order: usize,
}

pub(super) fn read_webrtc_media_evidence(
    session_id: &str,
    artifact_dir: Option<&Path>,
    log_file: Option<&Path>,
    since_seconds: u64,
    now: OffsetDateTime,
    not_before: Option<OffsetDateTime>,
) -> WebRtcMediaEvidence {
    let mut evidence = WebRtcMediaEvidence::default();
    let sources = collect_webrtc_media_source_candidates(session_id, artifact_dir, log_file);
    let safe_session_id = safe_webrtc_session_id(session_id);
    let session_log_name = format!("webrtc-session-{safe_session_id}.log");
    let mut raw_lines = Vec::new();

    for source in sources {
        if evidence
            .attempted_sources
            .iter()
            .any(|path| path == &source)
        {
            continue;
        }
        evidence.attempted_sources.push(source.clone());
        let source_is_session_specific = source
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name == session_log_name || name.contains(session_id));
        let file = match File::open(&source) {
            Ok(file) => file,
            Err(error) => {
                evidence
                    .read_errors
                    .push(format!("{}: {}", source.display(), error));
                continue;
            }
        };
        let source_order = evidence.read_sources.len();
        evidence.read_sources.push(source.clone());
        for (line_index, line) in BufReader::new(file).lines().enumerate() {
            let line_number = line_index + 1;
            let line = match line {
                Ok(line) => line,
                Err(error) => {
                    evidence.read_errors.push(format!(
                        "{}:{}: {}",
                        source.display(),
                        line_number,
                        error
                    ));
                    continue;
                }
            };
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let json = serde_json::from_str::<serde_json::Value>(trimmed).ok();
            let observed_at = parse_webrtc_diagnostic_timestamp(trimmed, json.as_ref());
            raw_lines.push(WebRtcMediaRawLine {
                source: source.clone(),
                line_number,
                line,
                source_is_session_specific,
                observed_at,
                source_order,
            });
        }
    }

    raw_lines.sort_by(compare_webrtc_media_raw_lines);
    for raw_line in raw_lines {
        observe_webrtc_media_line(
            &mut evidence,
            session_id,
            &raw_line.source,
            raw_line.line_number,
            &raw_line.line,
            raw_line.source_is_session_specific,
            since_seconds,
            now,
            not_before,
        );
    }

    evidence
}

fn compare_webrtc_media_raw_lines(
    left: &WebRtcMediaRawLine,
    right: &WebRtcMediaRawLine,
) -> Ordering {
    match (left.observed_at, right.observed_at) {
        (Some(left_at), Some(right_at)) => left_at.cmp(&right_at),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
    .then_with(|| left.source_order.cmp(&right.source_order))
    .then_with(|| left.line_number.cmp(&right.line_number))
}

#[allow(clippy::too_many_arguments)]
fn observe_webrtc_media_line(
    evidence: &mut WebRtcMediaEvidence,
    session_id: &str,
    source: &Path,
    line_number: usize,
    line: &str,
    source_is_session_specific: bool,
    since_seconds: u64,
    now: OffsetDateTime,
    not_before: Option<OffsetDateTime>,
) {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }
    let json = serde_json::from_str::<serde_json::Value>(trimmed).ok();
    let observed_at = parse_webrtc_diagnostic_timestamp(trimmed, json.as_ref());
    if observed_at
        .is_some_and(|timestamp| !is_webrtc_diagnostic_recent(timestamp, since_seconds, now))
    {
        return;
    }
    if let Some(not_before) = not_before {
        match observed_at {
            Some(timestamp) if timestamp >= not_before => {}
            Some(_) | None => return,
        }
    }
    if !source_is_session_specific
        && !webrtc_line_matches_session(trimmed, json.as_ref(), session_id)
    {
        return;
    }

    evidence.matched_lines += 1;
    let sequence = evidence.matched_lines;
    if let Some(observed_at) = observed_at
        && evidence
            .latest_at
            .is_none_or(|current| observed_at > current)
    {
        evidence.latest_at = Some(observed_at);
    }
    update_webrtc_gate_freshness_markers(evidence, trimmed, json.as_ref(), observed_at);
    let summary = summarize_webrtc_evidence_line(source, line_number, trimmed);

    if is_webrtc_stream_stats_line(trimmed, json.as_ref())
        && let Some(fps) =
            find_webrtc_f64_any(json.as_ref(), trimmed, &["fps", "video_fps", "videoFPS"])
    {
        update_latest_metric(
            &mut evidence.latest_fps,
            ObservedMetric {
                value: fps,
                sequence,
                evidence: summary.clone(),
            },
        );
        update_lowest_f64(
            &mut evidence.lowest_fps,
            ObservedMetric {
                value: fps,
                sequence,
                evidence: summary.clone(),
            },
        );
    }

    observe_webrtc_audio_evidence(evidence, json.as_ref(), trimmed, sequence, &summary);
    observe_webrtc_video_evidence(evidence, json.as_ref(), trimmed, sequence, &summary);
    observe_webrtc_render_evidence(evidence, json.as_ref(), trimmed, sequence, &summary);
}

pub(super) fn describe_webrtc_sources(evidence: &WebRtcMediaEvidence) -> String {
    if evidence.read_sources.is_empty() {
        return "none".to_owned();
    }
    evidence
        .read_sources
        .iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>()
        .join(",")
}
