use std::path::PathBuf;

use clap::{Parser, Subcommand};

mod android;
mod check;
mod common;
#[cfg(target_os = "macos")]
mod crossnet;
mod doctor;
mod operator;
mod smoke;
mod test;

pub(crate) use android::*;
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
#[command(about = "SkyBridge CLI")]
#[command(
    long_about = "SkyBridge CLI operator surface. The `skybridge` binary name remains stable for scripts; Mac app-bound crossnet commands use crossnet-control/1, while native/headless commands use the selected state directory."
)]
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
    Android(AndroidCommand),
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

impl Cli {
    pub(crate) fn json_output_requested(&self) -> bool {
        match &self.command {
            Commands::Agent(_) | Commands::Login(_) | Commands::Logout => false,
            Commands::Device(device) => match &device.command {
                DeviceSubcommand::Status(output) => output.json,
                DeviceSubcommand::Discover(args) => args.output.json,
                DeviceSubcommand::Enroll(args) => args.output.json,
                DeviceSubcommand::Approve(args) => args.output.json,
            },
            Commands::Code(code) => match &code.command {
                CodeSubcommand::Create(args) => args.output.json,
                CodeSubcommand::Current(args) => args.output.json,
            },
            Commands::Connect(args) => args.json,
            #[cfg(target_os = "macos")]
            Commands::Crossnet(crossnet) => match &crossnet.command {
                CrossnetSubcommand::Preflight(output) => output.json,
                CrossnetSubcommand::Host(args) => args.output.json,
                CrossnetSubcommand::Connect(args) => args.output.json,
                CrossnetSubcommand::Disconnect(output) => output.json,
                CrossnetSubcommand::Status(args) => args.output.json,
                CrossnetSubcommand::Settings(args) => match &args.command {
                    None => args.output.json,
                    Some(CrossnetSettingsSubcommand::Set(set_args)) => {
                        args.output.json || set_args.output.json
                    }
                },
            },
            Commands::Android(android) => match &android.command {
                AndroidSubcommand::Devices(args) => args.output.json,
                AndroidSubcommand::Status(args)
                | AndroidSubcommand::Doctor(args)
                | AndroidSubcommand::Lan(args)
                | AndroidSubcommand::Code(args) => args.output.json,
            },
            Commands::Session(session) => match &session.command {
                SessionSubcommand::Ls(output) => output.json,
                SessionSubcommand::Inspect(args) => args.output.json,
            },
            Commands::Disconnect(_) => false,
            Commands::RemoteDesktop(remote_desktop) => match &remote_desktop.command {
                RemoteDesktopSubcommand::Contract(output) => output.json,
                RemoteDesktopSubcommand::Status(args) => args.output.json,
                RemoteDesktopSubcommand::Resolutions(args) => args.output.json,
                RemoteDesktopSubcommand::Start(args) => args.output.json,
                RemoteDesktopSubcommand::Stop(args) => args.output.json,
                RemoteDesktopSubcommand::SetResolution(args) => args.output.json,
                RemoteDesktopSubcommand::SetFps(args) => args.output.json,
            },
            Commands::File(file) => match &file.command {
                FileSubcommand::Send(args) => args.output.json,
                FileSubcommand::Receive(args) => args.output.json,
                FileSubcommand::History(output) => output.json,
            },
            Commands::Check(check) => match &check.command {
                CheckSubcommand::Memory(args) => args.output.json,
                CheckSubcommand::Performance(args) => args.output.json,
                CheckSubcommand::Connectivity(args) => args.output.json,
                CheckSubcommand::RemoteControlNotice(args) => args.output.json,
                CheckSubcommand::Coverage(args) => args.output.json,
            },
            Commands::Test(test) => match &test.command {
                TestSubcommand::Swift(args) => args.output.json,
            },
            Commands::Diagnose(diagnose) => match &diagnose.command {
                DiagnoseSubcommand::WebRtcMedia(args) => args.output.json,
            },
            Commands::Doctor(doctor) => match &doctor.command {
                Some(DoctorSubcommand::Signaling(args)) => doctor.output.json || args.output.json,
                Some(DoctorSubcommand::MediaLease(args)) => doctor.output.json || args.output.json,
                Some(DoctorSubcommand::WebRtcMedia(args)) => doctor.output.json || args.output.json,
                None => doctor.output.json,
            },
            Commands::Smoke(smoke) => smoke.json_output_requested(),
            Commands::Capabilities(output) | Commands::Metrics(output) => output.json,
            Commands::Logs(_) | Commands::Internal(_) | Commands::Version => false,
        }
    }
}

impl SmokeCommand {
    fn json_output_requested(&self) -> bool {
        match &self.command {
            SmokeSubcommand::WebRtc(command) => match &command.command {
                WebRtcSmokeSubcommand::Gate(args) => args.output.json,
            },
            SmokeSubcommand::LocalWebrtc(args)
            | SmokeSubcommand::LocalWebrtcSecurityNotice(args)
            | SmokeSubcommand::LocalMacosSecurityNoticePanel(args)
            | SmokeSubcommand::RealDevice(args)
            | SmokeSubcommand::RealDeviceP2p(args)
            | SmokeSubcommand::RealDeviceP2pSecurityNotice(args)
            | SmokeSubcommand::RealDeviceFileTransfer(args) => args.output.json,
            SmokeSubcommand::LocalP2p(args) => args.output.json,
            SmokeSubcommand::Suite(args) => args.common.output.json,
            SmokeSubcommand::All(args) => args.common.output.json,
            SmokeSubcommand::Faults(args) | SmokeSubcommand::FaultDetection(args) => {
                args.output.json
            }
        }
    }
}
