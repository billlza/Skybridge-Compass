use crate::performance_evidence::{extract_text_u64, extract_text_value};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_p2p_remote_mac_ipad_online_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    lower: &str,
    is_mac: bool,
    is_ios: bool,
    line_sequence: u64,
) {
    if is_ios && is_ipad_presence_heartbeat(line, lower) {
        evidence.ios_ipad_presence_heartbeat_samples += 1;
    }

    if !is_mac {
        return;
    }

    if is_mac_ipad_dashboard_role_boot(line, lower) {
        evidence.mac_ipad_dashboard_role_boot_samples += 1;
    }

    if is_ipad_control_port_probe(line, lower) {
        if text_value_equals(line, "reachable", "1")
            && text_value_equals(line, "source", "pre-mac-online-probe")
            && text_value_equals(line, "listenerReady", "1")
            && extract_text_u64(line, "port").is_some_and(|port| port > 0)
            && identity_key(line).is_some()
        {
            evidence.mac_ipad_control_port_reachable_samples += 1;
            remember_identity_sequence(
                &mut evidence.mac_ipad_control_port_reachable_identity_sequences,
                line,
                line_sequence,
            );
        } else {
            evidence.mac_ipad_control_port_unreachable_samples += 1;
        }
    }

    if is_mac_ipad_visible_row(line, lower) {
        evidence.mac_ipad_online_ui_rows += 1;
        remember_physical_identity_row(
            &mut evidence.mac_ipad_online_physical_identity_rows,
            &mut evidence.mac_ipad_online_physical_row_counts,
            line,
        );
    }

    if is_mac_ipad_online_row(line, lower) {
        let button_enabled =
            boolean_text_value(line, "buttonEnabled") || boolean_text_value(line, "button_enabled");
        let strong_match = is_strong_match(line, lower);
        let weak_match = is_weak_match(line, lower);
        let real_online_row_source = is_real_online_row_source(line);
        if real_online_row_source {
            evidence.mac_ipad_real_online_row_source_samples += 1;
        }
        if button_enabled {
            evidence.mac_ipad_online_button_enabled_rows += 1;
        }
        if button_enabled
            && strong_match
            && real_online_row_source
            && !is_explicit_non_connectable_row(line, lower)
            && row_endpoint_is_unspecified_or_valid(line, lower)
        {
            evidence.mac_ipad_online_connectable_enabled_rows += 1;
            remember_identity_source_sequence(
                &mut evidence.mac_ipad_online_connectable_identity_sequences,
                line,
                line_sequence,
            );
        }
        if strong_match {
            evidence.mac_ipad_online_strong_match_rows += 1;
        }
        if weak_match {
            evidence.mac_ipad_online_weak_match_rows += 1;
        }
    }

    if is_mac_ipad_connect_click(line, lower) {
        evidence.mac_ipad_connect_click_samples += 1;
        let real_button_click = is_real_connect_button_source(line);
        if real_button_click {
            evidence.mac_ipad_real_button_source_click_samples += 1;
        }
        if real_button_click {
            remember_identity_source_sequence(
                &mut evidence.mac_ipad_connect_click_identity_sequences,
                line,
                line_sequence,
            );
            if has_real_connect_endpoint(line, lower) {
                evidence.mac_ipad_connect_real_endpoint_samples += 1;
            }
        }
        if is_no_endpoint_failure(line, lower) {
            evidence.mac_ipad_connect_no_endpoint_failures += 1;
        }
    }

    if is_mac_ipad_connect_start(line, lower) {
        evidence.mac_ipad_p2p_connect_start_samples += 1;
        remember_identity_sequence(
            &mut evidence.mac_ipad_connect_start_identity_sequences,
            line,
            line_sequence,
        );
    }

    if is_mac_ipad_connect_result(line, lower) {
        if text_value_equals(line, "result", "success")
            && (has_real_connect_endpoint(line, lower)
                || is_external_ax_connected_result(line, lower))
        {
            evidence.mac_ipad_connect_success_samples += 1;
            remember_identity_sequence(
                &mut evidence.mac_ipad_connect_success_identity_sequences,
                line,
                line_sequence,
            );
        } else {
            evidence.mac_ipad_connect_failure_samples += 1;
        }
    }
}

fn is_mac_ipad_dashboard_role_boot(line: &str, lower: &str) -> bool {
    lower.contains("boot")
        && text_value_equals(line, "role", "mac-online-ipad-client")
        && text_value_equals(line, "process", "SkyBridgeCompassApp")
        && text_value_equals(line, "source", "app")
        && matches!(
            extract_text_value(line, "uiRole")
                .unwrap_or_default()
                .to_ascii_lowercase()
                .as_str(),
            "dashboard" | "root-container"
        )
}

fn is_ipad_presence_heartbeat(line: &str, lower: &str) -> bool {
    (line.contains("iCloud KVS 在线心跳已发布") && lower.contains("ipad"))
        || (lower.contains("ios-icloud-presence")
            && lower.contains("heartbeat")
            && target_family_is_ipad(line, lower))
}

fn is_ipad_control_port_probe(line: &str, lower: &str) -> bool {
    lower.contains("ipad-control-port")
        && (text_value_equals(line, "probe", "tcp-only") || lower.contains("probe=tcp-only"))
}

fn is_real_online_row_source(line: &str) -> bool {
    text_value_equals(line, "source", "OnlineDeviceCard")
        && (text_value_equals(line, "evidenceSource", "external-ax")
            || text_value_equals(line, "evidenceSource", "app-smoke")
            || text_value_equals(line, "buttonEvidenceSource", "accessibility")
            || text_value_equals(line, "observer", "accessibility"))
}

fn is_real_connect_button_source(line: &str) -> bool {
    text_value_equals(line, "source", "OnlineDeviceCard")
        && (text_value_equals(line, "clickSource", "accessibility")
            || text_value_equals(line, "clickMechanism", "AXUIElementPerformAction"))
        && boolean_text_value(line, "targetRowBound")
}

fn is_mac_ipad_online_row(line: &str, lower: &str) -> bool {
    is_mac_ipad_visible_row(line, lower)
        && (text_value_equals(line, "status", "online") || boolean_text_value(line, "online"))
}

fn is_mac_ipad_visible_row(line: &str, lower: &str) -> bool {
    (lower.contains("mac-ipad-online-row")
        || lower.contains("mac-online-device-ui")
        || lower.contains("mac-ipad-online-ui")
        || lower.contains("mac-ipad-trusted-device-ui")
        || lower.contains("mac-ipad-cloud-device-ui")
        || lower.contains("source=trusteddevicecard")
        || lower.contains("source=clouddevicecard")
        || lower.contains("source=clouddevicerow"))
        && target_family_is_ipad(line, lower)
        && (boolean_text_value(line, "visible") || lower.contains("visible=true"))
}

fn is_mac_ipad_connect_click(line: &str, lower: &str) -> bool {
    if lower.contains("mac-online-connect-start")
        || lower.contains("mac-ipad-connect-start")
        || lower.contains("mac-online-connect-result")
        || lower.contains("mac-ipad-connect-result")
    {
        return false;
    }
    (lower.contains("mac-ipad-connect-button")
        || lower.contains("mac-online-connect")
        || lower.contains("mac-ipad-online-connect"))
        && target_family_is_ipad(line, lower)
        && (text_value_equals(line, "action", "button")
            || boolean_text_value(line, "button")
            || lower.contains("connect-button"))
}

fn is_explicit_non_connectable_row(line: &str, lower: &str) -> bool {
    text_value_equals(line, "controlEndpoint", "0")
        || text_value_equals(line, "hasControlEndpoint", "0")
        || text_value_equals(line, "candidateCount", "0")
        || text_value_equals(line, "candidates", "0")
        || text_value_equals(line, "resolvedSource", "skybridgeCloud")
        || text_value_equals(line, "source", "skybridgeCloud")
        || is_no_endpoint_failure(line, lower)
}

fn row_endpoint_is_unspecified_or_valid(line: &str, lower: &str) -> bool {
    let has_endpoint_claim = [
        "resolvedSource",
        "controlEndpoint",
        "hasControlEndpoint",
        "candidateCount",
        "candidates",
        "service",
        "endpointClass",
        "bonjourServiceName",
        "endpointHost",
        "endpointPort",
    ]
    .iter()
    .any(|key| extract_text_value(line, key).is_some());
    !has_endpoint_claim || has_real_connect_endpoint(line, lower)
}

fn is_mac_ipad_connect_start(line: &str, lower: &str) -> bool {
    (lower.contains("mac-ipad-connect-start") || lower.contains("mac-online-connect-start"))
        && target_family_is_ipad(line, lower)
        && (has_real_connect_endpoint(line, lower) || is_external_ax_connect_start(line))
}

fn is_mac_ipad_connect_result(line: &str, lower: &str) -> bool {
    (lower.contains("mac-ipad-connect-result") || lower.contains("mac-online-connect-result"))
        && target_family_is_ipad(line, lower)
}

fn is_external_ax_connect_start(line: &str) -> bool {
    is_real_connect_button_source(line) && text_value_equals(line, "evidenceSource", "external-ax")
}

fn is_external_ax_connected_result(line: &str, lower: &str) -> bool {
    text_value_equals(line, "source", "OnlineDeviceCard")
        && (text_value_equals(line, "evidenceSource", "external-ax")
            || text_value_equals(line, "observer", "accessibility")
            || text_value_equals(line, "clickSource", "accessibility"))
        && (text_value_equals(line, "status", "connected") || lower.contains("status=connected"))
}

fn target_family_is_ipad(line: &str, lower: &str) -> bool {
    text_value_equals(line, "targetFamily", "ipad")
        || text_value_equals(line, "family", "ipad")
        || lower.contains("targetfamily=ipad")
        || lower.contains("family=ipad")
}

fn is_strong_match(line: &str, lower: &str) -> bool {
    boolean_text_value(line, "strongIdentity")
        || boolean_text_value(line, "strongMatch")
        || matches!(
            extract_text_value(line, "matchStrength")
                .unwrap_or_default()
                .to_ascii_lowercase()
                .as_str(),
            "stable-id" | "stableid" | "device-id" | "deviceid" | "ip" | "endpoint" | "identity"
        )
        || lower.contains("matchstrength=stable-id")
        || lower.contains("matchstrength=device-id")
}

fn is_weak_match(line: &str, lower: &str) -> bool {
    boolean_text_value(line, "weakNameMatch")
        || matches!(
            extract_text_value(line, "matchStrength")
                .unwrap_or_default()
                .to_ascii_lowercase()
                .as_str(),
            "name" | "weak-name" | "weakname" | "name-only" | "nameonly"
        )
        || lower.contains("matchstrength=name")
}

fn has_real_connect_endpoint(line: &str, lower: &str) -> bool {
    let has_control_endpoint = boolean_text_value(line, "controlEndpoint")
        || boolean_text_value(line, "hasControlEndpoint");
    let has_candidates = extract_text_u64(line, "candidateCount").is_some_and(|count| count > 0)
        || extract_text_u64(line, "candidates").is_some_and(|count| count > 0);
    let has_real_source = text_value_is_real_endpoint_source(line, "resolvedSource")
        || text_value_is_real_endpoint_source(line, "source")
        || lower.contains("service=_skybridge._tcp")
        || lower.contains("service=_skybridge._udp")
        || lower.contains("endpointclass=bonjour-service")
        || lower.contains("endpointclass=direct-host");

    (has_control_endpoint || has_candidates)
        && has_real_source
        && has_dialable_route(line)
        && !is_no_endpoint_failure(line, lower)
}

fn has_dialable_route(line: &str) -> bool {
    has_real_bonjour_service_name(line) || has_real_direct_endpoint(line)
}

fn has_real_bonjour_service_name(line: &str) -> bool {
    extract_text_value(line, "bonjourServiceName").is_some_and(|value| {
        let normalized = value.trim().to_ascii_lowercase();
        !normalized.is_empty()
            && normalized != "-"
            && !normalized.starts_with("id:")
            && !normalized.starts_with("fp:")
            && !normalized.starts_with("ip:")
            && !normalized.starts_with("mac:")
            && !normalized.starts_with("name:")
            && !normalized.starts_with("serial:")
            && !normalized.starts_with("recent:name:")
            && !normalized.starts_with("recent:peer:")
    })
}

fn has_real_direct_endpoint(line: &str) -> bool {
    let has_host = extract_text_value(line, "endpointHost").is_some_and(|value| {
        let normalized = value.trim().to_ascii_lowercase();
        !normalized.is_empty()
            && normalized != "-"
            && normalized != "0.0.0.0"
            && normalized != "::"
            && normalized != "::0"
    });
    let has_port = extract_text_u64(line, "endpointPort").is_some_and(|port| port > 0);
    has_host && has_port
}

fn is_no_endpoint_failure(line: &str, lower: &str) -> bool {
    boolean_text_value(line, "noConnectableEndpoint")
        || lower.contains("noconnectableendpoint")
        || lower.contains("no connectable endpoint")
        || lower.contains("缺少真实 skybridge 控制端点")
}

fn text_value_is_real_endpoint_source(line: &str, key: &str) -> bool {
    matches!(
        extract_text_value(line, key)
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
        "skybridgebonjour"
            | "skybridge-bonjour"
            | "bonjour"
            | "skybridgep2p"
            | "skybridge-p2p"
            | "p2p"
            | "direct-host"
            | "bonjour-service"
    )
}

fn text_value_equals(line: &str, key: &str, expected: &str) -> bool {
    extract_text_value(line, key).is_some_and(|value| value.eq_ignore_ascii_case(expected))
}

fn boolean_text_value(line: &str, key: &str) -> bool {
    extract_text_value(line, key)
        .is_some_and(|value| matches!(value.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
}

fn remember_identity_sequence(
    sequences: &mut std::collections::BTreeMap<String, u64>,
    line: &str,
    line_sequence: u64,
) {
    if let Some(identity) = identity_key(line) {
        sequences.entry(identity).or_insert(line_sequence);
    }
}

fn remember_identity_source_sequence(
    sequences: &mut std::collections::BTreeMap<String, u64>,
    line: &str,
    line_sequence: u64,
) {
    if let (Some(identity), Some(source)) = (identity_key(line), source_key(line)) {
        sequences
            .entry(format!("{identity}\u{1f}source:{source}"))
            .or_insert(line_sequence);
    }
}

fn remember_physical_identity_row(
    rows: &mut std::collections::BTreeMap<String, std::collections::BTreeSet<String>>,
    row_counts: &mut std::collections::BTreeMap<String, u64>,
    line: &str,
) {
    let Some(physical_key) = physical_device_key(line) else {
        return;
    };
    *row_counts.entry(physical_key.clone()).or_default() += 1;
    let Some(identity) = identity_key(line) else {
        return;
    };
    rows.entry(physical_key).or_default().insert(identity);
}

fn physical_device_key(line: &str) -> Option<String> {
    [
        "physicalDeviceKey",
        "dedupeKey",
        "canonicalDeviceKey",
        "canonicalIdentity",
        "canonicalIdentityKey",
    ]
    .iter()
    .find_map(|key| normalized_identity_payload(line, key))
    .map(|value| format!("physical:{value}"))
    .or_else(|| presentation_physical_key(line))
    .or_else(|| identity_key(line))
}

fn presentation_physical_key(line: &str) -> Option<String> {
    let name = normalized_identity_payload(line, "device")
        .or_else(|| normalized_identity_payload(line, "deviceName"))
        .or_else(|| normalized_identity_payload(line, "name"))?;
    let family = normalized_identity_payload(line, "targetFamily")
        .or_else(|| normalized_identity_payload(line, "family"))
        .unwrap_or_else(|| "device".to_owned());
    let model = normalized_identity_payload(line, "model").unwrap_or_else(|| family.clone());
    Some(format!("presentation:{family}:{name}:{model}"))
}

fn identity_key(line: &str) -> Option<String> {
    [
        "identityKey",
        "targetDeviceId",
        "p2pDeviceId",
        "cloudDeviceId",
        "deviceId",
        "pubKeyFP",
        "bonjourServiceName",
    ]
    .iter()
    .find_map(|key| normalized_identity_value(line, key))
}

fn source_key(line: &str) -> Option<String> {
    normalized_identity_value(line, "source")
}

fn normalized_identity_value(line: &str, key: &str) -> Option<String> {
    normalized_identity_payload(line, key).map(|value| format!("{key}:{value}"))
}

fn normalized_identity_payload(line: &str, key: &str) -> Option<String> {
    let value = extract_text_value(line, key)?;
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed == "-" {
        return None;
    }
    Some(trimmed.to_ascii_lowercase())
}
