use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow, bail};
use serde::Serialize;
use serde_json::{Value, json};
use time::OffsetDateTime;

use crate::CodeCurrentArgs;

#[derive(Debug, serde::Deserialize, Serialize)]
struct ConnectionCodeSnapshot {
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    code: String,
    #[serde(rename = "sessionId")]
    session_id: String,
    #[serde(rename = "expiresAt")]
    expires_at: Option<String>,
    #[serde(rename = "leaseMode")]
    lease_mode: Option<String>,
    #[serde(rename = "deviceId")]
    device_id: Option<String>,
    #[serde(rename = "protocolPublicKeyFingerprint")]
    protocol_public_key_fingerprint: Option<String>,
    #[serde(rename = "generatedAt")]
    generated_at: Option<String>,
}

pub(crate) async fn code_current(args: CodeCurrentArgs) -> Result<()> {
    let snapshot_path = args
        .snapshot
        .unwrap_or_else(default_connection_code_snapshot_path);
    let snapshot = read_connection_code_snapshot(&snapshot_path)?;
    if args.output.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&connection_code_snapshot_json(
                &snapshot,
                &snapshot_path
            ))?
        );
    } else {
        print!(
            "{}",
            format_connection_code_snapshot_text(&snapshot, &snapshot_path)
        );
    }
    Ok(())
}

fn connection_code_snapshot_json(snapshot: &ConnectionCodeSnapshot, snapshot_path: &Path) -> Value {
    json!({
        "code": snapshot.code,
        "session_id": snapshot.session_id,
        "expires_at": snapshot.expires_at,
        "lease_mode": snapshot.lease_mode,
        "device_id": snapshot.device_id,
        "protocol_public_key_fingerprint": snapshot.protocol_public_key_fingerprint,
        "generated_at": snapshot.generated_at,
        "snapshot": snapshot_path,
    })
}

fn format_connection_code_snapshot_text(
    snapshot: &ConnectionCodeSnapshot,
    snapshot_path: &Path,
) -> String {
    let mut lines = vec![
        format!("Code: {}", snapshot.code),
        format!("Session ID: {}", snapshot.session_id),
    ];
    if let Some(expires_at) = snapshot.expires_at.as_deref() {
        lines.push(format!("Expires At: {expires_at}"));
    }
    lines.push(format!("Snapshot: {}", snapshot_path.display()));
    lines.push(String::new());
    lines.join("\n")
}

fn default_connection_code_snapshot_path() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library")
        .join("Application Support")
        .join("SkyBridge")
        .join("connection-code-latest.json")
}

fn read_connection_code_snapshot(path: &Path) -> Result<ConnectionCodeSnapshot> {
    let data = fs::read_to_string(path).map_err(|error| {
        anyhow!(
            "connection code snapshot unavailable at {}: {}",
            path.display(),
            error
        )
    })?;
    let snapshot: ConnectionCodeSnapshot = serde_json::from_str(&data).map_err(|error| {
        anyhow!(
            "connection code snapshot is malformed at {}: {}",
            path.display(),
            error
        )
    })?;
    if snapshot.code.trim().is_empty() || snapshot.session_id.trim().is_empty() {
        bail!(
            "connection code snapshot at {} is incomplete",
            path.display()
        );
    }
    if let Some(expires_at) = snapshot.expires_at.as_deref() {
        let parsed =
            OffsetDateTime::parse(expires_at, &time::format_description::well_known::Rfc3339)
                .map_err(|error| {
                    anyhow!(
                        "connection code snapshot has invalid expires_at {}: {}",
                        expires_at,
                        error
                    )
                })?;
        if parsed <= OffsetDateTime::now_utc() {
            bail!("connection code snapshot at {} is expired", path.display());
        }
    }
    Ok(snapshot)
}

#[cfg(test)]
mod tests;
