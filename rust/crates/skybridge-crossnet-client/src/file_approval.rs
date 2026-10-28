use super::*;

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileApprovalBinding {
    #[serde(rename = "transferID")]
    pub transfer_id: String,
    #[serde(rename = "senderDeviceID")]
    pub sender_device_id: String,
    pub sender_fingerprint: String,
    pub session_reference: String,
    pub metadata_digest: String,
    pub file_name: String,
    pub file_size: u64,
    #[serde(rename = "fileSHA256")]
    pub file_sha256: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileApprovalPrompt {
    pub id: String,
    pub nonce: String,
    pub binding: FileApprovalBinding,
    pub expires_at_milliseconds: i64,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct FileApprovalResult {
    pub runtime_target: String,
    pub operation: String,
    pub device_ref: String,
    pub authorized: Option<bool>,
    pub pending: Vec<FileApprovalPrompt>,
    pub decided_id: Option<String>,
    pub allowed: Option<bool>,
    pub transport: Option<String>,
    pub success: bool,
    pub error_code: Option<String>,
}

impl FileApprovalResult {
    fn validate(
        &self,
        operation: &str,
        target: &str,
        decision: Option<(&str, bool)>,
    ) -> Result<()> {
        if self.runtime_target != "mac_app_runtime"
            || self.operation != operation
            || self.device_ref != target
            || (self.success && self.authorized.is_none())
            || self.pending.len() > 8
            || (self.authorized != Some(true) && !self.pending.is_empty())
            || (self.success == self.error_code.is_some())
            || self
                .transport
                .as_deref()
                .is_some_and(|t| !["usb", "network"].contains(&t))
        {
            bail!("invalid file approval response");
        }
        if let Some((id, allowed)) = decision {
            if self.success
                && (self.authorized != Some(true)
                    || self
                        .decided_id
                        .as_deref()
                        .and_then(|v| uuid::Uuid::parse_str(v).ok())
                        != uuid::Uuid::parse_str(id).ok()
                    || self.allowed != Some(allowed))
            {
                bail!("file decision lacks exact receiver acknowledgement");
            }
        } else if self.decided_id.is_some() || self.allowed.is_some() {
            bail!("read-only file approval result claims a decision");
        }
        for prompt in &self.pending {
            uuid::Uuid::parse_str(&prompt.id)?;
            uuid::Uuid::parse_str(&prompt.binding.transfer_id)?;
            uuid::Uuid::parse_str(&prompt.binding.sender_device_id)?;
            let hex = |s: &str| {
                s.len() == 64
                    && s.bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            };
            if !hex(&prompt.binding.sender_fingerprint)
                || !hex(&prompt.binding.metadata_digest)
                || !hex(&prompt.binding.file_sha256)
                || prompt.binding.file_name.is_empty()
                || prompt.binding.file_name.len() > 1024
                || prompt.binding.file_size > 2 * 1024 * 1024 * 1024
                || prompt.expires_at_milliseconds <= 0
            {
                bail!("invalid pending file metadata");
            }
        }
        Ok(())
    }
    pub fn require_success(&self) -> Result<()> {
        if !self.success {
            bail!(
                "{}",
                self.error_code
                    .as_deref()
                    .unwrap_or("file_approval_unconfirmed")
            );
        }
        Ok(())
    }
}

pub async fn file_approval(
    operation: &str,
    target: &str,
    decision: Option<(&str, bool)>,
) -> Result<FileApprovalResult> {
    if !["status", "authorize", "decide", "revoke"].contains(&operation)
        || (operation == "decide") != decision.is_some()
    {
        bail!("invalid file approval action");
    }
    uuid::Uuid::parse_str(target)?;
    let mut params = json!({"device_ref":target});
    if let Some((id, allow)) = decision {
        uuid::Uuid::parse_str(id)?;
        params["approval_id"] = json!(id);
        params["allow"] = json!(allow);
    }
    let method = format!("crossnet.file.approval.{operation}");
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, &method).await?;
    let result: FileApprovalResult = parse_result(
        &method,
        call_at_path_with_timeout(&path, &method, params, Duration::from_secs(120)).await?,
    )?;
    result.validate(operation, target, decision)?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn decision_requires_receiver_acknowledgement_for_exact_id_and_choice() {
        let target = uuid::Uuid::new_v4().to_string();
        let id = uuid::Uuid::new_v4().to_string();
        let mut r = FileApprovalResult {
            runtime_target: "mac_app_runtime".into(),
            operation: "decide".into(),
            device_ref: target.clone(),
            authorized: Some(true),
            pending: vec![],
            decided_id: Some(id.clone()),
            allowed: Some(true),
            transport: Some("usb".into()),
            success: true,
            error_code: None,
        };
        r.validate("decide", &target, Some((&id, true))).unwrap();
        assert!(r.validate("decide", &target, Some((&id, false))).is_err());
        r.decided_id = Some(uuid::Uuid::new_v4().to_string());
        assert!(r.validate("decide", &target, Some((&id, true))).is_err());
        r.success = false;
        assert!(r.validate("decide", &target, Some((&id, true))).is_err());
        r.error_code = Some("file_approval_no_longer_pending".into());
        r.validate("decide", &target, Some((&id, true))).unwrap();
    }
}

#[derive(Debug)]
pub struct FileApprovalUnavailable;
impl std::fmt::Display for FileApprovalUnavailable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("The running Mac app does not provide CLI file approval. Use the updated app candidate; no approval decision was confirmed.")
    }
}
impl std::error::Error for FileApprovalUnavailable {}
