use super::*;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DesktopDevice {
    pub device_ref: String,
    pub name: String,
    pub platform: Option<String>,
    pub available: bool,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DesktopSession {
    pub session_ref: String,
    pub device_ref: String,
    pub name: String,
    pub phase: String,
    pub window_visible: bool,
    pub frame_presented: bool,
    pub input_authorized: bool,
    pub input_ready: bool,
    pub error_code: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DesktopResult {
    pub runtime_target: String,
    pub operation: String,
    pub devices: Vec<DesktopDevice>,
    pub sessions: Vec<DesktopSession>,
}

fn validate(
    result: DesktopResult,
    operation: &str,
    reference: Option<&str>,
) -> Result<DesktopResult> {
    if result.runtime_target != "mac_app_runtime"
        || result.operation != operation
        || result.devices.len() > 512
        || result.sessions.len() > 32
    {
        bail!("invalid native desktop result");
    }
    let mut devices = std::collections::HashSet::new();
    for device in &result.devices {
        uuid::Uuid::parse_str(&device.device_ref)?;
        if !devices.insert(&device.device_ref) || (device.available && device.reason.is_some()) {
            bail!("contradictory desktop device capability");
        }
    }
    let mut sessions = std::collections::HashSet::new();
    for session in &result.sessions {
        uuid::Uuid::parse_str(&session.session_ref)?;
        uuid::Uuid::parse_str(&session.device_ref)?;
        if !sessions.insert(&session.session_ref)
            || ![
                "connecting",
                "waiting_frame",
                "ready",
                "stopping",
                "closed",
                "failed",
            ]
            .contains(&session.phase.as_str())
            || (session.input_ready
                && !(session.input_authorized && session.frame_presented && session.window_visible))
            || (session.phase == "ready" && !session.frame_presented)
            || (["closed", "failed"].contains(&session.phase.as_str())
                && (session.frame_presented || session.input_ready))
        {
            bail!("contradictory desktop readiness");
        }
    }
    if let Some(reference) = reference {
        let expected = uuid::Uuid::parse_str(reference)?;
        let session = result
            .sessions
            .first()
            .filter(|_| result.sessions.len() == 1)
            .ok_or_else(|| anyhow!("desktop result omitted the exact requested session"))?;
        let observed = if operation == "start" {
            &session.device_ref
        } else {
            &session.session_ref
        };
        if uuid::Uuid::parse_str(observed)? != expected {
            bail!("desktop result belongs to a different target");
        }
    }
    Ok(result)
}

pub async fn desktop(operation: &str, reference: Option<&str>) -> Result<DesktopResult> {
    if !["devices", "start", "status", "stop"].contains(&operation) {
        bail!("unknown desktop operation");
    }
    if ["start", "stop"].contains(&operation) && reference.is_none() {
        bail!("desktop operation requires an exact reference");
    }
    let mut params = json!({});
    if let Some(reference) = reference {
        uuid::Uuid::parse_str(reference)?;
        params[if operation == "start" {
            "device_ref"
        } else {
            "session_ref"
        }] = json!(reference);
    }
    let path = default_socket_path()?;
    let method = format!("crossnet.desktop.{operation}");
    preflight_app_method_at_path(&path, &method).await?;
    validate(
        parse_result(&method, call_at_path(&path, &method, params).await?)?,
        operation,
        reference,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn response() -> DesktopResult {
        DesktopResult {
            runtime_target: "mac_app_runtime".into(),
            operation: "status".into(),
            devices: vec![],
            sessions: vec![DesktopSession {
                session_ref: uuid::Uuid::new_v4().to_string(),
                device_ref: uuid::Uuid::new_v4().to_string(),
                name: "host".into(),
                phase: "connecting".into(),
                window_visible: false,
                frame_presented: false,
                input_authorized: false,
                input_ready: false,
                error_code: None,
            }],
        }
    }
    #[test]
    fn connected_socket_cannot_claim_visible_video_or_input() {
        let mut r = response();
        r.sessions[0].phase = "ready".into();
        assert!(validate(r, "status", None).is_err());
        let mut r = response();
        r.sessions[0].input_ready = true;
        assert!(validate(r, "status", None).is_err());
    }
    #[test]
    fn stops_and_status_are_bound_to_the_exact_session() {
        let r = response();
        let reference = r.sessions[0].session_ref.clone();
        assert!(validate(r.clone(), "status", Some(&reference)).is_ok());
        assert!(validate(r, "status", Some(&uuid::Uuid::new_v4().to_string())).is_err());
    }
}
