//! Shared portal session coordination for hardened Wayland deployments.
//!
//! This module intentionally centralizes xdg-desktop-portal session creation,
//! restore-token rotation, and persistent-output metadata so that capture and
//! input paths do not drift into separate application identities.

#![cfg(target_os = "linux")]

use std::collections::HashMap;
use std::fs;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use zbus::zvariant::{OwnedFd as PortalOwnedFd, OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, proxy};

use crate::crypto::aead::{AeadProvider, AesGcmProvider, EncryptedData};
use crate::remote::input::{KeyEvent, KeyEventType, MouseButton, MouseEvent, MouseEventType};

const PORTAL_STATE_FILENAME: &str = "portal_state.json.enc";
const PORTAL_STATE_AAD: &[u8] = b"skybridge.portal-state.v1";
const PORTAL_PERSIST_MODE_TRANSIENT: u32 = 2;
const PORTAL_POINTER_KEYBOARD_TYPES: u32 = 1 | 2;
const PORTAL_POINTER_DEVICE: u32 = 1;
const PORTAL_KEYBOARD_DEVICE: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PortalSessionState {
    BootstrapRequired,
    BootstrapInProgress,
    RestorePending,
    Active,
    RotatingRestoreToken,
    PersistentOutputLost,
    PermissionRevoked,
    SecretStoreUnavailable,
    RebootstrapRequired,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PortalStreamInfo {
    pub pipewire_node_id: u32,
    pub width: u32,
    pub height: u32,
    pub source_type: Option<u32>,
    pub mapping_id: Option<String>,
    pub position: Option<(i32, i32)>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct StoredPortalState {
    version: u32,
    restore_token: String,
    stream: Option<PortalStreamInfo>,
    updated_at_ms: u64,
}

#[derive(Debug, Clone)]
pub struct PortalSessionSnapshot {
    pub state: PortalSessionState,
    pub session_handle: String,
    pub stream: PortalStreamInfo,
    pub restore_token_present: bool,
    pub pipewire_fd_valid: bool,
    pub input_allowed: bool,
}

#[derive(Debug, Clone)]
pub struct PortalCallContext {
    pub connection: Connection,
    pub session_handle: OwnedObjectPath,
    pub stream_node_id: u32,
    pub stream: PortalStreamInfo,
    pub allowed_devices: u32,
}

#[derive(Debug)]
pub struct PortalCaptureContext {
    pub stream: PortalStreamInfo,
    pub pipewire_fd: OwnedFd,
}

#[derive(Debug, thiserror::Error)]
pub enum PortalError {
    #[error("portal bootstrap required")]
    BootstrapRequired,
    #[error("portal state requires re-bootstrap")]
    RebootstrapRequired,
    #[error("portal permission denied")]
    PermissionDenied,
    #[error("portal persistent output lost")]
    PersistentOutputLost,
    #[error("portal secret store unavailable: {0}")]
    SecretStoreUnavailable(String),
    #[error("portal error: {0}")]
    Portal(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("serde: {0}")]
    Serde(#[from] serde_json::Error),
}

impl From<crate::crypto::aead::AeadError> for PortalError {
    fn from(value: crate::crypto::aead::AeadError) -> Self {
        Self::Portal(value.to_string())
    }
}

#[proxy(
    interface = "org.freedesktop.portal.Request",
    default_service = "org.freedesktop.portal.Desktop",
    gen_blocking = false
)]
trait Request {
    #[zbus(signal)]
    fn response(&self, response: u32, results: HashMap<String, OwnedValue>) -> zbus::Result<()>;
}

#[proxy(
    interface = "org.freedesktop.portal.RemoteDesktop",
    default_service = "org.freedesktop.portal.Desktop",
    default_path = "/org/freedesktop/portal/desktop",
    gen_blocking = false
)]
trait RemoteDesktop {
    fn create_session(&self, options: HashMap<&str, Value<'_>>) -> zbus::Result<OwnedObjectPath>;

    fn select_devices(
        &self,
        session_handle: &zbus::zvariant::ObjectPath<'_>,
        options: HashMap<&str, Value<'_>>,
    ) -> zbus::Result<OwnedObjectPath>;

    fn start(
        &self,
        session_handle: &zbus::zvariant::ObjectPath<'_>,
        parent_window: &str,
        options: HashMap<&str, Value<'_>>,
    ) -> zbus::Result<OwnedObjectPath>;

    fn notify_pointer_motion_absolute(
        &self,
        session_handle: &zbus::zvariant::ObjectPath<'_>,
        options: HashMap<&str, Value<'_>>,
        stream: u32,
        x: f64,
        y: f64,
    ) -> zbus::Result<()>;

    fn notify_pointer_button(
        &self,
        session_handle: &zbus::zvariant::ObjectPath<'_>,
        options: HashMap<&str, Value<'_>>,
        button: i32,
        state: u32,
    ) -> zbus::Result<()>;

    fn notify_pointer_axis(
        &self,
        session_handle: &zbus::zvariant::ObjectPath<'_>,
        options: HashMap<&str, Value<'_>>,
        dx: f64,
        dy: f64,
    ) -> zbus::Result<()>;

    fn notify_keyboard_keysym(
        &self,
        session_handle: &zbus::zvariant::ObjectPath<'_>,
        options: HashMap<&str, Value<'_>>,
        keysym: i32,
        state: u32,
    ) -> zbus::Result<()>;
}

#[proxy(
    interface = "org.freedesktop.portal.ScreenCast",
    default_service = "org.freedesktop.portal.Desktop",
    default_path = "/org/freedesktop/portal/desktop",
    gen_blocking = false
)]
trait ScreenCast {
    fn select_sources(
        &self,
        session_handle: &zbus::zvariant::ObjectPath<'_>,
        options: HashMap<&str, Value<'_>>,
    ) -> zbus::Result<OwnedObjectPath>;

    fn open_pipe_wire_remote(
        &self,
        session_handle: &zbus::zvariant::ObjectPath<'_>,
        options: HashMap<&str, Value<'_>>,
    ) -> zbus::Result<PortalOwnedFd>;
}

#[proxy(
    interface = "org.freedesktop.portal.Session",
    default_service = "org.freedesktop.portal.Desktop",
    gen_blocking = false
)]
trait Session {
    fn close(&self) -> zbus::Result<()>;
}

struct ActivePortalSession {
    connection: Connection,
    session_handle: OwnedObjectPath,
    stream: PortalStreamInfo,
    restore_token: Option<String>,
    pipewire_fd: Option<Arc<OwnedFd>>,
    allowed_devices: u32,
}

impl ActivePortalSession {
    fn snapshot(&self, state: PortalSessionState) -> PortalSessionSnapshot {
        PortalSessionSnapshot {
            state,
            session_handle: self.session_handle.to_string(),
            stream: self.stream.clone(),
            restore_token_present: self
                .restore_token
                .as_deref()
                .map(|value| !value.trim().is_empty())
                .unwrap_or(false),
            pipewire_fd_valid: self.pipewire_fd.is_some(),
            input_allowed: self.allowed_devices & PORTAL_POINTER_KEYBOARD_TYPES != 0,
        }
    }

    fn call_context(&self) -> PortalCallContext {
        PortalCallContext {
            connection: self.connection.clone(),
            session_handle: self.session_handle.clone(),
            stream_node_id: self.stream.pipewire_node_id,
            stream: self.stream.clone(),
            allowed_devices: self.allowed_devices,
        }
    }

    fn capture_context(&self) -> Result<PortalCaptureContext, PortalError> {
        let pipewire_fd = self
            .pipewire_fd
            .as_ref()
            .ok_or(PortalError::PersistentOutputLost)
            .and_then(|fd| duplicate_owned_fd(fd))?;
        Ok(PortalCaptureContext {
            stream: self.stream.clone(),
            pipewire_fd,
        })
    }
}

pub struct PortalSessionCoordinator {
    state: PortalSessionState,
    active: Option<ActivePortalSession>,
}

impl PortalSessionCoordinator {
    fn new() -> Self {
        Self {
            state: PortalSessionState::BootstrapRequired,
            active: None,
        }
    }

    pub async fn bootstrap_interactive(
        &mut self,
        capture_cursor: bool,
    ) -> Result<PortalSessionSnapshot, PortalError> {
        self.state = PortalSessionState::BootstrapInProgress;
        let active = self
            .activate_session(SessionActivationMode::Interactive { capture_cursor })
            .await?;
        let snapshot = active.snapshot(PortalSessionState::Active);
        self.active = Some(active);
        self.state = PortalSessionState::Active;
        Ok(snapshot)
    }

    pub async fn ensure_runtime_session(
        &mut self,
        capture_cursor: bool,
    ) -> Result<PortalSessionSnapshot, PortalError> {
        if let Some(active) = self.active.as_ref() {
            self.state = PortalSessionState::Active;
            return Ok(active.snapshot(self.state));
        }

        let stored = PortalStateStore::load()?;
        let stored = stored.ok_or(PortalError::BootstrapRequired)?;
        self.state = PortalSessionState::RestorePending;
        match self
            .activate_session(SessionActivationMode::Restore {
                capture_cursor,
                restore_token: stored.restore_token,
            })
            .await
        {
            Ok(active) => {
                let snapshot = active.snapshot(PortalSessionState::Active);
                self.active = Some(active);
                self.state = PortalSessionState::Active;
                Ok(snapshot)
            }
            Err(PortalError::PermissionDenied)
            | Err(PortalError::PersistentOutputLost)
            | Err(PortalError::RebootstrapRequired) => {
                let _ = PortalStateStore::clear();
                self.active = None;
                self.state = PortalSessionState::RebootstrapRequired;
                Err(PortalError::RebootstrapRequired)
            }
            Err(err) => Err(err),
        }
    }

    pub fn active_snapshot(&self) -> Option<PortalSessionSnapshot> {
        self.active
            .as_ref()
            .map(|session| session.snapshot(self.state))
    }

    pub fn active_call_context(&self) -> Result<PortalCallContext, PortalError> {
        self.active
            .as_ref()
            .map(ActivePortalSession::call_context)
            .ok_or(PortalError::BootstrapRequired)
    }

    pub fn active_capture_context(&self) -> Result<PortalCaptureContext, PortalError> {
        self.active
            .as_ref()
            .ok_or(PortalError::BootstrapRequired)?
            .capture_context()
    }

    pub async fn close_active(&mut self) {
        if let Some(active) = self.active.take() {
            let _ = close_portal_session(&active.connection, &active.session_handle).await;
        }
        self.state = PortalSessionState::BootstrapRequired;
    }

    async fn activate_session(
        &mut self,
        mode: SessionActivationMode,
    ) -> Result<ActivePortalSession, PortalError> {
        let connection = Connection::session()
            .await
            .map_err(|err| PortalError::Portal(format!("D-Bus connection failed: {}", err)))?;
        let remote_desktop = RemoteDesktopProxy::new(&connection)
            .await
            .map_err(|err| PortalError::Portal(err.to_string()))?;
        let screen_cast = ScreenCastProxy::new(&connection)
            .await
            .map_err(|err| PortalError::Portal(err.to_string()))?;

        let session_handle = create_remote_desktop_session(&connection, &remote_desktop).await?;

        let (capture_cursor, restore_token) = match &mode {
            SessionActivationMode::Interactive { capture_cursor } => (*capture_cursor, None),
            SessionActivationMode::Restore {
                capture_cursor,
                restore_token,
            } => (*capture_cursor, Some(restore_token.as_str())),
        };

        select_remote_devices(&connection, &remote_desktop, &session_handle, restore_token).await?;
        select_monitor_source(&connection, &screen_cast, &session_handle, capture_cursor).await?;

        let start_result =
            start_remote_desktop_session(&connection, &remote_desktop, &session_handle).await?;
        let pipewire_fd = open_pipewire_remote(&screen_cast, &session_handle).await?;

        let new_restore_token = start_result.restore_token.clone();
        if let Some(token) = new_restore_token.as_ref() {
            self.state = PortalSessionState::RotatingRestoreToken;
            PortalStateStore::save(&StoredPortalState {
                version: 1,
                restore_token: token.clone(),
                stream: Some(start_result.stream.clone()),
                updated_at_ms: now_ms(),
            })?;
        }

        Ok(ActivePortalSession {
            connection,
            session_handle,
            stream: start_result.stream,
            restore_token: new_restore_token,
            pipewire_fd: pipewire_fd.map(Arc::new),
            allowed_devices: start_result.allowed_devices,
        })
    }
}

#[derive(Debug)]
enum SessionActivationMode {
    Interactive {
        capture_cursor: bool,
    },
    Restore {
        capture_cursor: bool,
        restore_token: String,
    },
}

#[derive(Debug)]
struct StartSessionResult {
    stream: PortalStreamInfo,
    restore_token: Option<String>,
    allowed_devices: u32,
}

fn coordinator() -> &'static Arc<Mutex<PortalSessionCoordinator>> {
    static INSTANCE: OnceLock<Arc<Mutex<PortalSessionCoordinator>>> = OnceLock::new();
    INSTANCE.get_or_init(|| Arc::new(Mutex::new(PortalSessionCoordinator::new())))
}

pub async fn bootstrap_portal_session(
    capture_cursor: bool,
) -> Result<PortalSessionSnapshot, PortalError> {
    coordinator()
        .lock()
        .await
        .bootstrap_interactive(capture_cursor)
        .await
}

pub async fn ensure_runtime_portal_session(
    capture_cursor: bool,
) -> Result<PortalSessionSnapshot, PortalError> {
    coordinator()
        .lock()
        .await
        .ensure_runtime_session(capture_cursor)
        .await
}

pub async fn active_portal_call_context() -> Result<PortalCallContext, PortalError> {
    coordinator().lock().await.active_call_context()
}

pub async fn active_portal_capture_context() -> Result<PortalCaptureContext, PortalError> {
    coordinator().lock().await.active_capture_context()
}

pub async fn send_pointer_event(event: &MouseEvent) -> Result<(), PortalError> {
    let context = active_portal_call_context().await?;
    if context.allowed_devices & PORTAL_POINTER_DEVICE == 0 {
        return Err(PortalError::Portal(
            "runtime portal session is view-only; rerun portal-bootstrap and enable Allow Remote Interaction".to_string(),
        ));
    }
    let proxy = RemoteDesktopProxy::new(&context.connection)
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let session_path = zbus::zvariant::ObjectPath::try_from(context.session_handle.as_str())
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let options: HashMap<&str, Value<'_>> = HashMap::new();

    match &event.event_type {
        MouseEventType::Move { x, y } => {
            proxy
                .notify_pointer_motion_absolute(
                    &session_path,
                    options,
                    context.stream_node_id,
                    *x as f64,
                    *y as f64,
                )
                .await
                .map_err(|err| PortalError::Portal(err.to_string()))?;
        }
        MouseEventType::ButtonDown { button } => {
            proxy
                .notify_pointer_button(&session_path, options, linux_button_code(button), 1)
                .await
                .map_err(|err| PortalError::Portal(err.to_string()))?;
        }
        MouseEventType::ButtonUp { button } => {
            proxy
                .notify_pointer_button(&session_path, options, linux_button_code(button), 0)
                .await
                .map_err(|err| PortalError::Portal(err.to_string()))?;
        }
        MouseEventType::Click { button } => {
            proxy
                .notify_pointer_button(&session_path, options.clone(), linux_button_code(button), 1)
                .await
                .map_err(|err| PortalError::Portal(err.to_string()))?;
            proxy
                .notify_pointer_button(&session_path, options, linux_button_code(button), 0)
                .await
                .map_err(|err| PortalError::Portal(err.to_string()))?;
        }
        MouseEventType::DoubleClick { button } => {
            for _ in 0..2 {
                proxy
                    .notify_pointer_button(
                        &session_path,
                        options.clone(),
                        linux_button_code(button),
                        1,
                    )
                    .await
                    .map_err(|err| PortalError::Portal(err.to_string()))?;
                proxy
                    .notify_pointer_button(
                        &session_path,
                        options.clone(),
                        linux_button_code(button),
                        0,
                    )
                    .await
                    .map_err(|err| PortalError::Portal(err.to_string()))?;
            }
        }
        MouseEventType::Scroll { dx, dy } => {
            proxy
                .notify_pointer_axis(&session_path, options, *dx as f64, *dy as f64)
                .await
                .map_err(|err| PortalError::Portal(err.to_string()))?;
        }
    }

    Ok(())
}

pub async fn send_keyboard_event(event: &KeyEvent) -> Result<(), PortalError> {
    let context = active_portal_call_context().await?;
    if context.allowed_devices & PORTAL_KEYBOARD_DEVICE == 0 {
        return Err(PortalError::Portal(
            "runtime portal session is view-only; rerun portal-bootstrap and enable Allow Remote Interaction".to_string(),
        ));
    }
    let proxy = RemoteDesktopProxy::new(&context.connection)
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let session_path = zbus::zvariant::ObjectPath::try_from(context.session_handle.as_str())
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let options: HashMap<&str, Value<'_>> = HashMap::new();
    let state = match event.event_type {
        KeyEventType::KeyDown | KeyEventType::KeyTyped => 1,
        KeyEventType::KeyUp => 0,
    };
    proxy
        .notify_keyboard_keysym(&session_path, options, event.keysym as i32, state)
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))
}

pub async fn close_runtime_portal_session() {
    coordinator().lock().await.close_active().await;
}

async fn create_remote_desktop_session(
    conn: &Connection,
    proxy: &RemoteDesktopProxy<'_>,
) -> Result<OwnedObjectPath, PortalError> {
    let handle_token = portal_token("skybridge_handle");
    let session_handle_token = portal_token("skybridge_session");
    let request_path = request_path_for_handle(conn, &handle_token)?;
    let request_proxy = RequestProxy::builder(conn)
        .path(request_path.clone())
        .map_err(|err| PortalError::Portal(err.to_string()))?
        .build()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let mut responses = request_proxy
        .receive_response()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let mut options: HashMap<&str, Value<'_>> = HashMap::new();
    options.insert("handle_token", Value::from(handle_token.as_str()));
    options.insert(
        "session_handle_token",
        Value::from(session_handle_token.as_str()),
    );

    let request = proxy
        .create_session(options)
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    if request.as_str() != request_path.as_str() {
        return Err(PortalError::Portal("Portal request path mismatch".to_string()));
    }
    let response = tokio::time::timeout(Duration::from_secs(30), responses.next())
        .await
        .map_err(|_| PortalError::Portal("Portal request timed out".to_string()))?
        .ok_or_else(|| PortalError::Portal("Portal request returned no response".to_string()))?;
    let args = response
        .args()
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let results = match args.response {
        0 => args.results,
        1 | 2 => return Err(PortalError::PermissionDenied),
        code => {
            return Err(PortalError::Portal(format!(
                "Portal request failed with response code {}",
                code
            )))
        }
    };
    results
        .get("session_handle")
        .and_then(owned_path_from_value)
        .ok_or_else(|| PortalError::Portal("Missing session_handle".to_string()))
}

async fn select_remote_devices(
    conn: &Connection,
    proxy: &RemoteDesktopProxy<'_>,
    session_handle: &OwnedObjectPath,
    restore_token: Option<&str>,
) -> Result<(), PortalError> {
    let handle_token = portal_token("skybridge_select_devices");
    let request_path = request_path_for_handle(conn, &handle_token)?;
    let request_proxy = RequestProxy::builder(conn)
        .path(request_path.clone())
        .map_err(|err| PortalError::Portal(err.to_string()))?
        .build()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let mut responses = request_proxy
        .receive_response()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let mut options: HashMap<&str, Value<'_>> = HashMap::new();
    options.insert("handle_token", Value::from(handle_token.as_str()));
    options.insert("types", Value::from(PORTAL_POINTER_KEYBOARD_TYPES));
    options.insert("persist_mode", Value::from(PORTAL_PERSIST_MODE_TRANSIENT));
    if let Some(restore_token) = restore_token {
        options.insert("restore_token", Value::from(restore_token));
    }

    let session_path = zbus::zvariant::ObjectPath::try_from(session_handle.as_str())
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let request = proxy
        .select_devices(&session_path, options)
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    if request.as_str() != request_path.as_str() {
        return Err(PortalError::Portal("Portal request path mismatch".to_string()));
    }
    let response = tokio::time::timeout(Duration::from_secs(120), responses.next())
        .await
        .map_err(|_| PortalError::Portal("Portal request timed out".to_string()))?
        .ok_or_else(|| PortalError::Portal("Portal request returned no response".to_string()))?;
    let args = response
        .args()
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    match args.response {
        0 => {}
        1 | 2 => return Err(PortalError::PermissionDenied),
        code => {
            return Err(PortalError::Portal(format!(
                "Portal request failed with response code {}",
                code
            )))
        }
    }
    Ok(())
}

async fn select_monitor_source(
    conn: &Connection,
    proxy: &ScreenCastProxy<'_>,
    session_handle: &OwnedObjectPath,
    capture_cursor: bool,
) -> Result<(), PortalError> {
    let handle_token = portal_token("skybridge_select_source");
    let request_path = request_path_for_handle(conn, &handle_token)?;
    let request_proxy = RequestProxy::builder(conn)
        .path(request_path.clone())
        .map_err(|err| PortalError::Portal(err.to_string()))?
        .build()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let mut responses = request_proxy
        .receive_response()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let mut options: HashMap<&str, Value<'_>> = HashMap::new();
    options.insert("handle_token", Value::from(handle_token.as_str()));
    options.insert("types", Value::from(1u32));
    options.insert("multiple", Value::from(false));
    options.insert(
        "cursor_mode",
        Value::from(if capture_cursor { 2u32 } else { 1u32 }),
    );

    let session_path = zbus::zvariant::ObjectPath::try_from(session_handle.as_str())
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let request = proxy
        .select_sources(&session_path, options)
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    if request.as_str() != request_path.as_str() {
        return Err(PortalError::Portal("Portal request path mismatch".to_string()));
    }
    let response = tokio::time::timeout(Duration::from_secs(120), responses.next())
        .await
        .map_err(|_| PortalError::Portal("Portal request timed out".to_string()))?
        .ok_or_else(|| PortalError::Portal("Portal request returned no response".to_string()))?;
    let args = response
        .args()
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    match args.response {
        0 => {}
        1 | 2 => return Err(PortalError::PermissionDenied),
        code => {
            return Err(PortalError::Portal(format!(
                "Portal request failed with response code {}",
                code
            )))
        }
    }
    Ok(())
}

async fn start_remote_desktop_session(
    conn: &Connection,
    proxy: &RemoteDesktopProxy<'_>,
    session_handle: &OwnedObjectPath,
) -> Result<StartSessionResult, PortalError> {
    let handle_token = portal_token("skybridge_start");
    let request_path = request_path_for_handle(conn, &handle_token)?;
    let request_proxy = RequestProxy::builder(conn)
        .path(request_path.clone())
        .map_err(|err| PortalError::Portal(err.to_string()))?
        .build()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let mut responses = request_proxy
        .receive_response()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let mut options: HashMap<&str, Value<'_>> = HashMap::new();
    options.insert("handle_token", Value::from(handle_token.as_str()));

    let session_path = zbus::zvariant::ObjectPath::try_from(session_handle.as_str())
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let request = proxy
        .start(&session_path, "", options)
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    if request.as_str() != request_path.as_str() {
        return Err(PortalError::Portal("Portal request path mismatch".to_string()));
    }
    let response = tokio::time::timeout(Duration::from_secs(120), responses.next())
        .await
        .map_err(|_| PortalError::Portal("Portal request timed out".to_string()))?
        .ok_or_else(|| PortalError::Portal("Portal request returned no response".to_string()))?;
    let args = response
        .args()
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let results = match args.response {
        0 => args.results,
        1 | 2 => return Err(PortalError::PermissionDenied),
        code => {
            return Err(PortalError::Portal(format!(
                "Portal request failed with response code {}",
                code
            )))
        }
    };
    let stream = parse_streams(
        results
            .get("streams")
            .ok_or(PortalError::PersistentOutputLost)?,
    )?;
    let restore_token = results.get("restore_token").and_then(string_from_value);
    let allowed_devices = results.get("devices").and_then(u32_from_value).unwrap_or(0);
    Ok(StartSessionResult {
        stream,
        restore_token,
        allowed_devices,
    })
}

async fn open_pipewire_remote(
    proxy: &ScreenCastProxy<'_>,
    session_handle: &OwnedObjectPath,
) -> Result<Option<OwnedFd>, PortalError> {
    let session_path = zbus::zvariant::ObjectPath::try_from(session_handle.as_str())
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let fd = proxy
        .open_pipe_wire_remote(&session_path, HashMap::new())
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let owned: OwnedFd = fd.into();
    if owned.as_raw_fd() < 0 {
        return Err(PortalError::PersistentOutputLost);
    }
    Ok(Some(owned))
}

async fn close_portal_session(
    conn: &Connection,
    session_handle: &OwnedObjectPath,
) -> Result<(), PortalError> {
    let session_path = zbus::zvariant::ObjectPath::try_from(session_handle.as_str())
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let proxy = SessionProxy::builder(conn)
        .path(session_path)
        .map_err(|err| PortalError::Portal(err.to_string()))?
        .build()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    proxy
        .close()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))
}

fn duplicate_owned_fd(fd: &OwnedFd) -> Result<OwnedFd, PortalError> {
    let duplicated = unsafe { libc::dup(fd.as_raw_fd()) };
    if duplicated < 0 {
        return Err(PortalError::Io(std::io::Error::last_os_error()));
    }
    // SAFETY: `dup` hands ownership of a fresh descriptor to the caller.
    Ok(unsafe { OwnedFd::from_raw_fd(duplicated) })
}

fn portal_token(prefix: &str) -> String {
    let sanitized_prefix: String = prefix
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '_' })
        .collect();
    format!("{}_{}", sanitized_prefix, uuid::Uuid::new_v4().simple())
}

async fn wait_request_response(
    conn: &Connection,
    request_path: OwnedObjectPath,
    timeout: Duration,
) -> Result<(u32, HashMap<String, OwnedValue>), PortalError> {
    let request_proxy = RequestProxy::builder(conn)
        .path(request_path)
        .map_err(|err| PortalError::Portal(err.to_string()))?
        .build()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;

    let mut responses = request_proxy
        .receive_response()
        .await
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    let response = tokio::time::timeout(timeout, responses.next())
        .await
        .map_err(|_| PortalError::Portal("Portal request timed out".to_string()))?
        .ok_or_else(|| PortalError::Portal("Portal request returned no response".to_string()))?;
    let args = response
        .args()
        .map_err(|err| PortalError::Portal(err.to_string()))?;
    match args.response {
        0 => Ok((args.response, args.results)),
        1 | 2 => Err(PortalError::PermissionDenied),
        code => Err(PortalError::Portal(format!(
            "Portal request failed with response code {}",
            code
        ))),
    }
}

fn parse_streams(streams: &OwnedValue) -> Result<PortalStreamInfo, PortalError> {
    let parsed: Vec<(u32, HashMap<String, OwnedValue>)> = streams
        .try_clone()
        .map_err(|err| PortalError::Portal(err.to_string()))?
        .try_into()
        .map_err(|_| PortalError::PersistentOutputLost)?;
    let (node_id, properties) = parsed
        .into_iter()
        .next()
        .ok_or(PortalError::PersistentOutputLost)?;

    let size = properties.get("size").and_then(size_from_value);
    let width = size.map(|value| value.0.max(1) as u32).unwrap_or(1920);
    let height = size.map(|value| value.1.max(1) as u32).unwrap_or(1080);

    Ok(PortalStreamInfo {
        pipewire_node_id: node_id,
        width,
        height,
        source_type: properties.get("source_type").and_then(u32_from_value),
        mapping_id: properties.get("mapping_id").and_then(string_from_value),
        position: properties.get("position").and_then(position_from_value),
    })
}

fn owned_path_from_value(value: &OwnedValue) -> Option<OwnedObjectPath> {
    value
        .try_clone()
        .ok()
        .and_then(|value| {
            OwnedObjectPath::try_from(value.clone()).ok().or_else(|| {
                String::try_from(value)
                    .ok()
                    .and_then(|path| OwnedObjectPath::try_from(path).ok())
            })
        })
}

fn request_path_for_handle(
    conn: &Connection,
    handle_token: &str,
) -> Result<OwnedObjectPath, PortalError> {
    let sender = conn
        .unique_name()
        .map(|name| name.as_str().trim_start_matches(':').replace('.', "_"))
        .ok_or_else(|| PortalError::Portal("Connection missing unique D-Bus name".to_string()))?;
    let path = format!(
        "/org/freedesktop/portal/desktop/request/{}/{}",
        sender, handle_token
    );
    OwnedObjectPath::try_from(path).map_err(|err| PortalError::Portal(err.to_string()))
}

fn string_from_value(value: &OwnedValue) -> Option<String> {
    value
        .try_clone()
        .ok()
        .and_then(|value| String::try_from(value).ok())
}

fn u32_from_value(value: &OwnedValue) -> Option<u32> {
    value
        .try_clone()
        .ok()
        .and_then(|value| u32::try_from(value).ok())
}

fn position_from_value(value: &OwnedValue) -> Option<(i32, i32)> {
    value
        .try_clone()
        .ok()
        .and_then(|value| <(i32, i32)>::try_from(value).ok())
}

fn size_from_value(value: &OwnedValue) -> Option<(i32, i32)> {
    value
        .try_clone()
        .ok()
        .and_then(|value| <(i32, i32)>::try_from(value).ok())
}

struct PortalStateStore;

impl PortalStateStore {
    fn load() -> Result<Option<StoredPortalState>, PortalError> {
        let path = state_store_path()?;
        if !path.exists() {
            return Ok(None);
        }
        let key = load_portal_state_key()?;
        let bytes = fs::read(path)?;
        let encrypted = EncryptedData::from_bytes(&bytes, 12).ok_or_else(|| {
            PortalError::Portal("Portal state ciphertext is truncated".to_string())
        })?;
        let clear = AesGcmProvider::new().decrypt(&key, &encrypted, PORTAL_STATE_AAD)?;
        Ok(Some(serde_json::from_slice(&clear)?))
    }

    fn save(state: &StoredPortalState) -> Result<(), PortalError> {
        let path = state_store_path()?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let clear = serde_json::to_vec_pretty(state)?;
        let key = load_portal_state_key()?;
        let encrypted = AesGcmProvider::new().encrypt(&key, &clear, PORTAL_STATE_AAD)?;
        let tmp = path.with_extension("tmp");
        fs::write(&tmp, encrypted.to_bytes())?;
        fs::rename(tmp, path)?;
        Ok(())
    }

    fn clear() -> Result<(), PortalError> {
        let path = state_store_path()?;
        if path.exists() {
            fs::remove_file(path)?;
        }
        Ok(())
    }
}

fn state_store_path() -> Result<PathBuf, PortalError> {
    let state_home = std::env::var("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|_| {
            std::env::var("HOME").map(|home| PathBuf::from(home).join(".local").join("state"))
        })
        .map_err(|_| {
            PortalError::SecretStoreUnavailable(
                "Neither XDG_STATE_HOME nor HOME is available".to_string(),
            )
        })?;
    Ok(state_home.join("compass").join(PORTAL_STATE_FILENAME))
}

fn load_portal_state_key() -> Result<Vec<u8>, PortalError> {
    if let Ok(credentials_dir) = std::env::var("CREDENTIALS_DIRECTORY") {
        let key_path = Path::new(&credentials_dir).join("portal_state_key");
        return parse_portal_state_key(&fs::read(&key_path)?);
    }

    if let Ok(key_file) = std::env::var("SKYBRIDGE_PORTAL_STATE_KEY_FILE") {
        return parse_portal_state_key(&fs::read(key_file)?);
    }

    Err(PortalError::SecretStoreUnavailable(
        "Missing portal_state_key credential".to_string(),
    ))
}

fn parse_portal_state_key(bytes: &[u8]) -> Result<Vec<u8>, PortalError> {
    if bytes.len() == 32 {
        return Ok(bytes.to_vec());
    }

    let trimmed = String::from_utf8_lossy(bytes).trim().to_string();
    if let Ok(decoded) = hex::decode(&trimmed)
        && decoded.len() == 32
    {
        return Ok(decoded);
    }

    if let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(trimmed.as_bytes())
        && decoded.len() == 32
    {
        return Ok(decoded);
    }

    Err(PortalError::SecretStoreUnavailable(
        "portal_state_key must be 32 raw bytes, 64-char hex, or base64-encoded 32 bytes"
            .to_string(),
    ))
}

fn linux_button_code(button: &MouseButton) -> i32 {
    match button {
        MouseButton::Left => 0x110,
        MouseButton::Right => 0x111,
        MouseButton::Middle => 0x112,
        MouseButton::Button4 => 0x113,
        MouseButton::Button5 => 0x114,
        MouseButton::ScrollUp => 0x90001,
        MouseButton::ScrollDown => 0x90002,
        MouseButton::ScrollLeft => 0x90003,
        MouseButton::ScrollRight => 0x90004,
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn with_test_key(key_dir: &Path) {
        // SAFETY: test-only mutation happens before the code under test reads the env var.
        unsafe { std::env::set_var("CREDENTIALS_DIRECTORY", key_dir) };
    }

    #[test]
    fn test_parse_portal_state_key_from_hex() {
        let raw = b"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
        let parsed = parse_portal_state_key(raw).expect("hex key");
        assert_eq!(parsed.len(), 32);
    }

    #[test]
    fn test_portal_state_roundtrip() {
        let home = tempdir().expect("tmp");
        let creds = tempdir().expect("creds");
        fs::write(
            creds.path().join("portal_state_key"),
            b"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        )
        .expect("key");
        // SAFETY: test-only env mutation is scoped to this unit test.
        unsafe { std::env::set_var("HOME", home.path()) };
        // SAFETY: test-only env mutation is scoped to this unit test.
        unsafe { std::env::remove_var("XDG_STATE_HOME") };
        with_test_key(creds.path());

        let state = StoredPortalState {
            version: 1,
            restore_token: "token".to_string(),
            stream: Some(PortalStreamInfo {
                pipewire_node_id: 7,
                width: 1920,
                height: 1080,
                source_type: Some(1),
                mapping_id: Some("map".to_string()),
                position: Some((0, 0)),
            }),
            updated_at_ms: 123,
        };

        PortalStateStore::save(&state).expect("save");
        let loaded = PortalStateStore::load().expect("load").expect("state");
        assert_eq!(loaded.restore_token, "token");
        assert_eq!(loaded.stream.expect("stream").pipewire_node_id, 7);
    }

    #[test]
    fn test_portal_token_uses_dbus_safe_characters() {
        let token = portal_token("skybridge-select-source");
        assert!(token.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '_'));
    }

    #[test]
    fn test_owned_path_from_string_variant() {
        let value = Value::from(
            "/org/freedesktop/portal/desktop/session/1_106/skybridge_session_test",
        )
        .try_to_owned()
        .expect("owned");
        let path = owned_path_from_value(&value).expect("path");
        assert_eq!(
            path.as_str(),
            "/org/freedesktop/portal/desktop/session/1_106/skybridge_session_test"
        );
    }
}
