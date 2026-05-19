use super::CheckCoverageEntry;
use super::source::SearchableCheckSource;

mod control_plane;
mod coverage;
mod memory;
mod performance;
mod smoke;

const CHECK_COVERAGE_ENTRY_COUNT: usize = 24;

pub(super) fn quality_check_coverage_entries(
    source: &SearchableCheckSource,
) -> Vec<CheckCoverageEntry> {
    let mut entries = Vec::with_capacity(CHECK_COVERAGE_ENTRY_COUNT);
    memory::append_entries(source, &mut entries);
    performance::append_entries(source, &mut entries);
    smoke::append_entries(source, &mut entries);
    control_plane::append_entries(source, &mut entries);
    coverage::append_entries(source, &mut entries);
    debug_assert_eq!(entries.len(), CHECK_COVERAGE_ENTRY_COUNT);
    entries
}
