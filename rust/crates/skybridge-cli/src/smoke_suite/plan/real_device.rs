use std::path::Path;

use crate::webrtc_media_dimensions::VideoDimensions;

use super::SmokeSuiteStepSpec;
use super::standard::push_remote_control_notice_check_step;

const DEFAULT_REAL_DEVICE_VIDEO_SIZE: VideoDimensions = VideoDimensions {
    width: 2056,
    height: 1329,
};

struct RealDeviceP2pRemoteStepOptions<'a> {
    real_device_id: Option<&'a str>,
    min_fps: f64,
    timeout_seconds: Option<u64>,
    soak_seconds: u64,
    video_size: VideoDimensions,
}

#[allow(clippy::too_many_arguments)]
pub(super) fn push_real_device_smoke_steps(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    real_device_id: Option<&str>,
    auth_session_file: Option<&Path>,
    min_fps: f64,
    timeout_seconds: Option<u64>,
    soak_seconds: u64,
    video_sizes: &[VideoDimensions],
) {
    for size in real_device_video_sizes(video_sizes) {
        push_real_device_webrtc_smoke_step(
            root,
            steps,
            real_device_id,
            auth_session_file,
            min_fps,
            timeout_seconds,
            soak_seconds,
            size.width,
            size.height,
        );
    }

    push_real_device_p2p_remote_smoke_steps(
        root,
        steps,
        real_device_id,
        min_fps,
        timeout_seconds,
        soak_seconds,
        video_sizes,
    );

    push_real_device_file_transfer_smoke_step(root, steps, real_device_id, timeout_seconds);
}

pub(super) fn push_real_device_file_transfer_smoke_step(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    real_device_id: Option<&str>,
    timeout_seconds: Option<u64>,
) {
    let mut file_env = vec![
        env_pair("SKYBRIDGE_SMOKE_USER_REALISTIC", "1"),
        env_pair("SKYBRIDGE_SMOKE_PRESERVE_INSTALL", "1"),
        env_pair("SKYBRIDGE_SMOKE_MAC_HOST_MODE", "signed-app"),
        env_pair("SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH", "1"),
        env_pair("SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH", "1"),
    ];
    push_optional_device_id(&mut file_env, real_device_id);
    push_optional_timeout(&mut file_env, timeout_seconds);
    steps.push(SmokeSuiteStepSpec {
        name: "real_device_file_transfer_smoke",
        description: "Real iPad bidirectional P2P file-transfer smoke",
        program: "bash".to_owned(),
        args: vec!["Scripts/run_real_device_file_transfer_smoke.sh".to_owned()],
        env: file_env,
        cwd: root.to_path_buf(),
    });
}

#[allow(clippy::too_many_arguments)]
fn push_real_device_webrtc_smoke_step(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    real_device_id: Option<&str>,
    auth_session_file: Option<&Path>,
    min_fps: f64,
    timeout_seconds: Option<u64>,
    soak_seconds: u64,
    video_width: u32,
    video_height: u32,
) {
    let mut webrtc_env = Vec::new();
    push_media_env(&mut webrtc_env, min_fps, webrtc_target_fps_floor(min_fps));
    push_optional_timeout(&mut webrtc_env, timeout_seconds);
    push_optional_soak(&mut webrtc_env, soak_seconds);
    push_env(&mut webrtc_env, "SKYBRIDGE_SMOKE_FORCE_RELAY_ICE", "1");
    push_env(&mut webrtc_env, "SKYBRIDGE_SMOKE_EXTREME_MEDIA", "1");
    push_video_size(&mut webrtc_env, video_width, video_height);
    push_env(
        &mut webrtc_env,
        "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK",
        "1",
    );
    push_env(&mut webrtc_env, "SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN", "0");
    push_optional_device_id(&mut webrtc_env, real_device_id);
    if let Some(auth_session_file) = auth_session_file {
        push_env(
            &mut webrtc_env,
            "SKYBRIDGE_SMOKE_AUTH_SESSION_FILE",
            auth_session_file.display().to_string(),
        );
    }
    steps.push(SmokeSuiteStepSpec {
        name: "real_device_webrtc_smoke",
        description: "Real iPad WebRTC media smoke with Rust doctor gate",
        program: "bash".to_owned(),
        args: vec!["Scripts/run_real_device_webrtc_smoke.sh".to_owned()],
        env: webrtc_env,
        cwd: root.to_path_buf(),
    });
}

pub(super) fn push_real_device_p2p_remote_smoke_steps(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    real_device_id: Option<&str>,
    min_fps: f64,
    timeout_seconds: Option<u64>,
    soak_seconds: u64,
    video_sizes: &[VideoDimensions],
) {
    for size in real_device_video_sizes(video_sizes) {
        push_real_device_p2p_remote_smoke_step(
            root,
            steps,
            &RealDeviceP2pRemoteStepOptions {
                real_device_id,
                min_fps,
                timeout_seconds,
                soak_seconds,
                video_size: size,
            },
        );
    }
}

pub(super) fn push_real_device_p2p_security_notice_smoke_steps(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    real_device_id: Option<&str>,
    min_fps: f64,
    timeout_seconds: Option<u64>,
    soak_seconds: u64,
    video_sizes: &[VideoDimensions],
) {
    let artifact_dir = root
        .join("Artifacts")
        .join("real_device_p2p_security_notice");
    for size in real_device_video_sizes(video_sizes) {
        push_real_device_p2p_remote_security_notice_smoke_step(
            root,
            steps,
            &artifact_dir,
            &RealDeviceP2pRemoteStepOptions {
                real_device_id,
                min_fps,
                timeout_seconds,
                soak_seconds,
                video_size: size,
            },
        );
    }
    push_remote_control_notice_check_step(root, steps, &artifact_dir, "p2p", false);
}

fn push_real_device_p2p_remote_smoke_step(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    options: &RealDeviceP2pRemoteStepOptions<'_>,
) {
    let mut env = Vec::new();
    push_media_env(&mut env, options.min_fps, 60.0);
    push_env(&mut env, "SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB", "1");
    push_env(&mut env, "SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW", "1");
    push_env(&mut env, "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY", "0");
    push_env(&mut env, "SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE", "X-Wing");
    push_video_size(
        &mut env,
        options.video_size.width,
        options.video_size.height,
    );
    push_env(
        &mut env,
        "SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION",
        "upright",
    );
    push_env(&mut env, "SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH", "1");
    push_env(&mut env, "SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH", "1");
    push_optional_timeout(&mut env, options.timeout_seconds);
    push_optional_soak(&mut env, options.soak_seconds);
    push_optional_device_id(&mut env, options.real_device_id);
    steps.push(SmokeSuiteStepSpec {
        name: "real_device_p2p_remote_smoke",
        description: "Real iPad same-Wi-Fi P2P remote desktop smoke with no fallback",
        program: "bash".to_owned(),
        args: vec!["Scripts/run_real_device_p2p_remote_smoke.sh".to_owned()],
        env,
        cwd: root.to_path_buf(),
    });
}

fn push_real_device_p2p_remote_security_notice_smoke_step(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    artifact_dir: &Path,
    options: &RealDeviceP2pRemoteStepOptions<'_>,
) {
    let mut env = Vec::new();
    push_media_env(&mut env, options.min_fps, 60.0);
    push_env(
        &mut env,
        "SKYBRIDGE_SMOKE_ARTIFACT_DIR",
        artifact_dir.display(),
    );
    push_env(&mut env, "SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB", "1");
    push_env(&mut env, "SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW", "1");
    push_env(
        &mut env,
        "SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE",
        "1",
    );
    push_env(
        &mut env,
        "SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE",
        "1",
    );
    push_env(&mut env, "SKYBRIDGE_SMOKE_RUN_MAC_ONLINE_IPAD", "0");
    push_env(
        &mut env,
        "SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME",
        "Mac Smoke Operator",
    );
    push_env(
        &mut env,
        "SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID",
        "mac-smoke-nebula",
    );
    push_env(
        &mut env,
        "SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME",
        "iPad Smoke Operator",
    );
    push_env(
        &mut env,
        "SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID",
        "ipad-smoke-nebula",
    );
    push_env(&mut env, "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY", "0");
    push_env(&mut env, "SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE", "X-Wing");
    push_video_size(
        &mut env,
        options.video_size.width,
        options.video_size.height,
    );
    push_env(
        &mut env,
        "SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION",
        "upright",
    );
    push_env(&mut env, "SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH", "1");
    push_env(&mut env, "SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH", "1");
    push_optional_timeout(&mut env, options.timeout_seconds);
    push_optional_soak(&mut env, options.soak_seconds);
    push_optional_device_id(&mut env, options.real_device_id);
    steps.push(SmokeSuiteStepSpec {
        name: "real_device_p2p_security_notice_smoke",
        description: "Real iPad P2P remote desktop smoke with security notice evidence",
        program: "bash".to_owned(),
        args: vec!["Scripts/run_real_device_p2p_remote_smoke.sh".to_owned()],
        env,
        cwd: root.to_path_buf(),
    });
}

fn real_device_video_sizes(video_sizes: &[VideoDimensions]) -> Vec<VideoDimensions> {
    if video_sizes.is_empty() {
        vec![DEFAULT_REAL_DEVICE_VIDEO_SIZE]
    } else {
        video_sizes.to_vec()
    }
}

fn push_media_env(env: &mut Vec<(String, String)>, min_fps: f64, target_fps_floor: f64) {
    push_env(env, "SKYBRIDGE_SMOKE_MIN_FPS", format!("{min_fps:.2}"));
    push_env(
        env,
        "SKYBRIDGE_SMOKE_TARGET_FPS",
        target_fps(min_fps, target_fps_floor),
    );
    push_env(env, "SKYBRIDGE_SMOKE_REQUIRE_AUDIO", "1");
}

fn push_video_size(env: &mut Vec<(String, String)>, width: u32, height: u32) {
    push_env(env, "SKYBRIDGE_SMOKE_VIDEO_WIDTH", width);
    push_env(env, "SKYBRIDGE_SMOKE_VIDEO_HEIGHT", height);
}

fn push_optional_timeout(env: &mut Vec<(String, String)>, timeout_seconds: Option<u64>) {
    if let Some(timeout_seconds) = timeout_seconds {
        push_env(env, "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS", timeout_seconds);
    }
}

fn push_optional_soak(env: &mut Vec<(String, String)>, soak_seconds: u64) {
    if soak_seconds > 0 {
        push_env(env, "SKYBRIDGE_SMOKE_SOAK_SECONDS", soak_seconds);
    }
}

fn push_optional_device_id(env: &mut Vec<(String, String)>, real_device_id: Option<&str>) {
    if let Some(device_id) = real_device_id {
        push_env(env, "SKYBRIDGE_REAL_DEVICE_ID", device_id);
    }
}

fn webrtc_target_fps_floor(min_fps: f64) -> f64 {
    if min_fps >= 59.0 { 60.0 } else { 32.0 }
}

fn target_fps(min_fps: f64, floor: f64) -> u32 {
    min_fps.ceil().max(floor).clamp(1.0, 120.0) as u32
}

fn push_env(env: &mut Vec<(String, String)>, name: &'static str, value: impl ToString) {
    env.push(env_pair(name, value));
}

fn env_pair(name: &'static str, value: impl ToString) -> (String, String) {
    (name.to_owned(), value.to_string())
}
