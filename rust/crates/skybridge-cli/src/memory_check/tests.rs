use std::path::PathBuf;

use anyhow::Result;

use super::super::OutputOptions;
use super::*;

mod args;
mod execution;

fn doctor_check<'a>(report: &'a DoctorProbeReport, name: &str) -> &'a DoctorCheck {
    report
        .checks
        .iter()
        .find(|check| check.name == name)
        .unwrap_or_else(|| panic!("{name} check missing"))
}

#[cfg(unix)]
fn make_test_dir(name: &str) -> Result<PathBuf> {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "skybridge-cli-{name}-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir_all(&path)?;
    Ok(path)
}
