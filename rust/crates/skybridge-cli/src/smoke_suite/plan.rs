use std::path::{Path, PathBuf};

use anyhow::Result;

use crate::webrtc_media_dimensions::VideoDimensions;
use crate::{LocalP2pSmokeScenario, SmokeSuiteProfile};

mod benchmarks;
mod real_device;
mod standard;

use benchmarks::push_benchmark_steps;
use real_device::{
    push_real_device_file_transfer_smoke_step, push_real_device_p2p_remote_smoke_steps,
    push_real_device_smoke_steps,
};
pub(super) use standard::{push_fault_injection_steps, push_local_p2p_smoke_steps};
use standard::{
    push_full_smoke_steps, push_ios_config_steps, push_local_webrtc_smoke_steps,
    push_quick_smoke_steps, push_release_smoke_steps, push_script_test_steps,
};

#[derive(Debug, Clone)]
pub(super) struct SmokeSuiteStepSpec {
    pub(super) name: &'static str,
    pub(super) description: &'static str,
    pub(super) program: String,
    pub(super) args: Vec<String>,
    pub(super) env: Vec<(String, String)>,
    pub(super) cwd: PathBuf,
}

#[derive(Debug, Clone, Copy, Default)]
pub(super) struct SmokeFaultOptions {
    pub(super) iterations: Option<u32>,
    pub(super) timeout_ms: Option<u32>,
    pub(super) delay_ms: Option<u32>,
    pub(super) progress_interval: Option<u32>,
}

#[derive(Debug, Clone, Default)]
pub(super) struct SmokeLocalP2pOptions {
    pub(super) scenario: LocalP2pSmokeScenario,
    pub(super) rounds: Option<u32>,
    pub(super) timeout_seconds: Option<u64>,
    pub(super) ios_device_id: Option<String>,
    pub(super) target_name: Option<String>,
}

impl SmokeSuiteStepSpec {
    pub(super) fn command_vector(&self) -> Vec<String> {
        let mut command = Vec::with_capacity(1 + self.args.len());
        command.push(self.program.clone());
        command.extend(self.args.iter().cloned());
        command
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn build_smoke_suite_steps(
    root: &Path,
    profile: SmokeSuiteProfile,
    skip_real_device: bool,
    real_device_id: Option<&str>,
    auth_session_file: Option<&Path>,
    min_fps: f64,
    timeout_seconds: Option<u64>,
    soak_seconds: u64,
    video_sizes: &[VideoDimensions],
) -> Result<Vec<SmokeSuiteStepSpec>> {
    let mut steps = Vec::new();
    match profile {
        SmokeSuiteProfile::Quick => push_quick_smoke_steps(root, &mut steps),
        SmokeSuiteProfile::Full => push_full_smoke_steps(root, &mut steps),
        SmokeSuiteProfile::ScriptTests => push_script_test_steps(root, &mut steps),
        SmokeSuiteProfile::IosConfig => push_ios_config_steps(root, &mut steps),
        SmokeSuiteProfile::LocalWebrtc => push_local_webrtc_smoke_steps(root, &mut steps, min_fps),
        SmokeSuiteProfile::LocalP2p => {
            push_local_p2p_smoke_steps(root, &mut steps, SmokeLocalP2pOptions::default())
        }
        SmokeSuiteProfile::RealDeviceP2p => push_real_device_p2p_remote_smoke_steps(
            root,
            &mut steps,
            real_device_id,
            min_fps,
            timeout_seconds,
            soak_seconds,
            video_sizes,
        ),
        SmokeSuiteProfile::RealDeviceFileTransfer => {
            push_real_device_file_transfer_smoke_step(
                root,
                &mut steps,
                real_device_id,
                timeout_seconds,
            );
        }
        SmokeSuiteProfile::FaultInjection => {
            push_fault_injection_steps(root, &mut steps, SmokeFaultOptions::default())
        }
        SmokeSuiteProfile::Benchmarks => push_benchmark_steps(root, &mut steps),
        SmokeSuiteProfile::Release => push_release_smoke_steps(root, &mut steps),
        SmokeSuiteProfile::RealDevice => push_real_device_smoke_steps(
            root,
            &mut steps,
            real_device_id,
            auth_session_file,
            min_fps,
            timeout_seconds,
            soak_seconds,
            video_sizes,
        ),
        SmokeSuiteProfile::All => {
            push_full_smoke_steps(root, &mut steps);
            push_script_test_steps(root, &mut steps);
            push_ios_config_steps(root, &mut steps);
            push_local_p2p_smoke_steps(root, &mut steps, SmokeLocalP2pOptions::default());
            push_local_webrtc_smoke_steps(root, &mut steps, min_fps);
            push_fault_injection_steps(root, &mut steps, SmokeFaultOptions::default());
            push_benchmark_steps(root, &mut steps);
            push_release_smoke_steps(root, &mut steps);
            if !skip_real_device {
                push_real_device_smoke_steps(
                    root,
                    &mut steps,
                    real_device_id,
                    auth_session_file,
                    min_fps,
                    timeout_seconds,
                    soak_seconds,
                    video_sizes,
                );
            }
        }
    }
    Ok(steps)
}

fn swift_test_cache_env(root: &Path) -> Vec<(String, String)> {
    let cache_dir = root.join(".swiftpm-cache").display().to_string();
    let module_cache_dir = root.join(".swiftpm-module-cache").display().to_string();
    vec![
        ("SWIFTPM_CACHE_PATH".to_owned(), cache_dir),
        (
            "CLANG_MODULE_CACHE_PATH".to_owned(),
            module_cache_dir.clone(),
        ),
        ("SWIFT_MODULE_CACHE_PATH".to_owned(), module_cache_dir),
    ]
}
