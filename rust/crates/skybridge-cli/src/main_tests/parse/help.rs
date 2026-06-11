use clap::Parser;
use clap::error::ErrorKind;

use crate::Cli;

#[test]
fn help_surfaces_operator_capabilities() {
    let top_level = help_text(["skybridge", "--help"]);
    for expected in ["device", "file", "session", "check", "doctor", "smoke"] {
        assert!(
            top_level.contains(expected),
            "top-level help should mention {expected}"
        );
    }

    let device = help_text(["skybridge", "device", "--help"]);
    assert!(device.contains("discover"));

    let device_discover = help_text(["skybridge", "device", "discover", "--help"]);
    for expected in [
        "--timeout-seconds",
        "--service-type",
        "--require-capability",
        "--json",
    ] {
        assert!(
            device_discover.contains(expected),
            "device discover help should mention {expected}"
        );
    }

    let file = help_text(["skybridge", "file", "--help"]);
    assert!(file.contains("prove"));
    assert!(file.contains("send"));
    assert!(file.contains("receive"));

    let remote_desktop = help_text(["skybridge", "session", "remote-desktop", "--help"]);
    assert!(remote_desktop.contains("prove"));

    let remote_desktop_prove =
        help_text(["skybridge", "session", "remote-desktop", "prove", "--help"]);
    for expected in [
        "--artifact-dir",
        "--min-fps",
        "--exact-video-size",
        "--min-pass-window-seconds",
        "--json",
    ] {
        assert!(
            remote_desktop_prove.contains(expected),
            "remote-desktop prove help should mention {expected}"
        );
    }
}

fn help_text<const N: usize>(args: [&str; N]) -> String {
    let error = Cli::try_parse_from(args).expect_err("help should exit through clap display error");
    assert_eq!(error.kind(), ErrorKind::DisplayHelp);
    error.to_string()
}
