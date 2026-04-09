use std::io;
use std::path::PathBuf;

pub fn autostart_desktop_path() -> Option<PathBuf> {
    let base = directories::BaseDirs::new()?;
    Some(
        base.config_dir()
            .join("autostart")
            .join("skybridge-compass.desktop"),
    )
}

pub fn desktop_entry(exec: &str) -> String {
    // Keep this file minimal and desktop-environment friendly.
    //
    // NOTE: Prefer a stable command name over an absolute dev path (which may contain spaces).
    format!(
        "[Desktop Entry]\n\
Type=Application\n\
Version=1.0\n\
Name=SkyBridge Compass\n\
Comment=Next-Generation Platform Connectivity\n\
Exec={exec}\n\
Terminal=false\n\
X-GNOME-Autostart-enabled=true\n",
    )
}

pub fn set_autostart_enabled(enabled: bool) -> Result<(), io::Error> {
    let Some(path) = autostart_desktop_path() else {
        return Ok(());
    };
    if enabled {
        let Some(parent) = path.parent() else {
            return Ok(());
        };
        std::fs::create_dir_all(parent)?;
        std::fs::write(&path, desktop_entry("skybridge-compass"))?;
        return Ok(());
    }

    match std::fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktop_entry_contains_exec() {
        let entry = desktop_entry("skybridge-compass");
        assert!(entry.contains("Exec=skybridge-compass\n"));
        assert!(entry.contains("Type=Application\n"));
        assert!(entry.contains("X-GNOME-Autostart-enabled=true\n"));
    }
}
