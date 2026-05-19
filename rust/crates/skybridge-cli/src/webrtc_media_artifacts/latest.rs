use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow, bail};
use time::OffsetDateTime;

use super::default_webrtc_artifact_dir;
use crate::webrtc_media_parse::{find_webrtc_string, parse_webrtc_diagnostic_timestamp};

pub(crate) fn resolve_webrtc_media_session_arg(
    session_id: Option<&str>,
    latest: bool,
    artifact_dir: Option<&Path>,
    log_file: Option<&Path>,
) -> Result<String> {
    let session_id = session_id.map(str::trim).filter(|value| !value.is_empty());
    match (session_id, latest) {
        (Some(_), true) => bail!("pass either --session-id <id> or --latest, not both"),
        (Some(session_id), false) => Ok(session_id.to_owned()),
        (None, true) => resolve_latest_webrtc_media_session_id(artifact_dir, log_file),
        (None, false) => bail!("pass --session-id <id> or --latest"),
    }
}

fn resolve_latest_webrtc_media_session_id(
    artifact_dir: Option<&Path>,
    log_file: Option<&Path>,
) -> Result<String> {
    let mut candidates = Vec::new();
    if let Some(log_file) = log_file {
        candidates.push(log_file.to_path_buf());
    }
    if let Some(artifact_dir) = artifact_dir {
        collect_webrtc_media_latest_candidates_from_dir(artifact_dir, &mut candidates);
    }
    if artifact_dir.is_none()
        && log_file.is_none()
        && let Some(default_dir) = default_webrtc_artifact_dir()
    {
        collect_webrtc_media_latest_candidates_from_dir(&default_dir, &mut candidates);
    }

    candidates.sort();
    candidates.dedup();

    let mut best: Option<(OffsetDateTime, String)> = None;
    for path in candidates {
        let Ok(file) = File::open(&path) else {
            continue;
        };
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let json = serde_json::from_str::<serde_json::Value>(trimmed).ok();
            let Some(session_id) = find_webrtc_string(json.as_ref(), trimmed, "sessionId")
                .or_else(|| find_webrtc_string(json.as_ref(), trimmed, "session_id"))
                .or_else(|| find_webrtc_string(json.as_ref(), trimmed, "session"))
                .or_else(|| session_id_from_webrtc_media_file_name(&path))
            else {
                continue;
            };
            let timestamp = parse_webrtc_diagnostic_timestamp(trimmed, json.as_ref())
                .or_else(|| file_modified_time_utc(&path))
                .unwrap_or_else(OffsetDateTime::now_utc);
            if best
                .as_ref()
                .is_none_or(|(best_timestamp, _)| timestamp >= *best_timestamp)
            {
                best = Some((timestamp, session_id));
            }
        }
    }

    best.map(|(_, session_id)| session_id)
        .ok_or_else(|| anyhow!("could not find latest WebRTC media diagnostics session"))
}

fn collect_webrtc_media_latest_candidates_from_dir(dir: &Path, candidates: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries = entries.flatten().collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if name.starts_with("webrtc-media-")
            || name.starts_with("webrtc-session-")
            || name.contains("webrtc")
            || name.contains("smoke-status")
        {
            candidates.push(path);
        }
    }
}

fn session_id_from_webrtc_media_file_name(path: &Path) -> Option<String> {
    let name = path.file_name()?.to_str()?;
    let value = name
        .strip_prefix("webrtc-media-")
        .or_else(|| name.strip_prefix("webrtc-session-"))?;
    let session_id = value
        .trim_end_matches(".jsonl")
        .trim_end_matches(".log")
        .trim_end_matches(".txt")
        .to_owned();
    (!session_id.is_empty()).then_some(session_id)
}

fn file_modified_time_utc(path: &Path) -> Option<OffsetDateTime> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(OffsetDateTime::from(modified))
}

#[cfg(test)]
mod tests {
    use anyhow::Result;

    use super::*;
    use crate::cli_test_support::make_test_dir;

    #[test]
    fn resolve_latest_session_prefers_newest_timestamp_and_validates_args() -> Result<()> {
        let artifact_dir = make_test_dir("webrtc-media-latest")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-OLD.jsonl"),
            r#"{"timestamp":"2026-05-16T01:00:00Z","session":"OLD"}"#,
        )?;
        std::fs::write(
            artifact_dir.join("webrtc-session-NEW.log"),
            "[2026-05-16T01:00:01Z] native-video-tx session=NEW framesSent=1\n",
        )?;

        assert_eq!(
            resolve_webrtc_media_session_arg(None, true, Some(&artifact_dir), None)?,
            "NEW"
        );
        assert_eq!(
            resolve_webrtc_media_session_arg(Some(" EXPLICIT "), false, Some(&artifact_dir), None)?,
            "EXPLICIT"
        );
        assert!(
            resolve_webrtc_media_session_arg(Some("NEW"), true, Some(&artifact_dir), None).is_err()
        );
        assert!(resolve_webrtc_media_session_arg(None, false, Some(&artifact_dir), None).is_err());
        Ok(())
    }
}
