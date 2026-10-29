use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum HandshakeProfile {
    Qperiapt,
    Xwing,
    Mlkem,
    Classic,
}
impl HandshakeProfile {
    pub fn wire(self) -> &'static str {
        match self {
            Self::Qperiapt => "qperiapt",
            Self::Xwing => "xwing",
            Self::Mlkem => "mlkem",
            Self::Classic => "classic",
        }
    }
    pub fn title(self) -> &'static str {
        match self {
            Self::Qperiapt => "Q-Periapt",
            Self::Xwing => "X-Wing",
            Self::Mlkem => "ML-KEM-768（纯 PQC）",
            Self::Classic => "Classic",
        }
    }
    fn matches_suite(self, suite: Option<&str>) -> bool {
        match self {
            Self::Qperiapt => suite == Some("Q-Periapt-ABI2-PolicyBound"),
            Self::Xwing => suite == Some("X-Wing"),
            Self::Mlkem => matches!(suite, Some("ML-KEM-768" | "ML-KEM-768-FS")),
            Self::Classic => false,
        }
    }
}
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct HandshakeOption {
    pub profile: HandshakeProfile,
    pub selectable: bool,
    pub reason: Option<String>,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HandshakeSnapshot {
    pub revision: String,
    pub configured_profile: HandshakeProfile,
    pub provider_suite: Option<String>,
    pub options: Vec<HandshakeOption>,
    pub busy: bool,
}
impl HandshakeSnapshot {
    fn validate(&self) -> Result<()> {
        uuid::Uuid::parse_str(&self.revision).context("invalid handshake revision")?;
        let profiles = [
            HandshakeProfile::Qperiapt,
            HandshakeProfile::Xwing,
            HandshakeProfile::Mlkem,
            HandshakeProfile::Classic,
        ];
        if self.options.len() != profiles.len()
            || profiles
                .iter()
                .any(|p| self.options.iter().filter(|o| &o.profile == p).count() != 1)
            || self
                .options
                .iter()
                .any(|o| o.profile == HandshakeProfile::Classic && o.selectable)
        {
            bail!("invalid handshake profile availability");
        }
        Ok(())
    }
}
#[derive(Debug, Deserialize, Serialize)]
pub struct HandshakeResult {
    pub runtime_target: String,
    pub operation: String,
    pub scope: String,
    pub device_ref: Option<String>,
    pub usb_udid: Option<String>,
    pub local: HandshakeSnapshot,
    pub remote: Option<HandshakeSnapshot>,
    pub local_applied: bool,
    pub remote_applied: bool,
    pub local_error: Option<String>,
    pub remote_error: Option<String>,
    pub management_authorized: Option<bool>,
    pub management_transport: Option<String>,
    pub negotiated_suite: Option<String>,
    pub session_transport: Option<String>,
    pub session_matches_configuration: Option<bool>,
    pub reconnected: bool,
    pub reconnect_error: Option<String>,
    pub success: bool,
    pub partial: bool,
}
impl HandshakeResult {
    fn validate(
        &self,
        operation: &str,
        scope: &str,
        target: Option<&str>,
        profile: Option<HandshakeProfile>,
    ) -> Result<()> {
        if self.runtime_target != "mac_app_runtime"
            || self.operation != operation
            || self.scope != scope
            || self.device_ref.as_deref() != target
        {
            bail!("handshake response target mismatch");
        }
        self.local.validate()?;
        if let Some(remote) = &self.remote {
            remote.validate()?;
        }
        if self.partial != (scope == "both" && self.local_applied != self.remote_applied) {
            bail!("inconsistent partial handshake result");
        }
        if operation != "set" && (self.local_applied || self.remote_applied || self.reconnected) {
            bail!("read or revoke unexpectedly reports a profile mutation");
        }
        for (applied, snapshot) in [
            (self.local_applied, Some(&self.local)),
            (self.remote_applied, self.remote.as_ref()),
        ] {
            if applied
                && !matches!((profile, snapshot), (Some(p), Some(s)) if s.configured_profile == p && p.matches_suite(s.provider_suite.as_deref()))
            {
                bail!("applied profile lacks provider read-back");
            }
        }
        if self.success
            && (self.local_error.is_some()
                || self.reconnect_error.is_some()
                || (scope == "both" && self.remote_error.is_some())
                || (operation == "set"
                    && (!self.local_applied || (scope == "both" && !self.remote_applied)))
                || (operation == "revoke" && self.management_authorized != Some(false)))
        {
            bail!("inconsistent successful handshake result");
        }
        if self.reconnected
            && (self.session_matches_configuration != Some(true) || self.negotiated_suite.is_none())
        {
            bail!("reconnect lacks negotiated suite evidence");
        }
        Ok(())
    }
}

async fn handshake_at_target(
    operation: &str,
    scope: &str,
    target: Option<&str>,
    profile: Option<HandshakeProfile>,
    reconnect: bool,
    usb: Option<&HandshakeUSBTarget>,
) -> Result<HandshakeResult> {
    if !["list", "status", "set", "revoke"].contains(&operation)
        || !["local", "both"].contains(&scope)
        || (operation == "set") != profile.is_some()
        || (reconnect && operation != "set")
        || ((scope == "both" || reconnect || operation == "revoke")
            && target.is_none()
            && usb.is_none())
    {
        bail!("invalid handshake operation, scope or target");
    }
    if target.is_some() && usb.is_some() {
        bail!("choose either discovery target or explicit USB target");
    }
    if let Some(usb) = usb {
        uuid::Uuid::parse_str(&usb.peer_id).context("USB peer must be a stable UUID")?;
        if !(24..=64).contains(&usb.udid.len())
            || !usb.udid.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
            || usb.expected_fingerprint.len() != 64
            || !usb
                .expected_fingerprint
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            bail!("USB target requires a physical UDID and full lowercase protocol fingerprint");
        }
    }
    if let Some(target) = target {
        uuid::Uuid::parse_str(target).context("target must be a device_ref UUID")?;
    }
    let method = format!("crossnet.handshake.{operation}");
    let mut params = json!({"scope":scope,"reconnect":reconnect});
    if let Some(target) = target {
        params["device_ref"] = json!(target);
    }
    if let Some(profile) = profile {
        params["profile"] = json!(profile);
    }
    if let Some(usb) = usb {
        params["udid"] = json!(usb.udid);
        params["peer_id"] = json!(usb.peer_id);
        params["expected_fingerprint"] = json!(usb.expected_fingerprint);
    }
    let path = default_socket_path()?;
    preflight_app_method_at_path(&path, &method).await?;
    let result: HandshakeResult = parse_result(
        &method,
        call_at_path_with_timeout(&path, &method, params, Duration::from_secs(180)).await?,
    )?;
    result.validate(operation, scope, target, profile)?;
    if result.usb_udid.as_deref() != usb.map(|t| t.udid.as_str()) {
        bail!("handshake USB target mismatch");
    }
    Ok(result)
}

#[derive(Debug, Clone)]
pub struct HandshakeUSBTarget {
    pub udid: String,
    pub peer_id: String,
    pub expected_fingerprint: String,
}
pub async fn handshake(
    operation: &str,
    scope: &str,
    target: Option<&str>,
    profile: Option<HandshakeProfile>,
    reconnect: bool,
) -> Result<HandshakeResult> {
    handshake_at_target(operation, scope, target, profile, reconnect, None).await
}
pub async fn handshake_usb(
    operation: &str,
    scope: &str,
    target: &HandshakeUSBTarget,
    profile: Option<HandshakeProfile>,
    reconnect: bool,
) -> Result<HandshakeResult> {
    handshake_at_target(operation, scope, None, profile, reconnect, Some(target)).await
}

#[cfg(test)]
mod tests {
    use super::*;
    fn result() -> HandshakeResult {
        let snapshot = json!({"revision":uuid::Uuid::new_v4().to_string(),"configuredProfile":"xwing","providerSuite":"X-Wing","busy":false,
            "options":[{"profile":"qperiapt","selectable":true},{"profile":"xwing","selectable":true},{"profile":"mlkem","selectable":true},{"profile":"classic","selectable":false}]});
        serde_json::from_value(json!({"runtime_target":"mac_app_runtime","operation":"set","scope":"both","device_ref":null,"usb_udid":null,
            "local":snapshot,"remote":snapshot,"local_applied":true,"remote_applied":true,"management_authorized":true,
            "reconnected":false,"success":true,"partial":false})).expect("valid fixture")
    }
    #[test]
    fn successful_both_result_requires_two_actual_provider_readbacks() {
        let mut r = result();
        r.validate("set", "both", None, Some(HandshakeProfile::Xwing))
            .unwrap();
        r.remote.as_mut().unwrap().provider_suite = Some("ML-KEM-768".into());
        assert!(
            r.validate("set", "both", None, Some(HandshakeProfile::Xwing))
                .is_err()
        );
    }
    #[test]
    fn partial_result_is_valid_only_when_reported_as_failure() {
        let mut r = result();
        r.local_applied = false;
        r.partial = true;
        r.local_error = Some("configuration_changed".into());
        assert!(
            r.validate("set", "both", None, Some(HandshakeProfile::Xwing))
                .is_err()
        );
        r.success = false;
        r.validate("set", "both", None, Some(HandshakeProfile::Xwing))
            .unwrap();
        r.partial = false;
        assert!(
            r.validate("set", "both", None, Some(HandshakeProfile::Xwing))
                .is_err()
        );
    }
    #[test]
    fn status_cannot_claim_mutation_and_reconnect_requires_negotiated_evidence() {
        let mut r = result();
        r.operation = "status".into();
        assert!(r.validate("status", "both", None, None).is_err());
        r.operation = "set".into();
        r.reconnected = true;
        assert!(
            r.validate("set", "both", None, Some(HandshakeProfile::Xwing))
                .is_err()
        );
    }
    #[test]
    fn classic_availability_and_duplicate_profile_are_rejected() {
        let mut r = result();
        r.local.options[3].selectable = true;
        assert!(r.local.validate().is_err());
        r.local.options[3].selectable = false;
        r.local.options[2].profile = HandshakeProfile::Xwing;
        assert!(r.local.validate().is_err());
    }
    #[tokio::test]
    async fn missing_target_and_invalid_usb_identity_fail_before_socket_access() {
        assert!(
            handshake("set", "both", None, Some(HandshakeProfile::Xwing), false)
                .await
                .unwrap_err()
                .to_string()
                .contains("target")
        );
        let target = HandshakeUSBTarget {
            udid: "00008140-000E788401C0801C".into(),
            peer_id: uuid::Uuid::new_v4().to_string(),
            expected_fingerprint: "short".into(),
        };
        assert!(
            handshake_usb("status", "local", &target, None, false)
                .await
                .unwrap_err()
                .to_string()
                .contains("fingerprint")
        );
    }
}

#[derive(Debug)]
pub struct HandshakeManagementUnavailable;
impl std::fmt::Display for HandshakeManagementUnavailable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("The running Mac app does not provide native handshake management. Use the updated app candidate; no settings were changed.")
    }
}
impl std::error::Error for HandshakeManagementUnavailable {}
