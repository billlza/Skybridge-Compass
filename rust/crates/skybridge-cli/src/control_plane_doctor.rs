use anyhow::Result;
use skybridge_core::SignalServerClient;

use crate::{DoctorCheck, DoctorProbeReport};

mod checks;
mod media_lease;
mod signaling;

pub(crate) use media_lease::build_media_lease_doctor_report;
pub(crate) use signaling::build_signaling_doctor_report;

fn control_plane_report(target: String, checks: Vec<DoctorCheck>) -> DoctorProbeReport {
    DoctorProbeReport {
        target,
        checks,
        fault_stage: None,
        latest_diagnostic_at: None,
        latest_video_evidence_at: None,
        latest_receiver_evidence_at: None,
        latest_audio_tx_evidence_at: None,
        latest_audio_rx_evidence_at: None,
    }
}

fn signal_server_client(base_url: Option<String>) -> Result<SignalServerClient> {
    if let Some(base_url) = base_url.filter(|value| !value.trim().is_empty()) {
        let api_key = std::env::var("SKYBRIDGE_CLIENT_API_KEY")
            .unwrap_or_else(|_| "skybridge-client-v1".to_owned());
        let client_version = std::env::var("SKYBRIDGE_CLIENT_VERSION")
            .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_owned());
        let protocol_version =
            std::env::var("SKYBRIDGE_PROTOCOL_VERSION").unwrap_or_else(|_| "1".to_owned());
        return SignalServerClient::new(base_url, api_key, client_version, protocol_version);
    }
    SignalServerClient::from_env()
}
