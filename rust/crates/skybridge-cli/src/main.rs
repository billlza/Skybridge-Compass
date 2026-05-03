use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use clap::{Args, Parser, Subcommand};
use serde::Serialize;
use serde_json::json;
use skybridge_agent::{
    clear_auth_session, ensure_device_identity, ensure_rust_pqc_identity, load_auth_session,
    load_health_snapshot, load_session_registry, refresh_auth_session_if_needed,
    remove_managed_session_control, remove_session_runtime, resolve_paths, run_agent,
    signing_binding, signing_signature, store_auth_session, store_session_registry,
    update_enrollment_status, upsert_managed_session_control, upsert_session_runtime,
};
use skybridge_core::{
    AgentRuntimeStatus, AuthState, CryptoSuite, CurrentPathOriginPolicy, EnrollmentStatus,
    InboundMessage, ManagedSessionControl, NativeWebRtcConfig, NativeWebRtcEvent,
    NativeWebRtcSession, NebulaOAuthClient, PqcResponderConfig, ProtocolIdentityBinding,
    ProtocolSigningAlgorithm, RuntimeSessionKeepaliveStatus, RuntimeSessionRecord,
    RuntimeSessionRole, RuntimeSessionSource, RuntimeSessionState, RuntimeSessionTransportEvent,
    SessionReadiness, SignalServerClient, SignalingConnection, SignalingLifecycleEvent,
    SignalingLifecyclePhase, SignalingRuntimeEvent, derive_tenant_identifier, make_join_envelope,
    make_runtime_id,
};
use time::OffsetDateTime;

const ENV_PQC_BRIDGE_IDENTITY: &str = "SKYBRIDGE_PQC_BRIDGE_IDENTITY";

#[derive(Debug, Parser)]
#[command(name = "skybridge")]
#[command(about = "SkyBridge CLI operator surface")]
struct Cli {
    #[arg(long, global = true)]
    state_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    Agent(AgentCommand),
    Login(LoginCommand),
    Logout,
    Device(DeviceCommand),
    Code(CodeCommand),
    Connect(ConnectCommand),
    Session(SessionCommand),
    Disconnect(DisconnectCommand),
    File(FileCommand),
    Doctor(DoctorCommand),
    Logs(LogsCommand),
    Metrics(OutputOptions),
    #[command(hide = true)]
    Internal(InternalCommand),
    Version,
}

#[derive(Debug, Args)]
struct LoginCommand {
    #[arg(long)]
    no_open: bool,
    #[arg(long)]
    print_only: bool,
    #[arg(long)]
    redirect_uri: Option<String>,
    #[arg(long)]
    callback_url: Option<String>,
    #[arg(long)]
    authorization_code: Option<String>,
}

#[derive(Debug, Args)]
struct OutputOptions {
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Args)]
struct DoctorCommand {
    #[command(subcommand)]
    command: Option<DoctorSubcommand>,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Subcommand)]
enum DoctorSubcommand {
    Signaling(SignalingDoctorArgs),
    MediaLease(MediaLeaseDoctorArgs),
}

#[derive(Debug, Args)]
struct SignalingDoctorArgs {
    #[arg(long)]
    base_url: Option<String>,
    #[arg(long)]
    expected_backend: Option<String>,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Args)]
struct MediaLeaseDoctorArgs {
    #[arg(long)]
    base_url: Option<String>,
    #[arg(long)]
    session_id: Option<String>,
    #[arg(long, env = "SKYBRIDGE_MEDIA_ADMISSION_TOKEN")]
    media_admission_token: Option<String>,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Args)]
struct DisconnectCommand {
    session_id: String,
}

#[derive(Debug, Args)]
struct ConnectCommand {
    code: String,
    #[arg(long, default_value_t = 5)]
    hold_seconds: u64,
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Subcommand)]
enum AgentSubcommand {
    Run,
}

#[derive(Debug, Args)]
struct AgentCommand {
    #[command(subcommand)]
    command: AgentSubcommand,
}

#[derive(Debug, Subcommand)]
enum DeviceSubcommand {
    Status(OutputOptions),
    Enroll(DeviceEnrollArgs),
    Approve(DeviceApproveArgs),
}

#[derive(Debug, Args)]
struct DeviceEnrollArgs {
    #[arg(long)]
    invite_token: Option<String>,
    #[arg(long)]
    device_name: Option<String>,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Args)]
struct DeviceApproveArgs {
    #[arg(value_name = "PENDING_DEVICE_ID")]
    pending_device_id: String,
    #[arg(long, default_value = "Ed25519")]
    pending_algorithm: String,
    #[arg(long)]
    pending_fingerprint: String,
    #[arg(long)]
    device_name: Option<String>,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Args)]
struct DeviceCommand {
    #[command(subcommand)]
    command: DeviceSubcommand,
}

#[derive(Debug, Subcommand)]
enum CodeSubcommand {
    Create(CodeCreateArgs),
}

#[derive(Debug, Args)]
struct CodeCreateArgs {
    #[arg(long)]
    device_name: Option<String>,
    #[arg(long, default_value_t = 300)]
    ttl_seconds: i64,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Args)]
struct CodeCommand {
    #[command(subcommand)]
    command: CodeSubcommand,
}

#[derive(Debug, Subcommand)]
enum SessionSubcommand {
    Ls(OutputOptions),
    Inspect(SessionInspectArgs),
}

#[derive(Debug, Args)]
struct SessionInspectArgs {
    id: String,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Args)]
struct SessionCommand {
    #[command(subcommand)]
    command: SessionSubcommand,
}

#[derive(Debug, Subcommand)]
enum FileSubcommand {
    Send(FileSendArgs),
    Receive,
    History(OutputOptions),
}

#[derive(Debug, Args)]
struct FileSendArgs {
    path: PathBuf,
    #[arg(long)]
    to: String,
}

#[derive(Debug, Args)]
struct FileCommand {
    #[command(subcommand)]
    command: FileSubcommand,
}

#[derive(Debug, Subcommand)]
enum LogsSubcommand {
    Tail(TailArgs),
}

#[derive(Debug, Args)]
struct TailArgs {
    #[arg(long, default_value_t = 50)]
    lines: usize,
}

#[derive(Debug, Args)]
struct LogsCommand {
    #[command(subcommand)]
    command: LogsSubcommand,
}

#[derive(Debug, Subcommand)]
enum InternalSubcommand {
    VerifyMldsa(VerifyMldsaArgs),
}

#[derive(Debug, Args)]
struct InternalCommand {
    #[command(subcommand)]
    command: InternalSubcommand,
}

#[derive(Debug, Args)]
struct VerifyMldsaArgs {
    #[arg(long)]
    message_base64: String,
    #[arg(long)]
    signature_base64: String,
    #[arg(long)]
    public_key_base64: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    dispatch(cli).await
}

async fn dispatch(cli: Cli) -> Result<()> {
    match cli.command {
        Commands::Agent(agent) => match agent.command {
            AgentSubcommand::Run => {
                run_agent(skybridge_agent::AgentRuntimeOptions {
                    state_dir: cli.state_dir,
                    heartbeat_interval: Duration::from_secs(2),
                })
                .await
            }
        },
        Commands::Login(args) => login(cli.state_dir, args).await,
        Commands::Logout => logout(cli.state_dir).await,
        Commands::Device(device) => match device.command {
            DeviceSubcommand::Status(output) => device_status(cli.state_dir, output.json).await,
            DeviceSubcommand::Enroll(args) => device_enroll(cli.state_dir, args).await,
            DeviceSubcommand::Approve(args) => device_approve(cli.state_dir, args).await,
        },
        Commands::Code(code) => match code.command {
            CodeSubcommand::Create(args) => code_create(cli.state_dir, args).await,
        },
        Commands::Connect(args) => connect_code(cli.state_dir, args).await,
        Commands::Session(session) => match session.command {
            SessionSubcommand::Ls(output) => session_ls(cli.state_dir, output.json).await,
            SessionSubcommand::Inspect(args) => session_inspect(cli.state_dir, args).await,
        },
        Commands::Disconnect(args) => disconnect(cli.state_dir, &args.session_id).await,
        Commands::File(file) => match file.command {
            FileSubcommand::Send(args) => not_implemented(&format!(
                "Phase 6 pending: file send from `{}` to `{}` waits for the shared route contract.",
                args.path.display(),
                args.to
            )),
            FileSubcommand::Receive => {
                not_implemented("Phase 6 pending: inbound file receive is not wired yet.")
            }
            FileSubcommand::History(output) => placeholder_json_or_text(
                output.json,
                json!({
                    "history": [],
                    "message": "Phase 6 pending: file transfer history is not wired yet."
                }),
                "Phase 6 pending: file transfer history is not wired yet.",
            ),
        },
        Commands::Doctor(args) => match args.command {
            Some(DoctorSubcommand::Signaling(signaling)) => doctor_signaling(signaling).await,
            Some(DoctorSubcommand::MediaLease(media_lease)) => {
                doctor_media_lease(media_lease).await
            }
            None => doctor(cli.state_dir, args.output.json).await,
        },
        Commands::Logs(logs) => match logs.command {
            LogsSubcommand::Tail(args) => tail_logs(cli.state_dir, args.lines).await,
        },
        Commands::Metrics(output) => metrics(cli.state_dir, output.json).await,
        Commands::Internal(internal) => match internal.command {
            InternalSubcommand::VerifyMldsa(args) => internal_verify_mldsa(args),
        },
        Commands::Version => version(),
    }
}

async fn login(state_dir: Option<PathBuf>, args: LoginCommand) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let oauth = NebulaOAuthClient::from_env()?;
    let redirect_uri = args
        .redirect_uri
        .or_else(|| std::env::var("SKYBRIDGE_OAUTH_REDIRECT_URI").ok())
        .unwrap_or_else(|| "skybridge://auth/nebula".to_owned());
    let authorization_request = oauth.make_authorization_request(
        &redirect_uri,
        &["openid", "profile", "email", "offline_access"],
        &[],
    )?;

    if args.print_only {
        println!("{}", authorization_request.authorization_url);
        return Ok(());
    }

    let session = oauth
        .complete_authorization_interactively(
            &authorization_request,
            !args.no_open,
            args.callback_url,
            args.authorization_code,
        )
        .await?;
    store_auth_session(&paths, &session).await?;
    let identity = ensure_device_identity(&paths).await?;
    let tenant_id = derive_tenant_identifier(&session.access_token).unwrap_or_default();
    println!("Logged in as: {}", session.display_name);
    println!("User ID: {}", session.user_identifier);
    println!(
        "Tenant ID: {}",
        if tenant_id.is_empty() {
            "<unresolved>"
        } else {
            &tenant_id
        }
    );
    println!("Device ID: {}", identity.state.device.device_id);
    Ok(())
}

async fn logout(state_dir: Option<PathBuf>) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    clear_auth_session(&paths).await?;
    println!("Logged out");
    Ok(())
}

fn internal_verify_mldsa(args: VerifyMldsaArgs) -> Result<()> {
    let message = STANDARD
        .decode(args.message_base64.trim().as_bytes())
        .map_err(|error| anyhow!("invalid message_base64: {error}"))?;
    let signature = STANDARD
        .decode(args.signature_base64.trim().as_bytes())
        .map_err(|error| anyhow!("invalid signature_base64: {error}"))?;
    let public_key = STANDARD
        .decode(args.public_key_base64.trim().as_bytes())
        .map_err(|error| anyhow!("invalid public_key_base64: {error}"))?;
    skybridge_core::mldsa65_verify_detached(&message, &signature, &public_key)?;
    println!("ok");
    Ok(())
}

async fn maybe_pqc_identity_report(
    paths: &skybridge_agent::AgentPaths,
    identity: &skybridge_agent::DeviceIdentityMaterial,
) -> Result<Option<serde_json::Value>> {
    if identity.state.device.protocol_signing_algorithm != ProtocolSigningAlgorithm::MlDsa65
        && !pqc_bridge_identity_enabled()
    {
        return Ok(None);
    }

    let pqc_identity = ensure_rust_pqc_identity(paths).await?;
    Ok(Some(json!({
        "signing_algorithm": pqc_identity.signing_algorithm,
        "supported_suites": [
            CryptoSuite::XWING_MLDSA.to_string(),
            CryptoSuite::MLKEM768_MLDSA65.to_string(),
        ],
        "signing_public_key_base64": STANDARD.encode(&pqc_identity.signing_public_key),
        "signing_public_key_fingerprint": ProtocolIdentityBinding::compute_fingerprint(
            pqc_identity.signing_algorithm,
            &pqc_identity.signing_public_key,
        ),
        "kem_public_keys": [
            {
                "suite": CryptoSuite::XWING_MLDSA.to_string(),
                "wire_id": format!("{:#06x}", CryptoSuite::XWING_MLDSA.wire_id),
                "public_key_base64": STANDARD.encode(&pqc_identity.xwing_public_key),
            },
            {
                "suite": CryptoSuite::MLKEM768_MLDSA65.to_string(),
                "wire_id": format!("{:#06x}", CryptoSuite::MLKEM768_MLDSA65.wire_id),
                "public_key_base64": STANDARD.encode(&pqc_identity.mlkem768_public_key),
            }
        ],
        "bootstrap_env": {
            "SKYBRIDGE_PROTOCOL_SIGNING_ALGORITHM": ProtocolSigningAlgorithm::MlDsa65.as_str(),
            "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64": STANDARD.encode(&pqc_identity.xwing_public_key),
            "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64": STANDARD.encode(&pqc_identity.mlkem768_public_key),
        }
    })))
}

fn pqc_bridge_identity_enabled() -> bool {
    std::env::var(ENV_PQC_BRIDGE_IDENTITY)
        .ok()
        .is_some_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes"
            )
        })
}

async fn maybe_inline_pqc_responder_config(
    paths: &skybridge_agent::AgentPaths,
    identity: &skybridge_agent::DeviceIdentityMaterial,
    local_binding: &ProtocolIdentityBinding,
) -> Result<Option<PqcResponderConfig>> {
    if local_binding.protocol_signing_algorithm != ProtocolSigningAlgorithm::MlDsa65
        && !pqc_bridge_identity_enabled()
    {
        return Ok(None);
    }

    let pqc_identity = ensure_rust_pqc_identity(paths).await?;
    let pqc_binding =
        if local_binding.protocol_signing_algorithm == ProtocolSigningAlgorithm::MlDsa65 {
            local_binding.clone()
        } else {
            ProtocolIdentityBinding::new(
                local_binding.device_id.clone(),
                pqc_identity.signing_algorithm,
                pqc_identity.signing_public_key.clone(),
                None,
            )?
        };
    Ok(Some(PqcResponderConfig {
        local_binding: pqc_binding,
        local_device_name: Some(identity.state.device.device_name.clone()),
        identity: pqc_identity,
        supported_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
    }))
}

async fn device_status(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let identity = ensure_device_identity(&paths).await?;
    let health = load_health_snapshot(&paths).await?;
    let auth_session = load_auth_session(&paths).await?;
    let tenant_id = auth_session
        .as_ref()
        .and_then(|session| derive_tenant_identifier(&session.access_token));
    let pqc_identity = maybe_pqc_identity_report(&paths, &identity).await?;

    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "schema_version": identity.state.schema_version,
                "account_id": identity.state.account_id,
                "auth_state": identity.state.auth_state,
                "tenant_id": tenant_id,
                "device": identity.state.device,
                "pqc_identity": pqc_identity,
                "agent_health": health,
            }))?
        );
        return Ok(());
    }

    println!("Device ID: {}", identity.state.device.device_id);
    println!("Device Name: {}", identity.state.device.device_name);
    println!(
        "Enrollment: {}",
        describe_enrollment(identity.state.device.enrollment_status)
    );
    println!("Auth State: {}", describe_auth(identity.state.auth_state));
    println!(
        "Algorithm: {}",
        identity.state.device.protocol_signing_algorithm
    );
    println!(
        "Fingerprint: {}",
        identity
            .state
            .device
            .public_key_fingerprint
            .as_deref()
            .unwrap_or("<pending>")
    );
    println!(
        "Tenant ID: {}",
        tenant_id.as_deref().unwrap_or("<unresolved>")
    );
    if let Some(pqc_identity) = pqc_identity {
        let suites = pqc_identity["supported_suites"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|value| value.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        println!(
            "PQC: {}",
            if suites.is_empty() {
                "enabled"
            } else {
                &suites
            }
        );
    }
    if let Some(health) = health {
        println!(
            "Agent: {} (updated {})",
            describe_agent_status(health.status),
            health.updated_at
        );
    } else {
        println!("Agent: no health snapshot yet");
    }
    Ok(())
}

async fn device_enroll(state_dir: Option<PathBuf>, args: DeviceEnrollArgs) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let auth_session = require_auth_session(&paths).await?;
    let tenant_id = require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(&paths).await?;
    let binding = signing_binding(&identity)?;
    let signal_server = SignalServerClient::from_env()?;
    let invite_token = args
        .invite_token
        .or_else(|| std::env::var("SKYBRIDGE_ENROLL_INVITE_TOKEN").ok())
        .ok_or_else(|| {
            anyhow!(
                "missing invite token; pass --invite-token or set SKYBRIDGE_ENROLL_INVITE_TOKEN"
            )
        })?;
    let device_name = args
        .device_name
        .clone()
        .unwrap_or_else(|| identity.state.device.device_name.clone());

    let registered = signal_server
        .enroll_first_device(
            &auth_session,
            &tenant_id,
            &binding,
            &invite_token,
            &device_name,
        )
        .await?;
    let identity =
        update_enrollment_status(&paths, EnrollmentStatus::Enrolled, Some(&device_name)).await?;

    if args.output.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "enrolled": true,
                "tenant_id": tenant_id,
                "device": registered,
                "local_identity": identity,
            }))?
        );
    } else {
        println!("Device enrolled");
        println!("Tenant ID: {}", tenant_id);
        println!("Device ID: {}", registered.device_id);
        println!("Status: {}", registered.status);
    }
    Ok(())
}

async fn device_approve(state_dir: Option<PathBuf>, args: DeviceApproveArgs) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let auth_session = require_auth_session(&paths).await?;
    let tenant_id = require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(&paths).await?;
    let approver_binding = signing_binding(&identity)?;
    let pending_algorithm = args.pending_algorithm.parse::<ProtocolSigningAlgorithm>()?;
    let pending_binding = ProtocolIdentityBinding::new(
        args.pending_device_id.clone(),
        pending_algorithm,
        match pending_algorithm {
            ProtocolSigningAlgorithm::Ed25519 => vec![0_u8; 32],
            ProtocolSigningAlgorithm::MlDsa65 => vec![1_u8],
        },
        Some(args.pending_fingerprint.clone()),
    )?;
    let signal_server = SignalServerClient::from_env()?;
    let registered = signal_server
        .confirm_device_enrollment(
            &auth_session,
            &tenant_id,
            &approver_binding,
            &pending_binding,
            args.device_name.as_deref().unwrap_or("Approved Device"),
        )
        .await?;

    if args.output.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "confirmed": true,
                "tenant_id": tenant_id,
                "device": registered,
            }))?
        );
    } else {
        println!("Device approved");
        println!("Pending Device ID: {}", registered.device_id);
        println!("Status: {}", registered.status);
    }
    Ok(())
}

async fn code_create(state_dir: Option<PathBuf>, args: CodeCreateArgs) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let auth_session = require_auth_session(&paths).await?;
    let tenant_id = require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(&paths).await?;
    let binding = signing_binding(&identity)?;
    let signal_server = SignalServerClient::from_env()?;
    let admission =
        request_admission_lease(&signal_server, &auth_session, &tenant_id, &identity).await?;
    let device_name = args
        .device_name
        .clone()
        .unwrap_or_else(|| identity.state.device.device_name.clone());
    let lease = signal_server
        .register_connection_code(&admission.token, &device_name, args.ttl_seconds)
        .await?;
    let turn_credentials = signal_server
        .fetch_turn_credentials(&lease.turn_admission_lease.token)
        .await?;
    upsert_session_runtime(
        &paths,
        RuntimeSessionRecord::new(
            make_runtime_id(&lease.session_id),
            lease.session_id.clone(),
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            lease.signaling_server_origin.clone(),
            identity.state.device.device_id.clone(),
            None,
            None,
            None,
            RuntimeSessionState::Pending,
        ),
    )
    .await?;
    upsert_managed_session_control(
        &paths,
        ManagedSessionControl::new(
            lease.session_id.clone(),
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            identity.state.device.device_id.clone(),
            lease.signaling_server_origin.clone(),
            lease.session_token.clone(),
            Some(turn_credentials.clone()),
        ),
    )
    .await?;

    let output = json!({
        "code": lease.code,
        "session_id": lease.session_id,
        "expires_in": lease.expires_in,
        "signaling_server_origin": lease.signaling_server_origin,
        "turn_credential_ttl": turn_credentials.ttl,
        "device_name": device_name,
        "tenant_id": tenant_id,
        "fingerprint": binding.protocol_public_key_fingerprint,
    });
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&output)?);
    } else {
        println!("Code: {}", output["code"].as_str().unwrap_or_default());
        println!(
            "Session ID: {}",
            output["session_id"].as_str().unwrap_or_default()
        );
        println!(
            "Expires In: {}s",
            output["expires_in"].as_i64().unwrap_or_default()
        );
        println!(
            "Signaling Origin: {}",
            output["signaling_server_origin"]
                .as_str()
                .unwrap_or_default()
        );
    }
    Ok(())
}

async fn connect_code(state_dir: Option<PathBuf>, args: ConnectCommand) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let auth_session = require_auth_session(&paths).await?;
    let tenant_id = require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(&paths).await?;
    let local_binding = signing_binding(&identity)?;
    let pqc_responder =
        maybe_inline_pqc_responder_config(&paths, &identity, &local_binding).await?;
    let signal_server = SignalServerClient::from_env()?;
    let admission =
        request_admission_lease(&signal_server, &auth_session, &tenant_id, &identity).await?;
    let lookup = signal_server
        .lookup_connection_code(&admission.token, &args.code)
        .await?;
    let turn_credentials = signal_server
        .fetch_turn_credentials(&lookup.turn_admission_lease.token)
        .await?;
    let canonical_origin =
        CurrentPathOriginPolicy::canonical_origin(&lookup.signaling_server_origin)?;
    let ws_url = signal_server.websocket_url(
        &lookup.signaling_server_origin,
        &lookup.session_id,
        &lookup.session_token,
    )?;
    let mut connection = SignalingConnection::connect(ws_url, &lookup.session_id).await?;

    let initial_record = RuntimeSessionRecord::new(
        make_runtime_id(&lookup.session_id),
        lookup.session_id.clone(),
        RuntimeSessionRole::Responder,
        RuntimeSessionSource::Code,
        canonical_origin.clone(),
        identity.state.device.device_id.clone(),
        Some(lookup.initiator_device_id.clone()),
        lookup.initiator_device_name.clone(),
        Some(lookup.initiator_protocol_public_key_fingerprint.clone()),
        RuntimeSessionState::Connecting,
    );
    upsert_session_runtime(&paths, initial_record).await?;
    let mut native_session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: lookup.session_id.clone(),
        local_device_id: identity.state.device.device_id.clone(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: Some(turn_credentials),
        classic_initiator: None,
        pqc_initiator: None,
        pqc_responder,
    })
    .await?;
    native_session.start().await?;

    let bound_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let hold_deadline = tokio::time::Instant::now() + Duration::from_secs(args.hold_seconds);
    let mut signaling_stream_closed = false;
    let mut signaling_bound = false;
    let mut join_sent = false;

    loop {
        if !signaling_bound && tokio::time::Instant::now() >= bound_deadline {
            bail!("signaling connect timed out before bound");
        }
        if args.hold_seconds > 0 && signaling_bound && tokio::time::Instant::now() >= hold_deadline
        {
            break;
        }
        if should_stop_inline_connect(&paths, &lookup.session_id, signaling_stream_closed).await? {
            break;
        }

        tokio::select! {
            event = connection.next_runtime_event(), if !signaling_stream_closed => {
                let Some(event) = event else {
                    signaling_stream_closed = true;
                    continue;
                };
                match event {
                    SignalingRuntimeEvent::Lifecycle(lifecycle) => {
                        apply_runtime_session_event(&paths, &lookup.session_id, &lifecycle).await?;
                        if lifecycle.phase == SignalingLifecyclePhase::Bound && !join_sent {
                            signaling_bound = true;
                            connection
                                .send(make_join_envelope(
                                    &lookup.session_id,
                                    &identity.state.device.device_id,
                                ))
                                .await?;
                            join_sent = true;
                        }
                        drain_inline_native_events(
                            &paths,
                            &connection,
                            &lookup.session_id,
                            &mut native_session,
                        )
                        .await?;
                        if lifecycle.phase == SignalingLifecyclePhase::Failed && !signaling_bound {
                            bail!(
                                "signaling failed before bound: {}",
                                lifecycle
                                    .error_description
                                    .unwrap_or_else(|| "unknown".to_owned())
                            );
                        }
                        if matches!(lifecycle.phase, SignalingLifecyclePhase::Closed | SignalingLifecyclePhase::Failed) {
                            signaling_stream_closed = true;
                        }
                    }
                    SignalingRuntimeEvent::Inbound(inbound) => {
                        apply_inline_inbound_runtime_event(
                            &paths,
                            &lookup.session_id,
                            inbound,
                            &native_session,
                        )
                        .await?;
                        drain_inline_native_events(
                            &paths,
                            &connection,
                            &lookup.session_id,
                            &mut native_session,
                        )
                        .await?;
                    }
                }
            }
            event = native_session.next_event() => {
                let Some(event) = event else {
                    continue;
                };
                apply_inline_native_event(
                    &paths,
                    &connection,
                    &lookup.session_id,
                    event,
                )
                .await?;
            }
            _ = tokio::time::sleep(Duration::from_millis(100)) => {}
        }
    }

    let snapshot = connection.snapshot().await;
    let registry = load_session_registry(&paths).await?;
    let record = registry
        .get(&lookup.session_id)
        .cloned()
        .ok_or_else(|| anyhow!("runtime session disappeared"))?;

    let output = json!({
        "signaling_bound": signaling_bound,
        "session_id": lookup.session_id,
        "role": record.role,
        "source": record.source,
        "signaling_server_origin": record.signaling_server_origin,
        "lifecycle_phase": record.lifecycle_phase,
        "runtime_state": record.state,
        "signaling_health": record.signaling_health,
        "readiness": record.readiness,
        "transport_preserved": record.transport_preserved,
        "remote_device_id": lookup.initiator_device_id,
        "remote_device_name": lookup.initiator_device_name,
        "remote_protocol_signing_algorithm": lookup.initiator_protocol_signing_algorithm,
        "remote_protocol_public_key_fingerprint": lookup.initiator_protocol_public_key_fingerprint,
        "active_handle": snapshot.active_handle,
    });
    if args.json {
        println!("{}", serde_json::to_string_pretty(&output)?);
    } else {
        println!(
            "Completed signaling plane run for session {}",
            output["session_id"].as_str().unwrap_or_default()
        );
        println!(
            "Lifecycle Phase: {}",
            output["lifecycle_phase"].as_str().unwrap_or_default()
        );
        println!(
            "Remote Device: {}",
            output["remote_device_id"].as_str().unwrap_or_default()
        );
        println!(
            "Signaling Origin: {}",
            output["signaling_server_origin"]
                .as_str()
                .unwrap_or_default()
        );
    }
    Ok(())
}

async fn drain_inline_native_events(
    paths: &skybridge_agent::AgentPaths,
    connection: &SignalingConnection,
    session_id: &str,
    native_session: &mut NativeWebRtcSession,
) -> Result<()> {
    while let Some(event) = native_session.try_next_event() {
        apply_inline_native_event(paths, connection, session_id, event).await?;
    }
    Ok(())
}

async fn session_ls(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let registry = load_session_registry(&paths).await?;
    let sessions = registry.values_sorted();
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(
                &json!({ "schema_version": registry.schema_version, "sessions": sessions }),
            )?
        );
        return Ok(());
    }
    if sessions.is_empty() {
        println!("No recorded sessions");
        return Ok(());
    }
    for session in sessions {
        println!(
            "{} [{:?}] {:?} {:?} readiness={} preserved={} keepalive={}",
            session.session_id,
            session.role,
            session.state,
            session.signaling_health,
            describe_runtime_readiness(&session),
            session.transport_preserved,
            describe_keepalive_brief(&session.keepalive),
        );
    }
    Ok(())
}

async fn session_inspect(state_dir: Option<PathBuf>, args: SessionInspectArgs) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let registry = load_session_registry(&paths).await?;
    let session = registry
        .get(&args.id)
        .cloned()
        .ok_or_else(|| anyhow!("session `{}` not found", args.id))?;
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&session)?);
    } else {
        println!("Session ID: {}", session.session_id);
        println!("Role: {:?}", session.role);
        println!("Source: {:?}", session.source);
        println!("Lifecycle Phase: {:?}", session.lifecycle_phase);
        println!("Signaling Health: {:?}", session.signaling_health);
        println!(
            "Current Readiness: {}",
            describe_readiness(&session.readiness)
        );
        if let Some(last_established) = session.last_established_readiness.as_ref() {
            if session.readiness != *last_established {
                println!(
                    "Last Established Readiness: {}",
                    describe_readiness(last_established)
                );
            }
        }
        println!("Transport Preserved: {}", session.transport_preserved);
        if let Some(summary) = describe_terminal_runtime_summary(&session) {
            println!("Runtime Summary: {summary}");
        }
        if let Some(transport_ready_at) = session.transport_ready_at {
            println!("Transport Ready At: {transport_ready_at}");
        }
        if let Some(handshake_completed_at) = session.handshake_completed_at {
            println!("Handshake Completed At: {handshake_completed_at}");
        }
        println!(
            "Keepalive: {}",
            describe_keepalive_brief(&session.keepalive)
        );
        if let Some(last_activity_at) = session.keepalive.last_activity_at {
            println!("Last Data-plane Activity: {last_activity_at}");
        }
        if let Some(error) = session.last_transport_error.as_deref() {
            println!("Last Transport Error: {error}");
        }
        println!("Updated At: {}", session.updated_at);
    }
    Ok(())
}

async fn disconnect(state_dir: Option<PathBuf>, session_id: &str) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let registry = load_session_registry(&paths).await?;
    if registry.get(session_id).is_none() {
        bail!("session `{}` not found", session_id);
    }
    let _ = remove_managed_session_control(&paths, session_id).await;
    remove_session_runtime(
        &paths,
        session_id,
        Some("disconnected_by_operator".to_owned()),
    )
    .await?;
    println!("Marked session {} as disconnected", session_id);
    Ok(())
}

async fn doctor(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let identity = ensure_device_identity(&paths).await?;
    let health = load_health_snapshot(&paths).await?;
    let auth_session = load_auth_session(&paths).await?;
    let signal_server = SignalServerClient::from_env()?;
    let now = OffsetDateTime::now_utc();

    let identity_ok =
        identity.state.schema_version == skybridge_core::LocalIdentityState::SCHEMA_VERSION;
    let auth_ok = auth_session
        .as_ref()
        .is_some_and(|session| derive_tenant_identifier(&session.access_token).is_some());
    let health_freshness = health
        .as_ref()
        .map(|value| (now - value.updated_at).whole_seconds())
        .unwrap_or(-1);
    let health_ok = health.as_ref().is_some_and(|value| {
        value.schema_version == skybridge_core::AgentHealthSnapshot::SCHEMA_VERSION
            && health_freshness <= 10
    });
    let log_exists = tokio::fs::try_exists(&paths.log_file).await?;
    let control_plane_health = signal_server.probe_health().await;
    let control_plane_ok = control_plane_health.is_ok();
    let control_plane_detail = match &control_plane_health {
        Ok(snapshot) => format!(
            "reachable via {} (status={} instance={} backend={})",
            signal_server.base_url,
            snapshot.status,
            snapshot.instance_id.as_deref().unwrap_or("unknown"),
            snapshot.state_backend.as_deref().unwrap_or("unknown")
        ),
        Err(error) => format!(
            "control-plane probe failed against {}: {}",
            signal_server.base_url, error
        ),
    };

    let report = json!({
        "state_dir": paths.root.display().to_string(),
        "checks": [
            {
                "name": "state_directory",
                "ok": tokio::fs::try_exists(&paths.root).await?,
                "detail": "state directory is resolved and accessible",
            },
            {
                "name": "device_identity",
                "ok": identity_ok,
                "detail": if identity_ok {
                    "device identity and signing key are present"
                } else {
                    "device identity missing or schema-mismatched"
                },
            },
            {
                "name": "auth_session",
                "ok": auth_ok,
                "detail": if auth_ok {
                    "auth session present and tenant derivation succeeded"
                } else {
                    "auth session missing or tenant derivation failed; run `skybridge login`"
                },
            },
            {
                "name": "agent_health",
                "ok": health_ok,
                "detail": if health_ok {
                    format!("health snapshot is fresh ({}s old)", health_freshness)
                } else if health.is_some() {
                    format!("health snapshot is stale ({}s old)", health_freshness)
                } else {
                    "health snapshot missing; start the agent in foreground or background".to_owned()
                },
            },
            {
                "name": "agent_log",
                "ok": log_exists,
                "detail": if log_exists {
                    "structured log file exists".to_owned()
                } else {
                    "structured log file missing; run the agent once to create it".to_owned()
                },
            },
            {
                "name": "control_plane",
                "ok": control_plane_ok,
                "detail": control_plane_detail,
            }
        ]
    });

    if as_json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }

    println!("State directory: {}", paths.root.display());
    for check in report["checks"]
        .as_array()
        .ok_or_else(|| anyhow!("doctor report shape changed"))?
    {
        let status = if check["ok"].as_bool().unwrap_or(false) {
            "OK"
        } else {
            "WARN"
        };
        println!(
            "[{}] {}: {}",
            status,
            check["name"].as_str().unwrap_or("unknown"),
            check["detail"].as_str().unwrap_or("")
        );
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize)]
struct DoctorCheck {
    name: &'static str,
    ok: bool,
    severity: &'static str,
    detail: String,
    #[serde(
        rename = "serverBuildFingerprint",
        skip_serializing_if = "Option::is_none"
    )]
    server_build_fingerprint: Option<String>,
    #[serde(rename = "stateBackend", skip_serializing_if = "Option::is_none")]
    state_backend: Option<String>,
    #[serde(rename = "rejectReason", skip_serializing_if = "Option::is_none")]
    reject_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
struct DoctorProbeReport {
    target: String,
    checks: Vec<DoctorCheck>,
}

async fn doctor_signaling(args: SignalingDoctorArgs) -> Result<()> {
    let as_json = args.output.json;
    let report =
        build_signaling_doctor_report(args.base_url, args.expected_backend.as_deref()).await?;
    print_doctor_probe_report(&report, as_json)
}

async fn doctor_media_lease(args: MediaLeaseDoctorArgs) -> Result<()> {
    let as_json = args.output.json;
    let report =
        build_media_lease_doctor_report(args.base_url, args.session_id, args.media_admission_token)
            .await?;
    print_doctor_probe_report(&report, as_json)
}

async fn build_signaling_doctor_report(
    base_url: Option<String>,
    expected_backend: Option<&str>,
) -> Result<DoctorProbeReport> {
    let signal_server = signal_server_client(base_url)?;
    let target = signal_server.base_url.clone();
    let root = signal_server.probe_json_endpoint("/").await;
    let health = signal_server.probe_json_endpoint("/health").await;
    let ready = signal_server.probe_json_endpoint("/readyz").await;
    let turn_credentials = signal_server
        .probe_json_endpoint("/api/turn/credentials")
        .await;
    let media_lease_route = signal_server.probe_media_lease_without_token().await;
    let mut checks = Vec::new();

    checks.push(check_probe_reachable("root", &root, "/"));
    checks.push(check_probe_reachable("health", &health, "/health"));
    checks.push(check_readyz(&ready));
    checks.push(check_route_present(
        "turn_credentials_route",
        &turn_credentials,
        "/api/turn/credentials",
    ));
    checks.push(check_route_present(
        "media_lease_route",
        &media_lease_route,
        "/api/media/lease",
    ));

    let build = first_string(
        &[probe_body(&health), probe_body(&ready), probe_body(&root)],
        "serverBuildFingerprint",
    );
    checks.push(check_build_fingerprint(build.clone()));

    let state_backend = first_string(
        &[probe_body(&health), probe_body(&ready), probe_body(&root)],
        "stateBackend",
    );
    checks.push(check_state_backend(state_backend.clone(), expected_backend));

    let supports_media = first_bool(
        &[probe_body(&health), probe_body(&ready), probe_body(&root)],
        "supportsMediaAdmissionRefresh",
    );
    let media_route_present = route_present(&media_lease_route);
    let media_ok = supports_media == Some(true) && media_route_present;
    checks.push(DoctorCheck {
        name: "media_diagnostics_supported",
        ok: media_ok,
        severity: if media_ok { "info" } else { "error" },
        detail: if media_ok {
            "health advertises media admission refresh and /api/media/lease is routable".to_owned()
        } else if supports_media != Some(true) {
            "server did not advertise media admission diagnostics support".to_owned()
        } else {
            "/api/media/lease is missing or hidden behind a bad gateway".to_owned()
        },
        server_build_fingerprint: build,
        state_backend,
        reject_reason: None,
    });

    Ok(DoctorProbeReport { target, checks })
}

async fn build_media_lease_doctor_report(
    base_url: Option<String>,
    expected_session_id: Option<String>,
    media_admission_token: Option<String>,
) -> Result<DoctorProbeReport> {
    let signal_server = signal_server_client(base_url)?;
    let target = signal_server.base_url.clone();
    let health = signal_server.probe_json_endpoint("/health").await;
    let mut checks = vec![check_probe_reachable("health", &health, "/health")];

    let supports_media = first_bool(&[probe_body(&health)], "supportsMediaAdmissionRefresh");
    checks.push(DoctorCheck {
        name: "media_endpoint_advertised",
        ok: supports_media == Some(true),
        severity: if supports_media == Some(true) {
            "info"
        } else {
            "error"
        },
        detail: "health should advertise supportsMediaAdmissionRefresh=true".to_owned(),
        server_build_fingerprint: first_string(&[probe_body(&health)], "serverBuildFingerprint"),
        state_backend: first_string(&[probe_body(&health)], "stateBackend"),
        reject_reason: None,
    });

    let Some(token) = media_admission_token.filter(|value| !value.trim().is_empty()) else {
        checks.push(DoctorCheck {
            name: "media_admission_token",
            ok: false,
            severity: "warn",
            detail: "media lease was not probed; pass --media-admission-token or SKYBRIDGE_MEDIA_ADMISSION_TOKEN".to_owned(),
            server_build_fingerprint: first_string(&[probe_body(&health)], "serverBuildFingerprint"),
            state_backend: first_string(&[probe_body(&health)], "stateBackend"),
            reject_reason: None,
        });
        return Ok(DoctorProbeReport { target, checks });
    };

    let lease = signal_server.probe_media_lease(&token).await;
    let lease_body = probe_body(&lease);
    let lease_success = lease.as_ref().is_ok_and(|probe| probe.success);
    let response_session_id = lease_body.and_then(|body| value_string(body, "sessionId"));
    let expected_session_matches = match expected_session_id.as_deref() {
        Some(expected) if lease_success => response_session_id
            .as_deref()
            .is_some_and(|actual| actual == expected),
        Some(_) if !lease_success => false,
        _ => true,
    };
    checks.push(DoctorCheck {
        name: "media_lease_success",
        ok: lease_success && expected_session_matches,
        severity: if lease_success && expected_session_matches {
            "info"
        } else {
            "error"
        },
        detail: match (&lease, expected_session_id.as_deref()) {
            (Ok(probe), Some(expected)) if probe.success && expected_session_matches => {
                format!(
                    "/api/media/lease returned HTTP {} for session {expected}",
                    probe.status_code
                )
            }
            (Ok(probe), Some(expected)) if probe.success => format!(
                "/api/media/lease returned session {}; expected {expected}",
                response_session_id.as_deref().unwrap_or("<missing>")
            ),
            (Ok(probe), _) => format!(
                "/api/media/lease rejected request with HTTP {}",
                probe.status_code
            ),
            (Err(error), _) => format!("/api/media/lease probe failed: {error}"),
        },
        server_build_fingerprint: lease_body
            .and_then(|body| value_string(body, "serverBuildFingerprint"))
            .or_else(|| first_string(&[probe_body(&health)], "serverBuildFingerprint")),
        state_backend: first_string(&[probe_body(&health)], "stateBackend"),
        reject_reason: lease_body.and_then(|body| value_string(body, "rejectReason")),
    });
    let diagnostic_fields_present = lease_body.is_some_and(|body| {
        body.get("rejectReason").is_some()
            || body.get("mediaTokenRevokedReason").is_some()
            || body.get("mediaTokenSessionRejectReason").is_some()
            || body.get("mediaTokenRequestGeneration").is_some()
            || body.get("mediaTokenSessionPresent").is_some()
    });
    checks.push(DoctorCheck {
        name: "media_lease_diagnostics",
        ok: lease_success || diagnostic_fields_present,
        severity: if lease_success || diagnostic_fields_present {
            "info"
        } else {
            "error"
        },
        detail: if lease_success {
            "media lease succeeded; no rejection diagnostics were needed".to_owned()
        } else if diagnostic_fields_present {
            "rejected media lease included structured token/session diagnostics".to_owned()
        } else {
            "rejected media lease did not include structured diagnostics".to_owned()
        },
        server_build_fingerprint: lease_body
            .and_then(|body| value_string(body, "serverBuildFingerprint"))
            .or_else(|| first_string(&[probe_body(&health)], "serverBuildFingerprint")),
        state_backend: first_string(&[probe_body(&health)], "stateBackend"),
        reject_reason: lease_body.and_then(|body| value_string(body, "rejectReason")),
    });

    Ok(DoctorProbeReport { target, checks })
}

fn signal_server_client(base_url: Option<String>) -> Result<SignalServerClient> {
    if let Some(base_url) = base_url.filter(|value| !value.trim().is_empty()) {
        let api_key = std::env::var("SKYBRIDGE_CLIENT_API_KEY")
            .unwrap_or_else(|_| "skybridge-client-v1".to_owned());
        let client_version = std::env::var("SKYBRIDGE_CLIENT_VERSION")
            .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_owned());
        let protocol_version =
            std::env::var("SKYBRIDGE_PROTOCOL_VERSION").unwrap_or_else(|_| "1".to_owned());
        return SignalServerClient::new(base_url, api_key, client_version, protocol_version);
    }
    SignalServerClient::from_env()
}

fn print_doctor_probe_report(report: &DoctorProbeReport, as_json: bool) -> Result<()> {
    if as_json {
        println!("{}", serde_json::to_string_pretty(report)?);
        return Ok(());
    }
    println!("Target: {}", report.target);
    for check in &report.checks {
        let status = if check.ok {
            "OK".to_owned()
        } else {
            check.severity.to_ascii_uppercase()
        };
        println!("[{}] {}: {}", status, check.name, check.detail);
    }
    Ok(())
}

fn check_probe_reachable(
    name: &'static str,
    probe: &Result<skybridge_core::ControlPlaneRawProbe>,
    path: &str,
) -> DoctorCheck {
    match probe {
        Ok(probe) => DoctorCheck {
            name,
            ok: probe.success,
            severity: if probe.success { "info" } else { "error" },
            detail: format!("{path} returned HTTP {}", probe.status_code),
            server_build_fingerprint: value_string(&probe.body, "serverBuildFingerprint"),
            state_backend: value_string(&probe.body, "stateBackend"),
            reject_reason: value_string(&probe.body, "rejectReason"),
        },
        Err(error) => DoctorCheck {
            name,
            ok: false,
            severity: "error",
            detail: format!("{path} probe failed: {error}"),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        },
    }
}

fn check_readyz(probe: &Result<skybridge_core::ControlPlaneRawProbe>) -> DoctorCheck {
    match probe {
        Ok(probe) => {
            let status = value_string(&probe.body, "status").unwrap_or_else(|| "-".to_owned());
            let ok = probe.success && status == "ready";
            DoctorCheck {
                name: "readyz",
                ok,
                severity: if ok { "info" } else { "error" },
                detail: format!(
                    "/readyz returned HTTP {} status={status}",
                    probe.status_code
                ),
                server_build_fingerprint: value_string(&probe.body, "serverBuildFingerprint"),
                state_backend: value_string(&probe.body, "stateBackend"),
                reject_reason: value_string(&probe.body, "rejectReason"),
            }
        }
        Err(error) => DoctorCheck {
            name: "readyz",
            ok: false,
            severity: "error",
            detail: format!("/readyz probe failed: {error}"),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        },
    }
}

fn route_present(probe: &Result<skybridge_core::ControlPlaneRawProbe>) -> bool {
    probe
        .as_ref()
        .is_ok_and(|probe| !matches!(probe.status_code, 404 | 405 | 502))
}

fn check_route_present(
    name: &'static str,
    probe: &Result<skybridge_core::ControlPlaneRawProbe>,
    path: &str,
) -> DoctorCheck {
    match probe {
        Ok(probe) => {
            let ok = !matches!(probe.status_code, 404 | 405 | 502);
            DoctorCheck {
                name,
                ok,
                severity: if ok { "info" } else { "error" },
                detail: format!("{path} route probe returned HTTP {}", probe.status_code),
                server_build_fingerprint: value_string(&probe.body, "serverBuildFingerprint"),
                state_backend: value_string(&probe.body, "stateBackend"),
                reject_reason: value_string(&probe.body, "rejectReason"),
            }
        }
        Err(error) => DoctorCheck {
            name,
            ok: false,
            severity: "error",
            detail: format!("{path} route probe failed: {error}"),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        },
    }
}

fn check_build_fingerprint(fingerprint: Option<String>) -> DoctorCheck {
    let ok = fingerprint
        .as_deref()
        .is_some_and(|value| !is_generic_build_fingerprint(value));
    DoctorCheck {
        name: "build_fingerprint",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: match fingerprint.as_deref() {
            Some(value) if ok => format!("server build fingerprint is {value}"),
            Some(value) => format!("server build fingerprint is generic: {value}"),
            None => "server build fingerprint missing".to_owned(),
        },
        server_build_fingerprint: fingerprint,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_state_backend(
    state_backend: Option<String>,
    expected_backend: Option<&str>,
) -> DoctorCheck {
    let ok = match expected_backend {
        Some(expected) => state_backend
            .as_deref()
            .is_some_and(|value| value.eq_ignore_ascii_case(expected)),
        None => state_backend.is_some(),
    };
    DoctorCheck {
        name: "state_backend",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: match (state_backend.as_deref(), expected_backend) {
            (Some(value), Some(_)) if ok => format!("state backend is {value}"),
            (Some(value), Some(expected)) => {
                format!("state backend is {value}; expected {expected}")
            }
            (None, Some(expected)) => format!("state backend missing; expected {expected}"),
            (Some(value), None) => format!("state backend is {value}"),
            (None, None) => "state backend missing".to_owned(),
        },
        server_build_fingerprint: None,
        state_backend,
        reject_reason: None,
    }
}

fn probe_body(probe: &Result<skybridge_core::ControlPlaneRawProbe>) -> Option<&serde_json::Value> {
    probe.as_ref().ok().map(|probe| &probe.body)
}

fn value_string(value: &serde_json::Value, key: &str) -> Option<String> {
    value.get(key)?.as_str().map(ToOwned::to_owned)
}

fn value_bool(value: &serde_json::Value, key: &str) -> Option<bool> {
    value.get(key)?.as_bool()
}

fn first_string(values: &[Option<&serde_json::Value>], key: &str) -> Option<String> {
    values
        .iter()
        .filter_map(|value| value.and_then(|item| value_string(item, key)))
        .next()
}

fn first_bool(values: &[Option<&serde_json::Value>], key: &str) -> Option<bool> {
    values
        .iter()
        .filter_map(|value| value.and_then(|item| value_bool(item, key)))
        .next()
}

fn is_generic_build_fingerprint(value: &str) -> bool {
    let normalized = value.trim();
    normalized.is_empty()
        || normalized == "skybridge-signaling/1.0.0"
        || normalized.ends_with("+unidentified-build")
}

async fn metrics(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let health = load_health_snapshot(&paths).await?;
    let Some(health) = health else {
        bail!("No health snapshot found. Start the agent first.");
    };

    let payload = json!({
        "status": health.status,
        "updated_at": health.updated_at.format(&time::format_description::well_known::Rfc3339)?,
        "active_sessions": health.active_sessions,
        "active_transfers": health.active_transfers,
        "fallback_invocation_count": health.fallback_invocation_count,
    });

    if as_json {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("Status: {}", describe_agent_status(health.status));
        println!("Updated At: {}", health.updated_at);
        println!("Active Sessions: {}", health.active_sessions);
        println!("Active Transfers: {}", health.active_transfers);
        println!(
            "Fallback Invocation Count: {}",
            health.fallback_invocation_count
        );
    }
    Ok(())
}

async fn tail_logs(state_dir: Option<PathBuf>, lines: usize) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let body = tokio::fs::read_to_string(&paths.log_file)
        .await
        .map_err(|error| {
            anyhow!(
                "Failed to read {}: {}. Start the agent once to create the structured log file.",
                paths.log_file.display(),
                error
            )
        })?;

    let mut tail = body.lines().rev().take(lines).collect::<Vec<_>>();
    tail.reverse();
    for line in tail {
        println!("{line}");
    }
    Ok(())
}

fn version() -> Result<()> {
    let payload = json!({
        "cli_version": env!("CARGO_PKG_VERSION"),
        "workspace": "rust",
        "contracts_schema_version": 1u32,
        "implemented_phases": ["phase_4_auth", "phase_5_signaling_plane"],
    });
    println!("{}", serde_json::to_string_pretty(&payload)?);
    Ok(())
}

async fn request_admission_lease(
    signal_server: &SignalServerClient,
    auth_session: &skybridge_core::AuthSession,
    tenant_id: &str,
    identity: &skybridge_agent::DeviceIdentityMaterial,
) -> Result<skybridge_core::AdmissionLease> {
    let binding = signing_binding(identity)?;
    let challenge = signal_server
        .request_admission_challenge(auth_session, tenant_id, &binding)
        .await?;
    let signature = signing_signature(identity, &challenge.signature_payload())?;
    signal_server
        .complete_admission(auth_session, tenant_id, &challenge, &binding, &signature)
        .await
}

async fn require_auth_session(
    paths: &skybridge_agent::AgentPaths,
) -> Result<skybridge_core::AuthSession> {
    if let Some(session) = refresh_auth_session_if_needed(paths).await? {
        return Ok(session);
    }
    bail!("No auth session found. Run `skybridge login` first.")
}

fn require_tenant_id(session: &skybridge_core::AuthSession) -> Result<String> {
    derive_tenant_identifier(&session.access_token).ok_or_else(|| {
        anyhow!("failed to derive tenant id from access token; set SKYBRIDGE_TENANT_ID if needed")
    })
}

async fn apply_runtime_session_event(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
    event: &SignalingLifecycleEvent,
) -> Result<()> {
    let mut registry = load_session_registry(paths).await?;
    registry.apply_signaling_event(session_id, event);
    store_session_registry(paths, &registry).await
}

async fn apply_inline_inbound_runtime_event(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
    inbound: InboundMessage,
    native_session: &NativeWebRtcSession,
) -> Result<()> {
    match inbound {
        InboundMessage::Envelope(envelope) => {
            let mut registry = load_session_registry(paths).await?;
            registry.update_remote_peer(session_id, envelope.from.clone(), None, None);
            store_session_registry(paths, &registry).await?;
            native_session.handle_signaling_envelope(&envelope).await?;
        }
        InboundMessage::ServerFrame(_) | InboundMessage::Unknown => {}
    }
    Ok(())
}

async fn apply_inline_native_event(
    paths: &skybridge_agent::AgentPaths,
    connection: &SignalingConnection,
    session_id: &str,
    event: NativeWebRtcEvent,
) -> Result<()> {
    match event {
        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
            connection.send(envelope).await?;
        }
        NativeWebRtcEvent::TransportReady => {
            let mut registry = load_session_registry(paths).await?;
            registry
                .apply_transport_event(session_id, RuntimeSessionTransportEvent::TransportReady);
            store_session_registry(paths, &registry).await?;
        }
        NativeWebRtcEvent::HandshakeComplete { negotiated_suite } => {
            let mut registry = load_session_registry(paths).await?;
            registry.apply_transport_event(
                session_id,
                RuntimeSessionTransportEvent::HandshakeComplete { negotiated_suite },
            );
            store_session_registry(paths, &registry).await?;
        }
        NativeWebRtcEvent::Keepalive { kind, ping_id } => {
            let mut registry = load_session_registry(paths).await?;
            registry.apply_transport_event(
                session_id,
                RuntimeSessionTransportEvent::Keepalive { kind, ping_id },
            );
            store_session_registry(paths, &registry).await?;
        }
        NativeWebRtcEvent::TransportDisconnected { reason } => {
            let mut registry = load_session_registry(paths).await?;
            registry.apply_transport_event(
                session_id,
                RuntimeSessionTransportEvent::TransportDisconnected { reason },
            );
            store_session_registry(paths, &registry).await?;
        }
    }
    Ok(())
}

async fn should_stop_inline_connect(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
    signaling_stream_closed: bool,
) -> Result<bool> {
    let registry = load_session_registry(paths).await?;
    let Some(record) = registry.get(session_id) else {
        return Ok(true);
    };
    if matches!(
        record.state,
        RuntimeSessionState::Disconnected | RuntimeSessionState::Failed
    ) {
        return Ok(true);
    }
    if signaling_stream_closed && !record.readiness.is_transport_established_for(session_id) {
        return Ok(true);
    }
    Ok(false)
}

fn not_implemented(message: &str) -> Result<()> {
    bail!(message.to_owned())
}

fn placeholder_json_or_text(as_json: bool, payload: serde_json::Value, text: &str) -> Result<()> {
    if as_json {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("{text}");
    }
    Ok(())
}

fn describe_enrollment(status: EnrollmentStatus) -> &'static str {
    match status {
        EnrollmentStatus::Unenrolled => "unenrolled",
        EnrollmentStatus::PendingApproval => "pending_approval",
        EnrollmentStatus::Enrolled => "enrolled",
    }
}

fn describe_auth(state: AuthState) -> &'static str {
    match state {
        AuthState::LoggedOut => "logged_out",
        AuthState::LoggedIn => "logged_in",
    }
}

fn describe_agent_status(status: AgentRuntimeStatus) -> &'static str {
    match status {
        AgentRuntimeStatus::Starting => "starting",
        AgentRuntimeStatus::Healthy => "healthy",
        AgentRuntimeStatus::Degraded => "degraded",
        AgentRuntimeStatus::Stopping => "stopping",
    }
}

fn describe_readiness(readiness: &SessionReadiness) -> String {
    match readiness {
        SessionReadiness::Idle => "idle".to_owned(),
        SessionReadiness::TransportReady { session_id } => {
            format!("transport_ready({session_id})")
        }
        SessionReadiness::HandshakeComplete {
            session_id,
            negotiated_suite,
        } => format!("handshake_complete({session_id}, suite={negotiated_suite})"),
    }
}

fn describe_runtime_readiness(session: &RuntimeSessionRecord) -> String {
    let current = describe_readiness(&session.readiness);
    match session.last_established_readiness.as_ref() {
        Some(last_established) if session.readiness != *last_established => format!(
            "{current} (last_established={})",
            describe_readiness(last_established)
        ),
        _ => current,
    }
}

fn describe_terminal_runtime_summary(session: &RuntimeSessionRecord) -> Option<String> {
    if !matches!(
        session.state,
        RuntimeSessionState::Disconnected | RuntimeSessionState::Failed
    ) {
        return None;
    }

    let phase = match session.state {
        RuntimeSessionState::Disconnected => "disconnected",
        RuntimeSessionState::Failed => "failed",
        _ => unreachable!("non-terminal session state passed to terminal summary"),
    };
    let mut summary = match session.effective_established_readiness() {
        Some(readiness) => format!("{phase} after {}", describe_readiness(readiness)),
        None => format!("{phase} before transport became ready"),
    };
    if let Some(reason) = session
        .last_transport_error
        .as_deref()
        .or(session.last_error.as_deref())
    {
        summary.push_str(&format!(" (reason={reason})"));
    }
    Some(summary)
}

fn describe_keepalive_brief(keepalive: &RuntimeSessionKeepaliveStatus) -> String {
    let mut summary = format!(
        "hb {}/{} ping {} pong {} replied {}",
        keepalive.heartbeat_sent_count,
        keepalive.heartbeat_received_count,
        keepalive.ping_sent_count,
        keepalive.pong_received_count,
        keepalive.pong_replied_count,
    );
    if let Some(ping_id) = keepalive.last_ping_id {
        summary.push_str(&format!(" last_ping={ping_id}"));
    }
    if let Some(pong_id) = keepalive.last_pong_id {
        summary.push_str(&format!(" last_pong={pong_id}"));
    }
    if let Some(last_activity_at) = keepalive.last_activity_at {
        summary.push_str(&format!(" active={last_activity_at}"));
    }
    summary
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::Arc;
    use std::thread;

    #[test]
    fn generic_build_fingerprints_are_rejected() {
        assert!(is_generic_build_fingerprint("skybridge-signaling/1.0.0"));
        assert!(is_generic_build_fingerprint(
            "skybridge-signaling/1.0.0+unidentified-build"
        ));
        assert!(!is_generic_build_fingerprint(
            "skybridge-signaling/20260501164000-abcdef123456"
        ));
    }

    #[test]
    fn doctor_subcommands_parse_with_json_flags() {
        assert!(Cli::try_parse_from(["skybridge", "doctor", "--json"]).is_ok());
        assert!(Cli::try_parse_from(["skybridge", "doctor", "signaling", "--json"]).is_ok());
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "doctor",
                "media-lease",
                "--media-admission-token",
                "token",
                "--json",
            ])
            .is_ok()
        );
    }

    #[tokio::test]
    async fn signaling_doctor_mock_server_reports_media_surface() -> Result<()> {
        let base_url = spawn_mock_server(vec![
            (
                "GET",
                "/",
                200,
                json!({
                    "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                    "stateBackend": "redis",
                    "supportsMediaAdmissionRefresh": true,
                    "endpoints": ["/api/media/lease", "/api/media/admission/refresh"]
                }),
            ),
            (
                "GET",
                "/health",
                200,
                json!({
                    "status": "ok",
                    "ready": true,
                    "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                    "stateBackend": "redis",
                    "supportsMediaAdmissionRefresh": true
                }),
            ),
            (
                "GET",
                "/readyz",
                200,
                json!({
                    "status": "ready",
                    "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                    "stateBackend": "redis",
                    "supportsMediaAdmissionRefresh": true
                }),
            ),
            (
                "GET",
                "/api/turn/credentials",
                401,
                json!({
                    "error": "missing_turn_admission",
                    "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456"
                }),
            ),
            (
                "POST",
                "/api/media/lease",
                401,
                json!({
                    "error": "missing_media_admission",
                    "rejectReason": "missingToken",
                    "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456"
                }),
            ),
        ])?;

        let report = build_signaling_doctor_report(Some(base_url), Some("redis")).await?;

        assert!(report.checks.iter().all(|check| check.ok));
        assert!(
            report
                .checks
                .iter()
                .any(|check| check.name == "media_diagnostics_supported")
        );
        Ok(())
    }

    #[tokio::test]
    async fn media_lease_doctor_reports_reject_reason_fields() -> Result<()> {
        let base_url = spawn_mock_server(vec![
            (
                "GET",
                "/health",
                200,
                json!({
                    "status": "ok",
                    "ready": true,
                    "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                    "stateBackend": "redis",
                    "supportsMediaAdmissionRefresh": true
                }),
            ),
            (
                "POST",
                "/api/media/lease",
                401,
                json!({
                    "error": "media_admission_token_superseded",
                    "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                    "mediaTokenState": "revoked",
                    "mediaTokenRevokedReason": "remote_kill",
                    "mediaTokenSessionRejectReason": "remote_kill",
                    "rejectReason": "remote_kill"
                }),
            ),
        ])?;

        let report = build_media_lease_doctor_report(
            Some(base_url),
            Some("SESSION1".to_owned()),
            Some("token".to_owned()),
        )
        .await?;

        let success = report
            .checks
            .iter()
            .find(|check| check.name == "media_lease_success")
            .expect("media lease success check missing");
        assert!(!success.ok);

        let diagnostics = report
            .checks
            .iter()
            .find(|check| check.name == "media_lease_diagnostics")
            .expect("media diagnostics check missing");
        assert!(diagnostics.ok);
        assert_eq!(diagnostics.reject_reason.as_deref(), Some("remote_kill"));
        Ok(())
    }

    fn spawn_mock_server(
        routes: Vec<(&'static str, &'static str, u16, serde_json::Value)>,
    ) -> Result<String> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let address = listener.local_addr()?;
        let routes = Arc::new(routes);
        thread::spawn(move || {
            for stream in listener.incoming().take(16) {
                let Ok(mut stream) = stream else { continue };
                let mut buffer = [0_u8; 4096];
                let bytes_read = stream.read(&mut buffer).unwrap_or(0);
                let request = String::from_utf8_lossy(&buffer[..bytes_read]);
                let mut first_line = request.lines().next().unwrap_or("").split_whitespace();
                let method = first_line.next().unwrap_or("");
                let path = first_line.next().unwrap_or("");
                let route = routes.iter().find(|(route_method, route_path, _, _)| {
                    *route_method == method && *route_path == path
                });
                let (status, body) = route
                    .map(|(_, _, status, body)| (*status, body.clone()))
                    .unwrap_or_else(|| (404, json!({ "error": "not_found" })));
                let reason = if status == 200 { "OK" } else { "ERROR" };
                let body = body.to_string();
                let response = format!(
                    "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes());
            }
        });
        Ok(format!("http://{address}"))
    }
}
