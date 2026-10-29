use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

use anyhow::{Context, Result, bail};
use time::OffsetDateTime;

use crate::performance_evidence::update_signed_kem_refresh_evidence;
use crate::webrtc_media_parse::{
    parse_webrtc_diagnostic_timestamp, parse_webrtc_local_console_timestamp,
};

mod audio;
mod files;
mod final_window;
mod ios_lan_rx;
mod log_order;
mod mac_ipad_online;
mod mac_tx;
mod markers;
mod metal_render;
mod pass_window;
mod remote_desktop_status;
mod route;
mod types;

use audio::update_p2p_remote_audio_evidence;
use files::is_p2p_remote_ios_log;
pub(crate) use files::{p2p_remote_performance_artifact_available, p2p_remote_performance_files};
pub(crate) use final_window::update_p2p_remote_final_window_ios_evidence;
use final_window::update_p2p_remote_final_window_mac_evidence;
use ios_lan_rx::update_p2p_remote_ios_lan_rx_evidence;
use log_order::{P2pRemoteLogEntry, sort_log_entries_chronologically};
use mac_ipad_online::update_p2p_remote_mac_ipad_online_evidence;
use mac_tx::update_p2p_remote_mac_tx_evidence;
use markers::update_p2p_remote_marker_evidence;
use metal_render::update_p2p_remote_metal_render_evidence;
use pass_window::p2p_remote_latest_pass_window;
use remote_desktop_status::update_p2p_remote_remote_desktop_evidence;
use route::update_p2p_remote_route_evidence;
pub(crate) use types::P2pRemotePerformanceEvidence;

pub(crate) fn read_p2p_remote_performance_evidence(
    artifact_dir: &Path,
) -> Result<P2pRemotePerformanceEvidence> {
    let files = p2p_remote_performance_files(artifact_dir)?;
    if files.is_empty() {
        bail!(
            "no P2P remote performance logs found in {}",
            artifact_dir.display()
        );
    }

    let mut evidence = P2pRemotePerformanceEvidence {
        file_count: files.len(),
        ..Default::default()
    };
    let mut entries: Vec<P2pRemoteLogEntry> = Vec::new();
    let mut ios_entries: Vec<(usize, usize, Option<OffsetDateTime>, String)> = Vec::new();
    for (file_id, path) in files.into_iter().enumerate() {
        let is_ios = is_p2p_remote_ios_log(&path);
        let is_mac = !is_ios;
        evidence.has_ios_log |= is_ios;
        evidence.has_mac_log |= is_mac;
        let file = File::open(&path)
            .with_context(|| format!("failed to open P2P remote log {}", path.display()))?;
        for (line_index, line) in BufReader::new(file)
            .lines()
            .map_while(Result::ok)
            .enumerate()
        {
            let observed_at = parse_webrtc_diagnostic_timestamp(line.trim(), None);
            if is_ios {
                ios_entries.push((file_id, line_index, observed_at, line.clone()));
            }
            entries.push((is_mac, is_ios, file_id, line_index, observed_at, line));
        }
    }
    let pass_window = p2p_remote_latest_pass_window(&ios_entries);
    evidence.pass_window_start_at = pass_window.start_at;
    evidence.pass_window_end_at = pass_window.end_at;
    evidence.pass_window_seconds = pass_window.window_seconds;
    evidence.pass_requested_seconds = pass_window.requested_seconds;
    let local_timestamp_anchor = pass_window.end_at.or(pass_window.start_at);
    for (is_mac, is_ios, _, _, observed_at, line) in &mut entries {
        if *is_ios
            && observed_at.is_none()
            && let Some(anchor) = local_timestamp_anchor
        {
            *observed_at = parse_webrtc_local_console_timestamp(line.trim(), anchor);
        }
        if *is_mac {
            *observed_at =
                observed_at.or_else(|| parse_webrtc_diagnostic_timestamp(line.trim(), None));
        }
    }
    sort_log_entries_chronologically(&mut entries);
    for (is_mac, is_ios, file_id, line_index, observed_at, line) in entries {
        update_p2p_remote_evidence_with_observed_at(
            &mut evidence,
            &line,
            is_mac,
            is_ios,
            observed_at,
        );
        let in_final_pass_window = if is_ios {
            let in_log_order_window = pass_window
                .start_position()
                .zip(pass_window.end_position())
                .is_some_and(
                    |((start_file_id, start_line_index), (end_file_id, end_line_index))| {
                        file_id == start_file_id
                            && file_id == end_file_id
                            && line_index >= start_line_index
                            && line_index <= end_line_index
                    },
                );
            let in_time_window = observed_at
                .zip(pass_window.start_at.zip(pass_window.end_at))
                .is_some_and(|(timestamp, (start, end))| {
                    timestamp >= start && timestamp <= end + time::Duration::seconds(1)
                });
            in_log_order_window && in_time_window
        } else {
            observed_at
                .zip(pass_window.start_at.zip(pass_window.end_at))
                .is_some_and(|(timestamp, (start, end))| {
                    timestamp >= start + time::Duration::seconds(1) && timestamp <= end
                })
        };
        if in_final_pass_window {
            if is_mac {
                update_p2p_remote_final_window_mac_evidence(&mut evidence, &line);
            }
            if is_ios {
                update_p2p_remote_final_window_ios_evidence(&mut evidence, &line);
            }
        }
    }
    Ok(evidence)
}

#[cfg(test)]
pub(crate) fn update_p2p_remote_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    is_mac: bool,
    is_ios: bool,
) {
    update_p2p_remote_evidence_with_observed_at(evidence, line, is_mac, is_ios, None);
}

fn update_p2p_remote_evidence_with_observed_at(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    is_mac: bool,
    is_ios: bool,
    observed_at: Option<OffsetDateTime>,
) {
    let lower = line.to_ascii_lowercase();
    let line_sequence = update_signed_kem_refresh_evidence(
        &mut evidence.signed_kem_refresh,
        line,
        &lower,
        is_mac,
        is_ios,
        observed_at,
    );
    update_p2p_remote_marker_evidence(evidence, line, &lower, line_sequence);
    update_p2p_remote_mac_ipad_online_evidence(
        evidence,
        line,
        &lower,
        is_mac,
        is_ios,
        line_sequence,
    );
    update_p2p_remote_route_evidence(evidence, line, is_mac, is_ios);
    update_p2p_remote_mac_tx_evidence(evidence, line, is_mac);
    update_p2p_remote_ios_lan_rx_evidence(evidence, line, is_ios);
    update_p2p_remote_metal_render_evidence(evidence, line, is_ios);
    update_p2p_remote_remote_desktop_evidence(evidence, line, is_ios);
    update_p2p_remote_audio_evidence(evidence, line, is_mac, is_ios);
}
