use std::path::{Path, PathBuf};

use anyhow::{Result, bail};

pub(crate) fn resolve_repo_root() -> Result<PathBuf> {
    let mut current = std::env::current_dir()?;
    loop {
        if current.join("Scripts").is_dir()
            && current.join("rust").join("Cargo.toml").is_file()
            && current.join("Package.swift").is_file()
        {
            return Ok(current);
        }

        if !current.pop() {
            break;
        }
    }

    bail!("Could not locate SkyBridge repository root from current directory")
}

pub(crate) fn swift_test_cache_env(root: &Path) -> Vec<(String, String)> {
    let cache_dir = root.join(".swiftpm-cache").display().to_string();
    let module_cache_dir = root.join(".swiftpm-module-cache").display().to_string();
    vec![
        ("SWIFTPM_CACHE_PATH".to_owned(), cache_dir),
        (
            "CLANG_MODULE_CACHE_PATH".to_owned(),
            module_cache_dir.clone(),
        ),
        ("SWIFT_MODULE_CACHE_PATH".to_owned(), module_cache_dir),
    ]
}
