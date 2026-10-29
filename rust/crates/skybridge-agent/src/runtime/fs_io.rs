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
    ensure_dir(&paths.received_dir).await?;
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
    let file_name = path
        .file_name()
        .ok_or_else(|| anyhow::anyhow!("json path is missing its filename"))?
        .to_string_lossy();
    let temp_path = path.with_file_name(format!(".{file_name}.tmp-{}", uuid::Uuid::now_v7()));
    let publish_result: Result<()> = async {
        use tokio::io::AsyncWriteExt;

        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            options.mode(0o600);
        }
        let mut file = options
            .open(&temp_path)
            .await
            .with_context(|| format!("failed to create {}", temp_path.display()))?;
        file.write_all(&body)
            .await
            .with_context(|| format!("failed to write {}", temp_path.display()))?;
        file.flush()
            .await
            .with_context(|| format!("failed to flush {}", temp_path.display()))?;
        file.sync_all()
            .await
            .with_context(|| format!("failed to sync {}", temp_path.display()))?;
        drop(file);
        restrict_file_permissions(&temp_path).await?;
        #[cfg(windows)]
        if path.exists() {
            fs::remove_file(path)
                .await
                .with_context(|| format!("failed to replace {}", path.display()))?;
        }
        fs::rename(&temp_path, path)
            .await
            .with_context(|| format!("failed to publish {}", path.display()))?;
        restrict_file_permissions(path).await
    }
    .await;
    if let Err(error) = publish_result {
        match fs::remove_file(&temp_path).await {
            Ok(()) => Err(error),
            Err(cleanup_error) if cleanup_error.kind() == std::io::ErrorKind::NotFound => {
                Err(error)
            }
            Err(cleanup_error) => Err(error.context(format!(
                "failed to clean temporary json file {}: {cleanup_error}",
                temp_path.display()
            ))),
        }
    } else {
        Ok(())
    }
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
    match fs::symlink_metadata(path).await {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            anyhow::bail!("private JSON path {} is not a regular file", path.display());
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to inspect private JSON {}", path.display()));
        }
    }
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
    let metadata = fs::symlink_metadata(path)
        .await
        .with_context(|| format!("failed to inspect directory {}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        anyhow::bail!(
            "private state directory {} is not a regular directory",
            path.display()
        );
    }

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
    let metadata = fs::symlink_metadata(path)
        .await
        .with_context(|| format!("failed to inspect file {}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        anyhow::bail!(
            "private state file {} is not a regular file",
            path.display()
        );
    }

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
