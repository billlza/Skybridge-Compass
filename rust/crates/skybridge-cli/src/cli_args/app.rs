use clap::{Args, Subcommand};

use crate::app_control_client::AppearanceMode;

#[derive(Debug, Args)]
pub(crate) struct AppCommand {
    /// Select an existing Skybridge.WinClient.exe process.
    #[arg(long, global = true, value_parser = clap::value_parser!(u32).range(1..))]
    pub(crate) pid: Option<u32>,
    #[arg(long, global = true)]
    pub(crate) json: bool,
    #[command(subcommand)]
    pub(crate) command: AppSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum AppSubcommand {
    /// List app processes; discovery does not prove that their IPC is ready.
    Instances,
    /// Read the selected running app's state.
    Status,
    /// Read or change allowlisted settings in the running app.
    Settings(AppSettingsArgs),
    /// Control the app-owned remote desktop host listener.
    RemoteDesktop(AppRemoteDesktopArgs),
}

#[derive(Debug, Args)]
pub(crate) struct AppSettingsArgs {
    #[command(subcommand)]
    pub(crate) command: Option<AppSettingsSubcommand>,
}

#[derive(Debug, Subcommand)]
pub(crate) enum AppSettingsSubcommand {
    Set(AppSettingSetArgs),
}

#[derive(Debug, Args)]
pub(crate) struct AppSettingSetArgs {
    #[arg(value_parser = ["appearance.mode"])]
    pub(crate) id: String,
    #[arg(value_enum)]
    pub(crate) value: AppearanceMode,
}

#[derive(Debug, Args)]
pub(crate) struct AppRemoteDesktopArgs {
    #[command(subcommand)]
    pub(crate) command: AppRemoteDesktopSubcommand,
}

#[derive(Debug, Subcommand)]
pub(crate) enum AppRemoteDesktopSubcommand {
    Interfaces,
    /// Enable a host listener; this does not verify a connected peer or frames.
    Start {
        #[arg(long, value_parser = parse_interface_ref)]
        interface_ref: String,
    },
    /// Stop only the indicated host generation.
    Stop {
        #[arg(long)]
        generation: u64,
    },
}

fn parse_interface_ref(value: &str) -> Result<String, String> {
    if value.is_empty()
        || value.len() > 128
        || value.chars().any(char::is_whitespace)
        || value.chars().any(char::is_control)
    {
        return Err(
            "interface ref must be 1..128 bytes without whitespace or control characters".into(),
        );
    }
    Ok(value.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[derive(Parser)]
    struct TestCli {
        #[command(flatten)]
        app: AppCommand,
    }

    #[test]
    fn app_arguments_require_explicit_targets_and_allowlisted_values() {
        for args in [
            vec!["app", "--pid", "0", "status"],
            vec!["app", "settings", "set", "identity.key", "dark"],
            vec!["app", "settings", "set", "appearance.mode", "unknown"],
            vec!["app", "remote-desktop", "start"],
            vec!["app", "remote-desktop", "start", "--interface-ref", " "],
            vec!["app", "remote-desktop", "stop"],
            vec!["app", "remote-desktop", "stop", "--generation", "-1"],
        ] {
            assert!(TestCli::try_parse_from(args).is_err());
        }
        let parsed = TestCli::try_parse_from([
            "app",
            "settings",
            "set",
            "appearance.mode",
            "dark",
            "--pid",
            "42",
            "--json",
        ])
        .unwrap()
        .app;
        assert_eq!(parsed.pid, Some(42));
        assert!(parsed.json);
        let AppSubcommand::Settings(settings) = parsed.command else {
            panic!("settings command")
        };
        let Some(AppSettingsSubcommand::Set(setting)) = settings.command else {
            panic!("set command")
        };
        assert_eq!(setting.id, "appearance.mode");
        assert_eq!(setting.value, AppearanceMode::Dark);
    }
}
