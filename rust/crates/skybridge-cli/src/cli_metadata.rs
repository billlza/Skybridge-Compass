use anyhow::Result;
use serde_json::json;

pub(crate) fn version() -> Result<()> {
    let payload = json!({
        "product_name": "SkyBridge CLI",
        "binary_name": "skybridge",
        "cli_version": env!("CARGO_PKG_VERSION"),
        "workspace": "rust",
        "contracts_schema_version": 1u32,
        "implemented_phases": ["phase_4_auth", "phase_5_signaling_plane"],
    });
    println!("{}", serde_json::to_string_pretty(&payload)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_renders_json_payload() -> Result<()> {
        version()
    }
}
