use super::*;

#[test]
fn diagnose_latest_resolves_newest_session() -> Result<()> {
    let artifact_dir = make_test_dir("diagnose-webrtc-latest")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-OLD.jsonl"),
        json!({
            "timestamp": "2026-05-03T09:00:00Z",
            "session_id": "OLD",
            "kind": "videoStats",
            "video_fps": 20
        })
        .to_string(),
    )?;
    std::fs::write(
        artifact_dir.join("webrtc-media-NEW.jsonl"),
        json!({
            "timestamp": "2026-05-03T09:01:00Z",
            "session_id": "NEW",
            "kind": "videoStats",
            "video_fps": 20
        })
        .to_string(),
    )?;

    let resolved = resolve_webrtc_media_session_arg(None, true, Some(&artifact_dir), None)?;
    assert_eq!(resolved, "NEW");
    assert!(
        resolve_webrtc_media_session_arg(Some("NEW"), true, Some(&artifact_dir), None).is_err()
    );
    Ok(())
}
