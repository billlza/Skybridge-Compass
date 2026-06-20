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
//! [`connect`], [`disconnect`], [`status`]) as typed async functions backed by
//! serde structs. Failures are surfaced loudly via `anyhow::Error` — a
//! server-reported `ok:false` becomes an error carrying the server's message,
//! and a missing/refused socket becomes a clear "app not running" hint.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[cfg(unix)]
use serde_json::json;
#[cfg(unix)]
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
#[cfg(unix)]
use tokio::net::UnixStream;

/// Wire-protocol version negotiated by the `crossnet-control/1` contract.
///
/// Cross-platform constant: only the unix socket fns consume it, so it is
/// `dead_code` on non-unix targets where those fns are not compiled.
#[cfg_attr(not(unix), allow(dead_code))]
const PROTOCOL_VERSION: u32 = 1;

/// How long a single request/response round trip may take before we give up.
///
/// `status --watch` deliberately does not use this — it streams events for as
/// long as the caller keeps reading.
///
/// Cross-platform constant: only the unix socket fns consume it, so it is
/// `dead_code` on non-unix targets where those fns are not compiled.
#[cfg_attr(not(unix), allow(dead_code))]
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// The relative path, under the user's home directory, of the control socket.
const SOCKET_RELATIVE_PATH: &str = "Library/Application Support/SkyBridge/crossnet-control.sock";

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
    /// Only the unix `host` fn consumes it, so it is `dead_code` on non-unix
    /// targets where that fn is not compiled.
    #[cfg_attr(not(unix), allow(dead_code))]
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
    #[serde(default)]
    pub auth_loaded: bool,
    /// Whether the Mac app currently has a tenant binding.
    #[serde(default)]
    pub tenant_bound: bool,
}

/// Result of `crossnet.host` — a freshly issued connection code plus the
/// session it is bound to.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct HostResult {
    /// The 8-character connection code a remote peer enters to connect.
    pub code: String,
    /// The hosting session identifier.
    pub session_id: String,
    /// ISO-8601 expiry, or `None` if the lease does not expire.
    #[serde(default)]
    pub expires_at: Option<String>,
    /// The lease mode the server actually applied.
    pub lease_mode: String,
}

/// Result of `crossnet.connect` — the session formed by redeeming a code.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ConnectResult {
    /// The session identifier formed by the connect.
    pub session_id: String,
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
    #[serde(default)]
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
    /// Whether the app currently has a loaded auth session.
    #[serde(default)]
    pub auth_loaded: bool,
    /// Whether the app currently has a tenant binding.
    #[serde(default)]
    pub tenant_bound: bool,
}

/// Queries the app-owned control surface and auth state (`crossnet.hello`).
#[cfg(unix)]
pub async fn hello() -> Result<HelloResult> {
    let path = default_socket_path()?;
    hello_at_path(&path).await
}

#[cfg(unix)]
async fn hello_at_path(path: &PathBuf) -> Result<HelloResult> {
    let result = call_at_path(path, "crossnet.hello", json!({})).await?;
    parse_result("crossnet.hello", result)
}

/// Ensures the app operator socket is present and bound to a loaded Mac app
/// auth/tenant context before a mutating control method is sent.
#[cfg(unix)]
pub async fn preflight_app_session() -> Result<HelloResult> {
    let path = default_socket_path()?;
    preflight_app_session_at_path(&path).await
}

#[cfg(unix)]
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
#[cfg(unix)]
pub async fn host(lease_mode: Option<LeaseMode>) -> Result<HostResult> {
    let path = default_socket_path()?;
    host_at_path(&path, lease_mode).await
}

#[cfg(unix)]
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
#[cfg(unix)]
pub async fn connect(code: &str) -> Result<ConnectResult> {
    let path = default_socket_path()?;
    preflight_app_session_at_path(&path).await?;
    let result = call_at_path(&path, "crossnet.connect", json!({ "code": code })).await?;
    parse_result("crossnet.connect", result)
}

/// Tears down the current cross-network session (`crossnet.disconnect`).
#[cfg(unix)]
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
#[cfg(unix)]
pub async fn status(watch: bool) -> Result<StatusOutcome> {
    let path = default_socket_path()?;
    status_at_path(&path, watch).await
}

#[cfg(unix)]
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
#[cfg(unix)]
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
#[cfg(unix)]
pub struct StatusWatch {
    reader: BufReader<UnixStream>,
    initial: StatusResult,
}

#[cfg(unix)]
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
#[cfg(unix)]
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
#[cfg(unix)]
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
/// cross-platform unit tests, but only the unix socket fns call it in a
/// non-test build, so it is `dead_code` on non-unix targets.
#[cfg_attr(not(unix), allow(dead_code))]
fn decode_response(expected_id: &str, value: Value) -> Result<Value> {
    if let Some(id) = value.get("id").and_then(Value::as_str)
        && id != expected_id
    {
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

    let error = value.get("error");
    let message = error
        .and_then(|e| e.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("unknown control error");
    let code = error
        .and_then(|e| e.get("code"))
        .and_then(Value::as_str)
        .unwrap_or("internal");
    Err(anyhow!("{message} (code: {code})"))
}

/// Deserializes a raw `result` object into a typed struct.
///
/// Pure helper (no socket I/O): kept cross-platform and exercised by the
/// cross-platform unit tests, but only the unix socket fns call it in a
/// non-test build, so it is `dead_code` on non-unix targets.
#[cfg_attr(not(unix), allow(dead_code))]
fn parse_result<T: for<'de> Deserialize<'de>>(method: &str, result: Value) -> Result<T> {
    serde_json::from_value(result).with_context(|| format!("failed to decode {method} result"))
}

/// Writes one NDJSON line (`<json>\n`) and flushes it.
#[cfg(unix)]
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
#[cfg(unix)]
async fn read_line(reader: &mut BufReader<UnixStream>) -> Result<String> {
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .await
        .context("failed to read control response")?;
    Ok(line)
}

/// Parses one NDJSON line into a JSON value.
///
/// Pure helper (no socket I/O): kept cross-platform, but only the unix socket
/// fns call it in a non-test build, so it is `dead_code` on non-unix targets.
#[cfg_attr(not(unix), allow(dead_code))]
fn parse_line(line: &str) -> Result<Value> {
    serde_json::from_str(line.trim_end_matches(['\n', '\r']))
        .context("failed to parse control response line")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::ffi::OsString;
    #[cfg(unix)]
    use std::sync::Mutex;
    #[cfg(unix)]
    use tokio::net::UnixListener;

    #[cfg(unix)]
    static HOME_ENV_LOCK: Mutex<()> = Mutex::new(());

    #[cfg(unix)]
    struct HomeEnvRestore(Option<OsString>);

    #[cfg(unix)]
    impl HomeEnvRestore {
        fn capture() -> Self {
            Self(std::env::var_os("HOME"))
        }
    }

    #[cfg(unix)]
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
        assert_eq!(parsed.session_id, "sess-1");
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

    #[cfg(unix)]
    #[tokio::test(flavor = "current_thread")]
    async fn host_preflights_app_session_and_writes_host_request() -> Result<()> {
        let socket_path = make_test_socket_path("host-preflight")?;
        let server = spawn_fake_server(&socket_path, 2).await?;

        let result = host_at_path(&socket_path, Some(LeaseMode::Long)).await?;
        assert_eq!(result.code, "ABCD1234");
        assert_eq!(result.session_id, "session-host");
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

    #[cfg(unix)]
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

    #[cfg(unix)]
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

    #[cfg(unix)]
    fn make_test_socket_path(label: &str) -> Result<PathBuf> {
        let uuid = uuid::Uuid::new_v4().to_string();
        let suffix = uuid
            .get(..8)
            .ok_or_else(|| anyhow!("failed to build test home suffix"))?;
        Ok(PathBuf::from("/tmp")
            .join(format!("sbc-{label}-{suffix}"))
            .join(SOCKET_RELATIVE_PATH))
    }

    #[cfg(unix)]
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

    #[cfg(unix)]
    async fn spawn_fake_server(
        socket_path: &std::path::Path,
        expected_requests: usize,
    ) -> Result<tokio::task::JoinHandle<Result<Vec<Value>>>> {
        spawn_fake_server_with_auth(socket_path, expected_requests, true, true).await
    }

    #[cfg(unix)]
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
                        "expires_at": null,
                        "lease_mode": "long"
                    }),
                    "crossnet.status" => json!({
                        "connection_status": "idle",
                        "readiness": "idle",
                        "session_present": false,
                        "session_ref": null,
                        "suite": null,
                        "signaling_health": "healthy",
                        "auth_loaded": auth_loaded,
                        "tenant_bound": tenant_bound
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

    #[cfg(unix)]
    fn request_method(value: &Value) -> Option<&str> {
        value.get("method").and_then(Value::as_str)
    }
}
