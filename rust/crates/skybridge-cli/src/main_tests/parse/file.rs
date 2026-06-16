use clap::Parser;

use crate::{Cli, Commands, FileSubcommand};

#[test]
fn file_transfer_subcommands_parse_json_flags() {
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "file",
            "send",
            "/tmp/payload.txt",
            "--to",
            "peer-device",
            "--session-id",
            "session-1",
            "--json",
        ])
        .is_ok()
    );
    assert!(Cli::try_parse_from(["skybridge", "file", "receive", "--json"]).is_ok());
    assert!(Cli::try_parse_from(["skybridge", "file", "history", "--json"]).is_ok());
}

#[test]
fn file_send_parses_request_only_session_binding() {
    let cli = Cli::try_parse_from([
        "skybridge",
        "file",
        "send",
        "/tmp/payload.txt",
        "--to",
        "remote-device",
        "--session-id",
        "session-1",
        "--json",
    ])
    .expect("file send request-only command should parse");

    let Commands::File(file) = cli.command else {
        panic!("expected file command");
    };
    let FileSubcommand::Send(args) = file.command else {
        panic!("expected file send subcommand");
    };
    assert_eq!(args.path, std::path::PathBuf::from("/tmp/payload.txt"));
    assert_eq!(args.to, "remote-device");
    assert_eq!(args.session_id.as_deref(), Some("session-1"));
    assert!(args.output.json);
}

#[test]
fn file_send_still_accepts_legacy_planned_shape_without_session_id() {
    let cli = Cli::try_parse_from([
        "skybridge",
        "file",
        "send",
        "/tmp/payload.txt",
        "--to",
        "remote-device",
        "--json",
    ])
    .expect("legacy planned file send shape should still parse");

    let Commands::File(file) = cli.command else {
        panic!("expected file command");
    };
    let FileSubcommand::Send(args) = file.command else {
        panic!("expected file send subcommand");
    };
    assert_eq!(args.session_id, None);
}
