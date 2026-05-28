use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::Serialize;

use crate::{RemoteControlNoticeCheckArgs, RemoteControlNoticeTransportArg};

#[derive(Debug, Serialize)]
struct RemoteControlNoticeCheckJson {
    name: &'static str,
    passed: bool,
    detail: String,
}

#[derive(Debug, Serialize)]
struct RemoteControlNoticeReportJson {
    schema_version: u8,
    transport: &'static str,
    source: String,
    passed: bool,
    checks: Vec<RemoteControlNoticeCheckJson>,
}

#[derive(Debug, Default)]
struct RemoteControlNoticeEvidence {
    events: Vec<NoticeEvent>,
    panel_presented: Vec<NoticeEvent>,
    panel_hidden: Vec<NoticeEvent>,
    lifecycle: Option<NoticeLifecycleEvidence>,
    rejected: bool,
    timed_out: bool,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum NoticeEventKind {
    Shown,
    Approved,
    Active,
    Disconnected,
    Rejected,
    TimedOut,
    PanelPresented,
    PanelHidden,
}

#[derive(Debug, Clone)]
struct NoticeEvent {
    kind: NoticeEventKind,
    fields: BTreeMap<String, String>,
    ordinal: usize,
}

#[derive(Debug, Clone)]
struct NoticeLifecycleEvidence {
    shown: NoticeEvent,
    approved: NoticeEvent,
    active: NoticeEvent,
    disconnected: NoticeEvent,
}

impl NoticeLifecycleEvidence {
    fn fields(&self) -> [&BTreeMap<String, String>; 4] {
        [
            &self.shown.fields,
            &self.approved.fields,
            &self.active.fields,
            &self.disconnected.fields,
        ]
    }
}

pub(crate) async fn check_remote_control_notice(args: RemoteControlNoticeCheckArgs) -> Result<()> {
    let (source, text) = read_notice_source(&args)?;
    let report =
        analyze_remote_control_notice_text(&text, args.transport, source, args.require_panel);
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        print_report_text(&report);
    }
    if !report.passed {
        bail!("remote-control-notice check failed");
    }
    Ok(())
}

fn read_notice_source(args: &RemoteControlNoticeCheckArgs) -> Result<(String, String)> {
    match (&args.artifact_dir, &args.log_file) {
        (Some(_), Some(_)) => bail!("use either --artifact-dir or --log-file, not both"),
        (Some(dir), None) => {
            let text = read_artifact_dir(dir)?;
            Ok((dir.display().to_string(), text))
        }
        (None, Some(path)) => {
            let text = read_text_lossy(path)
                .with_context(|| format!("failed to read log file {}", path.display()))?;
            Ok((path.display().to_string(), text))
        }
        (None, None) => bail!("one of --artifact-dir or --log-file is required"),
    }
}

fn read_artifact_dir(dir: &Path) -> Result<String> {
    if !dir.is_dir() {
        bail!("artifact directory does not exist: {}", dir.display());
    }
    let mut files = Vec::new();
    collect_text_files(dir, &mut files)?;
    files.sort();
    let mut text = String::new();
    for path in files {
        let content = read_text_lossy(&path)
            .with_context(|| format!("failed to read artifact file {}", path.display()))?;
        text.push_str(&content);
        if !content.ends_with('\n') {
            text.push('\n');
        }
    }
    Ok(text)
}

fn read_text_lossy(path: &Path) -> Result<String> {
    let bytes = fs::read(path)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn collect_text_files(dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(dir).with_context(|| format!("failed to read {}", dir.display()))? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_text_files(&path, files)?;
        } else if is_notice_text_candidate(&path) {
            files.push(path);
        }
    }
    Ok(())
}

fn is_notice_text_candidate(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|ext| ext.to_str()),
        Some("log" | "txt" | "status" | "json")
    )
}

fn analyze_remote_control_notice_text(
    text: &str,
    transport: RemoteControlNoticeTransportArg,
    source: String,
    require_panel: bool,
) -> RemoteControlNoticeReportJson {
    let expected_transport = transport_label(transport);
    let evidence = parse_notice_evidence(text, expected_transport);
    let lifecycle = evidence.lifecycle.as_ref();
    let pending_panel = lifecycle
        .and_then(|lifecycle| panel_presented_for_phase(&evidence, lifecycle, "awaitingApproval"));
    let active_panel =
        lifecycle.and_then(|lifecycle| panel_presented_for_phase(&evidence, lifecycle, "active"));

    let mut checks = Vec::new();
    push_check(
        &mut checks,
        "shown",
        evidence.has_kind(NoticeEventKind::Shown),
        "remoteControlNoticeShown lifecycle event",
    );
    push_check(
        &mut checks,
        "approved",
        evidence.has_kind(NoticeEventKind::Approved),
        "remoteControlNoticeApproved lifecycle event",
    );
    push_check(
        &mut checks,
        "active",
        evidence.has_kind(NoticeEventKind::Active),
        "remoteControlNoticeActive lifecycle event",
    );
    push_check(
        &mut checks,
        "disconnected",
        evidence.has_kind(NoticeEventKind::Disconnected),
        "remoteControlNoticeDisconnected lifecycle event",
    );
    push_check(
        &mut checks,
        "session_order",
        lifecycle.is_some(),
        "notice lifecycle events bind to one session in shown->approved->active->disconnected order",
    );
    push_check(
        &mut checks,
        "transport",
        lifecycle.is_some_and(|lifecycle| {
            lifecycle.fields().iter().all(|fields| {
                fields
                    .get("transport")
                    .is_some_and(|value| value == expected_transport)
            })
        }),
        "notice evidence records the requested transport",
    );
    push_check(
        &mut checks,
        "remote_ip",
        lifecycle.is_some_and(|lifecycle| {
            lifecycle
                .fields()
                .iter()
                .all(|fields| present(fields.get("remoteIP")))
        }),
        "notice evidence records the peer IP",
    );
    push_check(
        &mut checks,
        "account",
        lifecycle.is_some_and(|lifecycle| {
            lifecycle
                .fields()
                .iter()
                .all(|fields| present(fields.get("remoteAccount")))
        }),
        "notice evidence records remote account metadata",
    );
    push_check(
        &mut checks,
        "nebula_id",
        lifecycle.is_some_and(|lifecycle| {
            lifecycle
                .fields()
                .iter()
                .all(|fields| present(fields.get("remoteNebula")))
        }),
        "notice evidence records remote NebulaID metadata",
    );
    push_check(
        &mut checks,
        "device",
        lifecycle.is_some_and(|lifecycle| {
            lifecycle
                .fields()
                .iter()
                .all(|fields| present(fields.get("device")))
        }),
        "notice evidence records remote device identity",
    );
    push_check(
        &mut checks,
        "pqc_suite",
        lifecycle.is_some_and(|lifecycle| {
            lifecycle.fields().iter().all(|fields| {
                fields
                    .get("cryptoSuite")
                    .is_some_and(|value| concrete_quantum_safe_suite(value))
            })
        }),
        "notice evidence records a specific quantum-safe/PQC suite",
    );
    if require_panel {
        push_check(
            &mut checks,
            "panel_pending_top_center",
            pending_panel.is_some_and(panel_event_is_top_centered),
            "pending approval panel is rendered at the top center of the visible screen",
        );
        push_check(
            &mut checks,
            "panel_pending_buttons",
            pending_panel
                .is_some_and(|event| event_buttons_include(event, &["close", "reject", "approve"])),
            "pending approval panel exposes close, reject, and approve actions",
        );
        push_check(
            &mut checks,
            "panel_active_top_center",
            active_panel.is_some_and(panel_event_is_top_centered),
            "active remote-control panel remains at the top center of the visible screen",
        );
        push_check(
            &mut checks,
            "panel_active_buttons",
            active_panel
                .is_some_and(|event| event_buttons_include(event, &["close", "disconnect"])),
            "active remote-control panel exposes close and disconnect actions",
        );
        push_check(
            &mut checks,
            "panel_visible_until_disconnect",
            lifecycle.is_some_and(|lifecycle| panel_visible_until_disconnect(&evidence, lifecycle)),
            "active panel remains visible until the remote-control session disconnects",
        );
    }
    push_check(
        &mut checks,
        "fail_closed",
        !evidence.rejected && !evidence.timed_out,
        "approved lifecycle contains no reject or timeout event",
    );

    let passed = checks.iter().all(|check| check.passed);
    RemoteControlNoticeReportJson {
        schema_version: 1,
        transport: expected_transport,
        source,
        passed,
        checks,
    }
}

fn parse_notice_evidence(text: &str, expected_transport: &str) -> RemoteControlNoticeEvidence {
    let mut evidence = RemoteControlNoticeEvidence::default();
    for (ordinal, line) in text.lines().enumerate() {
        let Some(kind) = parse_event_kind(line) else {
            continue;
        };
        let fields = parse_fields(line);
        if fields
            .get("transport")
            .is_some_and(|transport| transport != expected_transport)
        {
            continue;
        }
        match kind {
            NoticeEventKind::Shown
            | NoticeEventKind::Approved
            | NoticeEventKind::Active
            | NoticeEventKind::Disconnected => {
                evidence.events.push(NoticeEvent {
                    kind,
                    fields,
                    ordinal,
                });
            }
            NoticeEventKind::Rejected => evidence.rejected = true,
            NoticeEventKind::TimedOut => evidence.timed_out = true,
            NoticeEventKind::PanelPresented => {
                evidence.panel_presented.push(NoticeEvent {
                    kind,
                    fields,
                    ordinal,
                });
            }
            NoticeEventKind::PanelHidden => {
                evidence.panel_hidden.push(NoticeEvent {
                    kind,
                    fields,
                    ordinal,
                });
            }
        }
    }
    evidence.lifecycle = find_ordered_lifecycle(&evidence.events);
    evidence
}

impl RemoteControlNoticeEvidence {
    fn has_kind(&self, kind: NoticeEventKind) -> bool {
        self.events.iter().any(|event| event.kind == kind)
    }
}

fn find_ordered_lifecycle(events: &[NoticeEvent]) -> Option<NoticeLifecycleEvidence> {
    let mut events_by_session: BTreeMap<String, Vec<&NoticeEvent>> = BTreeMap::new();
    for event in events {
        let Some(session_id) = event
            .fields
            .get("session")
            .filter(|value| present(Some(value)))
        else {
            continue;
        };
        events_by_session
            .entry(session_id.to_owned())
            .or_default()
            .push(event);
    }

    let mut candidates = Vec::new();
    for (_, mut session_events) in events_by_session {
        session_events.sort_by_key(|event| event.ordinal);
        let Some(shown) = first_event_after(&session_events, NoticeEventKind::Shown, None) else {
            continue;
        };
        let Some(approved) = first_event_after(
            &session_events,
            NoticeEventKind::Approved,
            Some(shown.ordinal),
        ) else {
            continue;
        };
        let Some(active) = first_event_after(
            &session_events,
            NoticeEventKind::Active,
            Some(approved.ordinal),
        ) else {
            continue;
        };
        let Some(disconnected) = first_event_after(
            &session_events,
            NoticeEventKind::Disconnected,
            Some(active.ordinal),
        ) else {
            continue;
        };
        candidates.push(NoticeLifecycleEvidence {
            shown: shown.clone(),
            approved: approved.clone(),
            active: active.clone(),
            disconnected: disconnected.clone(),
        });
    }

    candidates
        .into_iter()
        .max_by_key(|candidate| candidate.disconnected.ordinal)
}

fn first_event_after(
    events: &[&NoticeEvent],
    kind: NoticeEventKind,
    after_ordinal: Option<usize>,
) -> Option<NoticeEvent> {
    events
        .iter()
        .copied()
        .find(|event| {
            event.kind == kind && after_ordinal.is_none_or(|ordinal| event.ordinal > ordinal)
        })
        .cloned()
}

fn parse_event_kind(line: &str) -> Option<NoticeEventKind> {
    let marker = "remoteControlNotice";
    let start = line.find(marker)? + marker.len();
    let tail = &line[start..];
    match tail.split_whitespace().next()? {
        "Shown" => Some(NoticeEventKind::Shown),
        "Approved" => Some(NoticeEventKind::Approved),
        "Active" => Some(NoticeEventKind::Active),
        "Disconnected" => Some(NoticeEventKind::Disconnected),
        "Rejected" => Some(NoticeEventKind::Rejected),
        "TimedOut" => Some(NoticeEventKind::TimedOut),
        "PanelPresented" => Some(NoticeEventKind::PanelPresented),
        "PanelHidden" => Some(NoticeEventKind::PanelHidden),
        _ => None,
    }
}

fn panel_presented_for_phase<'a>(
    evidence: &'a RemoteControlNoticeEvidence,
    lifecycle: &NoticeLifecycleEvidence,
    phase: &str,
) -> Option<&'a NoticeEvent> {
    let session_id = lifecycle.shown.fields.get("session")?;
    evidence.panel_presented.iter().find(|event| {
        event
            .fields
            .get("session")
            .is_some_and(|value| value == session_id)
            && event
                .fields
                .get("phase")
                .is_some_and(|value| value == phase)
    })
}

fn panel_visible_until_disconnect(
    evidence: &RemoteControlNoticeEvidence,
    lifecycle: &NoticeLifecycleEvidence,
) -> bool {
    let Some(session_id) = lifecycle.shown.fields.get("session") else {
        return false;
    };
    let Some(active_panel) = panel_presented_for_phase(evidence, lifecycle, "active") else {
        return false;
    };
    if active_panel.ordinal >= lifecycle.disconnected.ordinal {
        return false;
    }
    evidence.panel_hidden.iter().any(|event| {
        event.ordinal > lifecycle.disconnected.ordinal
            && event
                .fields
                .get("session")
                .is_some_and(|value| value == session_id)
    })
}

fn panel_event_is_top_centered(event: &NoticeEvent) -> bool {
    if !event
        .fields
        .get("topCentered")
        .is_some_and(|value| value == "1" || value.eq_ignore_ascii_case("true"))
    {
        return false;
    }
    let Some(frame) = event
        .fields
        .get("frame")
        .and_then(|value| parse_rect(value))
    else {
        return false;
    };
    let Some(visible_frame) = event
        .fields
        .get("visibleFrame")
        .and_then(|value| parse_rect(value))
    else {
        return false;
    };
    let frame_mid_x = frame[0] + frame[2] / 2.0;
    let visible_mid_x = visible_frame[0] + visible_frame[2] / 2.0;
    let top_offset = visible_frame[1] + visible_frame[3] - (frame[1] + frame[3]);
    (frame_mid_x - visible_mid_x).abs() <= 2.0 && (0.0..=36.0).contains(&top_offset)
}

fn parse_rect(value: &str) -> Option<[f64; 4]> {
    let mut parts = value.split(',');
    let x = parts.next()?.parse().ok()?;
    let y = parts.next()?.parse().ok()?;
    let width = parts.next()?.parse().ok()?;
    let height = parts.next()?.parse().ok()?;
    if parts.next().is_some() || width <= 0.0 || height <= 0.0 {
        return None;
    }
    Some([x, y, width, height])
}

fn event_buttons_include(event: &NoticeEvent, required: &[&str]) -> bool {
    let Some(buttons) = event.fields.get("buttons") else {
        return false;
    };
    required.iter().all(|required_button| {
        buttons
            .split(',')
            .any(|button| button.eq_ignore_ascii_case(required_button))
    })
}

fn concrete_quantum_safe_suite(value: &str) -> bool {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed == "-" || trimmed == "missing" {
        return false;
    }
    let normalized = trimmed.to_ascii_lowercase().replace(['_', '+'], " ");
    !matches!(
        normalized.as_str(),
        "pqc"
            | "pqc secure channel"
            | "quantum safe"
            | "quantum-safe"
            | "post quantum"
            | "post-quantum"
    ) && (normalized.contains("x-wing")
        || normalized.contains("xwing")
        || normalized.contains("ml-kem")
        || normalized.contains("mlkem")
        || normalized.contains("0x0001")
        || normalized.contains("0x0101")
        || normalized.contains("0x0102"))
}

fn parse_fields(line: &str) -> BTreeMap<String, String> {
    line.split_whitespace()
        .filter_map(|part| {
            let (key, value) = part.split_once('=')?;
            Some((key.to_owned(), value.to_owned()))
        })
        .collect()
}

fn push_check(
    checks: &mut Vec<RemoteControlNoticeCheckJson>,
    name: &'static str,
    passed: bool,
    detail: &'static str,
) {
    checks.push(RemoteControlNoticeCheckJson {
        name,
        passed,
        detail: detail.to_owned(),
    });
}

fn present(value: Option<&String>) -> bool {
    value.is_some_and(|value| {
        let trimmed = value.trim();
        !trimmed.is_empty() && trimmed != "-" && trimmed != "missing"
    })
}

fn transport_label(transport: RemoteControlNoticeTransportArg) -> &'static str {
    match transport {
        RemoteControlNoticeTransportArg::P2p => "p2p",
        RemoteControlNoticeTransportArg::Webrtc => "webrtc",
    }
}

fn print_report_text(report: &RemoteControlNoticeReportJson) {
    println!("remote-control-notice check: {}", report.transport);
    println!("source: {}", report.source);
    for check in &report.checks {
        let status = if check.passed { "ok" } else { "failed" };
        println!("  - {}: {} ({})", check.name, status, check.detail);
    }
}

#[cfg(test)]
mod tests {
    use super::{RemoteControlNoticeTransportArg, analyze_remote_control_notice_text};

    #[test]
    fn notice_evidence_passes_for_complete_p2p_lifecycle() {
        let text = "\
remoteControlNoticeShown session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
remoteControlNoticePanelPresented session=s1 transport=p2p phase=awaitingApproval frame=280.0,794.0,760.0,188.0 visibleFrame=0.0,0.0,1320.0,1000.0 level=statusBar collectionBehavior=canJoinAllSpaces,fullScreenAuxiliary,transient topCentered=1 buttons=close,reject,approve
remoteControlNoticeApproved session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
remoteControlNoticeActive session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
remoteControlNoticePanelPresented session=s1 transport=p2p phase=active frame=280.0,828.0,760.0,154.0 visibleFrame=0.0,0.0,1320.0,1000.0 level=statusBar collectionBehavior=canJoinAllSpaces,fullScreenAuxiliary,transient topCentered=1 buttons=close,disconnect
remoteControlNoticeDisconnected session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
remoteControlNoticePanelHidden session=s1 transport=p2p phase=active
";
        let report = analyze_remote_control_notice_text(
            text,
            RemoteControlNoticeTransportArg::P2p,
            "fixture".to_owned(),
            true,
        );
        assert!(report.passed);
    }

    #[test]
    fn notice_evidence_fails_when_panel_evidence_is_missing() {
        let text = "\
remoteControlNoticeShown session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
remoteControlNoticeApproved session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
remoteControlNoticeActive session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
remoteControlNoticeDisconnected session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
";
        let report = analyze_remote_control_notice_text(
            text,
            RemoteControlNoticeTransportArg::P2p,
            "fixture".to_owned(),
            true,
        );
        assert!(!report.passed);
        assert!(
            report
                .checks
                .iter()
                .any(|check| { check.name == "panel_pending_top_center" && !check.passed })
        );
        assert!(
            report
                .checks
                .iter()
                .any(|check| check.name == "panel_active_buttons" && !check.passed)
        );
    }

    #[test]
    fn notice_evidence_fails_when_crypto_suite_is_generic_pqc_fallback() {
        let text = "\
remoteControlNoticeShown session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=PQC_secure_channel
remoteControlNoticePanelPresented session=s1 transport=p2p phase=awaitingApproval frame=280.0,794.0,760.0,188.0 visibleFrame=0.0,0.0,1320.0,1000.0 level=statusBar collectionBehavior=canJoinAllSpaces,fullScreenAuxiliary,transient topCentered=1 buttons=close,reject,approve
remoteControlNoticeApproved session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=PQC_secure_channel
remoteControlNoticeActive session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=PQC_secure_channel
remoteControlNoticePanelPresented session=s1 transport=p2p phase=active frame=280.0,828.0,760.0,154.0 visibleFrame=0.0,0.0,1320.0,1000.0 level=statusBar collectionBehavior=canJoinAllSpaces,fullScreenAuxiliary,transient topCentered=1 buttons=close,disconnect
remoteControlNoticeDisconnected session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=PQC_secure_channel
remoteControlNoticePanelHidden session=s1 transport=p2p phase=active
";
        let report = analyze_remote_control_notice_text(
            text,
            RemoteControlNoticeTransportArg::P2p,
            "fixture".to_owned(),
            true,
        );
        assert!(!report.passed);
        assert!(
            report
                .checks
                .iter()
                .any(|check| check.name == "pqc_suite" && !check.passed)
        );
    }

    #[test]
    fn notice_evidence_fails_when_nebula_id_is_missing() {
        let text = "\
remoteControlNoticeShown session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=alice remoteNebula=missing localAccount=mac localNebula=missing device=iPad cryptoSuite=ML-KEM_PQC
remoteControlNoticeApproved session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=alice remoteNebula=missing localAccount=mac localNebula=missing device=iPad cryptoSuite=ML-KEM_PQC
remoteControlNoticeActive session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=alice remoteNebula=missing localAccount=mac localNebula=missing device=iPad cryptoSuite=ML-KEM_PQC
remoteControlNoticeDisconnected session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=alice remoteNebula=missing localAccount=mac localNebula=missing device=iPad cryptoSuite=ML-KEM_PQC
";
        let report = analyze_remote_control_notice_text(
            text,
            RemoteControlNoticeTransportArg::Webrtc,
            "fixture".to_owned(),
            false,
        );
        assert!(!report.passed);
        assert!(
            report
                .checks
                .iter()
                .any(|check| check.name == "nebula_id" && !check.passed)
        );
    }

    #[test]
    fn notice_evidence_fails_when_only_local_identity_is_present() {
        let text = "\
remoteControlNoticeShown session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=missing remoteNebula=missing localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=ML-KEM_PQC
remoteControlNoticeApproved session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=missing remoteNebula=missing localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=ML-KEM_PQC
remoteControlNoticeActive session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=missing remoteNebula=missing localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=ML-KEM_PQC
remoteControlNoticeDisconnected session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=missing remoteNebula=missing localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=ML-KEM_PQC
";
        let report = analyze_remote_control_notice_text(
            text,
            RemoteControlNoticeTransportArg::Webrtc,
            "fixture".to_owned(),
            false,
        );
        assert!(!report.passed);
        assert!(
            report
                .checks
                .iter()
                .any(|check| check.name == "account" && !check.passed)
        );
        assert!(
            report
                .checks
                .iter()
                .any(|check| check.name == "nebula_id" && !check.passed)
        );
    }

    #[test]
    fn notice_evidence_fails_when_device_identity_is_missing() {
        let text = "\
remoteControlNoticeShown session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=missing cryptoSuite=X-Wing_PQC
remoteControlNoticeApproved session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=missing cryptoSuite=X-Wing_PQC
remoteControlNoticeActive session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=missing cryptoSuite=X-Wing_PQC
remoteControlNoticeDisconnected session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=missing cryptoSuite=X-Wing_PQC
";
        let report = analyze_remote_control_notice_text(
            text,
            RemoteControlNoticeTransportArg::P2p,
            "fixture".to_owned(),
            false,
        );
        assert!(!report.passed);
        assert!(
            report
                .checks
                .iter()
                .any(|check| check.name == "device" && !check.passed)
        );
    }

    #[test]
    fn notice_evidence_fails_when_lifecycle_events_cross_sessions() {
        let text = "\
remoteControlNoticeShown session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
remoteControlNoticeApproved session=s2 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
remoteControlNoticeActive session=s1 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
remoteControlNoticeDisconnected session=s2 transport=p2p remoteIP=192.0.2.1 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=X-Wing_PQC
";
        let report = analyze_remote_control_notice_text(
            text,
            RemoteControlNoticeTransportArg::P2p,
            "fixture".to_owned(),
            false,
        );
        assert!(!report.passed);
        assert!(
            report
                .checks
                .iter()
                .any(|check| check.name == "session_order" && !check.passed)
        );
    }

    #[test]
    fn notice_evidence_fails_when_lifecycle_order_is_reversed() {
        let text = "\
remoteControlNoticeApproved session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=ML-KEM_PQC
remoteControlNoticeShown session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=ML-KEM_PQC
remoteControlNoticeActive session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=ML-KEM_PQC
remoteControlNoticeDisconnected session=s1 transport=webrtc remoteIP=203.0.113.4 remoteAccount=alice remoteNebula=nebula-123 localAccount=mac localNebula=nebula-local device=iPad cryptoSuite=ML-KEM_PQC
";
        let report = analyze_remote_control_notice_text(
            text,
            RemoteControlNoticeTransportArg::Webrtc,
            "fixture".to_owned(),
            false,
        );
        assert!(!report.passed);
        assert!(
            report
                .checks
                .iter()
                .any(|check| check.name == "session_order" && !check.passed)
        );
    }
}
