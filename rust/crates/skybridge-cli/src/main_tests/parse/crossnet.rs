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
    let CrossnetSubcommand::Settings(output) = command.command else {
        panic!("expected settings subcommand");
    };
    assert!(output.json);
    assert!(Cli::try_parse_from(["skybridge", "settings", "--json"]).is_err());
}
