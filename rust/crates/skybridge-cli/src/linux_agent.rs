use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, ensure};
use rustix::process::{Pid, PidfdFlags, Signal, pidfd_open, pidfd_send_signal};
use serde_json::json;
use skybridge_agent::{agent_runtime_is_active, resolve_paths};
use tokio::io::Interest;
use tokio::io::unix::AsyncFd;

use crate::AgentStopArgs;
use crate::agent_runtime_guard::load_owned_agent_health;

pub(crate) async fn stop(state_dir: Option<PathBuf>, args: AgentStopArgs) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let before = load_owned_agent_health(&paths).await?;
    if let Some(expected) = &args.instance_id {
        ensure!(
            *expected == before.instance_id,
            "agent incarnation changed; no signal was sent"
        );
    }
    let pid = Pid::from_raw(i32::try_from(before.pid).context("invalid agent PID")?)
        .context("agent PID cannot be zero")?;
    let pidfd = pidfd_open(pid, PidfdFlags::NONBLOCK).context(
        "failed to open agent pidfd; Linux 5.10+ is required, no PID-based fallback was used",
    )?;
    // Pin the process before a second lock/lease/health check. If the first
    // process exited and its PID was reused, that unrelated process cannot be
    // authorized by the original agent's now-unowned lock or replaced lease.
    let after = load_owned_agent_health(&paths).await?;
    ensure!(
        before.instance_id == after.instance_id && before.pid == after.pid,
        "agent incarnation changed while opening pidfd; no signal was sent"
    );
    // SAFETY: pidfd_open returned a live, nonblocking OwnedFd. It is moved into
    // AsyncFd, never replaced or closed while registered, and only borrowed for
    // pidfd_send_signal. AsyncFd deregisters before dropping the OwnedFd.
    let process = unsafe { AsyncFd::register_with_interest(pidfd, Interest::READABLE) }
        .context("failed to monitor agent process exit")?;
    pidfd_send_signal(process.get_ref(), Signal::TERM)
        .context("failed to request agent shutdown")?;
    // The OS signals pidfd readability on exit even for a non-child process.
    // Timeout never escalates to SIGKILL or retries against another incarnation.
    let _exited = tokio::time::timeout(
        Duration::from_secs(args.timeout_seconds),
        process.readable(),
    )
    .await
    .context("agent stop deadline expired after SIGTERM; shutdown may still be in progress")?
    .context("failed to observe agent process exit after SIGTERM")?;
    let replacement_active = agent_runtime_is_active(&paths)?;
    if args.output.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "schema_version": 1,
                "success": true,
                "instance_id": before.instance_id,
                "pid": before.pid,
                "signal_sent": "SIGTERM",
                "process_exited": true,
                "replacement_agent_active": replacement_active,
                "cleanup_verified": false,
            }))?
        );
    } else {
        println!(
            "Agent {} exited after SIGTERM; replacement agent active: {}. Inspect logs for session cleanup results.",
            before.instance_id, replacement_active
        );
    }
    Ok(())
}
