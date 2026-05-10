use std::cmp::Ordering;
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use clap::{Args, Parser, Subcommand, ValueEnum};
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
const WEBRTC_AUDIO_SCHEDULE_LEAD_HARD_MIN_MS: f64 = -40.0;
const WEBRTC_AUDIO_ARRIVAL_P95_PRESSURE_MS: f64 = 150.0;
const WEBRTC_AUDIO_ARRIVAL_MAX_SPIKE_MS: f64 = 500.0;
const WEBRTC_AUDIO_PLC_FRAME_PRESSURE_MIN: u64 = 3;
const WEBRTC_AUDIO_PLC_RATIO_PRESSURE: f64 = 0.01;
const WEBRTC_AUDIO_PLC_BURST_FRAME_PRESSURE_MIN: u64 = 8;
const WEBRTC_AUDIO_PLC_BURST_RATIO_PRESSURE: f64 = 0.03;

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
    Diagnose(DiagnoseCommand),
    Doctor(DoctorCommand),
    Smoke(SmokeCommand),
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

#[derive(Debug, Args)]
struct SmokeCommand {
    #[command(subcommand)]
    command: SmokeSubcommand,
}

#[derive(Debug, Subcommand)]
enum SmokeSubcommand {
    #[command(name = "webrtc")]
    WebRtc(WebRtcSmokeCommand),
    #[command(name = "local-webrtc")]
    LocalWebrtc(SmokeSuiteCommonArgs),
    #[command(name = "local-p2p")]
    LocalP2p(SmokeLocalP2pArgs),
    #[command(name = "real-device")]
    RealDevice(SmokeSuiteCommonArgs),
    Suite(SmokeSuiteArgs),
    All(SmokeAllArgs),
    Faults(SmokeFaultsArgs),
    #[command(name = "fault-detection")]
    FaultDetection(SmokeFaultsArgs),
}

#[derive(Debug, Args)]
struct WebRtcSmokeCommand {
    #[command(subcommand)]
    command: WebRtcSmokeSubcommand,
}

#[derive(Debug, Subcommand)]
enum WebRtcSmokeSubcommand {
    Gate(WebRtcSmokeGateArgs),
}

#[derive(Debug, Args)]
struct SmokeSuiteArgs {
    #[arg(long, value_enum, default_value = "quick")]
    profile: SmokeSuiteProfile,
    #[command(flatten)]
    common: SmokeSuiteCommonArgs,
}

#[derive(Debug, Args)]
struct SmokeAllArgs {
    #[command(flatten)]
    common: SmokeSuiteCommonArgs,
}

#[derive(Debug, Args)]
struct SmokeSuiteCommonArgs {
    #[arg(long)]
    dry_run: bool,
    #[arg(long)]
    skip_real_device: bool,
    #[arg(long, env = "SKYBRIDGE_REAL_DEVICE_ID")]
    real_device_id: Option<String>,
    #[arg(long, env = "SKYBRIDGE_SMOKE_AUTH_SESSION_FILE")]
    auth_session_file: Option<PathBuf>,
    #[arg(long, default_value_t = 30.0)]
    min_fps: f64,
    #[arg(long, env = "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS")]
    timeout_seconds: Option<u64>,
    #[arg(long, env = "SKYBRIDGE_SMOKE_SOAK_SECONDS", default_value_t = 0)]
    soak_seconds: u64,
    #[arg(long, env = "SKYBRIDGE_SMOKE_VIDEO_WIDTH", default_value_t = 2056)]
    video_width: u32,
    #[arg(long, env = "SKYBRIDGE_SMOKE_VIDEO_HEIGHT", default_value_t = 1329)]
    video_height: u32,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Args)]
struct SmokeFaultsArgs {
    #[arg(long)]
    dry_run: bool,
    #[arg(long)]
    iterations: Option<u32>,
    #[arg(long)]
    timeout_ms: Option<u32>,
    #[arg(long)]
    delay_ms: Option<u32>,
    #[arg(long)]
    progress_interval: Option<u32>,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Args)]
struct SmokeLocalP2pArgs {
    #[arg(long)]
    dry_run: bool,
    #[arg(long, value_enum, default_value = "bootstrap-rekey")]
    scenario: LocalP2pSmokeScenario,
    #[arg(long, env = "SKYBRIDGE_SMOKE_ROUNDS")]
    rounds: Option<u32>,
    #[arg(long, env = "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS")]
    timeout_seconds: Option<u64>,
    #[arg(long, env = "SKYBRIDGE_SMOKE_IOS_DEVICE_ID")]
    ios_device_id: Option<String>,
    #[arg(long, env = "SKYBRIDGE_SMOKE_MAC_TARGET_NAME")]
    target_name: Option<String>,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, ValueEnum)]
#[serde(rename_all = "kebab-case")]
enum LocalP2pSmokeScenario {
    BootstrapRekey,
    XwingOnly,
    CompatPurePqc,
}

impl Default for LocalP2pSmokeScenario {
    fn default() -> Self {
        Self::BootstrapRekey
    }
}

impl LocalP2pSmokeScenario {
    fn as_env_value(self) -> &'static str {
        match self {
            Self::BootstrapRekey => "bootstrap-rekey",
            Self::XwingOnly => "xwing-only",
            Self::CompatPurePqc => "compat-pure-pqc",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, ValueEnum)]
#[serde(rename_all = "kebab-case")]
enum SmokeSuiteProfile {
    Quick,
    Full,
    ScriptTests,
    IosConfig,
    LocalWebrtc,
    LocalP2p,
    FaultInjection,
    Benchmarks,
    Release,
    RealDevice,
    All,
}

#[derive(Debug, Subcommand)]
enum DoctorSubcommand {
    Signaling(SignalingDoctorArgs),
    MediaLease(MediaLeaseDoctorArgs),
    #[command(name = "webrtc-media")]
    WebRtcMedia(WebRtcMediaDoctorArgs),
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
struct WebRtcMediaDoctorArgs {
    #[arg(long)]
    session_id: Option<String>,
    #[arg(long)]
    latest: bool,
    #[arg(long)]
    artifact_dir: Option<PathBuf>,
    #[arg(long)]
    log_file: Option<PathBuf>,
    #[arg(long, default_value_t = 120)]
    since_seconds: u64,
    #[arg(long, default_value_t = 20.0)]
    min_fps: f64,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    require_audio: bool,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Args)]
struct WebRtcSmokeGateArgs {
    #[arg(long)]
    session_id: Option<String>,
    #[arg(long)]
    latest: bool,
    #[arg(long)]
    artifact_dir: Option<PathBuf>,
    #[arg(long)]
    log_file: Option<PathBuf>,
    #[arg(long, default_value_t = 120)]
    since_seconds: u64,
    #[arg(long, default_value_t = 30.0)]
    min_fps: f64,
    #[arg(long, default_value_t = 0)]
    min_width: u32,
    #[arg(long, default_value_t = 0)]
    min_height: u32,
    #[arg(long)]
    exact_video_size: bool,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    require_audio: bool,
    #[arg(long, default_value_t = 240)]
    timeout_seconds: u64,
    #[arg(long, default_value_t = 0)]
    min_pass_seconds: u64,
    #[arg(long, default_value_t = 2)]
    poll_interval_seconds: u64,
    #[command(flatten)]
    output: OutputOptions,
}

#[derive(Debug, Args)]
struct DiagnoseCommand {
    #[command(subcommand)]
    command: DiagnoseSubcommand,
}

#[derive(Debug, Subcommand)]
enum DiagnoseSubcommand {
    #[command(name = "webrtc-media")]
    WebRtcMedia(WebRtcMediaDiagnoseArgs),
}

#[derive(Debug, Args)]
struct WebRtcMediaDiagnoseArgs {
    #[arg(long)]
    session_id: Option<String>,
    #[arg(long)]
    latest: bool,
    #[arg(long)]
    artifact_dir: Option<PathBuf>,
    #[arg(long)]
    log_file: Option<PathBuf>,
    #[arg(long, default_value_t = 120)]
    since_seconds: u64,
    #[arg(long, default_value_t = 20.0)]
    min_fps: f64,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    require_audio: bool,
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
    Current(CodeCurrentArgs),
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
struct CodeCurrentArgs {
    #[arg(long)]
    snapshot: Option<PathBuf>,
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
            CodeSubcommand::Current(args) => code_current(args).await,
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
        Commands::Diagnose(args) => match args.command {
            DiagnoseSubcommand::WebRtcMedia(webrtc_media) => {
                diagnose_webrtc_media(webrtc_media).await
            }
        },
        Commands::Doctor(args) => match args.command {
            Some(DoctorSubcommand::Signaling(signaling)) => doctor_signaling(signaling).await,
            Some(DoctorSubcommand::MediaLease(media_lease)) => {
                doctor_media_lease(media_lease).await
            }
            Some(DoctorSubcommand::WebRtcMedia(webrtc_media)) => {
                doctor_webrtc_media(webrtc_media).await
            }
            None => doctor(cli.state_dir, args.output.json).await,
        },
        Commands::Smoke(smoke) => match smoke.command {
            SmokeSubcommand::WebRtc(webrtc) => match webrtc.command {
                WebRtcSmokeSubcommand::Gate(args) => smoke_webrtc_gate(args).await,
            },
            SmokeSubcommand::LocalWebrtc(common) => {
                smoke_suite(SmokeSuiteArgs {
                    profile: SmokeSuiteProfile::LocalWebrtc,
                    common,
                })
                .await
            }
            SmokeSubcommand::LocalP2p(args) => smoke_local_p2p(args).await,
            SmokeSubcommand::RealDevice(common) => {
                smoke_suite(SmokeSuiteArgs {
                    profile: SmokeSuiteProfile::RealDevice,
                    common,
                })
                .await
            }
            SmokeSubcommand::Suite(args) => smoke_suite(args).await,
            SmokeSubcommand::All(args) => {
                smoke_suite(SmokeSuiteArgs {
                    profile: SmokeSuiteProfile::All,
                    common: args.common,
                })
                .await
            }
            SmokeSubcommand::Faults(args) => smoke_faults(args).await,
            SmokeSubcommand::FaultDetection(args) => smoke_faults(args).await,
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

#[derive(Debug, serde::Deserialize, Serialize)]
struct ConnectionCodeSnapshot {
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    code: String,
    #[serde(rename = "sessionId")]
    session_id: String,
    #[serde(rename = "expiresAt")]
    expires_at: Option<String>,
    #[serde(rename = "leaseMode")]
    lease_mode: Option<String>,
    #[serde(rename = "deviceId")]
    device_id: Option<String>,
    #[serde(rename = "protocolPublicKeyFingerprint")]
    protocol_public_key_fingerprint: Option<String>,
    #[serde(rename = "generatedAt")]
    generated_at: Option<String>,
}

async fn code_current(args: CodeCurrentArgs) -> Result<()> {
    let snapshot_path = args
        .snapshot
        .unwrap_or_else(default_connection_code_snapshot_path);
    let snapshot = read_connection_code_snapshot(&snapshot_path)?;
    if args.output.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "code": snapshot.code,
                "session_id": snapshot.session_id,
                "expires_at": snapshot.expires_at,
                "lease_mode": snapshot.lease_mode,
                "device_id": snapshot.device_id,
                "protocol_public_key_fingerprint": snapshot.protocol_public_key_fingerprint,
                "generated_at": snapshot.generated_at,
                "snapshot": snapshot_path,
            }))?
        );
    } else {
        println!("Code: {}", snapshot.code);
        println!("Session ID: {}", snapshot.session_id);
        if let Some(expires_at) = snapshot.expires_at {
            println!("Expires At: {}", expires_at);
        }
        println!("Snapshot: {}", snapshot_path.display());
    }
    Ok(())
}

fn default_connection_code_snapshot_path() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library")
        .join("Application Support")
        .join("SkyBridge")
        .join("connection-code-latest.json")
}

fn read_connection_code_snapshot(path: &Path) -> Result<ConnectionCodeSnapshot> {
    let data = fs::read_to_string(path).map_err(|error| {
        anyhow!(
            "connection code snapshot unavailable at {}: {}",
            path.display(),
            error
        )
    })?;
    let snapshot: ConnectionCodeSnapshot = serde_json::from_str(&data).map_err(|error| {
        anyhow!(
            "connection code snapshot is malformed at {}: {}",
            path.display(),
            error
        )
    })?;
    if snapshot.code.trim().is_empty() || snapshot.session_id.trim().is_empty() {
        bail!(
            "connection code snapshot at {} is incomplete",
            path.display()
        );
    }
    if let Some(expires_at) = snapshot.expires_at.as_deref() {
        let parsed =
            OffsetDateTime::parse(expires_at, &time::format_description::well_known::Rfc3339)
                .map_err(|error| {
                    anyhow!(
                        "connection code snapshot has invalid expires_at {}: {}",
                        expires_at,
                        error
                    )
                })?;
        if parsed <= OffsetDateTime::now_utc() {
            bail!("connection code snapshot at {} is expired", path.display());
        }
    }
    Ok(snapshot)
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
    #[serde(rename = "faultStage", skip_serializing_if = "Option::is_none")]
    fault_stage: Option<&'static str>,
    #[serde(skip)]
    latest_diagnostic_at: Option<OffsetDateTime>,
    #[serde(skip)]
    latest_video_evidence_at: Option<OffsetDateTime>,
    #[serde(skip)]
    latest_receiver_evidence_at: Option<OffsetDateTime>,
    #[serde(skip)]
    latest_audio_tx_evidence_at: Option<OffsetDateTime>,
    #[serde(skip)]
    latest_audio_rx_evidence_at: Option<OffsetDateTime>,
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

async fn doctor_webrtc_media(args: WebRtcMediaDoctorArgs) -> Result<()> {
    let as_json = args.output.json;
    let session_id = resolve_webrtc_media_session_arg(
        args.session_id.as_deref(),
        args.latest,
        args.artifact_dir.as_deref(),
        args.log_file.as_deref(),
    )?;
    let report = build_webrtc_media_doctor_report(&args, &session_id)?;
    print_doctor_probe_report(&report, as_json)?;
    ensure_webrtc_media_doctor_passed(&report)
}

async fn diagnose_webrtc_media(args: WebRtcMediaDiagnoseArgs) -> Result<()> {
    let as_json = args.output.json;
    let session_id = resolve_webrtc_media_session_arg(
        args.session_id.as_deref(),
        args.latest,
        args.artifact_dir.as_deref(),
        args.log_file.as_deref(),
    )?;
    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some(session_id.clone()),
            latest: false,
            artifact_dir: args.artifact_dir,
            log_file: args.log_file,
            since_seconds: args.since_seconds,
            min_fps: args.min_fps,
            require_audio: args.require_audio,
            output: OutputOptions { json: as_json },
        },
        &session_id,
    )?;
    print_doctor_probe_report(&report, as_json)
}

async fn smoke_webrtc_gate(args: WebRtcSmokeGateArgs) -> Result<()> {
    if args.timeout_seconds == 0 {
        bail!("--timeout-seconds must be greater than zero");
    }
    if args.min_pass_seconds >= args.timeout_seconds {
        bail!("--min-pass-seconds must be smaller than --timeout-seconds");
    }
    if args.poll_interval_seconds == 0 {
        bail!("--poll-interval-seconds must be greater than zero");
    }
    if !args.min_fps.is_finite() || args.min_fps <= 0.0 {
        bail!("--min-fps must be a positive finite number");
    }
    if (args.min_width == 0) != (args.min_height == 0) {
        bail!("pass both --min-width and --min-height, or neither");
    }
    if args.exact_video_size && (args.min_width == 0 || args.min_height == 0) {
        bail!("--exact-video-size requires --min-width and --min-height");
    }

    let session_id = resolve_webrtc_media_session_arg(
        args.session_id.as_deref(),
        args.latest,
        args.artifact_dir.as_deref(),
        args.log_file.as_deref(),
    )?;
    let started = Instant::now();
    let timeout = Duration::from_secs(args.timeout_seconds);
    let min_pass_duration = Duration::from_secs(args.min_pass_seconds);
    let poll_interval = Duration::from_secs(args.poll_interval_seconds);
    let fresh_sample_max_age = time::Duration::seconds(
        i64::try_from((args.poll_interval_seconds.saturating_mul(3)).max(10)).unwrap_or(i64::MAX),
    );
    let mut passing_since: Option<Instant> = None;
    let mut pass_window_start_at: Option<OffsetDateTime> = None;

    loop {
        let require_receiver = args.min_width > 0 && args.min_height > 0;
        let gate_since_seconds = if min_pass_duration.is_zero() || pass_window_start_at.is_some() {
            args.since_seconds
        } else {
            (args.poll_interval_seconds.saturating_mul(3)).max(10)
        };
        let doctor_args = WebRtcMediaDoctorArgs {
            session_id: Some(session_id.clone()),
            latest: false,
            artifact_dir: args.artifact_dir.clone(),
            log_file: args.log_file.clone(),
            since_seconds: gate_since_seconds,
            min_fps: args.min_fps,
            require_audio: args.require_audio,
            output: OutputOptions {
                json: args.output.json,
            },
        };
        let report = build_webrtc_media_doctor_report_for_gate(
            &doctor_args,
            &session_id,
            args.min_width,
            args.min_height,
            args.exact_video_size,
            webrtc_smoke_gate_strict_fps_floor(args.min_fps, args.min_pass_seconds),
            pass_window_start_at,
        )?;
        if ensure_webrtc_media_doctor_passed(&report).is_ok() {
            if min_pass_duration.is_zero() {
                print_doctor_probe_report(&report, args.output.json)?;
                return Ok(());
            }
            if !webrtc_smoke_gate_report_is_fresh(
                &report,
                fresh_sample_max_age,
                args.require_audio,
                require_receiver,
            ) {
                passing_since = None;
                pass_window_start_at = None;
            } else {
                if passing_since.is_none() {
                    if let Some(window_start) = webrtc_smoke_gate_required_evidence_floor(
                        &report,
                        args.require_audio,
                        require_receiver,
                    ) {
                        passing_since = Some(Instant::now());
                        pass_window_start_at = Some(window_start);
                    } else {
                        passing_since = None;
                        pass_window_start_at = None;
                    }
                }
                let wall_window_satisfied = passing_since
                    .is_some_and(|first_passing| first_passing.elapsed() >= min_pass_duration);
                let evidence_window_satisfied = pass_window_start_at.is_some_and(|window_start| {
                    webrtc_smoke_gate_pass_window_satisfied(
                        &report,
                        window_start,
                        min_pass_duration,
                        args.require_audio,
                        require_receiver,
                    )
                });
                if wall_window_satisfied || evidence_window_satisfied {
                    print_doctor_probe_report(&report, args.output.json)?;
                    return Ok(());
                }
            }
        } else {
            passing_since = None;
            pass_window_start_at = None;
        }
        if webrtc_smoke_gate_terminal_failure(&report) {
            print_doctor_probe_report(&report, args.output.json)?;
            ensure_webrtc_media_doctor_passed(&report)?;
            return Ok(());
        }

        if started.elapsed() >= timeout {
            print_doctor_probe_report(&report, args.output.json)?;
            bail!(
                "WebRTC media smoke gate timed out after {}s for session {session_id} (min_fps={:.2}, require_audio={}, min_pass_seconds={})",
                args.timeout_seconds,
                args.min_fps,
                args.require_audio,
                args.min_pass_seconds
            );
        }

        let remaining = timeout.saturating_sub(started.elapsed());
        tokio::time::sleep(poll_interval.min(remaining)).await;
    }
}

fn webrtc_smoke_gate_strict_fps_floor(min_fps: f64, min_pass_seconds: u64) -> bool {
    min_pass_seconds > 0 || min_fps >= 59.0
}

fn webrtc_smoke_gate_report_is_fresh(
    report: &DoctorProbeReport,
    max_age: time::Duration,
    require_audio: bool,
    require_receiver: bool,
) -> bool {
    let now = OffsetDateTime::now_utc();
    if !webrtc_smoke_gate_time_is_fresh(report.latest_diagnostic_at, now, max_age)
        || !webrtc_smoke_gate_time_is_fresh(report.latest_video_evidence_at, now, max_age)
    {
        return false;
    }
    if require_receiver
        && !webrtc_smoke_gate_time_is_fresh(report.latest_receiver_evidence_at, now, max_age)
    {
        return false;
    }
    if require_audio {
        webrtc_smoke_gate_time_is_fresh(report.latest_audio_tx_evidence_at, now, max_age)
            && webrtc_smoke_gate_time_is_fresh(report.latest_audio_rx_evidence_at, now, max_age)
    } else {
        true
    }
}

fn webrtc_smoke_gate_time_is_fresh(
    observed_at: Option<OffsetDateTime>,
    now: OffsetDateTime,
    max_age: time::Duration,
) -> bool {
    observed_at.is_some_and(|latest| latest <= now && now - latest <= max_age)
}

fn webrtc_smoke_gate_required_evidence_floor(
    report: &DoctorProbeReport,
    require_audio: bool,
    require_receiver: bool,
) -> Option<OffsetDateTime> {
    let mut times = vec![report.latest_video_evidence_at?];
    if require_receiver {
        times.push(report.latest_receiver_evidence_at?);
    }
    if require_audio {
        times.push(report.latest_audio_tx_evidence_at?);
        times.push(report.latest_audio_rx_evidence_at?);
    }
    times.into_iter().min()
}

fn webrtc_smoke_gate_pass_window_satisfied(
    report: &DoctorProbeReport,
    window_start: OffsetDateTime,
    min_pass_duration: Duration,
    require_audio: bool,
    require_receiver: bool,
) -> bool {
    if min_pass_duration.is_zero() {
        return true;
    }
    let Some(evidence_floor) =
        webrtc_smoke_gate_required_evidence_floor(report, require_audio, require_receiver)
    else {
        return false;
    };
    if evidence_floor < window_start {
        return false;
    }
    let Ok(required_seconds) = i64::try_from(min_pass_duration.as_secs()) else {
        return false;
    };
    evidence_floor - window_start >= time::Duration::seconds(required_seconds)
}

fn webrtc_smoke_gate_terminal_failure(report: &DoctorProbeReport) -> bool {
    if matches!(
        report.fault_stage,
        Some(
            "strict_media_failure"
                | "fallback_backpressure"
                | "fallback_capture_stalled"
                | "sck_capture_stalled"
                | "vt_encode_stalled"
                | "vt_encode_slow"
                | "native_video_rtp_stalled"
        )
    ) {
        return true;
    }

    report.checks.iter().any(|check| {
        !check.ok
            && matches!(
                check.name,
                "strict_media_failure" | "stale_fallback" | "backpressure" | "audio_relay_startup"
            )
    })
}

async fn smoke_suite(args: SmokeSuiteArgs) -> Result<()> {
    if !args.common.min_fps.is_finite() || args.common.min_fps <= 0.0 {
        bail!("--min-fps must be a positive finite number");
    }
    if matches!(args.common.timeout_seconds, Some(0)) {
        bail!("--timeout-seconds must be greater than zero");
    }
    if let Some(timeout_seconds) = args.common.timeout_seconds {
        if args.common.soak_seconds >= timeout_seconds {
            bail!("--soak-seconds must be smaller than --timeout-seconds");
        }
    }
    let timeout_seconds = args
        .common
        .timeout_seconds
        .or_else(|| (args.common.soak_seconds > 0).then_some(args.common.soak_seconds + 240));
    if args.common.video_width == 0 || args.common.video_height == 0 {
        bail!("--video-width and --video-height must be greater than zero");
    }
    if args.profile == SmokeSuiteProfile::RealDevice && args.common.skip_real_device {
        bail!("--skip-real-device is not valid with --profile real-device");
    }

    let root = resolve_repo_root()?;
    let steps = build_smoke_suite_steps(
        &root,
        args.profile,
        args.common.skip_real_device,
        args.common.real_device_id.as_deref(),
        args.common.auth_session_file.as_deref(),
        args.common.min_fps,
        timeout_seconds,
        args.common.soak_seconds,
        args.common.video_width,
        args.common.video_height,
    )?;
    run_smoke_suite_plan(
        &root,
        args.profile,
        args.common.dry_run,
        args.common.output.json,
        steps,
    )
}

async fn smoke_faults(args: SmokeFaultsArgs) -> Result<()> {
    let root = resolve_repo_root()?;
    let mut steps = Vec::new();
    push_fault_injection_steps(
        &root,
        &mut steps,
        SmokeFaultOptions {
            iterations: args.iterations,
            timeout_ms: args.timeout_ms,
            delay_ms: args.delay_ms,
            progress_interval: args.progress_interval,
        },
    );
    run_smoke_suite_plan(
        &root,
        SmokeSuiteProfile::FaultInjection,
        args.dry_run,
        args.output.json,
        steps,
    )
}

async fn smoke_local_p2p(args: SmokeLocalP2pArgs) -> Result<()> {
    if matches!(args.rounds, Some(0)) {
        bail!("--rounds must be greater than zero");
    }
    if matches!(args.timeout_seconds, Some(0)) {
        bail!("--timeout-seconds must be greater than zero");
    }
    let root = resolve_repo_root()?;
    let mut steps = Vec::new();
    push_local_p2p_smoke_steps(
        &root,
        &mut steps,
        SmokeLocalP2pOptions {
            scenario: args.scenario,
            rounds: args.rounds,
            timeout_seconds: args.timeout_seconds,
            ios_device_id: args.ios_device_id,
            target_name: args.target_name,
        },
    );
    run_smoke_suite_plan(
        &root,
        SmokeSuiteProfile::LocalP2p,
        args.dry_run,
        args.output.json,
        steps,
    )
}

#[derive(Debug, Clone)]
struct SmokeSuiteStepSpec {
    name: &'static str,
    description: &'static str,
    program: String,
    args: Vec<String>,
    env: Vec<(String, String)>,
    cwd: PathBuf,
}

#[derive(Debug, Clone, Copy, Default)]
struct SmokeFaultOptions {
    iterations: Option<u32>,
    timeout_ms: Option<u32>,
    delay_ms: Option<u32>,
    progress_interval: Option<u32>,
}

#[derive(Debug, Clone, Default)]
struct SmokeLocalP2pOptions {
    scenario: LocalP2pSmokeScenario,
    rounds: Option<u32>,
    timeout_seconds: Option<u64>,
    ios_device_id: Option<String>,
    target_name: Option<String>,
}

#[derive(Debug, Serialize)]
struct SmokeSuiteEnvJson {
    name: String,
    value: String,
}

#[derive(Debug, Serialize)]
struct SmokeSuiteStepJson {
    name: String,
    description: String,
    command: Vec<String>,
    env: Vec<SmokeSuiteEnvJson>,
    cwd: String,
}

#[derive(Debug, Serialize)]
struct SmokeSuiteOutcomeJson {
    name: String,
    description: String,
    command: Vec<String>,
    env: Vec<SmokeSuiteEnvJson>,
    cwd: String,
    success: bool,
    exit_code: Option<i32>,
    duration_ms: u128,
    stdout_tail: Option<String>,
    stderr_tail: Option<String>,
}

#[derive(Debug, Serialize)]
struct SmokeSuiteReportJson {
    schema_version: u8,
    profile: SmokeSuiteProfile,
    dry_run: bool,
    root: String,
    steps: Vec<SmokeSuiteStepJson>,
    outcomes: Vec<SmokeSuiteOutcomeJson>,
}

impl SmokeSuiteStepSpec {
    fn command_vector(&self) -> Vec<String> {
        let mut command = Vec::with_capacity(1 + self.args.len());
        command.push(self.program.clone());
        command.extend(self.args.iter().cloned());
        command
    }

    fn to_json(&self) -> SmokeSuiteStepJson {
        SmokeSuiteStepJson {
            name: self.name.to_owned(),
            description: self.description.to_owned(),
            command: self.command_vector(),
            env: self
                .env
                .iter()
                .map(|(name, value)| SmokeSuiteEnvJson {
                    name: name.clone(),
                    value: value.clone(),
                })
                .collect(),
            cwd: self.cwd.display().to_string(),
        }
    }
}

fn resolve_repo_root() -> Result<PathBuf> {
    let mut current = std::env::current_dir()?;
    loop {
        if current.join("Scripts").is_dir()
            && current.join("rust").join("Cargo.toml").is_file()
            && current.join("Package.swift").is_file()
        {
            return Ok(current);
        }

        if !current.pop() {
            break;
        }
    }

    bail!("Could not locate SkyBridge repository root from current directory")
}

fn build_smoke_suite_steps(
    root: &Path,
    profile: SmokeSuiteProfile,
    skip_real_device: bool,
    real_device_id: Option<&str>,
    auth_session_file: Option<&Path>,
    min_fps: f64,
    timeout_seconds: Option<u64>,
    soak_seconds: u64,
    video_width: u32,
    video_height: u32,
) -> Result<Vec<SmokeSuiteStepSpec>> {
    let mut steps = Vec::new();
    match profile {
        SmokeSuiteProfile::Quick => push_quick_smoke_steps(root, &mut steps),
        SmokeSuiteProfile::Full => push_full_smoke_steps(root, &mut steps),
        SmokeSuiteProfile::ScriptTests => push_script_test_steps(root, &mut steps),
        SmokeSuiteProfile::IosConfig => push_ios_config_steps(root, &mut steps),
        SmokeSuiteProfile::LocalWebrtc => push_local_webrtc_smoke_steps(root, &mut steps, min_fps),
        SmokeSuiteProfile::LocalP2p => {
            push_local_p2p_smoke_steps(root, &mut steps, SmokeLocalP2pOptions::default())
        }
        SmokeSuiteProfile::FaultInjection => {
            push_fault_injection_steps(root, &mut steps, SmokeFaultOptions::default())
        }
        SmokeSuiteProfile::Benchmarks => push_benchmark_steps(root, &mut steps),
        SmokeSuiteProfile::Release => push_release_smoke_steps(root, &mut steps),
        SmokeSuiteProfile::RealDevice => push_real_device_smoke_steps(
            root,
            &mut steps,
            real_device_id,
            auth_session_file,
            min_fps,
            timeout_seconds,
            soak_seconds,
            video_width,
            video_height,
        ),
        SmokeSuiteProfile::All => {
            push_full_smoke_steps(root, &mut steps);
            push_script_test_steps(root, &mut steps);
            push_ios_config_steps(root, &mut steps);
            push_local_p2p_smoke_steps(root, &mut steps, SmokeLocalP2pOptions::default());
            push_local_webrtc_smoke_steps(root, &mut steps, min_fps);
            push_fault_injection_steps(root, &mut steps, SmokeFaultOptions::default());
            push_benchmark_steps(root, &mut steps);
            push_release_smoke_steps(root, &mut steps);
            if !skip_real_device {
                push_real_device_smoke_steps(
                    root,
                    &mut steps,
                    real_device_id,
                    auth_session_file,
                    min_fps,
                    timeout_seconds,
                    soak_seconds,
                    video_width,
                    video_height,
                );
            }
        }
    }
    Ok(steps)
}

fn push_quick_smoke_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    steps.push(SmokeSuiteStepSpec {
        name: "rust_webrtc_cli_tests",
        description: "Rust CLI WebRTC doctor and smoke gate tests",
        program: "cargo".to_owned(),
        args: vec![
            "test".to_owned(),
            "--manifest-path".to_owned(),
            "rust/Cargo.toml".to_owned(),
            "-p".to_owned(),
            "skybridge".to_owned(),
            "webrtc".to_owned(),
        ],
        env: vec![],
        cwd: root.to_path_buf(),
    });
    steps.push(SmokeSuiteStepSpec {
        name: "swift_webrtc_policy_tests",
        description: "Swift WebRTC realtime media and stream start policy tests",
        program: "swift".to_owned(),
        args: vec![
            "test".to_owned(),
            "--filter".to_owned(),
            "SkyBridgeRealtimeMediaTests|CrossNetworkWebRTCStreamStartPolicyTests".to_owned(),
        ],
        env: swift_test_cache_env(root),
        cwd: root.to_path_buf(),
    });
    push_signaling_server_step(root, steps);
}

fn push_full_smoke_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    steps.push(SmokeSuiteStepSpec {
        name: "rust_workspace_tests",
        description: "Rust workspace test suite",
        program: "cargo".to_owned(),
        args: vec![
            "test".to_owned(),
            "--manifest-path".to_owned(),
            "rust/Cargo.toml".to_owned(),
            "--workspace".to_owned(),
        ],
        env: vec![],
        cwd: root.to_path_buf(),
    });
    steps.push(SmokeSuiteStepSpec {
        name: "swift_package_tests",
        description: "Swift package test suite",
        program: "swift".to_owned(),
        args: vec!["test".to_owned()],
        env: swift_test_cache_env(root),
        cwd: root.to_path_buf(),
    });
    push_signaling_server_step(root, steps);
}

fn push_signaling_server_step(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    steps.push(SmokeSuiteStepSpec {
        name: "signaling_server_tests",
        description: "Node signaling and media relay tests",
        program: "npm".to_owned(),
        args: vec!["test".to_owned()],
        env: vec![],
        cwd: root.join("Server").join("skybridge-signaling"),
    });
}

fn push_script_test_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    for (name, description, script) in [
        (
            "xcodebuild_helper_tests",
            "macOS xcodebuild helper shell tests",
            "Scripts/test_xcodebuild_helpers.sh",
        ),
        (
            "package_build_policy_tests",
            "release package build-policy shell tests",
            "Scripts/test_package_build_policy.sh",
        ),
        (
            "signing_entitlements_helper_tests",
            "signing entitlement helper shell tests",
            "Scripts/test_signing_entitlements_helpers.sh",
        ),
        (
            "ios_test_configuration_script_tests",
            "iOS test configuration guard fixture tests",
            "Scripts/test_check_ios_test_configuration.sh",
        ),
    ] {
        steps.push(SmokeSuiteStepSpec {
            name,
            description,
            program: "bash".to_owned(),
            args: vec![script.to_owned()],
            env: vec![],
            cwd: root.to_path_buf(),
        });
    }
}

fn push_ios_config_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    steps.push(SmokeSuiteStepSpec {
        name: "ios_test_configuration_static_gate",
        description: "Static iOS Xcode test target and scheme configuration gate",
        program: "bash".to_owned(),
        args: vec![
            "Scripts/check_ios_test_configuration.sh".to_owned(),
            "--static-only".to_owned(),
        ],
        env: vec![],
        cwd: root.to_path_buf(),
    });
}

fn push_local_webrtc_smoke_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>, min_fps: f64) {
    steps.push(SmokeSuiteStepSpec {
        name: "local_webrtc_smoke",
        description: "Local simulator WebRTC bootstrap smoke with Rust media doctor gate",
        program: "bash".to_owned(),
        args: vec!["Scripts/run_local_webrtc_smoke.sh".to_owned()],
        env: vec![(
            "SKYBRIDGE_SMOKE_MIN_FPS".to_owned(),
            format!("{min_fps:.2}"),
        )],
        cwd: root.to_path_buf(),
    });
}

fn push_local_p2p_smoke_steps(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    options: SmokeLocalP2pOptions,
) {
    let mut env = vec![(
        "SKYBRIDGE_SMOKE_SCENARIO".to_owned(),
        options.scenario.as_env_value().to_owned(),
    )];
    if let Some(rounds) = options.rounds {
        env.push(("SKYBRIDGE_SMOKE_ROUNDS".to_owned(), rounds.to_string()));
    }
    if let Some(timeout_seconds) = options.timeout_seconds {
        env.push((
            "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS".to_owned(),
            timeout_seconds.to_string(),
        ));
    }
    if let Some(ios_device_id) = options.ios_device_id {
        env.push(("SKYBRIDGE_SMOKE_IOS_DEVICE_ID".to_owned(), ios_device_id));
    }
    if let Some(target_name) = options.target_name {
        env.push(("SKYBRIDGE_SMOKE_MAC_TARGET_NAME".to_owned(), target_name));
    }
    steps.push(SmokeSuiteStepSpec {
        name: "local_p2p_smoke",
        description: "Local simulator P2P bootstrap and PQC rekey smoke",
        program: "bash".to_owned(),
        args: vec!["Scripts/run_local_p2p_smoke.sh".to_owned()],
        env,
        cwd: root.to_path_buf(),
    });
}

fn push_fault_injection_steps(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    options: SmokeFaultOptions,
) {
    let mut env = swift_test_cache_env(root);
    env.push(("SKYBRIDGE_RUN_FI".to_owned(), "1".to_owned()));
    if let Some(iterations) = options.iterations {
        env.push(("SKYBRIDGE_FI_ITERATIONS".to_owned(), iterations.to_string()));
    }
    if let Some(timeout_ms) = options.timeout_ms {
        env.push(("SKYBRIDGE_FI_TIMEOUT_MS".to_owned(), timeout_ms.to_string()));
    }
    if let Some(delay_ms) = options.delay_ms {
        env.push(("SKYBRIDGE_FI_DELAY_MS".to_owned(), delay_ms.to_string()));
    }
    if let Some(progress_interval) = options.progress_interval {
        env.push((
            "SKYBRIDGE_FI_PROGRESS_INTERVAL".to_owned(),
            progress_interval.to_string(),
        ));
    }
    steps.push(SmokeSuiteStepSpec {
        name: "handshake_fault_injection",
        description: "Swift handshake fault-injection suite",
        program: "swift".to_owned(),
        args: vec![
            "test".to_owned(),
            "--filter".to_owned(),
            "HandshakeFaultInjectionBenchTests".to_owned(),
        ],
        env,
        cwd: root.to_path_buf(),
    });
}

fn push_benchmark_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    push_swift_benchmark_step(
        root,
        steps,
        "swift_handshake_benchmarks",
        "Swift handshake and data-plane benchmark tests",
        &[("SKYBRIDGE_RUN_BENCH", "1")],
        "HandshakeBenchmarkTests|HandshakeDriverTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "policy_downgrade_benchmarks",
        "Swift policy downgrade benchmark tests",
        &[("SKYBRIDGE_RUN_POLICY_BENCH", "1")],
        "PolicyDowngradeBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "migration_coverage_benchmarks",
        "Swift migration coverage benchmark tests",
        &[("SKYBRIDGE_RUN_MIGRATION_BENCH", "1")],
        "MigrationCoverageBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "migration_harness_benchmarks",
        "Swift migration threat harness benchmark tests",
        &[("SKYBRIDGE_RUN_MIGRATION_HARNESS", "1")],
        "MigrationThreatHarnessBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "migration_provider_matrix_benchmarks",
        "Swift migration provider matrix benchmark tests",
        &[("SKYBRIDGE_RUN_MIGRATION_PROVIDER_MATRIX", "1")],
        "MigrationThreatProviderMatrixBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "migration_fleet_behavior_benchmarks",
        "Swift migration fleet behavior benchmark tests",
        &[("SKYBRIDGE_RUN_MIGRATION_FLEET_BENCH", "1")],
        "MigrationFleetBehaviorBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "soa_interoperability_benchmarks",
        "Swift SOA interoperability benchmark tests",
        &[("SKYBRIDGE_RUN_SOA_BENCH", "1")],
        "SOAInteroperabilityBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "network_condition_benchmarks",
        "Swift network condition benchmark tests",
        &[("SKYBRIDGE_RUN_NETWORK_BENCH", "1")],
        "NetworkConditionBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "boundary_stress_benchmarks",
        "Swift boundary stress benchmark tests",
        &[("SKYBRIDGE_RUN_BOUNDARY_STRESS", "1")],
        "BoundaryStressBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "traffic_padding_benchmarks",
        "Swift traffic padding benchmark tests",
        &[("SKYBRIDGE_RUN_PADDING_BENCH", "1")],
        "TrafficPaddingBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "traffic_padding_sensitivity_benchmarks",
        "Swift traffic padding sensitivity benchmark tests",
        &[("SKYBRIDGE_RUN_PADDING_SENS", "1")],
        "TrafficPaddingSensitivityBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "system_impact_benchmarks",
        "Swift system impact benchmark tests",
        &[("SKYBRIDGE_RUN_SYSTEM_IMPACT", "1")],
        "SystemImpactBenchTests",
    );
}

fn push_swift_benchmark_step(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    name: &'static str,
    description: &'static str,
    benchmark_env: &[(&str, &str)],
    filter: &'static str,
) {
    let mut env = swift_test_cache_env(root);
    for (name, value) in benchmark_env {
        env.push(((*name).to_owned(), (*value).to_owned()));
    }
    steps.push(SmokeSuiteStepSpec {
        name,
        description,
        program: "swift".to_owned(),
        args: vec!["test".to_owned(), "--filter".to_owned(), filter.to_owned()],
        env,
        cwd: root.to_path_buf(),
    });
}

fn push_release_smoke_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    steps.push(SmokeSuiteStepSpec {
        name: "macos_release_readiness",
        description: "Signed and notarized macOS release readiness gate",
        program: "bash".to_owned(),
        args: vec![
            "Scripts/check_macos_release_readiness.sh".to_owned(),
            "--require-notarization".to_owned(),
        ],
        env: vec![],
        cwd: root.to_path_buf(),
    });
}

fn push_real_device_smoke_steps(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    real_device_id: Option<&str>,
    auth_session_file: Option<&Path>,
    min_fps: f64,
    timeout_seconds: Option<u64>,
    soak_seconds: u64,
    video_width: u32,
    video_height: u32,
) {
    let mut webrtc_env = Vec::new();
    webrtc_env.push((
        "SKYBRIDGE_SMOKE_MIN_FPS".to_owned(),
        format!("{min_fps:.2}"),
    ));
    let target_fps_floor = if min_fps >= 59.0 { 60.0 } else { 32.0 };
    let target_fps = min_fps.ceil().max(target_fps_floor).clamp(1.0, 120.0) as u32;
    webrtc_env.push((
        "SKYBRIDGE_SMOKE_TARGET_FPS".to_owned(),
        target_fps.to_string(),
    ));
    webrtc_env.push(("SKYBRIDGE_SMOKE_REQUIRE_AUDIO".to_owned(), "1".to_owned()));
    if let Some(timeout_seconds) = timeout_seconds {
        webrtc_env.push((
            "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS".to_owned(),
            timeout_seconds.to_string(),
        ));
    }
    if soak_seconds > 0 {
        webrtc_env.push((
            "SKYBRIDGE_SMOKE_SOAK_SECONDS".to_owned(),
            soak_seconds.to_string(),
        ));
    }
    webrtc_env.push(("SKYBRIDGE_SMOKE_FORCE_RELAY_ICE".to_owned(), "1".to_owned()));
    webrtc_env.push(("SKYBRIDGE_SMOKE_EXTREME_MEDIA".to_owned(), "1".to_owned()));
    webrtc_env.push((
        "SKYBRIDGE_SMOKE_VIDEO_WIDTH".to_owned(),
        video_width.to_string(),
    ));
    webrtc_env.push((
        "SKYBRIDGE_SMOKE_VIDEO_HEIGHT".to_owned(),
        video_height.to_string(),
    ));
    webrtc_env.push((
        "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK".to_owned(),
        "1".to_owned(),
    ));
    webrtc_env.push((
        "SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN".to_owned(),
        "0".to_owned(),
    ));
    if let Some(device_id) = real_device_id {
        webrtc_env.push(("SKYBRIDGE_REAL_DEVICE_ID".to_owned(), device_id.to_owned()));
    }
    if let Some(auth_session_file) = auth_session_file {
        webrtc_env.push((
            "SKYBRIDGE_SMOKE_AUTH_SESSION_FILE".to_owned(),
            auth_session_file.display().to_string(),
        ));
    }
    steps.push(SmokeSuiteStepSpec {
        name: "real_device_webrtc_smoke",
        description: "Real iPad WebRTC media smoke with Rust doctor gate",
        program: "bash".to_owned(),
        args: vec!["Scripts/run_real_device_webrtc_smoke.sh".to_owned()],
        env: webrtc_env,
        cwd: root.to_path_buf(),
    });

    let mut file_env = Vec::new();
    if let Some(device_id) = real_device_id {
        file_env.push(("SKYBRIDGE_REAL_DEVICE_ID".to_owned(), device_id.to_owned()));
    }
    steps.push(SmokeSuiteStepSpec {
        name: "real_device_file_transfer_smoke",
        description: "Real iPad file-transfer smoke",
        program: "bash".to_owned(),
        args: vec!["Scripts/run_real_device_file_transfer_smoke.sh".to_owned()],
        env: file_env,
        cwd: root.to_path_buf(),
    });
}

fn swift_test_cache_env(root: &Path) -> Vec<(String, String)> {
    let cache_dir = root.join(".swiftpm-cache").display().to_string();
    let module_cache_dir = root.join(".swiftpm-module-cache").display().to_string();
    vec![
        ("SWIFTPM_CACHE_PATH".to_owned(), cache_dir),
        (
            "CLANG_MODULE_CACHE_PATH".to_owned(),
            module_cache_dir.clone(),
        ),
        ("SWIFT_MODULE_CACHE_PATH".to_owned(), module_cache_dir),
    ]
}

fn run_smoke_suite_plan(
    root: &Path,
    profile: SmokeSuiteProfile,
    dry_run: bool,
    as_json: bool,
    steps: Vec<SmokeSuiteStepSpec>,
) -> Result<()> {
    if dry_run {
        let report = SmokeSuiteReportJson {
            schema_version: 1,
            profile,
            dry_run,
            root: root.display().to_string(),
            steps: steps.iter().map(SmokeSuiteStepSpec::to_json).collect(),
            outcomes: vec![],
        };
        if as_json {
            println!("{}", serde_json::to_string_pretty(&report)?);
        } else {
            print_smoke_suite_plan_text(&report);
        }
        return Ok(());
    }

    let mut outcomes = Vec::new();
    for step in &steps {
        if !as_json {
            println!("==> {}: {}", step.name, step.description);
            println!("    {}", format_smoke_step_command(step));
        }

        let started = Instant::now();
        let mut command = Command::new(&step.program);
        command.args(&step.args).current_dir(&step.cwd);
        for (name, value) in &step.env {
            command.env(name, value);
        }

        let outcome = if as_json {
            let output = command.output()?;
            SmokeSuiteOutcomeJson {
                name: step.name.to_owned(),
                description: step.description.to_owned(),
                command: step.command_vector(),
                env: step
                    .env
                    .iter()
                    .map(|(name, value)| SmokeSuiteEnvJson {
                        name: name.clone(),
                        value: value.clone(),
                    })
                    .collect(),
                cwd: step.cwd.display().to_string(),
                success: output.status.success(),
                exit_code: output.status.code(),
                duration_ms: started.elapsed().as_millis(),
                stdout_tail: Some(tail_lossy(&output.stdout, 8_000)),
                stderr_tail: Some(tail_lossy(&output.stderr, 8_000)),
            }
        } else {
            let status = command.status()?;
            SmokeSuiteOutcomeJson {
                name: step.name.to_owned(),
                description: step.description.to_owned(),
                command: step.command_vector(),
                env: step
                    .env
                    .iter()
                    .map(|(name, value)| SmokeSuiteEnvJson {
                        name: name.clone(),
                        value: value.clone(),
                    })
                    .collect(),
                cwd: step.cwd.display().to_string(),
                success: status.success(),
                exit_code: status.code(),
                duration_ms: started.elapsed().as_millis(),
                stdout_tail: None,
                stderr_tail: None,
            }
        };

        let failed_name = if outcome.success {
            None
        } else {
            Some(outcome.name.clone())
        };
        outcomes.push(outcome);
        if let Some(failed_name) = failed_name {
            let report = SmokeSuiteReportJson {
                schema_version: 1,
                profile,
                dry_run: false,
                root: root.display().to_string(),
                steps: steps.iter().map(SmokeSuiteStepSpec::to_json).collect(),
                outcomes,
            };
            if as_json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            }
            bail!("smoke suite step `{failed_name}` failed");
        }
    }

    let report = SmokeSuiteReportJson {
        schema_version: 1,
        profile,
        dry_run: false,
        root: root.display().to_string(),
        steps: steps.iter().map(SmokeSuiteStepSpec::to_json).collect(),
        outcomes,
    };
    if as_json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("smoke suite passed: {} step(s)", report.outcomes.len());
    }
    Ok(())
}

fn print_smoke_suite_plan_text(report: &SmokeSuiteReportJson) {
    println!("smoke suite plan: {:?}", report.profile);
    println!("root: {}", report.root);
    for step in &report.steps {
        let env = if step.env.is_empty() {
            String::new()
        } else {
            let rendered = step
                .env
                .iter()
                .map(|entry| format!("{}={}", entry.name, shell_quote(&entry.value)))
                .collect::<Vec<_>>()
                .join(" ");
            format!("{rendered} ")
        };
        let command = step
            .command
            .iter()
            .map(|part| shell_quote(part))
            .collect::<Vec<_>>()
            .join(" ");
        println!("  - {}: {}", step.name, step.description);
        println!("    cwd: {}", step.cwd);
        println!("    cmd: {env}{command}");
    }
}

fn format_smoke_step_command(step: &SmokeSuiteStepSpec) -> String {
    let env = if step.env.is_empty() {
        String::new()
    } else {
        let rendered = step
            .env
            .iter()
            .map(|(name, value)| format!("{name}={}", shell_quote(value)))
            .collect::<Vec<_>>()
            .join(" ");
        format!("{rendered} ")
    };
    let command = step
        .command_vector()
        .iter()
        .map(|part| shell_quote(part))
        .collect::<Vec<_>>()
        .join(" ");
    format!("cwd={} {env}{command}", step.cwd.display())
}

fn shell_quote(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | ':' | '='))
    {
        value.to_owned()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}

fn tail_lossy(bytes: &[u8], max_chars: usize) -> String {
    let text = String::from_utf8_lossy(bytes);
    let char_count = text.chars().count();
    if char_count <= max_chars {
        return text.into_owned();
    }

    let tail = text
        .chars()
        .rev()
        .take(max_chars)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<String>();
    format!("...[truncated]\n{tail}")
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

    Ok(DoctorProbeReport {
        target,
        checks,
        fault_stage: None,
        latest_diagnostic_at: None,
        latest_video_evidence_at: None,
        latest_receiver_evidence_at: None,
        latest_audio_tx_evidence_at: None,
        latest_audio_rx_evidence_at: None,
    })
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
        return Ok(DoctorProbeReport {
            target,
            checks,
            fault_stage: None,
            latest_diagnostic_at: None,
            latest_video_evidence_at: None,
            latest_receiver_evidence_at: None,
            latest_audio_tx_evidence_at: None,
            latest_audio_rx_evidence_at: None,
        });
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

    Ok(DoctorProbeReport {
        target,
        checks,
        fault_stage: None,
        latest_diagnostic_at: None,
        latest_video_evidence_at: None,
        latest_receiver_evidence_at: None,
        latest_audio_tx_evidence_at: None,
        latest_audio_rx_evidence_at: None,
    })
}

fn build_webrtc_media_doctor_report(
    args: &WebRtcMediaDoctorArgs,
    session_id: &str,
) -> Result<DoctorProbeReport> {
    build_webrtc_media_doctor_report_with_video_requirements(args, session_id, 0, 0, false)
}

fn build_webrtc_media_doctor_report_with_video_requirements(
    args: &WebRtcMediaDoctorArgs,
    session_id: &str,
    min_width: u32,
    min_height: u32,
    exact_video_size: bool,
) -> Result<DoctorProbeReport> {
    build_webrtc_media_doctor_report_with_options(
        args,
        session_id,
        min_width,
        min_height,
        exact_video_size,
        false,
        None,
    )
}

fn build_webrtc_media_doctor_report_for_gate(
    args: &WebRtcMediaDoctorArgs,
    session_id: &str,
    min_width: u32,
    min_height: u32,
    exact_video_size: bool,
    strict_fps_floor: bool,
    not_before: Option<OffsetDateTime>,
) -> Result<DoctorProbeReport> {
    build_webrtc_media_doctor_report_with_options(
        args,
        session_id,
        min_width,
        min_height,
        exact_video_size,
        strict_fps_floor,
        not_before,
    )
}

fn build_webrtc_media_doctor_report_with_options(
    args: &WebRtcMediaDoctorArgs,
    session_id: &str,
    min_width: u32,
    min_height: u32,
    exact_video_size: bool,
    strict_fps_floor: bool,
    not_before: Option<OffsetDateTime>,
) -> Result<DoctorProbeReport> {
    let session_id = session_id.trim();
    if session_id.is_empty() {
        bail!("--session-id must not be empty");
    }
    if !args.min_fps.is_finite() || args.min_fps <= 0.0 {
        bail!("--min-fps must be a positive finite number");
    }
    if (min_width == 0) != (min_height == 0) {
        bail!("pass both min_width and min_height, or neither");
    }
    if exact_video_size && (min_width == 0 || min_height == 0) {
        bail!("exact_video_size requires min_width and min_height");
    }

    let now = OffsetDateTime::now_utc();
    let evidence = read_webrtc_media_evidence(
        session_id,
        args.artifact_dir.as_deref(),
        args.log_file.as_deref(),
        args.since_seconds,
        now,
        not_before,
    );
    let require_audio = args.require_audio;
    let mut checks = Vec::new();
    checks.push(check_webrtc_media_sources(&evidence));
    checks.push(check_webrtc_media_samples(
        &evidence,
        session_id,
        args.since_seconds,
    ));
    checks.push(check_webrtc_media_fps(
        &evidence,
        args.min_fps,
        require_audio,
        strict_fps_floor,
    ));
    if min_width > 0 && min_height > 0 {
        checks.push(check_webrtc_video_resolution(
            &evidence,
            min_width,
            min_height,
            exact_video_size,
        ));
    }
    if require_audio {
        checks.push(check_webrtc_media_counter(
            "audio_tx_captured",
            "audioTxCaptured",
            &evidence.audio_tx_captured,
        ));
        checks.push(check_webrtc_media_counter(
            "audio_tx_encoded",
            "audioTxEncoded",
            &evidence.audio_tx_encoded,
        ));
        checks.push(check_webrtc_media_counter(
            "audio_tx_sent",
            "audioTxSent",
            &evidence.audio_tx_sent,
        ));
        checks.push(check_webrtc_media_counter(
            "audio_rx_recv",
            "audioRxRecv",
            &evidence.audio_rx_recv,
        ));
        checks.push(check_webrtc_media_counter(
            "audio_rx_decoded",
            "audioRxDecoded",
            &evidence.audio_rx_decoded,
        ));
        checks.push(check_webrtc_media_counter(
            "audio_rx_played",
            "audioRxPlayed",
            &evidence.audio_rx_played,
        ));
        checks.push(check_webrtc_rendered_frames_counter(&evidence));
        checks.push(check_webrtc_audio_activity_continuity(&evidence));
        checks.push(check_webrtc_audio_playback_continuity(&evidence));
        checks.push(check_webrtc_audio_relay_startup(&evidence));
    }
    checks.push(check_webrtc_native_video_health(&evidence));
    checks.push(check_webrtc_native_video_rtc_stats(
        &evidence,
        args.min_fps,
        strict_fps_floor,
    ));
    checks.push(check_webrtc_sck_vt_encode_latency(&evidence, args.min_fps));
    checks.push(check_webrtc_native_video_receiver(&evidence));
    checks.push(check_webrtc_visible_native_render(
        &evidence,
        args.min_fps,
        strict_fps_floor,
    ));
    checks.push(check_webrtc_strict_media_failure(&evidence));
    checks.push(check_webrtc_stale_fallback(&evidence));
    checks.push(check_webrtc_backpressure(&evidence));
    let fault_stage = classify_webrtc_probable_fault_stage(&evidence, require_audio, args.min_fps);
    checks.push(check_webrtc_probable_fault_stage(fault_stage));

    Ok(DoctorProbeReport {
        target: format!(
            "webrtc-media session={} since={}s sources={}",
            session_id,
            args.since_seconds,
            describe_webrtc_sources(&evidence)
        ),
        checks,
        fault_stage,
        latest_diagnostic_at: evidence.latest_at,
        latest_video_evidence_at: evidence.latest_video_evidence_at,
        latest_receiver_evidence_at: evidence.latest_receiver_evidence_at,
        latest_audio_tx_evidence_at: evidence.latest_audio_tx_evidence_at,
        latest_audio_rx_evidence_at: evidence.latest_audio_rx_evidence_at,
    })
}

#[derive(Debug, Clone)]
struct ObservedMetric<T> {
    value: T,
    sequence: usize,
    evidence: String,
}

#[derive(Debug, Clone, Copy)]
struct VideoDimensions {
    width: u32,
    height: u32,
}

#[derive(Debug, Clone, Copy)]
struct ReceiverVideoDimensions {
    dimensions: VideoDimensions,
    explicit_visible: bool,
}

#[derive(Debug)]
struct WebRtcMediaRawLine {
    source: PathBuf,
    line_number: usize,
    line: String,
    source_is_session_specific: bool,
    observed_at: Option<OffsetDateTime>,
    source_order: usize,
}

#[derive(Debug, Default)]
struct CounterObservation {
    latest: Option<ObservedMetric<u64>>,
    lowest: Option<ObservedMetric<u64>>,
    first_positive: Option<ObservedMetric<u64>>,
    latest_positive: Option<ObservedMetric<u64>>,
    zero_after_positive: Option<ObservedMetric<u64>>,
    decrease_after_positive: Option<ObservedMetric<u64>>,
    positive_count: usize,
    seen_positive: bool,
}

#[derive(Debug, Default)]
struct WebRtcMediaEvidence {
    attempted_sources: Vec<PathBuf>,
    read_sources: Vec<PathBuf>,
    read_errors: Vec<String>,
    matched_lines: usize,
    latest_at: Option<OffsetDateTime>,
    latest_video_evidence_at: Option<OffsetDateTime>,
    latest_receiver_evidence_at: Option<OffsetDateTime>,
    latest_audio_tx_evidence_at: Option<OffsetDateTime>,
    latest_audio_rx_evidence_at: Option<OffsetDateTime>,
    lowest_fps: Option<ObservedMetric<f64>>,
    latest_fps: Option<ObservedMetric<f64>>,
    audio_tx_captured: CounterObservation,
    audio_tx_encoded: CounterObservation,
    audio_tx_sent: CounterObservation,
    audio_tx_captured_total: CounterObservation,
    audio_tx_encoded_total: CounterObservation,
    audio_tx_sent_total: CounterObservation,
    audio_drops: CounterObservation,
    audio_drops_total: CounterObservation,
    audio_rx_recv: CounterObservation,
    audio_rx_decoded: CounterObservation,
    audio_rx_played: CounterObservation,
    audio_rx_recv_total: CounterObservation,
    audio_rx_decoded_total: CounterObservation,
    audio_rx_played_total: CounterObservation,
    audio_rendered_frames: CounterObservation,
    audio_underflow: CounterObservation,
    audio_bridged_underflow: CounterObservation,
    audio_rebuffer: CounterObservation,
    audio_playback_drop: CounterObservation,
    audio_jitter_evicted: CounterObservation,
    audio_jitter_late: CounterObservation,
    audio_lowest_schedule_lead_ms: Option<ObservedMetric<f64>>,
    audio_highest_arrival_p95_ms: Option<ObservedMetric<f64>>,
    audio_highest_arrival_max_ms: Option<ObservedMetric<f64>>,
    audio_playout_pressure: Option<ObservedMetric<String>>,
    audio_tx_missing_viewer_endpoint: Option<ObservedMetric<String>>,
    audio_tx_relay_failure: Option<ObservedMetric<String>>,
    audio_tx_relay_bind_pending: Option<ObservedMetric<String>>,
    audio_rx_relay_bind_failure: Option<ObservedMetric<String>>,
    native_video_state: Option<ObservedMetric<String>>,
    native_video_failure: Option<ObservedMetric<String>>,
    native_video_submitted: CounterObservation,
    native_video_frames_encoded: CounterObservation,
    native_video_frames_sent: CounterObservation,
    native_video_key_frames_encoded: CounterObservation,
    native_video_packets_sent: CounterObservation,
    native_video_bytes_sent: CounterObservation,
    native_video_codec: Option<ObservedMetric<String>>,
    native_video_encoder: Option<ObservedMetric<String>>,
    native_video_quality_limit: Option<ObservedMetric<String>>,
    native_video_encode_fps: Option<ObservedMetric<f64>>,
    native_video_lowest_encode_fps: Option<ObservedMetric<f64>>,
    native_video_target_bitrate: CounterObservation,
    native_video_available_outgoing_bitrate: CounterObservation,
    native_video_current_rtt: Option<ObservedMetric<f64>>,
    native_video_remote_rtt: Option<ObservedMetric<f64>>,
    native_video_remote_packets_lost: Option<ObservedMetric<f64>>,
    native_video_remote_jitter: Option<ObservedMetric<f64>>,
    sck_captured: CounterObservation,
    sck_meaningful: CounterObservation,
    sck_encoded: CounterObservation,
    sck_encoded_bytes: CounterObservation,
    sck_capture_fps: Option<ObservedMetric<f64>>,
    sck_meaningful_fps: Option<ObservedMetric<f64>>,
    sck_encoded_fps: Option<ObservedMetric<f64>>,
    sck_encode_latency_p50_ms: Option<ObservedMetric<f64>>,
    sck_encode_latency_p95_ms: Option<ObservedMetric<f64>>,
    sck_encode_latency_max_ms: Option<ObservedMetric<f64>>,
    sck_encode_failures: CounterObservation,
    sck_codec: Option<ObservedMetric<String>>,
    native_video_receiver_frame: Option<ObservedMetric<String>>,
    native_video_receiver_dimensions: Option<ObservedMetric<VideoDimensions>>,
    native_video_receiver_dimensions_are_visible: bool,
    native_video_render_frame: Option<ObservedMetric<String>>,
    native_video_render_source: Option<ObservedMetric<String>>,
    native_video_render_dimensions: Option<ObservedMetric<VideoDimensions>>,
    native_video_render_dimensions_are_visible: bool,
    strict_media_failure: Option<ObservedMetric<String>>,
    fallback_producer_failure: Option<ObservedMetric<String>>,
    stale_fallback: Option<ObservedMetric<String>>,
    backpressure: Option<ObservedMetric<String>>,
}

fn check_webrtc_probable_fault_stage(stage: Option<&'static str>) -> DoctorCheck {
    DoctorCheck {
        name: "probable_fault_stage",
        ok: stage.is_none(),
        severity: if stage.is_some() { "error" } else { "info" },
        detail: stage.map_or_else(
            || "no single dominant WebRTC media fault stage detected".to_owned(),
            |stage| format!("probable fault stage: {stage}"),
        ),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn classify_webrtc_probable_fault_stage(
    evidence: &WebRtcMediaEvidence,
    require_audio: bool,
    min_fps: f64,
) -> Option<&'static str> {
    if evidence.matched_lines == 0 {
        return Some("diagnostics_missing");
    }
    if require_audio {
        if evidence
            .strict_media_failure
            .as_ref()
            .is_some_and(|failure| {
                failure
                    .value
                    .contains("realtime-audio-main-path-unavailable")
            })
        {
            if evidence.audio_tx_relay_failure.is_some()
                || evidence.audio_tx_relay_bind_pending.is_some()
            {
                return Some("audio_tx_relay_bind");
            }
            if evidence.audio_tx_missing_viewer_endpoint.is_some() {
                return Some("audio_tx_relay_send");
            }
        }
        if latest_counter_value(&evidence.audio_tx_captured) == Some(0) {
            return Some("audio_tx_capture");
        }
        if latest_counter_value(&evidence.audio_tx_encoded) == Some(0) {
            return Some("audio_tx_encode");
        }
        if latest_counter_value(&evidence.audio_tx_sent) == Some(0) {
            return Some("audio_tx_relay_send");
        }
        let tx_has_sent_media =
            latest_counter_value(&evidence.audio_tx_sent).is_some_and(|value| value > 0);
        if !tx_has_sent_media
            && evidence
                .audio_tx_relay_failure
                .as_ref()
                .is_some_and(|metric| {
                    metric.value.contains("leaseLimit") || metric.value.contains("relayBind")
                })
        {
            return Some("audio_tx_relay_send");
        }
        if evidence.audio_tx_relay_failure.is_some() && !webrtc_audio_rx_has_received(evidence) {
            return Some("audio_tx_relay_bind");
        }
        if evidence.audio_tx_relay_bind_pending.is_some() && !webrtc_audio_rx_has_received(evidence)
        {
            return Some("audio_tx_relay_bind");
        }
        if evidence.audio_tx_missing_viewer_endpoint.is_some()
            && evidence.audio_tx_relay_failure.is_none()
        {
            return Some("audio_tx_relay_send");
        }
        if evidence.audio_rx_relay_bind_failure.is_some() {
            return Some("audio_rx_relay_recv");
        }
        if latest_counter_value(&evidence.audio_rx_recv) == Some(0)
            || evidence.audio_rx_recv.zero_after_positive.is_some()
        {
            return Some("audio_rx_relay_recv");
        }
        if latest_counter_value(&evidence.audio_rx_decoded) == Some(0)
            || evidence.audio_rx_decoded.zero_after_positive.is_some()
        {
            return Some("audio_rx_decode");
        }
        if latest_counter_value(&evidence.audio_rx_played) == Some(0)
            || evidence.audio_rx_played.zero_after_positive.is_some()
        {
            return Some("audio_rx_playback");
        }
        if webrtc_audio_has_hard_playback_failure(evidence)
            || counter_observed_positive(&evidence.audio_rebuffer)
            || counter_observed_positive(&evidence.audio_playback_drop)
            || counter_observed_positive(&evidence.audio_jitter_evicted)
        {
            return Some("audio_rx_playback");
        }
    }
    if evidence.strict_media_failure.is_some() {
        return Some("strict_media_failure");
    }
    if evidence.backpressure.is_some() {
        return Some("fallback_backpressure");
    }
    if let Some(stage) = classify_webrtc_sck_tx_stage(evidence, min_fps) {
        return Some(stage);
    }
    if evidence.fallback_producer_failure.is_some() {
        return Some("fallback_capture_stalled");
    }
    if evidence
        .lowest_fps
        .as_ref()
        .is_some_and(|fps| fps.value <= 2.0)
        || (evidence.native_video_failure.is_some() && !webrtc_fallback_video_is_healthy(evidence))
    {
        return Some("native_video_rtp_stalled");
    }
    if require_audio {
        if let Some(stage) = classify_webrtc_audio_continuity_stage(evidence) {
            return Some(stage);
        }
    }
    None
}

fn classify_webrtc_sck_tx_stage(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
) -> Option<&'static str> {
    let has_sck_evidence = evidence.sck_captured.latest.is_some()
        || evidence.sck_meaningful.latest.is_some()
        || evidence.sck_encoded.latest.is_some()
        || evidence.sck_capture_fps.is_some()
        || evidence.sck_meaningful_fps.is_some()
        || evidence.sck_encoded_fps.is_some()
        || evidence.sck_encode_latency_p95_ms.is_some()
        || evidence.sck_encode_failures.latest.is_some();
    if !has_sck_evidence {
        return None;
    }

    let low_media_fps = evidence
        .lowest_fps
        .as_ref()
        .is_some_and(|fps| fps.value <= 2.0)
        || evidence
            .latest_fps
            .as_ref()
            .is_some_and(|fps| fps.value <= 2.0);

    let capture_missing_or_stalled = latest_counter_value(&evidence.sck_captured) == Some(0)
        || latest_counter_value(&evidence.sck_meaningful) == Some(0)
        || evidence
            .sck_meaningful_fps
            .as_ref()
            .is_some_and(|fps| fps.value <= 2.0);
    if low_media_fps && capture_missing_or_stalled {
        return Some("sck_capture_stalled");
    }

    let capture_flowing = latest_counter_value(&evidence.sck_meaningful)
        .is_some_and(|value| value > 0)
        || evidence
            .sck_meaningful_fps
            .as_ref()
            .is_some_and(|fps| fps.value > 2.0);
    let encode_missing_or_stalled = latest_counter_value(&evidence.sck_encoded) == Some(0)
        || latest_counter_value(&evidence.sck_encode_failures).is_some_and(|value| value > 0)
        || evidence
            .sck_encoded_fps
            .as_ref()
            .is_some_and(|fps| fps.value <= 2.0);
    if low_media_fps && capture_flowing && encode_missing_or_stalled {
        return Some("vt_encode_stalled");
    }

    let media_fps_below_gate = evidence
        .lowest_fps
        .as_ref()
        .is_some_and(|fps| fps.value < min_fps)
        || evidence
            .latest_fps
            .as_ref()
            .is_some_and(|fps| fps.value < min_fps);
    let encode_flowing = latest_counter_value(&evidence.sck_encoded).is_some_and(|value| value > 0)
        || evidence
            .sck_encoded_fps
            .as_ref()
            .is_some_and(|fps| fps.value > 2.0);
    if media_fps_below_gate
        && capture_flowing
        && encode_flowing
        && webrtc_sck_vt_encode_latency_over_budget(evidence, min_fps)
    {
        return Some("vt_encode_slow");
    }

    None
}

fn webrtc_frame_budget_ms(min_fps: f64) -> f64 {
    1_000.0 / min_fps.max(1.0)
}

fn webrtc_sck_vt_encode_latency_over_budget(evidence: &WebRtcMediaEvidence, min_fps: f64) -> bool {
    let budget_ms = webrtc_frame_budget_ms(min_fps);
    let p95_over_budget = evidence
        .sck_encode_latency_p95_ms
        .as_ref()
        .is_some_and(|metric| metric.value > budget_ms * 1.10);
    let max_severely_over_budget = evidence
        .sck_encode_latency_max_ms
        .as_ref()
        .is_some_and(|metric| metric.value > budget_ms * 2.0);
    p95_over_budget || max_severely_over_budget
}

fn classify_webrtc_audio_continuity_stage(evidence: &WebRtcMediaEvidence) -> Option<&'static str> {
    if !webrtc_counter_has_continuity(
        &evidence.audio_tx_captured,
        Some(&evidence.audio_tx_captured_total),
    ) {
        return Some("audio_tx_capture");
    }
    if !webrtc_counter_has_continuity(
        &evidence.audio_tx_encoded,
        Some(&evidence.audio_tx_encoded_total),
    ) {
        return Some("audio_tx_encode");
    }
    if !webrtc_counter_has_continuity(&evidence.audio_tx_sent, Some(&evidence.audio_tx_sent_total))
        || counter_observed_positive(&evidence.audio_drops)
        || counter_observed_positive(&evidence.audio_drops_total)
    {
        return Some("audio_tx_relay_send");
    }
    if !webrtc_counter_has_continuity(&evidence.audio_rx_recv, Some(&evidence.audio_rx_recv_total))
    {
        return Some("audio_rx_relay_recv");
    }
    if !webrtc_counter_has_continuity(
        &evidence.audio_rx_decoded,
        Some(&evidence.audio_rx_decoded_total),
    ) {
        return Some("audio_rx_decode");
    }
    if !webrtc_counter_has_continuity(
        &evidence.audio_rx_played,
        Some(&evidence.audio_rx_played_total),
    ) || !webrtc_rendered_frames_have_continuity(evidence)
    {
        return Some("audio_rx_playback");
    }
    None
}

fn latest_counter_value(observation: &CounterObservation) -> Option<u64> {
    observation.latest.as_ref().map(|value| value.value)
}

fn latest_positive_counter_value(observation: &CounterObservation) -> Option<u64> {
    observation
        .latest_positive
        .as_ref()
        .map(|value| value.value)
}

fn counter_observed_positive(observation: &CounterObservation) -> bool {
    observation
        .latest_positive
        .as_ref()
        .is_some_and(|metric| metric.value > 0)
}

fn webrtc_audio_rx_has_received(evidence: &WebRtcMediaEvidence) -> bool {
    counter_observed_positive(&evidence.audio_rx_recv)
        || counter_observed_positive(&evidence.audio_rx_recv_total)
}

fn read_webrtc_media_evidence(
    session_id: &str,
    artifact_dir: Option<&Path>,
    log_file: Option<&Path>,
    since_seconds: u64,
    now: OffsetDateTime,
    not_before: Option<OffsetDateTime>,
) -> WebRtcMediaEvidence {
    let mut evidence = WebRtcMediaEvidence::default();
    let sources = collect_webrtc_media_source_candidates(session_id, artifact_dir, log_file);
    let safe_session_id = safe_webrtc_session_id(session_id);
    let session_log_name = format!("webrtc-session-{safe_session_id}.log");
    let mut raw_lines = Vec::new();

    for source in sources {
        if evidence
            .attempted_sources
            .iter()
            .any(|path| path == &source)
        {
            continue;
        }
        evidence.attempted_sources.push(source.clone());
        let source_is_session_specific = source
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name == session_log_name || name.contains(session_id));
        let file = match File::open(&source) {
            Ok(file) => file,
            Err(error) => {
                evidence
                    .read_errors
                    .push(format!("{}: {}", source.display(), error));
                continue;
            }
        };
        let source_order = evidence.read_sources.len();
        evidence.read_sources.push(source.clone());
        for (line_index, line) in BufReader::new(file).lines().enumerate() {
            let line_number = line_index + 1;
            let line = match line {
                Ok(line) => line,
                Err(error) => {
                    evidence.read_errors.push(format!(
                        "{}:{}: {}",
                        source.display(),
                        line_number,
                        error
                    ));
                    continue;
                }
            };
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let json = serde_json::from_str::<serde_json::Value>(trimmed).ok();
            let observed_at = parse_webrtc_diagnostic_timestamp(trimmed, json.as_ref());
            raw_lines.push(WebRtcMediaRawLine {
                source: source.clone(),
                line_number,
                line,
                source_is_session_specific,
                observed_at,
                source_order,
            });
        }
    }

    raw_lines.sort_by(compare_webrtc_media_raw_lines);
    for raw_line in raw_lines {
        observe_webrtc_media_line(
            &mut evidence,
            session_id,
            &raw_line.source,
            raw_line.line_number,
            &raw_line.line,
            raw_line.source_is_session_specific,
            since_seconds,
            now,
            not_before,
        );
    }

    evidence
}

fn compare_webrtc_media_raw_lines(
    left: &WebRtcMediaRawLine,
    right: &WebRtcMediaRawLine,
) -> Ordering {
    match (left.observed_at, right.observed_at) {
        (Some(left_at), Some(right_at)) => left_at.cmp(&right_at),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
    .then_with(|| left.source_order.cmp(&right.source_order))
    .then_with(|| left.line_number.cmp(&right.line_number))
}

fn collect_webrtc_media_source_candidates(
    session_id: &str,
    artifact_dir: Option<&Path>,
    log_file: Option<&Path>,
) -> Vec<PathBuf> {
    let mut sources = Vec::new();
    if let Some(log_file) = log_file {
        sources.push(log_file.to_path_buf());
    }

    let mut candidate_dirs = Vec::new();
    if let Some(artifact_dir) = artifact_dir {
        candidate_dirs.push(artifact_dir.to_path_buf());
    }
    if artifact_dir.is_none()
        && let Some(default_dir) = default_webrtc_artifact_dir()
    {
        if !candidate_dirs.iter().any(|path| path == &default_dir) {
            candidate_dirs.push(default_dir);
        }
    }

    let safe_session_id = safe_webrtc_session_id(session_id);
    for artifact_dir in candidate_dirs {
        for candidate in [
            artifact_dir.join(format!("webrtc-session-{safe_session_id}.log")),
            artifact_dir.join(format!("webrtc-session-{safe_session_id}.jsonl")),
            artifact_dir.join(format!("webrtc-media-{safe_session_id}.jsonl")),
            artifact_dir.join("skybridge-smoke-status.log"),
        ] {
            if candidate.is_file() {
                sources.push(candidate);
            }
        }

        if let Ok(entries) = std::fs::read_dir(&artifact_dir) {
            let mut entries = entries.flatten().collect::<Vec<_>>();
            entries.sort_by_key(|entry| entry.file_name());
            for entry in entries {
                let path = entry.path();
                if !path.is_file() {
                    continue;
                }
                let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                    continue;
                };
                let extension_ok = path
                    .extension()
                    .and_then(|extension| extension.to_str())
                    .is_some_and(|extension| matches!(extension, "log" | "jsonl" | "txt"));
                if !extension_ok {
                    continue;
                }
                if name.contains(session_id)
                    || name.contains(&safe_session_id)
                    || name.contains("webrtc")
                    || name.contains("smoke-status")
                    || name == "mac.status.log"
                    || name == "mac.status.log.trace.log"
                    || name.starts_with("mac_round_")
                    || name.starts_with("ios_round_")
                {
                    sources.push(path);
                }
            }
        }
    }

    sources
}

fn default_webrtc_artifact_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library").join("Logs").join("SkyBridge"))
}

fn resolve_webrtc_media_session_arg(
    session_id: Option<&str>,
    latest: bool,
    artifact_dir: Option<&Path>,
    log_file: Option<&Path>,
) -> Result<String> {
    let session_id = session_id.map(str::trim).filter(|value| !value.is_empty());
    match (session_id, latest) {
        (Some(_), true) => bail!("pass either --session-id <id> or --latest, not both"),
        (Some(session_id), false) => Ok(session_id.to_owned()),
        (None, true) => resolve_latest_webrtc_media_session_id(artifact_dir, log_file),
        (None, false) => bail!("pass --session-id <id> or --latest"),
    }
}

fn resolve_latest_webrtc_media_session_id(
    artifact_dir: Option<&Path>,
    log_file: Option<&Path>,
) -> Result<String> {
    let mut candidates = Vec::new();
    if let Some(log_file) = log_file {
        candidates.push(log_file.to_path_buf());
    }
    if let Some(artifact_dir) = artifact_dir {
        collect_webrtc_media_latest_candidates_from_dir(artifact_dir, &mut candidates);
    }
    if artifact_dir.is_none()
        && log_file.is_none()
        && let Some(default_dir) = default_webrtc_artifact_dir()
    {
        collect_webrtc_media_latest_candidates_from_dir(&default_dir, &mut candidates);
    }

    candidates.sort();
    candidates.dedup();

    let mut best: Option<(OffsetDateTime, String)> = None;
    for path in candidates {
        let Ok(file) = File::open(&path) else {
            continue;
        };
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let json = serde_json::from_str::<serde_json::Value>(trimmed).ok();
            let Some(session_id) = find_webrtc_string(json.as_ref(), trimmed, "sessionId")
                .or_else(|| find_webrtc_string(json.as_ref(), trimmed, "session_id"))
                .or_else(|| find_webrtc_string(json.as_ref(), trimmed, "session"))
                .or_else(|| session_id_from_webrtc_media_file_name(&path))
            else {
                continue;
            };
            let timestamp = parse_webrtc_diagnostic_timestamp(trimmed, json.as_ref())
                .or_else(|| file_modified_time_utc(&path))
                .unwrap_or_else(OffsetDateTime::now_utc);
            if best
                .as_ref()
                .is_none_or(|(best_timestamp, _)| timestamp >= *best_timestamp)
            {
                best = Some((timestamp, session_id));
            }
        }
    }

    best.map(|(_, session_id)| session_id)
        .ok_or_else(|| anyhow!("could not find latest WebRTC media diagnostics session"))
}

fn collect_webrtc_media_latest_candidates_from_dir(dir: &Path, candidates: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries = entries.flatten().collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if name.starts_with("webrtc-media-")
            || name.starts_with("webrtc-session-")
            || name.contains("webrtc")
            || name.contains("smoke-status")
        {
            candidates.push(path);
        }
    }
}

fn session_id_from_webrtc_media_file_name(path: &Path) -> Option<String> {
    let name = path.file_name()?.to_str()?;
    let value = name
        .strip_prefix("webrtc-media-")
        .or_else(|| name.strip_prefix("webrtc-session-"))?;
    let session_id = value
        .trim_end_matches(".jsonl")
        .trim_end_matches(".log")
        .trim_end_matches(".txt")
        .to_owned();
    (!session_id.is_empty()).then_some(session_id)
}

fn file_modified_time_utc(path: &Path) -> Option<OffsetDateTime> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(OffsetDateTime::from(modified))
}

fn safe_webrtc_session_id(session_id: &str) -> String {
    session_id
        .chars()
        .filter(|value| value.is_ascii_alphanumeric() || *value == '-' || *value == '_')
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn observe_webrtc_media_line(
    evidence: &mut WebRtcMediaEvidence,
    session_id: &str,
    source: &Path,
    line_number: usize,
    line: &str,
    source_is_session_specific: bool,
    since_seconds: u64,
    now: OffsetDateTime,
    not_before: Option<OffsetDateTime>,
) {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }
    let json = serde_json::from_str::<serde_json::Value>(trimmed).ok();
    let observed_at = parse_webrtc_diagnostic_timestamp(trimmed, json.as_ref());
    if observed_at
        .is_some_and(|timestamp| !is_webrtc_diagnostic_recent(timestamp, since_seconds, now))
    {
        return;
    }
    if let Some(not_before) = not_before {
        match observed_at {
            Some(timestamp) if timestamp >= not_before => {}
            Some(_) | None => return,
        }
    }
    if !source_is_session_specific
        && !webrtc_line_matches_session(trimmed, json.as_ref(), session_id)
    {
        return;
    }

    evidence.matched_lines += 1;
    let sequence = evidence.matched_lines;
    if let Some(observed_at) = observed_at
        && evidence
            .latest_at
            .is_none_or(|current| observed_at > current)
    {
        evidence.latest_at = Some(observed_at);
    }
    update_webrtc_gate_freshness_markers(evidence, trimmed, json.as_ref(), observed_at);
    let summary = summarize_webrtc_evidence_line(source, line_number, trimmed);

    if is_webrtc_stream_stats_line(trimmed, json.as_ref())
        && let Some(fps) =
            find_webrtc_f64_any(json.as_ref(), trimmed, &["fps", "video_fps", "videoFPS"])
    {
        update_latest_metric(
            &mut evidence.latest_fps,
            ObservedMetric {
                value: fps,
                sequence,
                evidence: summary.clone(),
            },
        );
        update_lowest_f64(
            &mut evidence.lowest_fps,
            ObservedMetric {
                value: fps,
                sequence,
                evidence: summary.clone(),
            },
        );
    }

    observe_webrtc_counter(
        &mut evidence.audio_tx_captured,
        json.as_ref(),
        trimmed,
        "audioTxCaptured",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_tx_encoded,
        json.as_ref(),
        trimmed,
        "audioTxEncoded",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_tx_sent,
        json.as_ref(),
        trimmed,
        "audioTxSent",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_tx_captured_total,
        json.as_ref(),
        trimmed,
        "audioTxCapturedTotal",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_tx_encoded_total,
        json.as_ref(),
        trimmed,
        "audioTxEncodedTotal",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_tx_sent_total,
        json.as_ref(),
        trimmed,
        "audioTxSentTotal",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_drops,
        json.as_ref(),
        trimmed,
        "audioDrops",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_drops_total,
        json.as_ref(),
        trimmed,
        "audioDropsTotal",
        sequence,
        &summary,
    );
    if !is_webrtc_audio_rx_no_positive_placeholder(json.as_ref(), trimmed) {
        observe_webrtc_counter(
            &mut evidence.audio_rx_recv,
            json.as_ref(),
            trimmed,
            "audioRxRecv",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.audio_rx_decoded,
            json.as_ref(),
            trimmed,
            "audioRxDecoded",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.audio_rx_played,
            json.as_ref(),
            trimmed,
            "audioRxPlayed",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.audio_rx_recv_total,
            json.as_ref(),
            trimmed,
            "recvTotal",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.audio_rx_decoded_total,
            json.as_ref(),
            trimmed,
            "decodeTotal",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.audio_rx_played_total,
            json.as_ref(),
            trimmed,
            "playTotal",
            sequence,
            &summary,
        );
    }
    observe_webrtc_counter(
        &mut evidence.audio_rendered_frames,
        json.as_ref(),
        trimmed,
        "renderedFrames",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_underflow,
        json.as_ref(),
        trimmed,
        "underflow",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_bridged_underflow,
        json.as_ref(),
        trimmed,
        "bridgedUnderflow",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_rebuffer,
        json.as_ref(),
        trimmed,
        "rebuffer",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_playback_drop,
        json.as_ref(),
        trimmed,
        "playbackDrop",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_jitter_evicted,
        json.as_ref(),
        trimmed,
        "jitterEvicted",
        sequence,
        &summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_jitter_late,
        json.as_ref(),
        trimmed,
        "jitterLate",
        sequence,
        &summary,
    );
    observe_webrtc_audio_playout_pressure(evidence, json.as_ref(), trimmed, sequence, &summary);

    if let Some(reason) = find_webrtc_audio_tx_missing_endpoint_reason(json.as_ref(), trimmed) {
        update_latest_metric(
            &mut evidence.audio_tx_missing_viewer_endpoint,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.clone(),
            },
        );
    }

    if let Some(reason) = find_webrtc_audio_tx_relay_failure_reason(json.as_ref(), trimmed) {
        update_latest_metric(
            &mut evidence.audio_tx_relay_failure,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.clone(),
            },
        );
    }

    if let Some(reason) = find_webrtc_audio_tx_relay_bind_pending_reason(json.as_ref(), trimmed) {
        update_latest_metric(
            &mut evidence.audio_tx_relay_bind_pending,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.clone(),
            },
        );
    }

    if let Some(reason) = find_webrtc_audio_rx_relay_bind_failure(json.as_ref(), trimmed) {
        update_latest_metric(
            &mut evidence.audio_rx_relay_bind_failure,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.clone(),
            },
        );
    }

    if let Some(state) = find_webrtc_native_video_state(json.as_ref(), trimmed) {
        let observed = ObservedMetric {
            value: state.clone(),
            sequence,
            evidence: summary.clone(),
        };
        update_latest_metric(&mut evidence.native_video_state, observed.clone());
        if is_native_video_failure_state(&state) {
            update_latest_metric(&mut evidence.native_video_failure, observed);
        }
    }

    if is_webrtc_native_video_tx_line(trimmed, json.as_ref())
        || (is_webrtc_stream_stats_line(trimmed, json.as_ref())
            && (find_webrtc_u64(json.as_ref(), trimmed, "framesSent").is_some()
                || find_webrtc_u64(json.as_ref(), trimmed, "packetsSent").is_some()))
    {
        observe_webrtc_counter(
            &mut evidence.native_video_submitted,
            json.as_ref(),
            trimmed,
            "submitted",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_frames_encoded,
            json.as_ref(),
            trimmed,
            "framesEncoded",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_frames_sent,
            json.as_ref(),
            trimmed,
            "framesSent",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_key_frames_encoded,
            json.as_ref(),
            trimmed,
            "keyFramesEncoded",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_packets_sent,
            json.as_ref(),
            trimmed,
            "packetsSent",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_bytes_sent,
            json.as_ref(),
            trimmed,
            "bytesSent",
            sequence,
            &summary,
        );
        observe_webrtc_latest_string_any(
            &mut evidence.native_video_codec,
            json.as_ref(),
            trimmed,
            &["codec", "mimeType"],
            sequence,
            &summary,
        );
        observe_webrtc_latest_string_any(
            &mut evidence.native_video_encoder,
            json.as_ref(),
            trimmed,
            &["encoder", "encoderImplementation"],
            sequence,
            &summary,
        );
        observe_webrtc_latest_string_any(
            &mut evidence.native_video_quality_limit,
            json.as_ref(),
            trimmed,
            &["qualityLimit", "qualityLimitationReason"],
            sequence,
            &summary,
        );
        if let Some(fps) =
            find_webrtc_f64_any(json.as_ref(), trimmed, &["encodeFPS", "framesPerSecond"])
        {
            let observed = ObservedMetric {
                value: fps,
                sequence,
                evidence: summary.clone(),
            };
            update_latest_metric(&mut evidence.native_video_encode_fps, observed.clone());
            update_lowest_f64(&mut evidence.native_video_lowest_encode_fps, observed);
        }
        observe_webrtc_counter(
            &mut evidence.native_video_target_bitrate,
            json.as_ref(),
            trimmed,
            "targetBitrate",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_available_outgoing_bitrate,
            json.as_ref(),
            trimmed,
            "availableOutgoingBitrate",
            sequence,
            &summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.native_video_current_rtt,
            json.as_ref(),
            trimmed,
            &["currentRTT", "currentRoundTripTime"],
            sequence,
            &summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.native_video_remote_rtt,
            json.as_ref(),
            trimmed,
            &["remoteRTT", "remoteRoundTripTime"],
            sequence,
            &summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.native_video_remote_packets_lost,
            json.as_ref(),
            trimmed,
            &["remotePacketsLost"],
            sequence,
            &summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.native_video_remote_jitter,
            json.as_ref(),
            trimmed,
            &["remoteJitter"],
            sequence,
            &summary,
        );
    }

    if is_webrtc_sck_tx_telemetry_line(trimmed, json.as_ref()) {
        observe_webrtc_counter(
            &mut evidence.sck_captured,
            json.as_ref(),
            trimmed,
            "sckCaptured",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_captured,
            json.as_ref(),
            trimmed,
            "captured",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_meaningful,
            json.as_ref(),
            trimmed,
            "sckMeaningful",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_meaningful,
            json.as_ref(),
            trimmed,
            "meaningful",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encoded,
            json.as_ref(),
            trimmed,
            "sckEncoded",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encoded,
            json.as_ref(),
            trimmed,
            "encoded",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encoded_bytes,
            json.as_ref(),
            trimmed,
            "sckEncodedBytes",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encoded_bytes,
            json.as_ref(),
            trimmed,
            "encodedBytes",
            sequence,
            &summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_capture_fps,
            json.as_ref(),
            trimmed,
            &["sckCaptureFPS", "captureFPS"],
            sequence,
            &summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_meaningful_fps,
            json.as_ref(),
            trimmed,
            &["sckMeaningfulFPS", "meaningfulFPS"],
            sequence,
            &summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_encoded_fps,
            json.as_ref(),
            trimmed,
            &["sckEncodedFPS", "encodedFPS"],
            sequence,
            &summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_encode_latency_p50_ms,
            json.as_ref(),
            trimmed,
            &["sckEncodeLatencyP50Ms", "encodeLatencyP50Ms"],
            sequence,
            &summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_encode_latency_p95_ms,
            json.as_ref(),
            trimmed,
            &["sckEncodeLatencyP95Ms", "encodeLatencyP95Ms"],
            sequence,
            &summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_encode_latency_max_ms,
            json.as_ref(),
            trimmed,
            &["sckEncodeLatencyMaxMs", "encodeLatencyMaxMs"],
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encode_failures,
            json.as_ref(),
            trimmed,
            "sckEncodeFailures",
            sequence,
            &summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encode_failures,
            json.as_ref(),
            trimmed,
            "encodeFailures",
            sequence,
            &summary,
        );
        observe_webrtc_latest_string_any(
            &mut evidence.sck_codec,
            json.as_ref(),
            trimmed,
            &["codec"],
            sequence,
            &summary,
        );
    }

    if is_webrtc_native_video_receiver_line(trimmed, json.as_ref())
        && let Some(receiver_dimensions) =
            find_webrtc_native_video_receiver_dimensions(json.as_ref(), trimmed)
    {
        let should_update_dimensions = receiver_dimensions.explicit_visible
            || !evidence.native_video_receiver_dimensions_are_visible;
        if should_update_dimensions {
            update_latest_metric(
                &mut evidence.native_video_receiver_dimensions,
                ObservedMetric {
                    value: receiver_dimensions.dimensions,
                    sequence,
                    evidence: summary.clone(),
                },
            );
            if receiver_dimensions.explicit_visible {
                evidence.native_video_receiver_dimensions_are_visible = true;
            }
        }
    }

    if let Some(receiver) = find_webrtc_native_video_receiver_frame(json.as_ref(), trimmed) {
        update_latest_metric(
            &mut evidence.native_video_receiver_frame,
            ObservedMetric {
                value: receiver,
                sequence,
                evidence: summary.clone(),
            },
        );
    }

    if is_webrtc_native_video_render_line(trimmed, json.as_ref()) {
        if let Some(render_frame) = find_webrtc_native_video_render_frame(json.as_ref(), trimmed) {
            update_latest_metric(
                &mut evidence.native_video_render_frame,
                ObservedMetric {
                    value: render_frame,
                    sequence,
                    evidence: summary.clone(),
                },
            );
        }
        if let Some(render_dimensions) =
            find_webrtc_native_video_render_dimensions(json.as_ref(), trimmed)
        {
            let should_update_dimensions = render_dimensions.explicit_visible
                || !evidence.native_video_render_dimensions_are_visible;
            if should_update_dimensions {
                update_latest_metric(
                    &mut evidence.native_video_render_dimensions,
                    ObservedMetric {
                        value: render_dimensions.dimensions,
                        sequence,
                        evidence: summary.clone(),
                    },
                );
                if render_dimensions.explicit_visible {
                    evidence.native_video_render_dimensions_are_visible = true;
                }
            }
        }
        if let Some(source) = find_webrtc_string_any(
            json.as_ref(),
            trimmed,
            &["nativeRenderEvidenceSource", "source"],
        ) {
            update_latest_metric(
                &mut evidence.native_video_render_source,
                ObservedMetric {
                    value: source,
                    sequence,
                    evidence: summary.clone(),
                },
            );
        }
    }

    if let Some(reason) = find_webrtc_strict_media_failure_reason(json.as_ref(), trimmed) {
        update_latest_metric(
            &mut evidence.strict_media_failure,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.clone(),
            },
        );
    }

    if is_stale_fallback_line(json.as_ref(), trimmed) {
        update_latest_metric(
            &mut evidence.stale_fallback,
            ObservedMetric {
                value: "stale_fallback".to_owned(),
                sequence,
                evidence: summary.clone(),
            },
        );
    }
    if let Some(reason) = find_webrtc_fallback_producer_failure_reason(json.as_ref(), trimmed) {
        update_latest_metric(
            &mut evidence.fallback_producer_failure,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.clone(),
            },
        );
    }
    if is_backpressure_line(json.as_ref(), trimmed) {
        update_latest_metric(
            &mut evidence.backpressure,
            ObservedMetric {
                value: "backpressure".to_owned(),
                sequence,
                evidence: summary,
            },
        );
    }
}

fn update_webrtc_gate_freshness_markers(
    evidence: &mut WebRtcMediaEvidence,
    line: &str,
    json: Option<&serde_json::Value>,
    observed_at: Option<OffsetDateTime>,
) {
    if observed_at.is_none() {
        return;
    }
    if is_webrtc_native_video_tx_line(line, json)
        || is_webrtc_sck_tx_telemetry_line(line, json)
        || line.contains("native-video-frame-source")
    {
        update_latest_time(&mut evidence.latest_video_evidence_at, observed_at);
    }
    if line.contains("native-receiver-frame")
        || line.contains("remote-video-stats")
        || line.contains("remote-video-frame-evidence")
        || line.contains("native-render-frame")
    {
        update_latest_time(&mut evidence.latest_receiver_evidence_at, observed_at);
    }
    if line.contains("audioTx") || line.contains("audio-tx") {
        update_latest_time(&mut evidence.latest_audio_tx_evidence_at, observed_at);
    }
    if line.contains("audioRx") || line.contains("audio-rx") || line.contains("renderedFrames") {
        update_latest_time(&mut evidence.latest_audio_rx_evidence_at, observed_at);
    }
}

fn update_latest_time(slot: &mut Option<OffsetDateTime>, observed_at: Option<OffsetDateTime>) {
    if let Some(observed_at) = observed_at
        && slot.is_none_or(|current| observed_at > current)
    {
        *slot = Some(observed_at);
    }
}

fn observe_webrtc_counter(
    observation: &mut CounterObservation,
    json: Option<&serde_json::Value>,
    text: &str,
    key: &str,
    sequence: usize,
    summary: &str,
) {
    let Some(value) = find_webrtc_u64(json, text, key) else {
        return;
    };
    let observed = ObservedMetric {
        value,
        sequence,
        evidence: summary.to_owned(),
    };
    if let Some(previous) = observation.latest.as_ref() {
        if observation.seen_positive && value < previous.value {
            update_latest_metric(&mut observation.decrease_after_positive, observed.clone());
        }
    }
    if value > 0 {
        if observation.first_positive.is_none() {
            observation.first_positive = Some(observed.clone());
        }
        observation.seen_positive = true;
        observation.positive_count = observation.positive_count.saturating_add(1);
        update_latest_metric(&mut observation.latest_positive, observed.clone());
    } else if observation.seen_positive {
        update_latest_metric(&mut observation.zero_after_positive, observed.clone());
    }
    update_latest_metric(&mut observation.latest, observed.clone());
    update_lowest_u64(&mut observation.lowest, observed);
}

fn is_webrtc_audio_rx_no_positive_placeholder(
    json: Option<&serde_json::Value>,
    text: &str,
) -> bool {
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    if !probable.contains("audio-rx-no-positive-evidence") {
        return false;
    }
    let source = find_webrtc_string(json, text, "source").unwrap_or_default();
    let is_heartbeat = source == "remote-heartbeat"
        || source == "smoke-heartbeat"
        || text.contains("source=remote-heartbeat")
        || text.contains("source=smoke-heartbeat");
    if !is_heartbeat {
        return false;
    }
    find_webrtc_u64(json, text, "audioRxRecv") == Some(0)
        && find_webrtc_u64(json, text, "audioRxDecoded") == Some(0)
        && find_webrtc_u64(json, text, "audioRxPlayed") == Some(0)
}

fn observe_webrtc_latest_f64_any(
    observation: &mut Option<ObservedMetric<f64>>,
    json: Option<&serde_json::Value>,
    text: &str,
    keys: &[&str],
    sequence: usize,
    summary: &str,
) {
    let Some(value) = find_webrtc_f64_any(json, text, keys) else {
        return;
    };
    update_latest_metric(
        observation,
        ObservedMetric {
            value,
            sequence,
            evidence: summary.to_owned(),
        },
    );
}

fn observe_webrtc_latest_string_any(
    observation: &mut Option<ObservedMetric<String>>,
    json: Option<&serde_json::Value>,
    text: &str,
    keys: &[&str],
    sequence: usize,
    summary: &str,
) {
    let Some(value) = find_webrtc_string_any(json, text, keys) else {
        return;
    };
    let value = value.trim();
    if value.is_empty() || value == "-" {
        return;
    }
    update_latest_metric(
        observation,
        ObservedMetric {
            value: value.to_owned(),
            sequence,
            evidence: summary.to_owned(),
        },
    );
}

fn observe_webrtc_audio_playout_pressure(
    evidence: &mut WebRtcMediaEvidence,
    json: Option<&serde_json::Value>,
    text: &str,
    sequence: usize,
    summary: &str,
) {
    let schedule_lead_ms = find_webrtc_f64(json, text, "scheduleLeadMs");
    if let Some(value) = schedule_lead_ms {
        update_lowest_f64(
            &mut evidence.audio_lowest_schedule_lead_ms,
            ObservedMetric {
                value,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    let arrival_p95_ms = find_webrtc_f64(json, text, "audioArrivalP95Ms");
    if let Some(value) = arrival_p95_ms {
        update_highest_f64(
            &mut evidence.audio_highest_arrival_p95_ms,
            ObservedMetric {
                value,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    let arrival_max_ms = find_webrtc_f64(json, text, "audioArrivalMaxMs");
    if let Some(value) = arrival_max_ms {
        update_highest_f64(
            &mut evidence.audio_highest_arrival_max_ms,
            ObservedMetric {
                value,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    let queued_ms = find_webrtc_f64(json, text, "audioQueuedMs")
        .or_else(|| find_webrtc_f64(json, text, "queuedMs"));
    let target_queued_ms = find_webrtc_f64(json, text, "audioTargetQueuedMs")
        .or_else(|| find_webrtc_f64(json, text, "targetQueuedMs"));
    let low_queue_threshold_ms = target_queued_ms
        .map(|value| (value * 0.25).clamp(180.0, 600.0))
        .unwrap_or(180.0);
    let queue_low_water = queued_ms
        .map(|value| value <= low_queue_threshold_ms)
        .unwrap_or(false);
    let jitter_late = find_webrtc_u64(json, text, "jitterLate").unwrap_or(0);
    let plc_frames = find_webrtc_u64(json, text, "plcFrames")
        .or_else(|| find_webrtc_u64(json, text, "plc"))
        .unwrap_or(0);
    let plc_ratio = find_webrtc_f64(json, text, "plcRatio");
    let mut failures = Vec::new();
    if let Some(value) = schedule_lead_ms
        && value <= WEBRTC_AUDIO_SCHEDULE_LEAD_HARD_MIN_MS
        && queue_low_water
    {
        let queue_detail = queued_ms
            .map(|queued| format!(" queuedMs={queued:.0} thresholdMs={low_queue_threshold_ms:.0}"))
            .unwrap_or_default();
        failures.push(format!("scheduleLeadMs={value:.0}{queue_detail}"));
    }
    let arrival_spike_with_playout_pressure = arrival_max_ms
        .map(|value| value >= WEBRTC_AUDIO_ARRIVAL_MAX_SPIKE_MS)
        .unwrap_or(false)
        && (queue_low_water
            || schedule_lead_ms.map(|lead| lead < 0.0).unwrap_or(false)
            || jitter_late > 0);
    if let Some(value) = arrival_max_ms
        && arrival_spike_with_playout_pressure
    {
        failures.push(format!("audioArrivalMaxMs={value:.0}"));
    }
    if let (Some(p95), Some(lead)) = (arrival_p95_ms, schedule_lead_ms)
        && p95 >= WEBRTC_AUDIO_ARRIVAL_P95_PRESSURE_MS
        && lead < 0.0
    {
        failures.push(format!(
            "audioArrivalP95Ms={p95:.0} scheduleLeadMs={lead:.0}"
        ));
    }
    if let Some(lead) = schedule_lead_ms
        && jitter_late > 0
        && lead < 0.0
    {
        failures.push(format!("jitterLate={jitter_late} scheduleLeadMs={lead:.0}"));
    }
    let timing_pressure = queue_low_water
        || arrival_spike_with_playout_pressure
        || matches!(
            (arrival_p95_ms, schedule_lead_ms),
            (Some(p95), Some(lead))
                if p95 >= WEBRTC_AUDIO_ARRIVAL_P95_PRESSURE_MS && lead < 0.0
        )
        || matches!(
            schedule_lead_ms,
            Some(lead) if jitter_late > 0 && lead < 0.0
        );
    if let Some(value) = plc_ratio {
        let sustained_plc_burst = plc_frames >= WEBRTC_AUDIO_PLC_BURST_FRAME_PRESSURE_MIN
            && value >= WEBRTC_AUDIO_PLC_BURST_RATIO_PRESSURE;
        let correlated_plc_pressure = plc_frames >= WEBRTC_AUDIO_PLC_FRAME_PRESSURE_MIN
            && value >= WEBRTC_AUDIO_PLC_RATIO_PRESSURE
            && timing_pressure;
        if sustained_plc_burst || correlated_plc_pressure {
            failures.push(format!("plcFrames={plc_frames} plcRatio={value:.3}"));
        }
    } else if plc_frames >= WEBRTC_AUDIO_PLC_BURST_FRAME_PRESSURE_MIN && timing_pressure {
        failures.push(format!("plcFrames={plc_frames}"));
    }

    if failures.is_empty() {
        return;
    }

    update_latest_metric(
        &mut evidence.audio_playout_pressure,
        ObservedMetric {
            value: failures.join(", "),
            sequence,
            evidence: summary.to_owned(),
        },
    );
}

fn parse_webrtc_diagnostic_timestamp(
    text: &str,
    json: Option<&serde_json::Value>,
) -> Option<OffsetDateTime> {
    if let Some(json) = json {
        for key in ["timestamp", "time", "ts", "date", "created_at", "createdAt"] {
            if let Some(value) = find_json_value(json, key).and_then(parse_json_timestamp_value) {
                return Some(value);
            }
        }
    }
    let timestamp = text.strip_prefix('[')?.split_once(']')?.0;
    OffsetDateTime::parse(timestamp, &time::format_description::well_known::Rfc3339).ok()
}

fn parse_json_timestamp_value(value: &serde_json::Value) -> Option<OffsetDateTime> {
    if let Some(value) = value.as_str() {
        return OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339).ok();
    }
    let value = value.as_i64()?;
    let seconds = if value > 10_000_000_000 {
        value / 1000
    } else {
        value
    };
    OffsetDateTime::from_unix_timestamp(seconds).ok()
}

fn is_webrtc_diagnostic_recent(
    timestamp: OffsetDateTime,
    since_seconds: u64,
    now: OffsetDateTime,
) -> bool {
    if timestamp > now {
        return true;
    }
    let since_seconds = i64::try_from(since_seconds).unwrap_or(i64::MAX);
    now - timestamp <= time::Duration::seconds(since_seconds)
}

fn webrtc_line_matches_session(
    text: &str,
    json: Option<&serde_json::Value>,
    session_id: &str,
) -> bool {
    if let Some(json) = json {
        for key in ["session", "sessionId", "session_id"] {
            if find_json_value(json, key)
                .and_then(json_value_to_string)
                .is_some_and(|value| value == session_id)
            {
                return true;
            }
        }
    }
    extract_text_value(text, "session").is_some_and(|value| value == session_id)
}

fn is_webrtc_stream_stats_line(text: &str, json: Option<&serde_json::Value>) -> bool {
    text.contains("stream-stats")
        || text.contains("WebRTC 屏幕推流吞吐")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| {
                event == "stream-stats" || event == "webrtc.stream_stats" || event == "videoStats"
            })
}

fn is_webrtc_native_video_tx_line(text: &str, json: Option<&serde_json::Value>) -> bool {
    text.contains("native-video-tx")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| event == "native-video-tx" || event == "nativeVideoTx")
}

fn is_webrtc_sck_tx_telemetry_line(text: &str, json: Option<&serde_json::Value>) -> bool {
    text.contains("sckTxTelemetry")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| event == "sckTxTelemetry")
}

fn is_webrtc_native_video_receiver_line(text: &str, json: Option<&serde_json::Value>) -> bool {
    text.contains("native-receiver-frame")
        || text.contains("remote-video-frame-evidence")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| {
                matches!(
                    event.as_str(),
                    "native-receiver-frame"
                        | "nativeReceiverFrame"
                        | "remote-video-frame-evidence"
                        | "remoteVideoFrameEvidence"
                )
            })
}

fn is_webrtc_native_video_render_line(text: &str, json: Option<&serde_json::Value>) -> bool {
    text.contains("native-render-frame")
        || text.contains("nativeRenderEvidenceSource=rtc-mtl-video-view")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| {
                matches!(
                    event.as_str(),
                    "native-render-frame" | "nativeRenderFrame" | "visibleNativeRender"
                )
            })
}

fn find_webrtc_native_video_render_frame(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    if !is_webrtc_native_video_render_line(text, json) {
        return None;
    }
    let source = find_webrtc_string(json, text, "nativeRenderEvidenceSource")
        .or_else(|| find_webrtc_string(json, text, "source"))
        .unwrap_or_else(|| "-".to_owned());
    if source != "rtc-mtl-video-view" {
        return None;
    }
    let size = find_webrtc_string(json, text, "size").unwrap_or_else(|| "-".to_owned());
    let visible_size = find_webrtc_string(json, text, "visibleSize")
        .or_else(|| find_webrtc_string(json, text, "visibleFrame"))
        .unwrap_or_else(|| size.clone());
    let coded_size = find_webrtc_string(json, text, "codedSize")
        .or_else(|| find_webrtc_string(json, text, "codedFrame"))
        .unwrap_or_else(|| size.clone());
    let native_promotion_state =
        find_webrtc_string(json, text, "nativePromotionState").unwrap_or_else(|| "-".to_owned());
    Some(format!(
        "source={source} size={size} visibleSize={visible_size} codedSize={coded_size} nativePromotionState={native_promotion_state}"
    ))
}

fn find_webrtc_native_video_render_dimensions(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<ReceiverVideoDimensions> {
    if !is_webrtc_native_video_render_line(text, json) {
        return None;
    }
    if let Some(value) = find_webrtc_string(json, text, "visibleSize")
        .or_else(|| find_webrtc_string(json, text, "visibleFrame"))
        && let Some(dimensions) = parse_webrtc_video_dimensions(&value)
    {
        return Some(ReceiverVideoDimensions {
            dimensions,
            explicit_visible: true,
        });
    }
    find_webrtc_video_dimensions(json, text).map(|dimensions| ReceiverVideoDimensions {
        dimensions,
        explicit_visible: false,
    })
}

fn find_webrtc_native_video_receiver_frame(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    if !is_webrtc_native_video_receiver_line(text, json) {
        return None;
    }

    let frames_decoded = find_webrtc_u64(json, text, "framesDecoded").unwrap_or(0);
    let frames_received = find_webrtc_u64(json, text, "framesReceived").unwrap_or(0);
    let packets = find_webrtc_u64(json, text, "packets")
        .or_else(|| find_webrtc_u64(json, text, "packetsReceived"))
        .unwrap_or(0);
    let bytes = find_webrtc_u64(json, text, "bytes")
        .or_else(|| find_webrtc_u64(json, text, "bytesReceived"))
        .unwrap_or(0);
    let size = find_webrtc_string(json, text, "size").unwrap_or_else(|| "-".to_owned());
    let visible_size = find_webrtc_string(json, text, "visibleSize")
        .or_else(|| find_webrtc_string(json, text, "visibleFrame"))
        .unwrap_or_else(|| size.clone());
    let coded_size = find_webrtc_string(json, text, "codedSize")
        .or_else(|| find_webrtc_string(json, text, "codedFrame"))
        .unwrap_or_else(|| size.clone());
    let source = find_webrtc_string(json, text, "source").unwrap_or_else(|| "-".to_owned());
    if frames_decoded > 0 || frames_received > 0 || (packets > 0 && bytes > 0) {
        return Some(format!(
            "source={source} size={size} visibleSize={visible_size} codedSize={coded_size} packets={packets} bytes={bytes} framesReceived={frames_received} framesDecoded={frames_decoded}"
        ));
    }
    None
}

fn find_webrtc_native_video_receiver_dimensions(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<ReceiverVideoDimensions> {
    if let Some(value) = find_webrtc_string(json, text, "visibleSize")
        .or_else(|| find_webrtc_string(json, text, "visibleFrame"))
        && let Some(dimensions) = parse_webrtc_video_dimensions(&value)
    {
        return Some(ReceiverVideoDimensions {
            dimensions,
            explicit_visible: true,
        });
    }

    find_webrtc_video_dimensions(json, text).map(|dimensions| ReceiverVideoDimensions {
        dimensions,
        explicit_visible: false,
    })
}

fn find_webrtc_video_dimensions(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<VideoDimensions> {
    if let (Some(width), Some(height)) = (
        find_webrtc_u64(json, text, "width"),
        find_webrtc_u64(json, text, "height"),
    ) {
        return video_dimensions_from_u64(width, height);
    }

    for key in [
        "visibleSize",
        "visibleFrame",
        "size",
        "frame",
        "lastFrame",
        "encodeSize",
        "target",
    ] {
        if let Some(value) = find_webrtc_string(json, text, key)
            && let Some(dimensions) = parse_webrtc_video_dimensions(&value)
        {
            return Some(dimensions);
        }
    }
    None
}

fn parse_webrtc_video_dimensions(value: &str) -> Option<VideoDimensions> {
    let size = value.split_once('@').map_or(value, |(size, _)| size).trim();
    let (width, height) = size.split_once('x').or_else(|| size.split_once('X'))?;
    let width = width
        .trim()
        .trim_matches(|value: char| !value.is_ascii_digit())
        .parse::<u64>()
        .ok()?;
    let height = height
        .trim()
        .trim_matches(|value: char| !value.is_ascii_digit())
        .parse::<u64>()
        .ok()?;
    video_dimensions_from_u64(width, height)
}

fn video_dimensions_from_u64(width: u64, height: u64) -> Option<VideoDimensions> {
    if width == 0 || height == 0 || width > u32::MAX as u64 || height > u32::MAX as u64 {
        return None;
    }
    Some(VideoDimensions {
        width: width as u32,
        height: height as u32,
    })
}

fn find_webrtc_native_video_state(json: Option<&serde_json::Value>, text: &str) -> Option<String> {
    if let Some(json) = json
        && let Some(state) = find_json_value(json, "nativeVideoHealth")
            .and_then(json_value_to_string)
            .or_else(|| find_json_value(json, "native_video_health").and_then(json_value_to_string))
    {
        return Some(state);
    }
    let native_video_line = text.contains("native-video-health")
        || text.contains("native-video-tx")
        || text.contains("nativeVideoHealth");
    if !native_video_line {
        return None;
    }
    extract_text_value(text, "nativeVideoHealth").or_else(|| extract_text_value(text, "state"))
}

fn is_native_video_failure_state(state: &str) -> bool {
    matches!(state, "failedNoRTP" | "senderZero")
}

fn find_webrtc_strict_media_failure_reason(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let event = json
        .and_then(|json| {
            find_json_value(json, "event")
                .or_else(|| find_json_value(json, "name"))
                .or_else(|| find_json_value(json, "kind"))
                .and_then(json_value_to_string)
        })
        .unwrap_or_default();
    let matched = text.contains("strict-media-failed")
        || matches!(
            event.as_str(),
            "strict-media-failed"
                | "strictMediaFailed"
                | "strict-media-failure"
                | "strictMediaFailure"
        );
    if !matched {
        return None;
    }
    Some(
        find_webrtc_string(json, text, "reason")
            .or_else(|| find_webrtc_string(json, text, "failureReason"))
            .or_else(|| find_webrtc_string(json, text, "failure_reason"))
            .or_else(|| find_webrtc_string(json, text, "probable"))
            .unwrap_or_else(|| "strict-media-failed".to_owned()),
    )
}

fn find_webrtc_audio_tx_missing_endpoint_reason(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let reason = find_webrtc_string(json, text, "reason").unwrap_or_default();
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    if text.contains("audioTxUnavailable")
        && (reason == "missingViewerEndpoint" || text.contains("missingViewerEndpoint"))
    {
        return Some("missingViewerEndpoint".to_owned());
    }
    if probable.contains("missingViewerEndpoint") || probable.contains("missing-viewer-endpoint") {
        return Some(probable);
    }
    None
}

fn find_webrtc_audio_tx_relay_failure_reason(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let reason = find_webrtc_string(json, text, "reason").unwrap_or_default();
    let detail = find_webrtc_string(json, text, "detail").unwrap_or_default();
    let error = find_webrtc_string(json, text, "error").unwrap_or_default();
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    let lower = text.to_lowercase();
    let has_tx_prefix = text.contains("audioTxUnavailable")
        || text.contains("audioTxRelay")
        || text.contains("audioTxEndpointReady");
    if !has_tx_prefix {
        return None;
    }
    if reason == "missingViewerEndpoint" {
        return None;
    }
    if reason == "relayUnavailable"
        && (detail.contains("timed out")
            || error.contains("timed out")
            || lower.contains("timed out"))
    {
        return Some("relayBindTimedOut".to_owned());
    }
    if reason == "leaseLimit" || lower.contains("media_admission_token_lease_limit") {
        return Some("leaseLimit".to_owned());
    }
    if reason == "relayBindTimedOut" || lower.contains("relaybindtimedout") {
        return Some("relayBindTimedOut".to_owned());
    }
    if reason == "relayBindRejected" || lower.contains("relaybindrejected") {
        return Some(if error.is_empty() {
            "relayBindRejected".to_owned()
        } else {
            format!("relayBindRejected:{error}")
        });
    }
    if reason == "relayBindMalformed" || lower.contains("relaybindmalformed") {
        return Some("relayBindMalformed".to_owned());
    }
    if matches!(
        probable.as_str(),
        "relay-bind-sent"
            | "relay-bind-ack-pending-media-optimistic"
            | "relay-lease-renewed-in-place"
    ) {
        return None;
    }
    if probable.contains("relay-bind")
        && (probable.contains("timed-out")
            || probable.contains("timeout")
            || probable.contains("rejected")
            || probable.contains("malformed")
            || probable.contains("failed"))
    {
        return Some(probable);
    }
    if probable.contains("relayUnavailable") {
        return Some(probable);
    }
    None
}

fn find_webrtc_audio_tx_relay_bind_pending_reason(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let kind = find_webrtc_string(json, text, "kind").unwrap_or_default();
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    if kind == "audioTxRelayBindAckPending"
        || text.contains("audioTxRelayBindAckPending")
        || probable == "relay-bind-ack-pending-media-optimistic"
    {
        return Some("relayBindAckPending".to_owned());
    }
    None
}

fn find_webrtc_audio_rx_relay_bind_failure(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let kind = find_webrtc_string(json, text, "kind").unwrap_or_default();
    let stage = find_webrtc_string(json, text, "stage").unwrap_or_default();
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    let reason = find_webrtc_string(json, text, "reason").unwrap_or_default();
    let kind_lower = kind.to_ascii_lowercase();
    let text_lower = text.to_ascii_lowercase();
    let receiver_context = kind_lower.starts_with("audiorx")
        || text_lower.contains("audio-rx")
        || text_lower.contains("audiorx")
        || text.contains("receiverStartFailed");
    let sender_context = kind_lower.starts_with("audiotx")
        || text_lower.contains("audio-tx")
        || text_lower.contains("audiotx");
    if sender_context && !receiver_context {
        return None;
    }
    if text.contains("relayBindAckTimedOut") || stage == "relayBindAckTimedOut" {
        return Some("relayBindAckTimedOut".to_owned());
    }
    if text.contains("relayBindRejected") || stage == "relayBindRejected" {
        return Some(if reason.is_empty() {
            "relayBindRejected".to_owned()
        } else {
            format!("relayBindRejected:{reason}")
        });
    }
    if text.contains("relayBindMalformed") || stage == "relayBindMalformed" {
        return Some("relayBindMalformed".to_owned());
    }
    if text.contains("receiverStartFailed")
        && (text.contains("stage=udpBind")
            || text.contains("stage=relayBindAck")
            || text.contains("stage=udpConnection"))
    {
        return Some(
            extract_text_value(text, "stage")
                .map(|stage| format!("receiverStartFailed:{stage}"))
                .unwrap_or_else(|| "receiverStartFailed:relayBind".to_owned()),
        );
    }
    if receiver_context
        && (probable.contains("public-udp-relay-unreachable")
            || probable.contains("wrong-port")
            || probable.contains("relay-bind"))
    {
        return Some(probable);
    }
    None
}

fn find_webrtc_fallback_producer_failure_reason(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let fallback_producer = find_webrtc_string(json, text, "fallbackProducer")
        .or_else(|| find_webrtc_string(json, text, "producer"))
        .unwrap_or_default();
    let reason = find_webrtc_string(json, text, "reason").unwrap_or_default();
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    let lower = text.to_lowercase();
    if fallback_producer == "cgdisplayEmergency"
        && (reason.contains("stale") || lower.contains("sck latest fallback stale"))
    {
        return Some("cgdisplayEmergency".to_owned());
    }
    if lower.contains("video_fps")
        && find_webrtc_f64_any(json, text, &["video_fps", "fps", "videoFPS"])
            .is_some_and(|fps| fps <= 2.0)
    {
        return Some("lowFPS".to_owned());
    }
    if probable.contains("capture") || probable.contains("encoder-no-output") {
        return Some(probable);
    }
    None
}

fn is_stale_fallback_line(json: Option<&serde_json::Value>, text: &str) -> bool {
    let reason = find_webrtc_string(json, text, "reason").unwrap_or_default();
    let producer = find_webrtc_string(json, text, "producer")
        .or_else(|| find_webrtc_string(json, text, "fallbackProducer"))
        .unwrap_or_default();
    let fallback_line =
        text.contains("fallback") || text.contains("Fallback") || text.contains("producer");
    text.contains("stream-native-warmup-fallback-main")
        || text.contains("SCK latest fallback stale")
        || (fallback_line && reason.contains("stale"))
        || (producer == "cgdisplayEmergency"
            && (reason.contains("stale") || text.contains("sckLatestAgeMs=-")))
}

fn is_backpressure_line(json: Option<&serde_json::Value>, text: &str) -> bool {
    let drop_reason = find_webrtc_string(json, text, "dropReason").unwrap_or_default();
    let chunk_drop_reason = find_webrtc_string(json, text, "chunkDropReason").unwrap_or_default();
    text.contains("stream-backpressure")
        || drop_reason == "backpressure"
        || chunk_drop_reason.contains("backpressure")
        || find_webrtc_u64(json, text, "droppedBackpressure").is_some_and(|value| value > 0)
}

fn find_webrtc_f64(json: Option<&serde_json::Value>, text: &str, key: &str) -> Option<f64> {
    json.and_then(|json| find_json_value(json, key).and_then(json_value_to_f64))
        .or_else(|| extract_text_f64(text, key))
}

fn find_webrtc_f64_any(json: Option<&serde_json::Value>, text: &str, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|key| find_webrtc_f64(json, text, key))
}

fn find_webrtc_string_any(
    json: Option<&serde_json::Value>,
    text: &str,
    keys: &[&str],
) -> Option<String> {
    keys.iter()
        .find_map(|key| find_webrtc_string(json, text, key))
}

fn find_webrtc_u64(json: Option<&serde_json::Value>, text: &str, key: &str) -> Option<u64> {
    json.and_then(|json| find_json_value(json, key).and_then(json_value_to_u64))
        .or_else(|| extract_text_u64(text, key))
}

fn find_webrtc_string(json: Option<&serde_json::Value>, text: &str, key: &str) -> Option<String> {
    json.and_then(|json| find_json_value(json, key).and_then(json_value_to_string))
        .or_else(|| extract_text_value(text, key))
}

fn find_json_value<'a>(value: &'a serde_json::Value, key: &str) -> Option<&'a serde_json::Value> {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(value) = map.get(key) {
                return Some(value);
            }
            map.values().find_map(|child| find_json_value(child, key))
        }
        serde_json::Value::Array(items) => {
            items.iter().find_map(|child| find_json_value(child, key))
        }
        _ => None,
    }
}

fn json_value_to_string(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(value) => Some(value.clone()),
        serde_json::Value::Number(value) => Some(value.to_string()),
        serde_json::Value::Bool(value) => Some(value.to_string()),
        _ => None,
    }
}

fn json_value_to_f64(value: &serde_json::Value) -> Option<f64> {
    match value {
        serde_json::Value::Number(value) => value.as_f64(),
        serde_json::Value::String(value) => value.parse::<f64>().ok(),
        _ => None,
    }
}

fn json_value_to_u64(value: &serde_json::Value) -> Option<u64> {
    match value {
        serde_json::Value::Number(value) => value.as_u64(),
        serde_json::Value::String(value) => value.parse::<u64>().ok(),
        _ => None,
    }
}

fn extract_text_value(text: &str, key: &str) -> Option<String> {
    let needle = format!("{key}=");
    let start = text.find(&needle)? + needle.len();
    let token = text[start..]
        .chars()
        .take_while(|value| !value.is_whitespace() && !matches!(value, ',' | '}' | ']' | ')' | '"'))
        .collect::<String>();
    let token = token.trim_matches(|value| value == '"' || value == '\'');
    if token.is_empty() {
        None
    } else {
        Some(token.to_owned())
    }
}

fn extract_text_f64(text: &str, key: &str) -> Option<f64> {
    extract_text_value(text, key).and_then(|value| value.trim_end_matches('%').parse().ok())
}

fn extract_text_u64(text: &str, key: &str) -> Option<u64> {
    extract_text_value(text, key).and_then(|value| value.parse().ok())
}

fn update_latest_metric<T>(slot: &mut Option<ObservedMetric<T>>, observed: ObservedMetric<T>) {
    if slot
        .as_ref()
        .is_none_or(|current| observed.sequence >= current.sequence)
    {
        *slot = Some(observed);
    }
}

fn update_lowest_f64(slot: &mut Option<ObservedMetric<f64>>, observed: ObservedMetric<f64>) {
    if slot
        .as_ref()
        .is_none_or(|current| observed.value < current.value)
    {
        *slot = Some(observed);
    }
}

fn update_highest_f64(slot: &mut Option<ObservedMetric<f64>>, observed: ObservedMetric<f64>) {
    if slot
        .as_ref()
        .is_none_or(|current| observed.value > current.value)
    {
        *slot = Some(observed);
    }
}

fn update_lowest_u64(slot: &mut Option<ObservedMetric<u64>>, observed: ObservedMetric<u64>) {
    if slot
        .as_ref()
        .is_none_or(|current| observed.value < current.value)
    {
        *slot = Some(observed);
    }
}

fn summarize_webrtc_evidence_line(source: &Path, line_number: usize, line: &str) -> String {
    let file_name = source
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("log");
    let redacted = redact_sensitive_log_fragment(line);
    let summary = redacted.chars().take(180).collect::<String>();
    format!("{file_name}:{line_number} {summary}")
}

fn redact_sensitive_log_fragment(line: &str) -> String {
    if let Ok(mut value) = serde_json::from_str::<serde_json::Value>(line) {
        redact_sensitive_json_value(&mut value);
        return serde_json::to_string(&value).unwrap_or_else(|_| "<redacted-json>".to_owned());
    }

    let mut redacted = Vec::new();
    let mut redact_next = false;
    for part in line.split_whitespace() {
        if redact_next {
            redacted.push("<redacted>".to_owned());
            redact_next = false;
            continue;
        }
        let (part, next_is_sensitive) = redact_sensitive_log_part(part);
        redacted.push(part);
        redact_next = next_is_sensitive;
    }
    redacted.join(" ")
}

fn redact_sensitive_json_value(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(object) => {
            for (key, value) in object.iter_mut() {
                if is_sensitive_log_key(key) {
                    *value = serde_json::Value::String("<redacted>".to_owned());
                } else {
                    redact_sensitive_json_value(value);
                }
            }
        }
        serde_json::Value::Array(values) => {
            for value in values {
                redact_sensitive_json_value(value);
            }
        }
        _ => {}
    }
}

fn redact_sensitive_log_part(part: &str) -> (String, bool) {
    if let Some((key, value)) = part.split_once('=') {
        if is_sensitive_log_key(key) {
            let redact_next = value.eq_ignore_ascii_case("bearer");
            return (format!("{key}=<redacted>"), redact_next);
        }
    }
    if let Some((key, value)) = part.split_once(':')
        && is_sensitive_log_key(key)
        && !key.contains('/')
    {
        let redact_next = value.eq_ignore_ascii_case("bearer");
        return (format!("{key}:<redacted>"), redact_next);
    }
    (part.to_owned(), false)
}

fn is_sensitive_log_key(key: &str) -> bool {
    let normalized = key
        .trim_matches(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_' && ch != '-')
        .to_ascii_lowercase();
    normalized.contains("token")
        || normalized.contains("authorization")
        || normalized.contains("jwt")
        || normalized.contains("secret")
        || normalized.contains("password")
        || normalized.contains("credential")
        || normalized.contains("cookie")
        || normalized.contains("api_key")
        || normalized.contains("apikey")
}

fn describe_webrtc_sources(evidence: &WebRtcMediaEvidence) -> String {
    if evidence.read_sources.is_empty() {
        return "none".to_owned();
    }
    evidence
        .read_sources
        .iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>()
        .join(",")
}

fn check_webrtc_media_sources(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    let ok = !evidence.read_sources.is_empty() && evidence.read_errors.is_empty();
    let severity = if evidence.read_sources.is_empty() {
        "error"
    } else if evidence.read_errors.is_empty() {
        "info"
    } else {
        "warn"
    };
    DoctorCheck {
        name: "diagnostic_sources",
        ok,
        severity,
        detail: if evidence.read_errors.is_empty() {
            format!("read {} diagnostic source(s)", evidence.read_sources.len())
        } else {
            format!(
                "read {} diagnostic source(s); {} source/read error(s): {}",
                evidence.read_sources.len(),
                evidence.read_errors.len(),
                evidence.read_errors.join("; ")
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_media_samples(
    evidence: &WebRtcMediaEvidence,
    session_id: &str,
    since_seconds: u64,
) -> DoctorCheck {
    let ok = evidence.matched_lines > 0;
    DoctorCheck {
        name: "diagnostic_samples",
        ok,
        severity: if ok { "info" } else { "warn" },
        detail: if ok {
            match evidence.latest_at {
                Some(timestamp) => format!(
                    "matched {} diagnostics for session {session_id}; latest timestamp {timestamp}",
                    evidence.matched_lines
                ),
                None => format!(
                    "matched {} diagnostics for session {session_id}; lines had no parseable timestamp",
                    evidence.matched_lines
                ),
            }
        } else {
            format!("no diagnostics matched session {session_id} within the last {since_seconds}s")
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_media_fps(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
    require_audio: bool,
    strict_fps_floor: bool,
) -> DoctorCheck {
    let has_native_video_evidence = evidence.native_video_state.is_some()
        || evidence.native_video_submitted.latest.is_some()
        || evidence.native_video_frames_encoded.latest.is_some()
        || evidence.native_video_frames_sent.latest.is_some()
        || evidence.native_video_packets_sent.latest.is_some()
        || evidence.native_video_bytes_sent.latest.is_some()
        || evidence.native_video_encode_fps.is_some();
    if strict_fps_floor && min_fps >= 30.0 {
        if has_native_video_evidence {
            return check_webrtc_native_video_encode_fps_floor(evidence, min_fps, true);
        }
        return DoctorCheck {
            name: "video_fps",
            ok: false,
            severity: "error",
            detail: format!(
                "strict native RTP fps floor failed: no native RTP video evidence was observed; min={min_fps:.1}"
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    if !require_audio
        && webrtc_native_video_rtp_is_flowing(evidence)
        && evidence.latest_fps.is_none()
    {
        return check_webrtc_native_video_encode_fps_floor(evidence, min_fps, false);
    }
    let Some(lowest) = evidence.lowest_fps.as_ref() else {
        return webrtc_missing_observation_check(
            "video_fps",
            "no native RTP encodeFPS or stream-stats fps sample was observed for this session",
        );
    };
    let latest_value = evidence
        .latest_fps
        .as_ref()
        .map(|value| value.value)
        .unwrap_or(lowest.value);
    let latest = format!("{latest_value:.1}");
    let ok = lowest.value > 2.0
        && latest_value >= min_fps
        && (!strict_fps_floor || lowest.value >= min_fps);
    DoctorCheck {
        name: "video_fps",
        ok,
        severity: if ok {
            "info"
        } else if lowest.value <= 2.0 {
            "error"
        } else {
            "warn"
        },
        detail: if ok {
            if lowest.value >= min_fps {
                format!(
                    "lowest recent fps {:.1} meets min {:.1}; latest fps {latest}",
                    lowest.value, min_fps
                )
            } else {
                format!(
                    "latest fps {latest} meets min {:.1}; lowest transient fps {:.1}; evidence {}",
                    min_fps, lowest.value, lowest.evidence
                )
            }
        } else if lowest.value <= 2.0 {
            format!(
                "critically low fps {:.1} (<=2.0); latest fps {latest}; evidence {}",
                lowest.value, lowest.evidence
            )
        } else if strict_fps_floor && lowest.value < min_fps {
            format!(
                "strict fps floor failed: lowest recent fps {:.1} below min {:.1}; latest fps {latest}; evidence {}",
                lowest.value, min_fps, lowest.evidence
            )
        } else {
            format!(
                "fps {:.1} below min {:.1}; latest fps {latest}; evidence {}",
                lowest.value, min_fps, lowest.evidence
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_native_video_encode_fps_floor(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
    strict_fps_floor: bool,
) -> DoctorCheck {
    if webrtc_native_video_rtp_is_flowing(evidence) {
        let submitted = latest_counter_value(&evidence.native_video_submitted).unwrap_or(0);
        let frames_encoded =
            latest_counter_value(&evidence.native_video_frames_encoded).unwrap_or(0);
        let frames_sent = latest_counter_value(&evidence.native_video_frames_sent).unwrap_or(0);
        let packets_sent = latest_counter_value(&evidence.native_video_packets_sent).unwrap_or(0);
        let bytes_sent = latest_counter_value(&evidence.native_video_bytes_sent).unwrap_or(0);
        let state = evidence
            .native_video_state
            .as_ref()
            .map(|state| state.value.as_str())
            .unwrap_or("-");
        let Some(native_latest) = evidence.native_video_encode_fps.as_ref() else {
            let hard_native_fps_gate = strict_fps_floor || min_fps >= 59.0;
            return DoctorCheck {
                name: "video_fps",
                ok: !hard_native_fps_gate,
                severity: if hard_native_fps_gate {
                    "error"
                } else {
                    "info"
                },
                detail: format!(
                    "native RTP is flowing without stream-stats or encodeFPS sample; min={min_fps:.1} state={state} submitted={submitted} framesEncoded={frames_encoded} framesSent={frames_sent} packetsSent={packets_sent} bytesSent={bytes_sent}"
                ),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            };
        };
        let native_lowest = evidence
            .native_video_lowest_encode_fps
            .as_ref()
            .unwrap_or(native_latest);
        let ok = native_lowest.value > 2.0
            && native_latest.value >= min_fps
            && (!strict_fps_floor || native_lowest.value >= min_fps);
        return DoctorCheck {
            name: "video_fps",
            ok,
            severity: if ok {
                "info"
            } else if native_lowest.value <= 2.0 {
                "error"
            } else {
                "warn"
            },
            detail: if ok {
                format!(
                    "native RTP encodeFPS meets min {min_fps:.1}; lowest {:.1} latest {:.1} state={state} submitted={submitted} framesEncoded={frames_encoded} framesSent={frames_sent} packetsSent={packets_sent} bytesSent={bytes_sent}",
                    native_lowest.value, native_latest.value
                )
            } else if strict_fps_floor && native_lowest.value < min_fps {
                format!(
                    "strict native RTP encodeFPS floor failed: lowest {:.1} below min {min_fps:.1}; latest {:.1}; evidence {}",
                    native_lowest.value, native_latest.value, native_lowest.evidence
                )
            } else {
                format!(
                    "native RTP encodeFPS {:.1} below min {min_fps:.1}; lowest {:.1}; evidence {}",
                    native_latest.value, native_lowest.value, native_latest.evidence
                )
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    let state = evidence
        .native_video_state
        .as_ref()
        .map(|state| state.value.as_str())
        .unwrap_or("-");
    DoctorCheck {
        name: "video_fps",
        ok: false,
        severity: "error",
        detail: format!(
            "native RTP was observed but is not flowing; min={min_fps:.1} state={state} submitted={} framesSent={} packetsSent={} bytesSent={}",
            latest_counter_value(&evidence.native_video_submitted).unwrap_or(0),
            latest_counter_value(&evidence.native_video_frames_sent).unwrap_or(0),
            latest_counter_value(&evidence.native_video_packets_sent).unwrap_or(0),
            latest_counter_value(&evidence.native_video_bytes_sent).unwrap_or(0)
        ),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_video_resolution(
    evidence: &WebRtcMediaEvidence,
    min_width: u32,
    min_height: u32,
    exact_video_size: bool,
) -> DoctorCheck {
    let Some(observed) = evidence.native_video_receiver_dimensions.as_ref() else {
        let mode = if exact_video_size {
            "exactly"
        } else {
            "at least"
        };
        return DoctorCheck {
            name: "video_resolution",
            ok: false,
            severity: "error",
            detail: format!(
                "no iOS native receiver dimensions were observed; required {mode} {min_width}x{min_height}"
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    };
    let dimensions = observed.value;
    let dimensions_match = dimensions.width == min_width && dimensions.height == min_height;
    let ok = if exact_video_size {
        dimensions_match && evidence.native_video_receiver_dimensions_are_visible
    } else {
        dimensions.width >= min_width && dimensions.height >= min_height
    };
    DoctorCheck {
        name: "video_resolution",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: if ok && exact_video_size {
            format!(
                "iOS visible receiver dimensions {}x{} match exact target {}x{}",
                dimensions.width, dimensions.height, min_width, min_height
            )
        } else if exact_video_size
            && dimensions_match
            && !evidence.native_video_receiver_dimensions_are_visible
        {
            format!(
                "iOS receiver dimensions {}x{} match exact target {}x{} but were not reported as explicit visible dimensions; evidence {}",
                dimensions.width, dimensions.height, min_width, min_height, observed.evidence
            )
        } else if ok {
            format!(
                "iOS receiver dimensions {}x{} meet minimum {}x{}",
                dimensions.width, dimensions.height, min_width, min_height
            )
        } else if exact_video_size {
            format!(
                "iOS receiver dimensions {}x{} do not match exact target {}x{}; evidence {}",
                dimensions.width, dimensions.height, min_width, min_height, observed.evidence
            )
        } else {
            format!(
                "iOS receiver dimensions {}x{} below minimum {}x{}; evidence {}",
                dimensions.width, dimensions.height, min_width, min_height, observed.evidence
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn webrtc_native_video_rtp_is_flowing(evidence: &WebRtcMediaEvidence) -> bool {
    let state_flowing = evidence
        .native_video_state
        .as_ref()
        .is_some_and(|state| matches!(state.value.as_str(), "rtpFlowing" | "rendered" | "active"));
    let submitted =
        latest_counter_value(&evidence.native_video_submitted).is_some_and(|value| value > 0);
    let media_sent = latest_counter_value(&evidence.native_video_frames_sent)
        .is_some_and(|value| value > 0)
        || latest_counter_value(&evidence.native_video_packets_sent).is_some_and(|value| value > 0)
        || latest_counter_value(&evidence.native_video_bytes_sent).is_some_and(|value| value > 0);
    state_flowing && submitted && media_sent
}

fn check_webrtc_media_counter(
    name: &'static str,
    label: &str,
    observation: &CounterObservation,
) -> DoctorCheck {
    let Some(latest_metric) = observation.latest.as_ref() else {
        return webrtc_missing_observation_check(
            name,
            &format!("{label} was not observed for this session"),
        );
    };
    let latest = latest_metric.value.to_string();
    let ok = latest_metric.value > 0
        || (observation.seen_positive && observation.zero_after_positive.is_none());
    let zero_after_positive = observation.zero_after_positive.as_ref();
    DoctorCheck {
        name,
        ok: ok && zero_after_positive.is_none(),
        severity: if ok && zero_after_positive.is_none() {
            "info"
        } else {
            "error"
        },
        detail: if let Some(zero_after_positive) = zero_after_positive {
            format!(
                "{label} fell to zero after prior positive traffic; latest {latest}; evidence {}",
                zero_after_positive.evidence
            )
        } else if ok {
            format!("{label} stayed above zero; latest {latest}")
        } else {
            format!(
                "{label} has no positive observation; latest {latest}; evidence {}",
                latest_metric.evidence
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_rendered_frames_counter(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    let observation = &evidence.audio_rendered_frames;
    let Some(latest_metric) = observation.latest.as_ref() else {
        return webrtc_missing_observation_check(
            "audio_rendered_frames",
            "renderedFrames was not observed for this session",
        );
    };
    let latest = latest_metric.value.to_string();
    let ok = observation.seen_positive;
    DoctorCheck {
        name: "audio_rendered_frames",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: if ok {
            let positive = observation
                .latest_positive
                .as_ref()
                .map(|metric| metric.value.to_string())
                .unwrap_or_else(|| "unknown".to_owned());
            format!(
                "renderedFrames observed positive playback frames; latest {latest}; latest positive {positive}"
            )
        } else {
            format!(
                "renderedFrames has no positive observation; latest {latest}; evidence {}",
                latest_metric.evidence
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn webrtc_counter_has_continuity(
    window: &CounterObservation,
    total: Option<&CounterObservation>,
) -> bool {
    describe_webrtc_counter_continuity("counter", window, total).is_none()
}

fn webrtc_rendered_frames_have_continuity(evidence: &WebRtcMediaEvidence) -> bool {
    describe_webrtc_rendered_frames_continuity(evidence).is_none()
}

fn describe_webrtc_counter_continuity(
    label: &str,
    window: &CounterObservation,
    total: Option<&CounterObservation>,
) -> Option<String> {
    if let Some(total) = total {
        if let (Some(first), Some(latest)) = (
            total.first_positive.as_ref(),
            total.latest_positive.as_ref(),
        ) {
            if latest.sequence > first.sequence && latest.value > first.value {
                return None;
            }
        }
    }

    if window.positive_count >= 2 && window.zero_after_positive.is_none() {
        return None;
    }

    if let Some(total) = total
        && let Some(decrease) = total.decrease_after_positive.as_ref()
    {
        return Some(format!(
            "{label} total decreased after positive traffic; evidence {}",
            decrease.evidence
        ));
    }

    if let Some(zero) = window.zero_after_positive.as_ref() {
        return Some(format!(
            "{label} returned to zero after positive traffic; evidence {}",
            zero.evidence
        ));
    }

    let latest = window
        .latest
        .as_ref()
        .map(|metric| metric.value.to_string())
        .unwrap_or_else(|| "missing".to_owned());
    let total_hint = total
        .and_then(|total| total.latest.as_ref())
        .map(|metric| format!("; latest total {}", metric.value))
        .unwrap_or_default();
    Some(format!(
        "{label} needs at least two positive rolling samples or an increasing total; latest {latest}; positiveSamples={}{}",
        window.positive_count, total_hint
    ))
}

fn describe_webrtc_rendered_frames_continuity(evidence: &WebRtcMediaEvidence) -> Option<String> {
    let window = &evidence.audio_rendered_frames;
    if window.positive_count >= 2 {
        return None;
    }

    if window.seen_positive
        && webrtc_counter_has_continuity(
            &evidence.audio_rx_played,
            Some(&evidence.audio_rx_played_total),
        )
    {
        return None;
    }

    let latest = window
        .latest
        .as_ref()
        .map(|metric| metric.value.to_string())
        .unwrap_or_else(|| "missing".to_owned());
    Some(format!(
        "renderedFrames needs positive render samples while audio playback counters advance; latest {latest}; positiveSamples={}",
        window.positive_count
    ))
}

fn check_webrtc_audio_activity_continuity(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    let mut failures = Vec::new();
    for (label, window, total) in [
        (
            "audioTxCaptured",
            &evidence.audio_tx_captured,
            Some(&evidence.audio_tx_captured_total),
        ),
        (
            "audioTxEncoded",
            &evidence.audio_tx_encoded,
            Some(&evidence.audio_tx_encoded_total),
        ),
        (
            "audioTxSent",
            &evidence.audio_tx_sent,
            Some(&evidence.audio_tx_sent_total),
        ),
        (
            "audioRxRecv",
            &evidence.audio_rx_recv,
            Some(&evidence.audio_rx_recv_total),
        ),
        (
            "audioRxDecoded",
            &evidence.audio_rx_decoded,
            Some(&evidence.audio_rx_decoded_total),
        ),
        (
            "audioRxPlayed",
            &evidence.audio_rx_played,
            Some(&evidence.audio_rx_played_total),
        ),
    ] {
        if let Some(failure) = describe_webrtc_counter_continuity(label, window, total) {
            failures.push(failure);
        }
    }
    if let Some(failure) = describe_webrtc_rendered_frames_continuity(evidence) {
        failures.push(failure);
    }
    if let Some(drop) = evidence.audio_drops.latest_positive.as_ref() {
        failures.push(format!(
            "audioDrops={} after telemetry prime; evidence {}",
            drop.value, drop.evidence
        ));
    }
    DoctorCheck {
        name: "audio_activity_continuity",
        ok: failures.is_empty(),
        severity: if failures.is_empty() { "info" } else { "error" },
        detail: if failures.is_empty() {
            "audio TX/RX/playback counters showed sustained activity across multiple samples"
                .to_owned()
        } else {
            format!(
                "audio activity continuity insufficient: {}",
                failures.join("; ")
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_audio_playback_continuity(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    let mut failures = Vec::new();
    for (label, observation) in [
        ("rebuffer", &evidence.audio_rebuffer),
        ("playbackDrop", &evidence.audio_playback_drop),
        ("jitterEvicted", &evidence.audio_jitter_evicted),
    ] {
        if let Some(metric) = observation.latest_positive.as_ref() {
            failures.push(format!(
                "{label}={} evidence {}",
                metric.value, metric.evidence
            ));
        }
    }
    if counter_observed_positive(&evidence.audio_underflow)
        && !webrtc_audio_underflow_is_soft_bridged(evidence)
    {
        if let Some(metric) = evidence.audio_underflow.latest_positive.as_ref() {
            failures.push(format!(
                "underflow={} evidence {}",
                metric.value, metric.evidence
            ));
        }
    }
    if let Some(metric) = evidence.audio_playout_pressure.as_ref() {
        failures.push(format!(
            "playout pressure ({}) evidence {}",
            metric.value, metric.evidence
        ));
    }
    if failures.is_empty() {
        let detail = if counter_observed_positive(&evidence.audio_underflow)
            && webrtc_audio_underflow_is_soft_bridged(evidence)
        {
            "bounded soft-bridged audio underflow observed without rebuffer/playbackDrop/jitterEvicted"
                .to_owned()
        } else {
            "no audio underflow/rebuffer/playbackDrop/jitterEvicted/playout-pressure evidence observed"
                .to_owned()
        };
        return DoctorCheck {
            name: "audio_playback_continuity",
            ok: true,
            severity: "info",
            detail,
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    DoctorCheck {
        name: "audio_playback_continuity",
        ok: false,
        severity: "error",
        detail: format!("audio playback continuity failed: {}", failures.join("; ")),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn webrtc_audio_has_hard_playback_failure(evidence: &WebRtcMediaEvidence) -> bool {
    counter_observed_positive(&evidence.audio_rebuffer)
        || counter_observed_positive(&evidence.audio_playback_drop)
        || counter_observed_positive(&evidence.audio_jitter_evicted)
        || evidence.audio_playout_pressure.is_some()
        || (counter_observed_positive(&evidence.audio_underflow)
            && !webrtc_audio_underflow_is_soft_bridged(evidence))
}

fn webrtc_audio_underflow_is_soft_bridged(evidence: &WebRtcMediaEvidence) -> bool {
    const MAX_SOFT_BRIDGED_UNDERFLOW_EVENTS: u64 = 4;
    const MAX_SOFT_BRIDGED_UNDERFLOW_SAMPLES: u64 = 3_840;

    let Some(underflow_events) = latest_positive_counter_value(&evidence.audio_underflow) else {
        return false;
    };
    let Some(bridged_samples) = latest_positive_counter_value(&evidence.audio_bridged_underflow)
    else {
        return false;
    };
    underflow_events <= MAX_SOFT_BRIDGED_UNDERFLOW_EVENTS
        && bridged_samples <= MAX_SOFT_BRIDGED_UNDERFLOW_SAMPLES
        && !counter_observed_positive(&evidence.audio_rebuffer)
        && !counter_observed_positive(&evidence.audio_playback_drop)
        && !counter_observed_positive(&evidence.audio_jitter_evicted)
        && latest_counter_value(&evidence.audio_rendered_frames).is_some_and(|value| value > 0)
}

fn check_webrtc_native_video_health(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    if let Some(failure) = evidence.native_video_failure.as_ref() {
        let fallback_healthy = webrtc_fallback_video_is_healthy(evidence);
        return DoctorCheck {
            name: "native_video_health",
            ok: fallback_healthy,
            severity: if fallback_healthy { "warn" } else { "error" },
            detail: if fallback_healthy {
                format!(
                    "nativeVideoHealth entered {}, but fallback video remained healthy; evidence {}",
                    failure.value, failure.evidence
                )
            } else {
                format!(
                    "nativeVideoHealth entered {} and fallback video was not healthy; evidence {}",
                    failure.value, failure.evidence
                )
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    let Some(state) = evidence.native_video_state.as_ref() else {
        return webrtc_missing_observation_check(
            "native_video_health",
            "native-video-health/native-video-tx state was not observed",
        );
    };
    DoctorCheck {
        name: "native_video_health",
        ok: true,
        severity: "info",
        detail: format!("latest native video health state {}", state.value),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn optional_f64_label(value: Option<f64>) -> String {
    value
        .map(|value| format!("{value:.3}"))
        .unwrap_or_else(|| "-".to_owned())
}

fn webrtc_encoder_satisfies_strict_hardware_gate(encoder: &str) -> bool {
    let normalized = encoder.to_ascii_lowercase();
    normalized.contains("videotoolbox") || normalized.contains("hardware")
}

fn check_webrtc_native_video_rtc_stats(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
    strict_native_rtp_gate: bool,
) -> DoctorCheck {
    let native_rtp_gate = min_fps >= 59.0 || (strict_native_rtp_gate && min_fps >= 30.0);
    let has_native_video_evidence = evidence.native_video_state.is_some()
        || evidence.native_video_frames_sent.latest.is_some()
        || evidence.native_video_packets_sent.latest.is_some()
        || evidence.native_video_bytes_sent.latest.is_some();
    if !has_native_video_evidence {
        return DoctorCheck {
            name: "native_video_rtc_stats",
            ok: !native_rtp_gate,
            severity: if native_rtp_gate { "error" } else { "info" },
            detail: if native_rtp_gate {
                format!(
                    "native WebRTC RTP stats were not observed; min_fps={min_fps:.1} requires native RTP evidence"
                )
            } else {
                "native WebRTC RTP stats were not observed; no native video evidence was present"
                    .to_owned()
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }

    let frames_encoded = latest_counter_value(&evidence.native_video_frames_encoded).unwrap_or(0);
    let frames_sent = latest_counter_value(&evidence.native_video_frames_sent).unwrap_or(0);
    let packets_sent = latest_counter_value(&evidence.native_video_packets_sent).unwrap_or(0);
    let bytes_sent = latest_counter_value(&evidence.native_video_bytes_sent).unwrap_or(0);
    let target_bitrate = latest_counter_value(&evidence.native_video_target_bitrate).unwrap_or(0);
    let available_outgoing_bitrate =
        latest_counter_value(&evidence.native_video_available_outgoing_bitrate).unwrap_or(0);
    let codec = evidence
        .native_video_codec
        .as_ref()
        .map(|metric| metric.value.as_str())
        .unwrap_or("-");
    let encoder = evidence
        .native_video_encoder
        .as_ref()
        .map(|metric| metric.value.as_str())
        .unwrap_or("-");
    let quality_limit = evidence
        .native_video_quality_limit
        .as_ref()
        .map(|metric| metric.value.as_str())
        .unwrap_or("-");
    let encode_fps = evidence
        .native_video_encode_fps
        .as_ref()
        .map(|metric| metric.value);
    let current_rtt = evidence
        .native_video_current_rtt
        .as_ref()
        .map(|metric| metric.value);
    let remote_rtt = evidence
        .native_video_remote_rtt
        .as_ref()
        .map(|metric| metric.value);
    let remote_packets_lost = evidence
        .native_video_remote_packets_lost
        .as_ref()
        .map(|metric| metric.value);
    let remote_jitter = evidence
        .native_video_remote_jitter
        .as_ref()
        .map(|metric| metric.value);

    let codec_missing = codec == "-";
    let encoder_missing = encoder == "-";
    let encoder_not_hardware = native_rtp_gate
        && !encoder_missing
        && !webrtc_encoder_satisfies_strict_hardware_gate(encoder);
    let bwe_missing = target_bitrate == 0 && available_outgoing_bitrate == 0;
    let quality_limited = !matches!(quality_limit.to_ascii_lowercase().as_str(), "-" | "none");
    let counters_missing =
        frames_encoded == 0 || frames_sent == 0 || packets_sent == 0 || bytes_sent == 0;
    let encode_fps_below_min = !encode_fps.is_some_and(|fps| fps >= min_fps);
    let native_rtp_ready = !codec_missing
        && !encoder_missing
        && !encoder_not_hardware
        && !bwe_missing
        && !quality_limited
        && !counters_missing;
    let ok = !native_rtp_gate || (native_rtp_ready && !encode_fps_below_min);

    let mut missing = Vec::new();
    if codec_missing {
        missing.push("codec");
    }
    if encoder_missing {
        missing.push("encoder");
    }
    if encoder_not_hardware {
        missing.push("hardwareEncoder");
    }
    if bwe_missing {
        missing.push("targetBitrate/availableOutgoingBitrate");
    }
    if counters_missing {
        missing.push("encoded/sent/rtp counters");
    }
    if quality_limited {
        missing.push("qualityLimit!=none");
    }
    if encode_fps_below_min {
        missing.push("encodeFPS<min");
    }

    DoctorCheck {
        name: "native_video_rtc_stats",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: format!(
            "native RTP stats: framesEncoded={frames_encoded} framesSent={frames_sent} packetsSent={packets_sent} bytesSent={bytes_sent} codec={codec} encoder={encoder} qualityLimit={quality_limit} encodeFPS={} targetBitrate={target_bitrate} availableOutgoingBitrate={available_outgoing_bitrate} currentRTT={} remoteRTT={} remotePacketsLost={} remoteJitter={}{}",
            optional_f64_label(encode_fps),
            optional_f64_label(current_rtt),
            optional_f64_label(remote_rtt),
            optional_f64_label(remote_packets_lost),
            optional_f64_label(remote_jitter),
            if native_rtp_gate && !missing.is_empty() && min_fps >= 59.0 {
                format!("; high-fps missing {}", missing.join(","))
            } else if native_rtp_gate && !missing.is_empty() {
                format!("; native RTP gate missing {}", missing.join(","))
            } else if !native_rtp_gate {
                "; native RTP evidence gate not enforced below 30fps".to_owned()
            } else {
                String::new()
            }
        ),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_sck_vt_encode_latency(evidence: &WebRtcMediaEvidence, min_fps: f64) -> DoctorCheck {
    let p50 = evidence
        .sck_encode_latency_p50_ms
        .as_ref()
        .map(|metric| metric.value);
    let p95 = evidence
        .sck_encode_latency_p95_ms
        .as_ref()
        .map(|metric| metric.value);
    let max_latency = evidence
        .sck_encode_latency_max_ms
        .as_ref()
        .map(|metric| metric.value);
    let failures = latest_counter_value(&evidence.sck_encode_failures);
    let has_sck_tx_evidence = evidence.sck_captured.latest.is_some()
        || evidence.sck_meaningful.latest.is_some()
        || evidence.sck_encoded.latest.is_some()
        || evidence.sck_encoded_fps.is_some();
    let has_latency_evidence = p50.is_some() || p95.is_some() || max_latency.is_some();
    if !has_latency_evidence && failures.is_none() {
        return DoctorCheck {
            name: "sck_vt_encode_latency",
            ok: true,
            severity: "info",
            detail: if has_sck_tx_evidence {
                "SCK tx telemetry was observed, but VT encode latency fields were not present"
                    .to_owned()
            } else {
                "SCK/VT encode latency telemetry was not observed".to_owned()
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }

    let failures = failures.unwrap_or(0);
    let over_budget = webrtc_sck_vt_encode_latency_over_budget(evidence, min_fps);
    let ok = failures == 0 && !over_budget;
    let evidence_detail = evidence
        .sck_encode_latency_p95_ms
        .as_ref()
        .or(evidence.sck_encode_latency_max_ms.as_ref())
        .or(evidence.sck_encode_latency_p50_ms.as_ref())
        .map(|metric| metric.evidence.as_str())
        .or_else(|| {
            evidence
                .sck_encode_failures
                .latest
                .as_ref()
                .map(|metric| metric.evidence.as_str())
        })
        .unwrap_or("-");
    DoctorCheck {
        name: "sck_vt_encode_latency",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: format!(
            "SCK/VT encode latency: p50Ms={} p95Ms={} maxMs={} failures={} frameBudgetMs={:.2}; evidence {}",
            optional_f64_label(p50),
            optional_f64_label(p95),
            optional_f64_label(max_latency),
            failures,
            webrtc_frame_budget_ms(min_fps),
            evidence_detail
        ),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_native_video_receiver(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    if let Some(dimensions) = evidence.native_video_receiver_dimensions.as_ref()
        && evidence.native_video_receiver_dimensions_are_visible
    {
        return DoctorCheck {
            name: "native_video_receiver",
            ok: true,
            severity: "info",
            detail: format!(
                "iOS native receiver visible dimensions observed: {}x{}; evidence {}",
                dimensions.value.width, dimensions.value.height, dimensions.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }

    let Some(receiver) = evidence.native_video_receiver_frame.as_ref() else {
        return webrtc_missing_observation_check(
            "native_video_receiver",
            "iOS native receiver/decode frame evidence was not observed",
        );
    };
    DoctorCheck {
        name: "native_video_receiver",
        ok: true,
        severity: "info",
        detail: format!("iOS native receiver evidence observed: {}", receiver.value),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_visible_native_render(
    evidence: &WebRtcMediaEvidence,
    min_fps: f64,
    strict_native_render_gate: bool,
) -> DoctorCheck {
    let visible_render_gate = min_fps >= 59.0 || (strict_native_render_gate && min_fps >= 30.0);
    let Some(render_frame) = evidence.native_video_render_frame.as_ref() else {
        return DoctorCheck {
            name: "visible_native_render",
            ok: !visible_render_gate,
            severity: if visible_render_gate { "error" } else { "info" },
            detail: if visible_render_gate {
                "iOS RTCMTLVideoView visible render evidence was not observed; native video gate requires real visible rendering, not receiver stats only".to_owned()
            } else {
                "iOS RTCMTLVideoView visible render evidence was not observed; visible-render gate not enforced below 30fps".to_owned()
            },
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    };
    let source = evidence
        .native_video_render_source
        .as_ref()
        .map(|metric| metric.value.as_str())
        .unwrap_or("-");
    let source_ok = source == "rtc-mtl-video-view";
    let dimensions_label = evidence
        .native_video_render_dimensions
        .as_ref()
        .map(|metric| format!("{}x{}", metric.value.width, metric.value.height))
        .unwrap_or_else(|| "-".to_owned());
    DoctorCheck {
        name: "visible_native_render",
        ok: source_ok,
        severity: if source_ok { "info" } else { "error" },
        detail: format!(
            "iOS visible native render source={source} dimensions={dimensions_label}; evidence {}",
            render_frame.evidence
        ),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_strict_media_failure(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    if let Some(failure) = evidence.strict_media_failure.as_ref() {
        return DoctorCheck {
            name: "strict_media_failure",
            ok: false,
            severity: "error",
            detail: format!(
                "strict WebRTC media failure observed: {}; evidence {}",
                failure.value, failure.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    DoctorCheck {
        name: "strict_media_failure",
        ok: true,
        severity: "info",
        detail: "no strict WebRTC media failure was observed".to_owned(),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_audio_relay_startup(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    if let Some(failure) = evidence.audio_tx_relay_failure.as_ref() {
        if latest_counter_value(&evidence.audio_tx_sent).is_some_and(|value| value > 0) {
            if !webrtc_audio_rx_has_received(evidence) {
                return DoctorCheck {
                    name: "audio_relay_startup",
                    ok: false,
                    severity: "error",
                    detail: format!(
                        "Mac sender reported media sent after relay bind warning ({}), but receiver has no audio; bind evidence {}",
                        failure.value, failure.evidence
                    ),
                    server_build_fingerprint: None,
                    state_backend: None,
                    reject_reason: None,
                };
            }
            return DoctorCheck {
                name: "audio_relay_startup",
                ok: true,
                severity: "info",
                detail: format!(
                    "Mac sender reported media sent after relay bind warning ({}); bind evidence {}; continue diagnosing relay forwarding/RX if receiver stays zero",
                    failure.value, failure.evidence
                ),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            };
        }
        return DoctorCheck {
            name: "audio_relay_startup",
            ok: false,
            severity: "error",
            detail: format!(
                "Mac sender failed to bind/send media relay ({}); evidence {}",
                failure.value, failure.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    if let Some(pending) = evidence.audio_tx_relay_bind_pending.as_ref() {
        if !webrtc_audio_rx_has_received(evidence) {
            return DoctorCheck {
                name: "audio_relay_startup",
                ok: false,
                severity: "error",
                detail: format!(
                    "Mac sender relay bind ACK is still pending and receiver has no audio; bind evidence {}",
                    pending.evidence
                ),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            };
        }
        return DoctorCheck {
            name: "audio_relay_startup",
            ok: true,
            severity: "info",
            detail: format!(
                "Mac sender relay bind ACK was pending, but receiver audio is flowing; bind evidence {}",
                pending.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    if let Some(failure) = evidence.audio_rx_relay_bind_failure.as_ref() {
        return DoctorCheck {
            name: "audio_relay_startup",
            ok: false,
            severity: "error",
            detail: format!(
                "audio relay receiver startup failed at {}; evidence {}",
                failure.value, failure.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    if let Some(missing) = evidence.audio_tx_missing_viewer_endpoint.as_ref() {
        return DoctorCheck {
            name: "audio_relay_startup",
            ok: false,
            severity: "error",
            detail: format!(
                "Mac sender never received viewer media endpoint ({}); evidence {}",
                missing.value, missing.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    DoctorCheck {
        name: "audio_relay_startup",
        ok: true,
        severity: "info",
        detail: "no audio relay startup/bind failure evidence observed".to_owned(),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn webrtc_fallback_video_is_healthy(evidence: &WebRtcMediaEvidence) -> bool {
    evidence
        .latest_fps
        .as_ref()
        .is_some_and(|fps| fps.value > 2.0)
        && evidence.stale_fallback.is_none()
        && evidence.backpressure.is_none()
}

fn check_webrtc_stale_fallback(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    if let Some(stale) = evidence.stale_fallback.as_ref() {
        return DoctorCheck {
            name: "stale_fallback",
            ok: false,
            severity: "warn",
            detail: format!("stale fallback evidence observed: {}", stale.evidence),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    DoctorCheck {
        name: "stale_fallback",
        ok: true,
        severity: "info",
        detail: "no stale SCK/fallback producer evidence observed".to_owned(),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn check_webrtc_backpressure(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    if let Some(backpressure) = evidence.backpressure.as_ref() {
        return DoctorCheck {
            name: "backpressure",
            ok: false,
            severity: "warn",
            detail: format!("backpressure evidence observed: {}", backpressure.evidence),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    DoctorCheck {
        name: "backpressure",
        ok: true,
        severity: "info",
        detail: "no stream backpressure/drop evidence observed".to_owned(),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn webrtc_missing_observation_check(name: &'static str, detail: &str) -> DoctorCheck {
    DoctorCheck {
        name,
        ok: false,
        severity: "warn",
        detail: detail.to_owned(),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
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
    if let Some(fault_stage) = report.fault_stage {
        println!("[ERROR] probable_fault_stage: {fault_stage}");
    }
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

fn ensure_webrtc_media_doctor_passed(report: &DoctorProbeReport) -> Result<()> {
    let blocking: Vec<String> = report
        .checks
        .iter()
        .filter(|check| {
            !check.ok
                || matches!(
                    check.severity.to_ascii_lowercase().as_str(),
                    "warn" | "warning" | "error"
                )
        })
        .map(|check| format!("{} ({})", check.name, check.severity))
        .collect();
    if report.fault_stage.is_none() && blocking.is_empty() {
        return Ok(());
    }
    let fault = report
        .fault_stage
        .map(|stage| format!("probable_fault_stage={stage}"));
    let mut details = Vec::new();
    if let Some(fault) = fault {
        details.push(fault);
    }
    details.extend(blocking);
    bail!("WebRTC media doctor failed: {}", details.join(", "))
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
        assert!(Cli::try_parse_from(["skybridge", "code", "current", "--json"]).is_ok());
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "code",
                "current",
                "--snapshot",
                "/tmp/connection-code-latest.json",
                "--json",
            ])
            .is_ok()
        );
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
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "doctor",
                "webrtc-media",
                "--session-id",
                "SESSION1",
                "--artifact-dir",
                "/tmp",
                "--since-seconds",
                "60",
                "--min-fps",
                "24",
                "--json",
            ])
            .is_ok()
        );
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "doctor",
                "webrtc-media",
                "--latest",
                "--artifact-dir",
                "/tmp",
                "--require-audio",
                "false",
                "--json",
            ])
            .is_ok()
        );
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "diagnose",
                "webrtc-media",
                "--latest",
                "--artifact-dir",
                "/tmp",
                "--json",
            ])
            .is_ok()
        );
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "smoke",
                "webrtc",
                "gate",
                "--session-id",
                "SESSION1",
                "--artifact-dir",
                "/tmp",
                "--timeout-seconds",
                "240",
                "--min-pass-seconds",
                "60",
                "--poll-interval-seconds",
                "2",
                "--min-fps",
                "30.00",
                "--require-audio",
                "true",
                "--json",
            ])
            .is_ok()
        );
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "smoke",
                "suite",
                "--profile",
                "all",
                "--skip-real-device",
                "--soak-seconds",
                "600",
                "--timeout-seconds",
                "900",
                "--dry-run",
                "--json",
            ])
            .is_ok()
        );
        assert!(
            Cli::try_parse_from(["skybridge", "smoke", "faults", "--dry-run", "--json"]).is_ok()
        );
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "smoke",
                "fault-detection",
                "--dry-run",
                "--json"
            ])
            .is_ok()
        );
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "smoke",
                "faults",
                "--iterations",
                "200",
                "--timeout-ms",
                "2500",
                "--delay-ms",
                "200",
                "--progress-interval",
                "50",
                "--dry-run",
                "--json",
            ])
            .is_ok()
        );
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "smoke",
                "local-webrtc",
                "--min-fps",
                "30",
                "--dry-run",
                "--json",
            ])
            .is_ok()
        );
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "smoke",
                "local-p2p",
                "--scenario",
                "compat-pure-pqc",
                "--rounds",
                "2",
                "--timeout-seconds",
                "180",
                "--dry-run",
                "--json",
            ])
            .is_ok()
        );
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "smoke",
                "real-device",
                "--real-device-id",
                "00008132-0006452C1138801C",
                "--min-fps",
                "30",
                "--dry-run",
                "--json",
            ])
            .is_ok()
        );
        assert!(
            Cli::try_parse_from([
                "skybridge",
                "smoke",
                "all",
                "--skip-real-device",
                "--dry-run",
                "--json",
            ])
            .is_ok()
        );
        for profile in [
            "script-tests",
            "ios-config",
            "local-p2p",
            "local-webrtc",
            "benchmarks",
        ] {
            assert!(
                Cli::try_parse_from([
                    "skybridge",
                    "smoke",
                    "suite",
                    "--profile",
                    profile,
                    "--dry-run",
                    "--json",
                ])
                .is_ok(),
                "profile {profile} should parse"
            );
        }
    }

    #[test]
    fn smoke_webrtc_gate_terminal_failure_classifies_hard_failures() {
        let report = DoctorProbeReport {
            target: "webrtc-media session=SESSION1".to_owned(),
            checks: vec![],
            fault_stage: Some("strict_media_failure"),
            latest_diagnostic_at: None,
            latest_video_evidence_at: None,
            latest_receiver_evidence_at: None,
            latest_audio_tx_evidence_at: None,
            latest_audio_rx_evidence_at: None,
        };
        assert!(webrtc_smoke_gate_terminal_failure(&report));

        let vt_slow = DoctorProbeReport {
            target: "webrtc-media session=SESSION1".to_owned(),
            checks: vec![],
            fault_stage: Some("vt_encode_slow"),
            latest_diagnostic_at: None,
            latest_video_evidence_at: None,
            latest_receiver_evidence_at: None,
            latest_audio_tx_evidence_at: None,
            latest_audio_rx_evidence_at: None,
        };
        assert!(webrtc_smoke_gate_terminal_failure(&vt_slow));

        let pending = DoctorProbeReport {
            target: "webrtc-media session=SESSION1".to_owned(),
            checks: vec![DoctorCheck {
                name: "diagnostic_samples",
                ok: false,
                severity: "warn",
                detail: "no diagnostics matched yet".to_owned(),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            }],
            fault_stage: Some("diagnostics_missing"),
            latest_diagnostic_at: None,
            latest_video_evidence_at: None,
            latest_receiver_evidence_at: None,
            latest_audio_tx_evidence_at: None,
            latest_audio_rx_evidence_at: None,
        };
        assert!(!webrtc_smoke_gate_terminal_failure(&pending));
    }

    #[test]
    fn smoke_webrtc_gate_uses_strict_fps_floor_for_high_fps_and_soak() {
        assert!(!webrtc_smoke_gate_strict_fps_floor(30.0, 0));
        assert!(webrtc_smoke_gate_strict_fps_floor(30.0, 60));
        assert!(webrtc_smoke_gate_strict_fps_floor(59.0, 0));
        assert!(webrtc_smoke_gate_strict_fps_floor(60.0, 0));
    }

    #[test]
    fn smoke_webrtc_gate_soak_window_uses_slowest_required_evidence() {
        let base = OffsetDateTime::from_unix_timestamp(1_700_000_000).unwrap();
        let report = DoctorProbeReport {
            target: "webrtc-media session=SESSION1".to_owned(),
            checks: vec![],
            fault_stage: None,
            latest_diagnostic_at: Some(base + time::Duration::seconds(8)),
            latest_video_evidence_at: Some(base + time::Duration::seconds(5)),
            latest_receiver_evidence_at: Some(base + time::Duration::seconds(4)),
            latest_audio_tx_evidence_at: Some(base),
            latest_audio_rx_evidence_at: Some(base + time::Duration::seconds(6)),
        };

        assert_eq!(
            webrtc_smoke_gate_required_evidence_floor(&report, true, true),
            Some(base)
        );
        assert_eq!(
            webrtc_smoke_gate_required_evidence_floor(&report, false, true),
            Some(base + time::Duration::seconds(4))
        );
    }

    #[test]
    fn smoke_webrtc_gate_soak_window_passes_on_diagnostic_timestamps() {
        let base = OffsetDateTime::from_unix_timestamp(1_700_000_000).unwrap();
        let mut report = DoctorProbeReport {
            target: "webrtc-media session=SESSION1".to_owned(),
            checks: vec![],
            fault_stage: None,
            latest_diagnostic_at: Some(base),
            latest_video_evidence_at: Some(base),
            latest_receiver_evidence_at: Some(base),
            latest_audio_tx_evidence_at: Some(base),
            latest_audio_rx_evidence_at: Some(base),
        };
        let duration = Duration::from_secs(30);

        report.latest_video_evidence_at = Some(base + time::Duration::seconds(29));
        report.latest_receiver_evidence_at = Some(base + time::Duration::seconds(30));
        report.latest_audio_tx_evidence_at = Some(base + time::Duration::seconds(30));
        report.latest_audio_rx_evidence_at = Some(base + time::Duration::seconds(30));
        assert!(!webrtc_smoke_gate_pass_window_satisfied(
            &report, base, duration, true, true
        ));

        report.latest_video_evidence_at = Some(base + time::Duration::seconds(31));
        assert!(webrtc_smoke_gate_pass_window_satisfied(
            &report, base, duration, true, true
        ));
    }

    #[test]
    fn smoke_suite_all_profile_can_skip_real_device_steps() -> Result<()> {
        let root = PathBuf::from("/tmp/skybridge-test-root");
        let steps = build_smoke_suite_steps(
            &root,
            SmokeSuiteProfile::All,
            true,
            None,
            None,
            30.0,
            None,
            0,
            2056,
            1329,
        )?;
        let names = steps.iter().map(|step| step.name).collect::<Vec<_>>();
        assert!(names.contains(&"rust_workspace_tests"));
        assert!(names.contains(&"swift_package_tests"));
        assert!(names.contains(&"signaling_server_tests"));
        assert!(names.contains(&"xcodebuild_helper_tests"));
        assert!(names.contains(&"ios_test_configuration_static_gate"));
        assert!(names.contains(&"local_p2p_smoke"));
        assert!(names.contains(&"local_webrtc_smoke"));
        assert!(names.contains(&"handshake_fault_injection"));
        assert!(names.contains(&"swift_handshake_benchmarks"));
        assert!(names.contains(&"macos_release_readiness"));
        assert!(!names.contains(&"real_device_webrtc_smoke"));
        assert!(!names.contains(&"real_device_file_transfer_smoke"));
        Ok(())
    }

    #[test]
    fn smoke_faults_options_are_mapped_to_swift_environment() {
        let root = PathBuf::from("/tmp/skybridge-test-root");
        let mut steps = Vec::new();
        push_fault_injection_steps(
            &root,
            &mut steps,
            SmokeFaultOptions {
                iterations: Some(200),
                timeout_ms: Some(2500),
                delay_ms: Some(100),
                progress_interval: Some(25),
            },
        );
        let fault_step = steps
            .iter()
            .find(|step| step.name == "handshake_fault_injection")
            .expect("fault injection step");
        for (name, value) in [
            ("SKYBRIDGE_RUN_FI", "1"),
            ("SKYBRIDGE_FI_ITERATIONS", "200"),
            ("SKYBRIDGE_FI_TIMEOUT_MS", "2500"),
            ("SKYBRIDGE_FI_DELAY_MS", "100"),
            ("SKYBRIDGE_FI_PROGRESS_INTERVAL", "25"),
        ] {
            assert!(
                fault_step
                    .env
                    .iter()
                    .any(|(actual_name, actual_value)| actual_name == name && actual_value == value),
                "{name} should be passed to fault step"
            );
        }
    }

    #[test]
    fn smoke_local_p2p_options_are_mapped_to_script_environment() {
        let root = PathBuf::from("/tmp/skybridge-test-root");
        let mut steps = Vec::new();
        push_local_p2p_smoke_steps(
            &root,
            &mut steps,
            SmokeLocalP2pOptions {
                scenario: LocalP2pSmokeScenario::CompatPurePqc,
                rounds: Some(3),
                timeout_seconds: Some(180),
                ios_device_id: Some("ios-smoke-device".to_owned()),
                target_name: Some("Mac Smoke Target".to_owned()),
            },
        );
        let p2p_step = steps
            .iter()
            .find(|step| step.name == "local_p2p_smoke")
            .expect("local P2P smoke step");
        assert_eq!(p2p_step.program, "bash");
        assert_eq!(
            p2p_step.args,
            vec!["Scripts/run_local_p2p_smoke.sh".to_owned()]
        );
        for (name, value) in [
            ("SKYBRIDGE_SMOKE_SCENARIO", "compat-pure-pqc"),
            ("SKYBRIDGE_SMOKE_ROUNDS", "3"),
            ("SKYBRIDGE_SMOKE_TIMEOUT_SECONDS", "180"),
            ("SKYBRIDGE_SMOKE_IOS_DEVICE_ID", "ios-smoke-device"),
            ("SKYBRIDGE_SMOKE_MAC_TARGET_NAME", "Mac Smoke Target"),
        ] {
            assert!(
                p2p_step
                    .env
                    .iter()
                    .any(|(actual_name, actual_value)| actual_name == name && actual_value == value),
                "{name} should be passed to local P2P smoke step"
            );
        }
    }

    #[test]
    fn smoke_suite_real_device_steps_carry_device_auth_and_fps_env() -> Result<()> {
        let root = PathBuf::from("/tmp/skybridge-test-root");
        let auth_path = Path::new("/tmp/auth-session.json");
        let steps = build_smoke_suite_steps(
            &root,
            SmokeSuiteProfile::RealDevice,
            false,
            Some("00008132-0006452C1138801C"),
            Some(auth_path),
            30.0,
            Some(900),
            600,
            2056,
            1329,
        )?;
        let webrtc = steps
            .iter()
            .find(|step| step.name == "real_device_webrtc_smoke")
            .expect("real-device WebRTC step");
        assert!(webrtc.env.iter().any(|(name, value)| {
            name == "SKYBRIDGE_REAL_DEVICE_ID" && value == "00008132-0006452C1138801C"
        }));
        assert!(webrtc.env.iter().any(|(name, value)| {
            name == "SKYBRIDGE_SMOKE_AUTH_SESSION_FILE" && value == "/tmp/auth-session.json"
        }));
        assert!(
            webrtc
                .env
                .iter()
                .any(|(name, value)| name == "SKYBRIDGE_SMOKE_MIN_FPS" && value == "30.00")
        );
        assert!(
            webrtc
                .env
                .iter()
                .any(|(name, value)| name == "SKYBRIDGE_SMOKE_TARGET_FPS" && value == "32")
        );
        assert!(
            webrtc
                .env
                .iter()
                .any(|(name, value)| name == "SKYBRIDGE_SMOKE_REQUIRE_AUDIO" && value == "1")
        );
        assert!(
            webrtc.env.iter().any(|(name, value)| {
                name == "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS" && value == "900"
            })
        );
        assert!(
            webrtc
                .env
                .iter()
                .any(|(name, value)| { name == "SKYBRIDGE_SMOKE_SOAK_SECONDS" && value == "600" })
        );
        assert!(
            webrtc
                .env
                .iter()
                .any(|(name, value)| name == "SKYBRIDGE_SMOKE_FORCE_RELAY_ICE" && value == "1")
        );
        assert!(
            webrtc
                .env
                .iter()
                .any(|(name, value)| name == "SKYBRIDGE_SMOKE_EXTREME_MEDIA" && value == "1")
        );
        assert!(
            webrtc
                .env
                .iter()
                .any(|(name, value)| { name == "SKYBRIDGE_SMOKE_VIDEO_WIDTH" && value == "2056" })
        );
        assert!(
            webrtc
                .env
                .iter()
                .any(|(name, value)| { name == "SKYBRIDGE_SMOKE_VIDEO_HEIGHT" && value == "1329" })
        );
        assert!(webrtc.env.iter().any(|(name, value)| {
            name == "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK" && value == "1"
        }));
        assert!(webrtc.env.iter().any(|(name, value)| {
            name == "SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN" && value == "0"
        }));
        Ok(())
    }

    #[test]
    fn webrtc_evidence_summary_redacts_sensitive_log_fields() {
        let summary = summarize_webrtc_evidence_line(
            Path::new("webrtc-session-SESSION1.log"),
            7,
            r#"{"fps":60,"accessToken":"secret-access","nested":{"refresh_token":"secret-refresh"}}"#,
        );
        assert!(summary.contains("\"fps\":60"));
        assert!(!summary.contains("secret-access"));
        assert!(!summary.contains("secret-refresh"));
        assert!(summary.contains("<redacted>"));

        let plain = summarize_webrtc_evidence_line(
            Path::new("webrtc-session-SESSION1.log"),
            8,
            "audio relayToken=secret-relay authorization=Bearer secret-bearer fps=60",
        );
        assert!(!plain.contains("secret-relay"));
        assert!(!plain.contains("secret-bearer"));
        assert!(plain.contains("fps=60"));
    }

    #[test]
    fn code_current_reads_nonexpired_snapshot() -> Result<()> {
        let artifact_dir = make_test_dir("code-current-valid")?;
        let path = artifact_dir.join("connection-code-latest.json");
        let expires_at = (OffsetDateTime::now_utc() + time::Duration::minutes(5))
            .format(&time::format_description::well_known::Rfc3339)?;
        std::fs::write(
            &path,
            serde_json::to_string(&json!({
                "schemaVersion": 1,
                "code": "SB-TEST-CODE",
                "sessionId": "SESSION-CODE",
                "expiresAt": expires_at,
                "leaseMode": "cross-network",
                "deviceId": "DEVICE-1",
                "protocolPublicKeyFingerprint": "fp-test",
                "generatedAt": OffsetDateTime::now_utc()
                    .format(&time::format_description::well_known::Rfc3339)?,
            }))?,
        )?;

        let snapshot = read_connection_code_snapshot(&path)?;

        assert_eq!(snapshot.code, "SB-TEST-CODE");
        assert_eq!(snapshot.session_id, "SESSION-CODE");
        assert_eq!(snapshot.lease_mode.as_deref(), Some("cross-network"));
        Ok(())
    }

    #[test]
    fn code_current_rejects_expired_snapshot() -> Result<()> {
        let artifact_dir = make_test_dir("code-current-expired")?;
        let path = artifact_dir.join("connection-code-latest.json");
        let expires_at = (OffsetDateTime::now_utc() - time::Duration::minutes(5))
            .format(&time::format_description::well_known::Rfc3339)?;
        std::fs::write(
            &path,
            serde_json::to_string(&json!({
                "schemaVersion": 1,
                "code": "SB-OLD-CODE",
                "sessionId": "SESSION-OLD",
                "expiresAt": expires_at,
            }))?,
        )?;

        let error = read_connection_code_snapshot(&path).unwrap_err();

        assert!(error.to_string().contains("expired"));
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_plain_log_reports_media_failures() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-plain")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION1.log"),
            "\
stream-stats session=SESSION1 fps=1.5 screenBuffered=900000 fallbackProducer=cgdisplayEmergency dropReason=backpressure droppedBackpressure=2
audioTxStartup session=SESSION1 audioTxCaptured=0 audioTxEncoded=0 audioTxSent=0
audio-rx session=SESSION1 audioRxRecv=0 audioRxDecoded=0 audioRxPlayed=0
native-video-health session=SESSION1 state=failedNoRTP fallbackMode=main
fallbackProducerSwitch session=SESSION1 producer=cgdisplayEmergency reason=sck-latest-stale-or-missing sckLatestAgeMs=- holdMs=10000
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION1".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: false },
            },
            "SESSION1",
        )?;

        assert!(!doctor_check(&report, "video_fps").ok);
        assert_eq!(doctor_check(&report, "video_fps").severity, "error");
        assert!(!doctor_check(&report, "audio_tx_captured").ok);
        assert!(!doctor_check(&report, "audio_tx_encoded").ok);
        assert!(!doctor_check(&report, "audio_tx_sent").ok);
        assert!(!doctor_check(&report, "audio_rx_recv").ok);
        assert!(!doctor_check(&report, "audio_rx_decoded").ok);
        assert!(!doctor_check(&report, "audio_rx_played").ok);
        assert!(!doctor_check(&report, "native_video_health").ok);
        assert_eq!(report.fault_stage, Some("audio_tx_capture"));
        assert_eq!(
            doctor_check(&report, "native_video_health").severity,
            "error"
        );
        assert!(!doctor_check(&report, "stale_fallback").ok);
        assert!(!doctor_check(&report, "backpressure").ok);
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_detects_missing_viewer_audio_endpoint() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-missing-endpoint")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION6.log"),
            "\
stream-stats session=SESSION6 fps=21.0
streamConfigReceived session=SESSION6 audioRequested=true audioEndpoint=missing audioRelayToken=missing
audioTxUnavailable session=SESSION6 reason=missingViewerEndpoint mediaSession=-
native-video-health session=SESSION6 state=active
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION6".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION6",
        )?;

        assert_eq!(report.fault_stage, Some("audio_tx_relay_send"));
        assert!(!doctor_check(&report, "audio_relay_startup").ok);
        assert!(
            doctor_check(&report, "audio_relay_startup")
                .detail
                .contains("missingViewerEndpoint")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_orders_cross_source_diagnostics_by_timestamp() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-cross-source-time-order")?;
        let base = OffsetDateTime::now_utc() - time::Duration::seconds(60);
        let ts0 = (base + time::Duration::seconds(0))
            .format(&time::format_description::well_known::Rfc3339)?;
        let ts1 = (base + time::Duration::seconds(1))
            .format(&time::format_description::well_known::Rfc3339)?;
        let ts2 = (base + time::Duration::seconds(2))
            .format(&time::format_description::well_known::Rfc3339)?;
        let ts3 = (base + time::Duration::seconds(3))
            .format(&time::format_description::well_known::Rfc3339)?;
        let ts4 = (base + time::Duration::seconds(4))
            .format(&time::format_description::well_known::Rfc3339)?;
        let ts5 = (base + time::Duration::seconds(5))
            .format(&time::format_description::well_known::Rfc3339)?;
        let ts6 = (base + time::Duration::seconds(6))
            .format(&time::format_description::well_known::Rfc3339)?;
        let ts7 = (base + time::Duration::seconds(7))
            .format(&time::format_description::well_known::Rfc3339)?;
        let ts8 = (base + time::Duration::seconds(8))
            .format(&time::format_description::well_known::Rfc3339)?;
        let ts9 = (base + time::Duration::seconds(9))
            .format(&time::format_description::well_known::Rfc3339)?;

        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION9.jsonl"),
            format!(
                "{{\"timestamp\":\"{ts0}\",\"session\":\"SESSION9\",\"audioTxCaptured\":100,\"audioTxEncoded\":100,\"audioTxSent\":100}}\n\
                 {{\"timestamp\":\"{ts7}\",\"session\":\"SESSION9\",\"audioTxCaptured\":200,\"audioTxEncoded\":200,\"audioTxSent\":200}}\n"
            ),
        )?;
        std::fs::write(
            artifact_dir.join("aa-SESSION9.status.log"),
            format!(
                "[{ts2}] stream-stats session=SESSION9 fps=32\n\
                 [{ts3}] native-video-health session=SESSION9 state=rtpFlowing\n\
                 [{ts4}] native-video-tx session=SESSION9 state=rtpFlowing fallbackMode=main visibleFrame=2056x1329 codedFrame=2056x1330 framesEncoded=120 framesSent=120 packetsSent=240 bytesSent=4096 codec=video/H264 encoder=VideoToolbox qualityLimit=none encodeFPS=32\n\
                 [{ts5}] native-receiver-frame session=SESSION9 size=2056x1329 visibleSize=2056x1329 codedSize=2056x1329 source=remote-heartbeat\n\
                 [{ts5}] native-render-frame session=SESSION9 size=2056x1329 visibleSize=2056x1329 codedSize=2056x1329 source=rtc-mtl-video-view\n\
                 [{ts6}] audio-rx session=SESSION9 source=remote-heartbeat audioRxDatagrams=100 audioRxRecv=50 audioRxDecoded=49 audioRxPlayed=49 recvTotal=50 decodeTotal=49 playTotal=49 renderedFrames=48000 underflow=0 rebuffer=0 playbackDrop=0 jitterEvicted=0 engineRunning=true\n\
                 [{ts8}] audio-rx session=SESSION9 source=remote-heartbeat audioRxDatagrams=240 audioRxRecv=120 audioRxDecoded=118 audioRxPlayed=119 recvTotal=120 decodeTotal=118 playTotal=119 renderedFrames=96000 underflow=0 rebuffer=0 playbackDrop=0 jitterEvicted=0 engineRunning=true\n"
            ),
        )?;
        std::fs::write(
            artifact_dir.join("zz-SESSION9.webrtc-media.jsonl"),
            format!(
                "{{\"timestamp\":\"{ts1}\",\"kind\":\"audioRxRolling\",\"session\":\"SESSION9\",\"audioRxDatagrams\":1,\"audioRxRecv\":1,\"audioRxDecoded\":0,\"audioRxPlayed\":0,\"recvTotal\":1,\"decodeTotal\":0,\"playTotal\":0,\"renderedFrames\":0,\"underflow\":0,\"rebuffer\":0,\"playbackDrop\":0,\"jitterEvicted\":0}}\n\
                 {{\"timestamp\":\"{ts9}\",\"kind\":\"audioRxRolling\",\"session\":\"SESSION9\",\"audioRxDatagrams\":180,\"audioRxRecv\":90,\"audioRxDecoded\":88,\"audioRxPlayed\":89,\"recvTotal\":210,\"decodeTotal\":206,\"playTotal\":208,\"renderedFrames\":144000,\"underflow\":0,\"rebuffer\":0,\"playbackDrop\":0,\"jitterEvicted\":0}}\n"
            ),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION9".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION9",
        )?;

        assert!(doctor_check(&report, "audio_rx_decoded").ok);
        assert!(doctor_check(&report, "audio_rx_played").ok);
        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert!(report.fault_stage.is_none());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_detects_mac_tx_relay_bind_timeout_and_lease_limit() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-tx-relay-failure")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-W3MCEDC2X999ZKTU.log"),
            "\
audioTxEndpointReady session=W3MCEDC2X999ZKTU leaseSource=viewerEndpoint endpoint=82.156.225.30:3478 token=present mediaSession=W3MCEDC2X999ZKTU
audioTxUnavailable session=W3MCEDC2X999ZKTU reason=relayUnavailable error=media relay bind timed out
audioTxUnavailable session=W3MCEDC2X999ZKTU reason=leaseLimit error=信令服务器拒绝请求 (429): {\"error\":\"media_admission_token_lease_limit\"}
stream-stats session=W3MCEDC2X999ZKTU fps=0.8 fallbackProducer=sckLatest cgdisplayCaptureFPS=0.4 directEncodedFPS=0.6
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("W3MCEDC2X999ZKTU".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "W3MCEDC2X999ZKTU",
        )?;

        assert_eq!(report.fault_stage, Some("audio_tx_relay_send"));
        assert!(!doctor_check(&report, "audio_relay_startup").ok);
        assert!(
            doctor_check(&report, "audio_relay_startup")
                .detail
                .contains("Mac sender failed to bind/send media relay")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_prefers_latest_tx_relay_failure_over_missing_endpoint() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-tx-relay-priority")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-W3MCEDC2X999ZKTU.log"),
            "\
audioTxUnavailable session=W3MCEDC2X999ZKTU reason=missingViewerEndpoint mediaSession=-
audioTxEndpointReady session=W3MCEDC2X999ZKTU leaseSource=viewerEndpoint endpoint=82.156.225.30:3478 token=present mediaSession=W3MCEDC2X999ZKTU
audioTxUnavailable session=W3MCEDC2X999ZKTU reason=relayUnavailable error=media relay bind timed out
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("W3MCEDC2X999ZKTU".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "W3MCEDC2X999ZKTU",
        )?;

        assert_eq!(report.fault_stage, Some("audio_tx_relay_send"));
        assert!(!doctor_check(&report, "audio_relay_startup").ok);
        assert!(
            doctor_check(&report, "audio_relay_startup")
                .detail
                .contains("relayBindTimedOut")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_jsonl_reads_structured_diagnostics() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-jsonl")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION2.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION2",
                    "video_fps": 18.5,
                    "droppedBackpressure": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "sessionId": "SESSION2",
                    "audioTxCaptured": 12,
                    "audioTxEncoded": 11,
                    "audioTxSent": 10,
                    "audioTxCapturedTotal": 12,
                    "audioTxEncodedTotal": 11,
                    "audioTxSentTotal": 10,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "sessionId": "SESSION2",
                    "audioTxCaptured": 13,
                    "audioTxEncoded": 13,
                    "audioTxSent": 13,
                    "audioTxCapturedTotal": 25,
                    "audioTxEncodedTotal": 24,
                    "audioTxSentTotal": 23,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "sessionId": "SESSION2",
                    "audioRxRecv": 8,
                    "audioRxDecoded": 8,
                    "audioRxPlayed": 7,
                    "recvTotal": 8,
                    "decodeTotal": 8,
                    "playTotal": 7,
                    "renderedFrames": 3360,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "sessionId": "SESSION2",
                    "audioRxRecv": 9,
                    "audioRxDecoded": 9,
                    "audioRxPlayed": 9,
                    "recvTotal": 17,
                    "decodeTotal": 17,
                    "playTotal": 16,
                    "renderedFrames": 4320,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
                json!({
                    "event": "native-video-tx",
                    "sessionId": "SESSION2",
                    "nativeVideoHealth": "active"
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION2".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION2",
        )?;

        assert!(!doctor_check(&report, "video_fps").ok);
        assert_eq!(doctor_check(&report, "video_fps").severity, "warn");
        assert!(doctor_check(&report, "audio_tx_captured").ok);
        assert!(doctor_check(&report, "audio_tx_encoded").ok);
        assert!(doctor_check(&report, "audio_tx_sent").ok);
        assert!(doctor_check(&report, "audio_rx_recv").ok);
        assert!(doctor_check(&report, "audio_rx_decoded").ok);
        assert!(doctor_check(&report, "audio_rx_played").ok);
        assert!(doctor_check(&report, "audio_rendered_frames").ok);
        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert!(doctor_check(&report, "audio_playback_continuity").ok);
        assert!(doctor_check(&report, "native_video_health").ok);
        assert!(doctor_check(&report, "stale_fallback").ok);
        assert!(doctor_check(&report, "backpressure").ok);
        assert!(report.fault_stage.is_none());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_rejects_single_positive_audio_sample() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-single-audio-sample")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION13.jsonl"),
            json!({
                "kind": "audio",
                "session_id": "SESSION13",
                "video_fps": 60.0,
                "nativeVideoHealth": "rtpFlowing",
                "droppedBackpressure": 0,
                "audioTxCaptured": 300,
                "audioTxEncoded": 300,
                "audioTxSent": 300,
                "audioRxRecv": 290,
                "audioRxDecoded": 290,
                "audioRxPlayed": 290,
                "renderedFrames": 139200,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION13".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 55.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION13",
        )?;

        assert_eq!(report.fault_stage, Some("audio_tx_capture"));
        assert!(doctor_check(&report, "audio_tx_sent").ok);
        assert!(!doctor_check(&report, "audio_activity_continuity").ok);
        assert!(
            doctor_check(&report, "audio_activity_continuity")
                .detail
                .contains("at least two positive rolling samples")
        );
        Ok(())
    }

    #[test]
    fn webrtc_counter_continuity_allows_duplicate_source_total_replay_when_rolling_is_active() {
        let mut rolling = CounterObservation::default();
        let mut total = CounterObservation::default();
        for (sequence, value) in [(1, 230), (2, 225), (3, 240)] {
            let json = json!({ "audioRxRecv": value });
            observe_webrtc_counter(
                &mut rolling,
                Some(&json),
                "",
                "audioRxRecv",
                sequence,
                &format!("rolling:{sequence}"),
            );
        }
        for (sequence, value) in [(1, 1_000), (2, 1_240), (3, 230)] {
            let json = json!({ "recvTotal": value });
            observe_webrtc_counter(
                &mut total,
                Some(&json),
                "",
                "recvTotal",
                sequence,
                &format!("total:{sequence}"),
            );
        }

        assert!(total.decrease_after_positive.is_some());
        assert!(
            describe_webrtc_counter_continuity("audioRxRecv", &rolling, Some(&total)).is_none()
        );
    }

    #[test]
    fn doctor_webrtc_media_rejects_audio_tx_drops() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-audio-tx-drops")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION14.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION14",
                    "video_fps": 60.0,
                    "nativeVideoHealth": "rtpFlowing",
                    "droppedBackpressure": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION14",
                    "audioTxCaptured": 300,
                    "audioTxEncoded": 300,
                    "audioTxSent": 300,
                    "audioTxCapturedTotal": 300,
                    "audioTxEncodedTotal": 300,
                    "audioTxSentTotal": 300,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION14",
                    "audioTxCaptured": 300,
                    "audioTxEncoded": 300,
                    "audioTxSent": 299,
                    "audioTxCapturedTotal": 600,
                    "audioTxEncodedTotal": 600,
                    "audioTxSentTotal": 599,
                    "audioDrops": 1,
                    "audioDropsTotal": 1
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION14",
                    "audioRxRecv": 290,
                    "audioRxDecoded": 290,
                    "audioRxPlayed": 290,
                    "recvTotal": 290,
                    "decodeTotal": 290,
                    "playTotal": 290,
                    "renderedFrames": 139200,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION14",
                    "audioRxRecv": 290,
                    "audioRxDecoded": 290,
                    "audioRxPlayed": 290,
                    "recvTotal": 580,
                    "decodeTotal": 580,
                    "playTotal": 580,
                    "renderedFrames": 139200,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION14".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 55.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION14",
        )?;

        assert_eq!(report.fault_stage, Some("audio_tx_relay_send"));
        assert!(!doctor_check(&report, "audio_activity_continuity").ok);
        assert!(
            doctor_check(&report, "audio_activity_continuity")
                .detail
                .contains("audioDrops=1")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_video_only_accepts_native_rtp_without_audio() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-video-only-native")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION9.log"),
            "\
native-video-health session=SESSION9 state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9 state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/VP8 encoder=libvpx
native-receiver-frame session=SESSION9 size=1280x826 source=receiver-stats packets=23 bytes=22298 framesReceived=1 framesDecoded=1
audioTxUnavailable session=SESSION9 reason=missingViewerEndpoint mediaSession=SESSION9
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION9".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION9",
        )?;

        assert!(doctor_check(&report, "video_fps").ok);
        assert!(
            doctor_check(&report, "video_fps")
                .detail
                .contains("native RTP is flowing")
        );
        assert!(doctor_check(&report, "native_video_health").ok);
        assert!(doctor_check(&report, "native_video_receiver").ok);
        assert!(doctor_check_optional(&report, "audio_relay_startup").is_none());
        assert!(doctor_check_optional(&report, "audio_tx_sent").is_none());
        assert!(doctor_check(&report, "probable_fault_stage").ok);
        assert!(report.fault_stage.is_none());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_high_fps_accepts_structured_native_rtc_stats() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-high-fps-structured-rtc")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION60.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION60",
                    "video_fps": 60.0,
                    "nativeVideoHealth": "rtpFlowing",
                    "submitted": 120,
                    "framesEncoded": 118,
                    "framesSent": 117,
                    "keyFramesEncoded": 2,
                    "packetsSent": 820,
                    "bytesSent": 1_920_000,
                    "codec": "video/H264",
                    "encoder": "VideoToolbox",
                    "qualityLimit": "none",
                    "encodeWidth": 2056,
                    "encodeHeight": 1330,
                    "encodeFPS": 60,
                    "targetBitrate": 18_000_000,
                    "availableOutgoingBitrate": 28_000_000,
                    "currentRTT": 0.036,
                    "remoteRTT": 0.041,
                    "remotePacketsLost": 0,
                    "remoteJitter": 0.002
                })
                .to_string(),
                json!({
                    "kind": "remoteVideoFrameEvidence",
                    "session_id": "SESSION60",
                    "source": "receiver-stats",
                    "packets": 790,
                    "bytes": 1_810_000,
                    "framesReceived": 110,
                    "framesDecoded": 108,
                    "size": "2056x1330",
                    "visibleSize": "2056x1329",
                    "codedSize": "2056x1330"
                })
                .to_string(),
                json!({
                    "kind": "nativeRenderFrame",
                    "session_id": "SESSION60",
                    "source": "rtc-mtl-video-view",
                    "nativeRenderEvidenceSource": "rtc-mtl-video-view",
                    "nativePromotionState": "visible-render-evidence",
                    "size": "2056x1330",
                    "visibleSize": "2056x1329",
                    "codedSize": "2056x1330"
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION60".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 59.01,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION60",
            2056,
            1329,
            true,
        )?;

        assert!(doctor_check(&report, "video_fps").ok);
        assert!(doctor_check(&report, "native_video_health").ok);
        assert!(doctor_check(&report, "native_video_rtc_stats").ok);
        assert!(
            doctor_check(&report, "native_video_rtc_stats")
                .detail
                .contains("targetBitrate=18000000")
        );
        assert!(doctor_check(&report, "native_video_receiver").ok);
        assert!(doctor_check(&report, "visible_native_render").ok);
        assert!(doctor_check(&report, "video_resolution").ok);
        ensure_webrtc_media_doctor_passed(&report)?;
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_high_fps_rejects_missing_native_rtc_stats() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-high-fps-missing-rtc")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION60_MISSING.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION60_MISSING",
                    "video_fps": 60.0,
                    "nativeVideoHealth": "rtpFlowing",
                    "submitted": 120,
                    "framesSent": 117,
                    "packetsSent": 820,
                    "bytesSent": 1_920_000
                })
                .to_string(),
                json!({
                    "kind": "remoteVideoFrameEvidence",
                    "session_id": "SESSION60_MISSING",
                    "source": "receiver-stats",
                    "packets": 790,
                    "bytes": 1_810_000,
                    "framesReceived": 110,
                    "framesDecoded": 108,
                    "size": "2056x1330",
                    "visibleSize": "2056x1329",
                    "codedSize": "2056x1330"
                })
                .to_string(),
                json!({
                    "kind": "nativeRenderFrame",
                    "session_id": "SESSION60_MISSING",
                    "source": "rtc-mtl-video-view",
                    "nativeRenderEvidenceSource": "rtc-mtl-video-view",
                    "nativePromotionState": "visible-render-evidence",
                    "size": "2056x1330",
                    "visibleSize": "2056x1329",
                    "codedSize": "2056x1330"
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION60_MISSING".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 59.01,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION60_MISSING",
            2056,
            1329,
            true,
        )?;

        assert!(doctor_check(&report, "video_fps").ok);
        assert!(doctor_check(&report, "native_video_health").ok);
        assert!(!doctor_check(&report, "native_video_rtc_stats").ok);
        assert!(
            doctor_check(&report, "native_video_rtc_stats")
                .detail
                .contains("high-fps missing codec,encoder,targetBitrate/availableOutgoingBitrate,encoded/sent/rtp counters")
        );
        assert!(doctor_check(&report, "native_video_receiver").ok);
        assert!(doctor_check(&report, "visible_native_render").ok);
        assert!(doctor_check(&report, "video_resolution").ok);
        assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_high_fps_rejects_non_hardware_encoder() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-high-fps-software-encoder")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION60_SOFTWARE.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION60_SOFTWARE",
                    "video_fps": 60.0,
                    "nativeVideoHealth": "rtpFlowing",
                    "submitted": 120,
                    "framesEncoded": 118,
                    "framesSent": 117,
                    "keyFramesEncoded": 2,
                    "packetsSent": 820,
                    "bytesSent": 1_920_000,
                    "codec": "video/H264",
                    "encoder": "libx264",
                    "qualityLimit": "none",
                    "encodeWidth": 2056,
                    "encodeHeight": 1330,
                    "encodeFPS": 60,
                    "targetBitrate": 18_000_000,
                    "availableOutgoingBitrate": 28_000_000
                })
                .to_string(),
                json!({
                    "kind": "remoteVideoFrameEvidence",
                    "session_id": "SESSION60_SOFTWARE",
                    "source": "receiver-stats",
                    "packets": 790,
                    "bytes": 1_810_000,
                    "framesReceived": 110,
                    "framesDecoded": 108,
                    "size": "2056x1330",
                    "visibleSize": "2056x1329",
                    "codedSize": "2056x1330"
                })
                .to_string(),
                json!({
                    "kind": "nativeRenderFrame",
                    "session_id": "SESSION60_SOFTWARE",
                    "source": "rtc-mtl-video-view",
                    "nativeRenderEvidenceSource": "rtc-mtl-video-view",
                    "nativePromotionState": "visible-render-evidence",
                    "size": "2056x1330",
                    "visibleSize": "2056x1329",
                    "codedSize": "2056x1330"
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION60_SOFTWARE".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 59.01,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION60_SOFTWARE",
            2056,
            1329,
            true,
        )?;

        assert!(doctor_check(&report, "video_fps").ok);
        assert!(doctor_check(&report, "native_video_health").ok);
        assert!(!doctor_check(&report, "native_video_rtc_stats").ok);
        assert!(
            doctor_check(&report, "native_video_rtc_stats")
                .detail
                .contains("high-fps missing hardwareEncoder")
        );
        assert!(doctor_check(&report, "native_video_receiver").ok);
        assert!(doctor_check(&report, "visible_native_render").ok);
        assert!(doctor_check(&report, "video_resolution").ok);
        assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_high_fps_requires_visible_native_render() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-high-fps-missing-render")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION60_RENDER_MISSING.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION60_RENDER_MISSING",
                    "video_fps": 60.0,
                    "nativeVideoHealth": "rtpFlowing",
                    "submitted": 120,
                    "framesEncoded": 118,
                    "framesSent": 117,
                    "keyFramesEncoded": 2,
                    "packetsSent": 820,
                    "bytesSent": 1_920_000,
                    "codec": "video/H264",
                    "encoder": "VideoToolbox",
                    "qualityLimit": "none",
                    "encodeWidth": 2056,
                    "encodeHeight": 1330,
                    "encodeFPS": 60,
                    "targetBitrate": 18_000_000,
                    "availableOutgoingBitrate": 28_000_000
                })
                .to_string(),
                json!({
                    "kind": "remoteVideoFrameEvidence",
                    "session_id": "SESSION60_RENDER_MISSING",
                    "source": "receiver-stats",
                    "packets": 790,
                    "bytes": 1_810_000,
                    "framesReceived": 110,
                    "framesDecoded": 108,
                    "size": "2056x1330",
                    "visibleSize": "2056x1329",
                    "codedSize": "2056x1330"
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION60_RENDER_MISSING".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 59.01,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION60_RENDER_MISSING",
            2056,
            1329,
            true,
        )?;

        assert!(doctor_check(&report, "native_video_rtc_stats").ok);
        assert!(doctor_check(&report, "native_video_receiver").ok);
        assert!(!doctor_check(&report, "visible_native_render").ok);
        assert!(
            doctor_check(&report, "visible_native_render")
                .detail
                .contains("requires real visible rendering")
        );
        assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_rejects_receiver_resolution_below_strict_target() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-strict-resolution")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION9_SIZE.log"),
            "\
native-video-health session=SESSION9_SIZE state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_SIZE state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/H264 encoder=VideoToolbox
remote-video-frame-evidence session=SESSION9_SIZE source=receiver-stats type=inbound-rtp packets=240 bytes=254291 framesReceived=32 framesDecoded=32 size=960x620
",
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION9_SIZE".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION9_SIZE",
            2056,
            1329,
            false,
        )?;

        assert!(!doctor_check(&report, "video_resolution").ok);
        assert!(
            doctor_check(&report, "video_resolution")
                .detail
                .contains("960x620 below minimum 2056x1329")
        );
        assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_rejects_receiver_resolution_above_exact_target() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-exact-resolution")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION9_EXACT.log"),
            "\
native-video-health session=SESSION9_EXACT state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_EXACT state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/H264 encoder=VideoToolbox
remote-video-frame-evidence session=SESSION9_EXACT source=receiver-stats type=inbound-rtp packets=240 bytes=254291 framesReceived=32 framesDecoded=32 size=2056x1330
",
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION9_EXACT".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION9_EXACT",
            2056,
            1329,
            true,
        )?;

        assert!(!doctor_check(&report, "video_resolution").ok);
        assert!(
            doctor_check(&report, "video_resolution")
                .detail
                .contains("2056x1330 do not match exact target 2056x1329")
        );
        assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_rejects_exact_size_without_explicit_visible_evidence() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-exact-size-not-visible")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION9_SIZE_ONLY.log"),
            "\
native-video-health session=SESSION9_SIZE_ONLY state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_SIZE_ONLY state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/H264 encoder=VideoToolbox
remote-video-frame-evidence session=SESSION9_SIZE_ONLY source=receiver-stats type=inbound-rtp packets=240 bytes=254291 framesReceived=32 framesDecoded=32 size=2056x1329
",
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION9_SIZE_ONLY".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION9_SIZE_ONLY",
            2056,
            1329,
            true,
        )?;

        assert!(!doctor_check(&report, "video_resolution").ok);
        assert!(
            doctor_check(&report, "video_resolution")
                .detail
                .contains("not reported as explicit visible dimensions")
        );
        assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_accepts_explicit_visible_resolution_with_even_coded_padding()
    -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-visible-crop-resolution")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION9_VISIBLE.log"),
            "\
native-video-health session=SESSION9_VISIBLE state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_VISIBLE state=rtpFlowing submitted=120 framesSent=118 packetsSent=640 bytesSent=755000 codec=video/H264 encoder=VideoToolbox encodeSize=2056x1330
native-receiver-frame session=SESSION9_VISIBLE size=2056x1329 visibleSize=2056x1329 codedSize=2056x1330 evenPadding=1 source=receiver-stats packets=606 bytes=689351 framesReceived=31 framesDecoded=24
remote-video-frame-evidence session=SESSION9_VISIBLE source=receiver-stats type=inbound-rtp packets=900 bytes=900000 framesReceived=80 framesDecoded=80 size=2056x1330
",
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION9_VISIBLE".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION9_VISIBLE",
            2056,
            1329,
            true,
        )?;

        assert!(doctor_check(&report, "native_video_receiver").ok);
        assert!(doctor_check(&report, "video_resolution").ok);
        assert!(
            doctor_check(&report, "native_video_receiver")
                .detail
                .contains("codedSize=2056x1330")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_accepts_periodic_visible_receiver_dimensions_without_counters()
    -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-visible-status-resolution")?;
        std::fs::write(
            artifact_dir.join("ios-real-webrtc.status.log"),
            "\
native-receiver-frame session=SESSION9_VISIBLE_STATUS size=2056x1329 visibleSize=2056x1329 codedSize=2056x1330 evenPadding=1 visibleSource=inferred-even-padding-from-stream-config source=receiver-stats
",
        )?;
        std::fs::write(
            artifact_dir.join("mac.status.log"),
            "\
native-video-health session=SESSION9_VISIBLE_STATUS state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_VISIBLE_STATUS state=rtpFlowing submitted=120 framesSent=118 packetsSent=640 bytesSent=755000 codec=video/H264 encoder=VideoToolbox encodeSize=2056x1330
",
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION9_VISIBLE_STATUS".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION9_VISIBLE_STATUS",
            2056,
            1329,
            true,
        )?;

        assert!(doctor_check(&report, "native_video_receiver").ok);
        assert!(doctor_check(&report, "video_resolution").ok);
        assert!(
            doctor_check(&report, "native_video_receiver")
                .detail
                .contains("visible dimensions observed")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_reads_mac_status_log_for_live_gate_heartbeats() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-mac-status")?;
        std::fs::write(
            artifact_dir.join("mac.status.log"),
            "\
native-video-tx session=SESSION_MAC_STATUS state=rtpFlowing fallbackMode=main submitted=120 framesEncoded=118 framesSent=118 packetsSent=640 bytesSent=755000 codec=video/H264 encoder=VideoToolbox qualityLimit=none encodeSize=2056x1330 encodeFPS=32 targetBitrate=9443000 availableOutgoingBitrate=9443257
native-receiver-frame session=SESSION_MAC_STATUS size=2056x1329 visibleSize=2056x1329 codedSize=2056x1330 evenPadding=1 visibleSource=inferred-even-padding-from-stream source=remote-heartbeat
native-render-frame session=SESSION_MAC_STATUS size=2056x1329 visibleSize=2056x1329 codedSize=2056x1329 source=rtc-mtl-video-view nativeRenderEvidenceSource=rtc-mtl-video-view nativePromotionState=remote-heartbeat
",
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION_MAC_STATUS".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION_MAC_STATUS",
            2056,
            1329,
            true,
        )?;

        assert!(report.target.contains("mac.status.log"));
        assert!(doctor_check(&report, "video_fps").ok);
        assert!(doctor_check(&report, "native_video_rtc_stats").ok);
        assert!(doctor_check(&report, "native_video_receiver").ok);
        assert!(doctor_check(&report, "visible_native_render").ok);
        assert!(doctor_check(&report, "video_resolution").ok);
        ensure_webrtc_media_doctor_passed(&report)?;
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_rejects_receiver_resolution_below_exact_target() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-exact-resolution-low")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION9_LOW.log"),
            "\
native-video-health session=SESSION9_LOW state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_LOW state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/H264 encoder=VideoToolbox
remote-video-frame-evidence session=SESSION9_LOW source=receiver-stats type=inbound-rtp packets=240 bytes=254291 framesReceived=32 framesDecoded=32 size=2056x1328
",
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION9_LOW".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION9_LOW",
            2056,
            1329,
            true,
        )?;

        assert!(!doctor_check(&report, "video_resolution").ok);
        assert!(
            doctor_check(&report, "video_resolution")
                .detail
                .contains("2056x1328 do not match exact target 2056x1329")
        );
        assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_video_only_requires_native_receiver_evidence() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-video-only-missing-rx")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION10.log"),
            "\
native-video-health session=SESSION10 state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION10 state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/VP8 encoder=libvpx
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION10".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION10",
        )?;

        assert!(doctor_check(&report, "video_fps").ok);
        assert!(!doctor_check(&report, "native_video_receiver").ok);
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_rejects_size_only_native_receiver_evidence() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-size-only-rx")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION10_SIZE.log"),
            "\
native-video-health session=SESSION10_SIZE state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION10_SIZE state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/VP8 encoder=libvpx
native-receiver-frame session=SESSION10_SIZE size=1280x826 source=receiver-stats
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION10_SIZE".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION10_SIZE",
        )?;

        assert!(!doctor_check(&report, "native_video_receiver").ok);
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_reads_round_status_logs_for_native_video() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-round-status")?;
        std::fs::write(
            artifact_dir.join("mac_round_1.status.log"),
            "\
native-video-health session=SESSION11 state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION11 state=rtpFlowing submitted=7 framesSent=6 packetsSent=18 bytesSent=24000 codec=video/VP8 encoder=libvpx
",
        )?;
        std::fs::write(
            artifact_dir.join("ios_round_1.status.log.trace.log"),
            "remote-video-frame-evidence session=SESSION11 source=receiver-stats type=inbound-rtp packets=23 bytes=22298 framesReceived=1 framesDecoded=1 size=1280x826\n",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION11".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION11",
        )?;

        assert!(doctor_check(&report, "video_fps").ok);
        assert!(doctor_check(&report, "native_video_receiver").ok);
        assert!(report.target.contains("mac_round_1.status.log"));
        assert!(report.target.contains("ios_round_1.status.log.trace.log"));
        assert!(report.fault_stage.is_none());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_reads_ios_trace_when_artifact_dir_has_many_files() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-many-artifacts")?;
        for index in 0..160 {
            std::fs::write(
                artifact_dir.join(format!("aaa_noise_{index:03}.log")),
                "unrelated session=NOPE\n",
            )?;
        }
        std::fs::write(
            artifact_dir.join("mac.status.log"),
            "\
native-video-health session=SESSION11_MANY state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION11_MANY state=rtpFlowing submitted=7 framesSent=6 packetsSent=18 bytesSent=24000 codec=video/H264 encoder=VideoToolbox
",
        )?;
        std::fs::write(
            artifact_dir.join("ios-real-webrtc.status.log.trace.log"),
            "remote-video-frame-evidence session=SESSION11_MANY source=receiver-stats type=inbound-rtp packets=23 bytes=22298 framesReceived=1 framesDecoded=1 size=2056x1330 visibleSize=2056x1329 codedSize=2056x1330\n",
        )?;

        let report = build_webrtc_media_doctor_report_with_video_requirements(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION11_MANY".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION11_MANY",
            2056,
            1329,
            true,
        )?;

        assert!(doctor_check(&report, "native_video_receiver").ok);
        assert!(doctor_check(&report, "video_resolution").ok);
        assert!(
            report
                .target
                .contains("ios-real-webrtc.status.log.trace.log")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_allows_rx_startup_zero_and_native_fallback_resilience() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-startup-resilience")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION5.jsonl"),
            [
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION5",
                    "audioRxRecv": 1,
                    "audioRxDecoded": 0,
                    "audioRxPlayed": 0,
                    "recvTotal": 1,
                    "decodeTotal": 0,
                    "playTotal": 0,
                    "renderedFrames": 0,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION5",
                    "audioRxRecv": 246,
                    "audioRxDecoded": 237,
                    "audioRxPlayed": 237,
                    "recvTotal": 247,
                    "decodeTotal": 237,
                    "playTotal": 237,
                    "renderedFrames": 113760,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION5",
                    "audioRxRecv": 250,
                    "audioRxDecoded": 250,
                    "audioRxPlayed": 250,
                    "recvTotal": 497,
                    "decodeTotal": 487,
                    "playTotal": 487,
                    "renderedFrames": 120000,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION5",
                    "audioTxCaptured": 327,
                    "audioTxEncoded": 179,
                    "audioTxSent": 179,
                    "audioTxCapturedTotal": 327,
                    "audioTxEncodedTotal": 179,
                    "audioTxSentTotal": 179,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION5",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 577,
                    "audioTxEncodedTotal": 429,
                    "audioTxSentTotal": 429,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "nativeVideoRetry",
                    "session_id": "SESSION5",
                    "nativeVideoHealth": "failedNoRTP",
                    "fallbackProducer": "sckLatest",
                    "probable": "native-video-stalled-fast-retry"
                })
                .to_string(),
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION5",
                    "video_fps": 20.2,
                    "fallbackProducer": "sckLatest",
                    "nativeVideoHealth": "recovering",
                    "droppedBackpressure": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION5".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION5",
        )?;

        assert!(doctor_check(&report, "video_fps").ok);
        assert!(doctor_check(&report, "audio_rx_decoded").ok);
        assert!(doctor_check(&report, "audio_rx_played").ok);
        assert!(doctor_check(&report, "audio_rendered_frames").ok);
        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert!(doctor_check(&report, "audio_playback_continuity").ok);
        assert!(doctor_check(&report, "native_video_health").ok);
        assert_eq!(
            doctor_check(&report, "native_video_health").severity,
            "warn"
        );
        assert!(doctor_check(&report, "probable_fault_stage").ok);
        assert!(report.fault_stage.is_none());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_prefers_explicit_artifact_over_home_logs() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-home")?;
        let home_dir = make_test_dir("doctor-webrtc-media-home-root")?;
        let home_logs = home_dir.join("Library").join("Logs").join("SkyBridge");
        std::fs::create_dir_all(&home_logs)?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION3.log"),
            "stream-stats session=SESSION3 fps=21.0\n",
        )?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION3.jsonl"),
            [
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION3",
                    "audioTxCaptured": 5,
                    "audioTxEncoded": 5,
                    "audioTxSent": 5,
                    "audioTxCapturedTotal": 5,
                    "audioTxEncodedTotal": 5,
                    "audioTxSentTotal": 5,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION3",
                    "audioTxCaptured": 6,
                    "audioTxEncoded": 6,
                    "audioTxSent": 6,
                    "audioTxCapturedTotal": 11,
                    "audioTxEncodedTotal": 11,
                    "audioTxSentTotal": 11,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION3",
                    "audioRxRecv": 5,
                    "audioRxDecoded": 5,
                    "audioRxPlayed": 5,
                    "recvTotal": 5,
                    "decodeTotal": 5,
                    "playTotal": 5,
                    "renderedFrames": 2400,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION3",
                    "audioRxRecv": 6,
                    "audioRxDecoded": 6,
                    "audioRxPlayed": 6,
                    "recvTotal": 11,
                    "decodeTotal": 11,
                    "playTotal": 11,
                    "renderedFrames": 2880,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;
        std::fs::write(
            home_logs.join("webrtc-media-SESSION3.jsonl"),
            [
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION3",
                    "audioTxCaptured": 5,
                    "audioTxEncoded": 5,
                    "audioTxSent": 5,
                    "audioTxCapturedTotal": 5,
                    "audioTxEncodedTotal": 5,
                    "audioTxSentTotal": 5,
                    "audioDrops": 0,
                    "audioDropsTotal": 0,
                    "nativeVideoHealth": "active"
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION3",
                    "audioTxCaptured": 6,
                    "audioTxEncoded": 6,
                    "audioTxSent": 6,
                    "audioTxCapturedTotal": 11,
                    "audioTxEncodedTotal": 11,
                    "audioTxSentTotal": 11,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION3",
                    "audioRxRecv": 5,
                    "audioRxDecoded": 5,
                    "audioRxPlayed": 5,
                    "recvTotal": 5,
                    "decodeTotal": 5,
                    "playTotal": 5,
                    "renderedFrames": 2400,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION3",
                    "audioRxRecv": 6,
                    "audioRxDecoded": 6,
                    "audioRxPlayed": 6,
                    "recvTotal": 11,
                    "decodeTotal": 11,
                    "playTotal": 11,
                    "renderedFrames": 2880,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let previous_home = std::env::var_os("HOME");
        unsafe {
            std::env::set_var("HOME", &home_dir);
        }
        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION3".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION3",
        );
        restore_env_var("HOME", previous_home);
        let report = report?;

        assert!(doctor_check(&report, "video_fps").ok);
        assert!(doctor_check(&report, "audio_rx_played").ok);
        assert!(doctor_check(&report, "audio_rendered_frames").ok);
        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert!(doctor_check(&report, "audio_playback_continuity").ok);
        assert!(report.target.contains("webrtc-media-SESSION3.jsonl"));
        assert!(!report.target.contains(&home_logs.display().to_string()));
        Ok(())
    }

    #[test]
    fn diagnose_latest_resolves_newest_session() -> Result<()> {
        let artifact_dir = make_test_dir("diagnose-webrtc-latest")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-OLD.jsonl"),
            json!({
                "timestamp": "2026-05-03T09:00:00Z",
                "session_id": "OLD",
                "kind": "videoStats",
                "video_fps": 20
            })
            .to_string(),
        )?;
        std::fs::write(
            artifact_dir.join("webrtc-media-NEW.jsonl"),
            json!({
                "timestamp": "2026-05-03T09:01:00Z",
                "session_id": "NEW",
                "kind": "videoStats",
                "video_fps": 20
            })
            .to_string(),
        )?;

        let resolved = resolve_webrtc_media_session_arg(None, true, Some(&artifact_dir), None)?;
        assert_eq!(resolved, "NEW");
        assert!(
            resolve_webrtc_media_session_arg(Some("NEW"), true, Some(&artifact_dir), None).is_err()
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_detects_zero_rx_after_playback() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-zero-rx")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION4.log"),
            "\
stream-stats session=SESSION4 fps=21.0
audio event session=SESSION4 audioTxCaptured=20 audioTxEncoded=20 audioTxSent=20 audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10
audio-rx session=SESSION4 audioRxRecv=0 audioRxDecoded=0 audioRxPlayed=0
native-video-health session=SESSION4 state=active
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION4".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION4",
        )?;

        assert_eq!(report.fault_stage, Some("audio_rx_relay_recv"));
        assert!(!doctor_check(&report, "audio_rx_recv").ok);
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_ignores_audio_rx_no_positive_heartbeat_placeholder() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-rx-placeholder")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION4B.log"),
            "\
stream-stats session=SESSION4B fps=31.0
native-video-health session=SESSION4B state=rtpFlowing submitted=120 framesSent=120 packetsSent=240 bytesSent=4096
native-receiver-frame session=SESSION4B size=2056x1329 visibleSize=2056x1329 codedSize=2056x1329 source=receiver-stats
native-render-frame session=SESSION4B size=2056x1329 visibleSize=2056x1329 codedSize=2056x1329 source=rtc-mtl-video-view
audio event session=SESSION4B audioTxCaptured=20 audioTxEncoded=20 audioTxSent=20 audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10 recvTotal=10 decodeTotal=10 playTotal=10 renderedFrames=9600
audio-rx session=SESSION4B source=remote-heartbeat audioRxDatagrams=0 audioRxRecv=0 audioRxDecoded=0 audioRxPlayed=0 recvTotal=0 decodeTotal=0 playTotal=0 rejected=0 jitterEvicted=0 playbackDrop=0 renderedFrames=- underflow=- rebuffer=- probable=audio-rx-no-positive-evidence
audio event session=SESSION4B audioTxCaptured=20 audioTxEncoded=20 audioTxSent=20 audioRxRecv=12 audioRxDecoded=12 audioRxPlayed=12 recvTotal=22 decodeTotal=22 playTotal=22 renderedFrames=19200
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION4B".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION4B",
        )?;

        assert!(doctor_check(&report, "audio_rx_recv").ok);
        assert!(doctor_check(&report, "audio_rx_decoded").ok);
        assert!(doctor_check(&report, "audio_rx_played").ok);
        assert!(doctor_check(&report, "audio_playback_continuity").ok);
        assert_eq!(report.fault_stage, None);
        ensure_webrtc_media_doctor_passed(&report)?;
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_fails_audio_underflow_even_with_positive_playback_counters() -> Result<()>
    {
        let artifact_dir = make_test_dir("doctor-webrtc-media-audio-underflow")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION12.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION12",
                    "video_fps": 60.0,
                    "nativeVideoHealth": "rtpFlowing",
                    "droppedBackpressure": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION12",
                    "audioTxCaptured": 300,
                    "audioTxEncoded": 300,
                    "audioTxSent": 300,
                    "audioTxCapturedTotal": 300,
                    "audioTxEncodedTotal": 300,
                    "audioTxSentTotal": 300,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION12",
                    "audioTxCaptured": 300,
                    "audioTxEncoded": 300,
                    "audioTxSent": 300,
                    "audioTxCapturedTotal": 600,
                    "audioTxEncodedTotal": 600,
                    "audioTxSentTotal": 600,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION12",
                    "audioRxRecv": 290,
                    "audioRxDecoded": 290,
                    "audioRxPlayed": 290,
                    "recvTotal": 290,
                    "decodeTotal": 290,
                    "playTotal": 290,
                    "renderedFrames": 139200,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION12",
                    "audioRxRecv": 290,
                    "audioRxDecoded": 290,
                    "audioRxPlayed": 290,
                    "recvTotal": 580,
                    "decodeTotal": 580,
                    "playTotal": 580,
                    "renderedFrames": 139200,
                    "underflow": 2,
                    "rebuffer": 1,
                    "playbackDrop": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION12".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 55.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION12",
        )?;

        assert_eq!(report.fault_stage, Some("audio_rx_playback"));
        assert!(doctor_check(&report, "audio_rx_played").ok);
        assert!(doctor_check(&report, "audio_rendered_frames").ok);
        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert!(!doctor_check(&report, "audio_playback_continuity").ok);
        assert!(
            doctor_check(&report, "audio_playback_continuity")
                .detail
                .contains("underflow=2")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_fails_audio_jitter_eviction_without_rebuffer() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-audio-jitter-evicted")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION14.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION14",
                    "video_fps": 60.0,
                    "nativeVideoHealth": "rtpFlowing"
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION14",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 250,
                    "audioTxEncodedTotal": 250,
                    "audioTxSentTotal": 250,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION14",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 500,
                    "audioTxEncodedTotal": 500,
                    "audioTxSentTotal": 500,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION14",
                    "audioRxRecv": 250,
                    "audioRxDecoded": 248,
                    "audioRxPlayed": 250,
                    "recvTotal": 250,
                    "decodeTotal": 248,
                    "playTotal": 250,
                    "renderedFrames": 240000,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION14",
                    "audioRxRecv": 250,
                    "audioRxDecoded": 220,
                    "audioRxPlayed": 230,
                    "recvTotal": 500,
                    "decodeTotal": 468,
                    "playTotal": 480,
                    "renderedFrames": 240000,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 26
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION14".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 55.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION14",
        )?;

        assert_eq!(report.fault_stage, Some("audio_rx_playback"));
        assert!(!doctor_check(&report, "audio_playback_continuity").ok);
        assert!(
            doctor_check(&report, "audio_playback_continuity")
                .detail
                .contains("jitterEvicted=26")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_fails_audio_playout_pressure_without_underflow() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-audio-playout-pressure")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION19.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION19",
                    "video_fps": 32.0,
                    "nativeVideoHealth": "rtpFlowing"
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION19",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 250,
                    "audioTxEncodedTotal": 250,
                    "audioTxSentTotal": 250,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION19",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 500,
                    "audioTxEncodedTotal": 500,
                    "audioTxSentTotal": 500,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION19",
                    "audioRxRecv": 248,
                    "audioRxDecoded": 248,
                    "audioRxPlayed": 250,
                    "recvTotal": 248,
                    "decodeTotal": 248,
                    "playTotal": 250,
                    "renderedFrames": 240000,
                    "jitterLate": 0,
                    "scheduleLeadMs": 30,
                    "audioArrivalP95Ms": 70,
                    "audioArrivalMaxMs": 103,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION19",
                    "audioRxRecv": 248,
                    "audioRxDecoded": 242,
                    "audioRxPlayed": 247,
                    "recvTotal": 496,
                    "decodeTotal": 490,
                    "playTotal": 497,
                    "renderedFrames": 240960,
                    "jitterLate": 2,
                    "plcFrames": 5,
                    "plcRatio": 0.020,
                    "scheduleLeadMs": -50,
                    "audioArrivalP95Ms": 175.6,
                    "audioArrivalMaxMs": 679.2,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION19".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION19",
        )?;

        assert_eq!(report.fault_stage, Some("audio_rx_playback"));
        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert!(!doctor_check(&report, "audio_playback_continuity").ok);
        let detail = &doctor_check(&report, "audio_playback_continuity").detail;
        assert!(detail.contains("playout pressure"));
        assert!(detail.contains("audioArrivalMaxMs=679"));
        assert!(detail.contains("jitterLate=2"));
        assert!(detail.contains("plcFrames=5"));
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_allows_high_target_queue_schedule_shortfall() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-audio-target-shortfall")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION19B.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION19B",
                    "video_fps": 32.0,
                    "nativeVideoHealth": "rtpFlowing"
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION19B",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 250,
                    "audioTxEncodedTotal": 250,
                    "audioTxSentTotal": 250,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION19B",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 500,
                    "audioTxEncodedTotal": 500,
                    "audioTxSentTotal": 500,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION19B",
                    "audioRxRecv": 250,
                    "audioRxDecoded": 250,
                    "audioRxPlayed": 250,
                    "recvTotal": 250,
                    "decodeTotal": 250,
                    "playTotal": 250,
                    "renderedFrames": 240000,
                    "jitterLate": 0,
                    "plcFrames": 0,
                    "plcRatio": 0,
                    "audioQueuedMs": 2370.0,
                    "audioTargetQueuedMs": 2340.0,
                    "scheduleLeadMs": 30.0,
                    "audioArrivalP95Ms": 70.0,
                    "audioArrivalMaxMs": 103.0,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION19B",
                    "audioRxRecv": 249,
                    "audioRxDecoded": 245,
                    "audioRxPlayed": 246,
                    "recvTotal": 499,
                    "decodeTotal": 495,
                    "playTotal": 496,
                    "renderedFrames": 240480,
                    "jitterLate": 0,
                    "plcFrames": 1,
                    "plcRatio": 0.004,
                    "audioQueuedMs": 2155.0,
                    "audioTargetQueuedMs": 2340.0,
                    "scheduleLeadMs": -185.0,
                    "audioArrivalP95Ms": 56.0,
                    "audioArrivalMaxMs": 170.0,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION19B".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION19B",
        )?;

        assert!(doctor_check(&report, "audio_playback_continuity").ok);
        assert_ne!(report.fault_stage, Some("audio_rx_playback"));
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_allows_rendered_frames_window_reset() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-rendered-window-reset")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION19C.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION19C",
                    "video_fps": 32.0,
                    "nativeVideoHealth": "rtpFlowing"
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION19C",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 250,
                    "audioTxEncodedTotal": 250,
                    "audioTxSentTotal": 250,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION19C",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 500,
                    "audioTxEncodedTotal": 500,
                    "audioTxSentTotal": 500,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION19C",
                    "audioRxRecv": 250,
                    "audioRxDecoded": 250,
                    "audioRxPlayed": 250,
                    "recvTotal": 250,
                    "decodeTotal": 250,
                    "playTotal": 250,
                    "renderedFrames": 240000,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION19C",
                    "audioRxRecv": 250,
                    "audioRxDecoded": 250,
                    "audioRxPlayed": 250,
                    "recvTotal": 500,
                    "decodeTotal": 500,
                    "playTotal": 500,
                    "renderedFrames": 0,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION19C".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION19C",
        )?;

        assert!(doctor_check(&report, "audio_rendered_frames").ok);
        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert_ne!(report.fault_stage, Some("audio_rx_playback"));
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_allows_absorbed_arrival_spike() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-absorbed-arrival-spike")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION19D.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION19D",
                    "video_fps": 32.0,
                    "nativeVideoHealth": "rtpFlowing"
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION19D",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 250,
                    "audioTxEncodedTotal": 250,
                    "audioTxSentTotal": 250,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION19D",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 500,
                    "audioTxEncodedTotal": 500,
                    "audioTxSentTotal": 500,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION19D",
                    "audioRxRecv": 250,
                    "audioRxDecoded": 250,
                    "audioRxPlayed": 250,
                    "recvTotal": 250,
                    "decodeTotal": 250,
                    "playTotal": 250,
                    "renderedFrames": 240000,
                    "jitterLate": 0,
                    "plcFrames": 0,
                    "plcRatio": 0,
                    "audioQueuedMs": 2380.0,
                    "audioTargetQueuedMs": 2340.0,
                    "scheduleLeadMs": 40.0,
                    "audioArrivalP95Ms": 75.0,
                    "audioArrivalMaxMs": 672.0,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION19D",
                    "audioRxRecv": 250,
                    "audioRxDecoded": 250,
                    "audioRxPlayed": 250,
                    "recvTotal": 500,
                    "decodeTotal": 500,
                    "playTotal": 500,
                    "renderedFrames": 240000,
                    "jitterLate": 0,
                    "plcFrames": 0,
                    "plcRatio": 0,
                    "audioQueuedMs": 2380.0,
                    "audioTargetQueuedMs": 2340.0,
                    "scheduleLeadMs": 40.0,
                    "audioArrivalP95Ms": 80.0,
                    "audioArrivalMaxMs": 136.0,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION19D".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION19D",
        )?;

        assert!(doctor_check(&report, "audio_playback_continuity").ok);
        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert_ne!(report.fault_stage, Some("audio_rx_playback"));
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_allows_bounded_soft_bridged_underflow_without_rebuffer() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-bounded-soft-bridged-underflow")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION13A.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION13A",
                    "video_fps": 60.0,
                    "nativeVideoHealth": "rtpFlowing"
                })
                .to_string(),
                json!({
                    "kind": "remoteVideoFrameEvidence",
                    "session_id": "SESSION13A",
                    "source": "receiver-stats",
                    "size": "960x620",
                    "packets": 23,
                    "bytes": 22298,
                    "framesReceived": 1,
                    "framesDecoded": 1
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION13A",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 250,
                    "audioTxEncodedTotal": 250,
                    "audioTxSentTotal": 250,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION13A",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 500,
                    "audioTxEncodedTotal": 500,
                    "audioTxSentTotal": 500,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION13A",
                    "audioRxRecv": 230,
                    "audioRxDecoded": 227,
                    "audioRxPlayed": 250,
                    "recvTotal": 230,
                    "decodeTotal": 227,
                    "playTotal": 250,
                    "renderedFrames": 240240,
                    "underflow": 0,
                    "bridgedUnderflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION13A",
                    "audioRxRecv": 248,
                    "audioRxDecoded": 248,
                    "audioRxPlayed": 250,
                    "recvTotal": 478,
                    "decodeTotal": 475,
                    "playTotal": 500,
                    "renderedFrames": 240000,
                    "underflow": 2,
                    "bridgedUnderflow": 960,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION13A".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 55.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION13A",
        )?;

        assert_eq!(report.fault_stage, None);
        assert!(doctor_check(&report, "audio_rx_played").ok);
        assert!(doctor_check(&report, "audio_rendered_frames").ok);
        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert!(doctor_check(&report, "audio_playback_continuity").ok);
        assert!(
            doctor_check(&report, "audio_playback_continuity")
                .detail
                .contains("bounded soft-bridged")
        );
        ensure_webrtc_media_doctor_passed(&report)?;
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_fails_excessive_soft_bridged_underflow_without_rebuffer() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-soft-bridged-underflow")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION13.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION13",
                    "video_fps": 60.0,
                    "nativeVideoHealth": "rtpFlowing"
                })
                .to_string(),
                json!({
                    "kind": "remoteVideoFrameEvidence",
                    "session_id": "SESSION13",
                    "source": "receiver-stats",
                    "size": "960x620",
                    "packets": 23,
                    "bytes": 22298,
                    "framesReceived": 1,
                    "framesDecoded": 1
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION13",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 250,
                    "audioTxEncodedTotal": 250,
                    "audioTxSentTotal": 250,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION13",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 500,
                    "audioTxEncodedTotal": 500,
                    "audioTxSentTotal": 500,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION13",
                    "audioRxRecv": 230,
                    "audioRxDecoded": 227,
                    "audioRxPlayed": 250,
                    "recvTotal": 230,
                    "decodeTotal": 227,
                    "playTotal": 250,
                    "renderedFrames": 240240,
                    "underflow": 0,
                    "bridgedUnderflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION13",
                    "audioRxRecv": 222,
                    "audioRxDecoded": 202,
                    "audioRxPlayed": 228,
                    "recvTotal": 452,
                    "decodeTotal": 429,
                    "playTotal": 478,
                    "renderedFrames": 223680,
                    "underflow": 72,
                    "bridgedUnderflow": 17280,
                    "rebuffer": 0,
                    "playbackDrop": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION13".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 55.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION13",
        )?;

        assert_eq!(report.fault_stage, Some("audio_rx_playback"));
        assert!(doctor_check(&report, "audio_rx_played").ok);
        assert!(doctor_check(&report, "audio_rendered_frames").ok);
        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert!(!doctor_check(&report, "audio_playback_continuity").ok);
        assert!(
            doctor_check(&report, "audio_playback_continuity")
                .detail
                .contains("underflow=72")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_classifies_sck_capture_stall_before_rtp_stall() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-sck-capture-stall")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION_SCK0.jsonl"),
            [
                json!({
                    "kind": "sckTxTelemetry",
                    "session_id": "SESSION_SCK0",
                    "sckCaptured": 60,
                    "sckMeaningful": 0,
                    "sckEncoded": 0,
                    "sckCaptureFPS": 60.0,
                    "sckMeaningfulFPS": 0.0,
                    "sckEncodedFPS": 0.0,
                    "codec": "h264"
                })
                .to_string(),
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION_SCK0",
                    "video_fps": 1.0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION_SCK0".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION_SCK0",
        )?;

        assert_eq!(report.fault_stage, Some("sck_capture_stalled"));
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_classifies_vt_encode_stall_before_rtp_stall() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-vt-encode-stall")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION_VT0.jsonl"),
            [
                json!({
                    "kind": "sckTxTelemetry",
                    "session_id": "SESSION_VT0",
                    "sckCaptured": 60,
                    "sckMeaningful": 60,
                    "sckEncoded": 0,
                    "sckCaptureFPS": 60.0,
                    "sckMeaningfulFPS": 60.0,
                    "sckEncodedFPS": 0.0,
                    "sckEncodeLatencyP50Ms": 18.0,
                    "sckEncodeLatencyP95Ms": 42.0,
                    "sckEncodeLatencyMaxMs": 47.0,
                    "sckEncodeFailures": 3,
                    "codec": "h264"
                })
                .to_string(),
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION_VT0",
                    "video_fps": 1.0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION_VT0".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION_VT0",
        )?;

        assert_eq!(report.fault_stage, Some("vt_encode_stalled"));
        assert!(!doctor_check(&report, "sck_vt_encode_latency").ok);
        assert!(
            doctor_check(&report, "sck_vt_encode_latency")
                .detail
                .contains("failures=3")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_classifies_vt_encode_slow_before_rtp_stall() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-vt-encode-slow")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION_VT_SLOW.jsonl"),
            [
                json!({
                    "kind": "sckTxTelemetry",
                    "session_id": "SESSION_VT_SLOW",
                    "sckCaptured": 60,
                    "sckMeaningful": 60,
                    "sckEncoded": 60,
                    "sckCaptureFPS": 60.0,
                    "sckMeaningfulFPS": 60.0,
                    "sckEncodedFPS": 60.0,
                    "sckEncodeLatencyP50Ms": 18.0,
                    "sckEncodeLatencyP95Ms": 31.0,
                    "sckEncodeLatencyMaxMs": 38.0,
                    "sckEncodeFailures": 0,
                    "codec": "h264"
                })
                .to_string(),
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION_VT_SLOW",
                    "video_fps": 18.0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION_VT_SLOW".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 59.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION_VT_SLOW",
        )?;

        assert_eq!(report.fault_stage, Some("vt_encode_slow"));
        assert!(!doctor_check(&report, "sck_vt_encode_latency").ok);
        assert!(
            doctor_check(&report, "sck_vt_encode_latency")
                .detail
                .contains("p95Ms=31.000")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_detects_relay_bind_ack_timeout() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-relay-bind-timeout")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION7.jsonl"),
            json!({
                "kind": "audioRxRelayBind",
                "session_id": "SESSION7",
                "stage": "relayBindAckTimedOut",
                "probable": "public-udp-relay-unreachable-or-wrong-port"
            })
            .to_string(),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION7".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION7",
        )?;

        assert_eq!(report.fault_stage, Some("audio_rx_relay_recv"));
        assert!(!doctor_check(&report, "audio_relay_startup").ok);
        assert!(
            doctor_check(&report, "audio_relay_startup")
                .detail
                .contains("relayBindAckTimedOut")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_accepts_optimistic_sender_bind_pending_with_rx_flow() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-optimistic-tx-bind-pending")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION17.jsonl"),
            [
                json!({
                    "kind": "videoStats",
                    "session_id": "SESSION17",
                    "video_fps": 32.0,
                    "nativeVideoHealth": "rtpFlowing",
                    "fallbackProducer": "initial",
                    "droppedBackpressure": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRelayBindSent",
                    "session_id": "SESSION17",
                    "probable": "relay-bind-sent"
                })
                .to_string(),
                json!({
                    "kind": "audioTxRelayBindAckPending",
                    "session_id": "SESSION17",
                    "probable": "relay-bind-ack-pending-media-optimistic"
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION17",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 250,
                    "audioTxEncodedTotal": 250,
                    "audioTxSentTotal": 250,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION17",
                    "audioTxCaptured": 251,
                    "audioTxEncoded": 251,
                    "audioTxSent": 251,
                    "audioTxCapturedTotal": 501,
                    "audioTxEncodedTotal": 501,
                    "audioTxSentTotal": 501,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION17",
                    "audioRxRecv": 248,
                    "audioRxDecoded": 248,
                    "audioRxPlayed": 250,
                    "recvTotal": 248,
                    "decodeTotal": 248,
                    "playTotal": 250,
                    "renderedFrames": 240000,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxRolling",
                    "session_id": "SESSION17",
                    "audioRxRecv": 249,
                    "audioRxDecoded": 249,
                    "audioRxPlayed": 251,
                    "recvTotal": 497,
                    "decodeTotal": 497,
                    "playTotal": 501,
                    "renderedFrames": 240960,
                    "underflow": 0,
                    "rebuffer": 0,
                    "playbackDrop": 0,
                    "jitterEvicted": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION17".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION17",
        )?;

        assert!(doctor_check(&report, "audio_activity_continuity").ok);
        assert!(doctor_check(&report, "audio_playback_continuity").ok);
        assert!(doctor_check(&report, "audio_relay_startup").ok);
        assert!(doctor_check(&report, "probable_fault_stage").ok);
        assert!(report.fault_stage.is_none());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_does_not_mask_sent_audio_with_late_bind_warning() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-tx-sent-after-bind-warning")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION8.log"),
            "\
audioTxRelayBindTimedOut session=SESSION8 leaseSource=viewerEndpoint endpoint=82.156.225.30:3478 token=present
audioTxStartup session=SESSION8 audioTxCaptured=20 audioTxEncoded=20 audioTxSent=20
audio-rx session=SESSION8 audioRxRecv=0 audioRxDecoded=0 audioRxPlayed=0
stream-stats session=SESSION8 fps=21.0
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION8".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION8",
        )?;

        assert_eq!(report.fault_stage, Some("audio_tx_relay_bind"));
        assert!(!doctor_check(&report, "audio_relay_startup").ok);
        assert!(
            doctor_check(&report, "audio_relay_startup")
                .detail
                .contains("receiver has no audio")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_flags_optimistic_tx_bind_pending_when_rx_is_zero() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-tx-bind-pending-rx-zero")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION18.jsonl"),
            [
                json!({
                    "kind": "audioTxRelayBindAckPending",
                    "session_id": "SESSION18",
                    "probable": "relay-bind-ack-pending-media-optimistic"
                })
                .to_string(),
                json!({
                    "kind": "audioTxRolling",
                    "session_id": "SESSION18",
                    "audioTxCaptured": 250,
                    "audioTxEncoded": 250,
                    "audioTxSent": 250,
                    "audioTxCapturedTotal": 250,
                    "audioTxEncodedTotal": 250,
                    "audioTxSentTotal": 250,
                    "audioDrops": 0,
                    "audioDropsTotal": 0
                })
                .to_string(),
                json!({
                    "kind": "audioRxStartup",
                    "session_id": "SESSION18",
                    "audioRxDatagrams": 0,
                    "audioRxRecv": 0,
                    "audioRxDecoded": 0,
                    "audioRxPlayed": 0,
                    "recvTotal": 0,
                    "decodeTotal": 0,
                    "playTotal": 0
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION18".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 30.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION18",
        )?;

        assert_eq!(report.fault_stage, Some("audio_tx_relay_bind"));
        assert!(!doctor_check(&report, "audio_relay_startup").ok);
        assert!(
            doctor_check(&report, "audio_relay_startup")
                .detail
                .contains("relay bind ACK is still pending")
        );
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_flags_low_fps_fallback_producer() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-low-fps-fallback")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION8.log"),
            "\
stream-stats session=SESSION8 fps=0.8 fallbackProducer=cgdisplayEmergency cgdisplayCaptureFPS=0.4 directEncodedFPS=0.6
fallbackProducerSwitch session=SESSION8 producer=cgdisplayEmergency reason=sck-latest-stale-or-missing sckLatestAgeMs=1200 holdMs=10000
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION8".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 20.0,
                require_audio: true,
                output: OutputOptions { json: true },
            },
            "SESSION8",
        )?;

        assert_eq!(report.fault_stage, Some("fallback_capture_stalled"));
        assert!(!doctor_check(&report, "video_fps").ok);
        assert!(!doctor_check(&report, "stale_fallback").ok);
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_fails_strict_media_failure() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-strict-failed")?;
        std::fs::write(
            artifact_dir.join("webrtc-session-SESSION19.log"),
            "\
native-video-health session=SESSION19 state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION19 state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/VP8 encoder=libvpx
remote-video-frame-evidence session=SESSION19 source=receiver-stats type=inbound-rtp packets=23 bytes=22298 framesReceived=1 framesDecoded=1 size=1280x826
strict-media-failed session=SESSION19 reason=fallback-screen-frame-received format=jpeg size=1280x826
",
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION19".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION19",
        )?;

        assert_eq!(report.fault_stage, Some("strict_media_failure"));
        assert!(!doctor_check(&report, "strict_media_failure").ok);
        assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
        Ok(())
    }

    #[test]
    fn doctor_webrtc_media_fails_structured_strict_media_failure() -> Result<()> {
        let artifact_dir = make_test_dir("doctor-webrtc-media-structured-strict-failed")?;
        std::fs::write(
            artifact_dir.join("webrtc-media-SESSION20.jsonl"),
            [
                json!({
                    "kind": "nativeVideoHealth",
                    "session_id": "SESSION20",
                    "nativeVideoHealth": "rtpFlowing",
                    "submitted": 54,
                    "framesSent": 48,
                    "packetsSent": 269,
                    "bytesSent": 269590
                })
                .to_string(),
                json!({
                    "kind": "remoteVideoFrameEvidence",
                    "session_id": "SESSION20",
                    "source": "receiver-stats",
                    "packets": 23,
                    "bytes": 22298,
                    "framesReceived": 1,
                    "framesDecoded": 1,
                    "size": "1280x826"
                })
                .to_string(),
                json!({
                    "kind": "strictMediaFailure",
                    "session_id": "SESSION20",
                    "probable": "fallback-screen-frame",
                    "validationMode": "strict",
                    "failureReason": "fallback-screen-frame-received"
                })
                .to_string(),
            ]
            .join("\n"),
        )?;

        let report = build_webrtc_media_doctor_report(
            &WebRtcMediaDoctorArgs {
                session_id: Some("SESSION20".to_owned()),
                latest: false,
                artifact_dir: Some(artifact_dir),
                log_file: None,
                since_seconds: 120,
                min_fps: 1.0,
                require_audio: false,
                output: OutputOptions { json: true },
            },
            "SESSION20",
        )?;

        assert_eq!(report.fault_stage, Some("strict_media_failure"));
        assert!(
            doctor_check(&report, "strict_media_failure")
                .detail
                .contains("fallback-screen-frame-received")
        );
        assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
        Ok(())
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

    fn doctor_check<'a>(report: &'a DoctorProbeReport, name: &str) -> &'a DoctorCheck {
        report
            .checks
            .iter()
            .find(|check| check.name == name)
            .unwrap_or_else(|| panic!("{name} check missing"))
    }

    fn doctor_check_optional<'a>(
        report: &'a DoctorProbeReport,
        name: &str,
    ) -> Option<&'a DoctorCheck> {
        report.checks.iter().find(|check| check.name == name)
    }

    fn make_test_dir(name: &str) -> Result<PathBuf> {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "skybridge-cli-{name}-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&path)?;
        Ok(path)
    }

    fn restore_env_var(key: &str, previous: Option<std::ffi::OsString>) {
        unsafe {
            if let Some(previous) = previous {
                std::env::set_var(key, previous);
            } else {
                std::env::remove_var(key);
            }
        }
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
