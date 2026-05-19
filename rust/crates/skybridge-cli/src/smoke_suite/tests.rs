use std::path::{Path, PathBuf};

use crate::LocalP2pSmokeScenario;

use super::super::OutputOptions;
use super::*;

mod dry_run;
mod option_mapping;
mod plan_runner;
mod real_device_profiles;
mod validation;

fn smoke_common(dry_run: bool, json: bool) -> SmokeSuiteCommonArgs {
    SmokeSuiteCommonArgs {
        dry_run,
        skip_real_device: false,
        real_device_id: None,
        auth_session_file: None,
        min_fps: 30.0,
        timeout_seconds: None,
        soak_seconds: 0,
        video_width: 2056,
        video_height: 1329,
        video_sizes: Vec::new(),
        mainstream_resolutions: false,
        output: OutputOptions { json },
    }
}

fn shell_step(root: &Path, name: &'static str, script: &str) -> SmokeSuiteStepSpec {
    SmokeSuiteStepSpec {
        name,
        description: "test shell step",
        program: "sh".to_owned(),
        args: vec!["-c".to_owned(), script.to_owned()],
        env: vec![("SKYBRIDGE_TEST_ENV".to_owned(), "1".to_owned())],
        cwd: root.to_path_buf(),
    }
}
