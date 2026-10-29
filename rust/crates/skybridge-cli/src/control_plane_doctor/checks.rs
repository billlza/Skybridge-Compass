use anyhow::Result;
use skybridge_core::ControlPlaneRawProbe;

use crate::DoctorCheck;

pub(super) fn check_probe_reachable(
    name: &'static str,
    probe: &Result<ControlPlaneRawProbe>,
    path: &str,
) -> DoctorCheck {
    match probe {
        Ok(probe) => DoctorCheck {
            name,
            ok: probe.success,
            severity: if probe.success { "info" } else { "error" },
            detail: format!("{path} returned HTTP {}", probe.status_code),
            server_build_fingerprint: value_string(&probe.body, "serverBuildFingerprint"),
            state_backend: value_string(&probe.body, "stateBackend"),
            reject_reason: value_string(&probe.body, "rejectReason"),
        },
        Err(error) => DoctorCheck {
            name,
            ok: false,
            severity: "error",
            detail: format!("{path} probe failed: {error}"),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        },
    }
}

pub(super) fn check_readyz(probe: &Result<ControlPlaneRawProbe>) -> DoctorCheck {
    match probe {
        Ok(probe) => {
            let status = value_string(&probe.body, "status").unwrap_or_else(|| "-".to_owned());
            let ok = probe.success && status == "ready";
            DoctorCheck {
                name: "readyz",
                ok,
                severity: if ok { "info" } else { "error" },
                detail: format!(
                    "/readyz returned HTTP {} status={status}",
                    probe.status_code
                ),
                server_build_fingerprint: value_string(&probe.body, "serverBuildFingerprint"),
                state_backend: value_string(&probe.body, "stateBackend"),
                reject_reason: value_string(&probe.body, "rejectReason"),
            }
        }
        Err(error) => DoctorCheck {
            name: "readyz",
            ok: false,
            severity: "error",
            detail: format!("/readyz probe failed: {error}"),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        },
    }
}

pub(super) fn route_present(probe: &Result<ControlPlaneRawProbe>) -> bool {
    probe
        .as_ref()
        .is_ok_and(|probe| !matches!(probe.status_code, 404 | 405 | 502))
}

pub(super) fn check_route_present(
    name: &'static str,
    probe: &Result<ControlPlaneRawProbe>,
    path: &str,
) -> DoctorCheck {
    match probe {
        Ok(probe) => {
            let ok = !matches!(probe.status_code, 404 | 405 | 502);
            DoctorCheck {
                name,
                ok,
                severity: if ok { "info" } else { "error" },
                detail: format!("{path} route probe returned HTTP {}", probe.status_code),
                server_build_fingerprint: value_string(&probe.body, "serverBuildFingerprint"),
                state_backend: value_string(&probe.body, "stateBackend"),
                reject_reason: value_string(&probe.body, "rejectReason"),
            }
        }
        Err(error) => DoctorCheck {
            name,
            ok: false,
            severity: "error",
            detail: format!("{path} route probe failed: {error}"),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        },
    }
}

pub(super) fn check_build_fingerprint(fingerprint: Option<String>) -> DoctorCheck {
    let ok = fingerprint
        .as_deref()
        .is_some_and(|value| !is_generic_build_fingerprint(value));
    DoctorCheck {
        name: "build_fingerprint",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: match fingerprint.as_deref() {
            Some(value) if ok => format!("server build fingerprint is {value}"),
            Some(value) => format!("server build fingerprint is generic: {value}"),
            None => "server build fingerprint missing".to_owned(),
        },
        server_build_fingerprint: fingerprint,
        state_backend: None,
        reject_reason: None,
    }
}

pub(super) fn check_state_backend(
    state_backend: Option<String>,
    expected_backend: Option<&str>,
) -> DoctorCheck {
    let ok = match expected_backend {
        Some(expected) => state_backend
            .as_deref()
            .is_some_and(|value| value.eq_ignore_ascii_case(expected)),
        None => state_backend.is_some(),
    };
    DoctorCheck {
        name: "state_backend",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: match (state_backend.as_deref(), expected_backend) {
            (Some(value), Some(_)) if ok => format!("state backend is {value}"),
            (Some(value), Some(expected)) => {
                format!("state backend is {value}; expected {expected}")
            }
            (None, Some(expected)) => format!("state backend missing; expected {expected}"),
            (Some(value), None) => format!("state backend is {value}"),
            (None, None) => "state backend missing".to_owned(),
        },
        server_build_fingerprint: None,
        state_backend,
        reject_reason: None,
    }
}

pub(super) fn probe_body(probe: &Result<ControlPlaneRawProbe>) -> Option<&serde_json::Value> {
    probe.as_ref().ok().map(|probe| &probe.body)
}

pub(super) fn value_string(value: &serde_json::Value, key: &str) -> Option<String> {
    value.get(key)?.as_str().map(ToOwned::to_owned)
}

fn value_bool(value: &serde_json::Value, key: &str) -> Option<bool> {
    value.get(key)?.as_bool()
}

pub(super) fn first_string(values: &[Option<&serde_json::Value>], key: &str) -> Option<String> {
    values
        .iter()
        .filter_map(|value| value.and_then(|item| value_string(item, key)))
        .next()
}

pub(super) fn first_bool(values: &[Option<&serde_json::Value>], key: &str) -> Option<bool> {
    values
        .iter()
        .filter_map(|value| value.and_then(|item| value_bool(item, key)))
        .next()
}

fn is_generic_build_fingerprint(value: &str) -> bool {
    let normalized = value.trim();
    normalized.is_empty()
        || normalized == "skybridge-signaling/1.0.0"
        || normalized.ends_with("+unidentified-build")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generic_build_fingerprints_are_rejected() {
        assert!(is_generic_build_fingerprint("skybridge-signaling/1.0.0"));
        assert!(is_generic_build_fingerprint(
            "skybridge-signaling/1.0.0+unidentified-build"
        ));
        assert!(!is_generic_build_fingerprint(
            "skybridge-signaling/20260501164000-abcdef123456"
        ));
    }
}
