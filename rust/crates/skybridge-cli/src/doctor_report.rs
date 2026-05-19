mod presentation;
#[cfg(test)]
mod tests;
mod types;
mod validation;

pub(crate) use presentation::print_doctor_probe_report;
pub(crate) use types::{DoctorCheck, DoctorProbeReport, simple_doctor_check};
pub(crate) use validation::{ensure_probe_report_passed, ensure_webrtc_media_doctor_passed};
