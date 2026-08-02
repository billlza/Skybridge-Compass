//! Unix-domain-socket NDJSON client for the SkyBridge app's `crossnet-control/1`
//! cross-network control surface.
//!
//! The SkyBridge Compass Pro app hosts a Unix-domain socket and speaks the
//! shared `crossnet-control/1` wire contract: NDJSON (one JSON object per line,
//! `\n`-terminated, UTF-8). Each request carries a protocol version, a unique
//! request id, a method name, and method-specific params; the server replies
//! with a single response line whose `id` matches the request.
//!
//! This crate is the Rust *client* of that contract. It exposes
//! [`default_socket_path`] plus the control methods ([`hello`], [`host`],
//! [`connect`], [`disconnect`], [`status`], [`settings_snapshot`]) as typed
//! async functions backed by serde structs. Failures are surfaced loudly via
//! `anyhow::Error` — a
//! server-reported `ok:false` becomes an error carrying the server's message,
//! and a missing/refused socket becomes a clear "app not running" hint.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[cfg(target_os = "macos")]
use serde_json::json;
#[cfg(target_os = "macos")]
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
#[cfg(target_os = "macos")]
use tokio::net::UnixStream;

/// Wire-protocol version negotiated by the `crossnet-control/1` contract.
pub const CONTROL_PROTOCOL_VERSION: u32 = 1;

/// Wire-protocol version negotiated by the `crossnet-control/1` contract.
///
/// Cross-platform constant: only the macOS socket fns consume it, so it is
/// `dead_code` on non-macOS targets where those fns are not compiled.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const PROTOCOL_VERSION: u32 = CONTROL_PROTOCOL_VERSION;

/// How long a single request/response round trip may take before we give up.
///
/// `status --watch` deliberately does not use this — it streams events for as
/// long as the caller keeps reading.
///
/// Cross-platform constant: only the macOS socket fns consume it, so it is
/// `dead_code` on non-macOS targets where those fns are not compiled.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// Maximum NDJSON response payload bytes accepted before the trailing newline.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const MAX_RESPONSE_LINE_BYTES: usize = 64 * 1024;

/// The relative path, under the user's home directory, of the control socket.
const SOCKET_RELATIVE_PATH: &str = "Library/Application Support/SkyBridge/crossnet-control.sock";

const PUBLIC_SETTINGS_ALLOWLIST: &[&str] = &[
    "logging.verbose",
    "logging.level",
    "ui.show_realtime_fps",
    "ui.top_bar_ip_location",
    "ui.top_bar_network_speed",
    "ui.top_bar_network_latency",
    "pqc.prefer_xwing_hybrid",
    "pqc.signature_algorithm",
];

/// Resolves the default path of the `crossnet-control/1` Unix-domain socket:
/// `$HOME/Library/Application Support/SkyBridge/crossnet-control.sock`.
///
/// The home directory is resolved from the `HOME` environment variable, which
/// matches how the SkyBridge app derives `Application Support` on macOS. A
/// missing, empty, or relative `HOME` fails closed instead of constructing a
/// relative socket path.
pub fn default_socket_path() -> Result<PathBuf> {
    let home = PathBuf::from(std::env::var_os("HOME").ok_or_else(|| {
        anyhow!(
            "HOME is not set; cannot resolve SkyBridge app-owned crossnet control socket (code: home_required)"
        )
    })?);
    if home.as_os_str().is_empty() {
        bail!(
            "HOME is empty; cannot resolve SkyBridge app-owned crossnet control socket (code: home_required)"
        );
    }
    if !home.is_absolute() {
        bail!(
            "HOME must be an absolute path to resolve SkyBridge app-owned crossnet control socket (code: home_required)"
        );
    }
    Ok(home.join(SOCKET_RELATIVE_PATH))
}

/// Lease duration requested when hosting a cross-network connection code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeaseMode {
    /// Short-lived lease (the server's default short policy).
    Short,
    /// Long-lived lease.
    Long,
}

impl LeaseMode {
    /// The wire string the server expects for this lease mode.
    ///
    /// Only the macOS `host` fn consumes it, so it is `dead_code` on
    /// non-macOS targets where that fn is not compiled.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    fn as_wire(self) -> &'static str {
        match self {
            LeaseMode::Short => "short",
            LeaseMode::Long => "long",
        }
    }
}

/// Result of `crossnet.hello` — the app-owned control surface and auth state.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct HelloResult {
    /// App/build version reported by the Mac app.
    pub engine_version: String,
    /// Server-side wire protocol version.
    pub proto: u32,
    /// Whether the Mac app currently has a loaded auth session.
    pub auth_loaded: bool,
    /// Whether the Mac app currently has a tenant binding.
    pub tenant_bound: bool,
}

/// Result of `crossnet.host` — a freshly issued connection code plus the
/// session it is bound to.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct HostResult {
    /// The 8-character connection code a remote peer enters to connect.
    pub code: String,
    /// The hosting session identifier, retained for backward-compatible wire
    /// decoding. CLI output should prefer `session_ref` and avoid printing this
    /// raw value.
    #[serde(default)]
    pub session_id: Option<String>,
    /// Short non-secret reference for the hosting session.
    #[serde(default)]
    pub session_ref: Option<String>,
    /// ISO-8601 expiry, or `None` if the lease does not expire.
    #[serde(default)]
    pub expires_at: Option<String>,
    /// The lease mode the server actually applied.
    pub lease_mode: String,
}

/// Result of `crossnet.connect` — the session formed by redeeming a code.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ConnectResult {
    /// The session identifier formed by the connect, retained only for
    /// backward-compatible wire decoding. CLI output must not print this raw
    /// value; successful responses require `session_ref`.
    #[serde(default)]
    pub session_id: Option<String>,
    /// Short non-secret reference for the connected session.
    #[serde(default)]
    pub session_ref: Option<String>,
    /// The remote device's display name, if the server advertised one.
    #[serde(default)]
    pub remote_device_name: Option<String>,
    /// Human-readable readiness string.
    pub readiness: String,
}

/// Result of `crossnet.disconnect`.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DisconnectResult {
    /// `true` once the control plane has torn the session down.
    pub disconnected: bool,
}

/// Result of `crossnet.status` (and the payload of each streamed `status`
/// event when watching).
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct StatusResult {
    /// Coarse connection status string.
    pub connection_status: String,
    /// Readiness string.
    pub readiness: String,
    /// The active session id, if any.
    ///
    /// Deprecated for `crossnet-control/1` status responses. Newer Mac app
    /// builds report `session_present` plus `session_ref` to avoid leaking raw
    /// session/code material in status output.
    #[serde(default)]
    pub session_id: Option<String>,
    /// Whether the app currently has an active cross-network session.
    pub session_present: bool,
    /// Short non-secret reference for the active session, if present.
    #[serde(default)]
    pub session_ref: Option<String>,
    /// The negotiated cipher suite, if a session is established.
    #[serde(default)]
    pub suite: Option<String>,
    /// Signaling-plane health, if the server reports it.
    ///
    /// Absent on streamed events (the event payload omits it); defaults to
    /// `None` there.
    #[serde(default)]
    pub signaling_health: Option<String>,
    /// Stable failure code, if the Mac app can describe a degraded or failed
    /// state without exposing raw server/runtime error text.
    #[serde(default)]
    pub failure_code: Option<String>,
    /// Stable failure class matching the public crossnet-control contract.
    #[serde(default)]
    pub failure_class: Option<String>,
    /// Whether the app currently has a loaded auth session.
    pub auth_loaded: bool,
    /// Whether the app currently has a tenant binding.
    pub tenant_bound: bool,
}

/// A single read-only Mac app settings projection entry.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SettingSnapshot {
    /// Stable settings projection id, for example `logging.verbose`.
    pub id: String,
    /// Wire-level value kind: `bool`, `string`, `int`, or `null`.
    pub value_type: String,
    /// The redacted/allowlisted value reported by the Mac app.
    pub value: Value,
    /// Whether this key can be mutated through the current CLI surface.
    pub mutable: bool,
    /// Optional caveat, for example policy preference versus runtime proof.
    #[serde(default)]
    pub note: Option<String>,
}

/// Result of `crossnet.settings.snapshot`.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SettingsSnapshotResult {
    /// Runtime authority that produced the snapshot.
    pub runtime_target: String,
    /// Effect of this request. The current supported value is `read_only`.
    pub control_effect: String,
    /// Explicit allowlist of non-secret Mac app settings projections.
    pub settings: Vec<SettingSnapshot>,
}

/// Result of `crossnet.settings.set`.
///
/// Deliberately a distinct type from [`SettingsSnapshotResult`]: the read
/// projection stays pinned to `control_effect == "read_only"` while each entry
/// explicitly reports whether it is mutable, so gaining a write verb cannot
/// loosen the read contract or bypass the mutation-specific result validation.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SettingsMutationResult {
    /// Runtime authority that applied the change.
    pub runtime_target: String,
    /// Effect of this request. The only accepted value is `mac_runtime_mutation`.
    pub control_effect: String,
    /// Settings projection id that was changed.
    pub id: String,
    /// Wire-level value kind of the change.
    pub value_type: String,
    /// The value the operator asked for.
    pub requested_value: Value,
    /// The value the Mac app read back from its runtime after applying.
    pub observed_value: Value,
    /// Whether the Mac app ran its runtime apply hook.
    pub runtime_applied: bool,
    /// Optional caveat reported by the Mac app.
    #[serde(default)]
    pub note: Option<String>,
}

/// Settings ids this CLI is willing to mutate.
///
/// A strict subset of [`PUBLIC_SETTINGS_ALLOWLIST`]: `pqc.*` entries are readable
/// but their authority is the versioned protocol identity configuration, which is
/// committed through a prepare/commit flow that can require peer re-pinning, so a
/// one-shot control write must not claim to change them.
const MUTABLE_SETTINGS_ALLOWLIST: &[&str] = &[
    "logging.verbose",
    "logging.level",
    "ui.show_realtime_fps",
    "ui.top_bar_ip_location",
    "ui.top_bar_network_speed",
    "ui.top_bar_network_latency",
];

/// Queries the app-owned control surface and auth state (`crossnet.hello`).
#[cfg(target_os = "macos")]
pub async fn hello() -> Result<HelloResult> {
    let path = default_socket_path()?;
    hello_at_path(&path).await
}

#[cfg(target_os = "macos")]
async fn hello_at_path(path: &PathBuf) -> Result<HelloResult> {
    let result = call_at_path(path, "crossnet.hello", json!({})).await?;
    parse_result("crossnet.hello", result)
}

/// Ensures the app operator socket is present and bound to a loaded Mac app
/// auth/tenant context before a mutating control method is sent.
#[cfg(target_os = "macos")]
pub async fn preflight_app_session() -> Result<HelloResult> {
    let path = default_socket_path()?;
    preflight_app_session_at_path(&path).await
}

#[cfg(target_os = "macos")]
async fn preflight_app_session_at_path(path: &PathBuf) -> Result<HelloResult> {
    let app = hello_at_path(path).await?;
    if app.proto != PROTOCOL_VERSION {
        bail!(
            "SkyBridge Mac app operator protocol mismatch: client v{} server v{} (code: protocol_version_mismatch)",
            PROTOCOL_VERSION,
            app.proto
        );
    }
    if !app.auth_loaded {
        bail!(
            "SkyBridge Mac app is running but its auth session is not loaded; sign in to the Mac app before using GUI-bound crossnet commands (code: auth_required)"
        );
    }
    if !app.tenant_bound {
        bail!(
            "SkyBridge Mac app is running but tenant binding is unavailable; sign in again before using GUI-bound crossnet commands (code: tenant_required)"
        );
    }
    Ok(app)
}

/// Hosts a cross-network connection code (`crossnet.host`).
///
/// `lease_mode` is optional — pass `None` to let the server pick its default.
#[cfg(target_os = "macos")]
pub async fn host(lease_mode: Option<LeaseMode>) -> Result<HostResult> {
    let path = default_socket_path()?;
    host_at_path(&path, lease_mode).await
}

#[cfg(target_os = "macos")]
async fn host_at_path(path: &PathBuf, lease_mode: Option<LeaseMode>) -> Result<HostResult> {
    preflight_app_session_at_path(path).await?;
    let params = match lease_mode {
        Some(mode) => json!({ "lease_mode": mode.as_wire() }),
        None => json!({}),
    };
    let result = call_at_path(path, "crossnet.host", params).await?;
    parse_result("crossnet.host", result)
}

/// Connects to a hosted cross-network code (`crossnet.connect`).
#[cfg(target_os = "macos")]
pub async fn connect(code: &str) -> Result<ConnectResult> {
    let path = default_socket_path()?;
    preflight_app_session_at_path(&path).await?;
    let result = call_at_path(&path, "crossnet.connect", json!({ "code": code })).await?;
    validate_connect_result_projection(parse_result("crossnet.connect", result)?)
}

/// Tears down the current cross-network session (`crossnet.disconnect`).
#[cfg(target_os = "macos")]
pub async fn disconnect() -> Result<DisconnectResult> {
    let path = default_socket_path()?;
    preflight_app_session_at_path(&path).await?;
    let result = call_at_path(&path, "crossnet.disconnect", json!({})).await?;
    parse_result("crossnet.disconnect", result)
}

/// Queries cross-network control status (`crossnet.status`).
///
/// When `watch` is `false`, this performs a single request/response round trip
/// and returns the current [`StatusResult`].
///
/// When `watch` is `true`, this returns a [`StatusWatch`] that yields the
/// initial status snapshot followed by each unsolicited `status` event the
/// server streams, until the connection closes.
#[cfg(target_os = "macos")]
pub async fn status(watch: bool) -> Result<StatusOutcome> {
    let path = default_socket_path()?;
    status_at_path(&path, watch).await
}

/// Reads a redacted, allowlisted Mac app settings snapshot.
#[cfg(target_os = "macos")]
pub async fn settings_snapshot() -> Result<SettingsSnapshotResult> {
    let path = default_socket_path()?;
    settings_snapshot_at_path(&path).await
}

#[cfg(target_os = "macos")]
async fn settings_snapshot_at_path(path: &PathBuf) -> Result<SettingsSnapshotResult> {
    let result = call_at_path(path, "crossnet.settings.snapshot", json!({})).await?;
    let snapshot = parse_result("crossnet.settings.snapshot", result)?;
    validate_settings_snapshot_projection(snapshot)
}

/// Applies one allowlisted Mac app setting (`crossnet.settings.set`).
///
/// `value` must already be a `bool` or `string` matching the setting's declared
/// domain; the Mac app re-validates and fails closed.
#[cfg(target_os = "macos")]
pub async fn settings_set(id: &str, value: Value) -> Result<SettingsMutationResult> {
    let path = default_socket_path()?;
    settings_set_at_path(&path, id, value).await
}

#[cfg(target_os = "macos")]
async fn settings_set_at_path(
    path: &PathBuf,
    id: &str,
    value: Value,
) -> Result<SettingsMutationResult> {
    preflight_mutable_setting(id)?;
    preflight_app_session_at_path(path).await?;
    let result = call_at_path(
        path,
        "crossnet.settings.set",
        json!({ "id": id, "value": value }),
    )
    .await?;
    validate_settings_mutation_projection(
        parse_result("crossnet.settings.set", result)?,
        id,
        &value,
    )
}

/// Refuses ids this CLI must not mutate before any socket traffic happens.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn preflight_mutable_setting(id: &str) -> Result<()> {
    if MUTABLE_SETTINGS_ALLOWLIST.contains(&id) {
        return Ok(());
    }
    if PUBLIC_SETTINGS_ALLOWLIST.contains(&id) {
        bail!(
            "setting `{id}` is readable but not mutable through crossnet-control; protocol identity settings are committed through the Mac app's prepare/commit flow, which can require peer re-pinning (code: setting_immutable)"
        );
    }
    bail!("unknown crossnet-control setting `{id}` (code: setting_not_found)")
}

/// Fails closed unless the Mac app reported a real runtime read-back of the
/// requested value.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn validate_settings_mutation_projection(
    result: SettingsMutationResult,
    id: &str,
    requested: &Value,
) -> Result<SettingsMutationResult> {
    if result.runtime_target != "mac_app_runtime" {
        bail!(
            "crossnet.settings.set reported an unexpected runtime target `{}`",
            result.runtime_target
        );
    }
    if result.control_effect != "mac_runtime_mutation" {
        bail!(
            "crossnet.settings.set reported an unexpected control effect `{}`",
            result.control_effect
        );
    }
    if result.id != id {
        bail!(
            "crossnet.settings.set reported setting `{}` but `{id}` was requested",
            result.id
        );
    }
    if &result.requested_value != requested {
        bail!("crossnet.settings.set echoed a different requested value than was sent");
    }
    if !result.runtime_applied {
        bail!(
            "crossnet.settings.set did not apply `{id}` to the Mac app runtime (code: setting_runtime_apply_failed)"
        );
    }
    if &result.observed_value != requested {
        bail!(
            "crossnet.settings.set applied `{id}` but the Mac app runtime read back a different value (code: setting_runtime_apply_failed)"
        );
    }
    Ok(result)
}

#[cfg(target_os = "macos")]
async fn status_at_path(path: &PathBuf, watch: bool) -> Result<StatusOutcome> {
    if !watch {
        let result = call_at_path(path, "crossnet.status", json!({ "watch": false })).await?;
        let snapshot = parse_result("crossnet.status", result)?;
        return Ok(StatusOutcome::Snapshot(snapshot));
    }

    let stream = connect_socket(path).await?;
    let mut reader = BufReader::new(stream);
    let id = uuid::Uuid::new_v4().to_string();
    let request = json!({
        "v": PROTOCOL_VERSION,
        "id": id,
        "method": "crossnet.status",
        "params": { "watch": true },
    });
    write_line(reader.get_mut(), &request).await?;

    // The first line back is the matching response carrying the initial
    // snapshot; subsequent lines are unsolicited `status` events.
    let line = tokio::time::timeout(REQUEST_TIMEOUT, read_line(&mut reader))
        .await
        .map_err(|_| anyhow!("crossnet.status watch timed out waiting for the initial status"))??;
    let value = parse_line(&line)?;
    let initial = parse_result("crossnet.status", decode_response(&id, value)?)?;

    Ok(StatusOutcome::Watch(StatusWatch { reader, initial }))
}

/// The two shapes a [`status`] call can return.
#[cfg(target_os = "macos")]
pub enum StatusOutcome {
    /// A single status snapshot from a non-watching call.
    Snapshot(StatusResult),
    /// A live watch stream (initial snapshot plus subsequent events).
    Watch(StatusWatch),
}

/// A live status watch stream returned by [`status`] with `watch == true`.
///
/// Call [`StatusWatch::initial`] for the snapshot delivered alongside the
/// response, then poll [`StatusWatch::next_event`] for each streamed event.
#[cfg(target_os = "macos")]
pub struct StatusWatch {
    reader: BufReader<UnixStream>,
    initial: StatusResult,
}

#[cfg(target_os = "macos")]
impl StatusWatch {
    /// The status snapshot delivered as the watch's initial response.
    pub fn initial(&self) -> &StatusResult {
        &self.initial
    }

    /// Awaits the next streamed `status` event.
    ///
    /// Returns `Ok(Some(_))` for each event, `Ok(None)` when the server closes
    /// the stream, and `Err(_)` on a malformed or non-`status` frame.
    pub async fn next_event(&mut self) -> Result<Option<StatusResult>> {
        let line = read_line(&mut self.reader).await?;
        if line.is_empty() {
            return Ok(None);
        }
        let value = parse_line(&line)?;
        let event = value
            .get("event")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("expected a `status` event frame"))?;
        if event != "status" {
            bail!("unexpected event `{event}` on crossnet.status watch stream");
        }
        let data = value
            .get("data")
            .cloned()
            .ok_or_else(|| anyhow!("crossnet.status event missing `data`"))?;
        let status: StatusResult =
            serde_json::from_value(data).context("failed to decode crossnet.status event data")?;
        Ok(Some(status))
    }
}

/// Performs a single NDJSON request/response round trip and returns the raw
/// `result` object (the `ok:false` error path is already handled here).
#[cfg(target_os = "macos")]
async fn call_at_path(path: &PathBuf, method: &str, params: Value) -> Result<Value> {
    let stream = connect_socket(path).await?;
    let mut reader = BufReader::new(stream);
    let id = uuid::Uuid::new_v4().to_string();
    let request = json!({
        "v": PROTOCOL_VERSION,
        "id": id,
        "method": method,
        "params": params,
    });
    write_line(reader.get_mut(), &request).await?;

    let line = tokio::time::timeout(REQUEST_TIMEOUT, read_line(&mut reader))
        .await
        .map_err(|_| anyhow!("{method} timed out waiting for a response"))??;
    if line.is_empty() {
        bail!("{method} closed the control socket before responding");
    }
    let value = parse_line(&line)?;
    decode_response(&id, value)
}

/// Opens the control socket, mapping a missing/refused socket to a clear
/// "launch the app" hint rather than a bare OS error.
#[cfg(target_os = "macos")]
async fn connect_socket(path: &PathBuf) -> Result<UnixStream> {
    match UnixStream::connect(path).await {
        Ok(stream) => Ok(stream),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Err(anyhow!(
            "SkyBridge app not running / control socket missing at {} — launch the SkyBridge Compass Pro app",
            path.display()
        )),
        Err(err) if err.kind() == std::io::ErrorKind::ConnectionRefused => {
            let detail = if path.exists() {
                "stale socket file exists but no process is listening"
            } else {
                "control socket refused the connection"
            };
            Err(anyhow!(
                "SkyBridge crossnet control socket unavailable at {} — {}; relaunch the SkyBridge Compass Pro app",
                path.display(),
                detail
            ))
        }
        Err(err) => Err(anyhow::Error::new(err).context(format!(
            "failed to open the crossnet control socket at {}",
            path.display()
        ))),
    }
}

/// Validates a decoded response envelope against `expected_id` and returns the
/// `result` object, bailing with the server's error message on `ok:false`.
///
/// Pure helper (no socket I/O): kept cross-platform and exercised by the
/// cross-platform unit tests, but only the macOS socket fns call it in a
/// non-test build, so it is `dead_code` on non-macOS targets.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn decode_response(expected_id: &str, value: Value) -> Result<Value> {
    let version = value
        .get("v")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("control response missing numeric `v` field"))?;
    if version != u64::from(PROTOCOL_VERSION) {
        bail!("control response protocol version `{version}` did not match `{PROTOCOL_VERSION}`");
    }

    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("control response missing string `id` field"))?;
    if id != expected_id {
        bail!("response id `{id}` did not match request id `{expected_id}`");
    }

    let ok = value
        .get("ok")
        .and_then(Value::as_bool)
        .ok_or_else(|| anyhow!("control response missing boolean `ok` field"))?;
    if ok {
        return value
            .get("result")
            .cloned()
            .ok_or_else(|| anyhow!("control response ok:true missing `result`"));
    }

    let error = value
        .get("error")
        .ok_or_else(|| anyhow!("control response ok:false missing `error`"))?;
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("control response error missing string `message`"))?;
    let code = error
        .get("code")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("control response error missing string `code`"))?;
    Err(anyhow!("{message} (code: {code})"))
}

/// Deserializes a raw `result` object into a typed struct.
///
/// Pure helper (no socket I/O): kept cross-platform and exercised by the
/// cross-platform unit tests, but only the macOS socket fns call it in a
/// non-test build, so it is `dead_code` on non-macOS targets.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn parse_result<T: for<'de> Deserialize<'de>>(method: &str, result: Value) -> Result<T> {
    serde_json::from_value(result).with_context(|| format!("failed to decode {method} result"))
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn validate_settings_snapshot_projection(
    snapshot: SettingsSnapshotResult,
) -> Result<SettingsSnapshotResult> {
    if snapshot.runtime_target != "mac_app_runtime" {
        bail!(
            "crossnet.settings snapshot was not produced by the Mac app runtime (code: settings_projection_invalid_runtime)"
        );
    }
    if snapshot.control_effect != "read_only" {
        bail!(
            "crossnet.settings snapshot was not read-only (code: settings_projection_not_read_only)"
        );
    }
    for setting in &snapshot.settings {
        if setting.mutable {
            bail!(
                "crossnet.settings snapshot exposed a mutable setting through the read-only CLI surface (code: settings_projection_mutable)"
            );
        }
        if !PUBLIC_SETTINGS_ALLOWLIST.contains(&setting.id.as_str()) {
            bail!(
                "crossnet.settings snapshot included a setting outside the public allowlist (code: settings_projection_not_allowlisted)"
            );
        }
    }
    Ok(snapshot)
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn validate_connect_result_projection(result: ConnectResult) -> Result<ConnectResult> {
    let missing_session_ref = match result.session_ref.as_deref() {
        Some(session_ref) => session_ref.trim().is_empty(),
        None => true,
    };
    if missing_session_ref {
        bail!(
            "crossnet.connect response omitted the redacted session_ref required for public CLI output (code: session_ref_required)"
        );
    }
    Ok(result)
}

/// Writes one NDJSON line (`<json>\n`) and flushes it.
#[cfg(target_os = "macos")]
async fn write_line(stream: &mut UnixStream, value: &Value) -> Result<()> {
    let mut line = serde_json::to_vec(value).context("failed to serialize control request")?;
    line.push(b'\n');
    stream
        .write_all(&line)
        .await
        .context("failed to write control request")?;
    stream
        .flush()
        .await
        .context("failed to flush control request")?;
    Ok(())
}

/// Reads one `\n`-terminated line; returns an empty string at EOF.
#[cfg(target_os = "macos")]
async fn read_line(reader: &mut BufReader<UnixStream>) -> Result<String> {
    let mut line = Vec::new();
    loop {
        let available = reader
            .fill_buf()
            .await
            .context("failed to read control response")?;
        if available.is_empty() {
            if line.is_empty() {
                return Ok(String::new());
            }
            bail!(
                "crossnet-control response closed before newline terminator (code: response_unterminated)"
            );
        }

        let newline_index = available.iter().position(|byte| *byte == b'\n');
        let bytes_to_consume = newline_index.map_or(available.len(), |index| index + 1);
        let payload_bytes_to_append = newline_index.map_or(bytes_to_consume, |index| index);
        if line.len() + payload_bytes_to_append > MAX_RESPONSE_LINE_BYTES {
            bail!(
                "crossnet-control response line exceeded {MAX_RESPONSE_LINE_BYTES} bytes (code: response_too_large)"
            );
        }

        line.extend_from_slice(&available[..bytes_to_consume]);
        reader.consume(bytes_to_consume);
        if newline_index.is_some() {
            return String::from_utf8(line)
                .context("crossnet-control response line was not valid UTF-8");
        }
    }
}

/// Parses one NDJSON line into a JSON value.
///
/// Pure helper (no socket I/O): kept cross-platform, but only the unix socket
/// fns call it in a non-test build, so it is `dead_code` on non-macOS targets.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn parse_line(line: &str) -> Result<Value> {
    serde_json::from_str(line.trim_end_matches(['\n', '\r']))
        .context("failed to parse control response line")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[cfg(target_os = "macos")]
    use std::ffi::OsString;
    #[cfg(target_os = "macos")]
    use std::sync::Mutex;
    #[cfg(target_os = "macos")]
    use tokio::net::UnixListener;

    #[cfg(target_os = "macos")]
    static HOME_ENV_LOCK: Mutex<()> = Mutex::new(());

    #[cfg(target_os = "macos")]
    struct HomeEnvRestore(Option<OsString>);

    #[cfg(target_os = "macos")]
    impl HomeEnvRestore {
        fn capture() -> Self {
            Self(std::env::var_os("HOME"))
        }
    }

    #[cfg(target_os = "macos")]
    impl Drop for HomeEnvRestore {
        fn drop(&mut self) {
            // SAFETY: tests using HOME_ENV_LOCK mutate HOME serially.
            unsafe {
                match &self.0 {
                    Some(value) => std::env::set_var("HOME", value),
                    None => std::env::remove_var("HOME"),
                }
            }
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn default_socket_path_uses_home_application_support() -> Result<()> {
        let _guard = HOME_ENV_LOCK.lock().unwrap_or_else(|err| err.into_inner());
        let _restore = HomeEnvRestore::capture();
        // SAFETY: single-threaded test; we set and read HOME synchronously.
        unsafe {
            std::env::set_var("HOME", "/tmp/skybridge-test-home");
        }
        let path = default_socket_path()?;
        assert_eq!(
            path,
            PathBuf::from(
                "/tmp/skybridge-test-home/Library/Application Support/SkyBridge/crossnet-control.sock"
            )
        );
        Ok(())
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn default_socket_path_fails_when_home_missing() {
        let _guard = HOME_ENV_LOCK.lock().unwrap_or_else(|err| err.into_inner());
        let _restore = HomeEnvRestore::capture();
        // SAFETY: tests using HOME_ENV_LOCK mutate HOME serially.
        unsafe {
            std::env::remove_var("HOME");
        }
        let error = default_socket_path().expect_err("missing HOME must fail closed");
        let message = error.to_string();
        assert!(message.contains("HOME is not set"), "{message}");
        assert!(message.contains("home_required"), "{message}");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn default_socket_path_fails_when_home_empty_or_relative() {
        let _guard = HOME_ENV_LOCK.lock().unwrap_or_else(|err| err.into_inner());
        let _restore = HomeEnvRestore::capture();
        // SAFETY: tests using HOME_ENV_LOCK mutate HOME serially.
        unsafe {
            std::env::set_var("HOME", "");
        }
        let empty_error = default_socket_path().expect_err("empty HOME must fail closed");
        let empty_message = empty_error.to_string();
        assert!(empty_message.contains("HOME is empty"), "{empty_message}");
        assert!(empty_message.contains("home_required"), "{empty_message}");

        // SAFETY: tests using HOME_ENV_LOCK mutate HOME serially.
        unsafe {
            std::env::set_var("HOME", "relative-home");
        }
        let relative_error = default_socket_path().expect_err("relative HOME must fail closed");
        let relative_message = relative_error.to_string();
        assert!(
            relative_message.contains("HOME must be an absolute path"),
            "{relative_message}"
        );
        assert!(
            relative_message.contains("home_required"),
            "{relative_message}"
        );
    }

    #[test]
    fn decode_response_returns_result_on_ok() {
        let value = json!({ "v": 1, "id": "abc", "ok": true, "result": { "disconnected": true } });
        let result = decode_response("abc", value).expect("ok response should decode");
        assert_eq!(result, json!({ "disconnected": true }));
    }

    #[test]
    fn decode_response_bails_with_server_message_on_error() {
        let value = json!({
            "v": 1,
            "id": "abc",
            "ok": false,
            "error": { "code": "auth_missing", "message": "no logged-in keychain session" }
        });
        let err = decode_response("abc", value).expect_err("error response should bail");
        let message = err.to_string();
        assert!(
            message.contains("no logged-in keychain session"),
            "{message}"
        );
        assert!(message.contains("auth_missing"), "{message}");
    }

    #[test]
    fn decode_response_rejects_mismatched_id() {
        let value = json!({ "v": 1, "id": "other", "ok": true, "result": {} });
        let err = decode_response("expected", value).expect_err("id mismatch should bail");
        assert!(err.to_string().contains("did not match"), "{err}");
    }

    #[test]
    fn decode_response_rejects_missing_id_and_protocol_mismatch() {
        let missing_id = json!({ "v": 1, "ok": true, "result": {} });
        let missing_id_error =
            decode_response("expected", missing_id).expect_err("missing id must fail closed");
        assert!(
            missing_id_error
                .to_string()
                .contains("missing string `id` field"),
            "{missing_id_error}"
        );

        let wrong_version = json!({ "v": 2, "id": "expected", "ok": true, "result": {} });
        let wrong_version_error =
            decode_response("expected", wrong_version).expect_err("version mismatch must fail");
        assert!(
            wrong_version_error
                .to_string()
                .contains("protocol version `2` did not match `1`"),
            "{wrong_version_error}"
        );
    }

    #[test]
    fn host_result_round_trips() {
        let value = json!({
            "code": "ABCD1234",
            "session_id": "sess-1",
            "expires_at": null,
            "lease_mode": "short"
        });
        let parsed: HostResult =
            parse_result("crossnet.host", value).expect("host result should decode");
        assert_eq!(parsed.code, "ABCD1234");
        assert_eq!(parsed.session_id.as_deref(), Some("sess-1"));
        assert!(parsed.session_ref.is_none());
        assert!(parsed.expires_at.is_none());
        assert_eq!(parsed.lease_mode, "short");
    }

    #[test]
    fn status_result_decodes_auth_and_tenant_flags() {
        let value = json!({
            "connection_status": "idle",
            "readiness": "idle",
            "session_present": true,
            "session_ref": "abcd1234",
            "suite": null,
            "signaling_health": "healthy",
            "failure_code": "auth_required",
            "failure_class": "operator_precondition",
            "auth_loaded": true,
            "tenant_bound": false
        });
        let parsed: StatusResult =
            parse_result("crossnet.status", value).expect("status result should decode");
        assert!(parsed.auth_loaded);
        assert!(!parsed.tenant_bound);
        assert!(parsed.session_present);
        assert_eq!(parsed.session_ref.as_deref(), Some("abcd1234"));
        assert!(parsed.session_id.is_none());
        assert_eq!(parsed.signaling_health.as_deref(), Some("healthy"));
        assert_eq!(parsed.failure_code.as_deref(), Some("auth_required"));
        assert_eq!(
            parsed.failure_class.as_deref(),
            Some("operator_precondition")
        );
    }

    #[test]
    fn hello_result_rejects_missing_auth_or_tenant_fields() {
        let missing_auth = json!({
            "engine_version": "test-app",
            "proto": PROTOCOL_VERSION,
            "tenant_bound": true
        });
        let auth_error = parse_result::<HelloResult>("crossnet.hello", missing_auth)
            .expect_err("missing auth_loaded must be a schema error");
        assert!(
            auth_error.to_string().contains("failed to decode"),
            "{auth_error}"
        );

        let missing_tenant = json!({
            "engine_version": "test-app",
            "proto": PROTOCOL_VERSION,
            "auth_loaded": true
        });
        let tenant_error = parse_result::<HelloResult>("crossnet.hello", missing_tenant)
            .expect_err("missing tenant_bound must be a schema error");
        assert!(
            tenant_error.to_string().contains("failed to decode"),
            "{tenant_error}"
        );
    }

    #[test]
    fn connect_result_requires_redacted_session_ref() {
        let legacy_only = ConnectResult {
            session_id: Some("session-token-secret".to_owned()),
            session_ref: None,
            remote_device_name: Some("MacBook".to_owned()),
            readiness: "handshake_complete".to_owned(),
        };
        let error = validate_connect_result_projection(legacy_only)
            .expect_err("connect result must fail closed without session_ref");
        let message = error.to_string();
        assert!(message.contains("session_ref_required"), "{message}");
        assert!(!message.contains("session-token-secret"), "{message}");

        let redacted = ConnectResult {
            session_id: Some("session-token-secret".to_owned()),
            session_ref: Some("sha256:connectref".to_owned()),
            remote_device_name: Some("MacBook".to_owned()),
            readiness: "handshake_complete".to_owned(),
        };
        let validated = validate_connect_result_projection(redacted)
            .expect("redacted session_ref should satisfy public output contract");
        assert_eq!(validated.session_ref.as_deref(), Some("sha256:connectref"));
    }

    #[test]
    fn settings_snapshot_decodes_read_only_projection() {
        let value = json!({
            "runtime_target": "mac_app_runtime",
            "control_effect": "read_only",
            "settings": [
                {
                    "id": "logging.verbose",
                    "value_type": "bool",
                    "value": true,
                    "mutable": false
                },
                {
                    "id": "pqc.signature_algorithm",
                    "value_type": "string",
                    "value": "ML-DSA-65",
                    "mutable": false,
                    "note": "policy_preference_not_runtime_proof"
                }
            ]
        });
        let parsed: SettingsSnapshotResult =
            parse_result("crossnet.settings.snapshot", value).expect("settings should decode");
        assert_eq!(parsed.runtime_target, "mac_app_runtime");
        assert_eq!(parsed.control_effect, "read_only");
        assert_eq!(parsed.settings.len(), 2);
        assert!(!parsed.settings[0].mutable);
        assert_eq!(parsed.settings[0].value, Value::Bool(true));
        assert_eq!(
            parsed.settings[1].note.as_deref(),
            Some("policy_preference_not_runtime_proof")
        );
        validate_settings_snapshot_projection(parsed)
            .expect("allowlisted read-only settings should pass");
    }

    #[test]
    fn mutable_setting_preflight_separates_unknown_from_immutable() {
        assert!(preflight_mutable_setting("logging.level").is_ok());
        assert!(preflight_mutable_setting("ui.top_bar_ip_location").is_ok());

        // A readable-but-immutable id must not be reported as unknown: the
        // operator needs to learn that the value exists and why it is refused.
        let immutable = preflight_mutable_setting("pqc.signature_algorithm")
            .expect_err("pqc settings must not be mutable");
        assert!(
            immutable.to_string().contains("setting_immutable"),
            "{immutable}"
        );
        assert!(
            immutable.to_string().contains("peer re-pinning"),
            "{immutable}"
        );

        let unknown =
            preflight_mutable_setting("logging.nope").expect_err("unknown ids must fail closed");
        assert!(
            unknown.to_string().contains("setting_not_found"),
            "{unknown}"
        );

        // Every mutable id must also be readable, otherwise the CLI could write a
        // key the snapshot never surfaces.
        for id in MUTABLE_SETTINGS_ALLOWLIST {
            assert!(
                PUBLIC_SETTINGS_ALLOWLIST.contains(id),
                "{id} is mutable but not readable"
            );
        }
    }

    #[test]
    fn settings_mutation_projection_requires_a_real_runtime_read_back() {
        let requested = Value::Bool(true);
        let ok = SettingsMutationResult {
            runtime_target: "mac_app_runtime".to_owned(),
            control_effect: "mac_runtime_mutation".to_owned(),
            id: "logging.verbose".to_owned(),
            value_type: "bool".to_owned(),
            requested_value: requested.clone(),
            observed_value: requested.clone(),
            runtime_applied: true,
            note: None,
        };
        assert!(
            validate_settings_mutation_projection(ok.clone(), "logging.verbose", &requested)
                .is_ok()
        );

        // Read-back disagreement must fail closed rather than report success.
        let drifted = SettingsMutationResult {
            observed_value: Value::Bool(false),
            ..ok.clone()
        };
        let drifted_error =
            validate_settings_mutation_projection(drifted, "logging.verbose", &requested)
                .expect_err("a differing read-back must fail closed");
        assert!(
            drifted_error
                .to_string()
                .contains("setting_runtime_apply_failed"),
            "{drifted_error}"
        );

        // Claiming a value without running the apply hook must fail closed.
        let unapplied = SettingsMutationResult {
            runtime_applied: false,
            ..ok.clone()
        };
        assert!(
            validate_settings_mutation_projection(unapplied, "logging.verbose", &requested)
                .is_err()
        );

        // A read-only effect must never be accepted on the mutation path.
        let read_only = SettingsMutationResult {
            control_effect: "read_only".to_owned(),
            ..ok.clone()
        };
        assert!(
            validate_settings_mutation_projection(read_only, "logging.verbose", &requested)
                .is_err()
        );

        // The server must not answer about a different setting than was asked.
        let swapped = SettingsMutationResult {
            id: "logging.level".to_owned(),
            ..ok
        };
        assert!(
            validate_settings_mutation_projection(swapped, "logging.verbose", &requested).is_err()
        );
    }

    #[test]
    fn settings_snapshot_projection_validation_fails_closed_without_secret_echo() {
        let mutable = SettingsSnapshotResult {
            runtime_target: "mac_app_runtime".to_owned(),
            control_effect: "read_only".to_owned(),
            settings: vec![SettingSnapshot {
                id: "logging.verbose".to_owned(),
                value_type: "bool".to_owned(),
                value: Value::String("session-token-secret".to_owned()),
                mutable: true,
                note: None,
            }],
        };
        let mutable_error = validate_settings_snapshot_projection(mutable)
            .expect_err("mutable settings must be rejected by the read-only client");
        let mutable_message = mutable_error.to_string();
        assert!(
            mutable_message.contains("settings_projection_mutable"),
            "{mutable_message}"
        );
        assert!(
            !mutable_message.contains("session-token-secret"),
            "{mutable_message}"
        );

        let secret_id = SettingsSnapshotResult {
            runtime_target: "mac_app_runtime".to_owned(),
            control_effect: "read_only".to_owned(),
            settings: vec![SettingSnapshot {
                id: "auth.token".to_owned(),
                value_type: "string".to_owned(),
                value: Value::String("session-token-secret".to_owned()),
                mutable: false,
                note: None,
            }],
        };
        let secret_id_error = validate_settings_snapshot_projection(secret_id)
            .expect_err("non-allowlisted settings must be rejected");
        let secret_id_message = secret_id_error.to_string();
        assert!(
            secret_id_message.contains("settings_projection_not_allowlisted"),
            "{secret_id_message}"
        );
        assert!(
            !secret_id_message.contains("auth.token"),
            "{secret_id_message}"
        );
        assert!(
            !secret_id_message.contains("session-token-secret"),
            "{secret_id_message}"
        );

        let wrong_runtime = SettingsSnapshotResult {
            runtime_target: "ios_app_runtime".to_owned(),
            control_effect: "read_only".to_owned(),
            settings: Vec::new(),
        };
        let wrong_runtime_error = validate_settings_snapshot_projection(wrong_runtime)
            .expect_err("settings must come from the Mac app runtime");
        let wrong_runtime_message = wrong_runtime_error.to_string();
        assert!(
            wrong_runtime_message.contains("settings_projection_invalid_runtime"),
            "{wrong_runtime_message}"
        );
        assert!(
            !wrong_runtime_message.contains("ios_app_runtime"),
            "{wrong_runtime_message}"
        );
    }

    #[test]
    fn decode_response_missing_ok_does_not_echo_payload() {
        let value = json!({
            "v": 1,
            "id": "abc",
            "result": { "token": "secret-token" }
        });
        let err = decode_response("abc", value).expect_err("missing ok must fail");
        let message = err.to_string();
        assert!(message.contains("missing boolean `ok` field"), "{message}");
        assert!(!message.contains("secret-token"), "{message}");
    }

    #[cfg(target_os = "macos")]
    #[tokio::test(flavor = "current_thread")]
    async fn host_preflights_app_session_and_writes_host_request() -> Result<()> {
        let socket_path = make_test_socket_path("host-preflight")?;
        let server = spawn_fake_server(&socket_path, 2).await?;

        let result = host_at_path(&socket_path, Some(LeaseMode::Long)).await?;
        assert_eq!(result.code, "ABCD1234");
        assert_eq!(result.session_id.as_deref(), Some("session-host"));
        assert_eq!(result.session_ref.as_deref(), Some("sha256:hostref"));
        assert_eq!(result.lease_mode, "long");

        let requests = server.await.context("fake server task failed")??;
        assert_eq!(requests.len(), 2);
        assert_eq!(request_method(&requests[0]), Some("crossnet.hello"));
        assert_eq!(request_method(&requests[1]), Some("crossnet.host"));
        assert_eq!(
            requests[1]
                .get("params")
                .and_then(|params| params.get("lease_mode"))
                .and_then(Value::as_str),
            Some("long")
        );
        cleanup_socket_home(&socket_path);
        Ok(())
    }

    #[cfg(target_os = "macos")]
    #[tokio::test(flavor = "current_thread")]
    async fn settings_snapshot_at_path_reads_without_mutation_preflight() -> Result<()> {
        let socket_path = make_test_socket_path("settings-snapshot")?;
        let server = spawn_fake_server_with_auth(&socket_path, 1, false, false).await?;

        let snapshot = settings_snapshot_at_path(&socket_path).await?;
        assert_eq!(snapshot.runtime_target, "mac_app_runtime");
        assert_eq!(snapshot.control_effect, "read_only");
        assert!(snapshot.settings.iter().all(|setting| !setting.mutable));
        assert!(
            snapshot
                .settings
                .iter()
                .any(|setting| setting.id == "logging.verbose")
        );

        let requests = server.await.context("fake server task failed")??;
        assert_eq!(requests.len(), 1);
        assert_eq!(
            request_method(&requests[0]),
            Some("crossnet.settings.snapshot")
        );
        cleanup_socket_home(&socket_path);
        Ok(())
    }

    #[cfg(target_os = "macos")]
    #[tokio::test(flavor = "current_thread")]
    async fn host_rejects_missing_app_auth_before_mutation() -> Result<()> {
        let socket_path = make_test_socket_path("host-auth-required")?;
        let server = spawn_fake_server_with_auth(&socket_path, 1, false, true).await?;

        let error = host_at_path(&socket_path, None)
            .await
            .expect_err("host must preflight app auth");
        let message = error.to_string();
        assert!(message.contains("auth session is not loaded"), "{message}");
        assert!(message.contains("auth_required"), "{message}");

        let requests = server.await.context("fake server task failed")??;
        assert_eq!(requests.len(), 1);
        assert_eq!(request_method(&requests[0]), Some("crossnet.hello"));
        cleanup_socket_home(&socket_path);
        Ok(())
    }

    #[cfg(target_os = "macos")]
    #[tokio::test(flavor = "current_thread")]
    async fn preflight_rejects_missing_tenant_before_mutation() -> Result<()> {
        let socket_path = make_test_socket_path("tenant-required")?;
        let server = spawn_fake_server_with_auth(&socket_path, 1, true, false).await?;

        let error = preflight_app_session_at_path(&socket_path)
            .await
            .expect_err("preflight must require Mac app tenant binding");
        let message = error.to_string();
        assert!(
            message.contains("tenant binding is unavailable"),
            "{message}"
        );
        assert!(message.contains("tenant_required"), "{message}");

        let requests = server.await.context("fake server task failed")??;
        assert_eq!(requests.len(), 1);
        assert_eq!(request_method(&requests[0]), Some("crossnet.hello"));
        cleanup_socket_home(&socket_path);
        Ok(())
    }

    #[cfg(target_os = "macos")]
    #[tokio::test(flavor = "current_thread")]
    async fn status_at_path_decodes_read_only_mac_app_projection() -> Result<()> {
        let socket_path = make_test_socket_path("status-read-only")?;
        let server = spawn_fake_server(&socket_path, 1).await?;

        let outcome = status_at_path(&socket_path, false).await?;
        let StatusOutcome::Snapshot(status) = outcome else {
            panic!("non-watch status should return a snapshot");
        };
        assert_eq!(status.connection_status, "idle");
        assert_eq!(status.readiness, "idle");
        assert!(!status.session_present);
        assert_eq!(status.signaling_health.as_deref(), Some("healthy"));
        assert!(status.auth_loaded);
        assert!(status.tenant_bound);

        let requests = server.await.context("fake server task failed")??;
        assert_eq!(requests.len(), 1);
        assert_eq!(request_method(&requests[0]), Some("crossnet.status"));
        cleanup_socket_home(&socket_path);
        Ok(())
    }

    #[cfg(target_os = "macos")]
    #[tokio::test(flavor = "current_thread")]
    async fn missing_socket_fails_without_success_payload() -> Result<()> {
        let socket_path = make_test_socket_path("missing-socket")?;

        let error = match status_at_path(&socket_path, false).await {
            Ok(_) => panic!("missing app socket must fail closed"),
            Err(error) => error,
        };
        let message = error.to_string();
        assert!(message.contains("control socket missing"), "{message}");
        assert!(!message.contains("\"ok\":true"), "{message}");
        cleanup_socket_home(&socket_path);
        Ok(())
    }

    #[cfg(target_os = "macos")]
    #[tokio::test(flavor = "current_thread")]
    async fn read_line_accepts_exact_response_limit() -> Result<()> {
        let socket_path = make_test_socket_path("exact-response-line")?;
        let mut bytes = vec![b'a'; MAX_RESPONSE_LINE_BYTES];
        bytes.push(b'\n');
        let server = spawn_line_writer(&socket_path, bytes).await?;

        let stream = connect_socket(&socket_path).await?;
        let mut reader = BufReader::new(stream);
        let line = read_line(&mut reader).await?;
        assert_eq!(line.len(), MAX_RESPONSE_LINE_BYTES + 1);
        assert!(line.ends_with('\n'));

        server.await.context("line writer task failed")??;
        cleanup_socket_home(&socket_path);
        Ok(())
    }

    #[cfg(target_os = "macos")]
    #[tokio::test(flavor = "current_thread")]
    async fn read_line_rejects_oversized_response_without_echoing_payload() -> Result<()> {
        let socket_path = make_test_socket_path("oversized-response-line")?;
        let mut bytes = vec![b'a'; MAX_RESPONSE_LINE_BYTES + 1];
        bytes.extend_from_slice(b"secret-token\n");
        let server = spawn_line_writer(&socket_path, bytes).await?;

        let stream = connect_socket(&socket_path).await?;
        let mut reader = BufReader::new(stream);
        let error = read_line(&mut reader)
            .await
            .expect_err("oversized response line must fail closed");
        let message = error.to_string();
        assert!(message.contains("response_too_large"), "{message}");
        assert!(!message.contains("secret-token"), "{message}");

        server.await.context("line writer task failed")??;
        cleanup_socket_home(&socket_path);
        Ok(())
    }

    #[cfg(target_os = "macos")]
    fn make_test_socket_path(label: &str) -> Result<PathBuf> {
        let uuid = uuid::Uuid::new_v4().to_string();
        let suffix = uuid
            .get(..8)
            .ok_or_else(|| anyhow!("failed to build test home suffix"))?;
        Ok(PathBuf::from("/tmp")
            .join(format!("sbc-{label}-{suffix}"))
            .join(SOCKET_RELATIVE_PATH))
    }

    #[cfg(target_os = "macos")]
    fn cleanup_socket_home(socket_path: &std::path::Path) {
        if let Some(home) = socket_path
            .ancestors()
            .find(|candidate| {
                candidate
                    .file_name()
                    .is_some_and(|name| name.to_string_lossy() == "Library")
            })
            .and_then(|library| library.parent())
        {
            let _ = std::fs::remove_dir_all(home);
        }
    }

    #[cfg(target_os = "macos")]
    async fn spawn_fake_server(
        socket_path: &std::path::Path,
        expected_requests: usize,
    ) -> Result<tokio::task::JoinHandle<Result<Vec<Value>>>> {
        spawn_fake_server_with_auth(socket_path, expected_requests, true, true).await
    }

    #[cfg(target_os = "macos")]
    async fn spawn_fake_server_with_auth(
        socket_path: &std::path::Path,
        expected_requests: usize,
        auth_loaded: bool,
        tenant_bound: bool,
    ) -> Result<tokio::task::JoinHandle<Result<Vec<Value>>>> {
        let parent = socket_path
            .parent()
            .ok_or_else(|| anyhow!("default socket path missing parent"))?;
        std::fs::create_dir_all(parent)?;
        let _ = std::fs::remove_file(socket_path);
        let listener = UnixListener::bind(socket_path)?;
        Ok(tokio::spawn(async move {
            let mut requests = Vec::new();
            for _ in 0..expected_requests {
                let (stream, _) = listener.accept().await?;
                let mut reader = BufReader::new(stream);
                let line = read_line(&mut reader).await?;
                let request = parse_line(&line)?;
                let id = request
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("request missing id"))?
                    .to_owned();
                let method = request
                    .get("method")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("request missing method"))?
                    .to_owned();
                let result = match method.as_str() {
                    "crossnet.hello" => json!({
                        "engine_version": "test-app",
                        "proto": PROTOCOL_VERSION,
                        "auth_loaded": auth_loaded,
                        "tenant_bound": tenant_bound
                    }),
                    "crossnet.host" => json!({
                        "code": "ABCD1234",
                        "session_id": "session-host",
                        "session_ref": "sha256:hostref",
                        "expires_at": null,
                        "lease_mode": "long"
                    }),
                    "crossnet.connect" => json!({
                        "session_id": "session-connect-secret",
                        "session_ref": "sha256:connectref",
                        "remote_device_name": "Test Mac",
                        "readiness": "handshake_complete"
                    }),
                    "crossnet.status" => json!({
                        "connection_status": "idle",
                        "readiness": "idle",
                        "session_present": false,
                        "session_ref": null,
                        "suite": null,
                        "signaling_health": "healthy",
                        "failure_code": null,
                        "failure_class": null,
                        "auth_loaded": auth_loaded,
                        "tenant_bound": tenant_bound
                    }),
                    "crossnet.settings.snapshot" => json!({
                        "runtime_target": "mac_app_runtime",
                        "control_effect": "read_only",
                        "settings": [
                            {
                                "id": "logging.verbose",
                                "value_type": "bool",
                                "value": true,
                                "mutable": false
                            },
                            {
                                "id": "pqc.signature_algorithm",
                                "value_type": "string",
                                "value": "ML-DSA-65",
                                "mutable": false,
                                "note": "policy_preference_not_runtime_proof"
                            }
                        ]
                    }),
                    other => bail!("unexpected method {other}"),
                };
                let response = json!({
                    "v": PROTOCOL_VERSION,
                    "id": id,
                    "ok": true,
                    "result": result
                });
                write_line(reader.get_mut(), &response).await?;
                requests.push(request);
            }
            Ok(requests)
        }))
    }

    #[cfg(target_os = "macos")]
    async fn spawn_line_writer(
        socket_path: &std::path::Path,
        bytes: Vec<u8>,
    ) -> Result<tokio::task::JoinHandle<Result<()>>> {
        let parent = socket_path
            .parent()
            .ok_or_else(|| anyhow!("test socket path missing parent"))?;
        std::fs::create_dir_all(parent)?;
        let _ = std::fs::remove_file(socket_path);
        let listener = UnixListener::bind(socket_path)?;
        Ok(tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await?;
            stream.write_all(&bytes).await?;
            stream.flush().await?;
            Ok(())
        }))
    }

    #[cfg(target_os = "macos")]
    fn request_method(value: &Value) -> Option<&str> {
        value.get("method").and_then(Value::as_str)
    }
}
