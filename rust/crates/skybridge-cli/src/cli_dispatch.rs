use std::time::Duration;

use anyhow::Result;
use skybridge_agent::run_agent;

mod smoke;

#[cfg(target_os = "macos")]
use crate::CrossnetSubcommand;
use crate::auth_commands::{login, logout};
use crate::connectivity_check::check_connectivity;
use crate::device_commands::{device_approve, device_enroll, device_status};
use crate::doctor_commands::{
    diagnose_webrtc_media, doctor_media_lease, doctor_signaling, doctor_webrtc_media,
};
use crate::operator_status::{doctor, metrics, tail_logs};
use crate::performance_commands::check_performance;
use crate::session_commands::{disconnect, session_inspect, session_ls};
use crate::{
    AgentSubcommand, CheckSubcommand, Cli, CodeSubcommand, Commands, DeviceSubcommand,
    DiagnoseSubcommand, DoctorSubcommand, FileSubcommand, InternalSubcommand, LogsSubcommand,
    RemoteDesktopSubcommand, SessionSubcommand,
};

pub(super) async fn dispatch(cli: Cli) -> Result<()> {
    match cli.command {
        Commands::Agent(agent) => match agent.command {
            AgentSubcommand::Run => {
                run_agent(skybridge_agent::AgentRuntimeOptions {
                    state_dir: cli.state_dir,
                    heartbeat_interval: Duration::from_secs(2),
                    ..skybridge_agent::AgentRuntimeOptions::default()
                })
                .await
            }
        },
        Commands::Login(args) => login(cli.state_dir, args).await,
        Commands::Logout => logout(cli.state_dir).await,
        Commands::Device(device) => match device.command {
            DeviceSubcommand::Status(output) => device_status(cli.state_dir, output.json).await,
            DeviceSubcommand::Discover(args) => {
                crate::device_commands::device_discover(cli.state_dir, args).await
            }
            DeviceSubcommand::Enroll(args) => device_enroll(cli.state_dir, args).await,
            DeviceSubcommand::Approve(args) => device_approve(cli.state_dir, args).await,
        },
        Commands::Code(code) => match code.command {
            CodeSubcommand::Create(args) => {
                crate::connection_code::code_create(cli.state_dir, args).await
            }
            CodeSubcommand::Current(args) => {
                crate::connection_code_snapshot::code_current(args).await
            }
        },
        Commands::Connect(args) => crate::connection_code::connect_code(cli.state_dir, args).await,
        #[cfg(target_os = "macos")]
        Commands::Crossnet(crossnet) => match crossnet.command {
            CrossnetSubcommand::Preflight(output) => {
                crate::crossnet_commands::preflight(output.json).await
            }
            CrossnetSubcommand::Host(args) => crate::crossnet_commands::host(args).await,
            CrossnetSubcommand::Connect(args) => crate::crossnet_commands::connect(args).await,
            CrossnetSubcommand::Disconnect(output) => {
                crate::crossnet_commands::disconnect(output.json).await
            }
            CrossnetSubcommand::Status(args) => crate::crossnet_commands::status(args).await,
            CrossnetSubcommand::Settings(args) => {
                let outer_json = args.output.json;
                match args.command {
                    None => crate::crossnet_commands::settings(outer_json).await,
                    Some(crate::CrossnetSettingsSubcommand::Set(mut set_args)) => {
                        set_args.output.json |= outer_json;
                        crate::crossnet_commands::settings_set(set_args).await
                    }
                }
            }
        },
        Commands::Session(session) => match session.command {
            SessionSubcommand::Ls(output) => session_ls(cli.state_dir, output.json).await,
            SessionSubcommand::Inspect(args) => session_inspect(cli.state_dir, args).await,
        },
        Commands::Disconnect(args) => disconnect(cli.state_dir, &args.session_id).await,
        Commands::RemoteDesktop(remote_desktop) => match remote_desktop.command {
            RemoteDesktopSubcommand::Contract(output) => {
                crate::remote_desktop_commands::contract(output.json)
            }
            RemoteDesktopSubcommand::Status(args) => {
                crate::remote_desktop_commands::status(cli.state_dir, args).await
            }
            RemoteDesktopSubcommand::Resolutions(output) => {
                crate::remote_desktop_commands::resolutions(cli.state_dir, output).await
            }
            RemoteDesktopSubcommand::Start(args) => {
                crate::remote_desktop_commands::start(cli.state_dir, args).await
            }
            RemoteDesktopSubcommand::Stop(args) => {
                crate::remote_desktop_commands::stop(cli.state_dir, args).await
            }
            RemoteDesktopSubcommand::SetResolution(args) => {
                crate::remote_desktop_commands::set_resolution(cli.state_dir, args).await
            }
            RemoteDesktopSubcommand::SetFps(args) => {
                crate::remote_desktop_commands::set_fps(cli.state_dir, args).await
            }
        },
        Commands::File(file) => match file.command {
            FileSubcommand::Send(args) => crate::file_commands::send(cli.state_dir, args).await,
            FileSubcommand::Receive(args) => {
                crate::file_commands::receive(cli.state_dir, args).await
            }
            FileSubcommand::History(output) => {
                crate::file_commands::history(cli.state_dir, output.json).await
            }
        },
        Commands::Check(check) => match check.command {
            CheckSubcommand::Memory(args) => crate::memory_check::check_memory(args).await,
            CheckSubcommand::Performance(args) => check_performance(args).await,
            CheckSubcommand::Connectivity(args) => check_connectivity(args).await,
            CheckSubcommand::RemoteControlNotice(args) => {
                crate::remote_control_notice_check::check_remote_control_notice(args).await
            }
            CheckSubcommand::Coverage(args) => crate::check_coverage::check_coverage(args).await,
        },
        Commands::Test(command) => crate::test_commands::run_test_command(command).await,
        Commands::Diagnose(args) => match args.command {
            DiagnoseSubcommand::WebRtcMedia(webrtc_media) => {
                diagnose_webrtc_media(webrtc_media).await
            }
        },
        Commands::Doctor(args) => {
            let outer_json = args.output.json;
            match args.command {
                Some(DoctorSubcommand::Signaling(mut signaling)) => {
                    signaling.output.json |= outer_json;
                    doctor_signaling(signaling).await
                }
                Some(DoctorSubcommand::MediaLease(mut media_lease)) => {
                    media_lease.output.json |= outer_json;
                    doctor_media_lease(media_lease).await
                }
                Some(DoctorSubcommand::WebRtcMedia(mut webrtc_media)) => {
                    webrtc_media.output.json |= outer_json;
                    doctor_webrtc_media(webrtc_media).await
                }
                None => doctor(cli.state_dir, outer_json).await,
            }
        }
        Commands::Smoke(smoke) => smoke::dispatch_smoke_command(smoke).await,
        Commands::Capabilities(output) => {
            crate::operator_capabilities::print_operator_capabilities(output.json)
        }
        Commands::Logs(logs) => match logs.command {
            LogsSubcommand::Tail(args) => tail_logs(cli.state_dir, args.lines).await,
        },
        Commands::Metrics(output) => metrics(cli.state_dir, output.json).await,
        Commands::Internal(internal) => match internal.command {
            InternalSubcommand::VerifyMldsa(args) => crate::internal_commands::verify_mldsa(args),
        },
        Commands::Version => crate::cli_metadata::version(),
    }
}
