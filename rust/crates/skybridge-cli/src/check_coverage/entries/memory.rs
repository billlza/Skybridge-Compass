use super::super::CheckCoverageEntry;
use super::super::source::{SearchableCheckSource, source_has_all};

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    entries.push(CheckCoverageEntry {
        id: "memory_leak_pid_scan",
        domain: "memory",
        command: "skybridge check memory --pid <pid>",
        covered: source_has_all(
            source,
            &[
                "pid: Option<u32>",
                "memory_no_leaks",
                "run_command_with_timeout",
            ],
        ),
        evidence: "wraps macOS leaks against a live process and fails on non-zero leaks verdict"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "memory_leak_launched_process_scan",
        domain: "memory",
        command: "skybridge check memory --executable <path> --arg <arg>",
        covered: source_has_all(
            source,
            &[
                "executable: Option<PathBuf>",
                "command.arg(\"--atExit\")",
                "executable_args",
            ],
        ),
        evidence: "wraps leaks --atExit for command-scoped leak scans".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "memory_leak_timeout_gate",
        domain: "memory",
        command: "skybridge check memory --timeout-seconds 60",
        covered: source_has_all(
            source,
            &[
                "timeout_seconds",
                "timedOut={}",
                "memory_check_times_out_and_fails_without_fake_no_leaks",
            ],
        ),
        evidence: "kills hung leak scans and reports no verdict instead of hanging or passing"
            .to_owned(),
    });
}
