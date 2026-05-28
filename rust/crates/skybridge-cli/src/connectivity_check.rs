use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};

use crate::{
    ConnectivityCheckArgs, DoctorCheck, DoctorProbeReport, ensure_probe_report_passed,
    print_doctor_probe_report, simple_doctor_check,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PeerProfile {
    XWing,
    Pqc,
    Classic,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SuiteExpectation {
    XWing,
    PqcWithoutXWing,
    Classic,
}

#[derive(Debug, Clone, Copy)]
struct RequiredConnectivityCase {
    id: &'static str,
    check_name: &'static str,
    initiator_profile: PeerProfile,
    responder_profile: PeerProfile,
    expected_suite: SuiteExpectation,
    require_pinned_identity: bool,
    require_classic_fallback_allowed: bool,
}

const REQUIRED_CONNECTIVITY_CASES: &[RequiredConnectivityCase] = &[
    RequiredConnectivityCase {
        id: "mac-ios-xwing-xwing",
        check_name: "connectivity_mac_ios_xwing_xwing",
        initiator_profile: PeerProfile::XWing,
        responder_profile: PeerProfile::XWing,
        expected_suite: SuiteExpectation::XWing,
        require_pinned_identity: true,
        require_classic_fallback_allowed: false,
    },
    RequiredConnectivityCase {
        id: "mac-ios-xwing-pqc",
        check_name: "connectivity_mac_ios_xwing_pqc",
        initiator_profile: PeerProfile::XWing,
        responder_profile: PeerProfile::Pqc,
        expected_suite: SuiteExpectation::PqcWithoutXWing,
        require_pinned_identity: true,
        require_classic_fallback_allowed: false,
    },
    RequiredConnectivityCase {
        id: "mac-ios-pqc-xwing",
        check_name: "connectivity_mac_ios_pqc_xwing",
        initiator_profile: PeerProfile::Pqc,
        responder_profile: PeerProfile::XWing,
        expected_suite: SuiteExpectation::PqcWithoutXWing,
        require_pinned_identity: true,
        require_classic_fallback_allowed: false,
    },
    RequiredConnectivityCase {
        id: "mac-ios-pqc-classic",
        check_name: "connectivity_mac_ios_pqc_classic",
        initiator_profile: PeerProfile::Pqc,
        responder_profile: PeerProfile::Classic,
        expected_suite: SuiteExpectation::Classic,
        require_pinned_identity: false,
        require_classic_fallback_allowed: true,
    },
    RequiredConnectivityCase {
        id: "mac-ios-classic-pqc",
        check_name: "connectivity_mac_ios_classic_pqc",
        initiator_profile: PeerProfile::Classic,
        responder_profile: PeerProfile::Pqc,
        expected_suite: SuiteExpectation::Classic,
        require_pinned_identity: false,
        require_classic_fallback_allowed: true,
    },
];

#[derive(Debug, Clone)]
struct ConnectivityCaseEvidence {
    id: String,
    direction: String,
    initiator: String,
    responder: String,
    initiator_profile: PeerProfile,
    responder_profile: PeerProfile,
    selected_suite: String,
    policy: String,
    result: String,
    stable_protocol_identity: bool,
    pinned_protocol_identity: bool,
    classic_fallback_allowed: bool,
    source: String,
}

#[derive(Debug, Default)]
struct ConnectivityEvidence {
    file_count: usize,
    has_mac_log: bool,
    has_ios_log: bool,
    cases: BTreeMap<String, ConnectivityCaseEvidence>,
    hidden_failure_count: u64,
    first_hidden_failure: Option<String>,
}

pub(crate) async fn check_connectivity(args: ConnectivityCheckArgs) -> Result<()> {
    let as_json = args.output.json;
    let report = build_connectivity_check_report(&args)?;
    print_doctor_probe_report(&report, as_json)?;
    ensure_probe_report_passed(&report, "connectivity check failed")
}

pub(crate) fn build_connectivity_check_report(
    args: &ConnectivityCheckArgs,
) -> Result<DoctorProbeReport> {
    let evidence = read_connectivity_evidence(&args.artifact_dir)?;
    let mut checks = vec![
        check_connectivity_sources(&evidence),
        check_connectivity_no_hidden_failure(&evidence),
        check_connectivity_matrix_surface(&evidence),
        check_connectivity_stable_protocol_identity(&evidence),
        check_connectivity_no_unexpected_downgrade(&evidence),
    ];
    checks.extend(
        REQUIRED_CONNECTIVITY_CASES
            .iter()
            .map(|spec| check_required_connectivity_case(&evidence, spec)),
    );

    Ok(DoctorProbeReport {
        target: format!("connectivity artifact={}", args.artifact_dir.display()),
        fault_stage: classify_connectivity_fault_stage(&evidence),
        checks,
        latest_diagnostic_at: None,
        latest_video_evidence_at: None,
        latest_receiver_evidence_at: None,
        latest_audio_tx_evidence_at: None,
        latest_audio_rx_evidence_at: None,
    })
}

fn classify_connectivity_fault_stage(evidence: &ConnectivityEvidence) -> Option<&'static str> {
    if let Some(failure) = evidence.first_hidden_failure.as_deref() {
        let lower = failure.to_ascii_lowercase();
        if lower.contains("missing_stable_protocol_identity")
            || lower.contains("endpoint-only peer")
        {
            return Some("connectivity_missing_stable_protocol_identity");
        }
        if lower.contains("connection refused") || lower.contains("nwerror错误61") {
            return Some("connectivity_connection_refused");
        }
        if lower.contains("already_connected") || lower.contains("rejectalreadyconnected") {
            return Some("connectivity_already_connected_rejection");
        }
        return Some("connectivity_hidden_failure");
    }

    if REQUIRED_CONNECTIVITY_CASES
        .iter()
        .any(|spec| !case_passes(evidence.cases.get(spec.id), spec))
    {
        return Some("connectivity_matrix_incomplete");
    }

    None
}

fn read_connectivity_evidence(artifact_dir: &Path) -> Result<ConnectivityEvidence> {
    let files = connectivity_log_files(artifact_dir)?;
    if files.is_empty() {
        bail!(
            "no connectivity logs found in {}; expected .log/.status/.txt evidence files",
            artifact_dir.display()
        );
    }

    let mut evidence = ConnectivityEvidence {
        file_count: files.len(),
        ..Default::default()
    };

    for file in files {
        let content = fs::read_to_string(&file)
            .with_context(|| format!("failed to read connectivity log {}", file.display()))?;
        let file_name = file
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        if file_name.contains("mac") {
            evidence.has_mac_log = true;
        }
        if file_name.contains("ios") || file_name.contains("iphone") || file_name.contains("ipad") {
            evidence.has_ios_log = true;
        }
        for (line_index, line) in content.lines().enumerate() {
            update_connectivity_evidence(
                &mut evidence,
                line,
                &format!("{}:{}", file.display(), line_index + 1),
            );
        }
    }

    Ok(evidence)
}

fn connectivity_log_files(artifact_dir: &Path) -> Result<Vec<PathBuf>> {
    if !artifact_dir.is_dir() {
        return Err(anyhow!(
            "connectivity artifact dir does not exist: {}",
            artifact_dir.display()
        ));
    }

    let mut files = Vec::new();
    collect_connectivity_log_files(artifact_dir, &mut files)?;
    files.sort();
    Ok(files)
}

fn collect_connectivity_log_files(dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(dir).with_context(|| format!("failed to read {}", dir.display()))? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_connectivity_log_files(&path, files)?;
        } else if is_connectivity_log_file(&path) {
            files.push(path);
        }
    }
    Ok(())
}

fn is_connectivity_log_file(path: &Path) -> bool {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    name.ends_with(".log") || name.ends_with(".status") || name.ends_with(".txt")
}

fn update_connectivity_evidence(evidence: &mut ConnectivityEvidence, line: &str, source: &str) {
    if let Some(reason) = hidden_connectivity_failure_reason(line) {
        evidence.hidden_failure_count += 1;
        evidence
            .first_hidden_failure
            .get_or_insert_with(|| format!("{source} {reason}: {line}"));
    }

    let Some(case) = parse_connectivity_case_line(line, source) else {
        return;
    };

    if case.initiator == "mac" || case.responder == "mac" {
        evidence.has_mac_log = true;
    }
    if case.initiator == "ios" || case.responder == "ios" {
        evidence.has_ios_log = true;
    }
    evidence.cases.insert(case.id.clone(), case);
}

fn hidden_connectivity_failure_reason(line: &str) -> Option<&'static str> {
    let lower = line.to_ascii_lowercase();
    if lower.contains("missing_stable_protocol_identity")
        || lower.contains("strict pqc inbound-handshake rejected endpoint-only peer")
    {
        return Some("endpoint-only strict PQC rejection");
    }
    if lower.contains("connection refused") || lower.contains("nwerror错误61") {
        return Some("connection refused");
    }
    if lower.contains("already_connected") || lower.contains("rejectalreadyconnected") {
        return Some("remote desktop already_connected rejection");
    }
    if lower.contains("no symbol named") {
        return Some("missing system symbol");
    }
    if lower.contains("connectivity-case")
        && lower.contains("result=failure")
        && !lower.contains("expectedfailure=1")
    {
        return Some("connectivity case failure");
    }
    None
}

fn parse_connectivity_case_line(line: &str, source: &str) -> Option<ConnectivityCaseEvidence> {
    let marker = "connectivity-case";
    let start = line.find(marker)?;
    let fields = parse_key_value_fields(&line[start + marker.len()..]);
    let id = fields.get("id")?.to_owned();

    Some(ConnectivityCaseEvidence {
        id,
        direction: normalized_field(fields.get("direction")),
        initiator: normalized_field(fields.get("initiator")),
        responder: normalized_field(fields.get("responder")),
        initiator_profile: parse_peer_profile(
            fields
                .get("initiatorProfile")
                .or_else(|| fields.get("initiator_profile")),
        ),
        responder_profile: parse_peer_profile(
            fields
                .get("responderProfile")
                .or_else(|| fields.get("responder_profile")),
        ),
        selected_suite: fields
            .get("selectedSuite")
            .or_else(|| fields.get("selected_suite"))
            .cloned()
            .unwrap_or_default(),
        policy: normalized_field(fields.get("policy")),
        result: normalized_field(fields.get("result")),
        stable_protocol_identity: parse_bool_field(
            fields
                .get("stableProtocolIdentity")
                .or_else(|| fields.get("stable_protocol_identity")),
        ),
        pinned_protocol_identity: parse_bool_field(
            fields
                .get("pinnedProtocolIdentity")
                .or_else(|| fields.get("pinned_protocol_identity")),
        ),
        classic_fallback_allowed: parse_bool_field(
            fields
                .get("classicFallbackAllowed")
                .or_else(|| fields.get("classic_fallback_allowed")),
        ),
        source: source.to_owned(),
    })
}

fn parse_key_value_fields(input: &str) -> BTreeMap<String, String> {
    input
        .split_whitespace()
        .filter_map(|token| {
            let (key, value) = token.split_once('=')?;
            let value = value.trim_matches(|ch| ch == ',' || ch == ';' || ch == '"');
            Some((key.to_owned(), value.to_owned()))
        })
        .collect()
}

fn normalized_field(value: Option<&String>) -> String {
    value
        .map(|value| {
            value
                .trim()
                .trim_matches(|ch| ch == '"' || ch == ',' || ch == ';')
                .to_ascii_lowercase()
        })
        .unwrap_or_default()
}

fn parse_bool_field(value: Option<&String>) -> bool {
    matches!(
        normalized_field(value).as_str(),
        "1" | "true" | "yes" | "ok" | "pass" | "passed"
    )
}

fn parse_peer_profile(value: Option<&String>) -> PeerProfile {
    match normalized_field(value).replace(['_', '-'], "").as_str() {
        "xwing" | "pqcxwing" | "hybridxwing" => PeerProfile::XWing,
        "pqc" | "mlkem" | "mlkem768" | "postquantum" => PeerProfile::Pqc,
        "classic" | "p256" | "x25519" | "legacyclassic" => PeerProfile::Classic,
        _ => PeerProfile::Unknown,
    }
}

fn suite_matches_expectation(selected_suite: &str, expectation: SuiteExpectation) -> bool {
    let normalized = selected_suite
        .trim()
        .to_ascii_lowercase()
        .replace(['_', '-'], "");
    match expectation {
        SuiteExpectation::XWing => normalized.contains("xwing"),
        SuiteExpectation::PqcWithoutXWing => {
            !normalized.contains("xwing")
                && (normalized.contains("mlkem")
                    || normalized.contains("pqc")
                    || normalized.contains("mldsa"))
        }
        SuiteExpectation::Classic => {
            normalized.contains("classic")
                || normalized.contains("p256")
                || normalized.contains("x25519")
        }
    }
}

fn case_passes(case: Option<&ConnectivityCaseEvidence>, spec: &RequiredConnectivityCase) -> bool {
    let Some(case) = case else {
        return false;
    };

    case.direction == "mac-to-ios"
        && case.initiator == "mac"
        && case.responder == "ios"
        && case.initiator_profile == spec.initiator_profile
        && case.responder_profile == spec.responder_profile
        && case.result == "success"
        && case.stable_protocol_identity
        && (!spec.require_pinned_identity || case.pinned_protocol_identity)
        && (!spec.require_classic_fallback_allowed || case.classic_fallback_allowed)
        && suite_matches_expectation(&case.selected_suite, spec.expected_suite)
}

fn check_connectivity_sources(evidence: &ConnectivityEvidence) -> DoctorCheck {
    let ok = evidence.file_count > 0 && evidence.has_mac_log && evidence.has_ios_log;
    simple_doctor_check(
        "connectivity_sources",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "files={} macLog={} iosLog={} cases={}",
            evidence.file_count,
            evidence.has_mac_log,
            evidence.has_ios_log,
            evidence.cases.len()
        ),
    )
}

fn check_connectivity_no_hidden_failure(evidence: &ConnectivityEvidence) -> DoctorCheck {
    let ok = evidence.hidden_failure_count == 0;
    simple_doctor_check(
        "connectivity_no_hidden_failure",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "hiddenFailureCount={} firstHiddenFailure={}",
            evidence.hidden_failure_count,
            evidence.first_hidden_failure.as_deref().unwrap_or("-")
        ),
    )
}

fn check_connectivity_matrix_surface(evidence: &ConnectivityEvidence) -> DoctorCheck {
    let missing = REQUIRED_CONNECTIVITY_CASES
        .iter()
        .filter(|spec| !evidence.cases.contains_key(spec.id))
        .map(|spec| spec.id)
        .collect::<Vec<_>>();
    let ok = missing.is_empty();
    simple_doctor_check(
        "connectivity_matrix_surface",
        ok,
        if ok { "info" } else { "error" },
        if ok {
            format!(
                "connectivity matrix covers required cases: {}",
                REQUIRED_CONNECTIVITY_CASES
                    .iter()
                    .map(|spec| spec.id)
                    .collect::<Vec<_>>()
                    .join(",")
            )
        } else {
            format!("connectivity matrix missing cases: {}", missing.join(","))
        },
    )
}

fn check_connectivity_stable_protocol_identity(evidence: &ConnectivityEvidence) -> DoctorCheck {
    let missing = REQUIRED_CONNECTIVITY_CASES
        .iter()
        .filter_map(|spec| {
            let case = evidence.cases.get(spec.id)?;
            if !case.stable_protocol_identity
                || (spec.require_pinned_identity && !case.pinned_protocol_identity)
            {
                Some(spec.id)
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    let ok = missing.is_empty()
        && REQUIRED_CONNECTIVITY_CASES
            .iter()
            .all(|spec| evidence.cases.contains_key(spec.id));
    simple_doctor_check(
        "connectivity_stable_protocol_identity",
        ok,
        if ok { "info" } else { "error" },
        if ok {
            "all required Mac->iOS cases have stable protocol identity evidence; strict PQC cases also have pinned protocol identity".to_owned()
        } else {
            format!(
                "missing stable/pinned protocol identity evidence for cases: {}",
                missing.join(",")
            )
        },
    )
}

fn check_connectivity_no_unexpected_downgrade(evidence: &ConnectivityEvidence) -> DoctorCheck {
    let downgraded = REQUIRED_CONNECTIVITY_CASES
        .iter()
        .filter_map(|spec| {
            let case = evidence.cases.get(spec.id)?;
            if suite_matches_expectation(&case.selected_suite, spec.expected_suite)
                && (!spec.require_classic_fallback_allowed || case.classic_fallback_allowed)
            {
                None
            } else {
                Some(format!(
                    "{} selectedSuite={} classicFallbackAllowed={} policy={}",
                    spec.id, case.selected_suite, case.classic_fallback_allowed, case.policy
                ))
            }
        })
        .collect::<Vec<_>>();
    let ok = downgraded.is_empty()
        && REQUIRED_CONNECTIVITY_CASES
            .iter()
            .all(|spec| evidence.cases.contains_key(spec.id));
    simple_doctor_check(
        "connectivity_no_unexpected_downgrade",
        ok,
        if ok { "info" } else { "error" },
        if ok {
            "required asymmetric PQC/X-Wing cases stay PQC and PQC/classic cases downgrade only through explicit classic interop policy".to_owned()
        } else {
            format!(
                "unexpected suite/policy selection: {}",
                downgraded.join(" | ")
            )
        },
    )
}

fn check_required_connectivity_case(
    evidence: &ConnectivityEvidence,
    spec: &RequiredConnectivityCase,
) -> DoctorCheck {
    let case = evidence.cases.get(spec.id);
    let ok = case_passes(case, spec);
    simple_doctor_check(
        spec.check_name,
        ok,
        if ok { "info" } else { "error" },
        match case {
            Some(case) => format!(
                "direction={} initiator={} responder={} initiatorProfile={:?} responderProfile={:?} selectedSuite={} result={} stableProtocolIdentity={} pinnedProtocolIdentity={} classicFallbackAllowed={} source={}",
                case.direction,
                case.initiator,
                case.responder,
                case.initiator_profile,
                case.responder_profile,
                case.selected_suite,
                case.result,
                case.stable_protocol_identity,
                case.pinned_protocol_identity,
                case.classic_fallback_allowed,
                case.source
            ),
            None => format!("missing required connectivity case id={}", spec.id),
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::OutputOptions;
    use crate::cli_test_support::{doctor_check, fixture_dir, make_test_dir};

    fn args_for(artifact_dir: PathBuf) -> ConnectivityCheckArgs {
        ConnectivityCheckArgs {
            artifact_dir,
            output: OutputOptions { json: false },
        }
    }

    #[test]
    fn connectivity_matrix_fixture_passes() -> Result<()> {
        let report = build_connectivity_check_report(&args_for(fixture_dir(&[
            "connectivity",
            "mac-ios-matrix-pass",
        ])))?;

        for check in &report.checks {
            assert!(check.ok, "{}: {}", check.name, check.detail);
        }
        assert_eq!(report.fault_stage, None);
        Ok(())
    }

    #[test]
    fn connectivity_matrix_rejects_endpoint_only_inbound_failure() -> Result<()> {
        let dir = make_test_dir("connectivity-endpoint-only")?;
        fs::write(
            dir.join("mac.status.log"),
            include_str!("../tests/fixtures/connectivity/mac-ios-matrix-pass/mac.status.log"),
        )?;
        fs::write(
            dir.join("ios.status.log"),
            "[16:10:20.542] [WARNING] ⛔️ strict PQC inbound-handshake rejected endpoint-only peer: peer=host:fe80::bcd0 reason=missing_stable_protocol_identity\n",
        )?;

        let report = build_connectivity_check_report(&args_for(dir))?;
        let hidden = doctor_check(&report, "connectivity_no_hidden_failure");

        assert!(!hidden.ok);
        assert_eq!(
            report.fault_stage,
            Some("connectivity_missing_stable_protocol_identity")
        );
        assert!(hidden.detail.contains("missing_stable_protocol_identity"));
        Ok(())
    }

    #[test]
    fn connectivity_matrix_rejects_already_connected_rejection() -> Result<()> {
        let dir = make_test_dir("connectivity-already-connected")?;
        fs::write(
            dir.join("mac.status.log"),
            include_str!("../tests/fixtures/connectivity/mac-ios-matrix-pass/mac.status.log"),
        )?;
        fs::write(
            dir.join("ios.status.log"),
            "[17:17:23.823] [ERROR] [General] ❌ 远程桌面连接失败: 对端拒绝连接：already_connected\n",
        )?;

        let report = build_connectivity_check_report(&args_for(dir))?;
        let hidden = doctor_check(&report, "connectivity_no_hidden_failure");

        assert!(!hidden.ok);
        assert_eq!(
            report.fault_stage,
            Some("connectivity_already_connected_rejection")
        );
        assert!(hidden.detail.contains("already_connected"));
        Ok(())
    }

    #[test]
    fn connectivity_matrix_rejects_missing_asymmetric_case() -> Result<()> {
        let dir = make_test_dir("connectivity-missing-case")?;
        let mut mac_log =
            include_str!("../tests/fixtures/connectivity/mac-ios-matrix-pass/mac.status.log")
                .to_owned();
        mac_log = mac_log
            .lines()
            .filter(|line| !line.contains("id=mac-ios-classic-pqc"))
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(dir.join("mac.status.log"), mac_log)?;
        fs::write(dir.join("ios.status.log"), "ios connectivity boot\n")?;

        let report = build_connectivity_check_report(&args_for(dir))?;
        let surface = doctor_check(&report, "connectivity_matrix_surface");

        assert!(!surface.ok);
        assert!(surface.detail.contains("mac-ios-classic-pqc"));
        assert_eq!(report.fault_stage, Some("connectivity_matrix_incomplete"));
        Ok(())
    }

    #[test]
    fn connectivity_matrix_rejects_classic_downgrade_for_xwing_pqc() -> Result<()> {
        let dir = make_test_dir("connectivity-unexpected-downgrade")?;
        let mac_log =
            include_str!("../tests/fixtures/connectivity/mac-ios-matrix-pass/mac.status.log")
                .replace(
                    "id=mac-ios-xwing-pqc direction=mac-to-ios initiator=mac responder=ios initiatorProfile=xwing responderProfile=pqc policy=strict_pqc selectedSuite=ML-KEM-768 stableProtocolIdentity=1 pinnedProtocolIdentity=1 classicFallbackAllowed=0 result=success",
                    "id=mac-ios-xwing-pqc direction=mac-to-ios initiator=mac responder=ios initiatorProfile=xwing responderProfile=pqc policy=strict_pqc selectedSuite=P-256 stableProtocolIdentity=1 pinnedProtocolIdentity=1 classicFallbackAllowed=0 result=success",
                );
        fs::write(dir.join("mac.status.log"), mac_log)?;
        fs::write(dir.join("ios.status.log"), "ios connectivity boot\n")?;

        let report = build_connectivity_check_report(&args_for(dir))?;
        let downgrade = doctor_check(&report, "connectivity_no_unexpected_downgrade");
        let xwing_pqc = doctor_check(&report, "connectivity_mac_ios_xwing_pqc");

        assert!(!downgrade.ok);
        assert!(!xwing_pqc.ok);
        assert!(downgrade.detail.contains("mac-ios-xwing-pqc"));
        Ok(())
    }
}
