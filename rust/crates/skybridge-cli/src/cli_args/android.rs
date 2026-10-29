use std::path::PathBuf;

use clap::{Args, Subcommand};

use super::OutputOptions;

#[derive(Debug, Args)]
pub(crate) struct AndroidCommand {
    #[command(subcommand)]
    pub(crate) command: AndroidSubcommand,
}

/// Desktop-side operator bridge for the Android app: every subcommand goes
/// through `adb` to the debug build's localhost-only `adb-bridge/1` NDJSON
/// diagnostic surface. Read-only in v1.
#[derive(Debug, Subcommand)]
pub(crate) enum AndroidSubcommand {
    /// List adb-visible Android devices.
    Devices(AndroidDevicesArgs),
    /// App/runtime status snapshot (version, sessions, discovery state).
    Status(AndroidBridgeArgs),
    /// Runtime self-check: native PQC provider, NSD advertising, signaling config.
    Doctor(AndroidBridgeArgs),
    /// Classic LAN inbound file-receive surface state.
    Lan(AndroidBridgeArgs),
    /// Connection-code session state (redacted references only).
    Code(AndroidBridgeArgs),
}

#[derive(Debug, Args)]
pub(crate) struct AndroidDevicesArgs {
    /// Explicit adb executable (otherwise ANDROID_HOME/ANDROID_SDK_ROOT, then PATH).
    #[arg(long, value_name = "PATH")]
    pub(crate) adb: Option<PathBuf>,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}

#[derive(Debug, Args)]
pub(crate) struct AndroidBridgeArgs {
    /// Device serial (`adb -s`); required when more than one device is attached.
    #[arg(long, value_name = "SERIAL")]
    pub(crate) serial: Option<String>,
    /// Explicit adb executable (otherwise ANDROID_HOME/ANDROID_SDK_ROOT, then PATH).
    #[arg(long, value_name = "PATH")]
    pub(crate) adb: Option<PathBuf>,
    /// Debug application id hosting the bridge.
    #[arg(long, value_name = "PACKAGE", default_value = crate::android_bridge::DEFAULT_DEBUG_PACKAGE)]
    pub(crate) package: String,
    #[command(flatten)]
    pub(crate) output: OutputOptions,
}
