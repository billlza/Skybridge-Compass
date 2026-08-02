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
    assert!(Cli::try_parse_from(["skybridge", "file", "receive", "--list", "--json"]).is_ok());
    assert!(Cli::try_parse_from(["skybridge", "file", "history", "--json"]).is_ok());
}

#[test]
fn file_receive_requires_one_explicit_approval_action() {
    assert!(Cli::try_parse_from(["skybridge", "file", "receive", "--json"]).is_err());
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "file",
            "receive",
            "--session-id",
            "session-1",
            "--accept",
            "11111111-1111-4111-8111-111111111111",
            "--json",
        ])
        .is_ok()
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "file",
            "receive",
            "--reject",
            "11111111-1111-4111-8111-111111111111",
        ])
        .is_err(),
        "accept/reject must be bound to a session"
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "file",
            "receive",
            "--list",
            "--session-id",
            "session-1",
            "--reject",
            "11111111-1111-4111-8111-111111111111",
        ])
        .is_err(),
        "list and mutation actions must remain mutually exclusive"
    );
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
    assert!(!args.detach);
    assert_eq!(args.timeout_seconds, 300);
    assert!(args.output.json);
}

#[test]
fn file_send_parses_detach_and_bounded_timeout() {
    let cli = Cli::try_parse_from([
        "skybridge",
        "file",
        "send",
        "/tmp/payload.txt",
        "--to",
        "remote-device",
        "--session-id",
        "session-1",
        "--detach",
        "--timeout-seconds",
        "600",
    ])
    .expect("bounded detach file send should parse");
    let Commands::File(file) = cli.command else {
        panic!("expected file command");
    };
    let FileSubcommand::Send(args) = file.command else {
        panic!("expected file send subcommand");
    };
    assert!(args.detach);
    assert_eq!(args.timeout_seconds, 600);

    for invalid in ["0", "3601"] {
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "file",
                "send",
                "/tmp/payload.txt",
                "--to",
                "remote-device",
                "--session-id",
                "session-1",
                "--timeout-seconds",
                invalid,
            ])
            .is_err(),
            "timeout {invalid} must be rejected"
        );
    }
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
