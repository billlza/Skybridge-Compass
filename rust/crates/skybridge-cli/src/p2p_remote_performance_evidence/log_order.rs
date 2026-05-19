use time::OffsetDateTime;

pub(super) type P2pRemoteLogEntry = (bool, bool, usize, usize, Option<OffsetDateTime>, String);

pub(super) fn sort_log_entries_chronologically(entries: &mut [P2pRemoteLogEntry]) {
    entries.sort_by(|left, right| match (left.4, right.4) {
        (Some(left_at), Some(right_at)) if left_at != right_at => left_at.cmp(&right_at),
        _ => left.2.cmp(&right.2).then_with(|| left.3.cmp(&right.3)),
    });
}
