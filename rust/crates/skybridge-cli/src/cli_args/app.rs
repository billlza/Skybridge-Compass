use std::path::PathBuf;

use clap::{Args, Subcommand};

use super::OutputOptions;

#[derive(Debug, Args)]
pub(crate) struct AppCommand {
    #[command(subcommand)]
    pub(crate) command: AppSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum AppSubcommand {
    /// Launch the SkyBridge GUI app.
    ///
    /// On Windows, `--interactive` binds the launch to the active interactive
    /// console session so a GUI surfaces on the logged-in user's desktop even
    /// when this CLI runs as a service/SYSTEM. Elsewhere it is a normal spawn.
    Launch(AppLaunchArgs),
    /// Stop a running SkyBridge app process by pid or process name.
    Stop(AppStopArgs),
    /// Report whether a SkyBridge app process is running.
    Status(AppStatusArgs),
}

#[derive(Debug, Args)]
pub(crate) struct AppLaunchArgs {
    /// Absolute path to the executable (or `.app` bundle on macOS).
    #[arg(long, value_name = "PATH")]
    pub(crate) exe: PathBuf,
    /// Working directory for the launched process.
    #[arg(long, value_name = "DIR")]
    pub(crate) cwd: Option<PathBuf>,
    /// Argument passed through to the launched process (repeatable).
    #[arg(long = "arg", value_name = "S")]
    pub(crate) args: Vec<String>,
    /// Windows: launch into the active interactive console session
    /// (requires SYSTEM/admin with SE_TCB). No-op on macOS/unix.
    #[arg(long)]
    pub(crate) interactive: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct AppStopArgs {
    /// Process id to terminate.
    #[arg(long, value_name = "N")]
    pub(crate) pid: Option<u32>,
    /// Process (executable) name to resolve and terminate.
    #[arg(long, value_name = "PROCESS_NAME")]
    pub(crate) name: Option<String>,
    /// Force-kill (SIGKILL on unix / TerminateProcess on Windows).
    #[arg(long)]
    pub(crate) force: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct AppStatusArgs {
    /// Process (executable) name to query.
    #[arg(long, value_name = "PROCESS_NAME")]
    pub(crate) name: Option<String>,
    /// Process id to query.
    #[arg(long, value_name = "N")]
    pub(crate) pid: Option<u32>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}
