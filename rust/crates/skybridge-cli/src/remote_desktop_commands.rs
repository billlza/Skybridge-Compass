use std::path::PathBuf;

use anyhow::{Result, bail};
use serde::Serialize;
use skybridge_agent::{
    enqueue_remote_desktop_request_for_established_session,
    load_remote_desktop_capability_snapshot_registry, load_remote_desktop_request_registry,
    load_session_registry, resolve_paths,
};
use skybridge_core::{
    REMOTE_DESKTOP_FPS_REQUEST_CONTRACT, REMOTE_DESKTOP_RESOLUTION_REQUEST_CONTRACT,
    RemoteDesktopCapabilitySnapshot, RemoteDesktopControlAction, RemoteDesktopControlRequest,
    RemoteDesktopControlRequestPayload, RemoteDesktopControlRequestRegistry,
    RemoteDesktopControlRequestStatus, RemoteDesktopObservedMode, RemoteDesktopResolutionPreset,
    RemoteDesktopResolutionRequest, RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionSource,
    RuntimeSessionState, remote_desktop_fps_request_supported,
};

const SCHEMA_VERSION: u32 = 1;
const LIVE_CONTROL_STATUS: &str = "planned";
const PENDING_AGENT_OBSERVATION_STATUS: &str = "pending_agent_observation";
const AGENT_OBSERVED_NOT_APPLIED_STATUS: &str = "agent_observed_not_applied";
const REQUEST_CONTRACT_SOURCE: &str = "cli_request_contract_only_no_live_sender_modes";
const OBSERVED_MODES_SOURCE: &str = "agent_owned_remote_desktop_capability_snapshot_not_live_apply";
const OBSERVED_MODES_STATUS_PLANNED: &str = "planned";
const OBSERVED_MODES_STATUS_AVAILABLE: &str = "available";
const OBSERVED_MODES_STATUS_STALE: &str = "stale";

const REQUIRED_GATES: &[&str] = &[
    "agent_owned_remote_desktop_control",
    "sender_observed_mode_change",
    "remote_control_notice_artifact_gate",
    "real_device_p2p_remote_gate",
    "performance_p2p_remote_final_window_fps_gate",
];

const EVIDENCE_SOURCES: &[&str] = &[
    "skybridge doctor webrtc-media --latest|--session-id <id> [--json]",
    "skybridge check performance --kind p2p-remote --artifact-dir <dir> [--json]",
    "skybridge check remote-control-notice --log-file <path> [--json]",
];

const COMMAND_CONTRACTS: &[RemoteDesktopCommandContract] = &[
    RemoteDesktopCommandContract {
        command: "skybridge remote-desktop contract [--json]",
        status: "read_only",
        mutation_supported: false,
        agent_observation_required: false,
    },
    RemoteDesktopCommandContract {
        command: "skybridge remote-desktop status [--session-id <id>] [--json]",
        status: "read_only",
        mutation_supported: false,
        agent_observation_required: false,
    },
    RemoteDesktopCommandContract {
        command: "skybridge remote-desktop resolutions [--session-id <id>] [--json]",
        status: "read_only_contract",
        mutation_supported: false,
        agent_observation_required: false,
    },
    RemoteDesktopCommandContract {
        command: "skybridge remote-desktop start --session-id <id> [--resolution <preset>] [--fps <value>]",
        status: "request_only",
        mutation_supported: false,
        agent_observation_required: true,
    },
    RemoteDesktopCommandContract {
        command: "skybridge remote-desktop stop --session-id <id>",
        status: "request_only",
        mutation_supported: false,
        agent_observation_required: true,
    },
    RemoteDesktopCommandContract {
        command: "skybridge remote-desktop set-resolution --session-id <id> --resolution <preset>",
        status: "request_only",
        mutation_supported: false,
        agent_observation_required: true,
    },
    RemoteDesktopCommandContract {
        command: "skybridge remote-desktop set-fps --session-id <id> --fps <value>",
        status: "request_only",
        mutation_supported: false,
        agent_observation_required: true,
    },
];

#[derive(Debug, Clone, Copy, Serialize)]
struct RemoteDesktopCommandContract {
    command: &'static str,
    status: &'static str,
    mutation_supported: bool,
    agent_observation_required: bool,
}

#[derive(Debug, Serialize)]
struct RemoteDesktopContractReport {
    schema_version: u32,
    live_control_status: &'static str,
    mutation_supported: bool,
    agent_observation_supported: bool,
    request_contract_source: &'static str,
    commands: &'static [RemoteDesktopCommandContract],
    resolution_request_contract: &'static [RemoteDesktopResolutionPreset],
    fps_request_contract: &'static [u16],
    evidence_sources: &'static [&'static str],
    required_gates: &'static [&'static str],
}

#[derive(Debug, Serialize)]
struct RemoteDesktopResolutionReport {
    schema_version: u32,
    live_control_status: &'static str,
    mutation_supported: bool,
    source: &'static str,
    session_filter: Option<String>,
    observed_modes_status: &'static str,
    observed_modes_source: &'static str,
    observed_sessions: Vec<RemoteDesktopObservedSessionStatus>,
    resolutions: &'static [RemoteDesktopResolutionPreset],
    fps_values: &'static [u16],
    required_gates_before_live_apply: &'static [&'static str],
}

#[derive(Debug, Serialize)]
struct RemoteDesktopObservedSessionStatus {
    session_id: String,
    sender_modes: Vec<RemoteDesktopObservedMode>,
    display_modes: Vec<RemoteDesktopObservedMode>,
    observed_at: String,
    expires_at: String,
    updated_at: String,
    live_apply_supported: bool,
    control_request_agent_observed: bool,
    applied: bool,
}

#[derive(Debug, Serialize)]
struct RemoteDesktopStatusReport {
    schema_version: u32,
    live_control_status: &'static str,
    mutation_supported: bool,
    agent_observation_supported: bool,
    session_filter: Option<String>,
    sessions: Vec<RemoteDesktopSessionStatus>,
    evidence_sources: &'static [&'static str],
    required_gates_before_live_apply: &'static [&'static str],
}

#[derive(Debug, Serialize)]
struct RemoteDesktopMutationReport {
    schema_version: u32,
    action: RemoteDesktopControlAction,
    session_id: String,
    request_id: String,
    request_registered: bool,
    accepted: bool,
    live_control_status: &'static str,
    mutation_supported: bool,
    request_registry_supported: bool,
    pending_agent_observation: bool,
    agent_observed: bool,
    applied: bool,
    request: RemoteDesktopPendingRequestStatus,
    required_gates_before_live_apply: &'static [&'static str],
}

#[derive(Debug, Serialize)]
struct RemoteDesktopMutationRejectionReport {
    schema_version: u32,
    action: RemoteDesktopControlAction,
    session_id_provided: bool,
    request_registered: bool,
    accepted: bool,
    live_control_status: &'static str,
    mutation_supported: bool,
    request_registry_supported: bool,
    pending_agent_observation: bool,
    agent_observed: bool,
    applied: bool,
    error: RemoteDesktopMutationErrorReport,
    required_gates_before_live_apply: &'static [&'static str],
}

#[derive(Debug, Serialize)]
struct RemoteDesktopMutationErrorReport {
    code: &'static str,
    message: &'static str,
    retryable: bool,
    required_gate: &'static str,
}

#[derive(Debug, Serialize)]
struct RemoteDesktopSessionStatus {
    session_id: String,
    role: RuntimeSessionRole,
    source: RuntimeSessionSource,
    runtime_state: RuntimeSessionState,
    transport_preserved: bool,
    remote_identity_bound: bool,
    remote_display_name_available: bool,
    updated_at: String,
    live_control_status: &'static str,
    pending_agent_observation: bool,
    pending_request: Option<RemoteDesktopPendingRequestStatus>,
    latest_request: Option<RemoteDesktopPendingRequestStatus>,
}

#[derive(Debug, Clone, Serialize)]
struct RemoteDesktopPendingRequestStatus {
    request_id: String,
    action: RemoteDesktopControlAction,
    status: &'static str,
    pending_agent_observation: bool,
    agent_observed: bool,
    applied: bool,
    resolution: Option<RemoteDesktopResolutionRequest>,
    fps: Option<u16>,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, PartialEq, Eq)]
enum ResolutionRequest {
    Auto,
    Preset(&'static RemoteDesktopResolutionPreset),
}

pub(crate) fn contract(as_json: bool) -> Result<()> {
    let report = contract_report();
    if as_json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }

    println!("Remote Desktop CLI Contract v{}", report.schema_version);
    println!("Live control: {}", report.live_control_status);
    println!("Mutation supported: {}", report.mutation_supported);
    println!(
        "Request contract source: {}",
        report.request_contract_source
    );
    println!("Commands:");
    for command in report.commands {
        println!(
            "- {} [{} agent_observation_required={}]",
            command.command, command.status, command.agent_observation_required
        );
    }
    Ok(())
}

pub(crate) async fn status(
    state_dir: Option<PathBuf>,
    args: crate::RemoteDesktopStatusArgs,
) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let registry = load_session_registry(&paths).await?;
    let session_records = if let Some(session_id) = args.session_id.as_deref() {
        let session = registry
            .get(session_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("session `{session_id}` not found"))?;
        vec![session]
    } else {
        registry.values_sorted()
    };
    let request_registry = load_remote_desktop_request_registry(&paths).await?;
    let sessions = session_records
        .iter()
        .map(|session| session_to_status(session, &request_registry))
        .collect::<Vec<_>>();
    let has_pending_request = sessions
        .iter()
        .any(|session| session.pending_agent_observation);
    let has_observed_request = sessions.iter().any(|session| {
        session
            .latest_request
            .as_ref()
            .is_some_and(|request| request.agent_observed)
    });
    let report = RemoteDesktopStatusReport {
        schema_version: SCHEMA_VERSION,
        live_control_status: live_control_status(has_pending_request, has_observed_request),
        mutation_supported: false,
        agent_observation_supported: true,
        session_filter: args.session_id,
        sessions,
        evidence_sources: EVIDENCE_SOURCES,
        required_gates_before_live_apply: REQUIRED_GATES,
    };

    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }

    println!(
        "Remote desktop live control: {}",
        report.live_control_status
    );
    if report.sessions.is_empty() {
        println!("No sessions recorded for remote desktop inspection");
    }
    for session in &report.sessions {
        println!(
            "{} [{:?}] {:?} pending_agent_observation={}",
            session.session_id,
            session.role,
            session.runtime_state,
            session.pending_agent_observation
        );
    }
    Ok(())
}

pub(crate) async fn resolutions(
    state_dir: Option<PathBuf>,
    args: crate::RemoteDesktopResolutionsArgs,
) -> Result<()> {
    let (observed_modes_status, observed_sessions) =
        load_observed_resolution_sessions(state_dir, args.session_id.as_deref()).await?;
    let report = RemoteDesktopResolutionReport {
        schema_version: SCHEMA_VERSION,
        live_control_status: LIVE_CONTROL_STATUS,
        mutation_supported: false,
        source: REQUEST_CONTRACT_SOURCE,
        session_filter: args.session_id,
        observed_modes_status,
        observed_modes_source: OBSERVED_MODES_SOURCE,
        observed_sessions,
        resolutions: REMOTE_DESKTOP_RESOLUTION_REQUEST_CONTRACT,
        fps_values: REMOTE_DESKTOP_FPS_REQUEST_CONTRACT,
        required_gates_before_live_apply: REQUIRED_GATES,
    };
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }

    println!(
        "Remote desktop resolution request contract v{}",
        SCHEMA_VERSION
    );
    println!("Source: {}", report.source);
    for resolution in report.resolutions {
        println!("- {} {}", resolution.id, resolution.note);
    }
    println!("FPS request values: 30, 60, 120");
    println!("Observed sender modes: {}", report.observed_modes_status);
    for session in &report.observed_sessions {
        println!(
            "- session={} sender_modes={}",
            session.session_id,
            session.sender_modes.len()
        );
        for mode in &session.sender_modes {
            println!(
                "  - {} {}x{}@{}",
                mode.id, mode.width, mode.height, mode.fps
            );
        }
    }
    Ok(())
}

pub(crate) async fn start(
    state_dir: Option<PathBuf>,
    args: crate::RemoteDesktopStartArgs,
) -> Result<()> {
    let session_id = args.session_id;
    let resolution = match parse_resolution_request(&args.resolution) {
        Ok(resolution) => resolution,
        Err(error) => {
            return reject_invalid_mutation_request(
                args.output.json,
                RemoteDesktopControlAction::Start,
                session_id,
                error,
            );
        }
    };
    if let Err(error) = validate_fps(args.fps) {
        return reject_invalid_mutation_request(
            args.output.json,
            RemoteDesktopControlAction::Start,
            session_id,
            error,
        );
    }
    let payload = RemoteDesktopControlRequestPayload {
        resolution: Some(resolution.to_payload()),
        fps: Some(args.fps),
    };
    register_pending_request(
        state_dir,
        session_id,
        RemoteDesktopControlAction::Start,
        payload,
        args.output.json,
    )
    .await
}

pub(crate) async fn stop(
    state_dir: Option<PathBuf>,
    args: crate::RemoteDesktopSessionActionArgs,
) -> Result<()> {
    register_pending_request(
        state_dir,
        args.session_id,
        RemoteDesktopControlAction::Stop,
        RemoteDesktopControlRequestPayload::default(),
        args.output.json,
    )
    .await
}

pub(crate) async fn set_resolution(
    state_dir: Option<PathBuf>,
    args: crate::RemoteDesktopSetResolutionArgs,
) -> Result<()> {
    let session_id = args.session_id;
    let resolution = match parse_resolution_request(&args.resolution) {
        Ok(resolution) => resolution,
        Err(error) => {
            return reject_invalid_mutation_request(
                args.output.json,
                RemoteDesktopControlAction::SetResolution,
                session_id,
                error,
            );
        }
    };
    let payload = RemoteDesktopControlRequestPayload {
        resolution: Some(resolution.to_payload()),
        fps: None,
    };
    register_pending_request(
        state_dir,
        session_id,
        RemoteDesktopControlAction::SetResolution,
        payload,
        args.output.json,
    )
    .await
}

pub(crate) async fn set_fps(
    state_dir: Option<PathBuf>,
    args: crate::RemoteDesktopSetFpsArgs,
) -> Result<()> {
    let session_id = args.session_id;
    if let Err(error) = validate_fps(args.fps) {
        return reject_invalid_mutation_request(
            args.output.json,
            RemoteDesktopControlAction::SetFps,
            session_id,
            error,
        );
    }
    let payload = RemoteDesktopControlRequestPayload {
        resolution: None,
        fps: Some(args.fps),
    };
    register_pending_request(
        state_dir,
        session_id,
        RemoteDesktopControlAction::SetFps,
        payload,
        args.output.json,
    )
    .await
}

fn contract_report() -> RemoteDesktopContractReport {
    RemoteDesktopContractReport {
        schema_version: SCHEMA_VERSION,
        live_control_status: LIVE_CONTROL_STATUS,
        mutation_supported: false,
        agent_observation_supported: true,
        request_contract_source: REQUEST_CONTRACT_SOURCE,
        commands: COMMAND_CONTRACTS,
        resolution_request_contract: REMOTE_DESKTOP_RESOLUTION_REQUEST_CONTRACT,
        fps_request_contract: REMOTE_DESKTOP_FPS_REQUEST_CONTRACT,
        evidence_sources: EVIDENCE_SOURCES,
        required_gates: REQUIRED_GATES,
    }
}

fn session_to_status(
    session: &RuntimeSessionRecord,
    request_registry: &RemoteDesktopControlRequestRegistry,
) -> RemoteDesktopSessionStatus {
    let pending_request = request_registry
        .pending_for_session(&session.session_id)
        .first()
        .map(|request| request_to_status(request));
    let pending_agent_observation = pending_request.is_some();
    let latest_request = request_registry
        .values_sorted()
        .into_iter()
        .find(|request| request.session_id == session.session_id)
        .map(|request| request_to_status(&request));
    RemoteDesktopSessionStatus {
        session_id: session.session_id.clone(),
        role: session.role,
        source: session.source,
        runtime_state: session.state,
        transport_preserved: session.transport_preserved,
        remote_identity_bound: session
            .remote_protocol_public_key_fingerprint
            .as_deref()
            .is_some_and(|fingerprint| !fingerprint.trim().is_empty()),
        remote_display_name_available: session
            .remote_device_name
            .as_deref()
            .is_some_and(|name| !name.trim().is_empty()),
        updated_at: session.updated_at.to_string(),
        live_control_status: live_control_status(
            pending_agent_observation,
            latest_request
                .as_ref()
                .is_some_and(|request| request.agent_observed),
        ),
        pending_agent_observation,
        pending_request,
        latest_request,
    }
}

async fn load_observed_resolution_sessions(
    state_dir: Option<PathBuf>,
    session_filter: Option<&str>,
) -> Result<(&'static str, Vec<RemoteDesktopObservedSessionStatus>)> {
    let Some(session_id) = session_filter else {
        return Ok((OBSERVED_MODES_STATUS_PLANNED, Vec::new()));
    };

    let paths = resolve_paths(state_dir)?;
    let session_registry = load_session_registry(&paths).await?;
    let session = session_registry
        .get(session_id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("session `{session_id}` not found"))?;
    let capability_registry = load_remote_desktop_capability_snapshot_registry(&paths).await?;
    let Some(snapshot) = capability_registry.get_for_session(session_id) else {
        return Ok((OBSERVED_MODES_STATUS_PLANNED, Vec::new()));
    };
    if !snapshot_matches_session(snapshot, &session) {
        return Ok((OBSERVED_MODES_STATUS_STALE, Vec::new()));
    }

    Ok((
        OBSERVED_MODES_STATUS_AVAILABLE,
        vec![snapshot_to_observed_session(snapshot)],
    ))
}

fn snapshot_matches_session(
    snapshot: &RemoteDesktopCapabilitySnapshot,
    session: &RuntimeSessionRecord,
) -> bool {
    snapshot.session_id == session.session_id
        && snapshot.target_runtime_id == session.runtime_id
        && snapshot.is_fresh_at(time::OffsetDateTime::now_utc())
        && session.is_active()
        && session.effective_established_readiness().is_some()
}

fn snapshot_to_observed_session(
    snapshot: &RemoteDesktopCapabilitySnapshot,
) -> RemoteDesktopObservedSessionStatus {
    RemoteDesktopObservedSessionStatus {
        session_id: snapshot.session_id.clone(),
        sender_modes: snapshot.sender_modes.clone(),
        display_modes: snapshot.display_modes.clone(),
        observed_at: snapshot.observed_at.to_string(),
        expires_at: snapshot.expires_at.to_string(),
        updated_at: snapshot.updated_at.to_string(),
        live_apply_supported: false,
        control_request_agent_observed: false,
        applied: false,
    }
}

fn parse_resolution_request(value: &str) -> Result<ResolutionRequest> {
    let trimmed = value.trim();
    if trimmed.eq_ignore_ascii_case("auto") {
        return Ok(ResolutionRequest::Auto);
    }
    REMOTE_DESKTOP_RESOLUTION_REQUEST_CONTRACT
        .iter()
        .find(|preset| preset.id == trimmed)
        .map(ResolutionRequest::Preset)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "unsupported remote desktop resolution `{trimmed}`; run `skybridge remote-desktop resolutions --json` for the request contract"
            )
        })
}

fn validate_fps(fps: u16) -> Result<()> {
    if remote_desktop_fps_request_supported(fps) {
        return Ok(());
    }
    bail!("unsupported remote desktop fps `{fps}`; supported request values are 30, 60, and 120")
}

fn reject_invalid_mutation_request<T>(
    as_json: bool,
    action: RemoteDesktopControlAction,
    session_id: String,
    error: anyhow::Error,
) -> Result<T> {
    if as_json {
        print_mutation_rejection_report(
            action,
            &session_id,
            "remote_desktop_request_invalid",
            "remote desktop request is outside the bounded request contract",
            "remote_desktop.request_contract",
        )?;
        bail!("remote desktop request is outside the bounded request contract");
    }

    Err(error)
}

fn print_mutation_rejection_report(
    action: RemoteDesktopControlAction,
    session_id: &str,
    code: &'static str,
    message: &'static str,
    required_gate: &'static str,
) -> Result<()> {
    eprintln!(
        "{}",
        serde_json::to_string_pretty(&RemoteDesktopMutationRejectionReport {
            schema_version: SCHEMA_VERSION,
            action,
            session_id_provided: !session_id.trim().is_empty(),
            request_registered: false,
            accepted: false,
            live_control_status: LIVE_CONTROL_STATUS,
            mutation_supported: false,
            request_registry_supported: true,
            pending_agent_observation: false,
            agent_observed: false,
            applied: false,
            error: RemoteDesktopMutationErrorReport {
                code,
                message,
                retryable: false,
                required_gate,
            },
            required_gates_before_live_apply: REQUIRED_GATES,
        })?
    );
    Ok(())
}

async fn register_pending_request(
    state_dir: Option<PathBuf>,
    session_id: String,
    action: RemoteDesktopControlAction,
    payload: RemoteDesktopControlRequestPayload,
    as_json: bool,
) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    match enqueue_remote_desktop_request_for_established_session(
        &paths,
        &session_id,
        action,
        payload,
    )
    .await
    {
        Ok(request) => {
            let report = mutation_report(request);
            if as_json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!(
                    "Remote desktop request `{}` registered for session `{}`; pending_agent_observation=true applied=false",
                    report.request_id, report.session_id
                );
            }
            Ok(())
        }
        Err(error) => {
            if as_json {
                print_mutation_rejection_report(
                    action,
                    &session_id,
                    "remote_desktop_request_rejected",
                    "remote desktop request was rejected before agent observation",
                    "agent_owned_remote_desktop_control",
                )?;
                bail!("remote desktop request rejected before agent observation");
            }
            Err(error)
        }
    }
}

fn mutation_report(request: RemoteDesktopControlRequest) -> RemoteDesktopMutationReport {
    RemoteDesktopMutationReport {
        schema_version: SCHEMA_VERSION,
        action: request.action,
        session_id: request.session_id.clone(),
        request_id: request.request_id.clone(),
        request_registered: true,
        accepted: true,
        live_control_status: PENDING_AGENT_OBSERVATION_STATUS,
        mutation_supported: false,
        request_registry_supported: true,
        pending_agent_observation: true,
        agent_observed: false,
        applied: false,
        request: request_to_status(&request),
        required_gates_before_live_apply: REQUIRED_GATES,
    }
}

fn request_to_status(request: &RemoteDesktopControlRequest) -> RemoteDesktopPendingRequestStatus {
    RemoteDesktopPendingRequestStatus {
        request_id: request.request_id.clone(),
        action: request.action,
        status: request_status_label(request.status),
        pending_agent_observation: request.is_pending_agent_observation(),
        agent_observed: request.is_agent_observed(),
        applied: false,
        resolution: request.payload.resolution.clone(),
        fps: request.payload.fps,
        created_at: request.created_at.to_string(),
        updated_at: request.updated_at.to_string(),
    }
}

fn request_status_label(status: RemoteDesktopControlRequestStatus) -> &'static str {
    match status {
        RemoteDesktopControlRequestStatus::PendingAgentObservation => {
            PENDING_AGENT_OBSERVATION_STATUS
        }
        RemoteDesktopControlRequestStatus::AgentObserved => AGENT_OBSERVED_NOT_APPLIED_STATUS,
        RemoteDesktopControlRequestStatus::AgentRejected => "agent_rejected",
    }
}

fn live_control_status(pending_agent_observation: bool, agent_observed: bool) -> &'static str {
    if pending_agent_observation {
        PENDING_AGENT_OBSERVATION_STATUS
    } else if agent_observed {
        AGENT_OBSERVED_NOT_APPLIED_STATUS
    } else {
        LIVE_CONTROL_STATUS
    }
}

impl ResolutionRequest {
    fn to_payload(&self) -> RemoteDesktopResolutionRequest {
        match self {
            Self::Auto => RemoteDesktopResolutionRequest::Auto,
            Self::Preset(preset) => RemoteDesktopResolutionRequest::Preset {
                id: preset.id.to_owned(),
                width: preset
                    .width
                    .expect("resolution presets must carry width except auto"),
                height: preset
                    .height
                    .expect("resolution presets must carry height except auto"),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{OutputOptions, RemoteDesktopSetFpsArgs, RemoteDesktopStartArgs};

    #[test]
    fn remote_desktop_contract_keeps_live_application_unobserved() {
        let report = contract_report();
        assert_eq!(report.schema_version, 1);
        assert_eq!(report.live_control_status, "planned");
        assert!(!report.mutation_supported);
        assert!(report.agent_observation_supported);
        assert!(report.commands.iter().any(|command| {
            command.command.contains("start") && command.status == "request_only"
        }));
        assert!(
            report
                .required_gates
                .contains(&"real_device_p2p_remote_gate")
        );
    }

    #[test]
    fn resolution_and_fps_contract_validate_supported_values() -> Result<()> {
        assert_eq!(parse_resolution_request("auto")?, ResolutionRequest::Auto);
        assert!(matches!(
            parse_resolution_request("1920x1080")?,
            ResolutionRequest::Preset(RemoteDesktopResolutionPreset {
                id: "1920x1080",
                ..
            })
        ));
        assert!(parse_resolution_request("111x222").is_err());
        validate_fps(30)?;
        validate_fps(60)?;
        validate_fps(120)?;
        assert!(validate_fps(75).is_err());
        Ok(())
    }

    #[tokio::test]
    async fn live_mutations_reject_missing_sessions_before_registry_writes() -> Result<()> {
        let state_dir = crate::cli_test_support::make_test_dir("remote-desktop-missing-session")?;
        assert!(
            start(
                Some(state_dir.clone()),
                RemoteDesktopStartArgs {
                    session_id: "session-1".to_owned(),
                    resolution: "1920x1080".to_owned(),
                    fps: 60,
                    output: OutputOptions { json: false },
                }
            )
            .await
            .is_err()
        );
        assert!(
            set_fps(
                Some(state_dir),
                RemoteDesktopSetFpsArgs {
                    session_id: "session-1".to_owned(),
                    fps: 120,
                    output: OutputOptions { json: false },
                }
            )
            .await
            .is_err()
        );
        Ok(())
    }
}
