use std::path::Path;

use anyhow::{Result, bail};

use crate::{
    FileProveArgs, OutputOptions, PerformanceCheckArgs, PerformanceKindArg,
    performance_commands::run_performance_check,
};

pub(crate) fn send_placeholder(path: &Path, to: &str) -> Result<()> {
    bail!(
        "Phase 6 pending: file send from `{}` to `{}` waits for the shared route contract.",
        path.display(),
        to
    )
}

pub(crate) fn receive_placeholder() -> Result<()> {
    bail!("Phase 6 pending: inbound file receive is not wired yet.")
}

pub(crate) fn history_placeholder(_as_json: bool) -> Result<()> {
    bail!("Phase 6 pending: file transfer history is not wired to a real transfer registry yet.")
}

pub(crate) async fn prove_file_transfer(args: FileProveArgs) -> Result<()> {
    run_performance_check(
        PerformanceCheckArgs {
            kind: PerformanceKindArg::FileTransfer,
            session_id: None,
            latest: false,
            artifact_dir: Some(args.artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 59.0,
            min_width: 0,
            min_height: 0,
            exact_video_size: false,
            require_audio: true,
            strict_fps_floor: true,
            min_pass_window_seconds:
                crate::performance_budgets::P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
            manual_artifact: false,
            output: OutputOptions {
                json: args.output.json,
            },
        },
        "file-transfer proof failed",
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_placeholders_fail_closed_until_live_transfer_registry_exists() {
        assert!(history_placeholder(false).is_err());
        assert!(history_placeholder(true).is_err());
        assert!(send_placeholder(Path::new("/tmp/payload.txt"), "peer-device").is_err());
        assert!(receive_placeholder().is_err());
    }
}
