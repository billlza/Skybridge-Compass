use std::path::PathBuf;

use clap::{Args, Subcommand, ValueEnum};

use crate::performance_budgets::P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS;

use super::OutputOptions;

#[derive(Debug, Args)]
pub(crate) struct CheckCommand {
    #[command(subcommand)]
    pub(crate) command: CheckSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum CheckSubcommand {
    Memory(MemoryCheckArgs),
    Performance(PerformanceCheckArgs),
    Connectivity(ConnectivityCheckArgs),
    RemoteControlNotice(RemoteControlNoticeCheckArgs),
    Coverage(CoverageCheckArgs),
}

#[derive(Debug, Args)]
pub(crate) struct MemoryCheckArgs {
    #[arg(long, conflicts_with = "executable")]
    pub(crate) pid: Option<u32>,
    #[arg(long, value_name = "PATH", conflicts_with = "pid")]
    pub(crate) executable: Option<PathBuf>,
    #[arg(
        long = "arg",
        value_name = "ARG",
        requires = "executable",
        allow_hyphen_values = true
    )]
    pub(crate) executable_args: Vec<String>,
    #[arg(long, value_name = "PATH", default_value = "leaks")]
    pub(crate) leaks_tool: PathBuf,
    #[arg(long, default_value_t = 60)]
    pub(crate) timeout_seconds: u64,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    pub(crate) quiet: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct PerformanceCheckArgs {
    #[arg(long, value_enum, default_value = "auto")]
    pub(crate) kind: PerformanceKindArg,
    #[arg(long)]
    pub(crate) session_id: Option<String>,
    #[arg(long)]
    pub(crate) latest: bool,
    #[arg(long)]
    pub(crate) artifact_dir: Option<PathBuf>,
    #[arg(long)]
    pub(crate) log_file: Option<PathBuf>,
    #[arg(long, default_value_t = 120)]
    pub(crate) since_seconds: u64,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum PerformanceKindArg {
    Auto,
    Webrtc,
    P2pRemote,
    FileTransfer,
}

#[derive(Debug, Args)]
pub(crate) struct ConnectivityCheckArgs {
    #[arg(long)]
    pub(crate) artifact_dir: PathBuf,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct RemoteControlNoticeCheckArgs {
    #[arg(long, value_name = "DIR", conflicts_with = "log_file")]
    pub(crate) artifact_dir: Option<PathBuf>,
    #[arg(long, value_name = "PATH", conflicts_with = "artifact_dir")]
    pub(crate) log_file: Option<PathBuf>,
    #[arg(long, value_enum)]
    pub(crate) transport: RemoteControlNoticeTransportArg,
    #[arg(long)]
    pub(crate) require_panel: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum RemoteControlNoticeTransportArg {
    P2p,
    Webrtc,
}

#[derive(Debug, Args)]
pub(crate) struct CoverageCheckArgs {
    #[arg(long, value_enum, default_value = "operator-check-surface")]
    pub(crate) kind: CoverageKindArg,
    #[arg(long, default_value_t = 88.0)]
    pub(crate) min_percent: f64,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum CoverageKindArg {
    OperatorCheckSurface,
}

impl CoverageKindArg {
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::OperatorCheckSurface => "operator-check-surface",
        }
    }

    pub(crate) fn description(self) -> &'static str {
        match self {
            Self::OperatorCheckSurface => {
                "CLI operator check-surface coverage; this is not Rust line or branch coverage"
            }
        }
    }
}
