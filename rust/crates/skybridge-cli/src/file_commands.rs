use std::path::Path;

use anyhow::{Result, bail};
use serde_json::json;

pub(crate) fn send_placeholder(path: &Path, to: &str) -> Result<()> {
    bail!(
        "Phase 6 pending: file send from `{}` to `{}` waits for the shared route contract.",
        path.display(),
        to
    )
}

pub(crate) fn receive_placeholder() -> Result<()> {
    bail!("Phase 6 pending: inbound file receive is not wired yet.")
}

pub(crate) fn history_placeholder(as_json: bool) -> Result<()> {
    json_or_text(
        as_json,
        json!({
            "history": [],
            "message": "Phase 6 pending: file transfer history is not wired yet."
        }),
        "Phase 6 pending: file transfer history is not wired yet.",
    )
}

fn json_or_text(as_json: bool, payload: serde_json::Value, text: &str) -> Result<()> {
    if as_json {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("{text}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_placeholders_cover_text_json_and_errors() -> Result<()> {
        history_placeholder(false)?;
        history_placeholder(true)?;
        assert!(send_placeholder(Path::new("/tmp/payload.txt"), "peer-device").is_err());
        assert!(receive_placeholder().is_err());
        Ok(())
    }
}
