use clap::{Args, Subcommand, ValueEnum};

use super::OutputOptions;

#[derive(Debug, Args)]
pub(crate) struct CrossnetCommand {
    #[command(subcommand)]
    pub(crate) command: CrossnetSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum CrossnetSubcommand {
    /// Inspect or change handshake profiles through native application services.
    Handshake(CrossnetHandshakeArgs),
    /// Check whether the running Mac app is ready for GUI-bound crossnet mutations.
    Preflight(OutputOptions),
    /// Host a cross-network connection code via the SkyBridge app control socket.
    ///
    /// This is not read-only with respect to an existing session: requesting a
    /// lease that differs from the app's active one tears the current session
    /// down first. When the lease and authority already match, the app returns
    /// its existing code rather than issuing a new one.
    Host(CrossnetHostArgs),
    /// Connect to a hosted cross-network code.
    Connect(CrossnetConnectArgs),
    /// Disconnect the current cross-network session.
    Disconnect(OutputOptions),
    /// Show (or watch) cross-network control status.
    Status(CrossnetStatusArgs),
    /// Navigate the running Mac app UI to a sidebar destination.
    Navigate(CrossnetNavigateArgs),
    /// List the online account devices the Mac app can see.
    Devices(OutputOptions),
    /// One-click connect to an online account device by its `device_ref`.
    ///
    /// The remote device admits through pinned trust / account presence, so
    /// nothing needs to be tapped or typed on it.
    ConnectDevice(CrossnetConnectDeviceArgs),
    /// Show the Mac app settings projection, or change one allowlisted setting.
    Settings(CrossnetSettingsArgs),
    /// Discover nearby peers through the running Mac app's real P2P service.
    Nearby(CrossnetNearbyArgs),
    /// Connect and authenticate one discovery target in the Mac app.
    ConnectNearby(CrossnetConnectDeviceArgs),
    /// Send files through the Mac app, with progress and a verified receiver receipt.
    File(CrossnetFileArgs),
    /// Discover and connect Apple devices over the physical USB cable.
    Usb(CrossnetUSBArgs),
    /// Inspect the exact stored trust records before an explicit recovery.
    Trust(CrossnetTrustArgs),
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetTrustArgs {
    #[command(subcommand)]
    pub(crate) command: CrossnetTrustSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum CrossnetTrustSubcommand {
    /// Read real product storage and signature results; does not change trust.
    Preview(CrossnetTrustPreviewArgs),
    /// Verify the peer over USB and retire only approved stale mirror aliases.
    Recover(CrossnetTrustRecoverArgs),
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetTrustRecoverArgs {
    #[command(flatten)]
    pub(crate) target: CrossnetUSBConnectArgs,
    /// Exact read-only preview digest. Changed storage refuses the mutation.
    #[arg(long)]
    pub(crate) snapshot_sha256: String,
    /// Unique UUID for the immutable recovery archive; never reuse after uncertainty.
    #[arg(long)]
    pub(crate) recovery_id: String,
    /// Explicitly authorize stale mirror retirement while preserving the existing key.
    #[arg(long, required = true)]
    pub(crate) approve_mirror_retirement: bool,
    /// Separately approved historical peer whose own records must remain unchanged.
    #[arg(long)]
    pub(crate) preserve_shared_peer_id: Option<String>,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetTrustPreviewArgs {
    #[arg(long)]
    pub(crate) peer_id: String,
    #[arg(long)]
    pub(crate) expected_fingerprint: String,
    /// Preview shared-alias retirement while preserving this exact other peer.
    #[arg(long)]
    pub(crate) preserve_shared_peer_id: Option<String>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetUSBArgs {
    #[command(subcommand)]
    pub(crate) command: CrossnetUSBSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum CrossnetUSBSubcommand {
    /// Enumerate USB entries from the OS multiplexer; exclude network twins.
    Devices(OutputOptions),
    /// List existing paired identities without requiring network discovery.
    Peers(OutputOptions),
    /// Activate the selected USB device's existing SkyBridge app using Apple tools.
    Wake(CrossnetUSBWakeArgs),
    /// Authenticate the selected peer over USB, without a network fallback.
    Connect(CrossnetUSBConnectArgs),
    /// Connect a named app device over a selected cable, without network fallback.
    ConnectDevice(CrossnetUSBDeviceConnectArgs),
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetUSBDeviceConnectArgs {
    pub(crate) udid: String,
    #[arg(long)]
    pub(crate) to: String,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetUSBWakeArgs {
    pub(crate) udid: String,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetUSBConnectArgs {
    /// Physical device UDID from `crossnet usb devices`.
    pub(crate) udid: String,
    /// Stable protocol device UUID from the paired device/account, not a discovery reference.
    #[arg(long)]
    pub(crate) peer_id: String,
    /// Full lowercase protocol fingerprint shown for the selected peer.
    #[arg(long)]
    pub(crate) expected_fingerprint: String,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetNearbyArgs {
    /// Zero reads the current snapshot; a positive value starts app-owned scanning.
    #[arg(long, default_value_t = 3, value_parser = clap::value_parser!(u64).range(0..=10))]
    pub(crate) scan_seconds: u64,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetFileArgs {
    #[command(subcommand)]
    pub(crate) command: CrossnetFileSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum CrossnetFileSubcommand {
    Send(CrossnetFileSendArgs),
    /// Inspect or decide real receiver prompts, or manage the separate CLI permission.
    Approval(CrossnetFileApprovalArgs),
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetFileApprovalArgs {
    #[arg(value_enum)]
    pub(crate) action: FileApprovalAction,
    #[arg(long)]
    pub(crate) to: String,
    #[arg(long, requires = "decision")]
    pub(crate) approval_id: Option<String>,
    #[arg(long, value_enum, requires = "approval_id")]
    pub(crate) decision: Option<FileDecision>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}
#[derive(Debug, Clone, Copy, ValueEnum)]
pub(crate) enum FileApprovalAction {
    Status,
    Authorize,
    Decide,
    Revoke,
}
#[derive(Debug, Clone, Copy, ValueEnum)]
pub(crate) enum FileDecision {
    Allow,
    Deny,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum FileApprovalMode {
    Prompt,
    Allow,
    Deny,
    Device,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetFileSendArgs {
    pub(crate) path: std::path::PathBuf,
    /// Prompt in the terminal, explicitly allow/deny this file, or handle on the device.
    #[arg(long, value_enum, default_value = "prompt")]
    pub(crate) approval: FileApprovalMode,
    /// Authenticated device_ref from `crossnet nearby` / `connect-nearby`.
    #[arg(long)]
    pub(crate) to: String,
    #[arg(long, default_value_t = 300, value_parser = clap::value_parser!(u64).range(1..=3600))]
    pub(crate) timeout_seconds: u64,
    /// Terminal progress on stderr. JSON mode emits only the final result.
    #[arg(long, value_enum, default_value_t = crate::transfer_progress::ProgressMode::Auto, conflicts_with = "json")]
    pub(crate) progress: crate::transfer_progress::ProgressMode,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetSettingsArgs {
    /// Omit to print the read-only projection.
    #[command(subcommand)]
    pub(crate) command: Option<CrossnetSettingsSubcommand>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Subcommand)]
pub(crate) enum CrossnetSettingsSubcommand {
    /// Apply one allowlisted setting to the running Mac app and report the
    /// value its runtime reads back.
    Set(CrossnetSettingsSetArgs),
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetSettingsSetArgs {
    /// Settings projection id, for example `logging.level`.
    #[arg(value_name = "ID")]
    pub(crate) id: String,
    /// `true`/`false` for boolean settings, otherwise the string value.
    #[arg(value_name = "VALUE")]
    pub(crate) value: String,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetConnectDeviceArgs {
    /// Redacted device reference from `skybridge crossnet devices`.
    #[arg(value_name = "DEVICE_REF")]
    pub(crate) device_ref: String,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetNavigateArgs {
    /// Typed destination from the crossnet-control/1 navigation vocabulary.
    #[arg(value_enum, value_name = "DESTINATION")]
    pub(crate) destination: CrossnetNavigateDestination,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

/// The CLI-side mirror of the app's typed navigation vocabulary.
///
/// The app re-validates on its side, so an out-of-date CLI cannot navigate to
/// a destination the installed app does not have.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum CrossnetNavigateDestination {
    Dashboard,
    DeviceManagement,
    UsbDeviceManagement,
    FileTransfer,
    RemoteDesktop,
    QuantumCommunication,
    SystemMonitor,
    Settings,
}

impl CrossnetNavigateDestination {
    pub(crate) fn as_wire(self) -> &'static str {
        match self {
            Self::Dashboard => "dashboard",
            Self::DeviceManagement => "device_management",
            Self::UsbDeviceManagement => "usb_device_management",
            Self::FileTransfer => "file_transfer",
            Self::RemoteDesktop => "remote_desktop",
            Self::QuantumCommunication => "quantum_communication",
            Self::SystemMonitor => "system_monitor",
            Self::Settings => "settings",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum CrossnetLeaseMode {
    Short,
    Long,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetHostArgs {
    /// Lease for the issued code. Omit to keep the app's current lease.
    ///
    /// Passing a lease that differs from the active one disconnects the
    /// existing session before issuing the new code.
    #[arg(long, value_enum)]
    pub(crate) lease: Option<CrossnetLeaseMode>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetConnectArgs {
    #[arg(value_name = "CODE")]
    pub(crate) code: String,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetStatusArgs {
    #[arg(long)]
    pub(crate) watch: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetHandshakeArgs {
    #[command(subcommand)]
    pub(crate) command: CrossnetHandshakeSubcommand,
}
#[derive(Debug, Subcommand)]
pub(crate) enum CrossnetHandshakeSubcommand {
    /// List profiles and local runtime availability.
    List(OutputOptions),
    /// Read local/remote preferences and the actual negotiated session suite.
    Status(CrossnetHandshakeTargetArgs),
    /// Apply a profile for subsequent connections; remote management requires peer consent.
    Set(CrossnetHandshakeSetArgs),
    /// Revoke this Mac's persistent management permission on the selected peer.
    #[command(group(clap::ArgGroup::new("revoke_target").args(["to", "usb"]).required(true)))]
    Revoke(CrossnetHandshakeTargetArgs),
}
#[derive(Debug, Args)]
#[command(group(clap::ArgGroup::new("handshake_target").args(["to", "usb"]).multiple(false)))]
pub(crate) struct CrossnetHandshakeTargetArgs {
    #[arg(long, value_name = "DEVICE_REF", conflicts_with = "usb")]
    pub(crate) to: Option<String>,
    /// Direct USB route; pair with the exact protocol identity flags.
    #[arg(long, requires_all = ["peer_id", "expected_fingerprint"])]
    pub(crate) usb: Option<String>,
    #[arg(long, requires = "usb")]
    pub(crate) peer_id: Option<String>,
    #[arg(long, requires = "usb")]
    pub(crate) expected_fingerprint: Option<String>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}
#[derive(Debug, Clone, Copy, ValueEnum)]
pub(crate) enum HandshakeProfileArg {
    Qperiapt,
    Xwing,
    Mlkem,
    Classic,
}
impl From<HandshakeProfileArg> for skybridge_crossnet_client::HandshakeProfile {
    fn from(value: HandshakeProfileArg) -> Self {
        match value {
            HandshakeProfileArg::Qperiapt => Self::Qperiapt,
            HandshakeProfileArg::Xwing => Self::Xwing,
            HandshakeProfileArg::Mlkem => Self::Mlkem,
            HandshakeProfileArg::Classic => Self::Classic,
        }
    }
}
#[derive(Debug, Clone, Copy, ValueEnum)]
pub(crate) enum HandshakeScopeArg {
    Local,
    Both,
}
impl HandshakeScopeArg {
    pub(crate) fn wire(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Both => "both",
        }
    }
}
#[derive(Debug, Args)]
pub(crate) struct CrossnetHandshakeSetArgs {
    #[arg(value_enum)]
    pub(crate) profile: HandshakeProfileArg,
    #[arg(
        long,
        value_enum,
        default_value = "local",
        requires_if("both", "handshake_target")
    )]
    pub(crate) scope: HandshakeScopeArg,
    #[arg(long, requires = "handshake_target")]
    pub(crate) reconnect: bool,
    #[command(flatten)]
    pub(crate) target: CrossnetHandshakeTargetArgs,
}
