use anyhow::{Result, bail};

pub(super) const CHECK_COVERAGE_ENTRY_CATALOG_SOURCES: &[(&str, &str)] = &[
    ("check_coverage/entries.rs", include_str!("entries.rs")),
    (
        "check_coverage/entries/control_plane.rs",
        include_str!("entries/control_plane.rs"),
    ),
    (
        "check_coverage/entries/coverage.rs",
        include_str!("entries/coverage.rs"),
    ),
    (
        "check_coverage/entries/memory.rs",
        include_str!("entries/memory.rs"),
    ),
    (
        "check_coverage/entries/performance.rs",
        include_str!("entries/performance.rs"),
    ),
    (
        "check_coverage/entries/performance/file_transfer.rs",
        include_str!("entries/performance/file_transfer.rs"),
    ),
    (
        "check_coverage/entries/performance/p2p_remote_artifact.rs",
        include_str!("entries/performance/p2p_remote_artifact.rs"),
    ),
    (
        "check_coverage/entries/performance/p2p_remote_media.rs",
        include_str!("entries/performance/p2p_remote_media.rs"),
    ),
    (
        "check_coverage/entries/performance/p2p_remote_realtime.rs",
        include_str!("entries/performance/p2p_remote_realtime.rs"),
    ),
    (
        "check_coverage/entries/performance/webrtc.rs",
        include_str!("entries/performance/webrtc.rs"),
    ),
    (
        "check_coverage/entries/smoke.rs",
        include_str!("entries/smoke.rs"),
    ),
];

#[derive(Debug)]
pub(super) struct SearchableCheckSource(String);

impl SearchableCheckSource {
    pub(super) fn as_str(&self) -> &str {
        &self.0
    }
}

pub(super) fn source_has_all(source: &SearchableCheckSource, needles: &[&str]) -> bool {
    needles
        .iter()
        .all(|needle| source.as_str().contains(needle))
}

pub(super) fn source_without_check_coverage_catalog(source: &str) -> Result<SearchableCheckSource> {
    let mut searchable = source.to_owned();
    let mut removed_entries_fragments = 0usize;
    for (path, fragment) in CHECK_COVERAGE_ENTRY_CATALOG_SOURCES {
        match source.matches(fragment).count() {
            0 => {}
            1 => {
                searchable = searchable.replace(fragment, "");
                removed_entries_fragments += 1;
            }
            _ => bail!("check coverage entries catalog fragment included more than once: {path}"),
        }
    }

    match (
        legacy_entries_start(&searchable),
        print_report_start(&searchable),
    ) {
        (Some(start), Some(end)) if start < end => {
            searchable.replace_range(start..end, "");
        }
        (Some(_), Some(_)) => bail!("check coverage legacy catalog markers are reversed"),
        (Some(_), None) => bail!("check coverage legacy catalog end marker is missing"),
        (None, _) if removed_entries_fragments == 0 => {
            bail!("check coverage entries catalog is missing")
        }
        (None, _) => {}
    }

    if removed_entries_fragments > 0
        && removed_entries_fragments != CHECK_COVERAGE_ENTRY_CATALOG_SOURCES.len()
    {
        bail!("check coverage entries catalog is incomplete");
    }
    if legacy_entries_start(&searchable).is_some() {
        bail!("check coverage entries catalog was not fully removed");
    }
    Ok(SearchableCheckSource(searchable))
}

fn legacy_entries_start(source: &str) -> Option<usize> {
    line_start_index(source, "fn quality_check_coverage_entries")
        .or_else(|| line_start_index(source, "pub(super) fn quality_check_coverage_entries"))
}

fn print_report_start(source: &str) -> Option<usize> {
    line_start_index(source, "fn print_check_coverage_report")
}

fn line_start_index(source: &str, needle: &str) -> Option<usize> {
    source.match_indices(needle).find_map(|(idx, _)| {
        if idx == 0 || source.as_bytes().get(idx.wrapping_sub(1)) == Some(&b'\n') {
            Some(idx)
        } else {
            None
        }
    })
}

#[cfg(test)]
mod tests {
    use super::super::check_source_catalog;
    use super::super::entries::quality_check_coverage_entries;
    use super::*;

    fn entries_catalog_source() -> String {
        CHECK_COVERAGE_ENTRY_CATALOG_SOURCES
            .iter()
            .map(|(_, source)| *source)
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn check_coverage_entries_source_does_not_self_cover() -> Result<()> {
        let entries_source = entries_catalog_source();
        let searchable_source = source_without_check_coverage_catalog(&entries_source)?;
        let checks = quality_check_coverage_entries(&searchable_source);

        assert!(
            checks.iter().all(|entry| !entry.covered),
            "entries.rs needle catalog must not satisfy itself"
        );
        Ok(())
    }

    #[test]
    fn source_without_check_coverage_catalog_fails_closed_on_reversed_legacy_markers() {
        let source = "fn print_check_coverage_report() {}\n\
            fn quality_check_coverage_entries() { \"fake_pid_field\" \"fake_memory_ok\" \"fake_timeout_runner\" }";

        assert!(source_without_check_coverage_catalog(source).is_err());
    }

    #[test]
    fn source_without_check_coverage_catalog_removes_entries_source() -> Result<()> {
        let entries_source = entries_catalog_source();
        let source = format!("before\n{entries_source}\nafter");
        let searchable = source_without_check_coverage_catalog(&source)?;

        assert!(searchable.as_str().contains("before"));
        assert!(searchable.as_str().contains("after"));
        assert!(!searchable.as_str().contains("memory_leak_pid_scan"));
        Ok(())
    }

    #[test]
    fn source_without_check_coverage_catalog_fails_closed_on_duplicate_entries_source() {
        let entries_source = entries_catalog_source();
        let source = format!("{entries_source}\n{entries_source}");

        assert!(source_without_check_coverage_catalog(&source).is_err());
    }

    #[test]
    fn source_without_check_coverage_catalog_fails_closed_on_incomplete_entries_source() {
        let incomplete_entries_source = CHECK_COVERAGE_ENTRY_CATALOG_SOURCES
            .iter()
            .take(CHECK_COVERAGE_ENTRY_CATALOG_SOURCES.len() - 1)
            .map(|(_, source)| *source)
            .collect::<Vec<_>>()
            .join("\n");

        assert!(source_without_check_coverage_catalog(&incomplete_entries_source).is_err());
    }

    #[test]
    fn source_without_check_coverage_catalog_fails_closed_on_missing_legacy_end_marker() {
        let source = "fn quality_check_coverage_entries() { \"fake_pid_field\" }\n\
            fn unrelated_function() {}";

        assert!(source_without_check_coverage_catalog(source).is_err());
    }

    #[test]
    fn source_without_check_coverage_catalog_fails_closed_on_missing_entries_catalog() {
        let source = "fn print_check_coverage_report() {}";

        assert!(source_without_check_coverage_catalog(source).is_err());
    }

    #[test]
    fn cli_check_coverage_source_strips_entries_catalog_before_entries_scan() -> Result<()> {
        let source = check_source_catalog::cli_check_coverage_source();
        let searchable = source_without_check_coverage_catalog(&source)?;

        for (_, fragment) in CHECK_COVERAGE_ENTRY_CATALOG_SOURCES {
            assert!(!searchable.as_str().contains(fragment));
        }
        assert!(legacy_entries_start(searchable.as_str()).is_none());
        assert!(
            quality_check_coverage_entries(&searchable)
                .iter()
                .any(|entry| { entry.id == "coverage_threshold_gate" && entry.covered })
        );
        Ok(())
    }

    #[test]
    fn check_source_catalog_includes_entries_once() {
        let catalog_paths = check_source_catalog::cli_check_coverage_source_paths()
            .map(str::to_owned)
            .collect::<Vec<_>>();

        for &(include_path, _) in CHECK_COVERAGE_ENTRY_CATALOG_SOURCES {
            assert_eq!(
                catalog_paths
                    .iter()
                    .filter(|path| path.as_str() == include_path)
                    .count(),
                1,
                "{include_path} should be included once"
            );
        }
    }
}
