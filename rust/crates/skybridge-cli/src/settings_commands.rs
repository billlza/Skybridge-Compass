//! `skybridge settings` — operator-facing **request-contract** surface for the SkyBridge
//! app's controllable settings (remote-desktop quality, rendering, transport, capture, etc.).
//!
//! Design note: like the rest of the operator surface, this is deliberately **contract-only**.
//! `settings set` does NOT live-mutate a running app; it validates a requested value against
//! the published contract and emits a normalized request descriptor (source =
//! `cli_settings_request_contract_only_no_live_apply`). The app/agent remains the sole authority
//! that applies a request, so the CLI can never silently change a live session's behaviour.

use anyhow::{Result, bail};
use serde_json::{Value, json};

const SCHEMA_VERSION: u32 = 1;
const CONTRACT_SOURCE: &str = "cli_settings_request_contract_only_no_live_apply";

/// The shape of a controllable setting's accepted values.
#[derive(Clone, Copy)]
enum Kind {
    /// On/off toggle. Accepts on/off, true/false, yes/no, 1/0 (case-insensitive).
    Toggle,
    /// One of a fixed set of string choices (`allowed`).
    Enumerated,
    /// Inclusive integer range [`min`, `max`].
    IntRange,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Toggle => "toggle",
            Kind::Enumerated => "enum",
            Kind::IntRange => "int_range",
        }
    }
}

struct SettingSpec {
    key: &'static str,
    kind: Kind,
    /// Valid choices for `Kind::Enumerated`.
    allowed: &'static [&'static str],
    /// Inclusive bounds for `Kind::IntRange`.
    min: i64,
    max: i64,
    default: &'static str,
    /// Which app subsystem this request maps to, so operators know what it affects.
    applies_to: &'static str,
    description: &'static str,
}

/// The full, self-contained settings contract. Mirrors the toggles exposed in the macOS/iOS
/// app settings (remote-desktop display/quality, rendering pipeline, capture, clipboard).
const SETTINGS: &[SettingSpec] = &[
    SettingSpec {
        key: "resolution",
        kind: Kind::Enumerated,
        allowed: &["auto", "720p", "1080p", "1440p", "4k"],
        min: 0,
        max: 0,
        default: "auto",
        applies_to: "remote_desktop.display",
        description: "Requested remote-desktop capture/stream resolution preset.",
    },
    SettingSpec {
        key: "fps",
        kind: Kind::Enumerated,
        allowed: &["15", "30", "60", "120"],
        min: 0,
        max: 0,
        default: "60",
        applies_to: "remote_desktop.display",
        description: "Requested remote-desktop target frame rate.",
    },
    SettingSpec {
        key: "render-tier",
        kind: Kind::Enumerated,
        allowed: &["stable", "fluid", "reference"],
        min: 0,
        max: 0,
        default: "fluid",
        applies_to: "remote_desktop.rendering",
        description: "Requested rendering pipeline tier (stable=blit, fluid=ring buffer, reference=HDR).",
    },
    SettingSpec {
        key: "low-latency",
        kind: Kind::Toggle,
        allowed: &[],
        min: 0,
        max: 0,
        default: "off",
        applies_to: "remote_desktop.encoder",
        description: "Request the low-latency encoder rate-control path.",
    },
    SettingSpec {
        key: "encoding-profile",
        kind: Kind::Enumerated,
        allowed: &["h264", "hevc", "hevc-main10"],
        min: 0,
        max: 0,
        default: "hevc",
        applies_to: "remote_desktop.encoder",
        description: "Requested video encoding profile.",
    },
    SettingSpec {
        key: "compression-level",
        kind: Kind::IntRange,
        allowed: &[],
        min: 0,
        max: 100,
        default: "50",
        applies_to: "remote_desktop.encoder",
        description: "Requested compression level percentage (0=quality, 100=bandwidth).",
    },
    SettingSpec {
        key: "multi-monitor",
        kind: Kind::Toggle,
        allowed: &[],
        min: 0,
        max: 0,
        default: "off",
        applies_to: "remote_desktop.capture",
        description: "Request multi-monitor capture support (enables capture-display selection).",
    },
    SettingSpec {
        key: "capture-display",
        kind: Kind::IntRange,
        allowed: &[],
        min: 0,
        max: 16,
        default: "0",
        applies_to: "remote_desktop.capture",
        description: "Requested capture display index (0=main display; requires multi-monitor).",
    },
    SettingSpec {
        key: "clipboard-sync",
        kind: Kind::Toggle,
        allowed: &[],
        min: 0,
        max: 0,
        default: "off",
        applies_to: "session.clipboard",
        description: "Request clipboard synchronization over the P2P session.",
    },
];

fn find_spec(key: &str) -> Option<&'static SettingSpec> {
    SETTINGS.iter().find(|spec| spec.key == key)
}

fn spec_to_json(spec: &SettingSpec) -> Value {
    let mut entry = json!({
        "key": spec.key,
        "kind": spec.kind.as_str(),
        "default": spec.default,
        "applies_to": spec.applies_to,
        "description": spec.description,
    });
    match spec.kind {
        Kind::Enumerated => {
            entry["allowed"] = json!(spec.allowed);
        }
        Kind::IntRange => {
            entry["min"] = json!(spec.min);
            entry["max"] = json!(spec.max);
        }
        Kind::Toggle => {
            entry["allowed"] = json!(["on", "off"]);
        }
    }
    entry
}

/// Validate `value` against `spec`, returning the normalized canonical value or an error
/// describing the accepted inputs.
fn normalize_value(spec: &SettingSpec, value: &str) -> Result<String> {
    match spec.kind {
        Kind::Toggle => match value.trim().to_ascii_lowercase().as_str() {
            "on" | "true" | "yes" | "1" | "enable" | "enabled" => Ok("on".to_owned()),
            "off" | "false" | "no" | "0" | "disable" | "disabled" => Ok("off".to_owned()),
            other => bail!(
                "invalid value `{other}` for toggle `{}`; expected one of: on, off",
                spec.key
            ),
        },
        Kind::Enumerated => {
            let lowered = value.trim().to_ascii_lowercase();
            if let Some(found) = spec.allowed.iter().find(|choice| **choice == lowered) {
                Ok((*found).to_owned())
            } else {
                bail!(
                    "invalid value `{value}` for `{}`; expected one of: {}",
                    spec.key,
                    spec.allowed.join(", ")
                )
            }
        }
        Kind::IntRange => {
            let parsed: i64 = value.trim().parse().map_err(|_| {
                anyhow::anyhow!(
                    "invalid value `{value}` for `{}`; expected an integer in [{}, {}]",
                    spec.key,
                    spec.min,
                    spec.max
                )
            })?;
            if parsed < spec.min || parsed > spec.max {
                bail!(
                    "value {parsed} out of range for `{}`; expected an integer in [{}, {}]",
                    spec.key,
                    spec.min,
                    spec.max
                );
            }
            Ok(parsed.to_string())
        }
    }
}

/// `skybridge settings list` — concise list of controllable setting keys.
pub(crate) fn list(as_json: bool) -> Result<()> {
    if as_json {
        let keys: Vec<&str> = SETTINGS.iter().map(|spec| spec.key).collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({ "settings": keys }))?
        );
        return Ok(());
    }
    println!("Controllable settings ({} keys):", SETTINGS.len());
    for spec in SETTINGS {
        println!(
            "  {:<18} [{}] {}",
            spec.key,
            spec.kind.as_str(),
            spec.description
        );
    }
    Ok(())
}

/// `skybridge settings contract` — full request contract for every controllable setting.
pub(crate) fn contract(as_json: bool) -> Result<()> {
    let entries: Vec<Value> = SETTINGS.iter().map(spec_to_json).collect();
    let report = json!({
        "schema_version": SCHEMA_VERSION,
        "source": CONTRACT_SOURCE,
        "status": "request_contract_only",
        "note": "CLI emits validated request contracts; the app/agent is the sole authority that applies them.",
        "settings": entries,
    });
    if as_json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }
    println!("Settings request contract (schema v{SCHEMA_VERSION}, source={CONTRACT_SOURCE})");
    for spec in SETTINGS {
        let accepted = match spec.kind {
            Kind::Toggle => "on|off".to_owned(),
            Kind::Enumerated => spec.allowed.join("|"),
            Kind::IntRange => format!("{}..={}", spec.min, spec.max),
        };
        println!(
            "  {:<18} {:<22} default={:<8} -> {}",
            spec.key, accepted, spec.default, spec.applies_to
        );
    }
    Ok(())
}

/// `skybridge settings set <KEY> <VALUE>` — validate a requested value against the contract
/// and emit a normalized request descriptor (contract-only; not applied live).
pub(crate) fn set(key: &str, value: &str, as_json: bool) -> Result<()> {
    let Some(spec) = find_spec(key) else {
        let keys: Vec<&str> = SETTINGS.iter().map(|spec| spec.key).collect();
        bail!("unknown setting `{key}`; known keys: {}", keys.join(", "));
    };
    let normalized = normalize_value(spec, value)?;
    let request = json!({
        "schema_version": SCHEMA_VERSION,
        "source": CONTRACT_SOURCE,
        "status": "request_contract_only",
        "applied": false,
        "key": spec.key,
        "applies_to": spec.applies_to,
        "requested_value": value,
        "normalized_value": normalized,
        "note": "Validated against the settings contract; hand this descriptor to the app/agent to apply.",
    });
    if as_json {
        println!("{}", serde_json::to_string_pretty(&request)?);
        return Ok(());
    }
    println!(
        "OK  {} = {} (normalized from `{}`; target={}, not applied live)",
        spec.key, normalized, value, spec.applies_to
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_default_is_valid_under_its_own_contract() {
        for spec in SETTINGS {
            let normalized = normalize_value(spec, spec.default)
                .unwrap_or_else(|err| panic!("default for `{}` invalid: {err}", spec.key));
            // Defaults are already canonical, so normalization is idempotent.
            assert_eq!(
                normalize_value(spec, &normalized).unwrap(),
                normalized,
                "normalization not idempotent for `{}`",
                spec.key
            );
        }
    }

    #[test]
    fn toggle_accepts_synonyms_and_rejects_garbage() {
        let low_latency = find_spec("low-latency").unwrap();
        assert_eq!(normalize_value(low_latency, "TRUE").unwrap(), "on");
        assert_eq!(normalize_value(low_latency, "disabled").unwrap(), "off");
        assert!(normalize_value(low_latency, "maybe").is_err());
    }

    #[test]
    fn enum_is_case_insensitive_and_bounded() {
        let tier = find_spec("render-tier").unwrap();
        assert_eq!(normalize_value(tier, "REFERENCE").unwrap(), "reference");
        assert!(normalize_value(tier, "ultra").is_err());
    }

    #[test]
    fn int_range_enforces_bounds() {
        let compression = find_spec("compression-level").unwrap();
        assert_eq!(normalize_value(compression, "0").unwrap(), "0");
        assert_eq!(normalize_value(compression, "100").unwrap(), "100");
        assert!(normalize_value(compression, "101").is_err());
        assert!(normalize_value(compression, "-1").is_err());
        assert!(normalize_value(compression, "abc").is_err());
    }

    #[test]
    fn unknown_key_is_rejected() {
        assert!(find_spec("does-not-exist").is_none());
    }
}
