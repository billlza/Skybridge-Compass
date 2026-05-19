use clap::Parser;

use crate::Cli;

#[test]
fn doctor_and_connection_code_subcommands_parse_with_json_flags() {
    assert!(Cli::try_parse_from(["skybridge", "doctor", "--json"]).is_ok());
    assert!(Cli::try_parse_from(["skybridge", "code", "current", "--json"]).is_ok());
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "code",
            "current",
            "--snapshot",
            "/tmp/connection-code-latest.json",
            "--json",
        ])
        .is_ok()
    );
    assert!(Cli::try_parse_from(["skybridge", "doctor", "signaling", "--json"]).is_ok());
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "doctor",
            "media-lease",
            "--media-admission-token",
            "token",
            "--json",
        ])
        .is_ok()
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "doctor",
            "webrtc-media",
            "--session-id",
            "SESSION1",
            "--artifact-dir",
            "/tmp",
            "--since-seconds",
            "60",
            "--min-fps",
            "24",
            "--json",
        ])
        .is_ok()
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "doctor",
            "webrtc-media",
            "--latest",
            "--artifact-dir",
            "/tmp",
            "--require-audio",
            "false",
            "--json",
        ])
        .is_ok()
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "diagnose",
            "webrtc-media",
            "--latest",
            "--artifact-dir",
            "/tmp",
            "--json",
        ])
        .is_ok()
    );
}
