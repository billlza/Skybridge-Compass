use serde::Serialize;
use time::OffsetDateTime;

#[derive(Debug, Clone, Serialize)]
pub(crate) struct DoctorCheck {
    pub(crate) name: &'static str,
    pub(crate) ok: bool,
    pub(crate) severity: &'static str,
    pub(crate) detail: String,
    #[serde(
        rename = "serverBuildFingerprint",
        skip_serializing_if = "Option::is_none"
    )]
    pub(crate) server_build_fingerprint: Option<String>,
    #[serde(rename = "stateBackend", skip_serializing_if = "Option::is_none")]
    pub(crate) state_backend: Option<String>,
    #[serde(rename = "rejectReason", skip_serializing_if = "Option::is_none")]
    pub(crate) reject_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct DoctorProbeReport {
    pub(crate) target: String,
    pub(crate) checks: Vec<DoctorCheck>,
    #[serde(rename = "faultStage", skip_serializing_if = "Option::is_none")]
    pub(crate) fault_stage: Option<&'static str>,
    #[serde(skip)]
    pub(crate) latest_diagnostic_at: Option<OffsetDateTime>,
    #[serde(skip)]
    pub(crate) latest_video_evidence_at: Option<OffsetDateTime>,
    #[serde(skip)]
    pub(crate) latest_receiver_evidence_at: Option<OffsetDateTime>,
    #[serde(skip)]
    pub(crate) latest_audio_tx_evidence_at: Option<OffsetDateTime>,
    #[serde(skip)]
    pub(crate) latest_audio_rx_evidence_at: Option<OffsetDateTime>,
}

pub(crate) fn simple_doctor_check(
    name: &'static str,
    ok: bool,
    severity: &'static str,
    detail: String,
) -> DoctorCheck {
    DoctorCheck {
        name,
        ok,
        severity,
        detail,
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}
