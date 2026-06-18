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
//! [`default_socket_path`] plus the four control methods ([`host`],
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

/// Returns the default path of the `crossnet-control/1` Unix-domain socket:
/// `$HOME/Library/Application Support/SkyBridge/crossnet-control.sock`.
///
/// The home directory is resolved from the `HOME` environment variable, which
/// matches how the SkyBridge app derives `Application Support` on macOS.
pub fn default_socket_path() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    home.join(SOCKET_RELATIVE_PATH)
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
    #[serde(default)]
    pub session_id: Option<String>,
    /// The negotiated cipher suite, if a session is established.
    #[serde(default)]
    pub suite: Option<String>,
    /// Signaling-plane health, if the server reports it.
    ///
    /// Absent on streamed events (the event payload omits it); defaults to
    /// `None` there.
    #[serde(default)]
    pub signaling_health: Option<String>,
}

/// Hosts a cross-network connection code (`crossnet.host`).
///
/// `lease_mode` is optional — pass `None` to let the server pick its default.
#[cfg(unix)]
pub async fn host(lease_mode: Option<LeaseMode>) -> Result<HostResult> {
    let params = match lease_mode {
        Some(mode) => json!({ "lease_mode": mode.as_wire() }),
        None => json!({}),
    };
    let result = call("crossnet.host", params).await?;
    parse_result("crossnet.host", result)
}

/// Connects to a hosted cross-network code (`crossnet.connect`).
#[cfg(unix)]
pub async fn connect(code: &str) -> Result<ConnectResult> {
    let result = call("crossnet.connect", json!({ "code": code })).await?;
    parse_result("crossnet.connect", result)
}

/// Tears down the current cross-network session (`crossnet.disconnect`).
#[cfg(unix)]
pub async fn disconnect() -> Result<DisconnectResult> {
    let result = call("crossnet.disconnect", json!({})).await?;
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
    if !watch {
        let result = call("crossnet.status", json!({ "watch": false })).await?;
        let snapshot = parse_result("crossnet.status", result)?;
        return Ok(StatusOutcome::Snapshot(snapshot));
    }

    let path = default_socket_path();
    let stream = connect_socket(&path).await?;
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
            .ok_or_else(|| anyhow!("expected a `status` event frame, got: {value}"))?;
        if event != "status" {
            bail!("unexpected event `{event}` on crossnet.status watch stream");
        }
        let data = value
            .get("data")
            .cloned()
            .ok_or_else(|| anyhow!("crossnet.status event missing `data`"))?;
        let status: StatusResult = serde_json::from_value(data)
            .context("failed to decode crossnet.status event data")?;
        Ok(Some(status))
    }
}

/// Performs a single NDJSON request/response round trip and returns the raw
/// `result` object (the `ok:false` error path is already handled here).
#[cfg(unix)]
async fn call(method: &str, params: Value) -> Result<Value> {
    let path = default_socket_path();
    let stream = connect_socket(&path).await?;
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
        Err(err)
            if matches!(
                err.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
            ) =>
        {
            Err(anyhow!(
                "SkyBridge app not running / control socket unavailable at {} — launch the SkyBridge Compass Pro app and sign in first",
                path.display()
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
        .ok_or_else(|| anyhow!("control response missing boolean `ok` field: {value}"))?;
    if ok {
        return value
            .get("result")
            .cloned()
            .ok_or_else(|| anyhow!("control response ok:true missing `result`: {value}"));
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
        .with_context(|| format!("failed to parse control response line: {line:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_socket_path_uses_home_application_support() {
        // SAFETY: single-threaded test; we set and read HOME synchronously.
        unsafe {
            std::env::set_var("HOME", "/tmp/skybridge-test-home");
        }
        let path = default_socket_path();
        assert_eq!(
            path,
            PathBuf::from(
                "/tmp/skybridge-test-home/Library/Application Support/SkyBridge/crossnet-control.sock"
            )
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
        assert!(message.contains("no logged-in keychain session"), "{message}");
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
}
