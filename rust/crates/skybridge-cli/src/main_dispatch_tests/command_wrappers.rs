use anyhow::Result;

use crate::cli_test_support::make_test_dir;
use crate::{
    Cli, CodeCreateArgs, Commands, ConnectCommand, DeviceApproveArgs, DeviceCommand,
    DeviceEnrollArgs, DeviceSubcommand, FileCommand, FileSendArgs, FileSubcommand, OutputOptions,
};

#[tokio::test]
async fn command_wrappers_cover_auth_and_media_entrypoints() -> Result<()> {
    let state_dir = make_test_dir("main-wrapper-entry")?;

    assert!(
        crate::connection_code::code_create(
            Some(state_dir.clone()),
            CodeCreateArgs {
                device_name: Some("desk".to_owned()),
                ttl_seconds: 60,
                output: OutputOptions { json: true },
            },
        )
        .await
        .is_err()
    );
    assert!(
        crate::connection_code::connect_code(
            Some(state_dir.clone()),
            ConnectCommand {
                code: "ABCDEF".to_owned(),
                hold_seconds: 0,
                json: true,
            },
        )
        .await
        .is_err()
    );

    let enroll = DeviceCommand {
        command: DeviceSubcommand::Enroll(DeviceEnrollArgs {
            invite_token: Some("invite".to_owned()),
            device_name: Some("desk".to_owned()),
            output: OutputOptions { json: true },
        }),
    };
    assert!(
        crate::dispatch(Cli {
            state_dir: Some(state_dir.clone()),
            command: Commands::Device(enroll),
        })
        .await
        .is_err()
    );

    let approve = DeviceCommand {
        command: DeviceSubcommand::Approve(DeviceApproveArgs {
            pending_device_id: "pending".to_owned(),
            pending_algorithm: "Ed25519".to_owned(),
            pending_fingerprint: "fingerprint".to_owned(),
            device_name: Some("desk".to_owned()),
            output: OutputOptions { json: true },
        }),
    };
    assert!(
        crate::dispatch(Cli {
            state_dir: Some(state_dir.clone()),
            command: Commands::Device(approve),
        })
        .await
        .is_err()
    );

    let file_send = FileCommand {
        command: FileSubcommand::Send(FileSendArgs {
            path: "/tmp/payload.txt".into(),
            to: "peer".to_owned(),
            session_id: None,
            output: OutputOptions { json: true },
        }),
    };
    assert!(
        crate::dispatch(Cli {
            state_dir: Some(state_dir),
            command: Commands::File(file_send),
        })
        .await
        .is_err()
    );

    Ok(())
}
