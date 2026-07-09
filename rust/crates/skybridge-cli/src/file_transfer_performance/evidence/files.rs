use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use time::OffsetDateTime;

use crate::webrtc_media_parse::parse_webrtc_diagnostic_timestamp;

pub(super) struct FileTransferLogEntry {
    pub(super) is_mac: bool,
    pub(super) is_ios: bool,
    file_id: usize,
    line_index: usize,
    observed_at: Option<OffsetDateTime>,
    pub(super) line: String,
}

pub(super) struct FileTransferLogRead {
    pub(super) entries: Vec<FileTransferLogEntry>,
    pub(super) has_mac_log: bool,
    pub(super) has_ios_log: bool,
}

pub(super) fn file_transfer_performance_files(artifact_dir: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    let mut mac_status_log: Option<PathBuf> = None;
    let mut mac_stdout_log: Option<PathBuf> = None;
    for entry in fs::read_dir(artifact_dir)
        .with_context(|| format!("failed to read artifact dir {}", artifact_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        if name == "mac.status.log" {
            mac_status_log = Some(path);
        } else if name == "mac.stdout.log" {
            mac_stdout_log = Some(path);
        } else if is_file_transfer_ios_log(&path) {
            files.push(path);
        }
    }
    if let Some(path) = mac_status_log {
        files.push(path);
    } else if let Some(path) = mac_stdout_log {
        files.push(path);
    }
    files.sort();
    Ok(files)
}

pub(super) fn is_file_transfer_ios_log(path: &Path) -> bool {
    path.file_name()
        .and_then(|value| value.to_str())
        .is_some_and(|name| name.starts_with("ios-real-device-") && name.ends_with(".status.log"))
}

pub(super) fn read_file_transfer_logs(files: &[PathBuf]) -> Result<FileTransferLogRead> {
    let mut entries = Vec::new();
    let mut has_mac_log = false;
    let mut has_ios_log = false;
    for (file_id, path) in files.iter().enumerate() {
        let is_ios = is_file_transfer_ios_log(path);
        let is_mac = !is_ios;
        has_ios_log |= is_ios;
        has_mac_log |= is_mac;
        let file = File::open(path)
            .with_context(|| format!("failed to open file-transfer log {}", path.display()))?;
        for (line_index, line) in BufReader::new(file)
            .lines()
            .map_while(Result::ok)
            .enumerate()
        {
            let observed_at = parse_webrtc_diagnostic_timestamp(line.trim(), None);
            entries.push(FileTransferLogEntry {
                is_mac,
                is_ios,
                file_id,
                line_index,
                observed_at,
                line,
            });
        }
    }
    sort_file_transfer_log_entries_chronologically(&mut entries);
    Ok(FileTransferLogRead {
        entries,
        has_mac_log,
        has_ios_log,
    })
}

fn sort_file_transfer_log_entries_chronologically(entries: &mut [FileTransferLogEntry]) {
    entries.sort_by_key(|entry| {
        (
            entry.observed_at.is_none(),
            entry.observed_at,
            entry.file_id,
            entry.line_index,
        )
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(
        file_id: usize,
        line_index: usize,
        observed_at: Option<OffsetDateTime>,
    ) -> FileTransferLogEntry {
        FileTransferLogEntry {
            is_mac: file_id == 0,
            is_ios: file_id != 0,
            file_id,
            line_index,
            observed_at,
            line: format!("entry-{file_id}-{line_index}"),
        }
    }

    #[test]
    fn file_transfer_log_sort_uses_total_order_for_mixed_timestamps() {
        let early = OffsetDateTime::from_unix_timestamp(10).unwrap();
        let late = OffsetDateTime::from_unix_timestamp(20).unwrap();
        let mut entries = vec![
            entry(0, 0, Some(late)),
            entry(1, 0, None),
            entry(2, 0, Some(early)),
        ];

        sort_file_transfer_log_entries_chronologically(&mut entries);

        assert_eq!(
            entries
                .iter()
                .map(|entry| (entry.observed_at, entry.file_id, entry.line_index))
                .collect::<Vec<_>>(),
            vec![(Some(early), 2, 0), (Some(late), 0, 0), (None, 1, 0)]
        );
    }
}
