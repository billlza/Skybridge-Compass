use crate::channel::{map_channel, AdapterChannelBinding};
use crate::connection::{plan_connection, ConnectionPlan, ConnectionRequest, TrafficPaddingPlan};
use crate::discovery::{parse_service_kind, parse_txt_advertisement, DiscoveryServiceKind};
use crate::frame::{
    decode_frame, decode_frame_payload, encode_frame, encode_sbp2_frame, CoreFrame, FrameFlags,
};
use crate::suite::{
    negotiate_suite, offered_suites, CryptoProviderCapabilities, CryptoSuite, CryptoSuitePolicy,
};
use crate::transport::{
    NetworkPath, PeerCapabilities, PeerPlatform, SkyBridgeChannel, SkyBridgeReliability,
    SkyBridgeTransportKind, TransportBindingMaterial, TransportPlan, TransportSelector,
};
use crate::webrtc_proof::validate_webrtc_proof_json;
use std::fmt::Write as FmtWrite;
use std::fs;
use std::io::Write;

const HELP: &str = "\
skybridge command line

USAGE:
  skybridge version
  skybridge transport select --local <apple|windows> --remote <apple|windows> --path <same-lan|cross-nat>
  skybridge transport bind --transport <apple-native|msquic|webrtc|relay|tcp> --local-endpoint <text> --remote-endpoint <text> --candidate-pair <text> --secret-fp <text> --capability-digest <text> --timestamp-window-ms <n> [--relay-id <text>]
  skybridge suite offer --caps <xwing,mlkem,x25519,p256> [--allow-classic] [--allow-legacy-p256]
  skybridge suite select --local-caps <xwing,mlkem,x25519,p256> --remote-suites <0x0001,0x1001> [--allow-classic] [--allow-legacy-p256] [--timeout-observed]
  skybridge channel profile --channel <control|file|clipboard|telemetry|realtime>
  skybridge channel map --transport <apple-native|msquic|webrtc|relay|tcp> --channel <control|file|clipboard|telemetry|realtime>
  skybridge frame describe --channel <control|file|clipboard|telemetry|realtime> --sequence <n> --payload <text> [--sbp2-fixed <n>]
  skybridge connection plan --local <apple|windows> --remote <apple|windows> --path <same-lan|cross-nat> --local-caps <xwing,mlkem,x25519,p256> --remote-suites <0x0001,0x1001> [--allow-classic] [--allow-legacy-p256] [--timeout-observed] [--sbp2-fixed <n>]
  skybridge discovery parse --service <udp|tcp|_skybridge._udp|_skybridge._tcp> --txt <deviceId=...;pubKeyFP=...;platform=...;capabilities=...;name=...;version=...>
  skybridge webrtc-proof validate --proof <path> --expected-device-id <id> --expected-fingerprint <64-lowercase-hex> [--max-age-ms <n>]
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
        "frame" => execute_frame(&args[1..], out),
        "connection" => execute_connection(&args[1..], out),
        "discovery" => execute_discovery(&args[1..], out),
        "webrtc-proof" => execute_webrtc_proof(&args[1..], out),
        other => Err(format!("unknown command: {other}")),
    }
}

fn execute_transport(args: &[String], out: &mut impl Write) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("select") => execute_transport_select(args, out),
        Some("bind") => execute_transport_bind(args, out),
        _ => Err("expected transport select or transport bind".into()),
    }
}

fn execute_transport_select(args: &[String], out: &mut impl Write) -> Result<(), String> {
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

fn execute_transport_bind(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let material = TransportBindingMaterial {
        transport_kind: parse_transport_kind(required_option(args, "--transport")?)?,
        local_endpoint: required_option(args, "--local-endpoint")?.to_string(),
        remote_endpoint: required_option(args, "--remote-endpoint")?.to_string(),
        selected_candidate_pair: required_option(args, "--candidate-pair")?.to_string(),
        transport_secret_fingerprint: required_option(args, "--secret-fp")?.as_bytes().to_vec(),
        relay_id: optional_option(args, "--relay-id")
            .filter(|value| !value.is_empty())
            .map(str::to_string),
        timestamp_window_ms: parse_u64(
            required_option(args, "--timestamp-window-ms")?,
            "--timestamp-window-ms",
        )?,
        capability_digest: required_option(args, "--capability-digest")?
            .as_bytes()
            .to_vec(),
    };
    let digest = material.transcript_digest();

    writeln!(out, "transport={:?}", material.transport_kind).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "relay_id={}",
        material.relay_id.as_deref().unwrap_or("none")
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "timestamp_window_ms={}", material.timestamp_window_ms)
        .map_err(|err| err.to_string())?;
    writeln!(out, "binding_digest={}", format_hex(&digest)).map_err(|err| err.to_string())?;
    Ok(())
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
    match args.first().map(String::as_str) {
        Some("profile") => {
            let channel = parse_channel(required_option(args, "--channel")?)?;
            let reliability = channel.default_reliability();

            writeln!(out, "channel={channel:?}").map_err(|err| err.to_string())?;
            writeln!(out, "reliability={}", format_reliability(reliability))
                .map_err(|err| err.to_string())?;
            Ok(())
        }
        Some("map") => {
            let transport = parse_transport_kind(required_option(args, "--transport")?)?;
            let channel = parse_channel(required_option(args, "--channel")?)?;
            let profile = map_channel(transport, channel)
                .map_err(|err| format!("channel map failed: {err:?}"))?;

            writeln!(out, "channel={:?}", profile.channel).map_err(|err| err.to_string())?;
            writeln!(out, "transport={transport:?}").map_err(|err| err.to_string())?;
            writeln!(out, "binding={}", profile.binding.label()).map_err(|err| err.to_string())?;
            writeln!(
                out,
                "reliability={}",
                format_reliability(profile.reliability)
            )
            .map_err(|err| err.to_string())?;
            writeln!(
                out,
                "head_of_line_isolated={}",
                profile.binding.isolates_head_of_line_blocking()
            )
            .map_err(|err| err.to_string())?;
            Ok(())
        }
        _ => Err("expected channel profile or channel map".into()),
    }
}

fn execute_frame(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("describe") {
        return Err("expected frame describe".into());
    }

    let channel = parse_channel(required_option(args, "--channel")?)?;
    let sequence = parse_u64(required_option(args, "--sequence")?, "--sequence")?;
    let payload = required_option(args, "--payload")?.as_bytes().to_vec();
    let encoded = if let Some(padded) = optional_option(args, "--sbp2-fixed") {
        encode_sbp2_frame(
            channel,
            sequence,
            &payload,
            parse_usize(padded, "--sbp2-fixed")?,
        )
        .map_err(|err| format!("frame encode failed: {err:?}"))?
    } else {
        encode_frame(&CoreFrame {
            channel,
            sequence,
            flags: FrameFlags::END_OF_MESSAGE,
            payload,
        })
        .map_err(|err| format!("frame encode failed: {err:?}"))?
    };
    let decoded = decode_frame(&encoded).map_err(|err| format!("frame decode failed: {err:?}"))?;
    let decoded_payload =
        decode_frame_payload(&decoded).map_err(|err| format!("payload decode failed: {err:?}"))?;

    writeln!(out, "channel={:?}", decoded.channel).map_err(|err| err.to_string())?;
    writeln!(out, "sequence={}", decoded.sequence).map_err(|err| err.to_string())?;
    writeln!(out, "flags={:#06x}", decoded.flags.bits()).map_err(|err| err.to_string())?;
    writeln!(out, "frame_len={}", encoded.len()).map_err(|err| err.to_string())?;
    writeln!(out, "payload_len={}", decoded_payload.len()).map_err(|err| err.to_string())?;
    Ok(())
}

fn execute_connection(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("plan") {
        return Err("expected connection plan".into());
    }

    let traffic_padding = optional_option(args, "--sbp2-fixed")
        .map(|value| parse_usize(value, "--sbp2-fixed"))
        .transpose()?
        .map(TrafficPaddingPlan::sbp2_fixed)
        .unwrap_or_else(TrafficPaddingPlan::disabled);

    let request = ConnectionRequest {
        local: default_capabilities(parse_platform(required_option(args, "--local")?)?),
        remote: default_capabilities(parse_platform(required_option(args, "--remote")?)?),
        path: parse_path(required_option(args, "--path")?)?,
        local_crypto: parse_crypto_caps(required_option(args, "--local-caps")?)?,
        remote_suite_wire_ids: parse_suite_id_list(required_option(args, "--remote-suites")?)?,
        suite_policy: parse_suite_policy(args),
        traffic_padding,
    };

    let plan =
        plan_connection(request).map_err(|err| format!("connection plan failed: {err:?}"))?;
    print_connection_plan(&plan, out)
}

fn execute_discovery(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("parse") {
        return Err("expected discovery parse".into());
    }

    let service = parse_service_kind(required_option(args, "--service")?)
        .ok_or_else(|| "unsupported discovery service".to_string())?;
    let advertisement = parse_txt_advertisement(required_option(args, "--txt")?)
        .map_err(|err| format!("discovery TXT parse failed: {err:?}"))?;
    let capabilities = advertisement.peer_capabilities();

    writeln!(out, "service={}", format_service(service)).map_err(|err| err.to_string())?;
    writeln!(out, "device_id={}", advertisement.device_id).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "public_key_fingerprint={}",
        advertisement.public_key_fingerprint
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "platform={:?}", advertisement.platform).map_err(|err| err.to_string())?;
    writeln!(out, "platform_label={}", advertisement.platform_label)
        .map_err(|err| err.to_string())?;
    writeln!(out, "name={}", advertisement.name).map_err(|err| err.to_string())?;
    writeln!(out, "version={}", advertisement.protocol_version).map_err(|err| err.to_string())?;
    writeln!(out, "capabilities={}", advertisement.capabilities.join(","))
        .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "supports_apple_native={}",
        capabilities.supports_apple_native
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "supports_msquic={}", capabilities.supports_msquic)
        .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "supports_webrtc_data_channel={}",
        capabilities.supports_webrtc_data_channel
    )
    .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "supports_tcp_fallback={}",
        capabilities.supports_tcp_fallback
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "supports_relay={}", capabilities.supports_relay)
        .map_err(|err| err.to_string())?;
    Ok(())
}

fn execute_webrtc_proof(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("validate") {
        return Err("expected webrtc-proof validate".into());
    }

    let proof_path = required_option(args, "--proof")?;
    let expected_device_id = required_option(args, "--expected-device-id")?;
    let expected_fingerprint = required_option(args, "--expected-fingerprint")?;
    let max_age_ms = optional_option(args, "--max-age-ms")
        .map(|value| parse_u64(value, "--max-age-ms"))
        .transpose()?
        .unwrap_or(60_000);
    let json = fs::read_to_string(proof_path)
        .map_err(|err| format!("failed to read WebRTC proof: {err}"))?;
    let summary =
        validate_webrtc_proof_json(&json, expected_device_id, expected_fingerprint, max_age_ms)
            .map_err(|err| format!("webrtc proof validation failed: {err}"))?;

    writeln!(out, "webrtc_proof=valid").map_err(|err| err.to_string())?;
    writeln!(out, "peer_device_id={}", summary.peer_device_id).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "peer_public_key_fingerprint={}",
        summary.peer_public_key_fingerprint
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "helper_name={}", summary.helper_name).map_err(|err| err.to_string())?;
    writeln!(out, "adapter_binding={}", summary.adapter_binding).map_err(|err| err.to_string())?;
    writeln!(out, "local_endpoint={}", summary.local_endpoint).map_err(|err| err.to_string())?;
    writeln!(out, "remote_endpoint={}", summary.remote_endpoint).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "selected_candidate_pair={}",
        summary.selected_candidate_pair
    )
    .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "relay_id={}",
        summary.relay_id.as_deref().unwrap_or("none")
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "timestamp_window_ms={}", summary.timestamp_window_ms)
        .map_err(|err| err.to_string())?;
    writeln!(out, "proof_age_ms={}", summary.proof_age_ms).map_err(|err| err.to_string())?;
    Ok(())
}

fn has_flag(args: &[String], name: &str) -> bool {
    args.iter().any(|arg| arg == name)
}

fn optional_option<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|window| window[0] == name)
        .map(|window| window[1].as_str())
}

fn required_option<'a>(args: &'a [String], name: &str) -> Result<&'a str, String> {
    args.windows(2)
        .find(|window| window[0] == name)
        .map(|window| window[1].as_str())
        .ok_or_else(|| format!("missing required option: {name}"))
}

fn parse_u64(value: &str, name: &str) -> Result<u64, String> {
    value
        .parse::<u64>()
        .map_err(|_| format!("invalid {name}: {value}"))
}

fn parse_usize(value: &str, name: &str) -> Result<usize, String> {
    value
        .parse::<usize>()
        .map_err(|_| format!("invalid {name}: {value}"))
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

fn parse_transport_kind(value: &str) -> Result<SkyBridgeTransportKind, String> {
    match normalize(value).as_str() {
        "apple-native" | "apple" => Ok(SkyBridgeTransportKind::AppleNative),
        "msquic" | "windows-msquic" | "windows-native-msquic" => {
            Ok(SkyBridgeTransportKind::WindowsNativeMsQuic)
        }
        "skybridge-ice-msquic" | "ice-msquic" => Ok(SkyBridgeTransportKind::SkyBridgeIceMsQuic),
        "webrtc" | "webrtc-dc" | "webrtc-datachannel" => {
            Ok(SkyBridgeTransportKind::WebRtcDataChannel)
        }
        "relay" => Ok(SkyBridgeTransportKind::Relay),
        "tcp" | "tcp-fallback" => Ok(SkyBridgeTransportKind::TcpFallback),
        other => Err(format!("unsupported transport: {other}")),
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

fn print_connection_plan(plan: &ConnectionPlan, out: &mut impl Write) -> Result<(), String> {
    writeln!(out, "transport={:?}", plan.transport_kind).map_err(|err| err.to_string())?;
    writeln!(out, "transport_audit={:?}", plan.transport.audit_reason)
        .map_err(|err| err.to_string())?;
    writeln!(out, "transport_priority={}", plan.transport.priority)
        .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "suite={} ({:#06x})",
        plan.selected_suite.suite.name(),
        plan.selected_suite.suite.wire_id()
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "suite_audit={:?}", plan.selected_suite.audit).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "offered_suites={}",
        format_suite_list(&plan.offered_suites)
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "sbp2_enabled={}", plan.traffic_padding.sbp2_enabled)
        .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "sbp2_fixed_payload_len={}",
        plan.traffic_padding
            .fixed_payload_len
            .map(|len| len.to_string())
            .unwrap_or_else(|| "none".into())
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "frame_header_len={}", plan.frame_header_len).map_err(|err| err.to_string())?;
    writeln!(out, "channel_count={}", plan.channels.len()).map_err(|err| err.to_string())?;
    for profile in &plan.channels {
        writeln!(
            out,
            "channel.{}={}:{}:{}:head_of_line_isolated={}",
            format_channel_key(profile.channel),
            format_binding_kind(&profile.binding),
            profile.binding.label(),
            format_reliability(profile.reliability),
            profile.binding.isolates_head_of_line_blocking()
        )
        .map_err(|err| err.to_string())?;
    }
    Ok(())
}

fn format_suite_list(suites: &[CryptoSuite]) -> String {
    suites
        .iter()
        .map(|suite| format!("{}:{:#06x}", suite.name(), suite.wire_id()))
        .collect::<Vec<_>>()
        .join(",")
}

fn format_channel_key(channel: SkyBridgeChannel) -> &'static str {
    match channel {
        SkyBridgeChannel::Control => "control",
        SkyBridgeChannel::File => "file",
        SkyBridgeChannel::Clipboard => "clipboard",
        SkyBridgeChannel::Telemetry => "telemetry",
        SkyBridgeChannel::Realtime => "realtime",
    }
}

fn format_binding_kind(binding: &AdapterChannelBinding) -> &'static str {
    match binding {
        AdapterChannelBinding::AppleStream { .. } => "AppleStream",
        AdapterChannelBinding::AppleDatagram { .. } => "AppleDatagram",
        AdapterChannelBinding::MsQuicStream { .. } => "MsQuicStream",
        AdapterChannelBinding::MsQuicDatagram { .. } => "MsQuicDatagram",
        AdapterChannelBinding::WebRtcDataChannel { .. } => "WebRtcDataChannel",
        AdapterChannelBinding::RelayStream { .. } => "RelayStream",
        AdapterChannelBinding::TcpStream { .. } => "TcpStream",
    }
}

fn format_service(service: DiscoveryServiceKind) -> &'static str {
    service.service_type()
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

fn format_hex(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(&mut output, "{byte:02x}").expect("write to String");
    }
    output
}

fn normalize(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    const WEBRTC_PROOF_FINGERPRINT: &str =
        "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    fn run_cli(args: &[&str]) -> (i32, String, String) {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run(args.iter().copied(), &mut out, &mut err);
        (
            code,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    fn write_webrtc_proof_fixture(file_name: &str, sbf1_echo_verified: bool) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "skybridge-cli-webrtc-proof-{}-{file_name}.json",
            std::process::id()
        ));
        let captured_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis();
        let proof = format!(
            r#"{{
  "helperName": "schema-smoke-webrtc-helper",
  "peerDeviceId": "mac-1",
  "peerPublicKeyFingerprint": "{WEBRTC_PROOF_FINGERPRINT}",
  "dataChannelOpen": true,
  "sbf1EchoVerified": {sbf1_echo_verified},
  "sbf1FrameMagic": "SBF1",
  "adapterBinding": "verified webrtc datachannel helper",
  "localEndpoint": "windows.lan:5443",
  "remoteEndpoint": "mac.lan:5443",
  "selectedCandidatePair": "webrtc/dtls/sctp/helper-selected",
  "transportSecretFingerprintHex": "6666666666666666666666666666666666666666666666666666666666666666",
  "capabilityDigestHex": "7777777777777777777777777777777777777777777777777777777777777777",
  "relayId": "relay-helper",
  "timestampWindowMs": 15000,
  "capturedAtUnixMs": {captured_at}
}}"#
        );
        std::fs::write(&path, proof).unwrap();
        path
    }

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
    fn transport_bind_reports_core_transcript_digest() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
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
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
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
    fn channel_map_reports_adapter_binding() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "channel",
                "map",
                "--transport",
                "webrtc",
                "--channel",
                "file",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("channel=File"));
        assert!(stdout.contains("transport=WebRtcDataChannel"));
        assert!(stdout.contains("binding=skybridge.file"));
        assert!(stdout.contains("head_of_line_isolated=true"));
    }

    #[test]
    fn frame_describe_roundtrips_plain_payload() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "frame",
                "describe",
                "--channel",
                "control",
                "--sequence",
                "12",
                "--payload",
                "hello",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("channel=Control"));
        assert!(stdout.contains("sequence=12"));
        assert!(stdout.contains("flags=0x0002"));
        assert!(stdout.contains("payload_len=5"));
    }

    #[test]
    fn frame_describe_roundtrips_sbp2_payload() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "frame",
                "describe",
                "--channel",
                "control",
                "--sequence",
                "12",
                "--payload",
                "hello",
                "--sbp2-fixed",
                "32",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(stdout.contains("flags=0x0003"));
        assert!(stdout.contains("frame_len=60"));
        assert!(stdout.contains("payload_len=5"));
    }

    #[test]
    fn connection_plan_reports_transport_suite_channels_and_padding() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
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
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("transport=WebRtcDataChannel"));
        assert!(stdout.contains("transport_audit=WebRtcInterop"));
        assert!(stdout.contains("suite=x-wing-hybrid (0x0001)"));
        assert!(stdout.contains("suite_audit=HybridPqcPreferred"));
        assert!(stdout.contains("sbp2_enabled=true"));
        assert!(stdout.contains("sbp2_fixed_payload_len=512"));
        assert!(stdout.contains("frame_header_len=20"));
        assert!(stdout.contains(
            "channel.control=WebRtcDataChannel:skybridge.control:reliable-ordered:head_of_line_isolated=true"
        ));
    }

    #[test]
    fn discovery_parse_reports_mac_txt_capabilities() {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let txt = "deviceId=mac-1;pubKeyFP=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1";

        let code = run(
            [
                "discovery",
                "parse",
                "--service",
                "_skybridge._udp",
                "--txt",
                txt,
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("service=_skybridge._udp"));
        assert!(stdout.contains("device_id=mac-1"));
        assert!(stdout.contains("platform=Apple"));
        assert!(stdout.contains("supports_apple_native=true"));
        assert!(stdout.contains("supports_webrtc_data_channel=true"));
    }

    #[test]
    fn webrtc_proof_validate_reports_schema_summary() {
        let proof_path = write_webrtc_proof_fixture("valid", true);
        let proof_path_text = proof_path.to_string_lossy().to_string();

        let (code, stdout, stderr) = run_cli(&[
            "webrtc-proof",
            "validate",
            "--proof",
            &proof_path_text,
            "--expected-device-id",
            "mac-1",
            "--expected-fingerprint",
            WEBRTC_PROOF_FINGERPRINT,
        ]);

        let _ = std::fs::remove_file(proof_path);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("webrtc_proof=valid"));
        assert!(stdout.contains("peer_device_id=mac-1"));
        assert!(stdout.contains("helper_name=schema-smoke-webrtc-helper"));
        assert!(stdout.contains("adapter_binding=verified webrtc datachannel helper"));
        assert!(stdout.contains("selected_candidate_pair=webrtc/dtls/sctp/helper-selected"));
        assert!(stdout.contains("relay_id=relay-helper"));
        assert!(stdout.contains("timestamp_window_ms=15000"));
    }

    #[test]
    fn webrtc_proof_validate_rejects_missing_sbf1_echo() {
        let proof_path = write_webrtc_proof_fixture("missing-sbf1", false);
        let proof_path_text = proof_path.to_string_lossy().to_string();

        let (code, stdout, stderr) = run_cli(&[
            "webrtc-proof",
            "validate",
            "--proof",
            &proof_path_text,
            "--expected-device-id",
            "mac-1",
            "--expected-fingerprint",
            WEBRTC_PROOF_FINGERPRINT,
        ]);

        let _ = std::fs::remove_file(proof_path);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(stderr.contains("webrtc proof validation failed"));
        assert!(stderr.contains("SBF1 echo frame"));
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

    #[test]
    fn help_and_subcommand_errors_fail_closed() {
        let (code, stdout, stderr) = run_cli(&[]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("skybridge command line"));

        let (code, stdout, stderr) = run_cli(&["-h"]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("discovery parse"));

        for (args, expected) in [
            (&["bogus"][..], "unknown command: bogus"),
            (
                &["transport"][..],
                "expected transport select or transport bind",
            ),
            (&["suite"][..], "expected suite offer or suite select"),
            (&["channel"][..], "expected channel profile or channel map"),
            (&["frame"][..], "expected frame describe"),
            (&["connection"][..], "expected connection plan"),
            (&["discovery"][..], "expected discovery parse"),
            (&["webrtc-proof"][..], "expected webrtc-proof validate"),
        ] {
            let (code, stdout, stderr) = run_cli(args);
            assert_eq!(code, 2);
            assert!(stdout.is_empty());
            assert!(stderr.contains(expected));
        }
    }

    #[test]
    fn parsers_reject_invalid_scalar_options() {
        for (args, expected) in [
            (
                &[
                    "transport",
                    "select",
                    "--local",
                    "linux",
                    "--remote",
                    "apple",
                    "--path",
                    "same-lan",
                ][..],
                "unsupported platform: linux",
            ),
            (
                &[
                    "transport",
                    "select",
                    "--local",
                    "windows",
                    "--remote",
                    "apple",
                    "--path",
                    "moon",
                ][..],
                "unsupported path: moon",
            ),
            (
                &["channel", "profile", "--channel", "chat"][..],
                "unsupported channel: chat",
            ),
            (
                &[
                    "channel",
                    "map",
                    "--transport",
                    "carrier",
                    "--channel",
                    "control",
                ][..],
                "unsupported transport: carrier",
            ),
            (
                &["suite", "offer", "--caps", "banana"][..],
                "unsupported crypto capability: banana",
            ),
            (
                &[
                    "suite",
                    "select",
                    "--local-caps",
                    "x25519",
                    "--remote-suites",
                    "0xzz",
                ][..],
                "invalid suite id: 0xzz",
            ),
            (
                &[
                    "transport",
                    "bind",
                    "--transport",
                    "webrtc",
                    "--local-endpoint",
                    "a",
                    "--remote-endpoint",
                    "b",
                    "--candidate-pair",
                    "c",
                    "--secret-fp",
                    "d",
                    "--capability-digest",
                    "e",
                    "--timestamp-window-ms",
                    "soon",
                ][..],
                "invalid --timestamp-window-ms: soon",
            ),
            (
                &[
                    "frame",
                    "describe",
                    "--channel",
                    "control",
                    "--sequence",
                    "nan",
                    "--payload",
                    "hello",
                ][..],
                "invalid --sequence: nan",
            ),
            (
                &[
                    "connection",
                    "plan",
                    "--local",
                    "windows",
                    "--remote",
                    "macos",
                    "--path",
                    "cross-nat",
                    "--local-caps",
                    "xwing",
                    "--remote-suites",
                    "0x0001",
                    "--sbp2-fixed",
                    "tiny",
                ][..],
                "invalid --sbp2-fixed: tiny",
            ),
        ] {
            let (code, stdout, stderr) = run_cli(args);
            assert_eq!(code, 2);
            assert!(stdout.is_empty());
            assert!(stderr.contains(expected), "{stderr}");
        }
    }

    #[test]
    fn transport_aliases_and_binding_formatters_are_covered() {
        let (code, stdout, stderr) = run_cli(&[
            "transport",
            "bind",
            "--transport",
            "relay",
            "--local-endpoint",
            "local",
            "--remote-endpoint",
            "remote",
            "--candidate-pair",
            "relay/tcp",
            "--secret-fp",
            "secret",
            "--capability-digest",
            "caps",
            "--timestamp-window-ms",
            "2500",
            "--relay-id",
            "relay-1",
        ]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("transport=Relay"));
        assert!(stdout.contains("relay_id=relay-1"));

        let (code, stdout, stderr) = run_cli(&[
            "transport",
            "bind",
            "--transport",
            "tcp",
            "--local-endpoint",
            "local",
            "--remote-endpoint",
            "remote",
            "--candidate-pair",
            "tcp",
            "--secret-fp",
            "secret",
            "--capability-digest",
            "caps",
            "--timestamp-window-ms",
            "2500",
        ]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("transport=TcpFallback"));
        assert!(stdout.contains("relay_id=none"));

        let apple_stream = map_channel(
            SkyBridgeTransportKind::AppleNative,
            SkyBridgeChannel::Control,
        )
        .unwrap();
        let apple_datagram = map_channel(
            SkyBridgeTransportKind::AppleNative,
            SkyBridgeChannel::Telemetry,
        )
        .unwrap();
        let msquic_stream = map_channel(
            SkyBridgeTransportKind::WindowsNativeMsQuic,
            SkyBridgeChannel::File,
        )
        .unwrap();
        let msquic_datagram = map_channel(
            SkyBridgeTransportKind::WindowsNativeMsQuic,
            SkyBridgeChannel::Realtime,
        )
        .unwrap();
        let relay_stream =
            map_channel(SkyBridgeTransportKind::Relay, SkyBridgeChannel::Clipboard).unwrap();
        let tcp_stream = map_channel(
            SkyBridgeTransportKind::TcpFallback,
            SkyBridgeChannel::Control,
        )
        .unwrap();

        assert_eq!(format_binding_kind(&apple_stream.binding), "AppleStream");
        assert_eq!(
            format_binding_kind(&apple_datagram.binding),
            "AppleDatagram"
        );
        assert_eq!(format_binding_kind(&msquic_stream.binding), "MsQuicStream");
        assert_eq!(
            format_binding_kind(&msquic_datagram.binding),
            "MsQuicDatagram"
        );
        assert_eq!(format_binding_kind(&relay_stream.binding), "RelayStream");
        assert_eq!(format_binding_kind(&tcp_stream.binding), "TcpStream");
        assert_eq!(
            format_reliability(SkyBridgeReliability::Unreliable),
            "unreliable"
        );
    }

    #[test]
    fn suite_empty_offer_and_decimal_ids_are_reported() {
        let (code, stdout, stderr) = run_cli(&["suite", "offer", "--caps", ""]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert_eq!(stdout, "suites=\n");

        let (code, stdout, stderr) = run_cli(&[
            "suite",
            "select",
            "--local-caps",
            "x25519",
            "--remote-suites",
            "4097",
            "--allow-classic",
        ]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("suite=x25519-ed25519 (0x1001)"));
    }

    #[test]
    fn unknown_default_capabilities_are_disabled() {
        let caps = default_capabilities(PeerPlatform::Unknown);

        assert_eq!(caps.platform, PeerPlatform::Unknown);
        assert!(!caps.supports_apple_native);
        assert!(!caps.supports_msquic);
        assert!(!caps.supports_skybridge_ice_msquic);
        assert!(!caps.supports_webrtc_data_channel);
        assert!(!caps.supports_tcp_fallback);
        assert!(!caps.supports_relay);
    }
}
