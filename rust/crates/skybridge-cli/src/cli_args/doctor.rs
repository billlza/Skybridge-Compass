use std::path::PathBuf;

use clap::{Args, Subcommand};

use super::OutputOptions;

#[derive(Debug, Args)]
pub(crate) struct DoctorCommand {
    #[command(subcommand)]
    pub(crate) command: Option<DoctorSubcommand>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Subcommand)]
pub(crate) enum DoctorSubcommand {
    Signaling(SignalingDoctorArgs),
    MediaLease(MediaLeaseDoctorArgs),
    #[command(name = "webrtc-media")]
    WebRtcMedia(WebRtcMediaDoctorArgs),
}

#[derive(Debug, Args)]
pub(crate) struct SignalingDoctorArgs {
    #[arg(long)]
    pub(crate) base_url: Option<String>,
    /// Permit plaintext HTTP only when `--base-url` resolves to strict loopback.
    #[arg(long)]
    pub(crate) allow_insecure_loopback: bool,
    #[arg(long)]
    pub(crate) expected_backend: Option<String>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct MediaLeaseDoctorArgs {
    #[arg(long)]
    pub(crate) base_url: Option<String>,
    /// Permit plaintext HTTP only when `--base-url` resolves to strict loopback.
    #[arg(long)]
    pub(crate) allow_insecure_loopback: bool,
    #[arg(long)]
    pub(crate) session_id: Option<String>,
    #[arg(long, env = "SKYBRIDGE_MEDIA_ADMISSION_TOKEN")]
    pub(crate) media_admission_token: Option<String>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct WebRtcMediaDoctorArgs {
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
    #[arg(long, default_value_t = 20.0)]
    pub(crate) min_fps: f64,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    pub(crate) require_audio: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct DiagnoseCommand {
    #[command(subcommand)]
    pub(crate) command: DiagnoseSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum DiagnoseSubcommand {
    #[command(name = "webrtc-media")]
    WebRtcMedia(WebRtcMediaDiagnoseArgs),
}

#[derive(Debug, Args)]
pub(crate) struct WebRtcMediaDiagnoseArgs {
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
    #[arg(long, default_value_t = 20.0)]
    pub(crate) min_fps: f64,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    pub(crate) require_audio: bool,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}
