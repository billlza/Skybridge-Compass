use clap::Parser;

use crate::{Cli, Commands, CrossnetLeaseMode, CrossnetSubcommand};

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
