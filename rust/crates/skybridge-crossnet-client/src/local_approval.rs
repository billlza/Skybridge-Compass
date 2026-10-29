use super::*;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct LocalApproval {
    pub id: String,
    pub kind: String,
    pub peer_id: String,
    pub name: String,
    pub fingerprint: Option<String>,
    pub verification_code: Option<String>,
    pub can_decide: bool,
}
#[derive(Debug, Deserialize, Serialize)]
pub struct LocalApprovalResult {
    pub runtime_target: String,
    pub pending: Vec<LocalApproval>,
    pub decision_submitted: bool,
    pub approval_id: Option<String>,
}

pub async fn local_approvals() -> Result<LocalApprovalResult> {
    local_approval_call("pending", json!({}), None).await
}
pub async fn decide_local_approval(
    id: &str,
    decision: &str,
    code: Option<&str>,
) -> Result<LocalApprovalResult> {
    uuid::Uuid::parse_str(id)?;
    if !["allow_once", "always_allow", "reject"].contains(&decision) {
        bail!("invalid approval decision");
    }
    let mut params = json!({"approval_id":id,"decision":decision});
    if let Some(code) = code {
        params["verification_code"] = json!(code);
    }
    local_approval_call("decide", params, Some(id)).await
}
async fn local_approval_call(
    action: &str,
    params: Value,
    expected: Option<&str>,
) -> Result<LocalApprovalResult> {
    let path = default_socket_path()?;
    let method = format!("crossnet.approval.{action}");
    preflight_app_method_at_path(&path, &method).await?;
    let result: LocalApprovalResult =
        parse_result(&method, call_at_path(&path, &method, params).await?)?;
    if result.runtime_target != "mac_app_runtime" || result.pending.len() > 8 {
        bail!("invalid local approval result");
    }
    let mut ids = std::collections::HashSet::new();
    for prompt in &result.pending {
        let id = uuid::Uuid::parse_str(&prompt.id)?;
        if !ids.insert(id)
            || !["pairing", "file_delegation", "handshake_configuration"]
                .contains(&prompt.kind.as_str())
        {
            bail!("invalid local approval prompt");
        }
    }
    match expected {
        Some(id)
            if !result.decision_submitted
                || result
                    .approval_id
                    .as_deref()
                    .and_then(|s| uuid::Uuid::parse_str(s).ok())
                    != Some(uuid::Uuid::parse_str(id)?) =>
        {
            bail!("local approval decision not confirmed")
        }
        None if result.decision_submitted || result.approval_id.is_some() => {
            bail!("read-only approval request reported a decision")
        }
        _ => Ok(result),
    }
}
