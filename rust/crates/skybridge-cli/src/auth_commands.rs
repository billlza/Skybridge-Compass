use std::path::PathBuf;

use anyhow::Result;
use skybridge_agent::{
    clear_auth_session, ensure_device_identity, resolve_paths, store_auth_session,
};
use skybridge_core::{NebulaOAuthClient, derive_tenant_identifier};

use crate::LoginCommand;

pub(crate) async fn login(state_dir: Option<PathBuf>, args: LoginCommand) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let oauth = NebulaOAuthClient::from_env()?;
    let redirect_uri = args
        .redirect_uri
        .or_else(|| std::env::var("SKYBRIDGE_OAUTH_REDIRECT_URI").ok())
        .unwrap_or_else(|| "skybridge://auth/nebula".to_owned());
    let authorization_request = oauth.make_authorization_request(
        &redirect_uri,
        &["openid", "profile", "email", "offline_access"],
        &[],
    )?;

    if args.print_only {
        println!("{}", authorization_request.authorization_url);
        return Ok(());
    }

    let session = oauth
        .complete_authorization_interactively(
            &authorization_request,
            !args.no_open,
            args.callback_url,
            args.authorization_code,
        )
        .await?;
    store_auth_session(&paths, &session).await?;
    let identity = ensure_device_identity(&paths).await?;
    let tenant_id = derive_tenant_identifier(&session.access_token).unwrap_or_default();
    println!("Logged in as: {}", session.display_name);
    println!("User ID: {}", session.user_identifier);
    println!(
        "Tenant ID: {}",
        if tenant_id.is_empty() {
            "<unresolved>"
        } else {
            &tenant_id
        }
    );
    println!("Device ID: {}", identity.state.device.device_id);
    Ok(())
}

pub(crate) async fn logout(state_dir: Option<PathBuf>) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    clear_auth_session(&paths).await?;
    println!("Logged out");
    Ok(())
}
