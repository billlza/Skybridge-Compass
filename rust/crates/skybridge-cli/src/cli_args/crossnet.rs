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
    Host(CrossnetHostArgs),
    /// Connect to a hosted cross-network code.
    Connect(CrossnetConnectArgs),
    /// Disconnect the current cross-network session.
    Disconnect(OutputOptions),
    /// Show (or watch) cross-network control status.
    Status(CrossnetStatusArgs),
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum CrossnetLeaseMode {
    Short,
    Long,
}

#[derive(Debug, Args)]
pub(crate) struct CrossnetHostArgs {
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
