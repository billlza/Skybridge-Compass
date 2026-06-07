use crate::suite::{
    negotiate_suite, offered_suites, CryptoProviderCapabilities, CryptoSuite, CryptoSuitePolicy,
};
use crate::transport::{
    NetworkPath, PeerCapabilities, PeerPlatform, SkyBridgeChannel, SkyBridgeReliability,
    TransportPlan, TransportSelector,
};
use std::io::Write;

const HELP: &str = "\
skybridge command line

USAGE:
  skybridge version
  skybridge transport select --local <apple|windows> --remote <apple|windows> --path <same-lan|cross-nat>
  skybridge suite offer --caps <xwing,mlkem,x25519,p256> [--allow-classic] [--allow-legacy-p256]
  skybridge suite select --local-caps <xwing,mlkem,x25519,p256> --remote-suites <0x0001,0x1001> [--allow-classic] [--allow-legacy-p256] [--timeout-observed]
  skybridge channel profile --channel <control|file|clipboard|telemetry|realtime>
";

pub fn run<I, S>(args: I, out: &mut impl Write, err: &mut impl Write) -> i32
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    match execute(args.into_iter().map(Into::into).collect(), out) {
        Ok(()) => 0,
        Err(message) => {
            let _ = writeln!(err, "{message}");
            2
        }
    }
}

fn execute(args: Vec<String>, out: &mut impl Write) -> Result<(), String> {
    if args.is_empty() || args == ["--help"] || args == ["-h"] {
        write!(out, "{HELP}").map_err(|err| err.to_string())?;
        return Ok(());
    }

    match args[0].as_str() {
        "version" => {
            writeln!(out, "skybridge-core {}", env!("CARGO_PKG_VERSION"))
                .map_err(|err| err.to_string())?;
            Ok(())
        }
        "transport" => execute_transport(&args[1..], out),
        "suite" => execute_suite(&args[1..], out),
        "channel" => execute_channel(&args[1..], out),
        other => Err(format!("unknown command: {other}")),
    }
}

fn execute_transport(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("select") {
        return Err("expected transport select".into());
    }

    let local = required_option(args, "--local")?;
    let remote = required_option(args, "--remote")?;
    let path = required_option(args, "--path")?;
    let plan = TransportSelector::select(
        default_capabilities(parse_platform(local)?),
        default_capabilities(parse_platform(remote)?),
        parse_path(path)?,
    );

    print_transport_plan(plan, out)
}

fn execute_suite(args: &[String], out: &mut impl Write) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("offer") => {
            let caps = parse_crypto_caps(required_option(args, "--caps")?)?;
            let suites = offered_suites(caps, parse_suite_policy(args));
            print_suites(&suites, out)
        }
        Some("select") => {
            let local = parse_crypto_caps(required_option(args, "--local-caps")?)?;
            let remote = parse_suite_id_list(required_option(args, "--remote-suites")?)?;
            let selected = negotiate_suite(local, &remote, parse_suite_policy(args))
                .map_err(|err| format!("suite negotiation failed: {err:?}"))?;
            writeln!(
                out,
                "suite={} ({:#06x})",
                selected.suite.name(),
                selected.suite.wire_id()
            )
            .map_err(|err| err.to_string())?;
            writeln!(out, "audit={:?}", selected.audit).map_err(|err| err.to_string())?;
            Ok(())
        }
        _ => Err("expected suite offer or suite select".into()),
    }
}

fn execute_channel(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("profile") {
        return Err("expected channel profile".into());
    }

    let channel = parse_channel(required_option(args, "--channel")?)?;
    let reliability = channel.default_reliability();

    writeln!(out, "channel={channel:?}").map_err(|err| err.to_string())?;
    writeln!(out, "reliability={}", format_reliability(reliability))
        .map_err(|err| err.to_string())?;
    Ok(())
}

fn has_flag(args: &[String], name: &str) -> bool {
    args.iter().any(|arg| arg == name)
}

fn required_option<'a>(args: &'a [String], name: &str) -> Result<&'a str, String> {
    args.windows(2)
        .find(|window| window[0] == name)
        .map(|window| window[1].as_str())
        .ok_or_else(|| format!("missing required option: {name}"))
}

fn parse_platform(value: &str) -> Result<PeerPlatform, String> {
    match normalize(value).as_str() {
        "apple" | "mac" | "macos" | "ios" => Ok(PeerPlatform::Apple),
        "windows" | "win" => Ok(PeerPlatform::Windows),
        other => Err(format!("unsupported platform: {other}")),
    }
}

fn default_capabilities(platform: PeerPlatform) -> PeerCapabilities {
    match platform {
        PeerPlatform::Apple => PeerCapabilities::apple(),
        PeerPlatform::Windows => PeerCapabilities::windows(),
        PeerPlatform::Unknown => PeerCapabilities {
            platform,
            supports_apple_native: false,
            supports_msquic: false,
            supports_skybridge_ice_msquic: false,
            supports_webrtc_data_channel: false,
            supports_tcp_fallback: false,
            supports_relay: false,
        },
    }
}

fn parse_path(value: &str) -> Result<NetworkPath, String> {
    match normalize(value).as_str() {
        "same-lan" | "lan" | "local" => Ok(NetworkPath::same_lan()),
        "cross-nat" | "nat" | "remote" => Ok(NetworkPath::cross_nat()),
        other => Err(format!("unsupported path: {other}")),
    }
}

fn parse_channel(value: &str) -> Result<SkyBridgeChannel, String> {
    match normalize(value).as_str() {
        "control" => Ok(SkyBridgeChannel::Control),
        "file" => Ok(SkyBridgeChannel::File),
        "clipboard" => Ok(SkyBridgeChannel::Clipboard),
        "telemetry" => Ok(SkyBridgeChannel::Telemetry),
        "realtime" | "real-time" => Ok(SkyBridgeChannel::Realtime),
        other => Err(format!("unsupported channel: {other}")),
    }
}

fn parse_crypto_caps(value: &str) -> Result<CryptoProviderCapabilities, String> {
    let mut caps = CryptoProviderCapabilities::empty();
    for raw in value.split(',') {
        match normalize(raw).as_str() {
            "" => {}
            "all" | "research-all" => caps = CryptoProviderCapabilities::research_all(),
            "current-p256" => caps = CryptoProviderCapabilities::current_p256(),
            "xwing" | "x-wing" | "x-wing-hybrid" => caps.supports_xwing_hybrid = true,
            "mlkem" | "ml-kem" | "ml-kem-768" | "ml-kem-768-ml-dsa-65" => {
                caps.supports_mlkem_768_mldsa_65 = true;
            }
            "x25519" | "x25519-ed25519" => caps.supports_x25519_ed25519 = true,
            "p256" | "p-256" | "p256-ecdsa" => caps.supports_p256_ecdsa = true,
            other => return Err(format!("unsupported crypto capability: {other}")),
        }
    }
    Ok(caps)
}

fn parse_suite_policy(args: &[String]) -> CryptoSuitePolicy {
    CryptoSuitePolicy {
        allow_classic_fallback: has_flag(args, "--allow-classic"),
        allow_legacy_p256: has_flag(args, "--allow-legacy-p256"),
        timeout_observed: has_flag(args, "--timeout-observed"),
    }
}

fn parse_suite_id_list(value: &str) -> Result<Vec<u16>, String> {
    value
        .split(',')
        .filter(|part| !part.trim().is_empty())
        .map(parse_suite_id)
        .collect()
}

fn parse_suite_id(value: &str) -> Result<u16, String> {
    let value = value.trim();
    if let Some(hex) = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
    {
        return u16::from_str_radix(hex, 16).map_err(|_| format!("invalid suite id: {value}"));
    }

    value
        .parse::<u16>()
        .map_err(|_| format!("invalid suite id: {value}"))
}

fn print_transport_plan(plan: TransportPlan, out: &mut impl Write) -> Result<(), String> {
    writeln!(
        out,
        "kind={}",
        plan.kind
            .map(|kind| format!("{kind:?}"))
            .unwrap_or_else(|| "Unsupported".into())
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "audit={:?}", plan.audit_reason).map_err(|err| err.to_string())?;
    writeln!(out, "priority={}", plan.priority).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "relay_allowed={}",
        matches!(
            plan.relay_policy,
            crate::transport::RelayPolicy::Allowed | crate::transport::RelayPolicy::Required
        )
    )
    .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "relay_required={}",
        matches!(plan.relay_policy, crate::transport::RelayPolicy::Required)
    )
    .map_err(|err| err.to_string())?;
    Ok(())
}

fn print_suites(suites: &[CryptoSuite], out: &mut impl Write) -> Result<(), String> {
    if suites.is_empty() {
        writeln!(out, "suites=").map_err(|err| err.to_string())?;
        return Ok(());
    }

    for suite in suites {
        writeln!(out, "{}={:#06x}", suite.name(), suite.wire_id())
            .map_err(|err| err.to_string())?;
    }
    Ok(())
}

fn format_reliability(reliability: SkyBridgeReliability) -> String {
    match reliability {
        SkyBridgeReliability::ReliableOrdered => "reliable-ordered".into(),
        SkyBridgeReliability::ReliableUnordered => "reliable-unordered".into(),
        SkyBridgeReliability::PartialReliable { max_retransmits } => {
            format!("partial-reliable:{max_retransmits}")
        }
        SkyBridgeReliability::Unreliable => "unreliable".into(),
    }
}

fn normalize(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_command_reports_package_version() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(["version"], &mut out, &mut err);

        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert_eq!(
            String::from_utf8(out).unwrap(),
            format!("skybridge-core {}\n", env!("CARGO_PKG_VERSION"))
        );
    }

    #[test]
    fn transport_select_uses_core_policy() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "transport",
                "select",
                "--local",
                "windows",
                "--remote",
                "apple",
                "--path",
                "cross-nat",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("kind=WebRtcDataChannel"));
        assert!(stdout.contains("audit=WebRtcInterop"));
        assert!(stdout.contains("relay_allowed=true"));
    }

    #[test]
    fn channel_profile_reports_reliability() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            ["channel", "profile", "--channel", "realtime"],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(stdout.contains("channel=Realtime"));
        assert!(stdout.contains("reliability=partial-reliable:1"));
    }

    #[test]
    fn suite_offer_is_derived_from_caps_and_policy() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "suite",
                "offer",
                "--caps",
                "xwing,x25519,p256",
                "--allow-classic",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("x-wing-hybrid=0x0001"));
        assert!(stdout.contains("x25519-ed25519=0x1001"));
        assert!(!stdout.contains("p256-ecdsa"));
    }

    #[test]
    fn suite_select_reports_audit_reason() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "suite",
                "select",
                "--local-caps",
                "mlkem,x25519",
                "--remote-suites",
                "0x1001,0x0101",
                "--allow-classic",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(stdout.contains("suite=ml-kem-768-ml-dsa-65 (0x0101)"));
        assert!(stdout.contains("audit=PurePqcPreferred"));
    }

    #[test]
    fn suite_select_rejects_timeout_downgrade() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "suite",
                "select",
                "--local-caps",
                "x25519",
                "--remote-suites",
                "0x1001",
                "--allow-classic",
                "--timeout-observed",
            ],
            &mut out,
            &mut err,
        );

        assert_eq!(code, 2);
        assert!(out.is_empty());
        assert!(String::from_utf8(err)
            .unwrap()
            .contains("TimeoutCannotDowngrade"));
    }

    #[test]
    fn invalid_command_returns_usage_error() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            ["transport", "select", "--local", "windows"],
            &mut out,
            &mut err,
        );

        assert_eq!(code, 2);
        assert!(out.is_empty());
        assert!(String::from_utf8(err).unwrap().contains("--remote"));
    }
}
