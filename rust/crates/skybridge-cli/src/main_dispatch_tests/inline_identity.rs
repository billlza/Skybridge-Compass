use anyhow::Result;
use base64::Engine as _;

use crate::cli_test_support::make_test_dir;
use crate::{Cli, Commands, InternalCommand, InternalSubcommand, VerifyMldsaArgs};

#[tokio::test]
async fn inline_identity_and_internal_verify_paths_are_exercised() -> Result<()> {
    let paths = skybridge_agent::resolve_paths(Some(make_test_dir("main-inline-identity")?))?;
    let identity = skybridge_agent::ensure_device_identity(&paths).await?;
    let binding = skybridge_agent::signing_binding(&identity)?;
    let config =
        crate::auth_support::maybe_inline_pqc_responder_config(&paths, &identity, &binding).await?;
    assert!(config.is_none());

    let message = b"verify-me";
    let (public_key, secret_key) = skybridge_core::mldsa65_generate_keypair();
    let signature = skybridge_core::mldsa65_sign_detached(message, &secret_key)?;
    crate::internal_commands::verify_mldsa(VerifyMldsaArgs {
        message_base64: base64::engine::general_purpose::STANDARD.encode(message),
        signature_base64: base64::engine::general_purpose::STANDARD.encode(signature),
        public_key_base64: base64::engine::general_purpose::STANDARD.encode(public_key),
    })?;

    assert!(
        crate::dispatch(Cli {
            state_dir: None,
            command: Commands::Internal(InternalCommand {
                command: InternalSubcommand::VerifyMldsa(VerifyMldsaArgs {
                    message_base64: "not-base64".to_owned(),
                    signature_base64: "also-not-base64".to_owned(),
                    public_key_base64: "still-not-base64".to_owned(),
                }),
            }),
        })
        .await
        .is_err()
    );

    Ok(())
}
