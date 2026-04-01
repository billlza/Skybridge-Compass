mod nearby;
mod transfer;

use std::fs::File as StdFile;
use std::path::PathBuf;
use std::process::{Child, Command as ProcessCommand, Stdio};
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use clap::{Args, Parser, Subcommand, ValueEnum};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use serde_json::json;
use skybridge_agent::{
    AgentCryptoMode, LocalSessionTransferSmokeOptions, clear_auth_session, ensure_device_identity,
    ensure_rust_pqc_identity, load_auth_session, load_auth_session_source, load_health_snapshot,
    load_session_registry, refresh_auth_session_if_needed, remove_managed_session_control,
    remove_session_runtime, resolve_paths, run_agent, run_local_session_transfer_smoke,
    signing_binding, signing_signature, store_auth_session, store_auth_session_source,
    store_session_registry, update_enrollment_status,
    upsert_managed_session_control, upsert_session_runtime,
};
use skybridge_core::{
    AgentRuntimeStatus, AuthState, ConnectionCodeLease, ConnectionCodeLookup, CryptoSuite,
    CurrentPathOriginPolicy, EnrollmentStatus, InboundMessage, ManagedSessionControl,
    NativeWebRtcConfig, NativeWebRtcEvent, NativeWebRtcSession, NebulaOAuthClient,
    PqcResponderConfig, ProtocolIdentityBinding, ProtocolSigningAlgorithm,
    RuntimeSessionKeepaliveStatus, RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionSource,
    RuntimeSessionState, RuntimeSessionTransportEvent, SessionReadiness, SignalServerClient,
    SignalingConnection, SignalingLifecycleEvent, SignalingLifecyclePhase, SignalingRuntimeEvent,
    derive_tenant_identifier, generate_pkce_pair, make_join_envelope, make_runtime_id,
    should_refresh_access_token,
};
use time::OffsetDateTime;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use transfer::FileSendTransport;
use url::Url;

const ENV_PQC_BRIDGE_IDENTITY: &str = "SKYBRIDGE_PQC_BRIDGE_IDENTITY";
const GUI_AUTH_KEYCHAIN_SERVICE: &str = "com.skybridge.compass.authsession";
const GUI_AUTH_KEYCHAIN_ACCOUNT: &str = "primary";
const GUI_SUPABASE_SERVICE: &str = "SkyBridge.Supabase";
const CLI_LOGIN_CLIENT_ID: &str = "skybridge_compass_cli";
const DEFAULT_LOGIN_WEB_BASE_URL: &str = "https://skybridge.com";
const DEFAULT_LOGIN_API_BASE_URL: &str = "https://api.skybridge.com";
const AUTH_SOURCE_GUI_SESSION_REUSE: &str = "gui_session_reuse";
const AUTH_SOURCE_BROWSER_CLI_LOGIN: &str = "browser_cli_login";
const AUTH_SOURCE_LEGACY_NEBULA_OAUTH: &str = "legacy_nebula_oauth";

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum CliCryptoMode {
    Auto,
    Xwing,
    Mlkem,
    Classic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum TestMode {
    Local,
    Code,
}

impl CliCryptoMode {
    fn requested_pqc_suite(self) -> Option<CryptoSuite> {
        match self {
            Self::Xwing => Some(CryptoSuite::XWING_MLDSA),
            Self::Mlkem => Some(CryptoSuite::MLKEM768_MLDSA65),
            Self::Auto | Self::Classic => None,
        }
    }

    fn supported_pqc_suites(self) -> Vec<CryptoSuite> {
        match self {
            Self::Auto => vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
            Self::Xwing => vec![CryptoSuite::XWING_MLDSA],
            Self::Mlkem => vec![CryptoSuite::MLKEM768_MLDSA65],
            Self::Classic => Vec::new(),
        }
    }

    fn allows_classic(self) -> bool {
        matches!(self, Self::Auto | Self::Classic)
    }
}

impl From<CliCryptoMode> for AgentCryptoMode {
    fn from(value: CliCryptoMode) -> Self {
        match value {
            CliCryptoMode::Auto => AgentCryptoMode::Auto,
            CliCryptoMode::Xwing => AgentCryptoMode::Xwing,
            CliCryptoMode::Mlkem => AgentCryptoMode::Mlkem,
            CliCryptoMode::Classic => AgentCryptoMode::Classic,
        }
    }
}

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
    Test(TestCommand),
    Session(SessionCommand),
    Disconnect(DisconnectCommand),
    File(FileCommand),
    Doctor(OutputOptions),
    Logs(LogsCommand),
    Metrics(OutputOptions),
    #[command(hide = true)]
    Internal(InternalCommand),
    Version,
}

#[derive(Debug, Args)]
struct LoginCommand {
    #[arg(long, help = "Force browser login instead of reusing the macOS GUI session")]
    browser: bool,
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
struct DisconnectCommand {
    session_id: String,
}

#[derive(Debug, Args)]
struct ConnectCommand {
    code: String,
    #[arg(long, default_value_t = 5)]
    hold_seconds: u64,
    #[arg(long, value_enum, default_value = "auto")]
    crypto: CliCryptoMode,
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Args)]
struct TestCommand {
    #[arg(long, value_enum, default_value = "local")]
    mode: TestMode,
    #[arg(long, value_enum, default_value = "auto")]
    crypto: CliCryptoMode,
    #[arg(long)]
    auth_state_dir: Option<PathBuf>,
    #[arg(long)]
    auth_session_file: Option<PathBuf>,
    #[arg(long)]
    keep_temp_dir: bool,
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Subcommand)]
enum AgentSubcommand {
    Run(AgentRunArgs),
}

#[derive(Debug, Args)]
struct AgentCommand {
    #[command(subcommand)]
    command: AgentSubcommand,
}

#[derive(Debug, Args)]
struct AgentRunArgs {
    #[arg(long, value_enum, default_value = "auto")]
    crypto: CliCryptoMode,
}

#[derive(Debug, Subcommand)]
enum DeviceSubcommand {
    Status(OutputOptions),
    Enroll(DeviceEnrollArgs),
    Approve(DeviceApproveArgs),
    Discover(DeviceDiscoverArgs),
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
struct DeviceDiscoverArgs {
    #[arg(long, default_value_t = 3)]
    timeout_seconds: u64,
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
    Receive(FileReceiveArgs),
    History(OutputOptions),
}

#[derive(Debug, Args)]
struct FileSendArgs {
    path: PathBuf,
    #[arg(long)]
    to: String,
    #[arg(long, value_enum, default_value = "auto")]
    transport: FileSendTransport,
    #[arg(long, default_value_t = 3)]
    discovery_timeout_seconds: u64,
    #[arg(long)]
    compress: bool,
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Args)]
struct FileReceiveArgs {
    #[arg(long)]
    output_dir: Option<PathBuf>,
    #[arg(long, default_value_t = skybridge_core::DEFAULT_FILE_TRANSFER_PORT)]
    port: u16,
    #[arg(long)]
    once: bool,
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
            AgentSubcommand::Run(args) => {
                run_agent(skybridge_agent::AgentRuntimeOptions {
                    state_dir: cli.state_dir,
                    heartbeat_interval: Duration::from_secs(2),
                    crypto_mode: args.crypto.into(),
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
            DeviceSubcommand::Discover(args) => {
                nearby::device_discover(cli.state_dir, args.timeout_seconds, args.output.json).await
            }
        },
        Commands::Code(code) => match code.command {
            CodeSubcommand::Create(args) => code_create(cli.state_dir, args).await,
        },
        Commands::Connect(args) => connect_code(cli.state_dir, args).await,
        Commands::Test(args) => test_smoke(cli.state_dir, args).await,
        Commands::Session(session) => match session.command {
            SessionSubcommand::Ls(output) => session_ls(cli.state_dir, output.json).await,
            SessionSubcommand::Inspect(args) => session_inspect(cli.state_dir, args).await,
        },
        Commands::Disconnect(args) => disconnect(cli.state_dir, &args.session_id).await,
        Commands::File(file) => match file.command {
            FileSubcommand::Send(args) => {
                transfer::file_send(
                    cli.state_dir,
                    args.path,
                    args.to,
                    args.transport,
                    args.discovery_timeout_seconds,
                    args.compress,
                    args.json,
                )
                .await
            }
            FileSubcommand::Receive(args) => {
                transfer::file_receive(cli.state_dir, args.output_dir, args.port, args.once).await
            }
            FileSubcommand::History(output) => {
                transfer::file_history(cli.state_dir, output.json).await
            }
        },
        Commands::Doctor(output) => doctor(cli.state_dir, output.json).await,
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

async fn test_smoke(state_dir: Option<PathBuf>, args: TestCommand) -> Result<()> {
    match args.mode {
        TestMode::Local => {
            let result = run_local_session_transfer_smoke(LocalSessionTransferSmokeOptions {
                crypto_mode: args.crypto.into(),
                root_override: state_dir,
                keep_temp_dir: args.keep_temp_dir,
            })
            .await?;

            if args.json {
                println!("{}", serde_json::to_string_pretty(&result)?);
                return Ok(());
            }

            println!("Local session transfer smoke completed");
            println!("Negotiated Suite: {}", result.negotiated_suite);
            println!("Request ID: {}", result.request_id);
            println!("Transfer ID: {}", result.transfer_id);
            println!("Request State: {}", result.request_state);
            println!("SHA-256: {}", result.file_hash);
            if result.artifacts_retained {
                println!("Source Path: {}", result.source_path);
                println!("Received Path: {}", result.received_path);
                println!("Smoke Root: {}", result.smoke_root);
            } else {
                println!("Artifacts: cleaned up temporary files");
            }
            Ok(())
        }
        TestMode::Code => {
            let result = run_code_flow_smoke(
                state_dir,
                args.auth_state_dir,
                args.auth_session_file,
                args.crypto,
                args.keep_temp_dir,
            )
            .await?;
            if args.json {
                println!("{}", serde_json::to_string_pretty(&result)?);
                return Ok(());
            }

            println!("Code-flow session transfer smoke completed");
            println!("Code: {}", result.code);
            println!("Session ID: {}", result.session_id);
            println!("Negotiated Suite: {}", result.negotiated_suite);
            println!("Request ID: {}", result.request_id);
            println!("Transfer ID: {}", result.transfer_id);
            println!("Request State: {}", result.request_state);
            println!("SHA-256: {}", result.file_hash);
            println!("Auth Source Root: {}", result.auth_source_root);
            if result.artifacts_retained {
                println!("Received Path: {}", result.received_path);
                println!("Smoke Root: {}", result.smoke_root);
                println!("Initiator Agent Log: {}", result.initiator_agent_log);
                println!("Responder Agent Log: {}", result.responder_agent_log);
            } else {
                println!("Artifacts: cleaned up temporary files");
            }
            Ok(())
        }
    }
}

#[derive(Debug, serde::Serialize)]
struct CodeFlowSmokeResult {
    smoke_root: String,
    artifacts_retained: bool,
    auth_source_root: String,
    code: String,
    session_id: String,
    negotiated_suite: String,
    transfer_id: String,
    request_id: String,
    request_state: String,
    received_path: String,
    file_hash: String,
    initiator_agent_log: String,
    responder_agent_log: String,
}

struct AgentChild {
    child: Child,
    log_path: PathBuf,
}

impl AgentChild {
    fn terminate(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for AgentChild {
    fn drop(&mut self) {
        self.terminate();
    }
}

async fn run_code_flow_smoke(
    root_override: Option<PathBuf>,
    auth_state_dir: Option<PathBuf>,
    auth_session_file: Option<PathBuf>,
    crypto: CliCryptoMode,
    keep_temp_dir: bool,
) -> Result<CodeFlowSmokeResult> {
    let (auth_session, auth_source_root) =
        resolve_auth_session_for_code_smoke(auth_state_dir, auth_session_file).await?;
    let retain_artifacts = keep_temp_dir || root_override.is_some();

    let smoke_root = root_override.clone().unwrap_or_else(|| {
        std::env::temp_dir().join(format!("skybridge-code-smoke-{}", uuid::Uuid::now_v7()))
    });
    let initiator_root = smoke_root.join("initiator");
    let responder_root = smoke_root.join("responder");
    let receive_dir = smoke_root.join("downloads");
    tokio::fs::create_dir_all(&initiator_root).await?;
    tokio::fs::create_dir_all(&responder_root).await?;
    tokio::fs::create_dir_all(&receive_dir).await?;

    let result = async {
        let initiator_paths = resolve_paths(Some(initiator_root.clone()))?;
        let responder_paths = resolve_paths(Some(responder_root.clone()))?;
        store_auth_session(&initiator_paths, &auth_session).await?;
        store_auth_session(&responder_paths, &auth_session).await?;

        let _initiator_identity = ensure_device_identity(&initiator_paths).await?;
        let responder_identity = ensure_device_identity(&responder_paths).await?;
        let initiator_pqc = ensure_rust_pqc_identity(&initiator_paths).await?;
        let responder_pqc = ensure_rust_pqc_identity(&responder_paths).await?;

        let lease = create_code_lease_for_smoke(&initiator_paths, &auth_session).await?;
        let lookup =
            prepare_code_lookup_for_smoke(&responder_paths, &lease.code, &auth_session).await?;
        let exe_path = std::env::current_exe()?;

        let mut initiator_agent = spawn_agent_process(
            &exe_path,
            &initiator_root,
            &receive_dir,
            crypto,
            &responder_pqc,
            "initiator",
        )?;
        let mut responder_agent = spawn_agent_process(
            &exe_path,
            &responder_root,
            &receive_dir,
            crypto,
            &initiator_pqc,
            "responder",
        )?;

        let negotiated_suite = wait_for_handshake_completion(
            &initiator_paths,
            &lease.session_id,
            &mut initiator_agent,
        )
        .await?;
        let responder_suite = wait_for_handshake_completion(
            &responder_paths,
            &lease.session_id,
            &mut responder_agent,
        )
        .await?;
        if negotiated_suite != responder_suite {
            bail!(
                "initiator/responder negotiated different suites: {} vs {}",
                negotiated_suite,
                responder_suite
            );
        }

        let payload_path = smoke_root.join("payload.txt");
        let payload = format!(
            "skybridge-code-smoke:{}:{}\n",
            describe_cli_crypto_mode(crypto),
            uuid::Uuid::now_v7()
        );
        tokio::fs::write(&payload_path, payload.as_bytes()).await?;
        let request = skybridge_core::SessionFileTransferRequest::new_outgoing(
            lease.session_id.clone(),
            payload_path.display().to_string(),
            "payload.txt",
            i64::try_from(payload.len()).map_err(|_| anyhow!("payload length overflow"))?,
            Some(responder_identity.state.device.device_id.clone()),
            Some(responder_identity.state.device.device_name.clone()),
        );
        skybridge_agent::save_session_transfer_request(&initiator_paths, &request).await?;
        let completed =
            skybridge_agent::wait_for_request_terminal_state(&initiator_paths, &request.request_id)
                .await?;
        if completed.state != skybridge_core::SessionTransferRequestState::Completed {
            bail!(
                "{}",
                completed
                    .error
                    .unwrap_or_else(|| "code-flow session transfer failed".to_owned())
            );
        }

        let received_path = receive_dir.join("payload.txt");
        wait_for_received_file(
            &received_path,
            &payload,
            &mut initiator_agent,
            &mut responder_agent,
        )
        .await?;

        let result = CodeFlowSmokeResult {
            smoke_root: smoke_root.display().to_string(),
            artifacts_retained: retain_artifacts,
            auth_source_root,
            code: lease.code,
            session_id: lookup.session_id,
            negotiated_suite,
            transfer_id: completed
                .transfer_id
                .clone()
                .unwrap_or_else(|| completed.request_id.clone()),
            request_id: completed.request_id,
            request_state: format!("{:?}", completed.state),
            received_path: received_path.display().to_string(),
            file_hash: completed.file_hash.unwrap_or_default(),
            initiator_agent_log: initiator_agent.log_path.display().to_string(),
            responder_agent_log: responder_agent.log_path.display().to_string(),
        };

        initiator_agent.terminate();
        responder_agent.terminate();
        Ok(result)
    }
    .await;

    if !retain_artifacts {
        let _ = tokio::fs::remove_dir_all(&smoke_root).await;
    }

    result
}

async fn resolve_auth_session_for_code_smoke(
    explicit_root: Option<PathBuf>,
    explicit_session_file: Option<PathBuf>,
) -> Result<(skybridge_core::AuthSession, String)> {
    if let Some(session_file) = explicit_session_file {
        let session =
            maybe_refresh_supabase_auth_session(load_auth_session_from_file(&session_file).await?)
                .await?;
        return Ok((session, session_file.display().to_string()));
    }

    let candidate_roots = auth_candidate_roots(explicit_root)?;
    let mut searched = Vec::new();
    for root in candidate_roots {
        let paths = resolve_paths(Some(root.clone()))?;
        searched.push(root.display().to_string());
        if let Some(session) = load_auth_session(&paths).await? {
            let session = maybe_refresh_supabase_auth_session(session).await?;
            return Ok((session, root.display().to_string()));
        }
    }
    match load_auth_session_from_gui_keychain().await {
        Ok(Some(session)) => {
            let session = maybe_refresh_supabase_auth_session(session).await?;
            return Ok((
                session,
                format!(
                    "keychain:{}:{}",
                    GUI_AUTH_KEYCHAIN_SERVICE, GUI_AUTH_KEYCHAIN_ACCOUNT
                ),
            ));
        }
        Ok(None) => {}
        Err(error) => {
            searched.push(format!(
                "keychain:{}:{} ({})",
                GUI_AUTH_KEYCHAIN_SERVICE, GUI_AUTH_KEYCHAIN_ACCOUNT, error
            ));
        }
    }
    bail!(
        "No auth session found for code-flow smoke. Searched roots: {}. Pass --auth-state-dir <dir> or run `skybridge login` first.",
        searched.join(", ")
    )
}

async fn maybe_refresh_supabase_auth_session(
    session: skybridge_core::AuthSession,
) -> Result<skybridge_core::AuthSession> {
    if !should_refresh_access_token(&session.access_token, 300) {
        return Ok(session);
    }
    let access_token_expired = should_refresh_access_token(&session.access_token, 0);
    let Some(refresh_token) = session.refresh_token.as_deref() else {
        if access_token_expired {
            bail!("auth access token is expired and no refresh token is available");
        }
        return Ok(session);
    };
    match load_supabase_config_from_keychain().await {
        Ok(Some(config)) => {
            match refresh_supabase_auth_session(&config, refresh_token, &session).await {
                Ok(refreshed) => Ok(refreshed),
                Err(error) if access_token_expired => Err(anyhow!(
                    "auth access token is expired and refresh failed: {error}"
                )),
                Err(error) => {
                    eprintln!(
                        "warning: failed to refresh access token; continuing with existing token: {error}"
                    );
                    Ok(session)
                }
            }
        }
        Ok(None) if access_token_expired => Err(anyhow!(
            "auth access token is expired and Supabase refresh config is unavailable"
        )),
        Ok(None) => Ok(session),
        Err(error) if access_token_expired => Err(anyhow!(
            "auth access token is expired and Supabase refresh config could not be loaded: {error}"
        )),
        Err(error) => {
            eprintln!(
                "warning: failed to load Supabase refresh config; continuing with existing token: {error}"
            );
            Ok(session)
        }
    }
}

fn auth_candidate_roots(explicit_root: Option<PathBuf>) -> Result<Vec<PathBuf>> {
    let mut roots = Vec::new();
    let mut push_unique = |path: PathBuf| {
        if !roots.iter().any(|existing| existing == &path) {
            roots.push(path);
        }
    };

    if let Some(explicit_root) = explicit_root {
        push_unique(explicit_root);
        return Ok(roots);
    }

    push_unique(resolve_paths(None)?.root);

    if let Some(dirs) = ProjectDirs::from("com", "SkyBridge", "skybridge") {
        push_unique(dirs.data_local_dir().to_path_buf());
        push_unique(dirs.data_dir().to_path_buf());
    }

    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        push_unique(
            home.join("Library")
                .join("Application Support")
                .join("com.SkyBridge.skybridge"),
        );
        push_unique(
            home.join("Library")
                .join("Application Support")
                .join("com.skybridge.compass.pro")
                .join("SkyBridgeState"),
        );
        push_unique(
            home.join("Library")
                .join("Application Support")
                .join("com.SkyBridge.Compass"),
        );
    }

    Ok(roots)
}

async fn load_auth_session_from_gui_keychain() -> Result<Option<skybridge_core::AuthSession>> {
    #[derive(Debug, serde::Deserialize)]
    struct GuiAuthSession {
        #[serde(rename = "accessToken")]
        access_token: String,
        #[serde(rename = "refreshToken")]
        refresh_token: Option<String>,
        #[serde(rename = "userIdentifier")]
        user_identifier: String,
        #[serde(rename = "displayName")]
        display_name: String,
        #[serde(rename = "issuedAt")]
        issued_at: serde_json::Value,
    }

    #[cfg(not(target_os = "macos"))]
    {
        return Ok(None);
    }

    #[cfg(target_os = "macos")]
    {
        let Some(raw) =
            load_generic_keychain_string(GUI_AUTH_KEYCHAIN_SERVICE, GUI_AUTH_KEYCHAIN_ACCOUNT)
                .await?
        else {
            return Ok(None);
        };
        let normalized = normalize_gui_auth_session_payload(raw.trim())?;
        let session: GuiAuthSession = serde_json::from_str(&normalized)
            .map_err(|error| anyhow!("failed to decode GUI auth session JSON: {error}"))?;
        let issued_at = parse_gui_issued_at(&session.issued_at)?;
        Ok(Some(skybridge_core::AuthSession {
            access_token: session.access_token,
            refresh_token: session.refresh_token,
            user_identifier: session.user_identifier,
            nebula_id: None,
            display_name: session.display_name,
            issued_at,
        }))
    }
}

async fn load_auth_session_from_file(path: &PathBuf) -> Result<skybridge_core::AuthSession> {
    #[derive(Debug, serde::Deserialize)]
    struct GuiAuthSession {
        #[serde(rename = "accessToken")]
        access_token: String,
        #[serde(rename = "refreshToken")]
        refresh_token: Option<String>,
        #[serde(rename = "userIdentifier")]
        user_identifier: String,
        #[serde(rename = "displayName")]
        display_name: String,
        #[serde(rename = "issuedAt")]
        issued_at: serde_json::Value,
    }

    let body = tokio::fs::read_to_string(path).await.map_err(|error| {
        anyhow!(
            "failed to read auth session file {}: {error}",
            path.display()
        )
    })?;
    if let Ok(session) = serde_json::from_str::<skybridge_core::AuthSession>(&body) {
        return Ok(session);
    }
    let normalized = normalize_gui_auth_session_payload(body.trim())?;
    let gui_session: GuiAuthSession = serde_json::from_str(&normalized).map_err(|error| {
        anyhow!(
            "failed to decode auth session file {} as Rust or GUI session JSON: {error}",
            path.display()
        )
    })?;
    let issued_at = parse_gui_issued_at(&gui_session.issued_at)?;
    Ok(skybridge_core::AuthSession {
        access_token: gui_session.access_token,
        refresh_token: gui_session.refresh_token,
        user_identifier: gui_session.user_identifier,
        nebula_id: None,
        display_name: gui_session.display_name,
        issued_at,
    })
}

fn normalize_gui_auth_session_payload(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.starts_with('{') {
        return Ok(trimmed.to_owned());
    }
    if trimmed.len() % 2 != 0
        || !trimmed
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        bail!("GUI auth session payload is neither JSON nor lowercase hex JSON");
    }
    let mut decoded = Vec::with_capacity(trimmed.len() / 2);
    let bytes = trimmed.as_bytes();
    for index in (0..bytes.len()).step_by(2) {
        let high = hex_nibble(bytes[index])?;
        let low = hex_nibble(bytes[index + 1])?;
        decoded.push((high << 4) | low);
    }
    String::from_utf8(decoded)
        .map_err(|error| anyhow!("decoded GUI auth session hex is not valid UTF-8: {error}"))
}

fn hex_nibble(byte: u8) -> Result<u8> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        _ => bail!("invalid hex nibble in GUI auth session payload"),
    }
}

#[derive(Debug, Clone)]
struct SupabaseConfig {
    url: String,
    anon_key: String,
}

async fn load_supabase_config_from_keychain() -> Result<Option<SupabaseConfig>> {
    #[cfg(not(target_os = "macos"))]
    {
        return Ok(None);
    }

    #[cfg(target_os = "macos")]
    {
        let url = load_generic_keychain_string(GUI_SUPABASE_SERVICE, "URL").await?;
        let anon_key = load_generic_keychain_string(GUI_SUPABASE_SERVICE, "AnonKey").await?;
        match (url, anon_key) {
            (Some(url), Some(anon_key)) => Ok(Some(SupabaseConfig { url, anon_key })),
            _ => Ok(None),
        }
    }
}

async fn load_generic_keychain_string(
    service: &'static str,
    account: &'static str,
) -> Result<Option<String>> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, account);
        return Ok(None);
    }

    #[cfg(target_os = "macos")]
    {
        match load_generic_keychain_string_native(service, account).await {
            Ok(value) => Ok(value),
            Err(native_error) => {
                match load_generic_keychain_string_via_security_cli(service, account).await {
                    Ok(value) => Ok(value),
                    Err(cli_error) => Err(anyhow!(
                        "failed to load keychain item {service}/{account}: native lookup failed: {native_error}; security CLI fallback failed: {cli_error}"
                    )),
                }
            }
        }
    }
}

#[cfg(target_os = "macos")]
async fn load_generic_keychain_string_native(
    service: &'static str,
    account: &'static str,
) -> Result<Option<String>> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result: Result<Option<String>> = (|| {
            use security_framework::base::Error as SecurityError;
            use security_framework::passwords::get_generic_password;

            match get_generic_password(service, account) {
                Ok(bytes) => {
                    let text = String::from_utf8(bytes).map_err(|error| {
                        anyhow!("invalid UTF-8 from keychain item {service}/{account}: {error}")
                    })?;
                    Ok(Some(text))
                }
                Err(error) if error.code() == -25300 => Ok(None),
                Err(error) => Err(anyhow!(
                    "Security.framework lookup failed for {service}/{account}: {} ({})",
                    error.code(),
                    SecurityError::from_code(error.code())
                )),
            }
        })();
        let _ = tx.send(result);
    });

    tokio::time::timeout(Duration::from_secs(5), async move {
        loop {
            match rx.try_recv() {
                Ok(result) => return result,
                Err(std::sync::mpsc::TryRecvError::Empty) => {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    bail!("keychain worker disconnected for {service}/{account}");
                }
            }
        }
    })
    .await
    .map_err(|_| anyhow!("timed out waiting for keychain item {service}/{account}"))?
}

#[cfg(target_os = "macos")]
async fn load_generic_keychain_string_via_security_cli(
    service: &'static str,
    account: &'static str,
) -> Result<Option<String>> {
    let service_name = service.to_owned();
    let account_name = account.to_owned();
    tokio::time::timeout(
        Duration::from_secs(20),
        tokio::task::spawn_blocking(move || -> Result<Option<String>> {
            let output = ProcessCommand::new("security")
                .arg("find-generic-password")
                .arg("-s")
                .arg(&service_name)
                .arg("-a")
                .arg(&account_name)
                .arg("-w")
                .output()
                .map_err(|error| {
                    anyhow!(
                        "failed to launch security CLI for {service_name}/{account_name}: {error}"
                    )
                })?;
            if output.status.success() {
                let value = String::from_utf8(output.stdout).map_err(|error| {
                    anyhow!(
                        "security CLI returned non-UTF-8 output for {service_name}/{account_name}: {error}"
                    )
                })?;
                return Ok(Some(value.trim_end().to_owned()));
            }
            let stderr = String::from_utf8_lossy(&output.stderr);
            let normalized = stderr.to_ascii_lowercase();
            if normalized.contains("could not be found")
                || normalized.contains("item could not be found")
            {
                return Ok(None);
            }
            bail!(
                "security CLI lookup failed for {service_name}/{account_name}: status={:?} stderr={}",
                output.status,
                stderr.trim()
            );
        }),
    )
    .await
    .map_err(|_| anyhow!("timed out waiting for security CLI keychain lookup for {service}/{account}"))?
    .map_err(|error| anyhow!("security CLI worker failed for {service}/{account}: {error}"))?
}

async fn refresh_supabase_auth_session(
    config: &SupabaseConfig,
    refresh_token: &str,
    previous: &skybridge_core::AuthSession,
) -> Result<skybridge_core::AuthSession> {
    #[derive(Debug, serde::Deserialize)]
    struct SupabaseUser {
        id: String,
        email: Option<String>,
    }

    #[derive(Debug, serde::Deserialize)]
    struct SupabaseRefreshResponse {
        access_token: String,
        refresh_token: Option<String>,
        user: SupabaseUser,
    }

    let endpoint = format!(
        "{}/auth/v1/token?grant_type=refresh_token",
        config.url.trim_end_matches('/')
    );
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let response = client
        .post(&endpoint)
        .header("Content-Type", "application/json")
        .header("Authorization", format!("Bearer {}", config.anon_key))
        .header("apikey", &config.anon_key)
        .json(&serde_json::json!({ "refresh_token": refresh_token }))
        .send()
        .await?;
    if !response.status().is_success() {
        bail!(
            "supabase refresh failed ({}): {}",
            response.status(),
            response.text().await.unwrap_or_default()
        );
    }
    let refreshed: SupabaseRefreshResponse = response.json().await?;
    Ok(skybridge_core::AuthSession {
        access_token: refreshed.access_token,
        refresh_token: refreshed
            .refresh_token
            .or_else(|| previous.refresh_token.clone()),
        user_identifier: refreshed.user.id,
        nebula_id: previous.nebula_id.clone(),
        display_name: refreshed
            .user
            .email
            .unwrap_or_else(|| previous.display_name.clone()),
        issued_at: OffsetDateTime::now_utc(),
    })
}

fn parse_gui_issued_at(value: &serde_json::Value) -> Result<OffsetDateTime> {
    const APPLE_REFERENCE_UNIX_SECONDS: i64 = 978_307_200;
    match value {
        serde_json::Value::Number(number) => {
            let seconds = number
                .as_f64()
                .ok_or_else(|| anyhow!("issuedAt numeric value is not representable"))?;
            let unix_seconds = seconds + APPLE_REFERENCE_UNIX_SECONDS as f64;
            OffsetDateTime::from_unix_timestamp_nanos((unix_seconds * 1_000_000_000.0) as i128)
                .map_err(|error| anyhow!("invalid issuedAt timestamp: {error}"))
        }
        serde_json::Value::String(text) => {
            OffsetDateTime::parse(text, &time::format_description::well_known::Rfc3339)
                .map_err(|error| anyhow!("invalid issuedAt string: {error}"))
        }
        _ => bail!("unsupported issuedAt representation in GUI auth session"),
    }
}

async fn create_code_lease_for_smoke(
    paths: &skybridge_agent::AgentPaths,
    auth_session: &skybridge_core::AuthSession,
) -> Result<ConnectionCodeLease> {
    let tenant_id = require_tenant_id(auth_session)?;
    let identity = ensure_device_identity(paths).await?;
    let signal_server = SignalServerClient::from_env()?;
    let admission =
        request_admission_lease(&signal_server, auth_session, &tenant_id, &identity).await?;
    let lease = signal_server
        .register_connection_code(&admission.token, &identity.state.device.device_name, 300)
        .await?;
    let turn_credentials = signal_server
        .fetch_turn_credentials(&lease.turn_admission_lease.token)
        .await?;
    upsert_session_runtime(
        paths,
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
        paths,
        ManagedSessionControl::new(
            lease.session_id.clone(),
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            identity.state.device.device_id.clone(),
            lease.signaling_server_origin.clone(),
            lease.session_token.clone(),
            Some(turn_credentials),
        ),
    )
    .await?;
    Ok(lease)
}

async fn prepare_code_lookup_for_smoke(
    paths: &skybridge_agent::AgentPaths,
    code: &str,
    auth_session: &skybridge_core::AuthSession,
) -> Result<ConnectionCodeLookup> {
    let tenant_id = require_tenant_id(auth_session)?;
    let identity = ensure_device_identity(paths).await?;
    let signal_server = SignalServerClient::from_env()?;
    let admission =
        request_admission_lease(&signal_server, auth_session, &tenant_id, &identity).await?;
    let lookup = signal_server
        .lookup_connection_code(&admission.token, code)
        .await?;
    let turn_credentials = signal_server
        .fetch_turn_credentials(&lookup.turn_admission_lease.token)
        .await?;
    let canonical_origin =
        CurrentPathOriginPolicy::canonical_origin(&lookup.signaling_server_origin)?;
    let initial_record = RuntimeSessionRecord::new(
        make_runtime_id(&lookup.session_id),
        lookup.session_id.clone(),
        RuntimeSessionRole::Responder,
        RuntimeSessionSource::Code,
        canonical_origin,
        identity.state.device.device_id.clone(),
        Some(lookup.initiator_device_id.clone()),
        lookup.initiator_device_name.clone(),
        Some(lookup.initiator_protocol_public_key_fingerprint.clone()),
        RuntimeSessionState::Connecting,
    );
    upsert_session_runtime(paths, initial_record).await?;
    upsert_managed_session_control(
        paths,
        ManagedSessionControl::new(
            lookup.session_id.clone(),
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            identity.state.device.device_id.clone(),
            lookup.signaling_server_origin.clone(),
            lookup.session_token.clone(),
            Some(turn_credentials),
        ),
    )
    .await?;
    Ok(lookup)
}

fn spawn_agent_process(
    exe_path: &PathBuf,
    state_dir: &PathBuf,
    receive_dir: &PathBuf,
    crypto: CliCryptoMode,
    peer_pqc: &skybridge_core::RustPqcIdentityMaterial,
    label: &str,
) -> Result<AgentChild> {
    let log_path = state_dir
        .parent()
        .unwrap_or(state_dir)
        .join(format!("{label}-agent.log"));
    let log_file = StdFile::create(&log_path)?;
    let log_file_err = log_file.try_clone()?;
    let mut command = ProcessCommand::new(exe_path);
    command
        .arg("--state-dir")
        .arg(state_dir)
        .arg("agent")
        .arg("run")
        .arg("--crypto")
        .arg(describe_cli_crypto_mode(crypto))
        .env("SKYBRIDGE_FILE_RECEIVE_DIR", receive_dir)
        .env(
            "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
            STANDARD.encode(&peer_pqc.xwing_public_key),
        )
        .env(
            "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
            STANDARD.encode(&peer_pqc.mlkem768_public_key),
        )
        .stdout(Stdio::from(log_file))
        .stderr(Stdio::from(log_file_err));
    if let Some(preferred_suite) = crypto.requested_pqc_suite() {
        command.env("SKYBRIDGE_PQC_PREFERRED_SUITE", preferred_suite.to_string());
    }
    let child = command.spawn()?;
    Ok(AgentChild { child, log_path })
}

async fn wait_for_handshake_completion(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
    agent: &mut AgentChild,
) -> Result<String> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(status) = agent.child.try_wait()? {
            bail!(
                "agent exited before handshake completion with status {} (log: {})",
                status,
                agent.log_path.display()
            );
        }
        let registry = load_session_registry(paths).await?;
        if let Some(record) = registry.get(session_id) {
            if let SessionReadiness::HandshakeComplete {
                negotiated_suite, ..
            } = &record.readiness
            {
                return Ok(negotiated_suite.clone());
            }
        }
        if tokio::time::Instant::now() >= deadline {
            bail!(
                "timed out waiting for handshake completion (log: {})",
                agent.log_path.display()
            );
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

async fn wait_for_received_file(
    received_path: &PathBuf,
    expected_body: &str,
    initiator_agent: &mut AgentChild,
    responder_agent: &mut AgentChild,
) -> Result<()> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        for agent in [&mut *initiator_agent, &mut *responder_agent] {
            if let Some(status) = agent.child.try_wait()? {
                bail!(
                    "agent exited before transfer completion with status {} (log: {})",
                    status,
                    agent.log_path.display()
                );
            }
        }
        if tokio::fs::try_exists(received_path).await? {
            let received = tokio::fs::read_to_string(received_path).await?;
            if received == expected_body {
                return Ok(());
            }
        }
        if tokio::time::Instant::now() >= deadline {
            bail!(
                "timed out waiting for received file {}",
                received_path.display()
            );
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

fn describe_cli_crypto_mode(mode: CliCryptoMode) -> &'static str {
    match mode {
        CliCryptoMode::Auto => "auto",
        CliCryptoMode::Xwing => "xwing",
        CliCryptoMode::Mlkem => "mlkem",
        CliCryptoMode::Classic => "classic",
    }
}

#[derive(Debug, Serialize)]
struct CreateCliLoginSessionRequestPayload {
    client_id: String,
    code_challenge: String,
    redirect_uri: String,
    state: String,
    platform: String,
    cli_version: String,
    device_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateCliLoginSessionResponsePayload {
    session_id: String,
    browser_url: String,
    #[serde(rename = "expires_at")]
    _expires_at: String,
}

#[derive(Debug, Serialize)]
struct ExchangeCliLoginTokenRequestPayload {
    session_id: String,
    client_id: String,
    code: String,
    code_verifier: String,
}

#[derive(Debug, Deserialize)]
struct ExchangeCliLoginTokenResponsePayload {
    access_token: String,
    refresh_token: String,
    user_identifier: String,
    display_name: String,
    nebula_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct LoginApiErrorEnvelope {
    error: LoginApiErrorDetail,
}

#[derive(Debug, Deserialize)]
struct LoginApiErrorDetail {
    message: String,
}

#[derive(Debug)]
struct BrowserCallbackResult {
    code: String,
}

fn current_cli_platform() -> &'static str {
    match std::env::consts::OS {
        "macos" => "macos",
        "linux" => "linux",
        "windows" => "windows",
        other => other,
    }
}

fn login_api_base_url() -> String {
    std::env::var("SKYBRIDGE_LOGIN_API_BASE_URL")
        .unwrap_or_else(|_| DEFAULT_LOGIN_API_BASE_URL.to_owned())
        .trim()
        .trim_end_matches('/')
        .to_owned()
}

fn login_api_uses_loopback(base_url: &str) -> bool {
    Url::parse(base_url)
        .ok()
        .and_then(|url| url.host_str().map(str::to_owned))
        .map(|host| host == "127.0.0.1" || host.eq_ignore_ascii_case("localhost"))
        .unwrap_or(false)
}

fn login_web_base_url_override() -> Option<String> {
    std::env::var("SKYBRIDGE_LOGIN_WEB_BASE_URL")
        .ok()
        .map(|value| value.trim().trim_end_matches('/').to_owned())
        .filter(|value| !value.is_empty())
}

fn login_debug_enabled() -> bool {
    std::env::var("SKYBRIDGE_LOGIN_DEBUG")
        .ok()
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

fn effective_browser_login_url(response: &CreateCliLoginSessionResponsePayload) -> String {
    if let Some(configured) = login_web_base_url_override() {
        if let Ok(mut url) = Url::parse(&configured) {
            url.set_path("/auth/cli");
            url.set_query(Some(&format!("session={}", response.session_id)));
            return url.to_string();
        }
    }
    if !response.browser_url.trim().is_empty() {
        return response.browser_url.clone();
    }
    format!(
        "{}/auth/cli?session={}",
        DEFAULT_LOGIN_WEB_BASE_URL, response.session_id
    )
}

async fn read_login_api_error(response: reqwest::Response, fallback: &str) -> Result<String> {
    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    if let Ok(error) = serde_json::from_str::<LoginApiErrorEnvelope>(&body) {
        return Ok(format!("{} ({}): {}", fallback, status, error.error.message));
    }
    if body.trim().is_empty() {
        return Ok(format!("{} ({})", fallback, status));
    }
    Ok(format!("{} ({}): {}", fallback, status, body.trim()))
}

async fn wait_for_browser_cli_callback(
    listener: TcpListener,
    expected_state: &str,
) -> Result<BrowserCallbackResult> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(600);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            bail!("timed out waiting for browser login callback");
        }

        let (mut stream, _) = tokio::time::timeout(remaining, listener.accept())
            .await
            .map_err(|_| anyhow!("timed out waiting for browser login callback"))??;
        let mut request = vec![0_u8; 4096];
        let read = stream.read(&mut request).await?;
        let text = String::from_utf8_lossy(&request[..read]);
        let request_line = text
            .lines()
            .next()
            .ok_or_else(|| anyhow!("empty browser callback request"))?;
        let target = request_line
            .split_whitespace()
            .nth(1)
            .ok_or_else(|| anyhow!("invalid browser callback request line"))?;
        let callback_url = format!("http://127.0.0.1{target}");
        let url = Url::parse(&callback_url)?;
        let query = url.query_pairs().collect::<std::collections::HashMap<_, _>>();

        if let Some(error) = query
            .get("error_description")
            .or_else(|| query.get("error"))
            .map(|value| value.to_string())
        {
            let body = format!("SkyBridge CLI login failed: {error}\n");
            write_loopback_response(&mut stream, 400, &body).await?;
            bail!("{error}");
        }

        let returned_state = query
            .get("state")
            .map(|value| value.as_ref())
            .unwrap_or_default();
        if returned_state != expected_state {
            let body = "SkyBridge CLI login state mismatch. You can close this tab.\n";
            write_loopback_response(&mut stream, 400, body).await?;
            bail!("browser login state validation failed");
        }

        let Some(code) = query.get("code").map(|value| value.to_string()) else {
            let body = "SkyBridge CLI login callback did not include an authorization code.\n";
            write_loopback_response(&mut stream, 400, body).await?;
            bail!("browser login callback did not include an authorization code");
        };

        let body = "SkyBridge CLI login complete. You can close this tab.\n";
        write_loopback_response(&mut stream, 200, body).await?;
        return Ok(BrowserCallbackResult { code });
    }
}

async fn write_loopback_response(
    stream: &mut tokio::net::TcpStream,
    status_code: u16,
    body: &str,
) -> Result<()> {
    let status_text = if status_code == 200 { "OK" } else { "Bad Request" };
    let response = format!(
        "HTTP/1.1 {} {}\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
        status_code,
        status_text,
        body.len(),
        body
    );
    stream.write_all(response.as_bytes()).await?;
    stream.shutdown().await?;
    Ok(())
}

async fn complete_login(
    paths: &skybridge_agent::AgentPaths,
    session: &skybridge_core::AuthSession,
    source: &str,
) -> Result<()> {
    store_auth_session(paths, session).await?;
    store_auth_session_source(paths, source).await?;
    let identity = ensure_device_identity(paths).await?;
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
    println!("Login Source: {}", source);
    Ok(())
}

async fn try_reuse_gui_auth_session() -> Result<Option<skybridge_core::AuthSession>> {
    match load_auth_session_from_gui_keychain().await {
        Ok(Some(session)) => Ok(Some(maybe_refresh_supabase_auth_session(session).await?)),
        Ok(None) => Ok(None),
        Err(error) => {
            eprintln!(
                "warning: failed to reuse GUI login session; falling back to browser login: {error}"
            );
            Ok(None)
        }
    }
}

fn should_use_legacy_login(args: &LoginCommand) -> bool {
    args.redirect_uri.is_some() || args.callback_url.is_some() || args.authorization_code.is_some()
}

fn should_force_browser_login(args: &LoginCommand) -> bool {
    if args.browser {
        return true;
    }

    std::env::var("SKYBRIDGE_LOGIN_FORCE_BROWSER")
        .ok()
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

async fn login_via_legacy_nebula_oauth(
    paths: &skybridge_agent::AgentPaths,
    args: &LoginCommand,
) -> Result<()> {
    eprintln!(
        "warning: legacy Nebula OAuth login flags are deprecated; prefer `skybridge login` without redirect/code overrides"
    );
    let oauth = NebulaOAuthClient::from_env()?;
    let redirect_uri = args
        .redirect_uri
        .clone()
        .or_else(|| std::env::var("SKYBRIDGE_OAUTH_REDIRECT_URI").ok())
        .unwrap_or_else(|| "skybridge://auth/nebula".to_owned());
    let authorization_request = oauth
        .make_authorization_request(
            &redirect_uri,
            &["openid", "profile", "email", "offline_access"],
            &[],
        )
        .await?;

    if args.print_only {
        println!("{}", authorization_request.authorization_url);
        return Ok(());
    }

    let session = oauth
        .complete_authorization_interactively(
            &authorization_request,
            !args.no_open,
            args.callback_url.clone(),
            args.authorization_code.clone(),
        )
        .await?;
    complete_login(paths, &session, AUTH_SOURCE_LEGACY_NEBULA_OAUTH).await
}

async fn login_via_browser_cli_login(
    paths: &skybridge_agent::AgentPaths,
    args: &LoginCommand,
) -> Result<()> {
    let api_base_url = login_api_base_url();
    let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
    let local_addr = listener.local_addr()?;
    let redirect_uri = format!("http://127.0.0.1:{}/callback", local_addr.port());
    let (code_verifier, code_challenge) = generate_pkce_pair();
    let state = uuid::Uuid::now_v7().to_string();
    let mut client_builder = reqwest::Client::builder().timeout(Duration::from_secs(20));
    if login_api_uses_loopback(&api_base_url) {
        client_builder = client_builder.no_proxy();
    }
    let client = client_builder.build()?;
    let identity = ensure_device_identity(paths).await?;
    let request = CreateCliLoginSessionRequestPayload {
        client_id: CLI_LOGIN_CLIENT_ID.to_owned(),
        code_challenge,
        redirect_uri,
        state: state.clone(),
        platform: current_cli_platform().to_owned(),
        cli_version: env!("CARGO_PKG_VERSION").to_owned(),
        device_name: Some(identity.state.device.device_name.clone()),
    };
    let create_url = format!("{}/api/cli-login/sessions", api_base_url);
    if login_debug_enabled() {
        eprintln!("skybridge login debug: create session url = {create_url}");
    }
    let response = client.post(create_url).json(&request).send().await?;
    if !response.status().is_success() {
        bail!("{}", read_login_api_error(response, "failed to create browser login session").await?);
    }
    let session_response = response.json::<CreateCliLoginSessionResponsePayload>().await?;
    let browser_url = effective_browser_login_url(&session_response);

    println!("{}", browser_url);
    if args.print_only {
        return Ok(());
    }

    if !args.no_open {
        let _ = webbrowser::open(&browser_url);
    }

    let callback = wait_for_browser_cli_callback(listener, &state).await?;
    let exchange_url = format!("{}/api/cli-login/token", api_base_url);
    if login_debug_enabled() {
        eprintln!("skybridge login debug: exchange token url = {exchange_url}");
    }
    let response = client
        .post(exchange_url)
        .json(&ExchangeCliLoginTokenRequestPayload {
            session_id: session_response.session_id,
            client_id: CLI_LOGIN_CLIENT_ID.to_owned(),
            code: callback.code,
            code_verifier,
        })
        .send()
        .await?;

    if !response.status().is_success() {
        bail!("{}", read_login_api_error(response, "failed to exchange browser login code").await?);
    }

    let exchanged = response.json::<ExchangeCliLoginTokenResponsePayload>().await?;
    let session = skybridge_core::AuthSession {
        access_token: exchanged.access_token,
        refresh_token: Some(exchanged.refresh_token),
        user_identifier: exchanged.user_identifier,
        nebula_id: exchanged.nebula_id,
        display_name: exchanged.display_name,
        issued_at: OffsetDateTime::now_utc(),
    };
    complete_login(paths, &session, AUTH_SOURCE_BROWSER_CLI_LOGIN).await
}

async fn login(state_dir: Option<PathBuf>, args: LoginCommand) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    if should_use_legacy_login(&args) {
        return login_via_legacy_nebula_oauth(&paths, &args).await;
    }

    if !args.print_only && !should_force_browser_login(&args) {
        if let Some(session) = try_reuse_gui_auth_session().await? {
            return complete_login(&paths, &session, AUTH_SOURCE_GUI_SESSION_REUSE).await;
        }
    }

    login_via_browser_cli_login(&paths, &args).await
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
        .map(|value| {
            !matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "0" | "false" | "no" | "off"
            )
        })
        .unwrap_or(true)
}

async fn maybe_inline_pqc_responder_config(
    paths: &skybridge_agent::AgentPaths,
    identity: &skybridge_agent::DeviceIdentityMaterial,
    local_binding: &ProtocolIdentityBinding,
    supported_suites: Vec<CryptoSuite>,
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
        supported_suites,
    }))
}

fn inline_classic_responder_config(
    identity: &skybridge_agent::DeviceIdentityMaterial,
    local_binding: &ProtocolIdentityBinding,
) -> Result<skybridge_core::ClassicResponderConfig> {
    let signing_secret_key = identity
        .signing_key
        .ed25519_secret_key_bytes()
        .ok_or_else(|| anyhow!("classic mode requires an Ed25519 protocol identity"))?;
    Ok(skybridge_core::ClassicResponderConfig {
        local_binding: local_binding.clone(),
        signing_secret_key,
        local_device_name: Some(identity.state.device.device_name.clone()),
    })
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
    let pqc_responder = if args.crypto == CliCryptoMode::Classic {
        None
    } else {
        maybe_inline_pqc_responder_config(
            &paths,
            &identity,
            &local_binding,
            args.crypto.supported_pqc_suites(),
        )
        .await?
    };
    if matches!(args.crypto, CliCryptoMode::Xwing | CliCryptoMode::Mlkem) && pqc_responder.is_none()
    {
        bail!(
            "selected {} but no PQC responder identity is available; enable {} or use --crypto classic",
            args.crypto
                .requested_pqc_suite()
                .unwrap_or(CryptoSuite::XWING_MLDSA),
            ENV_PQC_BRIDGE_IDENTITY
        );
    }
    let classic_responder = if args.crypto == CliCryptoMode::Classic
        || (args.crypto == CliCryptoMode::Auto
            && pqc_responder.is_none()
            && args.crypto.allows_classic())
    {
        Some(inline_classic_responder_config(&identity, &local_binding)?)
    } else {
        None
    };
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
        classic_responder,
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
    let auth_source = load_auth_session_source(&paths).await?;
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
                    format!(
                        "auth session present and tenant derivation succeeded (source={})",
                        auth_source.as_deref().unwrap_or("unknown")
                    )
                } else {
                    "auth session missing or tenant derivation failed; run `skybridge login`"
                        .to_owned()
                }
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
        "implemented_phases": [
            "phase_4_auth",
            "phase_5_signaling_plane",
            "phase_6_nearby_discovery",
            "phase_6_file_transfer"
        ],
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
        NativeWebRtcEvent::ApplicationPayload { .. } => {}
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
