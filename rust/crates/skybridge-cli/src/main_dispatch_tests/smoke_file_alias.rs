use anyhow::Result;

use crate::{
    Cli, Commands, DisconnectCommand, FileCommand, FileSubcommand, OutputOptions,
    SmokeSuiteCommonArgs, SmokeSuiteProfile,
};

#[tokio::test]
async fn smoke_and_file_alias_dispatch_paths_remain_wired() -> Result<()> {
    for profile in [
        SmokeSuiteProfile::RealDevice,
        SmokeSuiteProfile::RealDeviceP2p,
        SmokeSuiteProfile::RealDeviceFileTransfer,
        SmokeSuiteProfile::All,
    ] {
        let result = crate::smoke_suite::smoke_suite(crate::SmokeSuiteArgs {
            profile,
            common: smoke_common(),
        })
        .await;
        if matches!(
            profile,
            SmokeSuiteProfile::RealDevice
                | SmokeSuiteProfile::RealDeviceP2p
                | SmokeSuiteProfile::RealDeviceFileTransfer
        ) {
            assert!(result.is_err());
        } else {
            result?;
        }
    }

    assert!(
        crate::dispatch(Cli {
            state_dir: None,
            command: Commands::File(FileCommand {
                command: FileSubcommand::History(OutputOptions { json: true }),
            }),
        })
        .await
        .is_err()
    );
    assert!(
        crate::dispatch(Cli {
            state_dir: None,
            command: Commands::Disconnect(DisconnectCommand {
                session_id: "missing".to_owned(),
            }),
        })
        .await
        .is_err()
    );

    Ok(())
}

fn smoke_common() -> SmokeSuiteCommonArgs {
    SmokeSuiteCommonArgs {
        dry_run: true,
        skip_real_device: true,
        real_device_id: None,
        auth_session_file: None,
        min_fps: 30.0,
        timeout_seconds: Some(60),
        soak_seconds: 0,
        video_width: 2056,
        video_height: 1329,
        video_sizes: Vec::new(),
        mainstream_resolutions: false,
        output: OutputOptions { json: true },
    }
}
