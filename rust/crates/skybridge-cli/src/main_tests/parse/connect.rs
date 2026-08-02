use clap::Parser;

use crate::{Cli, Commands};

#[test]
fn connect_uses_bounded_handshake_timeout() {
    let cli = Cli::try_parse_from(["skybridge", "connect", "SB-123456", "--json"])
        .expect("connect with default timeout should parse");
    let Commands::Connect(args) = cli.command else {
        panic!("expected connect command");
    };
    assert_eq!(args.timeout_seconds, 30);
    assert!(args.json);

    let cli = Cli::try_parse_from([
        "skybridge",
        "connect",
        "SB-123456",
        "--timeout-seconds",
        "120",
    ])
    .expect("connect with bounded timeout should parse");
    let Commands::Connect(args) = cli.command else {
        panic!("expected connect command");
    };
    assert_eq!(args.timeout_seconds, 120);

    for invalid in ["0", "301"] {
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "connect",
                "SB-123456",
                "--timeout-seconds",
                invalid,
            ])
            .is_err(),
            "timeout {invalid} must be rejected"
        );
    }
}

#[test]
fn legacy_hold_seconds_is_rejected() {
    assert!(
        Cli::try_parse_from(["skybridge", "connect", "SB-123456", "--hold-seconds", "5",]).is_err()
    );
}
