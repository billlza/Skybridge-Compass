use super::*;

mod control_plane;
mod parse;

#[tokio::test]
async fn dispatch_covers_safe_placeholders_coverage_and_smoke_aliases() -> Result<()> {
    for args in [
        &["skybridge", "version"][..],
        &[
            "skybridge",
            "check",
            "coverage",
            "--min-percent",
            "0",
            "--json",
        ][..],
        &["skybridge", "smoke", "local-webrtc", "--dry-run", "--json"][..],
        &["skybridge", "smoke", "local-p2p", "--dry-run", "--json"][..],
        &[
            "skybridge",
            "smoke",
            "real-device-p2p",
            "--dry-run",
            "--json",
        ][..],
        &[
            "skybridge",
            "smoke",
            "real-device-file-transfer",
            "--dry-run",
            "--json",
        ][..],
        &[
            "skybridge",
            "smoke",
            "all",
            "--skip-real-device",
            "--dry-run",
            "--json",
        ][..],
        &[
            "skybridge",
            "smoke",
            "fault-detection",
            "--dry-run",
            "--json",
        ][..],
    ] {
        dispatch(Cli::try_parse_from(args.iter().copied())?).await?;
    }
    let file_transfer_fixture =
        crate::cli_test_support::fixture_dir(&["file-transfer", "signed-kem-pass"]);
    dispatch(Cli::try_parse_from([
        "skybridge",
        "file",
        "prove",
        "--artifact-dir",
        &file_transfer_fixture.display().to_string(),
        "--json",
    ])?)
    .await?;

    let p2p_remote_fixture =
        crate::cli_test_support::fixture_dir(&["p2p-remote", "full-2k60-pass"]);
    dispatch(Cli::try_parse_from([
        "skybridge",
        "session",
        "remote-desktop",
        "prove",
        "--artifact-dir",
        &p2p_remote_fixture.display().to_string(),
        "--json",
    ])?)
    .await?;

    assert!(
        dispatch(Cli::try_parse_from([
            "skybridge",
            "file",
            "send",
            "/tmp/payload.txt",
            "--to",
            "peer-device",
        ])?)
        .await
        .is_err()
    );
    assert!(
        dispatch(Cli::try_parse_from([
            "skybridge",
            "file",
            "history",
            "--json"
        ])?)
        .await
        .is_err()
    );
    assert!(
        dispatch(Cli::try_parse_from(["skybridge", "file", "receive"])?)
            .await
            .is_err()
    );
    Ok(())
}
