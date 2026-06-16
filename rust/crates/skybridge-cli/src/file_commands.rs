use std::path::Path;

use anyhow::{Result, bail};
use serde::Serialize;
use serde_json::json;
use skybridge_agent::{
    enqueue_file_transfer_send_request_for_established_session,
    load_file_transfer_request_registry, resolve_paths,
};
use skybridge_core::{FileTransferControlRequest, FileTransferControlRequestStatus};

use crate::FileSendArgs;

const SCHEMA_VERSION: u32 = 1;
const FILE_TRANSFER_STATUS: &str = "planned";
const FILE_TRANSFER_REQUEST_STATUS: &str = "pending_agent_observation";
const FILE_TRANSFER_REQUEST_REJECTED_STATUS: &str = "rejected";
const FILE_TRANSFER_OBSERVED_STATUS: &str = "agent_observed";
const FILE_TRANSFER_IN_PROGRESS_STATUS: &str = "transfer_in_progress";
const FILE_TRANSFER_COMPLETED_STATUS: &str = "transfer_completed";
const FILE_TRANSFER_FAILED_STATUS: &str = "transfer_failed";
const FILE_TRANSFER_REJECTED_STATUS: &str = "agent_rejected";
const FILE_TRANSFER_EMPTY_STATUS: &str = "read_only_empty";
const FILE_TRANSFER_CONTRACT_SOURCE: &str = "cli_request_contract_only_no_live_transfer_route";
const FILE_TRANSFER_REQUEST_SOURCE: &str =
    "agent_owned_file_transfer_request_registry_live_transfer";
const FILE_TRANSFER_HISTORY_SOURCE: &str = "agent_owned_file_transfer_request_registry";
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
    accepted: bool,
    status: &'static str,
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
    match enqueue_file_transfer_send_request_for_established_session(
        &paths, session_id, &args.to, &args.path,
    )
    .await
    {
        Ok(request) => json_or_text(
            args.output.json,
            json!(request_report(&request)),
            &format!(
                "File transfer send request registered for session {} and is pending agent observation.",
                request.session_id
            ),
        ),
        Err(error) => {
            if args.output.json {
                print_request_rejection_report(
                    session_id,
                    "file_transfer_request_rejected",
                    "file transfer request was rejected before agent observation",
                )?;
                bail!("file transfer request rejected before agent observation");
            }
            Err(error)
        }
    }
}

pub(crate) fn receive_placeholder(as_json: bool) -> Result<()> {
    if as_json {
        print_planned_mutation_report(planned_mutation_report(
            "file.transfer.receive",
            "receive",
            false,
            false,
        ))?;
    }
    bail!(
        "{FILE_TRANSFER_ERROR}: `receive` requires explicit receive-directory policy, inbound sender identity proof, and real-device file-transfer validation"
    )
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

fn request_report(request: &FileTransferControlRequest) -> FileTransferRequestReport {
    FileTransferRequestReport {
        schema_version: SCHEMA_VERSION,
        capability_id: "file.transfer.send",
        action: "send",
        accepted: true,
        status: FILE_TRANSFER_REQUEST_STATUS,
        request_registered: true,
        pending_agent_observation: true,
        agent_observed: false,
        transfer_started: false,
        applied: false,
        receipt_verified: false,
        source_path_provided: true,
        source_regular_file_verified: true,
        source_sha256_recorded: true,
        destination_peer_provided: true,
        destination_bound_to_session_peer: true,
        session_id: request.session_id.clone(),
        request_id: request.request_id.clone(),
        source_size_bytes: request.source.size_bytes,
        source: FILE_TRANSFER_REQUEST_SOURCE,
        required_gates_before_live_transfer: REQUEST_ONLY_GATES,
    }
}

fn print_planned_mutation_report(report: FileTransferPlannedReport) -> Result<()> {
    eprintln!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
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
        "accepted": false,
        "status": FILE_TRANSFER_REQUEST_REJECTED_STATUS,
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
    eprintln!("{}", serde_json::to_string_pretty(&payload)?);
    Ok(())
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
    fn file_placeholders_cover_text_json_and_errors() -> Result<()> {
        assert!(send_placeholder(Path::new("/tmp/payload.txt"), "peer-device", false).is_err());
        assert!(receive_placeholder(false).is_err());
        Ok(())
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
}
