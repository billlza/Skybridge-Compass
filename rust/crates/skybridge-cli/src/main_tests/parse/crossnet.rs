use clap::Parser;

use crate::{Cli, Commands, CrossnetLeaseMode, CrossnetSubcommand};

#[test]
fn trust_recovery_requires_a_concrete_preview_and_explicit_retirement_flag() {
    let hash = "b".repeat(64);
    let mut args = vec![
        "skybridge",
        "crossnet",
        "trust",
        "recover",
        "00008140-000E788401C0801C",
        "--peer-id",
        "11111111-2222-3333-4444-555555555555",
        "--expected-fingerprint",
        &hash,
        "--snapshot-sha256",
        &hash,
        "--recovery-id",
        "11111111-2222-3333-4444-555555555556",
        "--json",
    ];
    assert!(Cli::try_parse_from(&args).is_err());
    args.push("--approve-mirror-retirement");
    assert!(Cli::try_parse_from(args).is_ok());
}

#[test]
fn usb_commands_keep_physical_and_protocol_identity_separate() {
    let fingerprint = "b".repeat(64);
    let peer = "11111111-2222-3333-4444-555555555555";
    let udid = "00008140-000E788401C0801C";
    assert!(Cli::try_parse_from(["skybridge", "crossnet", "usb", "devices", "--json"]).is_ok());
    let parsed = Cli::try_parse_from([
        "skybridge",
        "crossnet",
        "usb",
        "connect",
        udid,
        "--peer-id",
        peer,
        "--expected-fingerprint",
        &fingerprint,
        "--json",
    ])
    .unwrap();
    let Commands::Crossnet(command) = parsed.command else {
        panic!("expected app runtime");
    };
    let CrossnetSubcommand::Usb(command) = command.command else {
        panic!("expected USB");
    };
    let crate::CrossnetUSBSubcommand::Connect(args) = command.command else {
        panic!("expected connect");
    };
    assert_eq!(args.udid, udid);
    assert_eq!(args.peer_id, peer);
    assert_eq!(args.expected_fingerprint, fingerprint);
    assert!(args.output.json);
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "crossnet",
            "usb",
            "connect",
            udid,
            "--peer-id",
            peer
        ])
        .is_err()
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "crossnet",
            "trust",
            "preview",
            "--peer-id",
            peer,
            "--expected-fingerprint",
            &fingerprint,
            "--json"
        ])
        .is_ok()
    );
}

#[test]
fn crossnet_subcommands_parse_app_bound_surface() {
    let preflight = Cli::try_parse_from(["skybridge", "crossnet", "preflight", "--json"])
        .expect("crossnet preflight should parse");
    let Commands::Crossnet(command) = preflight.command else {
        panic!("expected crossnet command");
    };
    let CrossnetSubcommand::Preflight(output) = command.command else {
        panic!("expected preflight subcommand");
    };
    assert!(output.json);

    let host = Cli::try_parse_from([
        "skybridge",
        "crossnet",
        "host",
        "--lease",
        "short",
        "--json",
    ])
    .expect("crossnet host should parse");
    let Commands::Crossnet(command) = host.command else {
        panic!("expected crossnet command");
    };
    let CrossnetSubcommand::Host(args) = command.command else {
        panic!("expected host subcommand");
    };
    assert_eq!(args.lease, Some(CrossnetLeaseMode::Short));
    assert!(args.output.json);

    assert!(
        Cli::try_parse_from(["skybridge", "crossnet", "host", "--lease", "long", "--json"]).is_ok()
    );
    assert!(Cli::try_parse_from(["skybridge", "crossnet", "connect", "123456", "--json"]).is_ok());
    assert!(Cli::try_parse_from(["skybridge", "crossnet", "disconnect", "--json"]).is_ok());
    assert!(Cli::try_parse_from(["skybridge", "crossnet", "status", "--watch", "--json"]).is_ok());
    assert!(
        Cli::try_parse_from(["skybridge", "crossnet", "navigate", "settings", "--json"]).is_ok()
    );
    assert!(
        Cli::try_parse_from(["skybridge", "crossnet", "navigate", "remote-desktop"]).is_ok(),
        "kebab-case value-enum destinations must parse"
    );
    assert!(
        Cli::try_parse_from(["skybridge", "crossnet", "navigate", "about_box"]).is_err(),
        "unknown destinations must be rejected at the parser"
    );
    assert!(Cli::try_parse_from(["skybridge", "crossnet", "devices", "--json"]).is_ok());
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "crossnet",
            "connect-device",
            "sha256:00ff",
            "--json"
        ])
        .is_ok()
    );
    assert!(
        Cli::try_parse_from(["skybridge", "crossnet", "connect-device"]).is_err(),
        "connect-device requires a device_ref"
    );
    let settings = Cli::try_parse_from(["skybridge", "crossnet", "settings", "--json"])
        .expect("crossnet settings should parse");
    let Commands::Crossnet(command) = settings.command else {
        panic!("expected crossnet command");
    };
    let CrossnetSubcommand::Settings(args) = command.command else {
        panic!("expected settings subcommand");
    };
    assert!(args.output.json);
    assert!(
        args.command.is_none(),
        "bare `crossnet settings` must stay the read-only projection"
    );
    assert!(Cli::try_parse_from(["skybridge", "settings", "--json"]).is_err());

    let set = Cli::try_parse_from([
        "skybridge",
        "crossnet",
        "settings",
        "set",
        "logging.level",
        "Debug",
        "--json",
    ])
    .expect("crossnet settings set should parse");
    let Commands::Crossnet(command) = set.command else {
        panic!("expected crossnet command");
    };
    let CrossnetSubcommand::Settings(args) = command.command else {
        panic!("expected settings subcommand");
    };
    let Some(crate::CrossnetSettingsSubcommand::Set(set_args)) = args.command else {
        panic!("expected settings set subcommand");
    };
    assert_eq!(set_args.id, "logging.level");
    assert_eq!(set_args.value, "Debug");
    assert!(set_args.output.json);

    // Both operands are required: a bare id must not silently mean "unset".
    assert!(
        Cli::try_parse_from(["skybridge", "crossnet", "settings", "set", "logging.level"]).is_err()
    );
}
