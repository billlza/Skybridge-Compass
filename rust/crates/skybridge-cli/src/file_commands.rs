use std::path::Path;
use std::time::Duration;

use anyhow::{Result, bail};
use serde::Serialize;
use serde_json::json;
use skybridge_agent::{
    enqueue_file_transfer_send_request_for_established_session,
    load_file_transfer_request_registry, load_inbound_file_transfer_approval_registry,
    request_inbound_file_transfer_decision, resolve_paths,
};
use skybridge_core::{
    CrossNetworkTransferId, FileTransferControlRequest, FileTransferControlRequestStatus,
    InboundFileTransferApprovalDecision, InboundFileTransferApprovalRequest,
    InboundFileTransferApprovalStatus,
};

use crate::{FileReceiveArgs, FileSendArgs, agent_runtime_guard};

const SCHEMA_VERSION: u32 = 1;
const FILE_TRANSFER_STATUS: &str = "planned";
const FILE_TRANSFER_REQUEST_STATUS: &str = "pending_agent_observation";
const FILE_TRANSFER_REQUEST_REJECTED_STATUS: &str = "rejected";
const FILE_TRANSFER_OBSERVED_STATUS: &str = "agent_observed";
const FILE_TRANSFER_IN_PROGRESS_STATUS: &str = "transfer_in_progress";
const FILE_TRANSFER_COMPLETED_STATUS: &str = "transfer_completed";
const FILE_TRANSFER_FAILED_STATUS: &str = "transfer_failed";
const FILE_TRANSFER_REJECTED_STATUS: &str = "agent_rejected";
const FILE_TRANSFER_TIMED_OUT_STATUS: &str = "timed_out";
const FILE_TRANSFER_RECEIPT_INVALID_STATUS: &str = "receipt_invalid";
const FILE_TRANSFER_EMPTY_STATUS: &str = "read_only_empty";
const FILE_TRANSFER_CONTRACT_SOURCE: &str = "cli_request_contract_only_no_live_transfer_route";
const FILE_TRANSFER_REQUEST_SOURCE: &str =
    "agent_owned_file_transfer_request_registry_live_transfer";
const FILE_TRANSFER_HISTORY_SOURCE: &str = "agent_owned_file_transfer_request_registry";
const FILE_TRANSFER_RUNTIME_OWNER: &str = "skybridge-agent";
const FILE_TRANSFER_POLL_INTERVAL: Duration = Duration::from_millis(100);
const FILE_TRANSFER_ERROR: &str =
    "file transfer send requires an established session id bound to a handshake-complete peer";
const REQUIRED_GATES: &[&str] = &[
    "shared_route_contract",
    "protocol_identity_binding",
    "file_sha256_receipt",
    "receiver_write_policy",
    "real_device_file_transfer_gate",
];

const REQUEST_ONLY_GATES: &[&str] = &[
    "agent_owned_file_transfer_request",
    "agent_observed_file_transfer_request",
    "shared_route_contract",
    "receiver_write_policy",
    "file_sha256_receipt",
    "real_device_file_transfer_gate",
];

#[derive(Debug, Serialize)]
struct FileTransferPlannedReport {
    schema_version: u32,
    capability_id: &'static str,
    action: &'static str,
    accepted: bool,
    status: &'static str,
    mutation_supported: bool,
    route_bound: bool,
    receipt_supported: bool,
    source_path_provided: bool,
    destination_peer_provided: bool,
    source: &'static str,
    error: FileTransferErrorReport,
    required_gates_before_live_transfer: &'static [&'static str],
}

#[derive(Debug, Serialize)]
struct FileTransferErrorReport {
    code: &'static str,
    message: &'static str,
    retryable: bool,
    required_gate: &'static str,
}

#[derive(Debug, Serialize)]
struct FileTransferRequestReport {
    schema_version: u32,
    capability_id: &'static str,
    action: &'static str,
    success: bool,
    accepted: bool,
    status: &'static str,
    detached: bool,
    runtime_owner: &'static str,
    request_registered: bool,
    pending_agent_observation: bool,
    agent_observed: bool,
    transfer_started: bool,
    applied: bool,
    receipt_verified: bool,
    source_path_provided: bool,
    source_regular_file_verified: bool,
    source_sha256_recorded: bool,
    destination_peer_provided: bool,
    destination_bound_to_session_peer: bool,
    session_id: String,
    request_id: String,
    source_size_bytes: u64,
    source: &'static str,
    required_gates_before_live_transfer: &'static [&'static str],
}

#[derive(Debug, Serialize)]
struct FileTransferFailureReport<'a> {
    schema_version: u32,
    capability_id: &'static str,
    action: &'static str,
    success: bool,
    accepted: bool,
    status: &'static str,
    runtime_owner: &'static str,
    session_id: Option<&'a str>,
    request_id: Option<&'a str>,
    request_may_reach_terminal_state: bool,
    error: FileTransferFailureDetail<'a>,
}

#[derive(Debug, Serialize)]
struct FileTransferFailureDetail<'a> {
    code: &'a str,
    message: &'a str,
    retryable: bool,
}

#[derive(Debug, PartialEq, Eq)]
enum FileTransferWaitDecision {
    Pending,
    Complete,
    Failed(FileTransferAttemptFailure),
}

#[derive(Debug, PartialEq, Eq)]
struct FileTransferAttemptFailure {
    code: &'static str,
    message: String,
    retryable: bool,
}

impl FileTransferAttemptFailure {
    fn from_agent_guard(error: agent_runtime_guard::AgentRuntimeGuardError) -> Self {
        Self {
            code: error.code,
            message: error.message,
            retryable: error.retryable,
        }
    }

    fn registry_unavailable(_error: &anyhow::Error) -> Self {
        Self {
            code: "file_transfer_registry_unavailable",
            message: "failed to read the agent-owned file transfer registry".to_owned(),
            retryable: true,
        }
    }

    fn request_missing(request_id: &str) -> Self {
        Self {
            code: "file_transfer_request_missing",
            message: format!(
                "file transfer request `{request_id}` disappeared before reaching a terminal state"
            ),
            retryable: false,
        }
    }

    fn transfer_failed(request: &FileTransferControlRequest) -> Self {
        Self {
            code: "file_transfer_failed",
            message: request
                .failure_reason
                .clone()
                .unwrap_or_else(|| "file transfer failed without a verified receipt".to_owned()),
            retryable: true,
        }
    }

    fn agent_rejected() -> Self {
        Self {
            code: "file_transfer_agent_rejected",
            message: "the active agent rejected the file transfer request".to_owned(),
            retryable: false,
        }
    }

    fn invalid_receipt() -> Self {
        Self {
            code: "file_transfer_receipt_invalid",
            message: "file transfer reached completed state without matching byte-count and verified SHA-256 receipt evidence"
                .to_owned(),
            retryable: false,
        }
    }

    fn timeout(request_id: &str, timeout: Duration) -> Self {
        Self {
            code: "file_transfer_timeout",
            message: format!(
                "file transfer request `{request_id}` did not reach a verified terminal state within {} seconds",
                timeout.as_secs()
            ) + "; the command timeout does not cancel the transfer, so the request may still reach a terminal state",
            retryable: true,
        }
    }
}

#[derive(Debug, Serialize)]
struct FileTransferHistoryReport {
    schema_version: u32,
    capability_id: &'static str,
    status: String,
    source: &'static str,
    history_supported: bool,
    pending_requests: usize,
    history: Vec<FileTransferHistoryEntryReport>,
    required_gates_before_history: &'static [&'static str],
}

#[derive(Debug, Serialize)]
struct FileTransferHistoryEntryReport {
    request_id: String,
    session_id: String,
    status: &'static str,
    action: &'static str,
    pending_agent_observation: bool,
    agent_observed: bool,
    transfer_in_progress: bool,
    transfer_started: bool,
    transfer_completed: bool,
    transfer_failed: bool,
    /// `true` only when the agent recorded the receiver's SHA-256 receipt match.
    receipt_verified: bool,
    receipt_sha256_match: bool,
    bytes_transferred: u64,
    failure_reason: Option<String>,
    source_size_bytes: u64,
    source_regular_file_verified: bool,
    source_sha256_recorded: bool,
    destination_bound_to_session_peer: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Serialize)]
struct InboundFileApprovalListReport {
    schema_version: u32,
    capability_id: &'static str,
    status: &'static str,
    pending_count: usize,
    requests: Vec<InboundFileApprovalEntryReport>,
}

#[derive(Debug, Serialize)]
struct InboundFileApprovalEntryReport {
    transfer_id: String,
    session_id: String,
    authenticated_peer_device_id: String,
    authenticated_peer_device_name: String,
    file_name: String,
    file_size: u64,
    status: &'static str,
    decision: Option<&'static str>,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Serialize)]
struct InboundFileApprovalDecisionReport {
    schema_version: u32,
    capability_id: &'static str,
    action: &'static str,
    success: bool,
    accepted: bool,
    applied: bool,
    status: &'static str,
    session_id: String,
    transfer_id: String,
    authenticated_peer_device_id: String,
    authenticated_peer_device_name: String,
    file_name: String,
    file_size: u64,
}

pub(crate) fn send_placeholder(path: &Path, to: &str, as_json: bool) -> Result<()> {
    if as_json {
        print_planned_mutation_report(planned_mutation_report(
            "file.transfer.send",
            "send",
            !path.as_os_str().is_empty(),
            !to.trim().is_empty(),
        ))?;
    }
    bail!(
        "{FILE_TRANSFER_ERROR}: `send` requires shared route proof, protocol identity binding, file SHA-256 receipt evidence, receiver write policy, and real-device file-transfer validation"
    )
}

pub(crate) async fn send(state_dir: Option<std::path::PathBuf>, args: FileSendArgs) -> Result<()> {
    let Some(session_id) = args
        .session_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return send_placeholder(&args.path, &args.to, args.output.json);
    };

    let paths = resolve_paths(state_dir)?;
    require_active_agent_for_file_send(&paths, args.output.json, session_id, None).await?;
    let request = match enqueue_file_transfer_send_request_for_established_session(
        &paths, session_id, &args.to, &args.path,
    )
    .await
    {
        Ok(request) => request,
        Err(error) => {
            if args.output.json {
                print_request_rejection_report(
                    session_id,
                    "file_transfer_request_rejected",
                    "file transfer request was rejected before agent observation",
                )?;
                bail!("file transfer request rejected before agent observation");
            }
            return Err(error);
        }
    };

    if args.detach {
        require_active_agent_for_file_send(
            &paths,
            args.output.json,
            session_id,
            Some(&request.request_id),
        )
        .await?;
        return json_or_text(
            args.output.json,
            json!(request_report(&request, true)),
            &format!(
                "File transfer send request {} was registered for the active agent on session {}; detached before agent observation or completion.",
                request.request_id, request.session_id
            ),
        );
    }

    let timeout = Duration::from_secs(args.timeout_seconds);
    match wait_for_file_transfer(&paths, &request.request_id, timeout).await {
        Ok(completed) => json_or_text(
            args.output.json,
            json!(request_report(&completed, false)),
            &format!(
                "File transfer {} completed with a verified matching SHA-256 receipt.",
                completed.request_id
            ),
        ),
        Err(failure) => {
            print_file_transfer_failure_if_requested(
                args.output.json,
                true,
                Some(session_id),
                Some(&request.request_id),
                &failure,
            )?;
            bail!(failure.message)
        }
    }
}

async fn require_active_agent_for_file_send(
    paths: &skybridge_agent::AgentPaths,
    as_json: bool,
    session_id: &str,
    request_id: Option<&str>,
) -> Result<()> {
    let failure = match agent_runtime_guard::require_active_agent(paths).await {
        Ok(()) => return Ok(()),
        Err(error) => FileTransferAttemptFailure::from_agent_guard(error),
    };
    print_file_transfer_failure_if_requested(
        as_json,
        request_id.is_some(),
        Some(session_id),
        request_id,
        &failure,
    )?;
    bail!(failure.message)
}

async fn wait_for_file_transfer(
    paths: &skybridge_agent::AgentPaths,
    request_id: &str,
    timeout: Duration,
) -> std::result::Result<FileTransferControlRequest, FileTransferAttemptFailure> {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let registry = load_file_transfer_request_registry(paths)
            .await
            .map_err(|error| FileTransferAttemptFailure::registry_unavailable(&error))?;
        let request = registry
            .get(request_id)
            .cloned()
            .ok_or_else(|| FileTransferAttemptFailure::request_missing(request_id))?;

        match evaluate_file_transfer_request(&request) {
            FileTransferWaitDecision::Pending => {}
            FileTransferWaitDecision::Complete => return Ok(request),
            FileTransferWaitDecision::Failed(failure) => return Err(failure),
        }

        agent_runtime_guard::require_active_agent(paths)
            .await
            .map_err(FileTransferAttemptFailure::from_agent_guard)?;
        if tokio::time::Instant::now() >= deadline {
            return Err(FileTransferAttemptFailure::timeout(request_id, timeout));
        }
        tokio::time::sleep(FILE_TRANSFER_POLL_INTERVAL).await;
    }
}

fn evaluate_file_transfer_request(
    request: &FileTransferControlRequest,
) -> FileTransferWaitDecision {
    match request.status {
        FileTransferControlRequestStatus::PendingAgentObservation
        | FileTransferControlRequestStatus::AgentObserved
        | FileTransferControlRequestStatus::TransferInProgress => FileTransferWaitDecision::Pending,
        FileTransferControlRequestStatus::TransferCompleted
            if request.bytes_transferred == request.source.size_bytes
                && request.receipt_verified
                && request.receipt_sha256_match =>
        {
            FileTransferWaitDecision::Complete
        }
        FileTransferControlRequestStatus::TransferCompleted => {
            FileTransferWaitDecision::Failed(FileTransferAttemptFailure::invalid_receipt())
        }
        FileTransferControlRequestStatus::TransferFailed => {
            FileTransferWaitDecision::Failed(FileTransferAttemptFailure::transfer_failed(request))
        }
        FileTransferControlRequestStatus::AgentRejected => {
            FileTransferWaitDecision::Failed(FileTransferAttemptFailure::agent_rejected())
        }
    }
}

pub(crate) async fn receive(
    state_dir: Option<std::path::PathBuf>,
    args: FileReceiveArgs,
) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    if args.list {
        let registry = load_inbound_file_transfer_approval_registry(&paths).await?;
        let requests = registry
            .values_sorted()
            .into_iter()
            .map(inbound_approval_entry)
            .collect::<Vec<_>>();
        let pending_count = requests
            .iter()
            .filter(|request| request.status == "pending_decision")
            .count();
        let report = InboundFileApprovalListReport {
            schema_version: SCHEMA_VERSION,
            capability_id: "file.transfer.receive.approvals",
            status: if pending_count == 0 {
                "empty"
            } else {
                "pending"
            },
            pending_count,
            requests,
        };
        return json_or_text(
            args.output.json,
            json!(report),
            &format!("Inbound file approvals pending: {pending_count}"),
        );
    }

    let session_id = args
        .session_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow::anyhow!("--session-id is required for accept/reject"))?;
    let (action, transfer_id, decision) = match (args.accept.as_deref(), args.reject.as_deref()) {
        (Some(transfer_id), None) => (
            "accept",
            transfer_id,
            InboundFileTransferApprovalDecision::Approve,
        ),
        (None, Some(transfer_id)) => (
            "reject",
            transfer_id,
            InboundFileTransferApprovalDecision::Reject,
        ),
        _ => bail!("exactly one of --accept or --reject is required"),
    };
    CrossNetworkTransferId::parse(transfer_id.to_owned())?;
    agent_runtime_guard::require_active_agent(&paths)
        .await
        .map_err(|error| anyhow::anyhow!(error.message))?;
    let request =
        request_inbound_file_transfer_decision(&paths, session_id, transfer_id, decision).await?;
    let report = InboundFileApprovalDecisionReport {
        schema_version: SCHEMA_VERSION,
        capability_id: "file.transfer.receive.approval",
        action,
        success: true,
        accepted: true,
        applied: false,
        status: "decision_requested",
        session_id: request.session_id.clone(),
        transfer_id: request.transfer_id.clone(),
        authenticated_peer_device_id: request.authenticated_peer_device_id.clone(),
        authenticated_peer_device_name: request.authenticated_peer_device_name.clone(),
        file_name: request.file_name.clone(),
        file_size: request.file_size,
    };
    json_or_text(
        args.output.json,
        json!(report),
        &format!(
            "Inbound file transfer {} {} decision was registered for the active agent.",
            request.transfer_id, action
        ),
    )
}

fn inbound_approval_entry(
    request: InboundFileTransferApprovalRequest,
) -> InboundFileApprovalEntryReport {
    InboundFileApprovalEntryReport {
        transfer_id: request.transfer_id,
        session_id: request.session_id,
        authenticated_peer_device_id: request.authenticated_peer_device_id,
        authenticated_peer_device_name: request.authenticated_peer_device_name,
        file_name: request.file_name,
        file_size: request.file_size,
        status: match request.status {
            InboundFileTransferApprovalStatus::PendingDecision => "pending_decision",
            InboundFileTransferApprovalStatus::DecisionRequested => "decision_requested",
            InboundFileTransferApprovalStatus::AgentApplied => "agent_applied",
            InboundFileTransferApprovalStatus::AgentFailed => "agent_failed",
        },
        decision: request.decision.map(|decision| match decision {
            InboundFileTransferApprovalDecision::Approve => "approve",
            InboundFileTransferApprovalDecision::Reject => "reject",
            InboundFileTransferApprovalDecision::Expire => "expire",
        }),
        created_at: request.created_at.to_string(),
        updated_at: request.updated_at.to_string(),
    }
}

pub(crate) async fn history(state_dir: Option<std::path::PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let registry = load_file_transfer_request_registry(&paths).await?;
    let report = history_report(registry.values_sorted());
    let text = format!(
        "File transfer pending requests: {}",
        report.pending_requests
    );
    json_or_text(as_json, json!(report), &text)
}

fn planned_mutation_report(
    capability_id: &'static str,
    action: &'static str,
    source_path_provided: bool,
    destination_peer_provided: bool,
) -> FileTransferPlannedReport {
    FileTransferPlannedReport {
        schema_version: SCHEMA_VERSION,
        capability_id,
        action,
        accepted: false,
        status: FILE_TRANSFER_STATUS,
        mutation_supported: false,
        route_bound: false,
        receipt_supported: false,
        source_path_provided,
        destination_peer_provided,
        source: FILE_TRANSFER_CONTRACT_SOURCE,
        error: FileTransferErrorReport {
            code: "file_transfer_not_wired",
            message: FILE_TRANSFER_ERROR,
            retryable: false,
            required_gate: "shared_route_contract",
        },
        required_gates_before_live_transfer: REQUIRED_GATES,
    }
}

fn history_report(requests: Vec<FileTransferControlRequest>) -> FileTransferHistoryReport {
    let history = requests
        .into_iter()
        .map(history_entry_report)
        .collect::<Vec<_>>();
    let pending_requests = history
        .iter()
        .filter(|request| request.pending_agent_observation)
        .count();
    let in_progress = history.iter().filter(|r| r.transfer_in_progress).count();
    let completed = history.iter().filter(|r| r.transfer_completed).count();
    let failed = history.iter().filter(|r| r.transfer_failed).count();
    let observed = history.iter().filter(|r| r.agent_observed).count();
    let status = if pending_requests > 0 {
        FILE_TRANSFER_REQUEST_STATUS
    } else if in_progress > 0 {
        FILE_TRANSFER_IN_PROGRESS_STATUS
    } else if completed > 0 {
        FILE_TRANSFER_COMPLETED_STATUS
    } else if failed > 0 {
        FILE_TRANSFER_FAILED_STATUS
    } else if observed > 0 {
        FILE_TRANSFER_OBSERVED_STATUS
    } else {
        FILE_TRANSFER_EMPTY_STATUS
    };
    FileTransferHistoryReport {
        schema_version: SCHEMA_VERSION,
        capability_id: "file.transfer.history",
        status: status.to_owned(),
        source: FILE_TRANSFER_HISTORY_SOURCE,
        history_supported: true,
        pending_requests,
        history,
        required_gates_before_history: REQUIRED_GATES,
    }
}

fn history_entry_report(request: FileTransferControlRequest) -> FileTransferHistoryEntryReport {
    let status = file_transfer_status_label(request.status);
    let pending_agent_observation = request.is_pending_agent_observation();
    let agent_observed = request.is_agent_observed();
    let transfer_in_progress = request.is_transfer_in_progress();
    let transfer_completed = request.is_transfer_completed();
    let transfer_failed = request.is_transfer_failed();
    FileTransferHistoryEntryReport {
        request_id: request.request_id,
        session_id: request.session_id,
        status,
        action: "send",
        pending_agent_observation,
        agent_observed,
        transfer_in_progress,
        transfer_started: request.transfer_started_at.is_some(),
        transfer_completed,
        transfer_failed,
        receipt_verified: request.receipt_verified,
        receipt_sha256_match: request.receipt_sha256_match,
        bytes_transferred: request.bytes_transferred,
        failure_reason: request.failure_reason,
        source_size_bytes: request.source.size_bytes,
        source_regular_file_verified: true,
        source_sha256_recorded: !request.source.sha256_hex.trim().is_empty(),
        destination_bound_to_session_peer: true,
        created_at: request.created_at.to_string(),
        updated_at: request.updated_at.to_string(),
    }
}

fn file_transfer_status_label(status: FileTransferControlRequestStatus) -> &'static str {
    match status {
        FileTransferControlRequestStatus::PendingAgentObservation => FILE_TRANSFER_REQUEST_STATUS,
        FileTransferControlRequestStatus::AgentObserved => FILE_TRANSFER_OBSERVED_STATUS,
        FileTransferControlRequestStatus::TransferInProgress => FILE_TRANSFER_IN_PROGRESS_STATUS,
        FileTransferControlRequestStatus::TransferCompleted => FILE_TRANSFER_COMPLETED_STATUS,
        FileTransferControlRequestStatus::TransferFailed => FILE_TRANSFER_FAILED_STATUS,
        FileTransferControlRequestStatus::AgentRejected => FILE_TRANSFER_REJECTED_STATUS,
    }
}

fn request_report(
    request: &FileTransferControlRequest,
    detached: bool,
) -> FileTransferRequestReport {
    let success = request.status == FileTransferControlRequestStatus::TransferCompleted
        && request.receipt_verified
        && request.receipt_sha256_match;
    let pending_agent_observation = request.is_pending_agent_observation();
    let agent_observed = !pending_agent_observation;
    FileTransferRequestReport {
        schema_version: SCHEMA_VERSION,
        capability_id: "file.transfer.send",
        action: "send",
        success,
        accepted: true,
        status: file_transfer_status_label(request.status),
        detached,
        runtime_owner: FILE_TRANSFER_RUNTIME_OWNER,
        request_registered: true,
        pending_agent_observation,
        agent_observed,
        transfer_started: request.transfer_started_at.is_some(),
        applied: success,
        receipt_verified: request.receipt_verified,
        source_path_provided: true,
        source_regular_file_verified: true,
        source_sha256_recorded: true,
        destination_peer_provided: true,
        destination_bound_to_session_peer: true,
        session_id: request.session_id.clone(),
        request_id: request.request_id.clone(),
        source_size_bytes: request.source.size_bytes,
        source: FILE_TRANSFER_REQUEST_SOURCE,
        required_gates_before_live_transfer: if success { &[] } else { REQUEST_ONLY_GATES },
    }
}

fn print_planned_mutation_report(report: FileTransferPlannedReport) -> Result<()> {
    crate::cli_output::write_json_failure(&report)
}

fn print_request_rejection_report(
    session_id: &str,
    code: &'static str,
    message: &'static str,
) -> Result<()> {
    let payload = json!({
        "schema_version": SCHEMA_VERSION,
        "capability_id": "file.transfer.send",
        "action": "send",
        "success": false,
        "accepted": false,
        "status": FILE_TRANSFER_REQUEST_REJECTED_STATUS,
        "runtime_owner": FILE_TRANSFER_RUNTIME_OWNER,
        "request_registered": false,
        "pending_agent_observation": false,
        "agent_observed": false,
        "transfer_started": false,
        "applied": false,
        "receipt_verified": false,
        "session_id_provided": !session_id.trim().is_empty(),
        "error": {
            "code": code,
            "message": message,
            "retryable": false,
            "required_gate": "agent_owned_file_transfer_request"
        },
        "required_gates_before_live_transfer": REQUEST_ONLY_GATES
    });
    crate::cli_output::write_json_failure(&payload)
}

fn print_file_transfer_failure_if_requested(
    as_json: bool,
    accepted: bool,
    session_id: Option<&str>,
    request_id: Option<&str>,
    failure: &FileTransferAttemptFailure,
) -> Result<()> {
    if as_json {
        let report = file_transfer_failure_report(accepted, session_id, request_id, failure);
        crate::cli_output::write_json_failure(&report)?;
    }
    Ok(())
}

fn file_transfer_failure_report<'a>(
    accepted: bool,
    session_id: Option<&'a str>,
    request_id: Option<&'a str>,
    failure: &'a FileTransferAttemptFailure,
) -> FileTransferFailureReport<'a> {
    FileTransferFailureReport {
        schema_version: SCHEMA_VERSION,
        capability_id: "file.transfer.send",
        action: "send",
        success: false,
        accepted,
        status: file_transfer_failure_status(failure),
        runtime_owner: FILE_TRANSFER_RUNTIME_OWNER,
        session_id,
        request_id,
        request_may_reach_terminal_state: accepted
            && matches!(
                failure.code,
                "agent_unavailable"
                    | "agent_state_check_failed"
                    | "agent_health_unavailable"
                    | "agent_health_missing"
                    | "agent_health_schema_mismatch"
                    | "agent_health_state_dir_mismatch"
                    | "agent_not_healthy"
                    | "agent_health_stale"
                    | "file_transfer_timeout"
                    | "file_transfer_registry_unavailable"
            ),
        error: FileTransferFailureDetail {
            code: failure.code,
            message: &failure.message,
            retryable: failure.retryable,
        },
    }
}

fn file_transfer_failure_status(failure: &FileTransferAttemptFailure) -> &'static str {
    match failure.code {
        "agent_unavailable"
        | "agent_state_check_failed"
        | "agent_health_unavailable"
        | "agent_health_missing"
        | "agent_health_schema_mismatch"
        | "agent_health_state_dir_mismatch"
        | "agent_not_healthy"
        | "agent_health_stale" => FILE_TRANSFER_REQUEST_REJECTED_STATUS,
        "file_transfer_timeout" => FILE_TRANSFER_TIMED_OUT_STATUS,
        "file_transfer_agent_rejected" => FILE_TRANSFER_REJECTED_STATUS,
        "file_transfer_failed" => FILE_TRANSFER_FAILED_STATUS,
        "file_transfer_receipt_invalid" => FILE_TRANSFER_RECEIPT_INVALID_STATUS,
        "file_transfer_registry_unavailable" | "file_transfer_request_missing" => "failed",
        _ => "failed",
    }
}

fn json_or_text(as_json: bool, payload: serde_json::Value, text: &str) -> Result<()> {
    if as_json {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("{text}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_send_placeholder_covers_text_errors() -> Result<()> {
        assert!(send_placeholder(Path::new("/tmp/payload.txt"), "peer-device", false).is_err());
        Ok(())
    }

    #[test]
    fn public_file_failures_do_not_echo_internal_error_chains() {
        let sentinel = "/Users/example/private/session-token-secret";
        let internal = anyhow::anyhow!("registry failed at {sentinel}");
        let failure = FileTransferAttemptFailure::registry_unavailable(&internal);

        assert_eq!(failure.code, "file_transfer_registry_unavailable");
        assert!(!failure.message.contains(sentinel));
    }

    #[test]
    fn file_transfer_contract_stays_planned_without_path_or_peer_leakage() -> Result<()> {
        let send_report = planned_mutation_report("file.transfer.send", "send", true, true);
        assert_eq!(send_report.schema_version, 1);
        assert_eq!(send_report.status, "planned");
        assert!(!send_report.accepted);
        assert!(!send_report.mutation_supported);
        assert!(!send_report.route_bound);
        assert!(!send_report.receipt_supported);
        assert_eq!(send_report.error.required_gate, "shared_route_contract");
        assert!(
            send_report
                .required_gates_before_live_transfer
                .contains(&"real_device_file_transfer_gate")
        );
        let serialized = serde_json::to_string(&send_report)?;
        assert!(
            !serialized.contains("/tmp/payload.txt") && !serialized.contains("peer-device"),
            "planned file-transfer contract must not leak local paths or peer identifiers"
        );

        let history = history_report(Vec::new());
        assert_eq!(history.status, "read_only_empty");
        assert!(history.history_supported);
        assert_eq!(history.pending_requests, 0);
        assert!(history.history.is_empty());
        Ok(())
    }

    #[test]
    fn file_transfer_history_projects_pending_requests_without_private_details() -> Result<()> {
        let mut request = FileTransferControlRequest::pending_send(
            "request-1",
            "session-1",
            "runtime-1",
            skybridge_core::FileTransferSourceSnapshot {
                source_path: "/Users/bill/private/secret.bin".to_owned(),
                size_bytes: 42,
                sha256_hex: "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
                    .to_owned(),
            },
            skybridge_core::FileTransferDestinationBinding {
                requested_peer_ref: "peer-secret".to_owned(),
                remote_device_id: "remote-device-secret".to_owned(),
                remote_protocol_public_key_fingerprint: "fingerprint-secret".to_owned(),
            },
        );

        let history = history_report(vec![request.clone()]);
        assert_eq!(history.status, "pending_agent_observation");
        assert_eq!(history.pending_requests, 1);
        assert_eq!(history.history.len(), 1);
        assert_eq!(history.history[0].status, "pending_agent_observation");
        assert!(history.history[0].pending_agent_observation);
        assert!(!history.history[0].agent_observed);
        assert_eq!(history.history[0].source_size_bytes, 42);
        assert!(history.history[0].source_sha256_recorded);
        request.mark_agent_observed(time::OffsetDateTime::now_utc());
        let history = history_report(vec![request]);
        assert_eq!(history.status, "agent_observed");
        assert_eq!(history.pending_requests, 0);
        assert_eq!(history.history[0].status, "agent_observed");
        assert!(!history.history[0].pending_agent_observation);
        assert!(history.history[0].agent_observed);
        assert!(!history.history[0].transfer_started);
        assert!(!history.history[0].transfer_completed);
        assert!(!history.history[0].receipt_verified);

        let serialized = serde_json::to_string(&history)?;
        for secret in [
            "/Users/bill/private/secret.bin",
            "peer-secret",
            "remote-device-secret",
            "fingerprint-secret",
            "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
            "runtime-1",
        ] {
            assert!(
                !serialized.contains(secret),
                "file history public projection leaked {secret}: {serialized}"
            );
        }
        Ok(())
    }

    fn sample_request() -> FileTransferControlRequest {
        FileTransferControlRequest::pending_send(
            "request-evidence",
            "session-evidence",
            "runtime-evidence",
            skybridge_core::FileTransferSourceSnapshot {
                source_path: "/tmp/data.bin".to_owned(),
                size_bytes: 100,
                sha256_hex: "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
                    .to_owned(),
            },
            skybridge_core::FileTransferDestinationBinding {
                requested_peer_ref: "peer".to_owned(),
                remote_device_id: "remote".to_owned(),
                remote_protocol_public_key_fingerprint: "fp".to_owned(),
            },
        )
    }

    #[test]
    fn history_surfaces_completed_transfer_evidence() {
        let now = time::OffsetDateTime::now_utc();
        let mut request = sample_request();
        request.mark_transfer_started(now);
        request.mark_transfer_completed(100, now);
        let history = history_report(vec![request]);
        assert_eq!(history.status, "transfer_completed");
        let entry = &history.history[0];
        assert_eq!(entry.status, "transfer_completed");
        assert!(entry.transfer_started);
        assert!(entry.transfer_completed);
        assert!(entry.receipt_verified);
        assert!(entry.receipt_sha256_match);
        assert_eq!(entry.bytes_transferred, 100);
        assert!(entry.failure_reason.is_none());
    }

    #[test]
    fn history_surfaces_failed_transfer_without_claiming_receipt() {
        let now = time::OffsetDateTime::now_utc();
        let mut request = sample_request();
        request.mark_transfer_started(now);
        request.mark_transfer_failed("transfer transport error", now);
        let history = history_report(vec![request]);
        assert_eq!(history.status, "transfer_failed");
        let entry = &history.history[0];
        assert_eq!(entry.status, "transfer_failed");
        assert!(entry.transfer_started);
        assert!(entry.transfer_failed);
        assert!(
            !entry.receipt_verified,
            "failed transfer must never claim a verified receipt"
        );
        assert!(!entry.transfer_completed);
        assert_eq!(
            entry.failure_reason.as_deref(),
            Some("transfer transport error")
        );
    }

    #[test]
    fn file_send_wait_decision_requires_verified_matching_receipt() {
        let now = time::OffsetDateTime::now_utc();
        let mut request = sample_request();
        assert_eq!(
            evaluate_file_transfer_request(&request),
            FileTransferWaitDecision::Pending
        );

        request.mark_transfer_started(now);
        assert_eq!(
            evaluate_file_transfer_request(&request),
            FileTransferWaitDecision::Pending
        );

        request.mark_transfer_completed(100, now);
        assert_eq!(
            evaluate_file_transfer_request(&request),
            FileTransferWaitDecision::Complete
        );

        request.receipt_sha256_match = false;
        let FileTransferWaitDecision::Failed(failure) = evaluate_file_transfer_request(&request)
        else {
            panic!("completed transfer without matching receipt must fail closed");
        };
        assert_eq!(failure.code, "file_transfer_receipt_invalid");

        request.receipt_sha256_match = true;
        request.bytes_transferred = 99;
        let FileTransferWaitDecision::Failed(failure) = evaluate_file_transfer_request(&request)
        else {
            panic!("completed transfer with a byte-count mismatch must fail closed");
        };
        assert_eq!(failure.code, "file_transfer_receipt_invalid");
    }

    #[test]
    fn file_send_wait_decision_surfaces_failure_and_rejection() {
        let now = time::OffsetDateTime::now_utc();
        let mut failed = sample_request();
        failed.mark_transfer_failed("transport closed", now);
        let FileTransferWaitDecision::Failed(failure) = evaluate_file_transfer_request(&failed)
        else {
            panic!("transfer failure must be terminal");
        };
        assert_eq!(failure.code, "file_transfer_failed");
        assert_eq!(failure.message, "transport closed");

        let mut rejected = sample_request();
        rejected.status = FileTransferControlRequestStatus::AgentRejected;
        let FileTransferWaitDecision::Failed(failure) = evaluate_file_transfer_request(&rejected)
        else {
            panic!("agent rejection must be terminal");
        };
        assert_eq!(failure.code, "file_transfer_agent_rejected");
    }

    #[test]
    fn file_send_json_only_claims_success_for_verified_completion() -> Result<()> {
        let pending = sample_request();
        let pending_payload = serde_json::to_value(request_report(&pending, true))?;
        assert_eq!(pending_payload["schema_version"], 1);
        assert_eq!(pending_payload["capability_id"], "file.transfer.send");
        assert_eq!(pending_payload["success"], false);
        assert_eq!(pending_payload["accepted"], true);
        assert_eq!(pending_payload["detached"], true);
        assert_eq!(pending_payload["status"], "pending_agent_observation");
        assert_eq!(pending_payload["runtime_owner"], "skybridge-agent");
        assert_eq!(pending_payload["receipt_verified"], false);

        let now = time::OffsetDateTime::now_utc();
        let mut completed = sample_request();
        completed.mark_transfer_started(now);
        completed.mark_transfer_completed(100, now);
        let completed_payload = serde_json::to_value(request_report(&completed, false))?;
        assert_eq!(completed_payload["success"], true);
        assert_eq!(completed_payload["detached"], false);
        assert_eq!(completed_payload["status"], "transfer_completed");
        assert_eq!(completed_payload["applied"], true);
        assert_eq!(completed_payload["receipt_verified"], true);
        assert_eq!(
            completed_payload["required_gates_before_live_transfer"],
            serde_json::json!([])
        );
        Ok(())
    }

    #[test]
    fn file_send_failure_statuses_preserve_real_state() {
        let guard_failure = FileTransferAttemptFailure::from_agent_guard(
            agent_runtime_guard::AgentRuntimeGuardError {
                code: "agent_unavailable",
                message: "agent unavailable".to_owned(),
                retryable: true,
            },
        );
        assert_eq!(
            file_transfer_failure_status(&guard_failure),
            FILE_TRANSFER_REQUEST_REJECTED_STATUS
        );
        assert_eq!(
            file_transfer_failure_status(&FileTransferAttemptFailure::timeout(
                "request-1",
                Duration::from_secs(300),
            )),
            FILE_TRANSFER_TIMED_OUT_STATUS
        );
        assert_eq!(
            file_transfer_failure_status(&FileTransferAttemptFailure::agent_rejected()),
            FILE_TRANSFER_REJECTED_STATUS
        );
        let now = time::OffsetDateTime::now_utc();
        let mut failed = sample_request();
        failed.mark_transfer_failed("transport closed", now);
        assert_eq!(
            file_transfer_failure_status(&FileTransferAttemptFailure::transfer_failed(&failed)),
            FILE_TRANSFER_FAILED_STATUS
        );
    }

    #[test]
    fn file_send_timeout_json_does_not_claim_cancellation() -> Result<()> {
        let failure = FileTransferAttemptFailure::timeout("request-1", Duration::from_secs(300));
        let report =
            file_transfer_failure_report(true, Some("session-1"), Some("request-1"), &failure);
        let payload = serde_json::to_value(report)?;
        assert_eq!(payload["success"], false);
        assert_eq!(payload["accepted"], true);
        assert_eq!(payload["status"], "timed_out");
        assert_eq!(payload["request_may_reach_terminal_state"], true);
        assert!(
            payload["error"]["message"]
                .as_str()
                .expect("timeout message")
                .contains("does not cancel")
        );
        Ok(())
    }
}
