use std::sync::OnceLock;

use anyhow::{Result, anyhow};
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::time::UtcTime;

use super::AgentPaths;

static TRACING_GUARD: OnceLock<WorkerGuard> = OnceLock::new();

pub(super) fn init_tracing(paths: &AgentPaths) -> Result<()> {
    if TRACING_GUARD.get().is_some() {
        return Ok(());
    }

    let file_appender = tracing_appender::rolling::never(&paths.logs_dir, "agent.log");
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);
    TRACING_GUARD
        .set(guard)
        .map_err(|_| anyhow!("tracing guard already initialised"))?;

    let timer = UtcTime::rfc_3339();
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,skybridge_agent=info")),
        )
        .with_timer(timer)
        .with_writer(non_blocking)
        .json()
        .with_current_span(false)
        .with_span_list(false)
        .try_init()
        .map_err(|error| anyhow!("failed to initialize tracing subscriber: {error}"))?;
    Ok(())
}
