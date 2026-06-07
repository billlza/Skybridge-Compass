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
fn cli_version_smoke() {
    let output = skybridge().arg("version").output().expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.starts_with("skybridge-core "));
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
fn cli_transport_bind_reports_binding_digest() {
    let output = skybridge()
        .args([
            "transport",
            "bind",
            "--transport",
            "webrtc",
            "--local-endpoint",
            "10.0.0.1:443",
            "--remote-endpoint",
            "10.0.0.2:443",
            "--candidate-pair",
            "host/udp",
            "--secret-fp",
            "secret-fingerprint",
            "--capability-digest",
            "capability-digest",
            "--timestamp-window-ms",
            "10000",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("transport=WebRtcDataChannel"));
    assert!(stdout.contains("relay_id=none"));
    let digest = stdout
        .lines()
        .find_map(|line| line.strip_prefix("binding_digest="))
        .expect("binding digest output");
    assert_eq!(digest.len(), 64);
    assert!(digest.chars().all(|value| value.is_ascii_hexdigit()));
    assert_eq!(digest, digest.to_ascii_lowercase());
}

#[test]
fn cli_transport_bind_accepts_relay_id() {
    let output = skybridge()
        .args([
            "transport",
            "bind",
            "--transport",
            "relay",
            "--local-endpoint",
            "relay-local",
            "--remote-endpoint",
            "relay-remote",
            "--candidate-pair",
            "relay/tcp",
            "--secret-fp",
            "secret-fingerprint",
            "--capability-digest",
            "capability-digest",
            "--timestamp-window-ms",
            "5000",
            "--relay-id",
            "relay-1",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("transport=Relay"));
    assert!(stdout.contains("relay_id=relay-1"));
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
fn cli_channel_profile_reports_default_reliability() {
    let output = skybridge()
        .args(["channel", "profile", "--channel", "clipboard"])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("channel=Clipboard"));
    assert!(stdout.contains("reliability=reliable-ordered"));
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
fn cli_connection_plan_reports_core_contract() {
    let output = skybridge()
        .args([
            "connection",
            "plan",
            "--local",
            "windows",
            "--remote",
            "macos",
            "--path",
            "cross-nat",
            "--local-caps",
            "xwing,mlkem,x25519",
            "--remote-suites",
            "0x1001,0x0101,0x0001",
            "--allow-classic",
            "--sbp2-fixed",
            "512",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("transport=WebRtcDataChannel"));
    assert!(stdout.contains("suite=x-wing-hybrid (0x0001)"));
    assert!(stdout.contains("channel_count=5"));
    assert!(stdout.contains("channel.realtime=WebRtcDataChannel:skybridge.realtime"));
    assert!(stdout.contains("sbp2_enabled=true"));
}

#[test]
fn cli_discovery_parse_accepts_mac_bonjour_txt() {
    let output = skybridge()
        .args([
            "discovery",
            "parse",
            "--service",
            "_skybridge._udp",
            "--txt",
            "deviceId=mac-1;pubKeyFP=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("service=_skybridge._udp"));
    assert!(stdout.contains("device_id=mac-1"));
    assert!(stdout.contains("platform=Apple"));
    assert!(stdout.contains("supports_apple_native=true"));
    assert!(stdout.contains("supports_webrtc_data_channel=true"));
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

#[test]
fn cli_rejects_unknown_command() {
    let output = skybridge().arg("bogus").output().expect("run cli");

    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(2));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("unknown command: bogus"));
}
