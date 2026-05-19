use std::path::PathBuf;

use crate::webrtc_media_dimensions::{MAINSTREAM_WEBRTC_VIDEO_SIZES, VideoDimensions};
use anyhow::{Context, Result, bail};

use super::{
    SmokeFaultsArgs, SmokeLocalP2pArgs, SmokeSuiteArgs, SmokeSuiteCommonArgs, SmokeSuiteProfile,
};

mod plan;
mod runner;
use plan::*;
use runner::run_smoke_suite_plan;

fn is_real_device_smoke_profile(profile: SmokeSuiteProfile) -> bool {
    matches!(
        profile,
        SmokeSuiteProfile::RealDevice
            | SmokeSuiteProfile::RealDeviceP2p
            | SmokeSuiteProfile::RealDeviceFileTransfer
    )
}

pub(crate) async fn smoke_suite(args: SmokeSuiteArgs) -> Result<()> {
    if !args.common.min_fps.is_finite() || args.common.min_fps <= 0.0 {
        bail!("--min-fps must be a positive finite number");
    }
    if matches!(args.common.timeout_seconds, Some(0)) {
        bail!("--timeout-seconds must be greater than zero");
    }
    if let Some(timeout_seconds) = args.common.timeout_seconds
        && args.common.soak_seconds >= timeout_seconds
    {
        bail!("--soak-seconds must be smaller than --timeout-seconds");
    }
    let timeout_seconds = args
        .common
        .timeout_seconds
        .or_else(|| (args.common.soak_seconds > 0).then_some(args.common.soak_seconds + 240));
    if args.common.video_width == 0 || args.common.video_height == 0 {
        bail!("--video-width and --video-height must be greater than zero");
    }
    let video_sizes = resolve_smoke_video_sizes(&args.common)?;
    if is_real_device_smoke_profile(args.profile) && args.common.skip_real_device {
        bail!("--skip-real-device is not valid with real-device profiles");
    }

    let root = resolve_repo_root()?;
    let steps = build_smoke_suite_steps(
        &root,
        args.profile,
        args.common.skip_real_device,
        args.common.real_device_id.as_deref(),
        args.common.auth_session_file.as_deref(),
        args.common.min_fps,
        timeout_seconds,
        args.common.soak_seconds,
        &video_sizes,
    )?;
    run_smoke_suite_plan(
        &root,
        args.profile,
        args.common.dry_run,
        args.common.output.json,
        steps,
    )
}

fn resolve_smoke_video_sizes(common: &SmokeSuiteCommonArgs) -> Result<Vec<VideoDimensions>> {
    if common.mainstream_resolutions && !common.video_sizes.is_empty() {
        bail!("use either --mainstream-resolutions or --video-size, not both");
    }
    let sizes = if common.mainstream_resolutions {
        MAINSTREAM_WEBRTC_VIDEO_SIZES.to_vec()
    } else if !common.video_sizes.is_empty() {
        common
            .video_sizes
            .iter()
            .map(|value| parse_smoke_video_size(value))
            .collect::<Result<Vec<_>>>()?
    } else {
        vec![VideoDimensions {
            width: common.video_width,
            height: common.video_height,
        }]
    };
    dedupe_smoke_video_sizes(sizes)
}

fn parse_smoke_video_size(value: &str) -> Result<VideoDimensions> {
    let trimmed = value.trim();
    let Some((width, height)) = trimmed.split_once('x').or_else(|| trimmed.split_once('X')) else {
        bail!("invalid --video-size '{value}', expected WIDTHxHEIGHT");
    };
    let width = width
        .trim()
        .parse::<u32>()
        .with_context(|| format!("invalid --video-size width in '{value}'"))?;
    let height = height
        .trim()
        .parse::<u32>()
        .with_context(|| format!("invalid --video-size height in '{value}'"))?;
    if width == 0 || height == 0 {
        bail!("--video-size dimensions must be greater than zero: {value}");
    }
    Ok(VideoDimensions { width, height })
}

fn dedupe_smoke_video_sizes(sizes: Vec<VideoDimensions>) -> Result<Vec<VideoDimensions>> {
    let mut deduped = Vec::new();
    for size in sizes {
        if !deduped.contains(&size) {
            deduped.push(size);
        }
    }
    if deduped.is_empty() {
        bail!("at least one WebRTC smoke video size is required");
    }
    Ok(deduped)
}

pub(crate) async fn smoke_faults(args: SmokeFaultsArgs) -> Result<()> {
    let root = resolve_repo_root()?;
    let mut steps = Vec::new();
    push_fault_injection_steps(
        &root,
        &mut steps,
        SmokeFaultOptions {
            iterations: args.iterations,
            timeout_ms: args.timeout_ms,
            delay_ms: args.delay_ms,
            progress_interval: args.progress_interval,
        },
    );
    run_smoke_suite_plan(
        &root,
        SmokeSuiteProfile::FaultInjection,
        args.dry_run,
        args.output.json,
        steps,
    )
}

pub(crate) async fn smoke_local_p2p(args: SmokeLocalP2pArgs) -> Result<()> {
    if matches!(args.rounds, Some(0)) {
        bail!("--rounds must be greater than zero");
    }
    if matches!(args.timeout_seconds, Some(0)) {
        bail!("--timeout-seconds must be greater than zero");
    }
    let root = resolve_repo_root()?;
    let mut steps = Vec::new();
    push_local_p2p_smoke_steps(
        &root,
        &mut steps,
        SmokeLocalP2pOptions {
            scenario: args.scenario,
            rounds: args.rounds,
            timeout_seconds: args.timeout_seconds,
            ios_device_id: args.ios_device_id,
            target_name: args.target_name,
        },
    );
    run_smoke_suite_plan(
        &root,
        SmokeSuiteProfile::LocalP2p,
        args.dry_run,
        args.output.json,
        steps,
    )
}

fn resolve_repo_root() -> Result<PathBuf> {
    let mut current = std::env::current_dir()?;
    loop {
        if current.join("Scripts").is_dir()
            && current.join("rust").join("Cargo.toml").is_file()
            && current.join("Package.swift").is_file()
        {
            return Ok(current);
        }

        if !current.pop() {
            break;
        }
    }

    bail!("Could not locate SkyBridge repository root from current directory")
}

#[cfg(test)]
mod tests;
