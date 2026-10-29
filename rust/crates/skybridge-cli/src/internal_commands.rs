use anyhow::{Result, anyhow};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;

use crate::VerifyMldsaArgs;

pub(crate) fn verify_mldsa(args: VerifyMldsaArgs) -> Result<()> {
    let message = STANDARD
        .decode(args.message_base64.trim().as_bytes())
        .map_err(|error| anyhow!("invalid message_base64: {error}"))?;
    let signature = STANDARD
        .decode(args.signature_base64.trim().as_bytes())
        .map_err(|error| anyhow!("invalid signature_base64: {error}"))?;
    let public_key = STANDARD
        .decode(args.public_key_base64.trim().as_bytes())
        .map_err(|error| anyhow!("invalid public_key_base64: {error}"))?;
    skybridge_core::mldsa65_verify_detached(&message, &signature, &public_key)?;
    println!("ok");
    Ok(())
}
