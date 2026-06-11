use std::path::PathBuf;

use clap::{Args, Subcommand, ValueEnum};

use crate::performance_budgets::P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS;

use super::OutputOptions;

#[derive(Debug, Args)]
pub(crate) struct LoginCommand {
    #[arg(long)]
    pub(crate) no_open: bool,
    #[arg(long)]
    pub(crate) print_only: bool,
    #[arg(long)]
    pub(crate) redirect_uri: Option<String>,
    #[arg(long)]
    pub(crate) callback_url: Option<String>,
    #[arg(long)]
    pub(crate) authorization_code: Option<String>,
}

#[derive(Debug, Args)]
pub(crate) struct DisconnectCommand {
    pub(crate) session_id: String,
}

#[derive(Debug, Args)]
pub(crate) struct ConnectCommand {
    pub(crate) code: String,
    #[arg(long, default_value_t = 5)]
    pub(crate) hold_seconds: u64,
    #[arg(long)]
    pub(crate) json: bool,
}

#[derive(Debug, Subcommand)]
pub(crate) enum AgentSubcommand {
    Run,
}

#[derive(Debug, Args)]
pub(crate) struct AgentCommand {
    #[command(subcommand)]
    pub(crate) command: AgentSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum DeviceSubcommand {
    Status(OutputOptions),
    Enroll(DeviceEnrollArgs),
    Approve(DeviceApproveArgs),
    /// Browse the local network for SkyBridge devices via mDNS/Bonjour.
    Discover(DeviceDiscoverArgs),
}

#[derive(Debug, Args)]
pub(crate) struct DeviceDiscoverArgs {
    /// How long to browse before reporting results.
    #[arg(long, default_value_t = 5)]
    pub(crate) timeout_seconds: u64,
    /// mDNS service types to browse. Defaults to the SkyBridge control,
    /// file-transfer, and remote-desktop services advertised by the apps.
    #[arg(
        long = "service-type",
        value_name = "TYPE",
        value_parser = parse_non_empty_argument
    )]
    pub(crate) service_types: Vec<String>,
    /// Require at least one discovered service for the named capability.
    #[arg(long = "require-capability", value_enum, value_name = "CAPABILITY")]
    pub(crate) required_capabilities: Vec<DeviceCapabilityArg>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, ValueEnum)]
pub(crate) enum DeviceCapabilityArg {
    Control,
    FileTransfer,
    RemoteDesktop,
}

#[derive(Debug, Args)]
pub(crate) struct DeviceEnrollArgs {
    #[arg(long)]
    pub(crate) invite_token: Option<String>,
    #[arg(long)]
    pub(crate) device_name: Option<String>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct DeviceApproveArgs {
    #[arg(value_name = "PENDING_DEVICE_ID")]
    pub(crate) pending_device_id: String,
    #[arg(long, default_value = "Ed25519")]
    pub(crate) pending_algorithm: String,
    #[arg(long)]
    pub(crate) pending_fingerprint: String,
    #[arg(long)]
    pub(crate) device_name: Option<String>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct DeviceCommand {
    #[command(subcommand)]
    pub(crate) command: DeviceSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum CodeSubcommand {
    Create(CodeCreateArgs),
    Current(CodeCurrentArgs),
}

#[derive(Debug, Args)]
pub(crate) struct CodeCreateArgs {
    #[arg(long)]
    pub(crate) device_name: Option<String>,
    #[arg(long, default_value_t = 300)]
    pub(crate) ttl_seconds: i64,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CodeCurrentArgs {
    #[arg(long)]
    pub(crate) snapshot: Option<PathBuf>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CodeCommand {
    #[command(subcommand)]
    pub(crate) command: CodeSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum SessionSubcommand {
    Ls(OutputOptions),
    Inspect(SessionInspectArgs),
    #[command(name = "remote-desktop")]
    RemoteDesktop(RemoteDesktopCommand),
}

#[derive(Debug, Args)]
pub(crate) struct SessionInspectArgs {
    pub(crate) id: String,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct SessionCommand {
    #[command(subcommand)]
    pub(crate) command: SessionSubcommand,
}

#[derive(Debug, Args)]
pub(crate) struct RemoteDesktopCommand {
    #[command(subcommand)]
    pub(crate) command: RemoteDesktopSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum RemoteDesktopSubcommand {
    /// Prove a P2P remote-desktop artifact with the strict performance gate.
    Prove(RemoteDesktopProveArgs),
}

#[derive(Debug, Args)]
pub(crate) struct RemoteDesktopProveArgs {
    #[arg(long)]
    pub(crate) artifact_dir: PathBuf,
    #[arg(long, default_value_t = 59.0)]
    pub(crate) min_fps: f64,
    #[arg(long, default_value_t = 0)]
    pub(crate) min_width: u32,
    #[arg(long, default_value_t = 0)]
    pub(crate) min_height: u32,
    #[arg(long)]
    pub(crate) exact_video_size: bool,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    pub(crate) require_audio: bool,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    pub(crate) strict_fps_floor: bool,
    #[arg(long, default_value_t = P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS)]
    pub(crate) min_pass_window_seconds: u64,
    #[arg(long)]
    pub(crate) manual_artifact: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Subcommand)]
pub(crate) enum FileSubcommand {
    Send(FileSendArgs),
    Receive,
    History(OutputOptions),
    /// Prove a real-device file-transfer artifact with the strict performance gate.
    Prove(FileProveArgs),
}

#[derive(Debug, Args)]
pub(crate) struct FileSendArgs {
    pub(crate) path: PathBuf,
    #[arg(long)]
    pub(crate) to: String,
}

#[derive(Debug, Args)]
pub(crate) struct FileProveArgs {
    #[arg(long)]
    pub(crate) artifact_dir: PathBuf,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct FileCommand {
    #[command(subcommand)]
    pub(crate) command: FileSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum LogsSubcommand {
    Tail(TailArgs),
}

#[derive(Debug, Args)]
pub(crate) struct TailArgs {
    #[arg(long, default_value_t = 50)]
    pub(crate) lines: usize,
}

#[derive(Debug, Args)]
pub(crate) struct LogsCommand {
    #[command(subcommand)]
    pub(crate) command: LogsSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum InternalSubcommand {
    VerifyMldsa(VerifyMldsaArgs),
}

#[derive(Debug, Args)]
pub(crate) struct InternalCommand {
    #[command(subcommand)]
    pub(crate) command: InternalSubcommand,
}

#[derive(Debug, Args)]
pub(crate) struct VerifyMldsaArgs {
    #[arg(long)]
    pub(crate) message_base64: String,
    #[arg(long)]
    pub(crate) signature_base64: String,
    #[arg(long)]
    pub(crate) public_key_base64: String,
}

fn parse_non_empty_argument(value: &str) -> Result<String, String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        Err("value must not be empty".to_owned())
    } else {
        Ok(trimmed.to_owned())
    }
}
