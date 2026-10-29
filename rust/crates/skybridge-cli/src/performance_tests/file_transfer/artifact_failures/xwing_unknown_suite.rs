use super::*;

#[test]
fn file_transfer_artifact_rejects_plain_unknown_suite_line() {
    let mut evidence = FileTransferPerformanceEvidence::default();
    update_file_transfer_evidence(
        &mut evidence,
        "SecurityEvent unknown-suite stage=decode.messageA.supportedSuites wireId=0x9999",
        true,
        false,
    );
    update_file_transfer_evidence(
        &mut evidence,
        "suite peer=id:peer suite=X-Wing",
        true,
        false,
    );

    assert!(evidence.unknown_suite_rejected);
    assert!(evidence.xwing_suite_seen);
    let xwing = check_file_transfer_xwing(&evidence);
    assert!(!xwing.ok, "{}", xwing.detail);
    assert!(xwing.detail.contains("unknownSuiteRejected=true"));
}
