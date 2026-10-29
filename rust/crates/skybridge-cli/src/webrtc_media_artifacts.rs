use std::path::PathBuf;

mod latest;
mod sources;

pub(crate) use latest::resolve_webrtc_media_session_arg;
pub(crate) use sources::{collect_webrtc_media_source_candidates, safe_webrtc_session_id};

fn default_webrtc_artifact_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library").join("Logs").join("SkyBridge"))
}
