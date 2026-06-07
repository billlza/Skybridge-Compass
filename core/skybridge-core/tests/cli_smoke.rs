use std::process::Command;

fn skybridge() -> Command {
    Command::new(env!("CARGO_BIN_EXE_skybridge"))
}

#[test]
fn cli_help_smoke() {
    let output = skybridge().arg("--help").output().expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("skybridge command line"));
    assert!(stdout.contains("transport select"));
}

#[test]
fn cli_windows_same_lan_selects_msquic() {
    let output = skybridge()
        .args([
            "transport",
            "select",
            "--local",
            "windows",
            "--remote",
            "windows",
            "--path",
            "same-lan",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("kind=WindowsNativeMsQuic"));
    assert!(stdout.contains("audit=WindowsNativeMsQuicSameLan"));
    assert!(stdout.contains("priority=100"));
}

#[test]
fn cli_windows_to_apple_selects_webrtc_interop() {
    let output = skybridge()
        .args([
            "transport",
            "select",
            "--local",
            "windows",
            "--remote",
            "macos",
            "--path",
            "cross-nat",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("kind=WebRtcDataChannel"));
    assert!(stdout.contains("audit=WebRtcInterop"));
    assert!(stdout.contains("relay_allowed=true"));
}

#[test]
fn cli_suite_offer_lists_provider_derived_suites() {
    let output = skybridge()
        .args([
            "suite",
            "offer",
            "--caps",
            "xwing,x25519,p256",
            "--allow-classic",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("x-wing-hybrid=0x0001"));
    assert!(stdout.contains("x25519-ed25519=0x1001"));
    assert!(!stdout.contains("p256-ecdsa"));
}

#[test]
fn cli_suite_select_blocks_timeout_downgrade() {
    let output = skybridge()
        .args([
            "suite",
            "select",
            "--local-caps",
            "x25519",
            "--remote-suites",
            "0x1001",
            "--allow-classic",
            "--timeout-observed",
        ])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(2));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("TimeoutCannotDowngrade"));
}

#[test]
fn cli_channel_map_reports_transport_binding() {
    let output = skybridge()
        .args([
            "channel",
            "map",
            "--transport",
            "msquic",
            "--channel",
            "telemetry",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("channel=Telemetry"));
    assert!(stdout.contains("transport=WindowsNativeMsQuic"));
    assert!(stdout.contains("binding=skybridge.telemetry"));
    assert!(stdout.contains("reliability=reliable-unordered"));
    assert!(stdout.contains("head_of_line_isolated=true"));
}

#[test]
fn cli_frame_describe_reports_roundtrip_metadata() {
    let output = skybridge()
        .args([
            "frame",
            "describe",
            "--channel",
            "control",
            "--sequence",
            "8",
            "--payload",
            "hello",
            "--sbp2-fixed",
            "32",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("channel=Control"));
    assert!(stdout.contains("sequence=8"));
    assert!(stdout.contains("flags=0x0003"));
    assert!(stdout.contains("frame_len=60"));
    assert!(stdout.contains("payload_len=5"));
}

#[test]
fn cli_rejects_incomplete_transport_command() {
    let output = skybridge()
        .args(["transport", "select", "--local", "windows"])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(2));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("--remote"));
}
