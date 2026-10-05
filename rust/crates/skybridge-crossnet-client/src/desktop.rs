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
    desktop_at(operation, reference, None).await
}

pub async fn desktop_start_at(
    reference: &str,
    host: std::net::Ipv4Addr,
    port: u16,
) -> Result<DesktopResult> {
    desktop_at("start", Some(reference), Some((host, port))).await
}

fn request_params(
    operation: &str,
    reference: Option<&str>,
    endpoint: Option<(std::net::Ipv4Addr, u16)>,
) -> Result<(String, Value)> {
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
    if let (Some((host, port)), "start") = (endpoint, operation) {
        let first = host.octets()[0];
        if port == 0 || first == 0 || first == 127 || first >= 224 {
            bail!("desktop endpoint requires a unicast IPv4 address and nonzero port");
        }
        params["host"] = json!(host.to_string());
        params["port"] = json!(port);
        return Ok(("crossnet.desktop.start_at".to_owned(), params));
    }
    if endpoint.is_some() {
        bail!("desktop endpoint is only valid for start");
    }
    Ok((format!("crossnet.desktop.{operation}"), params))
}

async fn desktop_at(
    operation: &str,
    reference: Option<&str>,
    endpoint: Option<(std::net::Ipv4Addr, u16)>,
) -> Result<DesktopResult> {
    let (method, params) = request_params(operation, reference, endpoint)?;
    let path = default_socket_path()?;
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
    #[test]
    fn direct_start_has_a_distinct_capability_and_complete_endpoint() {
        let id = uuid::Uuid::new_v4().to_string();
        let host = "192.0.2.23".parse().unwrap();
        let (method, params) = request_params("start", Some(&id), Some((host, 59100))).unwrap();
        assert_eq!(method, "crossnet.desktop.start_at");
        assert_eq!(params["device_ref"], id);
        assert_eq!(params["host"], "192.0.2.23");
        assert_eq!(params["port"], 59100);
        assert!(request_params("status", Some(&id), Some((host, 59100))).is_err());
        assert!(request_params("start", None, Some((host, 59100))).is_err());
    }

    #[test]
    fn direct_start_rejects_invalid_routes_before_ipc() {
        let id = uuid::Uuid::new_v4().to_string();
        for address in ["0.0.0.0", "127.0.0.1", "224.0.0.1", "255.255.255.255"] {
            assert!(
                request_params("start", Some(&id), Some((address.parse().unwrap(), 59100)))
                    .is_err()
            );
        }
        assert!(
            request_params("start", Some(&id), Some(("192.0.2.23".parse().unwrap(), 0))).is_err()
        );
    }

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
