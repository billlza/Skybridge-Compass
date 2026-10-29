use super::super::CheckCoverageEntry;
use super::super::source::{SearchableCheckSource, source_has_all};

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    entries.push(CheckCoverageEntry {
        id: "coverage_threshold_gate",
        domain: "coverage",
        command: "skybridge check coverage --kind operator-check-surface --min-percent 88",
        covered: source_has_all(
            source,
            &[
                "CoverageKindArg::OperatorCheckSurface",
                "CheckSubcommand::Coverage(args)",
                "dispatch_covers_safe_placeholders_coverage_and_smoke_aliases",
                "CLI {} coverage failed",
            ],
        ),
        evidence: "this command fails when operator check-surface coverage is below the configured threshold; it is not code coverage".to_owned(),
    });
}
