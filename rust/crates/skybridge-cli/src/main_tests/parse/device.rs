use clap::Parser;

use crate::{Cli, Commands, DeviceSubcommand};

#[test]
fn device_discover_nearby_parses_json_flag_and_state_dir() {
    let cli = Cli::try_parse_from([
        "skybridge",
        "--state-dir",
        "/tmp/skybridge-state",
        "device",
        "discover",
        "--nearby",
        "--json",
    ])
    .expect("device discover --nearby should parse");

    assert_eq!(
        cli.state_dir.as_deref(),
        Some(std::path::Path::new("/tmp/skybridge-state"))
    );
    let Commands::Device(command) = cli.command else {
        panic!("expected device command");
    };
    let DeviceSubcommand::Discover(args) = command.command else {
        panic!("expected discover subcommand");
    };
    assert!(args.nearby);
    assert!(!args.scan);
    assert!(args.output.json);
}

#[test]
fn device_discover_active_scan_parses_command_shape() {
    let cli = Cli::try_parse_from([
        "skybridge",
        "device",
        "discover",
        "--nearby",
        "--scan",
        "--json",
    ])
    .expect("active scan command shape should parse");

    let Commands::Device(command) = cli.command else {
        panic!("expected device command");
    };
    let DeviceSubcommand::Discover(args) = command.command else {
        panic!("expected discover subcommand");
    };
    assert!(args.nearby);
    assert!(args.scan);
    assert!(args.output.json);
}
