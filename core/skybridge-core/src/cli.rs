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
