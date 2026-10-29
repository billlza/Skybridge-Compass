use clap::Parser;

use crate::Cli;

#[test]
fn test_swift_subcommand_parses() {
    assert!(Cli::try_parse_from(["skybridge", "test", "swift"]).is_ok());
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "test",
            "swift",
            "--filter",
            "RemoteControlSecurityNoticeTests",
            "--dry-run",
            "--json",
        ])
        .is_ok()
    );
}
