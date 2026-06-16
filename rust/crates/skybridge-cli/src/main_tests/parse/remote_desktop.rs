use clap::Parser;

use crate::{Cli, Commands, RemoteDesktopSubcommand};

#[test]
fn remote_desktop_subcommands_parse_with_json_flags() {
    assert!(
        Cli::try_parse_from(["skybridge", "device", "discover", "--nearby", "--json",]).is_ok()
    );
    assert!(Cli::try_parse_from(["skybridge", "remote-desktop", "contract", "--json"]).is_ok());
    assert!(Cli::try_parse_from(["skybridge", "remote-desktop", "resolutions", "--json"]).is_ok());
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "remote-desktop",
            "status",
            "--session-id",
            "session-1",
            "--json",
        ])
        .is_ok()
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "remote-desktop",
            "start",
            "--session-id",
            "session-1",
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ])
        .is_ok()
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "remote-desktop",
            "set-resolution",
            "--session-id",
            "session-1",
            "--resolution",
            "2056x1329",
            "--json",
        ])
        .is_ok()
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "remote-desktop",
            "set-fps",
            "--session-id",
            "session-1",
            "--fps",
            "120",
            "--json",
        ])
        .is_ok()
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "remote-desktop",
            "stop",
            "--session-id",
            "session-1",
            "--json",
        ])
        .is_ok()
    );
}

#[test]
fn remote_desktop_start_defaults_to_request_contract_values() {
    let cli = Cli::try_parse_from([
        "skybridge",
        "remote-desktop",
        "start",
        "--session-id",
        "session-1",
        "--json",
    ])
    .expect("remote-desktop start should parse with default request contract values");

    let Commands::RemoteDesktop(command) = cli.command else {
        panic!("expected remote-desktop command");
    };
    let RemoteDesktopSubcommand::Start(args) = command.command else {
        panic!("expected start subcommand");
    };
    assert_eq!(args.session_id, "session-1");
    assert_eq!(args.resolution, "auto");
    assert_eq!(args.fps, 60);
    assert!(args.output.json);
}

#[test]
fn remote_desktop_resolutions_parse_optional_session_filter() {
    let cli = Cli::try_parse_from([
        "skybridge",
        "remote-desktop",
        "resolutions",
        "--session-id",
        "session-1",
        "--json",
    ])
    .expect("remote-desktop resolutions should parse an optional session filter");

    let Commands::RemoteDesktop(command) = cli.command else {
        panic!("expected remote-desktop command");
    };
    let RemoteDesktopSubcommand::Resolutions(args) = command.command else {
        panic!("expected resolutions subcommand");
    };
    assert_eq!(args.session_id.as_deref(), Some("session-1"));
    assert!(args.output.json);
}

#[test]
fn remote_desktop_setters_parse_into_specific_request_variants() {
    let set_resolution = Cli::try_parse_from([
        "skybridge",
        "remote-desktop",
        "set-resolution",
        "--session-id",
        "session-resolution",
        "--resolution",
        "2056x1329",
        "--json",
    ])
    .expect("set-resolution should parse");
    let Commands::RemoteDesktop(command) = set_resolution.command else {
        panic!("expected remote-desktop command");
    };
    let RemoteDesktopSubcommand::SetResolution(args) = command.command else {
        panic!("expected set-resolution subcommand");
    };
    assert_eq!(args.session_id, "session-resolution");
    assert_eq!(args.resolution, "2056x1329");
    assert!(args.output.json);

    let set_fps = Cli::try_parse_from([
        "skybridge",
        "remote-desktop",
        "set-fps",
        "--session-id",
        "session-fps",
        "--fps",
        "120",
        "--json",
    ])
    .expect("set-fps should parse");
    let Commands::RemoteDesktop(command) = set_fps.command else {
        panic!("expected remote-desktop command");
    };
    let RemoteDesktopSubcommand::SetFps(args) = command.command else {
        panic!("expected set-fps subcommand");
    };
    assert_eq!(args.session_id, "session-fps");
    assert_eq!(args.fps, 120);
    assert!(args.output.json);
}
