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
    /// Show the running Mac app's read-only settings projection.
    Settings(OutputOptions),
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
