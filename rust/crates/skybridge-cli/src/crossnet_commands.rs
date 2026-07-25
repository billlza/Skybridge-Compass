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
/// `true`/`false` become booleans so boolean settings work without quoting;
/// everything else stays a string and the Mac app validates the domain. Numbers
/// are intentionally not inferred — no allowlisted mutable setting is numeric, and
/// guessing would turn a typo into a silently different type.
fn parse_setting_value(raw: &str) -> Value {
    match raw {
        "true" => Value::Bool(true),
        "false" => Value::Bool(false),
        other => Value::String(other.to_owned()),
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
        mutation_methods_enabled: false,
        ready_for_mutation: false,
        failure_code: None,
        failure_class: None,
        next_required_action: "signed Mac app socket smoke must prove live mutation before GUI-bound crossnet mutation commands are enabled",
    }
}

fn preflight_payload(result: &HelloResult) -> serde_json::Value {
    let state = preflight_state(result);
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
        };

        let payload = preflight_payload(&result);

        assert_eq!(payload["schema_version"], 1);
        assert_eq!(payload["capability_id"], "crossnet.preflight");
        assert_eq!(payload["runtime_target"], "mac_app_runtime");
        assert_eq!(payload["control_effect"], "read_only");
        assert_eq!(payload["mac_gui_control_protocol"], "crossnet-control/1");
        assert_eq!(payload["preconditions_ready"].as_bool(), Some(true));
        assert_eq!(payload["mutation_methods_enabled"].as_bool(), Some(false));
        assert_eq!(payload["ready_for_mutation"].as_bool(), Some(false));
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
    fn preflight_payload_reports_auth_and_tenant_readiness_failures() {
        let missing_auth = HelloResult {
            engine_version: "test-app".to_owned(),
            proto: CONTROL_PROTOCOL_VERSION,
            auth_loaded: false,
            tenant_bound: true,
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
