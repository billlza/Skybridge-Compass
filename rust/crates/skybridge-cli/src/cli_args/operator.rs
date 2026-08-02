use std::path::PathBuf;

use clap::{Args, Subcommand};

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
    #[arg(
        long,
        default_value_t = 30,
        value_parser = clap::value_parser!(u64).range(1..=300)
    )]
    pub(crate) timeout_seconds: u64,
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
    Discover(DeviceDiscoverArgs),
    Enroll(DeviceEnrollArgs),
    Approve(DeviceApproveArgs),
}

#[derive(Debug, Args)]
pub(crate) struct DeviceDiscoverArgs {
    #[arg(long)]
    pub(crate) nearby: bool,
    #[arg(long, requires = "nearby")]
    pub(crate) scan: bool,
    /// Foreground mDNS browse window. Omit for the bounded 4-second default.
    #[arg(
        long,
        requires = "scan",
        value_parser = clap::value_parser!(u64).range(1..=30)
    )]
    pub(crate) scan_seconds: Option<u64>,
    /// Include ephemeral mDNS-advertised IP/port observations in this response.
    #[arg(long, requires = "scan")]
    pub(crate) show_addresses: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
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

#[derive(Debug, Subcommand)]
pub(crate) enum RemoteDesktopSubcommand {
    Contract(OutputOptions),
    Status(RemoteDesktopStatusArgs),
    Resolutions(RemoteDesktopResolutionsArgs),
    Start(RemoteDesktopStartArgs),
    Stop(RemoteDesktopSessionActionArgs),
    SetResolution(RemoteDesktopSetResolutionArgs),
    SetFps(RemoteDesktopSetFpsArgs),
}

#[derive(Debug, Args)]
pub(crate) struct RemoteDesktopCommand {
    #[command(subcommand)]
    pub(crate) command: RemoteDesktopSubcommand,
}

#[derive(Debug, Args)]
pub(crate) struct RemoteDesktopStatusArgs {
    #[arg(long)]
    pub(crate) session_id: Option<String>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct RemoteDesktopResolutionsArgs {
    #[arg(long)]
    pub(crate) session_id: Option<String>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct RemoteDesktopStartArgs {
    #[arg(long)]
    pub(crate) session_id: String,
    #[arg(long, default_value = "auto")]
    pub(crate) resolution: String,
    #[arg(long, default_value_t = 60)]
    pub(crate) fps: u16,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct RemoteDesktopSessionActionArgs {
    #[arg(long)]
    pub(crate) session_id: String,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct RemoteDesktopSetResolutionArgs {
    #[arg(long)]
    pub(crate) session_id: String,
    #[arg(long)]
    pub(crate) resolution: String,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct RemoteDesktopSetFpsArgs {
    #[arg(long)]
    pub(crate) session_id: String,
    #[arg(long)]
    pub(crate) fps: u16,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Subcommand)]
pub(crate) enum FileSubcommand {
    Send(FileSendArgs),
    Receive(FileReceiveArgs),
    History(OutputOptions),
}

#[derive(Debug, Args)]
pub(crate) struct FileSendArgs {
    pub(crate) path: PathBuf,
    #[arg(long)]
    pub(crate) to: String,
    #[arg(long)]
    pub(crate) session_id: Option<String>,
    /// Return after the active agent accepts the request instead of waiting for a verified receipt.
    #[arg(long)]
    pub(crate) detach: bool,
    #[arg(
        long,
        default_value_t = 300,
        value_parser = clap::value_parser!(u64).range(1..=3600)
    )]
    pub(crate) timeout_seconds: u64,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
#[command(group(
    clap::ArgGroup::new("receive_action")
        .required(true)
        .args(["accept", "reject", "list"])
))]
pub(crate) struct FileReceiveArgs {
    /// Session containing the authenticated inbound approval request.
    #[arg(long, required_unless_present = "list")]
    pub(crate) session_id: Option<String>,
    /// Approve one pending inbound transfer by canonical transfer UUID.
    #[arg(long, conflicts_with_all = ["reject", "list"])]
    pub(crate) accept: Option<String>,
    /// Reject one pending inbound transfer by canonical transfer UUID.
    #[arg(long, conflicts_with_all = ["accept", "list"])]
    pub(crate) reject: Option<String>,
    /// List persisted inbound approval requests without changing them.
    #[arg(long, conflicts_with_all = ["accept", "reject"])]
    pub(crate) list: bool,
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
