#[cfg(test)]
mod tests;

mod source_fragments;

pub(crate) fn cli_check_coverage_source() -> String {
    source_fragments::cli_rust_source_fragments()
        .chain(source_fragments::check_coverage_evidence_fragments())
        .map(|(_, source)| source)
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
pub(crate) fn cli_check_coverage_source_paths() -> impl Iterator<Item = &'static str> {
    source_fragments::cli_rust_source_fragments().map(|(path, _)| path)
}
