use clap::Parser;

use crate::{Cli, Commands, CrossnetLeaseMode, CrossnetSubcommand};

#[test]
fn crossnet_subcommands_parse_app_bound_surface() {
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
}
