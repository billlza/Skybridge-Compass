use anyhow::{Result, bail};
use serde_json::Value;
use serde_json::json;
use skybridge_crossnet_client::{
    CONTROL_PROTOCOL_VERSION, ConnectResult, DisconnectResult, HelloResult, HostResult, LeaseMode,
    SettingsMutationResult, SettingsSnapshotResult, StatusOutcome, StatusResult,
};

use crate::{
    CrossnetConnectArgs, CrossnetHostArgs, CrossnetLeaseMode, CrossnetSettingsSetArgs,
    CrossnetStatusArgs,
};

impl From<CrossnetLeaseMode> for LeaseMode {
    fn from(mode: CrossnetLeaseMode) -> Self {
        match mode {
            CrossnetLeaseMode::Short => LeaseMode::Short,
            CrossnetLeaseMode::Long => LeaseMode::Long,
        }
    }
}

pub(crate) async fn preflight(as_json: bool) -> Result<()> {
    let result = skybridge_crossnet_client::hello().await?;
    print_preflight(&result, as_json)
}

pub(crate) async fn host(args: CrossnetHostArgs) -> Result<()> {
    let result = skybridge_crossnet_client::host(args.lease.map(LeaseMode::from)).await?;
    print_host(&result, args.output.json)
}

pub(crate) async fn connect(args: CrossnetConnectArgs) -> Result<()> {
    let result = skybridge_crossnet_client::connect(&args.code).await?;
    print_connect(&result, args.output.json)
}

pub(crate) async fn disconnect(as_json: bool) -> Result<()> {
    let result = skybridge_crossnet_client::disconnect().await?;
    print_disconnect(&result, as_json)
}

pub(crate) async fn devices(as_json: bool) -> Result<()> {
    let result = skybridge_crossnet_client::devices().await?;
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "capability_id": "crossnet.devices",
                "runtime_target": "mac_app_runtime",
                "control_effect": "read_only",
                "devices": result.devices,
            }))?
        );
    } else if result.devices.is_empty() {
        println!("No online account devices visible to the Mac app.");
    } else {
        for device in &result.devices {
            println!(
                "{}  {}  [{}]{}",
                device.device_ref,
                device.name,
                if device.online { "online" } else { "offline" },
                device
                    .platform
                    .as_deref()
                    .map(|platform| format!(" ({platform})"))
                    .unwrap_or_default(),
            );
        }
    }
    Ok(())
}

pub(crate) async fn connect_device(args: crate::CrossnetConnectDeviceArgs) -> Result<()> {
    let result = skybridge_crossnet_client::connect_device(&args.device_ref).await?;
    if args.output.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "capability_id": "crossnet.connect_device",
                "runtime_target": "mac_app_runtime",
                "control_effect": "mac_session_mutation",
                "device_ref": result.device_ref,
                "name": result.name,
                "connected": result.connected,
            }))?
        );
    } else {
        println!(
            "Connected to {} ({})",
            result.name.as_deref().unwrap_or("device"),
            result.device_ref
        );
    }
    Ok(())
}

pub(crate) async fn navigate(args: crate::CrossnetNavigateArgs) -> Result<()> {
    let destination = args.destination.as_wire();
    let result = skybridge_crossnet_client::navigate(destination).await?;
    if args.output.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "capability_id": "crossnet.navigation",
                "runtime_target": "mac_app_runtime",
                "control_effect": "mac_ui_navigation",
                "destination": result.destination,
                "presented_destination": result.presented_destination,
                "runtime_applied": result.runtime_applied,
            }))?
        );
    } else {
        println!("Navigated Mac app to: {}", result.presented_destination);
    }
    Ok(())
}

pub(crate) async fn status(args: CrossnetStatusArgs) -> Result<()> {
    match skybridge_crossnet_client::status(args.watch).await? {
        StatusOutcome::Snapshot(snapshot) => print_status(&snapshot, args.output.json),
        StatusOutcome::Watch(mut watch) => {
            print_status(watch.initial(), args.output.json)?;
            while let Some(event) = watch.next_event().await? {
                print_status(&event, args.output.json)?;
            }
            Ok(())
        }
    }
}

pub(crate) async fn settings(as_json: bool) -> Result<()> {
    let result = skybridge_crossnet_client::settings_snapshot().await?;
    print_settings(&result, as_json)
}

pub(crate) async fn settings_set(args: CrossnetSettingsSetArgs) -> Result<()> {
    let value = parse_setting_value(&args.value);
    let result = skybridge_crossnet_client::settings_set(&args.id, value).await?;
    print_settings_mutation(&result, args.output.json)
}

/// Maps the operator-typed argument onto a wire value.
///
/// `true`/`false` become booleans and a bare integer becomes a number, so
/// boolean and numeric settings work without quoting; everything else stays a
/// string. This is safe against typos because the Mac app validates the value
/// against the setting's declared type per id and answers
/// `setting_invalid_value` — a number sent to a string setting is rejected, not
/// coerced.
///
/// It relies on no mutable string setting having a purely numeric domain, which
/// holds today: `logging.level` is a word and `remote_desktop.resolution`
/// always contains an `x` or is `auto`. A future numeric-looking string setting
/// would need an explicit type lookup here.
fn parse_setting_value(raw: &str) -> Value {
    match raw {
        "true" => Value::Bool(true),
        "false" => Value::Bool(false),
        other => match other.parse::<i64>() {
            Ok(parsed) => Value::Number(parsed.into()),
            Err(_) => Value::String(other.to_owned()),
        },
    }
}

fn settings_mutation_payload(result: &SettingsMutationResult) -> Value {
    json!({
        "runtime_target": result.runtime_target,
        "control_effect": result.control_effect,
        "id": result.id,
        "value_type": result.value_type,
        "requested_value": result.requested_value,
        "observed_value": result.observed_value,
        "runtime_applied": result.runtime_applied,
        "note": result.note,
    })
}

fn print_settings_mutation(result: &SettingsMutationResult, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&settings_mutation_payload(result))?
        );
        return Ok(());
    }
    println!(
        "Setting `{}` applied to the Mac app runtime; observed={} runtime_applied={}",
        result.id, result.observed_value, result.runtime_applied
    );
    if let Some(note) = &result.note {
        println!("Note: {note}");
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PreflightState {
    preconditions_ready: bool,
    mutation_methods_enabled: bool,
    ready_for_mutation: bool,
    failure_code: Option<&'static str>,
    failure_class: Option<&'static str>,
    next_required_action: &'static str,
}

const MAC_GUI_CONTROL_RELEASE_GATE: &str = "signed_mac_app_socket_smoke_required";

/// Mutating methods the Mac app actually implements today.
///
/// Reported explicitly because `mutation_methods_enabled` is a single bool and
/// the truth is per-method: refusing to enumerate would let an operator read
/// "enabled" and assume `crossnet connect` works.
pub(crate) const ENABLED_MUTATION_METHODS: &[&str] = &[
    "crossnet.settings.set",
    "crossnet.host",
    "crossnet.connect",
    "crossnet.connect_device",
    "crossnet.disconnect",
    "crossnet.navigation",
];

/// Mutating methods that still fail closed.
///
/// Empty since `crossnet.navigate` landed and `crossnet.status --watch`
/// gained a real server-push stream. Kept so a future gap has a declared home
/// instead of being silently undisclosed, and so preflight keeps rendering an
/// explicit (possibly empty) disabled list.
pub(crate) const DISABLED_MUTATION_METHODS: &[&str] = &[];

fn preflight_state(result: &HelloResult) -> PreflightState {
    if result.proto != CONTROL_PROTOCOL_VERSION {
        return PreflightState {
            preconditions_ready: false,
            mutation_methods_enabled: false,
            ready_for_mutation: false,
            failure_code: Some("protocol_version_mismatch"),
            failure_class: Some("protocol_contract"),
            next_required_action: "update the SkyBridge CLI and Mac app so both speak crossnet-control/1",
        };
    }
    if !result.auth_loaded {
        return PreflightState {
            preconditions_ready: false,
            mutation_methods_enabled: false,
            ready_for_mutation: false,
            failure_code: Some("auth_required"),
            failure_class: Some("operator_precondition"),
            next_required_action: "sign in to the SkyBridge Compass Pro Mac app",
        };
    }
    if !result.tenant_bound {
        return PreflightState {
            preconditions_ready: false,
            mutation_methods_enabled: false,
            ready_for_mutation: false,
            failure_code: Some("tenant_required"),
            failure_class: Some("operator_precondition"),
            next_required_action: "refresh the Mac app sign-in so it can bind a tenant",
        };
    }
    PreflightState {
        preconditions_ready: true,
        // Some mutating methods are implemented now, so a blanket `false` would
        // deny a live code path. The enabled/disabled lists carry the detail.
        mutation_methods_enabled: !ENABLED_MUTATION_METHODS.is_empty(),
        ready_for_mutation: !ENABLED_MUTATION_METHODS.is_empty(),
        failure_code: None,
        failure_class: None,
        next_required_action: "settings, session, and navigation mutation methods are enabled and status watch streams; signed Mac app socket smoke is still required for release readiness",
    }
}

/// What the CLI can honestly say about per-method availability.
///
/// The CLI's own constants describe the app build it was compiled alongside.
/// When the running app reports its own method list we use that instead, so a
/// newer CLI pointed at an older app does not advertise verbs the app will
/// refuse.
fn resolved_mutation_methods(result: &HelloResult) -> (Vec<String>, Vec<String>, &'static str) {
    if result.enabled_mutation_methods.is_empty() {
        return (
            ENABLED_MUTATION_METHODS
                .iter()
                .map(|method| (*method).to_owned())
                .collect(),
            DISABLED_MUTATION_METHODS
                .iter()
                .map(|method| (*method).to_owned())
                .collect(),
            "cli_expectation_app_did_not_report",
        );
    }
    let enabled = result.enabled_mutation_methods.clone();
    // Anything this CLI knows about that the app did not claim is, from the
    // operator's point of view, disabled on the machine they are driving.
    let mut disabled = DISABLED_MUTATION_METHODS
        .iter()
        .map(|method| (*method).to_owned())
        .collect::<Vec<_>>();
    for method in ENABLED_MUTATION_METHODS {
        let method = (*method).to_owned();
        if !enabled.contains(&method) && !disabled.contains(&method) {
            disabled.push(method);
        }
    }
    (enabled, disabled, "app_reported")
}

fn preflight_payload(result: &HelloResult) -> serde_json::Value {
    let state = preflight_state(result);
    let (enabled_methods, disabled_methods, methods_source) = resolved_mutation_methods(result);
    json!({
        "schema_version": 1,
        "capability_id": "crossnet.preflight",
        "runtime_target": "mac_app_runtime",
        "control_effect": "read_only",
        "mac_gui_control_protocol": "crossnet-control/1",
        "engine_version": result.engine_version,
        "proto": result.proto,
        "expected_proto": CONTROL_PROTOCOL_VERSION,
        "auth_loaded": result.auth_loaded,
        "tenant_bound": result.tenant_bound,
        "preconditions_ready": state.preconditions_ready,
        "mutation_methods_enabled": state.mutation_methods_enabled,
        "enabled_mutation_methods": enabled_methods,
        "disabled_mutation_methods": disabled_methods,
        "mutation_methods_source": methods_source,
        "ready_for_mutation": state.ready_for_mutation,
        "release_gate": MAC_GUI_CONTROL_RELEASE_GATE,
        "failure_code": state.failure_code,
        "failure_class": state.failure_class,
        "next_required_action": state.next_required_action,
    })
}

fn print_preflight(result: &HelloResult, as_json: bool) -> Result<()> {
    let state = preflight_state(result);
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&preflight_payload(result))?
        );
    } else {
        println!(
            "Mac App Preconditions: {}",
            if state.preconditions_ready {
                "ready"
            } else {
                "not ready"
            }
        );
        println!("Engine Version: {}", result.engine_version);
        println!(
            "Protocol: {} (expected {})",
            result.proto, CONTROL_PROTOCOL_VERSION
        );
        println!("Auth Loaded: {}", result.auth_loaded);
        println!("Tenant Bound: {}", result.tenant_bound);
        println!(
            "Mutation Methods Enabled: {}",
            state.mutation_methods_enabled
        );
        println!("Release Gate: {MAC_GUI_CONTROL_RELEASE_GATE}");
        if let Some(code) = state.failure_code {
            println!("Failure Code: {code}");
        }
        if let Some(failure_class) = state.failure_class {
            println!("Failure Class: {failure_class}");
        }
        println!("Next Required Action: {}", state.next_required_action);
    }
    Ok(())
}

fn print_host(result: &HostResult, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "code": result.code,
                "session_ref": result.session_ref,
                "expires_at": result.expires_at,
                "lease_mode": result.lease_mode,
            }))?
        );
    } else {
        println!("Connection Code: {}", result.code);
        println!(
            "Session Ref: {}",
            result.session_ref.as_deref().unwrap_or("none")
        );
        println!("Lease Mode: {}", result.lease_mode);
        println!(
            "Expires At: {}",
            result.expires_at.as_deref().unwrap_or("never")
        );
    }
    Ok(())
}

fn print_connect(result: &ConnectResult, as_json: bool) -> Result<()> {
    let session_ref = connect_session_ref(result)?;
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "session_ref": session_ref,
                "remote_device_name": result.remote_device_name,
                "readiness": result.readiness,
            }))?
        );
    } else {
        println!("Session Ref: {session_ref}");
        println!(
            "Remote Device: {}",
            result.remote_device_name.as_deref().unwrap_or("unknown")
        );
        println!("Readiness: {}", result.readiness);
    }
    Ok(())
}

fn connect_session_ref(result: &ConnectResult) -> Result<&str> {
    let Some(session_ref) = result.session_ref.as_deref() else {
        bail!(
            "crossnet.connect response omitted the redacted session_ref required for public CLI output (code: session_ref_required)"
        );
    };
    let session_ref = session_ref.trim();
    if session_ref.is_empty() {
        bail!(
            "crossnet.connect response omitted the redacted session_ref required for public CLI output (code: session_ref_required)"
        );
    }
    Ok(session_ref)
}

fn print_disconnect(result: &DisconnectResult, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({ "disconnected": result.disconnected }))?
        );
    } else if result.disconnected {
        println!("Disconnected cross-network session");
    } else {
        println!("No cross-network session to disconnect");
    }
    Ok(())
}

fn print_status(status: &StatusResult, as_json: bool) -> Result<()> {
    let session_present = status.session_present || status.session_id.is_some();
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "connection_status": status.connection_status,
                "readiness": status.readiness,
                "session_present": session_present,
                "session_ref": status.session_ref,
                "suite": status.suite,
                "signaling_health": status.signaling_health,
                "failure_code": status.failure_code,
                "failure_class": status.failure_class,
                "auth_loaded": status.auth_loaded,
                "tenant_bound": status.tenant_bound,
            }))?
        );
    } else {
        println!("Connection Status: {}", status.connection_status);
        println!("Readiness: {}", status.readiness);
        println!(
            "Session: {}",
            if session_present { "present" } else { "none" }
        );
        println!(
            "Session Ref: {}",
            status.session_ref.as_deref().unwrap_or("none")
        );
        println!("Suite: {}", status.suite.as_deref().unwrap_or("none"));
        println!(
            "Signaling Health: {}",
            status.signaling_health.as_deref().unwrap_or("unknown")
        );
        println!(
            "Failure Code: {}",
            status.failure_code.as_deref().unwrap_or("none")
        );
        println!(
            "Failure Class: {}",
            status.failure_class.as_deref().unwrap_or("none")
        );
        println!("Auth Loaded: {}", status.auth_loaded);
        println!("Tenant Bound: {}", status.tenant_bound);
    }
    Ok(())
}

fn settings_payload(snapshot: &SettingsSnapshotResult) -> Value {
    json!({
        "schema_version": 1,
        "capability_id": "crossnet.settings.snapshot",
        "runtime_target": snapshot.runtime_target,
        "control_effect": snapshot.control_effect,
        "settings": snapshot.settings,
    })
}

fn print_settings(snapshot: &SettingsSnapshotResult, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&settings_payload(snapshot))?
        );
    } else {
        println!("Runtime Target: {}", snapshot.runtime_target);
        println!("Control Effect: {}", snapshot.control_effect);
        for setting in &snapshot.settings {
            let mut qualifiers = vec![setting.value_type.as_str()];
            if !setting.mutable {
                qualifiers.push("read-only");
            }
            println!(
                "{}: {} ({})",
                setting.id,
                setting_value_display(&setting.value),
                qualifiers.join(", ")
            );
            if let Some(note) = setting.note.as_deref() {
                println!("  Note: {note}");
            }
        }
    }
    Ok(())
}

fn setting_value_display(value: &Value) -> String {
    match value {
        Value::String(value) => value.to_owned(),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        Value::Null => "null".to_owned(),
        Value::Array(_) | Value::Object(_) => {
            serde_json::to_string(value).unwrap_or_else(|_| "<unsupported-json-value>".to_owned())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preflight_payload_reports_ready_mac_app_without_mutation_claims() {
        let result = HelloResult {
            engine_version: "1.2.3+456".to_owned(),
            proto: CONTROL_PROTOCOL_VERSION,
            auth_loaded: true,
            tenant_bound: true,
            enabled_mutation_methods: Vec::new(),
        };

        let payload = preflight_payload(&result);

        assert_eq!(payload["schema_version"], 1);
        assert_eq!(payload["capability_id"], "crossnet.preflight");
        assert_eq!(payload["runtime_target"], "mac_app_runtime");
        assert_eq!(payload["control_effect"], "read_only");
        assert_eq!(payload["mac_gui_control_protocol"], "crossnet-control/1");
        assert_eq!(payload["preconditions_ready"].as_bool(), Some(true));
        // Settings mutation is implemented, so a blanket `false` would deny a live
        // code path; the enumerated lists keep the per-method truth explicit so
        // "enabled" is never read as "connect works".
        assert_eq!(payload["mutation_methods_enabled"].as_bool(), Some(true));
        assert_eq!(payload["ready_for_mutation"].as_bool(), Some(true));
        assert_eq!(
            payload["enabled_mutation_methods"],
            serde_json::json!([
                "crossnet.settings.set",
                "crossnet.host",
                "crossnet.connect",
                "crossnet.connect_device",
                "crossnet.disconnect",
                "crossnet.navigation"
            ])
        );
        let disabled = payload["disabled_mutation_methods"]
            .as_array()
            .expect("disabled mutation methods must be enumerated")
            .iter()
            .map(|value| value.as_str().unwrap_or_default().to_owned())
            .collect::<Vec<_>>();
        // Nothing on the crossnet surface fails closed any more; the list must
        // stay present (and empty) so an operator sees an explicit answer.
        assert_eq!(disabled, Vec::<String>::new());
        let enabled = payload["enabled_mutation_methods"]
            .as_array()
            .expect("enabled mutation methods must be enumerated")
            .iter()
            .map(|value| value.as_str().unwrap_or_default().to_owned())
            .collect::<Vec<_>>();
        // A method reported as both enabled and disabled would let an operator
        // read whichever half suited them.
        for entry in &enabled {
            assert!(
                !disabled.contains(entry),
                "{entry} must not be reported both enabled and disabled: {payload}"
            );
        }
        assert_eq!(
            payload["release_gate"],
            "signed_mac_app_socket_smoke_required"
        );
        assert!(payload["failure_code"].is_null());
        assert!(payload["failure_class"].is_null());
        assert!(
            !payload.to_string().contains("\"mutation_supported\":true"),
            "{payload}"
        );
    }

    #[test]
    fn setting_values_are_typed_so_numeric_settings_do_not_need_quoting() {
        assert_eq!(parse_setting_value("true"), Value::Bool(true));
        assert_eq!(parse_setting_value("false"), Value::Bool(false));
        // `remote_desktop.target_fps` is numeric on the wire; sending "60" as a
        // string would be rejected by the app's typed allowlist.
        assert_eq!(parse_setting_value("60"), Value::Number(60.into()));
        assert_eq!(parse_setting_value("-1"), Value::Number((-1).into()));
        // Resolution presets and log levels must stay strings.
        assert_eq!(
            parse_setting_value("1920x1080"),
            Value::String("1920x1080".to_owned())
        );
        assert_eq!(
            parse_setting_value("auto"),
            Value::String("auto".to_owned())
        );
        assert_eq!(
            parse_setting_value("Warning"),
            Value::String("Warning".to_owned())
        );
    }

    /// The CLI ships separately from the Mac app, so its compile-time method
    /// list describes the app it was built alongside, not the app that is
    /// running. When the app reports its own list, that wins.
    #[test]
    fn preflight_reports_the_installed_app_method_list_over_cli_expectations() {
        // An older app that does not report a list at all: fall back to the
        // CLI's expectation and say so, rather than claiming the app agreed.
        let silent_app = HelloResult {
            engine_version: "1.0.1+900".to_owned(),
            proto: CONTROL_PROTOCOL_VERSION,
            auth_loaded: true,
            tenant_bound: true,
            enabled_mutation_methods: Vec::new(),
        };
        let payload = preflight_payload(&silent_app);
        assert_eq!(
            payload["mutation_methods_source"],
            "cli_expectation_app_did_not_report"
        );

        // An app that serves only the settings verb must not have the session
        // verbs advertised on its behalf.
        let older_app = HelloResult {
            engine_version: "1.0.2+901".to_owned(),
            proto: CONTROL_PROTOCOL_VERSION,
            auth_loaded: true,
            tenant_bound: true,
            enabled_mutation_methods: vec!["crossnet.settings.set".to_owned()],
        };
        let payload = preflight_payload(&older_app);
        assert_eq!(payload["mutation_methods_source"], "app_reported");
        let enabled = payload["enabled_mutation_methods"]
            .as_array()
            .expect("enabled methods must be enumerated")
            .iter()
            .map(|value| value.as_str().unwrap_or_default().to_owned())
            .collect::<Vec<_>>();
        assert_eq!(enabled, vec!["crossnet.settings.set".to_owned()]);
        let disabled = payload["disabled_mutation_methods"]
            .as_array()
            .expect("disabled methods must be enumerated")
            .iter()
            .map(|value| value.as_str().unwrap_or_default().to_owned())
            .collect::<Vec<_>>();
        for unsupported in ["crossnet.host", "crossnet.connect", "crossnet.disconnect"] {
            assert!(
                disabled.iter().any(|entry| entry == unsupported),
                "{unsupported} is not served by this app build and must not read as enabled: {payload}"
            );
        }
        assert!(
            !disabled
                .iter()
                .any(|entry| entry == "crossnet.settings.set"),
            "a method the app reported must not also read as disabled: {payload}"
        );
    }

    #[test]
    fn preflight_payload_reports_auth_and_tenant_readiness_failures() {
        let missing_auth = HelloResult {
            engine_version: "test-app".to_owned(),
            proto: CONTROL_PROTOCOL_VERSION,
            auth_loaded: false,
            tenant_bound: true,
            enabled_mutation_methods: Vec::new(),
        };
        let missing_auth_payload = preflight_payload(&missing_auth);
        assert_eq!(
            missing_auth_payload["ready_for_mutation"].as_bool(),
            Some(false)
        );
        assert_eq!(missing_auth_payload["failure_code"], "auth_required");
        assert_eq!(
            missing_auth_payload["failure_class"],
            "operator_precondition"
        );
        assert!(
            missing_auth_payload["next_required_action"]
                .as_str()
                .is_some_and(|value| value.contains("sign in"))
        );

        let missing_tenant = HelloResult {
            engine_version: "test-app".to_owned(),
            proto: CONTROL_PROTOCOL_VERSION,
            auth_loaded: true,
            tenant_bound: false,
            enabled_mutation_methods: Vec::new(),
        };
        let missing_tenant_payload = preflight_payload(&missing_tenant);
        assert_eq!(
            missing_tenant_payload["ready_for_mutation"].as_bool(),
            Some(false)
        );
        assert_eq!(missing_tenant_payload["failure_code"], "tenant_required");
        assert_eq!(
            missing_tenant_payload["failure_class"],
            "operator_precondition"
        );
    }

    #[test]
    fn preflight_payload_reports_protocol_mismatch() {
        let result = HelloResult {
            engine_version: "old-app".to_owned(),
            proto: CONTROL_PROTOCOL_VERSION + 1,
            auth_loaded: true,
            tenant_bound: true,
            enabled_mutation_methods: Vec::new(),
        };

        let payload = preflight_payload(&result);

        assert_eq!(payload["ready_for_mutation"].as_bool(), Some(false));
        assert_eq!(payload["failure_code"], "protocol_version_mismatch");
        assert_eq!(payload["failure_class"], "protocol_contract");
        assert_eq!(payload["expected_proto"], CONTROL_PROTOCOL_VERSION);
    }

    #[test]
    fn connect_session_ref_requires_redacted_reference_without_echoing_raw_session() {
        let missing_ref = ConnectResult {
            session_id: Some("session-token-secret".to_owned()),
            session_ref: None,
            remote_device_name: Some("MacBook".to_owned()),
            readiness: "handshake_complete".to_owned(),
        };
        let error = connect_session_ref(&missing_ref)
            .expect_err("connect output must fail closed without session_ref");
        let message = error.to_string();
        assert!(message.contains("session_ref_required"), "{message}");
        assert!(!message.contains("session-token-secret"), "{message}");

        let redacted = ConnectResult {
            session_id: Some("session-token-secret".to_owned()),
            session_ref: Some("sha256:connectref".to_owned()),
            remote_device_name: Some("MacBook".to_owned()),
            readiness: "handshake_complete".to_owned(),
        };
        assert_eq!(
            connect_session_ref(&redacted).expect("session_ref should be usable"),
            "sha256:connectref"
        );
    }

    #[test]
    fn settings_payload_reports_read_only_mac_app_projection() {
        let snapshot = SettingsSnapshotResult {
            runtime_target: "mac_app_runtime".to_owned(),
            control_effect: "read_only".to_owned(),
            settings: vec![
                skybridge_crossnet_client::SettingSnapshot {
                    id: "logging.verbose".to_owned(),
                    value_type: "bool".to_owned(),
                    value: Value::Bool(true),
                    mutable: false,
                    note: None,
                },
                skybridge_crossnet_client::SettingSnapshot {
                    id: "pqc.signature_algorithm".to_owned(),
                    value_type: "string".to_owned(),
                    value: Value::String("ML-DSA-65".to_owned()),
                    mutable: false,
                    note: Some("policy_preference_not_runtime_proof".to_owned()),
                },
            ],
        };

        let payload = settings_payload(&snapshot);

        assert_eq!(payload["schema_version"], 1);
        assert_eq!(payload["capability_id"], "crossnet.settings.snapshot");
        assert_eq!(payload["runtime_target"], "mac_app_runtime");
        assert_eq!(payload["control_effect"], "read_only");
        assert_eq!(payload["settings"][0]["mutable"].as_bool(), Some(false));
        assert_eq!(payload["settings"][1]["value"], "ML-DSA-65");
        assert_eq!(
            payload["settings"][1]["note"],
            "policy_preference_not_runtime_proof"
        );
    }
}
