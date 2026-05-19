use super::super::CheckCoverageEntry;
use super::super::source::SearchableCheckSource;

mod file_transfer;
mod p2p_remote_artifact;
mod p2p_remote_media;
mod p2p_remote_realtime;
mod webrtc;

const PERFORMANCE_ENTRY_COUNT: usize = 14;

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    let start_len = entries.len();
    webrtc::append_entries(source, entries);
    p2p_remote_artifact::append_entries(source, entries);
    file_transfer::append_entries(source, entries);
    p2p_remote_realtime::append_entries(source, entries);
    p2p_remote_media::append_entries(source, entries);
    debug_assert_eq!(entries.len() - start_len, PERFORMANCE_ENTRY_COUNT);
}
