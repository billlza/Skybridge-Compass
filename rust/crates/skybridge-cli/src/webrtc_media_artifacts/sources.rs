use std::path::{Path, PathBuf};

use super::default_webrtc_artifact_dir;

pub(crate) fn collect_webrtc_media_source_candidates(
    session_id: &str,
    artifact_dir: Option<&Path>,
    log_file: Option<&Path>,
) -> Vec<PathBuf> {
    let mut sources = Vec::new();
    if let Some(log_file) = log_file {
        sources.push(log_file.to_path_buf());
    }

    let mut candidate_dirs = Vec::new();
    if let Some(artifact_dir) = artifact_dir {
        candidate_dirs.push(artifact_dir.to_path_buf());
    }
    if artifact_dir.is_none()
        && let Some(default_dir) = default_webrtc_artifact_dir()
        && !candidate_dirs.iter().any(|path| path == &default_dir)
    {
        candidate_dirs.push(default_dir);
    }

    let safe_session_id = safe_webrtc_session_id(session_id);
    for artifact_dir in candidate_dirs {
        for candidate in [
            artifact_dir.join(format!("webrtc-session-{safe_session_id}.log")),
            artifact_dir.join(format!("webrtc-session-{safe_session_id}.jsonl")),
            artifact_dir.join(format!("webrtc-media-{safe_session_id}.jsonl")),
            artifact_dir.join("skybridge-smoke-status.log"),
        ] {
            if candidate.is_file() {
                sources.push(candidate);
            }
        }

        if let Ok(entries) = std::fs::read_dir(&artifact_dir) {
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
                let extension_ok = path
                    .extension()
                    .and_then(|extension| extension.to_str())
                    .is_some_and(|extension| matches!(extension, "log" | "jsonl" | "txt"));
                if !extension_ok {
                    continue;
                }
                if name.contains(session_id)
                    || name.contains(&safe_session_id)
                    || name.contains("webrtc")
                    || name.contains("smoke-status")
                    || name == "mac.status.log"
                    || name == "mac.status.log.trace.log"
                    || name.starts_with("mac_round_")
                    || name.starts_with("ios_round_")
                {
                    sources.push(path);
                }
            }
        }
    }

    sources
}

pub(crate) fn safe_webrtc_session_id(session_id: &str) -> String {
    session_id
        .chars()
        .filter(|value| value.is_ascii_alphanumeric() || *value == '-' || *value == '_')
        .collect()
}

#[cfg(test)]
mod tests {
    use anyhow::Result;

    use super::*;
    use crate::cli_test_support::make_test_dir;

    #[test]
    fn source_candidates_include_explicit_log_and_artifact_matches() -> Result<()> {
        let artifact_dir = make_test_dir("webrtc-media-sources")?;
        let explicit = artifact_dir.join("explicit.log");
        let session_log = artifact_dir.join("webrtc-session-SESSION_1.log");
        let round_log = artifact_dir.join("mac_round_1.status.log");
        let ignored = artifact_dir.join("unrelated.bin");
        for path in [&explicit, &session_log, &round_log, &ignored] {
            std::fs::write(path, "x")?;
        }

        let candidates = collect_webrtc_media_source_candidates(
            "SESSION/1",
            Some(&artifact_dir),
            Some(&explicit),
        );
        assert_eq!(candidates.first(), Some(&explicit));
        assert!(candidates.contains(&session_log));
        assert!(candidates.contains(&round_log));
        assert!(!candidates.contains(&ignored));
        Ok(())
    }

    #[test]
    fn safe_session_id_filters_filename_unsafe_characters() {
        assert_eq!(safe_webrtc_session_id("SESSION/1:bad ok"), "SESSION1badok");
    }
}
