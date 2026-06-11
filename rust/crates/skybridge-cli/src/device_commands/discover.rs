use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use mdns_sd::{ServiceDaemon, ServiceEvent};
use serde::Serialize;

use crate::DeviceCapabilityArg;

const DEFAULT_SERVICE_TYPES: [&str; 3] = [
    "_skybridge._tcp.local.",
    "_skybridge-transfer._tcp.local.",
    "_skybridge-remote._tcp.local.",
];
const MAX_DISCOVERY_TIMEOUT_SECONDS: u64 = 30;
const MAX_SERVICE_TYPES: usize = 8;
const MAX_FIELD_CHARS: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DiscoveredDevice {
    pub(crate) instance: String,
    pub(crate) service_type: String,
    pub(crate) capability: String,
    pub(crate) hostname: String,
    pub(crate) port: u16,
    pub(crate) addresses: Vec<String>,
    pub(crate) txt: BTreeMap<String, String>,
}

#[derive(Debug, Clone)]
struct DiscoveryRequest {
    service_types: Vec<String>,
    required_capabilities: Vec<DeviceCapabilityArg>,
    timeout_seconds: u64,
}

pub(crate) async fn device_discover(args: crate::DeviceDiscoverArgs) -> Result<()> {
    let request = build_discovery_request(&args)?;
    let timeout = Duration::from_secs(request.timeout_seconds);

    let types_for_browse = request.service_types.clone();
    let devices = tokio::task::spawn_blocking(move || browse(&types_for_browse, timeout))
        .await
        .context("mDNS browse task panicked")??;
    ensure_required_capabilities(&devices, &request.required_capabilities)?;

    if args.output.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "service_types": request.service_types,
                "required_capabilities": request.required_capabilities
                    .iter()
                    .map(|capability| capability_label(*capability))
                    .collect::<Vec<_>>(),
                "timeout_seconds": request.timeout_seconds,
                "devices": devices,
            }))?
        );
    } else {
        print!(
            "{}",
            render_human(
                &devices,
                &request.service_types,
                &request.required_capabilities,
                request.timeout_seconds,
            )
        );
    }
    Ok(())
}

fn build_discovery_request(args: &crate::DeviceDiscoverArgs) -> Result<DiscoveryRequest> {
    if args.timeout_seconds == 0 || args.timeout_seconds > MAX_DISCOVERY_TIMEOUT_SECONDS {
        bail!(
            "--timeout-seconds must be between 1 and {MAX_DISCOVERY_TIMEOUT_SECONDS}; got {}",
            args.timeout_seconds
        );
    }
    Ok(DiscoveryRequest {
        service_types: normalized_service_types(&args.service_types)?,
        required_capabilities: args.required_capabilities.clone(),
        timeout_seconds: args.timeout_seconds,
    })
}

fn normalized_service_types(requested: &[String]) -> Result<Vec<String>> {
    if requested.is_empty() {
        return Ok(DEFAULT_SERVICE_TYPES
            .iter()
            .map(|s| (*s).to_owned())
            .collect());
    }
    if requested.len() > MAX_SERVICE_TYPES {
        bail!(
            "at most {MAX_SERVICE_TYPES} --service-type values are supported; got {}",
            requested.len()
        );
    }
    requested
        .iter()
        .map(|ty| normalize_service_type(ty))
        .collect()
}

fn normalize_service_type(ty: &str) -> Result<String> {
    let trimmed = ty.trim();
    if trimmed.is_empty() {
        bail!("--service-type must not be empty");
    }
    if trimmed.chars().any(|ch| ch.is_control()) {
        bail!("--service-type must not contain control characters");
    }
    let normalized = if trimmed.ends_with(".local.") {
        trimmed.to_owned()
    } else if trimmed.ends_with(".local") {
        format!("{trimmed}.")
    } else {
        format!("{}.local.", trimmed.trim_end_matches('.'))
    };
    validate_service_type(&normalized)?;
    Ok(normalized)
}

fn validate_service_type(service_type: &str) -> Result<()> {
    let labels = service_type
        .trim_end_matches('.')
        .split('.')
        .collect::<Vec<_>>();
    if labels.len() != 3 || labels[2] != "local" {
        bail!(
            "invalid DNS-SD service type `{service_type}`; expected _name._tcp[.local.] or _name._udp[.local.]"
        );
    }
    let service = labels[0];
    let protocol = labels[1];
    if !service.starts_with('_') || service.len() < 2 || service.len() > 64 {
        bail!("invalid DNS-SD service label `{service}` in `{service_type}`");
    }
    if !matches!(protocol, "_tcp" | "_udp") {
        bail!("invalid DNS-SD protocol label `{protocol}` in `{service_type}`");
    }
    if !service[1..]
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '-')
    {
        bail!("invalid DNS-SD service label `{service}` in `{service_type}`");
    }
    Ok(())
}

fn browse(service_types: &[String], timeout: Duration) -> Result<Vec<DiscoveredDevice>> {
    let daemon = ServiceDaemon::new().context("failed to start mDNS daemon")?;
    let mut receivers = Vec::with_capacity(service_types.len());
    for service_type in service_types {
        let receiver = daemon
            .browse(service_type)
            .with_context(|| format!("failed to browse {service_type}"))?;
        receivers.push((service_type.clone(), receiver));
    }

    let deadline = Instant::now() + timeout;
    let mut devices: Vec<DiscoveredDevice> = Vec::new();
    loop {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        let mut received_any = false;
        for (service_type, receiver) in &receivers {
            // 轮询各服务类型的事件通道；短超时避免单通道独占等待窗口。
            while let Ok(event) = receiver.recv_timeout(Duration::from_millis(50)) {
                received_any = true;
                if let ServiceEvent::ServiceResolved(info) = event {
                    upsert(&mut devices, resolved_to_device(service_type, &info));
                }
            }
        }
        if !received_any {
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    for (service_type, _) in &receivers {
        daemon
            .stop_browse(service_type)
            .with_context(|| format!("failed to stop browsing {service_type}"))?;
    }
    daemon
        .shutdown()
        .context("failed to shut down mDNS daemon")?;

    devices.sort_by(|a, b| (&a.service_type, &a.instance).cmp(&(&b.service_type, &b.instance)));
    Ok(devices)
}

fn resolved_to_device(service_type: &str, info: &mdns_sd::ResolvedService) -> DiscoveredDevice {
    let mut addresses: Vec<String> = info
        .addresses
        .iter()
        .map(|ip| sanitize_discovery_field(&ip.to_string()))
        .collect();
    addresses.sort();
    let mut txt = BTreeMap::new();
    for property in info.txt_properties.iter() {
        txt.insert(
            sanitize_discovery_field(property.key()),
            sanitize_discovery_field(property.val_str()),
        );
    }
    DiscoveredDevice {
        instance: sanitize_discovery_field(&instance_name(&info.fullname, service_type)),
        service_type: service_type.to_owned(),
        capability: capability_label(service_type_capability(service_type)).to_owned(),
        hostname: sanitize_discovery_field(&info.host),
        port: info.port,
        addresses,
        txt,
    }
}

/// 从 fullname（`<instance>.<service-type>`）中截取实例名。
fn instance_name(fullname: &str, service_type: &str) -> String {
    fullname
        .strip_suffix(service_type)
        .map(|prefix| prefix.trim_end_matches('.').to_owned())
        .unwrap_or_else(|| fullname.to_owned())
}

fn upsert(devices: &mut Vec<DiscoveredDevice>, device: DiscoveredDevice) {
    if let Some(existing) = devices
        .iter_mut()
        .find(|d| d.service_type == device.service_type && d.instance == device.instance)
    {
        *existing = device;
    } else {
        devices.push(device);
    }
}

fn service_type_capability(service_type: &str) -> DeviceCapabilityArg {
    match service_type.trim_end_matches(".local.") {
        "_skybridge-transfer._tcp" => DeviceCapabilityArg::FileTransfer,
        "_skybridge-remote._tcp" => DeviceCapabilityArg::RemoteDesktop,
        _ => DeviceCapabilityArg::Control,
    }
}

fn capability_label(capability: DeviceCapabilityArg) -> &'static str {
    match capability {
        DeviceCapabilityArg::Control => "control",
        DeviceCapabilityArg::FileTransfer => "file-transfer",
        DeviceCapabilityArg::RemoteDesktop => "remote-desktop",
    }
}

fn ensure_required_capabilities(
    devices: &[DiscoveredDevice],
    required_capabilities: &[DeviceCapabilityArg],
) -> Result<()> {
    for required in required_capabilities {
        let expected = capability_label(*required);
        if devices.iter().all(|device| device.capability != expected) {
            bail!("required capability `{expected}` was not discovered");
        }
    }
    Ok(())
}

fn render_human(
    devices: &[DiscoveredDevice],
    service_types: &[String],
    required_capabilities: &[DeviceCapabilityArg],
    timeout_seconds: u64,
) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "Browsed {} for {timeout_seconds}s\n",
        service_types.join(", ")
    ));
    if !required_capabilities.is_empty() {
        let required = required_capabilities
            .iter()
            .map(|capability| capability_label(*capability))
            .collect::<Vec<_>>()
            .join(", ");
        out.push_str(&format!("Required capabilities: {required}\n"));
    }
    if devices.is_empty() {
        out.push_str("No SkyBridge devices discovered.\n");
        return out;
    }
    out.push_str(&format!("Discovered {} service(s):\n", devices.len()));
    for device in devices {
        out.push_str(&format!(
            "- {} [{} {}] {}:{} addrs=[{}]\n",
            device.instance,
            device.service_type.trim_end_matches(".local."),
            device.capability,
            device.hostname.trim_end_matches('.'),
            device.port,
            device.addresses.join(", ")
        ));
        for (key, value) in &device.txt {
            out.push_str(&format!("    txt {key}={value}\n"));
        }
    }
    out
}

fn sanitize_discovery_field(value: &str) -> String {
    let sanitized = value
        .chars()
        .flat_map(|ch| match ch {
            '\n' => "\\n".chars().collect::<Vec<_>>(),
            '\r' => "\\r".chars().collect::<Vec<_>>(),
            '\t' => "\\t".chars().collect::<Vec<_>>(),
            ch if ch.is_control() => "\\u{FFFD}".chars().collect::<Vec<_>>(),
            ch => vec![ch],
        })
        .collect::<String>();
    let mut chars = sanitized.chars();
    let truncated = chars.by_ref().take(MAX_FIELD_CHARS).collect::<String>();
    if chars.next().is_some() {
        format!("{truncated}...[truncated]")
    } else {
        truncated
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(instance: &str, service_type: &str, port: u16) -> DiscoveredDevice {
        DiscoveredDevice {
            instance: instance.to_owned(),
            service_type: service_type.to_owned(),
            capability: capability_label(service_type_capability(service_type)).to_owned(),
            hostname: format!("{instance}.local."),
            port,
            addresses: vec!["192.168.1.20".to_owned()],
            txt: BTreeMap::from([("platform".to_owned(), "macOS".to_owned())]),
        }
    }

    #[test]
    fn default_service_types_cover_control_and_file_transfer() {
        let types = normalized_service_types(&[]).expect("default types should normalize");
        assert_eq!(
            types,
            vec![
                "_skybridge._tcp.local.".to_owned(),
                "_skybridge-transfer._tcp.local.".to_owned(),
                "_skybridge-remote._tcp.local.".to_owned(),
            ]
        );
    }

    #[test]
    fn normalize_service_type_appends_local_suffix() {
        assert_eq!(
            normalize_service_type("_skybridge._tcp").expect("service type should normalize"),
            "_skybridge._tcp.local."
        );
        assert_eq!(
            normalize_service_type("_skybridge._tcp.").expect("service type should normalize"),
            "_skybridge._tcp.local."
        );
        assert_eq!(
            normalize_service_type("_skybridge._tcp.local").expect("service type should normalize"),
            "_skybridge._tcp.local."
        );
        assert_eq!(
            normalize_service_type("_skybridge._tcp.local.")
                .expect("service type should normalize"),
            "_skybridge._tcp.local."
        );
    }

    #[test]
    fn normalize_service_type_rejects_empty_control_or_invalid_protocol() {
        assert!(normalize_service_type("").is_err());
        assert!(normalize_service_type("   ").is_err());
        assert!(normalize_service_type("_skybridge._http").is_err());
        assert!(normalize_service_type("skybridge._tcp").is_err());
        assert!(normalize_service_type("_sky bridge._tcp").is_err());
    }

    #[test]
    fn build_discovery_request_rejects_unbounded_resource_requests() {
        let output = crate::OutputOptions { json: false };
        assert!(
            build_discovery_request(&crate::DeviceDiscoverArgs {
                timeout_seconds: 0,
                service_types: vec![],
                required_capabilities: vec![],
                output,
            })
            .is_err()
        );
        assert!(
            build_discovery_request(&crate::DeviceDiscoverArgs {
                timeout_seconds: MAX_DISCOVERY_TIMEOUT_SECONDS + 1,
                service_types: vec![],
                required_capabilities: vec![],
                output,
            })
            .is_err()
        );
        assert!(
            build_discovery_request(&crate::DeviceDiscoverArgs {
                timeout_seconds: 1,
                service_types: vec!["_skybridge._tcp".to_owned(); MAX_SERVICE_TYPES + 1],
                required_capabilities: vec![],
                output,
            })
            .is_err()
        );
    }

    #[test]
    fn instance_name_strips_service_suffix() {
        assert_eq!(
            instance_name(
                "Bill's Mac._skybridge._tcp.local.",
                "_skybridge._tcp.local."
            ),
            "Bill's Mac"
        );
        assert_eq!(
            instance_name("weird-fullname", "_skybridge._tcp.local."),
            "weird-fullname"
        );
    }

    #[test]
    fn upsert_replaces_existing_instance_and_keeps_others() {
        let mut devices = vec![sample("Mac", "_skybridge._tcp.local.", 50_000)];
        upsert(
            &mut devices,
            sample("iPad", "_skybridge._tcp.local.", 50_001),
        );
        let mut updated = sample("Mac", "_skybridge._tcp.local.", 50_002);
        updated.addresses = vec!["192.168.1.30".to_owned()];
        upsert(&mut devices, updated.clone());

        assert_eq!(devices.len(), 2);
        let mac = devices
            .iter()
            .find(|d| d.instance == "Mac")
            .expect("Mac entry present");
        assert_eq!(mac, &updated);
    }

    #[test]
    fn render_human_lists_devices_and_txt() {
        let devices = vec![sample("Bill's Mac", "_skybridge._tcp.local.", 50_000)];
        let rendered = render_human(&devices, &["_skybridge._tcp.local.".to_owned()], &[], 5);
        assert!(rendered.contains("Discovered 1 service(s):"));
        assert!(rendered.contains("- Bill's Mac [_skybridge._tcp control] Bill's Mac.local:50000"));
        assert!(rendered.contains("txt platform=macOS"));
    }

    #[test]
    fn render_human_reports_empty_result() {
        let rendered = render_human(&[], &["_skybridge._tcp.local.".to_owned()], &[], 3);
        assert!(rendered.contains("No SkyBridge devices discovered."));
    }

    #[test]
    fn required_capability_fails_closed_when_missing() {
        let devices = vec![sample("Mac", "_skybridge._tcp.local.", 50_000)];

        assert!(ensure_required_capabilities(&devices, &[DeviceCapabilityArg::Control]).is_ok());
        assert!(
            ensure_required_capabilities(&devices, &[DeviceCapabilityArg::RemoteDesktop]).is_err()
        );
    }

    #[test]
    fn sanitize_discovery_field_escapes_controls_and_bounds_length() {
        assert_eq!(
            sanitize_discovery_field("line\n\x1b[31m"),
            "line\\n\\u{FFFD}[31m"
        );
        let long = "x".repeat(MAX_FIELD_CHARS + 5);
        let sanitized = sanitize_discovery_field(&long);
        assert!(sanitized.ends_with("...[truncated]"));
    }
}
