use anyhow::Result;
use clap::Parser;

use crate::Cli;
use crate::cli_test_support::make_test_dir;

#[tokio::test]
async fn dispatch_covers_operator_entry_error_and_wrapper_paths() -> Result<()> {
    let state_dir = make_test_dir("main-dispatch-entry")?;
    let state = state_dir.display().to_string();

    dispatch_args(["skybridge", "--state-dir", &state, "logout"]).await?;
    dispatch_args([
        "skybridge",
        "--state-dir",
        &state,
        "device",
        "status",
        "--json",
    ])
    .await?;
    dispatch_args([
        "skybridge",
        "--state-dir",
        &state,
        "session",
        "ls",
        "--json",
    ])
    .await?;
    dispatch_args(["skybridge", "--state-dir", &state, "capabilities", "--json"]).await?;
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "device",
            "discover",
            "--nearby",
            "--json",
        ])
        .await
        .is_err()
    );
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "logs",
            "tail",
            "--lines",
            "1",
        ])
        .await
        .is_err()
    );
    assert!(
        dispatch_args(["skybridge", "--state-dir", &state, "metrics", "--json"])
            .await
            .is_err()
    );

    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "check",
            "memory",
            "--json",
        ])
        .await
        .is_err()
    );
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "session",
            "inspect",
            "missing"
        ])
        .await
        .is_err()
    );
    assert!(
        dispatch_args(["skybridge", "--state-dir", &state, "disconnect", "missing"])
            .await
            .is_err()
    );
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "check",
            "performance",
            "--kind",
            "p2p-remote",
        ])
        .await
        .is_err()
    );

    // This branch intentionally tolerates either outcome: missing OAuth env fails fast,
    // while a developer machine with env configured exercises the print-only path.
    let _ = dispatch_args(["skybridge", "--state-dir", &state, "login", "--print-only"]).await;

    Ok(())
}

async fn dispatch_args<const N: usize>(args: [&str; N]) -> Result<()> {
    crate::dispatch(Cli::try_parse_from(args)?).await
}
