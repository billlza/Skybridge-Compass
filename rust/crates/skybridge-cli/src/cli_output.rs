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

pub(crate) fn unhandled_error_details(error: &anyhow::Error) -> (&'static str, &'static str) {
    #[cfg(target_os = "macos")]
    if error
        .downcast_ref::<crate::file_approval_commands::FileApprovalInputRequired>()
        .is_some()
    {
        return (
            "file_approval_input_required",
            "CLI approval needs a terminal. Use --approval allow|deny for an explicit decision, or --approval device. No file was sent.",
        );
    }
    #[cfg(target_os = "macos")]
    if error
        .downcast_ref::<skybridge_crossnet_client::FileApprovalUnavailable>()
        .is_some()
    {
        return (
            "file_approval_unavailable",
            "The running Mac app does not provide CLI file approval. Use the updated app candidate; no approval decision was confirmed.",
        );
    }
    #[cfg(target_os = "macos")]
    if error
        .downcast_ref::<skybridge_crossnet_client::HandshakeManagementUnavailable>()
        .is_some()
    {
        return (
            "handshake_management_unavailable",
            "The running Mac app does not provide native handshake management. Use the updated app candidate; no settings were changed.",
        );
    }
    #[cfg(target_os = "macos")]
    if error
        .downcast_ref::<skybridge_crossnet_client::PeerPQCSuiteUnavailable>()
        .is_some()
    {
        return (
            "peer_pqc_suite_unavailable",
            "The peer does not provide the selected PQC suite. Review both devices' suite settings; no fallback was performed.",
        );
    }
    #[cfg(target_os = "macos")]
    if error
        .downcast_ref::<skybridge_crossnet_client::USBDeviceUnavailable>()
        .is_some()
    {
        return (
            "usb_device_unavailable",
            "The selected device is not connected over USB. Reconnect the selected device and refresh USB inventory; no network fallback was performed.",
        );
    }
    // Unknown errors retain the existing redaction boundary.
    let _ = error;
    ("command_failed", "SkyBridge command failed")
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

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn closed_suite_error_survives_context_without_exposing_context_text() {
        let error = anyhow::Error::new(skybridge_crossnet_client::PeerPQCSuiteUnavailable)
            .context("private token must not appear");
        let (code, message) = unhandled_error_details(&error);
        assert_eq!(code, "peer_pqc_suite_unavailable");
        assert!(!message.contains("private token"));
        let unknown = anyhow::anyhow!("unknown error with private token");
        assert_eq!(
            unhandled_error_details(&unknown),
            ("command_failed", "SkyBridge command failed")
        );
    }

    #[test]
    fn unavailable_handshake_management_has_a_closed_actionable_error() {
        let error = anyhow::Error::new(skybridge_crossnet_client::HandshakeManagementUnavailable)
            .context("private context");
        let (code, message) = unhandled_error_details(&error);
        assert_eq!(code, "handshake_management_unavailable");
        assert!(message.contains("updated app"));
        assert!(!message.contains("private context"));
    }
    #[test]
    fn absent_usb_error_survives_context_without_echoing_it() {
        let error = anyhow::Error::new(skybridge_crossnet_client::USBDeviceUnavailable)
            .context("private device data must not appear");
        let (code, message) = unhandled_error_details(&error);
        assert_eq!(code, "usb_device_unavailable");
        assert!(message.contains("no network fallback"));
        assert!(!message.contains("private device data"));
    }
}
