use clap::{Args, Subcommand, ValueEnum};

use super::OutputOptions;

#[derive(Debug, Args)]
pub(crate) struct CrossnetCommand {
    #[command(subcommand)]
    pub(crate) command: CrossnetSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum CrossnetSubcommand {
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
