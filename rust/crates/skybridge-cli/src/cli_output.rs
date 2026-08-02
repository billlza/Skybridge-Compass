use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result};
use serde::Serialize;

static JSON_FAILURE_WRITTEN: AtomicBool = AtomicBool::new(false);

#[derive(Serialize)]
struct UnhandledJsonFailure<'a> {
    schema_version: u32,
    success: bool,
    status: &'static str,
    error: UnhandledJsonError<'a>,
}

#[derive(Serialize)]
struct UnhandledJsonError<'a> {
    code: &'a str,
    message: &'a str,
    retryable: bool,
}

pub(crate) fn write_json_failure<T: Serialize>(report: &T) -> Result<()> {
    let mut encoded = serde_json::to_vec_pretty(report).context("encode CLI JSON failure")?;
    encoded.push(b'\n');

    let stderr = io::stderr();
    let mut stderr = stderr.lock();
    stderr
        .write_all(&encoded)
        .context("write CLI JSON failure")?;
    stderr.flush().context("flush CLI JSON failure")?;
    JSON_FAILURE_WRITTEN.store(true, Ordering::Release);
    Ok(())
}

pub(crate) fn json_failure_was_written() -> bool {
    JSON_FAILURE_WRITTEN.load(Ordering::Acquire)
}

pub(crate) fn write_unhandled_json_failure(code: &str, message: &str) -> Result<()> {
    write_json_failure(&UnhandledJsonFailure {
        schema_version: 1,
        success: false,
        status: "failed",
        error: UnhandledJsonError {
            code,
            message,
            retryable: false,
        },
    })
}
