use anyhow::Result;

use crate::smoke_suite::{smoke_faults, smoke_local_p2p, smoke_suite};
use crate::webrtc_smoke_gate::smoke_webrtc_gate;
use crate::{
    SmokeCommand, SmokeSubcommand, SmokeSuiteArgs, SmokeSuiteCommonArgs, SmokeSuiteProfile,
    WebRtcSmokeSubcommand,
};

pub(super) async fn dispatch_smoke_command(command: SmokeCommand) -> Result<()> {
    match command.command {
        SmokeSubcommand::WebRtc(webrtc) => match webrtc.command {
            WebRtcSmokeSubcommand::Gate(args) => smoke_webrtc_gate(args).await,
        },
        SmokeSubcommand::LocalWebrtc(common) => {
            run_suite_profile(SmokeSuiteProfile::LocalWebrtc, common).await
        }
        SmokeSubcommand::LocalP2p(args) => smoke_local_p2p(args).await,
        SmokeSubcommand::RealDevice(common) => {
            run_suite_profile(SmokeSuiteProfile::RealDevice, common).await
        }
        SmokeSubcommand::RealDeviceP2p(common) => {
            run_suite_profile(SmokeSuiteProfile::RealDeviceP2p, common).await
        }
        SmokeSubcommand::RealDeviceFileTransfer(common) => {
            run_suite_profile(SmokeSuiteProfile::RealDeviceFileTransfer, common).await
        }
        SmokeSubcommand::Suite(args) => smoke_suite(args).await,
        SmokeSubcommand::All(args) => run_suite_profile(SmokeSuiteProfile::All, args.common).await,
        SmokeSubcommand::Faults(args) => smoke_faults(args).await,
        SmokeSubcommand::FaultDetection(args) => smoke_faults(args).await,
    }
}

async fn run_suite_profile(profile: SmokeSuiteProfile, common: SmokeSuiteCommonArgs) -> Result<()> {
    smoke_suite(SmokeSuiteArgs { profile, common }).await
}
