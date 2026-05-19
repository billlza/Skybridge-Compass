#![cfg(test)]

use anyhow::Result;
use serde_json::json;
use time::OffsetDateTime;

use crate::cli_test_support::{
    doctor_check, doctor_check_optional, make_test_dir, set_env_var_for_test,
};
use crate::webrtc_media_artifacts::resolve_webrtc_media_session_arg;
use crate::webrtc_media_doctor::{
    build_webrtc_media_doctor_report, build_webrtc_media_doctor_report_for_gate,
    build_webrtc_media_doctor_report_with_video_requirements,
};
use crate::{OutputOptions, WebRtcMediaDoctorArgs, ensure_webrtc_media_doctor_passed};

mod audio_counters;
mod audio_playback;
mod capture_encode;
mod diagnostics_baseline;
mod fallback_strict;
mod relay_bind;
mod resolution_sources;
mod startup_artifact_resolution;
mod video_render;
