use super::*;
use std::path::Path;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct NearbyDevice {
    pub device_ref: String,
    pub name: String,
    pub platform: Option<String>,
    pub authenticated: bool,
    pub transport: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct NearbyDevicesResult {
    pub runtime_target: String,
    pub devices: Vec<NearbyDevice>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct NearbyConnectionResult {
    pub runtime_target: String,
    pub device_ref: String,
    pub authenticated: bool,
    pub transport: Option<String>,
    pub negotiated_suite: Option<String>,
    pub peer_fingerprint: Option<String>,
    pub pqc: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct USBDevice {
    pub udid: String,
    pub device_id: u32,
    pub product_id: u32,
    pub transport: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct USBDevicesResult {
    pub runtime_target: String,
    pub devices: Vec<USBDevice>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct USBPeerChoice {
    pub peer_id: String,
    pub name: String,
    pub expected_fingerprint: Option<String>,
    pub unavailable_reason: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct USBPeersResult {
    pub runtime_target: String,
    pub peers: Vec<USBPeerChoice>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct USBPeerInspection {
    pub runtime_target: String,
    pub udid: String,
    pub peer: USBPeerChoice,
    pub signature_verified: bool,
    pub paired: bool,
}

pub async fn usb_inspect(udid: &str) -> Result<USBPeerInspection> {
    if !valid_usb_udid(udid) {
        bail!("invalid physical USB UDID");
    }
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, "crossnet.usb.inspect").await?;
    let result: USBPeerInspection = parse_result(
        "crossnet.usb.inspect",
        call_at_path_with_timeout(
            &path,
            "crossnet.usb.inspect",
            json!({"udid":udid}),
            Duration::from_secs(15),
        )
        .await?,
    )?;
    uuid::Uuid::parse_str(&result.peer.peer_id)?;
    let fingerprint = result.peer.expected_fingerprint.as_deref().unwrap_or("");
    if result.runtime_target != "mac_app_runtime"
        || result.udid != udid
        || !result.signature_verified
        || fingerprint.len() != 64
        || !fingerprint
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        || result.peer.name.is_empty()
        || (result.paired && result.peer.unavailable_reason.is_some())
    {
        bail!("USB signed identity inspection was not confirmed");
    }
    Ok(result)
}

impl USBPeersResult {
    fn validate(&self) -> Result<()> {
        if self.runtime_target != "mac_app_runtime" || self.peers.len() > 4096 {
            bail!("USB pairing catalog runtime or size is invalid");
        }
        let mut ids = std::collections::HashSet::new();
        for peer in &self.peers {
            let id = uuid::Uuid::parse_str(&peer.peer_id)?;
            let valid_state = match (&peer.expected_fingerprint, &peer.unavailable_reason) {
                (Some(fingerprint), None) => {
                    fingerprint.len() == 64
                        && fingerprint
                            .bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                }
                (None, Some(reason)) => !reason.is_empty(),
                _ => false,
            };
            if !ids.insert(id) || peer.name.is_empty() || !valid_state {
                bail!("USB pairing catalog contains an ambiguous or invalid identity");
            }
        }
        Ok(())
    }
}

/// Paired identities are independent of discovery. A later USB handshake must
/// still prove that the selected identity is at the selected physical cable.
pub async fn usb_peers() -> Result<USBPeersResult> {
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, "crossnet.usb.peers").await?;
    let result: USBPeersResult = parse_result(
        "crossnet.usb.peers",
        call_at_path(&path, "crossnet.usb.peers", json!({})).await?,
    )?;
    result.validate()?;
    Ok(result)
}

#[derive(Debug, Deserialize, Serialize)]
pub struct TrustRecoveryPreviewResult {
    pub runtime_target: String,
    pub peer_id: String,
    pub expected_fingerprint: String,
    pub snapshot_sha256: String,
    /// Read-only storage evidence is passed through, never interpreted as authority by the CLI.
    pub records: Vec<serde_json::Value>,
    pub blockers: Vec<String>,
    pub eligible_for_explicit_recovery: bool,
    pub writes_performed: bool,
    pub preserving_shared_peer_id: Option<String>,
}

pub async fn trust_recovery_preview(
    peer_id: &str,
    expected_fingerprint: &str,
    preserve_shared_peer_id: Option<&str>,
) -> Result<TrustRecoveryPreviewResult> {
    uuid::Uuid::parse_str(peer_id).context("trust preview target must be a stable peer UUID")?;
    if expected_fingerprint.len() != 64
        || !expected_fingerprint
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        bail!("trust preview requires a full lowercase protocol fingerprint");
    }
    let preserved = preserve_shared_peer_id
        .map(uuid::Uuid::parse_str)
        .transpose()?;
    if preserved.is_some_and(|id| Some(id) == uuid::Uuid::parse_str(peer_id).ok()) {
        bail!("the preserved shared peer must differ from the recovery target");
    }
    let mut params = json!({"peer_id":peer_id,"expected_fingerprint":expected_fingerprint});
    if let Some(id) = preserve_shared_peer_id {
        params["preserve_shared_peer_id"] = json!(id);
    }
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, "crossnet.trust.preview").await?;
    let result: TrustRecoveryPreviewResult = parse_result(
        "crossnet.trust.preview",
        call_at_path(&path, "crossnet.trust.preview", params).await?,
    )?;
    if result.runtime_target != "mac_app_runtime"
        || result.peer_id != peer_id
        || result.expected_fingerprint != expected_fingerprint
        || result.writes_performed
        || result
            .preserving_shared_peer_id
            .as_deref()
            .map(uuid::Uuid::parse_str)
            .transpose()?
            != preserved
        || result.snapshot_sha256.len() != 64
        || !result
            .snapshot_sha256
            .bytes()
            .all(|b| b.is_ascii_hexdigit())
        || result.records.iter().any(|record| !record.is_object())
        || result.eligible_for_explicit_recovery != result.blockers.is_empty()
    {
        bail!("trust preview response does not match the requested read-only scope");
    }
    Ok(result)
}

fn valid_usb_udid(udid: &str) -> bool {
    (24..=64).contains(&udid.len()) && udid.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

#[derive(Debug, Deserialize, Serialize)]
pub struct TrustMirrorRecoveryResult {
    pub runtime_target: String,
    pub recovery_id: String,
    pub peer_id: String,
    pub expected_fingerprint: String,
    pub success: bool,
    pub status: String,
    pub retired_mirror_records: Option<u64>,
    pub keychain_authority_preserved: bool,
    pub authenticated_connection: bool,
    pub error_code: Option<String>,
    pub preserving_shared_peer_id: Option<String>,
    pub shared_peer_records_preserved: Option<bool>,
}

impl TrustMirrorRecoveryResult {
    fn validate(
        &self,
        recovery_id: uuid::Uuid,
        peer_id: uuid::Uuid,
        fingerprint: &str,
        preserved: Option<uuid::Uuid>,
    ) -> Result<()> {
        if self.runtime_target != "mac_app_runtime"
            || uuid::Uuid::parse_str(&self.recovery_id)? != recovery_id
            || uuid::Uuid::parse_str(&self.peer_id)? != peer_id
            || self.expected_fingerprint != fingerprint
            || !self.keychain_authority_preserved
            || self.authenticated_connection
            || self
                .preserving_shared_peer_id
                .as_deref()
                .map(uuid::Uuid::parse_str)
                .transpose()?
                != preserved
            || (preserved.is_some()
                && self.success
                && self.shared_peer_records_preserved != Some(true))
            || (preserved.is_none() && self.shared_peer_records_preserved.is_some())
            || !matches!(
                self.status.as_str(),
                "completed"
                    | "aliases_retired_binding_unconfirmed"
                    | "not_applied"
                    | "mirror_changed_after_archive"
                    | "shared_peer_changed_after_archive"
            )
            || self.success != (self.status == "completed")
            || (self.success
                && (self.retired_mirror_records.is_none_or(|n| n == 0)
                    || self.error_code.is_some()))
            || (!self.success && self.error_code.as_ref().is_none_or(String::is_empty))
            || (self.status == "not_applied" && self.retired_mirror_records != Some(0))
            || (self.status == "aliases_retired_binding_unconfirmed"
                && self.retired_mirror_records.is_none_or(|n| n == 0))
            || (self.status == "mirror_changed_after_archive"
                && self.retired_mirror_records.is_some())
        {
            bail!(
                "trust recovery result is inconsistent or does not match the approved transaction; outcome unconfirmed"
            );
        }
        Ok(())
    }
}

pub async fn recover_trust_mirror(
    udid: &str,
    peer_id: &str,
    expected_fingerprint: &str,
    snapshot_sha256: &str,
    recovery_id: &str,
    approve_mirror_retirement: bool,
    preserve_shared_peer_id: Option<&str>,
) -> Result<TrustMirrorRecoveryResult> {
    let peer =
        uuid::Uuid::parse_str(peer_id).context("recovery target must be a stable peer UUID")?;
    let recovery =
        uuid::Uuid::parse_str(recovery_id).context("recovery ID must be a fresh UUID")?;
    let preserved = preserve_shared_peer_id
        .map(uuid::Uuid::parse_str)
        .transpose()?;
    if preserved == Some(peer) {
        bail!("preserved peer must differ from the recovery target");
    }
    let valid_hash = |s: &str| {
        s.len() == 64
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    };
    if !approve_mirror_retirement
        || !valid_usb_udid(udid)
        || !valid_hash(expected_fingerprint)
        || !valid_hash(snapshot_sha256)
    {
        bail!(
            "recovery requires explicit mirror retirement approval, a USB UDID, full fingerprint and exact preview digest"
        );
    }
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, "crossnet.trust.recover").await?;
    let mut params = json!({"udid":udid, "peer_id":peer_id,
        "expected_fingerprint":expected_fingerprint, "snapshot_sha256":snapshot_sha256,
        "recovery_id":recovery_id, "approve_mirror_retirement":true});
    if let Some(id) = preserve_shared_peer_id {
        params["preserve_shared_peer_id"] = json!(id);
    }
    let result: TrustMirrorRecoveryResult = parse_result("crossnet.trust.recover", call_at_path_with_timeout(
        &path, "crossnet.trust.recover", params, Duration::from_secs(180)
    ).await.context("recovery response unavailable; inspect the recovery archive before retrying, outcome unconfirmed")?)?;
    result.validate(recovery, peer, expected_fingerprint, preserved)?;
    Ok(result)
}

pub async fn usb_devices() -> Result<USBDevicesResult> {
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, "crossnet.usb.devices").await?;
    let result: USBDevicesResult = parse_result(
        "crossnet.usb.devices",
        call_at_path(&path, "crossnet.usb.devices", json!({})).await?,
    )?;
    if result.runtime_target != "mac_app_runtime" {
        bail!("USB inventory runtime mismatch");
    }
    let mut udids = std::collections::HashSet::new();
    for device in &result.devices {
        if device.transport != "usb"
            || device.device_id == 0
            || !valid_usb_udid(&device.udid)
            || !udids.insert(&device.udid)
        {
            bail!("USB inventory contains an invalid, duplicate or non-USB target");
        }
    }
    Ok(result)
}

pub async fn connect_usb(
    udid: &str,
    peer_id: &str,
    expected_fingerprint: &str,
) -> Result<NearbyConnectionResult> {
    uuid::Uuid::parse_str(peer_id).context("USB target must be a stable peer UUID")?;
    if !valid_usb_udid(udid)
        || expected_fingerprint.len() != 64
        || !expected_fingerprint
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        bail!("USB connection requires a physical UDID and full lowercase protocol fingerprint");
    }
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, "crossnet.usb.connect").await?;
    let result: NearbyConnectionResult = parse_result(
        "crossnet.usb.connect",
        call_at_path_with_timeout(
            &path,
            "crossnet.usb.connect",
            json!({"udid":udid,"peer_id":peer_id,"expected_fingerprint":expected_fingerprint}),
            Duration::from_secs(180),
        )
        .await?,
    )?;
    result.validate_usb(expected_fingerprint)?;
    Ok(result)
}

/// Use an app-owned device reference and a selected cable. Identity resolution
/// and pin checks remain in the native handshake owner; no network fallback.
pub async fn connect_usb_device(udid: &str, device_ref: &str) -> Result<NearbyConnectionResult> {
    uuid::Uuid::parse_str(device_ref).context("USB target must be an app device reference")?;
    if !valid_usb_udid(udid) {
        bail!("USB connection requires a physical UDID");
    }
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, "crossnet.usb.connect_device").await?;
    let result: NearbyConnectionResult = parse_result(
        "crossnet.usb.connect_device",
        call_at_path_with_timeout(
            &path,
            "crossnet.usb.connect_device",
            json!({"udid":udid,"device_ref":device_ref}),
            Duration::from_secs(180),
        )
        .await?,
    )?;
    result.validate_usb_device(device_ref)?;
    Ok(result)
}

impl NearbyConnectionResult {
    fn validate_usb_device(&self, device_ref: &str) -> Result<()> {
        let fingerprint = self.peer_fingerprint.as_deref().unwrap_or("");
        if self.device_ref != device_ref
            || fingerprint.len() != 64
            || !fingerprint
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            bail!("USB response does not identify the selected app device");
        }
        self.validate_usb(fingerprint)
    }
    fn validate_usb(&self, expected_fingerprint: &str) -> Result<()> {
        uuid::Uuid::parse_str(&self.device_ref)
            .context("invalid authenticated USB peer reference")?;
        if self.runtime_target != "mac_app_runtime"
            || !self.authenticated
            || self.pqc != Some(true)
            || self.transport.as_deref() != Some("usb")
            || self.peer_fingerprint.as_deref() != Some(expected_fingerprint)
            || self.negotiated_suite.as_ref().is_none_or(String::is_empty)
        {
            bail!("USB connection did not authenticate the exact selected peer over USB");
        }
        Ok(())
    }
}

pub async fn nearby(scan_seconds: u64) -> Result<NearbyDevicesResult> {
    if scan_seconds > 10 {
        bail!("scan_seconds must be 0..10");
    }
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, "crossnet.nearby").await?;
    let result: NearbyDevicesResult = parse_result(
        "crossnet.nearby",
        call_at_path(
            &path,
            "crossnet.nearby",
            json!({"scan_seconds": scan_seconds}),
        )
        .await?,
    )?;
    if result.runtime_target != "mac_app_runtime" {
        bail!("nearby runtime mismatch");
    }
    let mut refs = std::collections::HashSet::new();
    for device in &result.devices {
        uuid::Uuid::parse_str(&device.device_ref).context("invalid nearby device reference")?;
        if !refs.insert(&device.device_ref) {
            bail!("duplicate nearby device reference");
        }
    }
    Ok(result)
}

pub async fn connect_nearby(device_ref: &str) -> Result<NearbyConnectionResult> {
    uuid::Uuid::parse_str(device_ref).context("device_ref must come from crossnet nearby")?;
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, "crossnet.connect_nearby").await?;
    let result: NearbyConnectionResult = parse_result(
        "crossnet.connect_nearby",
        call_at_path_with_timeout(
            &path,
            "crossnet.connect_nearby",
            json!({"device_ref": device_ref}),
            Duration::from_secs(90),
        )
        .await?,
    )?;
    if result.runtime_target != "mac_app_runtime"
        || result.device_ref != device_ref
        || !result.authenticated
    {
        bail!("nearby connection was not authenticated for the requested peer");
    }
    Ok(result)
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferPhase {
    Preparing,
    Transferring,
    AwaitingReceipt,
    Completed,
    Failed,
    Cancelled,
    Unconfirmed,
}

impl TransferPhase {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::Completed | Self::Failed | Self::Cancelled | Self::Unconfirmed
        )
    }
    pub fn label(&self) -> &'static str {
        match self {
            Self::Preparing => "preparing",
            Self::Transferring => "transferring",
            Self::AwaitingReceipt => "waiting for receiver receipt",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Unconfirmed => "completion unconfirmed",
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AppFileTransferEvent {
    pub operation_id: String,
    pub runtime_target: String,
    pub device_ref: String,
    pub transfer_id: Option<String>,
    pub file_name: String,
    pub status: TransferPhase,
    pub bytes_transferred: u64,
    pub total_bytes: u64,
    pub sha256: Option<String>,
    pub receipt_verified: bool,
    pub transport: Option<String>,
    pub success: bool,
    pub automatic_retry_allowed: bool,
    pub error_code: Option<String>,
}

impl AppFileTransferEvent {
    fn validate(&self, operation_id: &str, device_ref: &str) -> Result<()> {
        if self.operation_id != operation_id
            || self.device_ref != device_ref
            || self.runtime_target != "mac_app_runtime"
        {
            bail!("file transfer event is not bound to the requested operation and runtime");
        }
        if self.automatic_retry_allowed {
            bail!("file transfer event cannot authorize an automatic write retry");
        }
        if self.bytes_transferred > self.total_bytes {
            bail!("file transfer byte count exceeds source size");
        }
        if self
            .transport
            .as_deref()
            .is_some_and(|carrier| !matches!(carrier, "usb" | "network"))
        {
            bail!("file transfer event reported an invalid transport");
        }
        if self.status == TransferPhase::Completed {
            let valid_hash = self.sha256.as_ref().is_some_and(|s| {
                s.len() == 64
                    && s.bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            });
            let valid_id = self
                .transfer_id
                .as_ref()
                .is_some_and(|id| uuid::Uuid::parse_str(id).is_ok());
            if !self.success
                || !self.receipt_verified
                || !valid_hash
                || !valid_id
                || self.bytes_transferred != self.total_bytes
                || self.error_code.is_some()
            {
                bail!("file transfer completion lacks a matching verified receiver receipt");
            }
        } else if self.success || self.receipt_verified {
            bail!("non-completed file transfer claimed success");
        }
        if matches!(
            self.status,
            TransferPhase::Failed | TransferPhase::Cancelled | TransferPhase::Unconfirmed
        ) && self.error_code.as_ref().is_none_or(|code| code.is_empty())
        {
            bail!("failed transfer omitted its failure code");
        }
        Ok(())
    }
}

pub struct AppFileTransferWatch {
    reader: BufReader<UnixStream>,
    initial: AppFileTransferEvent,
    deadline: tokio::time::Instant,
    finished: bool,
    active_transfer: Option<String>,
    active_transport: Option<String>,
}

impl AppFileTransferWatch {
    pub fn initial(&self) -> &AppFileTransferEvent {
        &self.initial
    }

    pub async fn next_event(&mut self) -> Result<AppFileTransferEvent> {
        if self.finished {
            bail!("file transfer stream has already completed");
        }
        if tokio::time::Instant::now() >= self.deadline {
            bail!("transfer deadline expired; completion is unconfirmed");
        }
        let line = tokio::time::timeout_at(self.deadline, read_line(&mut self.reader)).await
        .map_err(|_| anyhow!("transfer deadline expired; receiver completion is unconfirmed and must not be retried automatically"))??;
        if tokio::time::Instant::now() >= self.deadline {
            bail!("transfer result arrived after the command deadline; completion is unconfirmed");
        }
        if line.is_empty() {
            bail!("file transfer stream ended without a terminal receipt; outcome unconfirmed");
        }
        let value = parse_line(&line)?;
        if value.get("v").and_then(Value::as_u64) != Some(u64::from(PROTOCOL_VERSION)) {
            bail!("file transfer event protocol mismatch");
        }
        if value.get("ok") == Some(&Value::Bool(false)) {
            decode_response(&self.initial.operation_id, value)?;
            bail!("unexpected file transfer failure envelope");
        }
        if value.get("event").and_then(Value::as_str) != Some("file_transfer") {
            bail!("unexpected file transfer stream event");
        }
        let event: AppFileTransferEvent = serde_json::from_value(
            value
                .get("data")
                .cloned()
                .ok_or_else(|| anyhow!("missing file transfer event data"))?,
        )?;
        event.validate(&self.initial.operation_id, &self.initial.device_ref)?;
        if event.file_name != self.initial.file_name {
            bail!("file transfer source name changed");
        }
        if let Some(id) = &self.active_transfer {
            if event.transfer_id.as_ref() != Some(id) {
                bail!("transfer identity changed after creation");
            }
        } else if event.transfer_id.is_some() {
            self.active_transfer = event.transfer_id.clone();
        }
        if let Some(carrier) = &self.active_transport {
            if event.transport.as_ref() != Some(carrier) {
                bail!("file transport changed after sending bytes; completion unconfirmed");
            }
        } else if event.bytes_transferred > 0 {
            self.active_transport = event.transport.clone();
        }
        self.finished = event.status.is_terminal();
        Ok(event)
    }
}

pub async fn send_app_file(
    path: &Path,
    device_ref: &str,
    timeout_seconds: u64,
) -> Result<AppFileTransferWatch> {
    uuid::Uuid::parse_str(device_ref).context("device_ref must come from crossnet nearby")?;
    if !(1..=3600).contains(&timeout_seconds) {
        bail!("timeout must be 1..3600 seconds");
    }
    let source = std::fs::canonicalize(path).context("resolve source file")?;
    if !source.is_file() {
        bail!("source must be a regular file");
    }
    let source_text = source
        .to_str()
        .ok_or_else(|| anyhow!("source path must be UTF-8"))?;
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, "crossnet.file.send").await?;
    let mut reader = BufReader::new(connect_socket(&path).await?);
    let id = uuid::Uuid::new_v4().to_string();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout_seconds + 10);
    write_line(
        reader.get_mut(),
        &json!({"v":PROTOCOL_VERSION,"id":id,"method":"crossnet.file.send",
        "params":{"path":source_text,"device_ref":device_ref,"timeout_seconds":timeout_seconds}}),
    )
    .await?;
    let line = tokio::time::timeout(REQUEST_TIMEOUT, read_line(&mut reader))
        .await
        .map_err(|_| anyhow!("file request acknowledgement timed out; outcome unconfirmed"))??;
    let initial: AppFileTransferEvent = parse_result(
        "crossnet.file.send",
        decode_response(&id, parse_line(&line)?)?,
    )?;
    initial.validate(&id, device_ref)?;
    if initial.status != TransferPhase::Preparing {
        bail!("file stream did not begin with preparation");
    }
    Ok(AppFileTransferWatch {
        reader,
        initial,
        deadline,
        finished: false,
        active_transfer: None,
        active_transport: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usb_pairing_catalog_requires_explicit_available_or_blocked_identity() {
        let id = uuid::Uuid::new_v4().to_string();
        let ready = json!({"runtime_target":"mac_app_runtime", "peers":[{
            "peer_id":id,"name":"Paired iPad","expected_fingerprint":"a".repeat(64)}]});
        let parsed: USBPeersResult = serde_json::from_value(ready.clone()).unwrap();
        assert!(parsed.validate().is_ok());
        let mut blocked = ready.clone();
        blocked["peers"][0]["expected_fingerprint"] = Value::Null;
        blocked["peers"][0]["unavailable_reason"] = json!("pairing_identity_needs_verification");
        assert!(
            serde_json::from_value::<USBPeersResult>(blocked.clone())
                .unwrap()
                .validate()
                .is_ok()
        );
        blocked["peers"][0]["unavailable_reason"] = Value::Null;
        assert!(
            serde_json::from_value::<USBPeersResult>(blocked)
                .unwrap()
                .validate()
                .is_err()
        );
        let mut ambiguous = ready.clone();
        ambiguous["peers"]
            .as_array_mut()
            .unwrap()
            .push(ready["peers"][0].clone());
        assert!(
            serde_json::from_value::<USBPeersResult>(ambiguous)
                .unwrap()
                .validate()
                .is_err()
        );
        let mut invalid_pin = ready;
        invalid_pin["peers"][0]["expected_fingerprint"] = json!("short");
        assert!(
            serde_json::from_value::<USBPeersResult>(invalid_pin)
                .unwrap()
                .validate()
                .is_err()
        );
    }

    #[test]
    fn trust_recovery_partial_result_never_claims_a_connected_session() {
        let peer = uuid::Uuid::new_v4();
        let recovery = uuid::Uuid::new_v4();
        let fingerprint = "b".repeat(64);
        let valid = json!({"runtime_target":"mac_app_runtime", "recovery_id":recovery,
            "peer_id":peer, "expected_fingerprint":fingerprint, "success":false,
            "status":"aliases_retired_binding_unconfirmed", "retired_mirror_records":2,
            "keychain_authority_preserved":true, "authenticated_connection":false,
            "error_code":"trust_recovery_failed"});
        let result: TrustMirrorRecoveryResult = serde_json::from_value(valid.clone()).unwrap();
        assert!(result.validate(recovery, peer, &fingerprint, None).is_ok());
        for (key, value) in [
            ("success", json!(true)),
            ("authenticated_connection", json!(true)),
            ("keychain_authority_preserved", json!(false)),
            ("error_code", Value::Null),
            ("retired_mirror_records", json!(0)),
            ("peer_id", json!(uuid::Uuid::new_v4())),
        ] {
            let mut invalid = valid.clone();
            invalid[key] = value;
            let result: TrustMirrorRecoveryResult = serde_json::from_value(invalid).unwrap();
            assert!(
                result.validate(recovery, peer, &fingerprint, None).is_err(),
                "{key}"
            );
        }
    }

    #[tokio::test]
    async fn mirror_retirement_without_explicit_approval_is_rejected_locally() {
        assert!(
            recover_trust_mirror(
                "00008140-000E788401C0801C",
                &uuid::Uuid::new_v4().to_string(),
                &"b".repeat(64),
                &"a".repeat(64),
                &uuid::Uuid::new_v4().to_string(),
                false,
                None
            )
            .await
            .is_err()
        );
    }

    #[test]
    fn usb_success_requires_usb_pqc_and_the_selected_identity() {
        let expected = "b".repeat(64);
        let valid = json!({"runtime_target":"mac_app_runtime",
            "device_ref":uuid::Uuid::new_v4().to_string(),"authenticated":true,
            "transport":"usb","negotiated_suite":"X-Wing","pqc":true,
            "peer_fingerprint":expected});
        serde_json::from_value::<NearbyConnectionResult>(valid.clone())
            .unwrap()
            .validate_usb(&expected)
            .unwrap();
        for (field, value) in [
            ("transport", json!("network")),
            ("pqc", json!(false)),
            ("peer_fingerprint", json!("c".repeat(64))),
            ("authenticated", json!(false)),
            ("negotiated_suite", json!(null)),
            ("device_ref", json!("invalid")),
        ] {
            let mut rejected = valid.clone();
            rejected[field] = value;
            assert!(
                serde_json::from_value::<NearbyConnectionResult>(rejected)
                    .unwrap()
                    .validate_usb(&expected)
                    .is_err(),
                "accepted invalid {field}"
            );
        }
    }

    #[test]
    fn named_usb_selection_refuses_wrong_device_network_or_missing_authority() {
        let selected = uuid::Uuid::new_v4().to_string();
        let valid = json!({"runtime_target":"mac_app_runtime", "device_ref":selected,
            "authenticated":true,"transport":"usb","negotiated_suite":"X-Wing",
            "pqc":true,"peer_fingerprint":"a".repeat(64)});
        serde_json::from_value::<NearbyConnectionResult>(valid.clone())
            .unwrap()
            .validate_usb_device(&selected)
            .unwrap();
        for (key, value) in [
            ("device_ref", json!(uuid::Uuid::new_v4().to_string())),
            ("transport", json!("network")),
            ("pqc", json!(false)),
            ("peer_fingerprint", Value::Null),
            ("peer_fingerprint", json!("invalid")),
        ] {
            let mut bad = valid.clone();
            bad[key] = value;
            assert!(
                serde_json::from_value::<NearbyConnectionResult>(bad)
                    .unwrap()
                    .validate_usb_device(&selected)
                    .is_err(),
                "{key}"
            );
        }
    }

    #[tokio::test]
    async fn named_usb_rejects_invalid_selection_before_socket_io() {
        assert!(
            connect_usb_device("network", &uuid::Uuid::new_v4().to_string())
                .await
                .is_err()
        );
        assert!(
            connect_usb_device("00008140-000E788401C0801C", "name")
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn invalid_usb_target_is_rejected_before_contacting_the_app() {
        assert!(
            connect_usb(
                "localhost:9527",
                &uuid::Uuid::new_v4().to_string(),
                &"b".repeat(64)
            )
            .await
            .is_err()
        );
        assert!(
            connect_usb(
                "00008140-000E788401C0801C",
                "discovery-name",
                &"b".repeat(64)
            )
            .await
            .is_err()
        );
    }

    #[test]
    fn shared_peer_recovery_completion_requires_exact_preservation_evidence() {
        let peer = uuid::Uuid::new_v4();
        let shared = uuid::Uuid::new_v4();
        let recovery = uuid::Uuid::new_v4();
        let fingerprint = "b".repeat(64);
        let valid = json!({"runtime_target":"mac_app_runtime", "recovery_id":recovery,
            "peer_id":peer, "expected_fingerprint":fingerprint, "success":true,
            "status":"completed", "retired_mirror_records":2, "keychain_authority_preserved":true,
            "authenticated_connection":false, "preserving_shared_peer_id":shared,
            "shared_peer_records_preserved":true});
        let good: TrustMirrorRecoveryResult = serde_json::from_value(valid.clone()).unwrap();
        assert!(
            good.validate(recovery, peer, &fingerprint, Some(shared))
                .is_ok()
        );
        for (field, value) in [
            ("shared_peer_records_preserved", json!(false)),
            ("shared_peer_records_preserved", Value::Null),
            ("preserving_shared_peer_id", json!(peer)),
        ] {
            let mut invalid = valid.clone();
            invalid[field] = value;
            let result: TrustMirrorRecoveryResult = serde_json::from_value(invalid).unwrap();
            assert!(
                result
                    .validate(recovery, peer, &fingerprint, Some(shared))
                    .is_err()
            );
        }
    }

    fn complete() -> AppFileTransferEvent {
        AppFileTransferEvent {
            operation_id: "operation".into(),
            runtime_target: "mac_app_runtime".into(),
            device_ref: "peer".into(),
            transfer_id: Some(uuid::Uuid::new_v4().to_string()),
            file_name: "file.bin".into(),
            status: TransferPhase::Completed,
            bytes_transferred: 8,
            total_bytes: 8,
            sha256: Some("a".repeat(64)),
            receipt_verified: true,
            transport: Some("usb".into()),
            success: true,
            automatic_retry_allowed: false,
            error_code: None,
        }
    }

    #[test]
    fn full_byte_count_without_receiver_receipt_is_not_success() {
        let mut event = complete();
        event.receipt_verified = false;
        assert!(event.validate("operation", "peer").is_err());
        event.receipt_verified = true;
        assert!(event.validate("operation", "peer").is_ok());
        event.status = TransferPhase::AwaitingReceipt;
        assert!(event.validate("operation", "peer").is_err());
    }

    #[test]
    fn completion_is_bound_to_operation_runtime_size_and_hash() {
        let event = complete();
        assert!(event.validate("other", "peer").is_err());
        assert!(event.validate("operation", "other").is_err());
        for bad in ["", "z", "short"] {
            let mut invalid = event.clone();
            invalid.sha256 = Some(bad.into());
            assert!(invalid.validate("operation", "peer").is_err());
        }
        let mut short = event;
        short.bytes_transferred = 7;
        assert!(short.validate("operation", "peer").is_err());
    }

    fn stream() -> (UnixStream, AppFileTransferWatch) {
        let (server, client) = UnixStream::pair().unwrap();
        let mut initial = complete();
        initial.status = TransferPhase::Preparing;
        initial.success = false;
        initial.receipt_verified = false;
        initial.bytes_transferred = 0;
        (
            server,
            AppFileTransferWatch {
                reader: BufReader::new(client),
                initial,
                deadline: tokio::time::Instant::now() + Duration::from_secs(1),
                finished: false,
                active_transfer: None,
                active_transport: None,
            },
        )
    }

    #[tokio::test]
    async fn socket_eof_is_not_completion() {
        let (server, mut watch) = stream();
        drop(server);
        assert!(
            watch
                .next_event()
                .await
                .unwrap_err()
                .to_string()
                .contains("unconfirmed")
        );
    }

    #[tokio::test]
    async fn socket_accepts_only_correlated_verified_terminal_result() {
        let (mut server, mut watch) = stream();
        let event = complete();
        write_line(
            &mut server,
            &json!({"v":1,"event":"file_transfer","data":event}),
        )
        .await
        .unwrap();
        assert!(watch.next_event().await.unwrap().success);
        assert!(watch.next_event().await.is_err());
    }

    #[tokio::test]
    async fn file_stream_refuses_a_carrier_change_after_bytes_were_sent() {
        let (mut server, mut watch) = stream();
        let mut sending = complete();
        sending.status = TransferPhase::Transferring;
        sending.success = false;
        sending.receipt_verified = false;
        sending.bytes_transferred = 4;
        let mut terminal = sending.clone();
        terminal.status = TransferPhase::Completed;
        terminal.success = true;
        terminal.receipt_verified = true;
        terminal.bytes_transferred = 8;
        terminal.transport = Some("network".into());
        for event in [sending, terminal] {
            write_line(
                &mut server,
                &json!({"v":1,"event":"file_transfer","data":event}),
            )
            .await
            .unwrap();
        }
        assert!(watch.next_event().await.is_ok());
        assert!(
            watch
                .next_event()
                .await
                .unwrap_err()
                .to_string()
                .contains("transport changed")
        );
    }

    #[tokio::test]
    async fn already_buffered_receipt_after_deadline_is_not_command_success() {
        let (mut server, mut watch) = stream();
        write_line(
            &mut server,
            &json!({"v":1,"event":"file_transfer","data":complete()}),
        )
        .await
        .unwrap();
        watch.deadline = tokio::time::Instant::now() - Duration::from_millis(1);
        assert!(
            watch
                .next_event()
                .await
                .unwrap_err()
                .to_string()
                .contains("deadline")
        );
    }

    #[tokio::test]
    async fn socket_refuses_wrong_protocol_even_with_a_valid_receipt() {
        let (mut server, mut watch) = stream();
        write_line(
            &mut server,
            &json!({"v":99,"event":"file_transfer","data":complete()}),
        )
        .await
        .unwrap();
        assert!(
            watch
                .next_event()
                .await
                .unwrap_err()
                .to_string()
                .contains("protocol")
        );
    }
}
