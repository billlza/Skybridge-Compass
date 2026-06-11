use clap::Parser;

use crate::{
    Cli, Commands, DeviceCapabilityArg, DeviceSubcommand, FileSubcommand, RemoteDesktopSubcommand,
    SessionSubcommand,
};

#[test]
fn operator_device_discover_file_and_remote_desktop_subcommands_parse() {
    let cli = Cli::try_parse_from([
        "skybridge",
        "device",
        "discover",
        "--timeout-seconds",
        "7",
        "--service-type",
        "_skybridge._tcp",
        "--service-type",
        "_skybridge-transfer._tcp.local.",
        "--require-capability",
        "remote-desktop",
        "--json",
    ])
    .expect("device discover should parse");
    let Commands::Device(device) = cli.command else {
        panic!("expected device command");
    };
    let DeviceSubcommand::Discover(args) = device.command else {
        panic!("expected device discover command");
    };
    assert_eq!(args.timeout_seconds, 7);
    assert_eq!(
        args.service_types,
        vec![
            "_skybridge._tcp".to_owned(),
            "_skybridge-transfer._tcp.local.".to_owned(),
        ]
    );
    assert_eq!(
        args.required_capabilities,
        vec![DeviceCapabilityArg::RemoteDesktop]
    );
    assert!(args.output.json);

    let cli = Cli::try_parse_from([
        "skybridge",
        "file",
        "prove",
        "--artifact-dir",
        "/tmp/file-transfer-artifact",
        "--json",
    ])
    .expect("file prove should parse");
    let Commands::File(file) = cli.command else {
        panic!("expected file command");
    };
    let FileSubcommand::Prove(args) = file.command else {
        panic!("expected file prove command");
    };
    assert_eq!(
        args.artifact_dir,
        std::path::PathBuf::from("/tmp/file-transfer-artifact")
    );
    assert!(args.output.json);

    let cli = Cli::try_parse_from([
        "skybridge",
        "session",
        "remote-desktop",
        "prove",
        "--artifact-dir",
        "/tmp/p2p-artifact",
        "--min-fps",
        "59",
        "--min-width",
        "2056",
        "--min-height",
        "1329",
        "--exact-video-size",
        "--min-pass-window-seconds",
        "10",
        "--manual-artifact",
        "--json",
    ])
    .expect("remote desktop prove should parse");
    let Commands::Session(session) = cli.command else {
        panic!("expected session command");
    };
    let SessionSubcommand::RemoteDesktop(remote_desktop) = session.command else {
        panic!("expected remote-desktop command");
    };
    let RemoteDesktopSubcommand::Prove(args) = remote_desktop.command;
    assert_eq!(
        args.artifact_dir,
        std::path::PathBuf::from("/tmp/p2p-artifact")
    );
    assert_eq!(args.min_fps, 59.0);
    assert_eq!(args.min_width, 2056);
    assert_eq!(args.min_height, 1329);
    assert!(args.exact_video_size);
    assert_eq!(args.min_pass_window_seconds, 10);
    assert!(args.manual_artifact);
    assert!(args.output.json);
}

#[test]
fn device_discover_rejects_empty_service_type_at_parse_boundary() {
    assert!(
        Cli::try_parse_from(["skybridge", "device", "discover", "--service-type", "",]).is_err()
    );
}
