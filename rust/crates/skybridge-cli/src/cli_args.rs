use std::path::PathBuf;

use clap::{Parser, Subcommand};

mod check;
mod common;
#[cfg(target_os = "macos")]
mod crossnet;
mod doctor;
mod operator;
mod smoke;
mod test;

pub(crate) use check::*;
pub(crate) use common::*;
#[cfg(target_os = "macos")]
pub(crate) use crossnet::*;
pub(crate) use doctor::*;
pub(crate) use operator::*;
pub(crate) use smoke::*;
pub(crate) use test::*;

#[derive(Debug, Parser)]
#[command(name = "skybridge")]
#[command(about = "SkyBridge CLI operator surface")]
pub(crate) struct Cli {
    #[arg(long, global = true)]
    pub(crate) state_dir: Option<PathBuf>,
    #[command(subcommand)]
    pub(crate) command: Commands,
}

#[derive(Debug, Subcommand)]
pub(crate) enum Commands {
    Agent(AgentCommand),
    Login(LoginCommand),
    Logout,
    Device(DeviceCommand),
    Code(CodeCommand),
    Connect(ConnectCommand),
    #[cfg(target_os = "macos")]
    Crossnet(CrossnetCommand),
    Session(SessionCommand),
    Disconnect(DisconnectCommand),
    RemoteDesktop(RemoteDesktopCommand),
    File(FileCommand),
    Check(CheckCommand),
    Test(TestCommand),
    Diagnose(DiagnoseCommand),
    Doctor(DoctorCommand),
    Smoke(SmokeCommand),
    Capabilities(OutputOptions),
    Logs(LogsCommand),
    Metrics(OutputOptions),
    #[command(hide = true)]
    Internal(InternalCommand),
    Version,
}
