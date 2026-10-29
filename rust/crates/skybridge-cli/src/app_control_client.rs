//! App-owned IPC framing and result contracts. A registry or helper process is
//! never a substitute for the selected Windows app's pipe.

use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub(crate) const PROTOCOL: &str = "skybridge-app-control/1";
pub(crate) const MAX_FRAME_BYTES: usize = 64 * 1024;
pub(crate) const METHODS: &[&str] = &[
    "app.status",
    "app.settings",
    "app.settings.set",
    "app.remote_desktop.interfaces",
    "app.remote_desktop.start",
    "app.remote_desktop.stop",
];

pub(crate) type AppResult<T> = Result<T, AppControlError>;

#[derive(Debug, Clone, Serialize)]
pub(crate) struct AppControlError {
    pub(crate) code: String,
    pub(crate) message: String,
    retryable: bool,
    pub(crate) mutation_unconfirmed: bool,
}

impl AppControlError {
    pub(crate) fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            retryable: false,
            mutation_unconfirmed: false,
        }
    }
}

impl std::fmt::Display for AppControlError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} (code: {})", self.message, self.code)
    }
}
impl std::error::Error for AppControlError {}

pub(crate) trait AppTransport {
    fn call(
        &mut self,
        method: &'static str,
        params: Value,
    ) -> impl Future<Output = AppResult<Value>>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub(crate) enum AppearanceMode {
    System,
    Light,
    Dark,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ObservedSetting {
    pub(crate) value: AppearanceMode,
    pub(crate) observed_value: AppearanceMode,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct HostSnapshot {
    pub(crate) generation: u64,
    pub(crate) enabled: bool,
    pub(crate) state: HostState,
    pub(crate) session_count: u64,
    pub(crate) frames_sent: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum HostState {
    Stopped,
    Listening,
    Authenticating,
    Connected,
    Failed,
}

impl HostState {
    pub(crate) fn is_running(self) -> bool {
        matches!(
            self,
            Self::Listening | Self::Authenticating | Self::Connected
        )
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct AppStatus {
    pub(crate) app_pid: u32,
    pub(crate) runtime_id: String,
    pub(crate) host: HostSnapshot,
    pub(crate) settings: BTreeMap<String, ObservedSetting>,
    pub(crate) capabilities: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SettingsSnapshot {
    pub(crate) settings: BTreeMap<String, ObservedSetting>,
    pub(crate) persistence: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SettingMutation {
    pub(crate) setting_id: String,
    pub(crate) requested_value: AppearanceMode,
    pub(crate) observed_value: AppearanceMode,
    pub(crate) persisted: bool,
    pub(crate) effect: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct HostInterface {
    interface_ref: String,
    name: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct HostInterfaces {
    interfaces: Vec<HostInterface>,
}

fn invalid_result() -> AppControlError {
    AppControlError::new(
        "app_result_invalid",
        "The app response does not match the requested result contract",
    )
}

pub(crate) fn decode_result<T: serde::de::DeserializeOwned>(value: Value) -> AppResult<T> {
    serde_json::from_value(value).map_err(|_| invalid_result())
}

pub(crate) fn encode_result<T: Serialize>(value: &T) -> AppResult<Value> {
    serde_json::to_value(value).map_err(|_| {
        AppControlError::new(
            "app_result_encoding_failed",
            "Could not encode the validated app result",
        )
    })
}

pub(crate) fn validate_host(host: &HostSnapshot) -> AppResult<()> {
    if (host.generation == 0
        && (host.state != HostState::Stopped
            || host.enabled
            || host.session_count != 0
            || host.frames_sent != 0))
        || (host.enabled && host.state == HostState::Stopped)
        || (!host.enabled && host.state.is_running())
    {
        return Err(invalid_result());
    }
    Ok(())
}

fn validate_settings(settings: &BTreeMap<String, ObservedSetting>) -> AppResult<()> {
    if settings.len() != 1
        || !settings
            .get("appearance.mode")
            .is_some_and(|setting| setting.value == setting.observed_value)
    {
        return Err(invalid_result());
    }
    Ok(())
}

pub(crate) fn parse_status(value: Value, pid: u32) -> AppResult<AppStatus> {
    let status: AppStatus = decode_result(value)?;
    if status.app_pid != pid
        || status.runtime_id != "windows_app_runtime"
        || status.capabilities.len() > METHODS.len()
        || status
            .capabilities
            .iter()
            .any(|method| !METHODS.contains(&method.as_str()))
        || status.capabilities.iter().collect::<BTreeSet<_>>().len() != status.capabilities.len()
    {
        return Err(invalid_result());
    }
    validate_host(&status.host)?;
    validate_settings(&status.settings)?;
    Ok(status)
}

pub(crate) fn parse_settings(value: Value) -> AppResult<SettingsSnapshot> {
    let settings: SettingsSnapshot = decode_result(value)?;
    validate_settings(&settings.settings)?;
    if settings.persistence != "persisted" {
        return Err(invalid_result());
    }
    Ok(settings)
}

pub(crate) fn parse_interfaces(value: Value) -> AppResult<HostInterfaces> {
    let result: HostInterfaces = decode_result(value)?;
    let mut refs = BTreeSet::new();
    if result.interfaces.len() > 128 {
        return Err(invalid_result());
    }
    for interface in &result.interfaces {
        if interface.interface_ref.is_empty()
            || interface.interface_ref.len() > 128
            || interface
                .interface_ref
                .chars()
                .any(|c| c.is_control() || c.is_whitespace())
            || interface.name.is_empty()
            || interface.name.len() > 512
            || interface.name.chars().any(char::is_control)
            || !refs.insert(&interface.interface_ref)
        {
            return Err(invalid_result());
        }
    }
    Ok(result)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Response {
    protocol: String,
    id: String,
    success: bool,
    result: Option<Value>,
    error: Option<ServerError>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ServerError {
    code: String,
    message: String,
    retryable: bool,
}

pub(crate) fn encode_request(id: &str, method: &str, params: Value) -> AppResult<Vec<u8>> {
    if uuid::Uuid::parse_str(id).is_err() || !METHODS.contains(&method) || !params.is_object() {
        return Err(AppControlError::new(
            "app_request_invalid",
            "Invalid app request identity, method, or parameters",
        ));
    }
    let mut bytes = serde_json::to_vec(
        &json!({"protocol": PROTOCOL, "id": id, "method": method, "params": params}),
    )
    .map_err(|_| AppControlError::new("app_request_invalid", "Could not encode the app request"))?;
    bytes.push(b'\n');
    if bytes.len() > MAX_FRAME_BYTES {
        return Err(AppControlError::new(
            "app_request_too_large",
            "The app request exceeds 64 KiB",
        ));
    }
    Ok(bytes)
}

pub(crate) fn decode_response(bytes: &[u8], expected_id: &str) -> AppResult<Value> {
    if bytes.len() > MAX_FRAME_BYTES {
        return Err(AppControlError::new(
            "app_response_too_large",
            "The app response exceeds 64 KiB",
        ));
    }
    if !bytes.ends_with(b"\n") {
        return Err(AppControlError::new(
            "app_response_unconfirmed",
            "The app closed before a complete response was received",
        ));
    }
    let response: Response = serde_json::from_slice(bytes).map_err(|_| {
        AppControlError::new(
            "app_response_invalid",
            "The app returned an invalid response envelope",
        )
    })?;
    if response.protocol != PROTOCOL || response.id != expected_id {
        return Err(AppControlError::new(
            "app_response_identity_mismatch",
            "The app response protocol or request ID does not match",
        ));
    }
    match (response.success, response.result, response.error) {
        (true, Some(result), None) if result.is_object() => Ok(result),
        (false, None, Some(error))
            if !error.retryable
                && !error.code.is_empty()
                && error.code.len() <= 96
                && error
                    .code
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_')
                && !error.message.is_empty()
                && error.message.len() <= 1024
                && !error.message.chars().any(char::is_control) =>
        {
            Err(AppControlError::new(&error.code, &error.message))
        }
        _ => Err(AppControlError::new(
            "app_response_invalid",
            "The app response must contain exactly one confirmed result or explicit error",
        )),
    }
}

pub(crate) async fn exchange<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    id: &str,
    request: &[u8],
) -> AppResult<Value> {
    stream.write_all(request).await.map_err(|_| {
        AppControlError::new(
            "app_response_unconfirmed",
            "The app request write did not complete; it will not be retried",
        )
    })?;
    let mut response = Vec::new();
    let mut buffer = [0_u8; 1024];
    loop {
        let read = stream.read(&mut buffer).await.map_err(|_| {
            AppControlError::new(
                "app_response_unconfirmed",
                "The app response could not be confirmed; the request will not be retried",
            )
        })?;
        if read == 0 {
            return decode_response(&response, id);
        }
        response.extend_from_slice(&buffer[..read]);
        if response.len() > MAX_FRAME_BYTES {
            return Err(AppControlError::new(
                "app_response_too_large",
                "The app response exceeds 64 KiB",
            ));
        }
        if response.contains(&b'\n') {
            return decode_response(&response, id);
        }
    }
}

pub(crate) fn select_pid(instances: &[u32], requested: Option<u32>) -> AppResult<u32> {
    match requested {
        Some(pid) if instances.contains(&pid) && pid != 0 => Ok(pid),
        Some(_) => Err(AppControlError::new(
            "app_instance_not_found",
            "The selected PID is not a running SkyBridge Windows app",
        )),
        None => match instances {
            [pid] if *pid != 0 => Ok(*pid),
            [] => Err(AppControlError::new(
                "app_not_running",
                "Launch the SkyBridge Windows app first",
            )),
            _ => Err(AppControlError::new(
                "app_instance_ambiguous",
                "Multiple SkyBridge Windows apps are running; select one with --pid",
            )),
        },
    }
}

pub(crate) fn verify_server_pid(selected: u32, observed: u32) -> AppResult<()> {
    if selected == 0 || selected != observed {
        return Err(AppControlError::new(
            "app_pipe_identity_mismatch",
            "The operator pipe belongs to a different process",
        ));
    }
    Ok(())
}

#[cfg(windows)]
mod native;
#[cfg(windows)]
pub(crate) use native::{AppClient, list_instances};

#[cfg(test)]
mod tests;
