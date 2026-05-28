use std::path::PathBuf;

use clap::{Args, Subcommand, ValueEnum};
use serde::Serialize;

use super::OutputOptions;

#[derive(Debug, Args)]
pub(crate) struct SmokeCommand {
    #[command(subcommand)]
    pub(crate) command: SmokeSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum SmokeSubcommand {
    #[command(name = "webrtc")]
    WebRtc(WebRtcSmokeCommand),
    #[command(name = "local-webrtc")]
    LocalWebrtc(SmokeSuiteCommonArgs),
    #[command(name = "local-webrtc-security-notice")]
    LocalWebrtcSecurityNotice(SmokeSuiteCommonArgs),
    #[command(name = "local-macos-security-notice-panel")]
    LocalMacosSecurityNoticePanel(SmokeSuiteCommonArgs),
    #[command(name = "local-p2p")]
    LocalP2p(SmokeLocalP2pArgs),
    #[command(name = "real-device")]
    RealDevice(SmokeSuiteCommonArgs),
    #[command(name = "real-device-p2p")]
    RealDeviceP2p(SmokeSuiteCommonArgs),
    #[command(name = "real-device-p2p-security-notice")]
    RealDeviceP2pSecurityNotice(SmokeSuiteCommonArgs),
    #[command(name = "real-device-file-transfer")]
    RealDeviceFileTransfer(SmokeSuiteCommonArgs),
    Suite(SmokeSuiteArgs),
    All(SmokeAllArgs),
    Faults(SmokeFaultsArgs),
    #[command(name = "fault-detection")]
    FaultDetection(SmokeFaultsArgs),
}

#[derive(Debug, Args)]
pub(crate) struct WebRtcSmokeCommand {
    #[command(subcommand)]
    pub(crate) command: WebRtcSmokeSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum WebRtcSmokeSubcommand {
    Gate(WebRtcSmokeGateArgs),
}

#[derive(Debug, Args)]
pub(crate) struct SmokeSuiteArgs {
    #[arg(long, value_enum, default_value = "quick")]
    pub(crate) profile: SmokeSuiteProfile,
    #[command(flatten)]
    pub(crate) common: SmokeSuiteCommonArgs,
}

#[derive(Debug, Args)]
pub(crate) struct SmokeAllArgs {
    #[command(flatten)]
    pub(crate) common: SmokeSuiteCommonArgs,
}

#[derive(Debug, Args)]
pub(crate) struct SmokeSuiteCommonArgs {
    #[arg(long)]
    pub(crate) dry_run: bool,
    #[arg(long)]
    pub(crate) skip_real_device: bool,
    #[arg(long, env = "SKYBRIDGE_REAL_DEVICE_ID")]
    pub(crate) real_device_id: Option<String>,
    #[arg(long, env = "SKYBRIDGE_SMOKE_AUTH_SESSION_FILE")]
    pub(crate) auth_session_file: Option<PathBuf>,
    #[arg(long, default_value_t = 30.0)]
    pub(crate) min_fps: f64,
    #[arg(long, env = "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS")]
    pub(crate) timeout_seconds: Option<u64>,
    #[arg(long, env = "SKYBRIDGE_SMOKE_SOAK_SECONDS", default_value_t = 0)]
    pub(crate) soak_seconds: u64,
    #[arg(long, env = "SKYBRIDGE_SMOKE_VIDEO_WIDTH", default_value_t = 2056)]
    pub(crate) video_width: u32,
    #[arg(long, env = "SKYBRIDGE_SMOKE_VIDEO_HEIGHT", default_value_t = 1329)]
    pub(crate) video_height: u32,
    #[arg(
        long = "video-size",
        env = "SKYBRIDGE_SMOKE_VIDEO_SIZES",
        value_delimiter = ',',
        value_name = "WIDTHxHEIGHT"
    )]
    pub(crate) video_sizes: Vec<String>,
    #[arg(
        long,
        env = "SKYBRIDGE_SMOKE_MAINSTREAM_RESOLUTIONS",
        default_value_t = false
    )]
    pub(crate) mainstream_resolutions: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct SmokeFaultsArgs {
    #[arg(long)]
    pub(crate) dry_run: bool,
    #[arg(long)]
    pub(crate) iterations: Option<u32>,
    #[arg(long)]
    pub(crate) timeout_ms: Option<u32>,
    #[arg(long)]
    pub(crate) delay_ms: Option<u32>,
    #[arg(long)]
    pub(crate) progress_interval: Option<u32>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct SmokeLocalP2pArgs {
    #[arg(long)]
    pub(crate) dry_run: bool,
    #[arg(long, value_enum, default_value = "bootstrap-rekey")]
    pub(crate) scenario: LocalP2pSmokeScenario,
    #[arg(long, env = "SKYBRIDGE_SMOKE_ROUNDS")]
    pub(crate) rounds: Option<u32>,
    #[arg(long, env = "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS")]
    pub(crate) timeout_seconds: Option<u64>,
    #[arg(long, env = "SKYBRIDGE_SMOKE_IOS_DEVICE_ID")]
    pub(crate) ios_device_id: Option<String>,
    #[arg(long, env = "SKYBRIDGE_SMOKE_MAC_TARGET_NAME")]
    pub(crate) target_name: Option<String>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum LocalP2pSmokeScenario {
    #[default]
    BootstrapRekey,
    XwingOnly,
    CompatPurePqc,
}

impl LocalP2pSmokeScenario {
    pub(crate) fn as_env_value(self) -> &'static str {
        match self {
            Self::BootstrapRekey => "bootstrap-rekey",
            Self::XwingOnly => "xwing-only",
            Self::CompatPurePqc => "compat-pure-pqc",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum SmokeSuiteProfile {
    Quick,
    Full,
    ScriptTests,
    IosConfig,
    LocalWebrtc,
    LocalWebrtcSecurityNotice,
    LocalMacosSecurityNoticePanel,
    LocalP2p,
    RealDeviceP2p,
    RealDeviceP2pSecurityNotice,
    FaultInjection,
    Benchmarks,
    Release,
    RealDevice,
    RealDeviceFileTransfer,
    All,
}

#[derive(Debug, Args)]
pub(crate) struct WebRtcSmokeGateArgs {
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
    #[arg(long, default_value_t = 30.0)]
    pub(crate) min_fps: f64,
    #[arg(long, default_value_t = 0)]
    pub(crate) min_width: u32,
    #[arg(long, default_value_t = 0)]
    pub(crate) min_height: u32,
    #[arg(long)]
    pub(crate) exact_video_size: bool,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    pub(crate) require_audio: bool,
    #[arg(long, default_value_t = 240)]
    pub(crate) timeout_seconds: u64,
    #[arg(long, default_value_t = 0)]
    pub(crate) min_pass_seconds: u64,
    #[arg(long, default_value_t = 2)]
    pub(crate) poll_interval_seconds: u64,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}
