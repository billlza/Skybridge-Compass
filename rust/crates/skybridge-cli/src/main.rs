use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use clap::{Args, Parser, Subcommand, ValueEnum};
use serde::{Deserialize, Serialize};
use serde_json::json;
use skybridge_agent::{
    clear_auth_session, ensure_device_identity, ensure_rust_pqc_identity, load_auth_session,
    load_health_snapshot, load_session_registry, refresh_auth_session_if_needed,
    remove_managed_session_control, remove_session_runtime, resolve_paths, run_agent,
    signing_binding, signing_signature, store_auth_session, store_session_registry,
    update_enrollment_status, upsert_managed_session_control, upsert_session_runtime,
};
use skybridge_core::{
    AgentRuntimeStatus, AuthState, ClassicResponderConfig, CryptoSuite, CurrentPathOriginPolicy,
    EnrollmentStatus, InboundMessage, ManagedSessionControl, NativeWebRtcConfig,
    NativeWebRtcEvent, NativeWebRtcSession, NebulaOAuthClient, PqcInitiatorTemplate,
    PqcResponderConfig, ProtocolIdentityBinding, ProtocolSigningAlgorithm,
    RuntimeSessionKeepaliveStatus, RuntimeSessionRecord, RuntimeSessionRole,
    RuntimeSessionSource, RuntimeSessionState, RuntimeSessionTransportEvent, SessionReadiness,
    SignalServerClient, SignalingConnection, SignalingLifecycleEvent, SignalingLifecyclePhase,
    SignalingRuntimeEvent, derive_tenant_identifier, make_join_envelope, make_runtime_id,
};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;
use tokio::io::{AsyncSeekExt, AsyncWriteExt};

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
    Doctor(OutputOptions),
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
    #[arg(long, value_enum, default_value_t = LoginMode::Auto)]
    mode: LoginMode,
    #[arg(long, default_value_t = 8789)]
    listen_port: u16,
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum LoginMode {
    Auto,
    Browser,
    Paste,
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
    Receive(FileReceiveArgs),
    History(OutputOptions),
}

#[derive(Debug, Args)]
struct FileSendArgs {
    path: PathBuf,
    #[arg(long)]
    to: String,
    #[arg(long, default_value_t = 300)]
    timeout_seconds: u64,
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Args)]
struct FileReceiveArgs {
    #[arg(long)]
    output_dir: Option<PathBuf>,
    #[arg(long, default_value_t = 300)]
    timeout_seconds: u64,
    #[arg(long)]
    json: bool,
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
            FileSubcommand::Send(args) => file_send(cli.state_dir, args).await,
            FileSubcommand::Receive(args) => file_receive(cli.state_dir, args).await,
            FileSubcommand::History(output) => file_history(cli.state_dir, output.json).await,
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

async fn login(state_dir: Option<PathBuf>, args: LoginCommand) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let oauth = NebulaOAuthClient::from_env()?;
    let redirect_uri = resolve_cli_login_redirect_uri(&args);
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
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "logged_in": true,
                "display_name": session.display_name,
                "user_id": session.user_identifier,
                "tenant_id": if tenant_id.is_empty() { None::<String> } else { Some(tenant_id.clone()) },
                "device_id": identity.state.device.device_id,
                "redirect_uri": redirect_uri,
                "mode": describe_login_mode(args.mode, authorization_request.redirect_uri.as_str()),
            }))?
        );
    } else {
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
        println!("Login Mode: {}", describe_login_mode(args.mode, authorization_request.redirect_uri.as_str()));
    }
    Ok(())
}

async fn logout(state_dir: Option<PathBuf>) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    clear_auth_session(&paths).await?;
    println!("Logged out");
    Ok(())
}

fn resolve_cli_login_redirect_uri(args: &LoginCommand) -> String {
    if let Some(explicit) = args
        .redirect_uri
        .clone()
        .or_else(|| std::env::var("SKYBRIDGE_OAUTH_REDIRECT_URI").ok())
    {
        return explicit;
    }

    match args.mode {
        LoginMode::Auto if args.callback_url.is_none() && args.authorization_code.is_none() => {
            format!("http://127.0.0.1:{}/auth/callback", args.listen_port)
        }
        LoginMode::Auto => "skybridge://auth/nebula".to_owned(),
        LoginMode::Browser => format!("http://127.0.0.1:{}/auth/callback", args.listen_port),
        LoginMode::Paste => "skybridge://auth/nebula".to_owned(),
    }
}

fn describe_login_mode(mode: LoginMode, redirect_uri: &str) -> &'static str {
    match mode {
        LoginMode::Browser => "browser-loopback",
        LoginMode::Paste => "manual-paste",
        LoginMode::Auto if redirect_uri.starts_with("http://127.0.0.1:")
            || redirect_uri.starts_with("http://localhost:") =>
        {
            "browser-loopback"
        }
        LoginMode::Auto => "manual-paste",
    }
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
                "0" | "false" | "no"
            )
        })
        .unwrap_or(true)
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

async fn maybe_inline_pqc_initiator_template(
    paths: &skybridge_agent::AgentPaths,
    identity: &skybridge_agent::DeviceIdentityMaterial,
    local_binding: &ProtocolIdentityBinding,
) -> Result<Option<PqcInitiatorTemplate>> {
    if local_binding.protocol_signing_algorithm != ProtocolSigningAlgorithm::MlDsa65
        && !pqc_bridge_identity_enabled()
    {
        return Ok(None);
    }

    let (pqc_binding, signing_secret_key) = if local_binding.protocol_signing_algorithm
        == ProtocolSigningAlgorithm::MlDsa65
    {
        let signing_secret_key = identity
            .signing_key
            .mldsa65_secret_key_bytes()
            .ok_or_else(|| anyhow!("missing ML-DSA-65 signing secret key"))?;
        (local_binding.clone(), signing_secret_key)
    } else {
        let pqc_identity = ensure_rust_pqc_identity(paths).await?;
        (
            ProtocolIdentityBinding::new(
                local_binding.device_id.clone(),
                pqc_identity.signing_algorithm,
                pqc_identity.signing_public_key.clone(),
                None,
            )?,
            pqc_identity.signing_secret_key,
        )
    };

    Ok(Some(PqcInitiatorTemplate {
        local_binding: pqc_binding,
        signing_secret_key,
        local_device_name: Some(identity.state.device.device_name.clone()),
        preferred_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
    }))
}

fn maybe_inline_classic_responder_config(
    identity: &skybridge_agent::DeviceIdentityMaterial,
    local_binding: &ProtocolIdentityBinding,
    role: RuntimeSessionRole,
) -> Result<Option<ClassicResponderConfig>> {
    if role != RuntimeSessionRole::Responder
        || local_binding.protocol_signing_algorithm != ProtocolSigningAlgorithm::Ed25519
    {
        return Ok(None);
    }
    let signing_secret_key = identity
        .signing_key
        .ed25519_secret_key_bytes()
        .ok_or_else(|| anyhow!("classic responder requires an Ed25519 protocol identity"))?;
    Ok(Some(ClassicResponderConfig {
        local_binding: local_binding.clone(),
        signing_secret_key,
        local_device_name: Some(identity.state.device.device_name.clone()),
    }))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum CrossNetworkFileTransferOp {
    Metadata,
    MetadataAck,
    Chunk,
    ChunkAck,
    Complete,
    CompleteAck,
    Cancel,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CrossNetworkFileTransferMessage {
    version: i32,
    op: CrossNetworkFileTransferOp,
    transfer_id: String,
    sender_device_id: Option<String>,
    sender_device_name: Option<String>,
    file_name: Option<String>,
    file_size: Option<i64>,
    chunk_size: Option<i32>,
    total_chunks: Option<i32>,
    mime_type: Option<String>,
    chunk_index: Option<i32>,
    #[serde(default, with = "opt_base64_bytes")]
    chunk_data: Option<Vec<u8>>,
    raw_size: Option<i32>,
    received_bytes: Option<i64>,
    message: Option<String>,
}

impl CrossNetworkFileTransferMessage {
    fn new(op: CrossNetworkFileTransferOp, transfer_id: String) -> Self {
        Self {
            version: 1,
            op,
            transfer_id,
            sender_device_id: None,
            sender_device_name: None,
            file_name: None,
            file_size: None,
            chunk_size: None,
            total_chunks: None,
            mime_type: None,
            chunk_index: None,
            chunk_data: None,
            raw_size: None,
            received_bytes: None,
            message: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairingKemPublicKeyInfo {
    suite_wire_id: u16,
    #[serde(with = "base64_bytes")]
    public_key: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairingIdentityExchangePayload {
    device_id: String,
    kem_public_keys: Vec<PairingKemPublicKeyInfo>,
    device_name: Option<String>,
    platform: Option<String>,
    remote_video_formats: Option<Vec<String>>,
    sent_at: f64,
}

#[derive(Debug)]
struct ReceiveState {
    transfer_id: String,
    file_name: String,
    file_size: i64,
    chunk_size: i32,
    temp_path: PathBuf,
    final_path: PathBuf,
    file: tokio::fs::File,
    received_bytes: i64,
}

#[derive(Debug, Default)]
struct SessionTransferState {
    pairing_sent: bool,
    rekey_attempted: bool,
    current_negotiated_suite: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum FileTransferDirection {
    Send,
    Receive,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileTransferHistoryEntry {
    recorded_at: String,
    direction: FileTransferDirection,
    session_id: String,
    transfer_id: String,
    file_name: String,
    path: String,
    bytes: i64,
    suite: Option<String>,
    peer_device_id: Option<String>,
    peer_device_name: Option<String>,
}

mod base64_bytes {
    use super::*;

    pub fn serialize<S>(value: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&STANDARD.encode(value))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        STANDARD
            .decode(value.as_bytes())
            .map_err(serde::de::Error::custom)
    }
}

mod opt_base64_bytes {
    use super::*;

    pub fn serialize<S>(value: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match value {
            Some(value) => serializer.serialize_some(&STANDARD.encode(value)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = Option::<serde_json::Value>::deserialize(deserializer)?;
        match value {
            None => Ok(None),
            Some(serde_json::Value::String(value)) => STANDARD
                .decode(value.as_bytes())
                .map(Some)
                .map_err(serde::de::Error::custom),
            Some(serde_json::Value::Array(values)) => values
                .into_iter()
                .map(|value| {
                    value
                        .as_u64()
                        .and_then(|byte| u8::try_from(byte).ok())
                        .ok_or_else(|| serde::de::Error::custom("invalid byte array"))
                })
                .collect::<Result<Vec<_>, _>>()
                .map(Some),
            Some(_) => Err(serde::de::Error::custom("invalid chunkData payload")),
        }
    }
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
    let pqc_initiator_template =
        maybe_inline_pqc_initiator_template(&paths, &identity, &local_binding).await?;
    let pqc_responder =
        maybe_inline_pqc_responder_config(&paths, &identity, &local_binding).await?;
    let classic_responder =
        maybe_inline_classic_responder_config(&identity, &local_binding, RuntimeSessionRole::Responder)?;
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
        pqc_initiator_template,
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

async fn drain_inline_native_events_collect_app(
    paths: &skybridge_agent::AgentPaths,
    connection: &SignalingConnection,
    session_id: &str,
    native_session: &mut NativeWebRtcSession,
) -> Result<Vec<Vec<u8>>> {
    let mut payloads = Vec::new();
    while let Some(event) = native_session.try_next_event() {
        match event {
            NativeWebRtcEvent::AppPayload { data } => payloads.push(data),
            other => apply_inline_native_event(paths, connection, session_id, other).await?,
        }
    }
    Ok(payloads)
}

fn apple_reference_seconds_now_cli() -> f64 {
    let now = OffsetDateTime::now_utc().unix_timestamp_nanos() as f64 / 1_000_000_000.0;
    now - 978_307_200.0
}

fn current_suite_is_pqc(suite: Option<&str>) -> bool {
    suite.and_then(CryptoSuite::from_name).is_some_and(|suite| suite.is_pqc())
}

fn canonical_pqc_rekey_election_device_id(raw: Option<&str>) -> Option<String> {
    let raw = raw?;
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.to_ascii_lowercase().starts_with("webrtc-") {
        return None;
    }
    Some(trimmed.to_ascii_lowercase())
}

fn should_initiate_pqc_rekey(local_device_id: Option<&str>, remote_device_id: Option<&str>) -> Option<bool> {
    let local = canonical_pqc_rekey_election_device_id(local_device_id)?;
    let remote = canonical_pqc_rekey_election_device_id(remote_device_id)?;
    if local == remote {
        return None;
    }
    Some(local < remote)
}

fn next_transfer_id() -> String {
    format!(
        "transfer-{}",
        OffsetDateTime::now_utc().unix_timestamp_nanos()
    )
}

fn output_dir_or_current_dir(value: Option<PathBuf>) -> Result<PathBuf> {
    match value {
        Some(path) => Ok(path),
        None => Ok(std::env::current_dir()?),
    }
}

fn file_transfer_history_path(paths: &skybridge_agent::AgentPaths) -> PathBuf {
    paths.runtime_dir.join("file-transfers.json")
}

async fn load_file_transfer_history(
    paths: &skybridge_agent::AgentPaths,
) -> Result<Vec<FileTransferHistoryEntry>> {
    let path = file_transfer_history_path(paths);
    match tokio::fs::read_to_string(&path).await {
        Ok(body) => Ok(serde_json::from_str(&body)?),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(error) => Err(error.into()),
    }
}

async fn append_file_transfer_history(
    paths: &skybridge_agent::AgentPaths,
    entry: FileTransferHistoryEntry,
) -> Result<()> {
    tokio::fs::create_dir_all(&paths.runtime_dir).await?;
    let mut history = load_file_transfer_history(paths).await?;
    history.push(entry);
    if history.len() > 200 {
        let drain_until = history.len() - 200;
        history.drain(0..drain_until);
    }
    tokio::fs::write(
        file_transfer_history_path(paths),
        serde_json::to_vec_pretty(&history)?,
    )
    .await?;
    Ok(())
}

fn now_rfc3339() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| OffsetDateTime::now_utc().unix_timestamp().to_string())
}

fn sanitize_filename(raw: &str) -> String {
    let mut value = raw.trim().replace('/', "_").replace('\\', "_");
    if value.is_empty() {
        value = "received.bin".to_owned();
    }
    value
}

fn unique_destination(output_dir: &std::path::Path, file_name: &str) -> PathBuf {
    let candidate = output_dir.join(file_name);
    if !candidate.exists() {
        return candidate;
    }
    let stem = candidate
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("received");
    let ext = candidate.extension().and_then(|value| value.to_str());
    for index in 2..1000 {
        let numbered = match ext {
            Some(ext) if !ext.is_empty() => output_dir.join(format!("{stem}-{index}.{ext}")),
            _ => output_dir.join(format!("{stem}-{index}")),
        };
        if !numbered.exists() {
            return numbered;
        }
    }
    output_dir.join(format!(
        "{}-{}",
        stem,
        OffsetDateTime::now_utc().unix_timestamp_nanos()
    ))
}

async fn build_pairing_identity_exchange_bytes(
    paths: &skybridge_agent::AgentPaths,
    identity: &skybridge_agent::DeviceIdentityMaterial,
    local_binding: &ProtocolIdentityBinding,
) -> Result<Option<Vec<u8>>> {
    if local_binding.protocol_signing_algorithm != ProtocolSigningAlgorithm::MlDsa65
        && !pqc_bridge_identity_enabled()
    {
        return Ok(None);
    }
    let pqc_identity = ensure_rust_pqc_identity(paths).await?;
    let payload = PairingIdentityExchangePayload {
        device_id: local_binding.device_id.clone(),
        kem_public_keys: vec![
            PairingKemPublicKeyInfo {
                suite_wire_id: CryptoSuite::XWING_MLDSA.wire_id,
                public_key: pqc_identity.xwing_public_key,
            },
            PairingKemPublicKeyInfo {
                suite_wire_id: CryptoSuite::MLKEM768_MLDSA65.wire_id,
                public_key: pqc_identity.mlkem768_public_key,
            },
        ],
        device_name: Some(identity.state.device.device_name.clone()),
        platform: Some(std::env::consts::OS.to_owned()),
        remote_video_formats: Some(vec!["bgra".to_owned()]),
        sent_at: apple_reference_seconds_now_cli(),
    };
    Ok(Some(serde_json::to_vec(&json!({
        "pairingIdentityExchange": payload
    }))?))
}

fn decode_pairing_identity_exchange(data: &[u8]) -> Result<Option<PairingIdentityExchangePayload>> {
    let value: serde_json::Value = match serde_json::from_slice(data) {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };
    let Some(payload) = value.get("pairingIdentityExchange") else {
        return Ok(None);
    };
    Ok(Some(serde_json::from_value(payload.clone())?))
}

fn peer_kem_public_keys_from_payload(
    payload: &PairingIdentityExchangePayload,
) -> BTreeMap<CryptoSuite, Vec<u8>> {
    payload
        .kem_public_keys
        .iter()
        .filter_map(|value| match value.suite_wire_id {
            0x0001 => Some((CryptoSuite::XWING_MLDSA, value.public_key.clone())),
            0x0101 => Some((CryptoSuite::MLKEM768_MLDSA65, value.public_key.clone())),
            _ => None,
        })
        .collect()
}

async fn maybe_send_pairing_exchange(
    native_session: &NativeWebRtcSession,
    session_state: &mut SessionTransferState,
    pairing_bytes: &Option<Vec<u8>>,
) -> Result<()> {
    if session_state.pairing_sent {
        return Ok(());
    }
    if let Some(bytes) = pairing_bytes {
        native_session.send_app_payload(bytes.clone()).await?;
        session_state.pairing_sent = true;
    }
    Ok(())
}

async fn maybe_start_pqc_rekey(
    native_session: &NativeWebRtcSession,
    session_state: &mut SessionTransferState,
    local_device_id: &str,
    payload: &PairingIdentityExchangePayload,
) -> Result<()> {
    if session_state.rekey_attempted
        || current_suite_is_pqc(session_state.current_negotiated_suite.as_deref())
    {
        return Ok(());
    }
    let peer_kem_public_keys = peer_kem_public_keys_from_payload(payload);
    if peer_kem_public_keys.is_empty() {
        return Ok(());
    }
    if should_initiate_pqc_rekey(Some(local_device_id), Some(&payload.device_id)) == Some(true) {
        if native_session
            .start_outbound_pqc_rekey(Some(payload.device_id.clone()), peer_kem_public_keys)
            .await?
        {
            session_state.rekey_attempted = true;
        }
    }
    Ok(())
}

async fn file_receive(state_dir: Option<PathBuf>, args: FileReceiveArgs) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let auth_session = require_auth_session(&paths).await?;
    let tenant_id = require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(&paths).await?;
    let local_binding = signing_binding(&identity)?;
    let pairing_bytes = build_pairing_identity_exchange_bytes(&paths, &identity, &local_binding)
        .await?
        .ok_or_else(|| anyhow!("failed to prepare local PQC identity for file receive"))?;
    let pqc_initiator_template =
        maybe_inline_pqc_initiator_template(&paths, &identity, &local_binding).await?;
    let pqc_responder =
        maybe_inline_pqc_responder_config(&paths, &identity, &local_binding).await?;
    let signal_server = SignalServerClient::from_env()?;
    let admission =
        request_admission_lease(&signal_server, &auth_session, &tenant_id, &identity).await?;
    let lease = signal_server
        .register_connection_code(
            &admission.token,
            &identity.state.device.device_name,
            args.timeout_seconds as i64,
        )
        .await?;
    let turn_credentials = signal_server
        .fetch_turn_credentials(&lease.turn_admission_lease.token)
        .await?;
    let output_dir = output_dir_or_current_dir(args.output_dir)?;
    tokio::fs::create_dir_all(&output_dir).await?;

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
            RuntimeSessionState::Connecting,
        ),
    )
    .await?;

    let ws_url = signal_server.websocket_url(
        &lease.signaling_server_origin,
        &lease.session_id,
        &lease.session_token,
    )?;
    let mut connection = SignalingConnection::connect(ws_url, &lease.session_id).await?;
    let classic_initiator = skybridge_core::ClassicInitiatorConfig {
        local_binding: local_binding.clone(),
        signing_secret_key: identity
            .signing_key
            .ed25519_secret_key_bytes()
            .ok_or_else(|| anyhow!("classic initiator requires an Ed25519 protocol identity"))?,
        local_device_name: Some(identity.state.device.device_name.clone()),
    };
    let mut native_session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: lease.session_id.clone(),
        local_device_id: identity.state.device.device_id.clone(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: Some(turn_credentials),
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_initiator_template,
        pqc_responder,
    })
    .await?;
    native_session.start().await?;

    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "code": lease.code,
                "session_id": lease.session_id,
                "output_dir": output_dir.display().to_string(),
            }))?
        );
    } else {
        println!("Receive Code: {}", lease.code);
        println!("Session ID: {}", lease.session_id);
        println!("Output Dir: {}", output_dir.display());
    }

    let deadline = tokio::time::Instant::now() + Duration::from_secs(args.timeout_seconds);
    let mut signaling_bound = false;
    let mut signaling_stream_closed = false;
    let mut join_sent = false;
    let mut session_state = SessionTransferState::default();
    let mut inbound = BTreeMap::<String, ReceiveState>::new();

    loop {
        if tokio::time::Instant::now() >= deadline {
            bail!("timed out waiting for inbound file transfer");
        }

        tokio::select! {
            event = connection.next_runtime_event(), if !signaling_stream_closed => {
                let Some(event) = event else {
                    signaling_stream_closed = true;
                    continue;
                };
                match event {
                    SignalingRuntimeEvent::Lifecycle(lifecycle) => {
                        apply_runtime_session_event(&paths, &lease.session_id, &lifecycle).await?;
                        if lifecycle.phase == SignalingLifecyclePhase::Bound && !join_sent {
                            signaling_bound = true;
                            connection
                                .send(make_join_envelope(&lease.session_id, &identity.state.device.device_id))
                                .await?;
                            join_sent = true;
                        }
                        for payload in drain_inline_native_events_collect_app(
                            &paths,
                            &connection,
                            &lease.session_id,
                            &mut native_session,
                        ).await? {
                            if let Some(pairing) = decode_pairing_identity_exchange(&payload)? {
                                maybe_send_pairing_exchange(
                                    &native_session,
                                    &mut session_state,
                                    &Some(pairing_bytes.clone()),
                                )
                                .await?;
                                maybe_start_pqc_rekey(
                                    &native_session,
                                    &mut session_state,
                                    &identity.state.device.device_id,
                                    &pairing,
                                ).await?;
                                continue;
                            }

                            let msg: CrossNetworkFileTransferMessage = match serde_json::from_slice(&payload) {
                                Ok(msg) => msg,
                                Err(_) => continue,
                            };
                            match msg.op {
                                CrossNetworkFileTransferOp::Metadata => {
                                    let file_name = sanitize_filename(
                                        msg.file_name
                                            .as_deref()
                                            .ok_or_else(|| anyhow!("missing file_name"))?,
                                    );
                                    let file_size = msg.file_size.ok_or_else(|| anyhow!("missing file_size"))?;
                                    let chunk_size = msg.chunk_size.unwrap_or(64 * 1024);
                                    let transfer_id = msg.transfer_id.clone();
                                    let final_path = unique_destination(&output_dir, &file_name);
                                    let temp_path = final_path.with_extension("part");
                                    let file = tokio::fs::File::create(&temp_path).await?;
                                    inbound.insert(
                                        transfer_id.clone(),
                                        ReceiveState {
                                            transfer_id: transfer_id.clone(),
                                            file_name,
                                            file_size,
                                            chunk_size,
                                            temp_path,
                                            final_path,
                                            file,
                                            received_bytes: 0,
                                        },
                                    );
                                    native_session.send_app_payload(serde_json::to_vec(
                                        &CrossNetworkFileTransferMessage::new(
                                            CrossNetworkFileTransferOp::MetadataAck,
                                            transfer_id,
                                        )
                                    )?).await?;
                                }
                                CrossNetworkFileTransferOp::Chunk => {
                                    let idx = msg.chunk_index.ok_or_else(|| anyhow!("missing chunk_index"))?;
                                    let data = msg.chunk_data.ok_or_else(|| anyhow!("missing chunk_data"))?;
                                    let raw_size = msg.raw_size.unwrap_or(data.len() as i32).max(0) as i64;
                                    let Some(state) = inbound.get_mut(&msg.transfer_id) else {
                                        continue;
                                    };
                                    let offset = (idx as i64) * (state.chunk_size as i64);
                                    state.file.seek(std::io::SeekFrom::Start(offset.max(0) as u64)).await?;
                                    state.file.write_all(&data).await?;
                                    state.received_bytes = state.received_bytes.max(offset + raw_size).min(state.file_size);
                                    let mut ack = CrossNetworkFileTransferMessage::new(
                                        CrossNetworkFileTransferOp::ChunkAck,
                                        state.transfer_id.clone(),
                                    );
                                    ack.chunk_index = Some(idx);
                                    ack.received_bytes = Some(state.received_bytes);
                                    native_session.send_app_payload(serde_json::to_vec(&ack)?).await?;
                                }
                                CrossNetworkFileTransferOp::Complete => {
                                    let Some(state) = inbound.remove(&msg.transfer_id) else {
                                        continue;
                                    };
                                    state.file.sync_all().await?;
                                    drop(state.file);
                                    if tokio::fs::rename(&state.temp_path, &state.final_path).await.is_err() {
                                        let bytes = tokio::fs::read(&state.temp_path).await?;
                                        tokio::fs::write(&state.final_path, bytes).await?;
                                        let _ = tokio::fs::remove_file(&state.temp_path).await;
                                    }
                                    native_session.send_app_payload(serde_json::to_vec(
                                        &CrossNetworkFileTransferMessage::new(
                                            CrossNetworkFileTransferOp::CompleteAck,
                                            state.transfer_id.clone(),
                                        )
                                    )?).await?;
                                    append_file_transfer_history(
                                        &paths,
                                        FileTransferHistoryEntry {
                                            recorded_at: now_rfc3339(),
                                            direction: FileTransferDirection::Receive,
                                            session_id: lease.session_id.clone(),
                                            transfer_id: state.transfer_id.clone(),
                                            file_name: state.file_name.clone(),
                                            path: state.final_path.display().to_string(),
                                            bytes: state.received_bytes,
                                            suite: session_state.current_negotiated_suite.clone(),
                                            peer_device_id: None,
                                            peer_device_name: None,
                                        },
                                    )
                                    .await?;
                                    if args.json {
                                        println!(
                                            "{}",
                                            serde_json::to_string_pretty(&json!({
                                                "received": true,
                                                "session_id": lease.session_id,
                                                "path": state.final_path.display().to_string(),
                                                "bytes": state.received_bytes,
                                                "suite": session_state.current_negotiated_suite,
                                            }))?
                                        );
                                    } else {
                                        println!(
                                            "Received {} -> {} ({} bytes, suite={})",
                                            state.file_name,
                                            state.final_path.display(),
                                            state.received_bytes,
                                            session_state.current_negotiated_suite.as_deref().unwrap_or("unknown"),
                                        );
                                    }
                                    return Ok(());
                                }
                                CrossNetworkFileTransferOp::Error => {
                                    bail!(
                                        "sender reported error transfer={} message={}",
                                        msg.transfer_id,
                                        msg.message.unwrap_or_else(|| "-".to_string())
                                    );
                                }
                                CrossNetworkFileTransferOp::MetadataAck
                                | CrossNetworkFileTransferOp::ChunkAck
                                | CrossNetworkFileTransferOp::CompleteAck
                                | CrossNetworkFileTransferOp::Cancel => {}
                            }
                        }
                        if lifecycle.phase == SignalingLifecyclePhase::Failed && !signaling_bound {
                            bail!("signaling failed before bound");
                        }
                        if matches!(lifecycle.phase, SignalingLifecyclePhase::Closed | SignalingLifecyclePhase::Failed) {
                            signaling_stream_closed = true;
                        }
                    }
                    SignalingRuntimeEvent::Inbound(inbound_message) => {
                        apply_inline_inbound_runtime_event(
                            &paths,
                            &lease.session_id,
                            inbound_message,
                            &native_session,
                        )
                        .await?;
                        for payload in drain_inline_native_events_collect_app(
                            &paths,
                            &connection,
                            &lease.session_id,
                            &mut native_session,
                        ).await? {
                            if let Some(pairing) = decode_pairing_identity_exchange(&payload)? {
                                maybe_send_pairing_exchange(
                                    &native_session,
                                    &mut session_state,
                                    &Some(pairing_bytes.clone()),
                                )
                                .await?;
                                maybe_start_pqc_rekey(
                                    &native_session,
                                    &mut session_state,
                                    &identity.state.device.device_id,
                                    &pairing,
                                ).await?;
                                continue;
                            }
                            let msg: CrossNetworkFileTransferMessage = match serde_json::from_slice(&payload) {
                                Ok(msg) => msg,
                                Err(_) => continue,
                            };
                            match msg.op {
                                CrossNetworkFileTransferOp::Metadata => {
                                    let file_name = sanitize_filename(
                                        msg.file_name
                                            .as_deref()
                                            .ok_or_else(|| anyhow!("missing file_name"))?,
                                    );
                                    let file_size = msg.file_size.ok_or_else(|| anyhow!("missing file_size"))?;
                                    let chunk_size = msg.chunk_size.unwrap_or(64 * 1024);
                                    let transfer_id = msg.transfer_id.clone();
                                    let final_path = unique_destination(&output_dir, &file_name);
                                    let temp_path = final_path.with_extension("part");
                                    let file = tokio::fs::File::create(&temp_path).await?;
                                    inbound.insert(
                                        transfer_id.clone(),
                                        ReceiveState {
                                            transfer_id: transfer_id.clone(),
                                            file_name,
                                            file_size,
                                            chunk_size,
                                            temp_path,
                                            final_path,
                                            file,
                                            received_bytes: 0,
                                        },
                                    );
                                    native_session.send_app_payload(serde_json::to_vec(
                                        &CrossNetworkFileTransferMessage::new(
                                            CrossNetworkFileTransferOp::MetadataAck,
                                            transfer_id,
                                        )
                                    )?).await?;
                                }
                                CrossNetworkFileTransferOp::Chunk => {
                                    let idx = msg.chunk_index.ok_or_else(|| anyhow!("missing chunk_index"))?;
                                    let data = msg.chunk_data.ok_or_else(|| anyhow!("missing chunk_data"))?;
                                    let raw_size = msg.raw_size.unwrap_or(data.len() as i32).max(0) as i64;
                                    let Some(state) = inbound.get_mut(&msg.transfer_id) else {
                                        continue;
                                    };
                                    let offset = (idx as i64) * (state.chunk_size as i64);
                                    state.file.seek(std::io::SeekFrom::Start(offset.max(0) as u64)).await?;
                                    state.file.write_all(&data).await?;
                                    state.received_bytes = state.received_bytes.max(offset + raw_size).min(state.file_size);
                                    let mut ack = CrossNetworkFileTransferMessage::new(
                                        CrossNetworkFileTransferOp::ChunkAck,
                                        state.transfer_id.clone(),
                                    );
                                    ack.chunk_index = Some(idx);
                                    ack.received_bytes = Some(state.received_bytes);
                                    native_session.send_app_payload(serde_json::to_vec(&ack)?).await?;
                                }
                                CrossNetworkFileTransferOp::Complete => {
                                    let Some(state) = inbound.remove(&msg.transfer_id) else {
                                        continue;
                                    };
                                    state.file.sync_all().await?;
                                    drop(state.file);
                                    if tokio::fs::rename(&state.temp_path, &state.final_path).await.is_err() {
                                        let bytes = tokio::fs::read(&state.temp_path).await?;
                                        tokio::fs::write(&state.final_path, bytes).await?;
                                        let _ = tokio::fs::remove_file(&state.temp_path).await;
                                    }
                                    native_session.send_app_payload(serde_json::to_vec(
                                        &CrossNetworkFileTransferMessage::new(
                                            CrossNetworkFileTransferOp::CompleteAck,
                                            state.transfer_id.clone(),
                                        )
                                    )?).await?;
                                    append_file_transfer_history(
                                        &paths,
                                        FileTransferHistoryEntry {
                                            recorded_at: now_rfc3339(),
                                            direction: FileTransferDirection::Receive,
                                            session_id: lease.session_id.clone(),
                                            transfer_id: state.transfer_id.clone(),
                                            file_name: state.file_name.clone(),
                                            path: state.final_path.display().to_string(),
                                            bytes: state.received_bytes,
                                            suite: session_state.current_negotiated_suite.clone(),
                                            peer_device_id: None,
                                            peer_device_name: None,
                                        },
                                    )
                                    .await?;
                                    if args.json {
                                        println!(
                                            "{}",
                                            serde_json::to_string_pretty(&json!({
                                                "received": true,
                                                "session_id": lease.session_id,
                                                "path": state.final_path.display().to_string(),
                                                "bytes": state.received_bytes,
                                                "suite": session_state.current_negotiated_suite,
                                            }))?
                                        );
                                    } else {
                                        println!(
                                            "Received {} -> {} ({} bytes, suite={})",
                                            state.file_name,
                                            state.final_path.display(),
                                            state.received_bytes,
                                            session_state.current_negotiated_suite.as_deref().unwrap_or("unknown"),
                                        );
                                    }
                                    return Ok(());
                                }
                                CrossNetworkFileTransferOp::Error => {
                                    bail!(
                                        "sender reported error transfer={} message={}",
                                        msg.transfer_id,
                                        msg.message.unwrap_or_else(|| "-".to_string())
                                    );
                                }
                                CrossNetworkFileTransferOp::MetadataAck
                                | CrossNetworkFileTransferOp::ChunkAck
                                | CrossNetworkFileTransferOp::CompleteAck
                                | CrossNetworkFileTransferOp::Cancel => {}
                            }
                        }
                    }
                }
            }
            event = native_session.next_event() => {
                let Some(event) = event else {
                    continue;
                };
                match event {
                    NativeWebRtcEvent::AppPayload { data } => {
                        if let Some(pairing) = decode_pairing_identity_exchange(&data)? {
                            maybe_send_pairing_exchange(
                                &native_session,
                                &mut session_state,
                                &Some(pairing_bytes.clone()),
                            )
                            .await?;
                            maybe_start_pqc_rekey(
                                &native_session,
                                &mut session_state,
                                &identity.state.device.device_id,
                                &pairing,
                            ).await?;
                            continue;
                        }
                        let msg: CrossNetworkFileTransferMessage = match serde_json::from_slice(&data) {
                            Ok(msg) => msg,
                            Err(_) => continue,
                        };
                        match msg.op {
                            CrossNetworkFileTransferOp::Metadata => {
                                let file_name = sanitize_filename(
                                    msg.file_name
                                        .as_deref()
                                        .ok_or_else(|| anyhow!("missing file_name"))?,
                                );
                                let file_size = msg.file_size.ok_or_else(|| anyhow!("missing file_size"))?;
                                let chunk_size = msg.chunk_size.unwrap_or(64 * 1024);
                                let transfer_id = msg.transfer_id.clone();
                                let final_path = unique_destination(&output_dir, &file_name);
                                let temp_path = final_path.with_extension("part");
                                let file = tokio::fs::File::create(&temp_path).await?;
                                inbound.insert(
                                    transfer_id.clone(),
                                    ReceiveState {
                                        transfer_id: transfer_id.clone(),
                                        file_name,
                                        file_size,
                                        chunk_size,
                                        temp_path,
                                        final_path,
                                        file,
                                        received_bytes: 0,
                                    },
                                );
                                native_session.send_app_payload(serde_json::to_vec(
                                    &CrossNetworkFileTransferMessage::new(
                                        CrossNetworkFileTransferOp::MetadataAck,
                                        transfer_id,
                                    )
                                )?).await?;
                            }
                            CrossNetworkFileTransferOp::Chunk => {
                                let idx = msg.chunk_index.ok_or_else(|| anyhow!("missing chunk_index"))?;
                                let data = msg.chunk_data.ok_or_else(|| anyhow!("missing chunk_data"))?;
                                let raw_size = msg.raw_size.unwrap_or(data.len() as i32).max(0) as i64;
                                let Some(state) = inbound.get_mut(&msg.transfer_id) else {
                                    continue;
                                };
                                let offset = (idx as i64) * (state.chunk_size as i64);
                                state.file.seek(std::io::SeekFrom::Start(offset.max(0) as u64)).await?;
                                state.file.write_all(&data).await?;
                                state.received_bytes = state.received_bytes.max(offset + raw_size).min(state.file_size);
                                let mut ack = CrossNetworkFileTransferMessage::new(
                                    CrossNetworkFileTransferOp::ChunkAck,
                                    state.transfer_id.clone(),
                                );
                                ack.chunk_index = Some(idx);
                                ack.received_bytes = Some(state.received_bytes);
                                native_session.send_app_payload(serde_json::to_vec(&ack)?).await?;
                            }
                            CrossNetworkFileTransferOp::Complete => {
                                let Some(state) = inbound.remove(&msg.transfer_id) else {
                                    continue;
                                };
                                state.file.sync_all().await?;
                                drop(state.file);
                                if tokio::fs::rename(&state.temp_path, &state.final_path).await.is_err() {
                                    let bytes = tokio::fs::read(&state.temp_path).await?;
                                    tokio::fs::write(&state.final_path, bytes).await?;
                                    let _ = tokio::fs::remove_file(&state.temp_path).await;
                                }
                                native_session.send_app_payload(serde_json::to_vec(
                                    &CrossNetworkFileTransferMessage::new(
                                        CrossNetworkFileTransferOp::CompleteAck,
                                        state.transfer_id.clone(),
                                    )
                                )?).await?;
                                append_file_transfer_history(
                                    &paths,
                                    FileTransferHistoryEntry {
                                        recorded_at: now_rfc3339(),
                                        direction: FileTransferDirection::Receive,
                                        session_id: lease.session_id.clone(),
                                        transfer_id: state.transfer_id.clone(),
                                        file_name: state.file_name.clone(),
                                        path: state.final_path.display().to_string(),
                                        bytes: state.received_bytes,
                                        suite: session_state.current_negotiated_suite.clone(),
                                        peer_device_id: None,
                                        peer_device_name: None,
                                    },
                                )
                                .await?;
                                if args.json {
                                    println!(
                                        "{}",
                                        serde_json::to_string_pretty(&json!({
                                            "received": true,
                                            "session_id": lease.session_id,
                                            "path": state.final_path.display().to_string(),
                                            "bytes": state.received_bytes,
                                            "suite": session_state.current_negotiated_suite,
                                        }))?
                                    );
                                } else {
                                    println!(
                                        "Received {} -> {} ({} bytes, suite={})",
                                        state.file_name,
                                        state.final_path.display(),
                                        state.received_bytes,
                                        session_state.current_negotiated_suite.as_deref().unwrap_or("unknown"),
                                    );
                                }
                                return Ok(());
                            }
                            CrossNetworkFileTransferOp::Error => {
                                bail!(
                                    "sender reported error transfer={} message={}",
                                    msg.transfer_id,
                                    msg.message.unwrap_or_else(|| "-".to_string())
                                );
                            }
                            CrossNetworkFileTransferOp::MetadataAck
                            | CrossNetworkFileTransferOp::ChunkAck
                            | CrossNetworkFileTransferOp::CompleteAck
                            | CrossNetworkFileTransferOp::Cancel => {}
                        }
                    }
                    NativeWebRtcEvent::HandshakeComplete { negotiated_suite } => {
                        session_state.current_negotiated_suite = Some(negotiated_suite.clone());
                        apply_inline_native_event(
                            &paths,
                            &connection,
                            &lease.session_id,
                            NativeWebRtcEvent::HandshakeComplete { negotiated_suite },
                        )
                        .await?;
                        maybe_send_pairing_exchange(
                            &native_session,
                            &mut session_state,
                            &Some(pairing_bytes.clone()),
                        )
                        .await?;
                    }
                    other => {
                        apply_inline_native_event(&paths, &connection, &lease.session_id, other).await?;
                    }
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(100)) => {}
        }
    }
}

async fn file_send(state_dir: Option<PathBuf>, args: FileSendArgs) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let auth_session = require_auth_session(&paths).await?;
    let tenant_id = require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(&paths).await?;
    let local_binding = signing_binding(&identity)?;
    let pairing_bytes = build_pairing_identity_exchange_bytes(&paths, &identity, &local_binding)
        .await?
        .ok_or_else(|| anyhow!("failed to prepare local PQC identity for file send"))?;
    let pqc_initiator_template =
        maybe_inline_pqc_initiator_template(&paths, &identity, &local_binding).await?;
    let pqc_responder =
        maybe_inline_pqc_responder_config(&paths, &identity, &local_binding).await?;
    let classic_responder =
        maybe_inline_classic_responder_config(&identity, &local_binding, RuntimeSessionRole::Responder)?;
    let signal_server = SignalServerClient::from_env()?;
    let admission =
        request_admission_lease(&signal_server, &auth_session, &tenant_id, &identity).await?;
    let lookup = signal_server
        .lookup_connection_code(&admission.token, &args.to)
        .await?;
    let turn_credentials = signal_server
        .fetch_turn_credentials(&lookup.turn_admission_lease.token)
        .await?;
    let ws_url = signal_server.websocket_url(
        &lookup.signaling_server_origin,
        &lookup.session_id,
        &lookup.session_token,
    )?;
    let mut connection = SignalingConnection::connect(ws_url, &lookup.session_id).await?;

    upsert_session_runtime(
        &paths,
        RuntimeSessionRecord::new(
            make_runtime_id(&lookup.session_id),
            lookup.session_id.clone(),
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            lookup.signaling_server_origin.clone(),
            identity.state.device.device_id.clone(),
            Some(lookup.initiator_device_id.clone()),
            lookup.initiator_device_name.clone(),
            Some(lookup.initiator_protocol_public_key_fingerprint.clone()),
            RuntimeSessionState::Connecting,
        ),
    )
    .await?;

    let mut native_session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: lookup.session_id.clone(),
        local_device_id: identity.state.device.device_id.clone(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: Some(turn_credentials),
        classic_initiator: None,
        classic_responder,
        pqc_initiator: None,
        pqc_initiator_template,
        pqc_responder,
    })
    .await?;
    native_session.start().await?;

    let file_bytes = tokio::fs::read(&args.path).await?;
    let file_name = args
        .path
        .file_name()
        .and_then(|value| value.to_str())
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("failed to determine file name"))?;
    let chunk_size = 64 * 1024usize;
    let total_chunks = if file_bytes.is_empty() {
        0
    } else {
        ((file_bytes.len() - 1) / chunk_size) + 1
    };
    let transfer_id = next_transfer_id();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(args.timeout_seconds);
    let mut signaling_bound = false;
    let mut signaling_stream_closed = false;
    let mut join_sent = false;
    let mut session_state = SessionTransferState::default();
    let mut metadata_sent = false;
    let mut metadata_acked = false;
    let mut next_chunk_index = 0usize;
    let mut awaiting_chunk_ack = None::<i32>;
    let mut complete_sent = false;

    loop {
        if tokio::time::Instant::now() >= deadline {
            bail!("timed out sending file");
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
                                .send(make_join_envelope(&lookup.session_id, &identity.state.device.device_id))
                                .await?;
                            join_sent = true;
                        }
                        for payload in drain_inline_native_events_collect_app(
                            &paths,
                            &connection,
                            &lookup.session_id,
                            &mut native_session,
                        ).await? {
                            if let Some(pairing) = decode_pairing_identity_exchange(&payload)? {
                                maybe_send_pairing_exchange(
                                    &native_session,
                                    &mut session_state,
                                    &Some(pairing_bytes.clone()),
                                )
                                .await?;
                                maybe_start_pqc_rekey(
                                    &native_session,
                                    &mut session_state,
                                    &identity.state.device.device_id,
                                    &pairing,
                                ).await?;
                                continue;
                            }
                            let msg: CrossNetworkFileTransferMessage = match serde_json::from_slice(&payload) {
                                Ok(msg) => msg,
                                Err(_) => continue,
                            };
                            match msg.op {
                                CrossNetworkFileTransferOp::MetadataAck if msg.transfer_id == transfer_id => {
                                    metadata_acked = true;
                                }
                                CrossNetworkFileTransferOp::ChunkAck if msg.transfer_id == transfer_id => {
                                    if awaiting_chunk_ack == msg.chunk_index {
                                        awaiting_chunk_ack = None;
                                        next_chunk_index = next_chunk_index.saturating_add(1);
                                    }
                                }
                                CrossNetworkFileTransferOp::CompleteAck if msg.transfer_id == transfer_id => {
                                    append_file_transfer_history(
                                        &paths,
                                        FileTransferHistoryEntry {
                                            recorded_at: now_rfc3339(),
                                            direction: FileTransferDirection::Send,
                                            session_id: lookup.session_id.clone(),
                                            transfer_id: transfer_id.clone(),
                                            file_name: file_name.clone(),
                                            path: args.path.display().to_string(),
                                            bytes: file_bytes.len() as i64,
                                            suite: session_state.current_negotiated_suite.clone(),
                                            peer_device_id: Some(lookup.initiator_device_id.clone()),
                                            peer_device_name: lookup.initiator_device_name.clone(),
                                        },
                                    )
                                    .await?;
                                    if args.json {
                                        println!(
                                            "{}",
                                            serde_json::to_string_pretty(&json!({
                                                "sent": true,
                                                "session_id": lookup.session_id,
                                                "transfer_id": transfer_id,
                                                "bytes": file_bytes.len(),
                                                "suite": session_state.current_negotiated_suite,
                                            }))?
                                        );
                                    } else {
                                        println!(
                                            "Sent {} ({} bytes, suite={})",
                                            file_name,
                                            file_bytes.len(),
                                            session_state.current_negotiated_suite.as_deref().unwrap_or("unknown"),
                                        );
                                    }
                                    return Ok(());
                                }
                                CrossNetworkFileTransferOp::Error => {
                                    bail!(
                                        "receiver reported error transfer={} message={}",
                                        msg.transfer_id,
                                        msg.message.unwrap_or_else(|| "-".to_string())
                                    );
                                }
                                _ => {}
                            }
                        }
                        if lifecycle.phase == SignalingLifecyclePhase::Failed && !signaling_bound {
                            bail!("signaling failed before bound");
                        }
                        if matches!(lifecycle.phase, SignalingLifecyclePhase::Closed | SignalingLifecyclePhase::Failed) {
                            signaling_stream_closed = true;
                        }
                    }
                    SignalingRuntimeEvent::Inbound(inbound_message) => {
                        apply_inline_inbound_runtime_event(
                            &paths,
                            &lookup.session_id,
                            inbound_message,
                            &native_session,
                        )
                        .await?;
                        for payload in drain_inline_native_events_collect_app(
                            &paths,
                            &connection,
                            &lookup.session_id,
                            &mut native_session,
                        ).await? {
                            if let Some(pairing) = decode_pairing_identity_exchange(&payload)? {
                                maybe_send_pairing_exchange(
                                    &native_session,
                                    &mut session_state,
                                    &Some(pairing_bytes.clone()),
                                )
                                .await?;
                                maybe_start_pqc_rekey(
                                    &native_session,
                                    &mut session_state,
                                    &identity.state.device.device_id,
                                    &pairing,
                                ).await?;
                            }
                        }
                    }
                }
            }
            event = native_session.next_event() => {
                let Some(event) = event else {
                    continue;
                };
                match event {
                    NativeWebRtcEvent::AppPayload { data } => {
                        if let Some(pairing) = decode_pairing_identity_exchange(&data)? {
                            maybe_send_pairing_exchange(
                                &native_session,
                                &mut session_state,
                                &Some(pairing_bytes.clone()),
                            )
                            .await?;
                            maybe_start_pqc_rekey(
                                &native_session,
                                &mut session_state,
                                &identity.state.device.device_id,
                                &pairing,
                            ).await?;
                            continue;
                        }
                        if let Ok(msg) = serde_json::from_slice::<CrossNetworkFileTransferMessage>(&data) {
                            match msg.op {
                                CrossNetworkFileTransferOp::MetadataAck if msg.transfer_id == transfer_id => {
                                    metadata_acked = true;
                                }
                                CrossNetworkFileTransferOp::ChunkAck if msg.transfer_id == transfer_id => {
                                    if awaiting_chunk_ack == msg.chunk_index {
                                        awaiting_chunk_ack = None;
                                        next_chunk_index = next_chunk_index.saturating_add(1);
                                    }
                                }
                                CrossNetworkFileTransferOp::CompleteAck if msg.transfer_id == transfer_id => {
                                    append_file_transfer_history(
                                        &paths,
                                        FileTransferHistoryEntry {
                                            recorded_at: now_rfc3339(),
                                            direction: FileTransferDirection::Send,
                                            session_id: lookup.session_id.clone(),
                                            transfer_id: transfer_id.clone(),
                                            file_name: file_name.clone(),
                                            path: args.path.display().to_string(),
                                            bytes: file_bytes.len() as i64,
                                            suite: session_state.current_negotiated_suite.clone(),
                                            peer_device_id: Some(lookup.initiator_device_id.clone()),
                                            peer_device_name: lookup.initiator_device_name.clone(),
                                        },
                                    )
                                    .await?;
                                    if args.json {
                                        println!(
                                            "{}",
                                            serde_json::to_string_pretty(&json!({
                                                "sent": true,
                                                "session_id": lookup.session_id,
                                                "transfer_id": transfer_id,
                                                "bytes": file_bytes.len(),
                                                "suite": session_state.current_negotiated_suite,
                                            }))?
                                        );
                                    } else {
                                        println!(
                                            "Sent {} ({} bytes, suite={})",
                                            file_name,
                                            file_bytes.len(),
                                            session_state.current_negotiated_suite.as_deref().unwrap_or("unknown"),
                                        );
                                    }
                                    return Ok(());
                                }
                                CrossNetworkFileTransferOp::Error => {
                                    bail!(
                                        "receiver reported error transfer={} message={}",
                                        msg.transfer_id,
                                        msg.message.unwrap_or_else(|| "-".to_string())
                                    );
                                }
                                _ => {}
                            }
                        }
                    }
                    NativeWebRtcEvent::HandshakeComplete { negotiated_suite } => {
                        session_state.current_negotiated_suite = Some(negotiated_suite.clone());
                        apply_inline_native_event(
                            &paths,
                            &connection,
                            &lookup.session_id,
                            NativeWebRtcEvent::HandshakeComplete { negotiated_suite },
                        )
                        .await?;
                        maybe_send_pairing_exchange(
                            &native_session,
                            &mut session_state,
                            &Some(pairing_bytes.clone()),
                        )
                        .await?;
                    }
                    other => {
                        apply_inline_native_event(&paths, &connection, &lookup.session_id, other).await?;
                    }
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(100)) => {}
        }

        if !current_suite_is_pqc(session_state.current_negotiated_suite.as_deref()) {
            continue;
        }

        if !metadata_sent {
            let mut metadata = CrossNetworkFileTransferMessage::new(
                CrossNetworkFileTransferOp::Metadata,
                transfer_id.clone(),
            );
            metadata.sender_device_id = Some(identity.state.device.device_id.clone());
            metadata.sender_device_name = Some(identity.state.device.device_name.clone());
            metadata.file_name = Some(file_name.clone());
            metadata.file_size = Some(file_bytes.len() as i64);
            metadata.chunk_size = Some(chunk_size as i32);
            metadata.total_chunks = Some(total_chunks as i32);
            metadata.mime_type = Some("application/octet-stream".to_owned());
            native_session.send_app_payload(serde_json::to_vec(&metadata)?).await?;
            metadata_sent = true;
            continue;
        }

        if metadata_acked && awaiting_chunk_ack.is_none() && next_chunk_index < total_chunks {
            let start = next_chunk_index * chunk_size;
            let end = std::cmp::min(start + chunk_size, file_bytes.len());
            let chunk = &file_bytes[start..end];
            let mut message = CrossNetworkFileTransferMessage::new(
                CrossNetworkFileTransferOp::Chunk,
                transfer_id.clone(),
            );
            message.chunk_index = Some(next_chunk_index as i32);
            message.chunk_data = Some(chunk.to_vec());
            message.raw_size = Some(chunk.len() as i32);
            native_session.send_app_payload(serde_json::to_vec(&message)?).await?;
            awaiting_chunk_ack = Some(next_chunk_index as i32);
            continue;
        }

        if metadata_acked
            && next_chunk_index >= total_chunks
            && awaiting_chunk_ack.is_none()
            && !complete_sent
        {
            native_session.send_app_payload(serde_json::to_vec(
                &CrossNetworkFileTransferMessage::new(
                    CrossNetworkFileTransferOp::Complete,
                    transfer_id.clone(),
                )
            )?).await?;
            complete_sent = true;
        }
    }
}

async fn file_history(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let history = load_file_transfer_history(&paths).await?;

    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "history": history,
            }))?
        );
        return Ok(());
    }

    if history.is_empty() {
        println!("No file transfer history yet.");
        return Ok(());
    }

    for entry in history {
        let direction = match entry.direction {
            FileTransferDirection::Send => "send",
            FileTransferDirection::Receive => "receive",
        };
        println!(
            "{} {} {} bytes {} suite={} peer={} path={}",
            entry.recorded_at,
            direction,
            entry.bytes,
            entry.file_name,
            entry.suite.as_deref().unwrap_or("unknown"),
            entry
                .peer_device_name
                .as_deref()
                .or(entry.peer_device_id.as_deref())
                .unwrap_or("-"),
            entry.path,
        );
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
        "implemented_phases": ["phase_4_auth", "phase_5_signaling_plane", "phase_6_file_transfer"],
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
        NativeWebRtcEvent::AppPayload { .. } => {}
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pqc_bridge_identity_defaults_to_enabled() {
        // SAFETY: test-scoped env mutation.
        unsafe { std::env::remove_var(ENV_PQC_BRIDGE_IDENTITY) };
        assert!(pqc_bridge_identity_enabled());
        // SAFETY: test-scoped env mutation.
        unsafe { std::env::set_var(ENV_PQC_BRIDGE_IDENTITY, "0") };
        assert!(!pqc_bridge_identity_enabled());
    }

    #[tokio::test]
    async fn file_transfer_history_round_trip() {
        let root = std::env::temp_dir().join(format!(
            "skybridge-cli-history-test-{}",
            OffsetDateTime::now_utc().unix_timestamp_nanos()
        ));
        std::fs::create_dir_all(&root).expect("create temp root");
        let paths = skybridge_agent::AgentPaths {
            root: root.clone(),
            identity_dir: root.join("identity"),
            runtime_dir: root.join("runtime"),
            logs_dir: root.join("logs"),
            identity_file: root.join("identity").join("device.json"),
            session_controls_file: root.join("runtime").join("session-controls.json"),
            health_file: root.join("runtime").join("health.json"),
            log_file: root.join("logs").join("agent.log"),
        };
        let entry = FileTransferHistoryEntry {
            recorded_at: "2026-03-20T00:00:00Z".to_owned(),
            direction: FileTransferDirection::Send,
            session_id: "session-1".to_owned(),
            transfer_id: "transfer-1".to_owned(),
            file_name: "demo.txt".to_owned(),
            path: "/tmp/demo.txt".to_owned(),
            bytes: 42,
            suite: Some("X-Wing + AES-256-GCM + ML-DSA-65".to_owned()),
            peer_device_id: Some("peer-1".to_owned()),
            peer_device_name: Some("Peer".to_owned()),
        };

        append_file_transfer_history(&paths, entry.clone())
            .await
            .expect("append");
        let history = load_file_transfer_history(&paths).await.expect("load");
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].transfer_id, entry.transfer_id);
        assert_eq!(history[0].bytes, entry.bytes);
        std::fs::remove_dir_all(root).expect("cleanup temp root");
    }
}
