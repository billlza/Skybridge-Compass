use std::path::Path;

use anyhow::{Context, Result};
use skybridge_core::StructuredEvent;
use tokio::fs;

use super::AgentPaths;

pub(super) async fn ensure_layout(paths: &AgentPaths) -> Result<()> {
    ensure_dir(&paths.root).await?;
    ensure_dir(&paths.identity_dir).await?;
    ensure_dir(&paths.runtime_dir).await?;
    ensure_dir(&paths.logs_dir).await?;
    Ok(())
}

async fn ensure_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)
        .await
        .with_context(|| format!("failed to create directory {}", path.display()))?;
    restrict_dir_permissions(path).await
}

pub(super) async fn write_json<T>(path: &Path, value: &T) -> Result<()>
where
    T: serde::Serialize,
{
    let body = serde_json::to_vec_pretty(value).context("failed to encode json")?;
    fs::write(path, body)
        .await
        .with_context(|| format!("failed to write {}", path.display()))?;
    restrict_file_permissions(path).await
}

pub(super) async fn append_event_line(path: &Path, event: StructuredEvent) -> Result<()> {
    let body = serde_json::to_vec(&event).context("failed to encode structured event")?;
    let mut line = body;
    line.push(b'\n');
    use tokio::io::AsyncWriteExt;

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .await
        .with_context(|| format!("failed to open {}", path.display()))?;
    file.write_all(&line)
        .await
        .with_context(|| format!("failed to append {}", path.display()))?;
    file.flush()
        .await
        .with_context(|| format!("failed to flush {}", path.display()))?;
    restrict_file_permissions(path).await
}

pub(super) async fn load_json<T>(path: &Path) -> Result<Option<T>>
where
    T: for<'de> serde::Deserialize<'de>,
{
    match fs::read_to_string(path).await {
        Ok(body) => {
            let decoded = serde_json::from_str(&body)
                .with_context(|| format!("failed to decode {}", path.display()))?;
            Ok(Some(decoded))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
    }
}

pub(crate) async fn restrict_dir_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let permissions = std::fs::Permissions::from_mode(0o700);
        fs::set_permissions(path, permissions)
            .await
            .with_context(|| format!("failed to set permissions on {}", path.display()))?;
    }

    Ok(())
}

pub(crate) async fn restrict_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let permissions = std::fs::Permissions::from_mode(0o600);
        fs::set_permissions(path, permissions)
            .await
            .with_context(|| format!("failed to set permissions on {}", path.display()))?;
    }

    Ok(())
}
