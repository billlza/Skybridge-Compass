use time::OffsetDateTime;

use crate::performance_evidence::extract_text_f64;

#[derive(Debug, Clone, Copy, Default)]
pub(super) struct P2pRemotePassWindow {
    pub(super) start_at: Option<OffsetDateTime>,
    pub(super) end_at: Option<OffsetDateTime>,
    start_file_id: Option<usize>,
    start_line_index: Option<usize>,
    end_file_id: Option<usize>,
    end_line_index: Option<usize>,
    pub(super) window_seconds: Option<f64>,
    pub(super) requested_seconds: Option<f64>,
}

impl P2pRemotePassWindow {
    pub(super) fn start_position(self) -> Option<(usize, usize)> {
        self.start_file_id.zip(self.start_line_index)
    }

    pub(super) fn end_position(self) -> Option<(usize, usize)> {
        self.end_file_id.zip(self.end_line_index)
    }
}

pub(super) fn p2p_remote_latest_pass_window(
    ios_entries: &[(usize, usize, Option<OffsetDateTime>, String)],
) -> P2pRemotePassWindow {
    let Some(pass_index) = ios_entries
        .iter()
        .rposition(|(_, _, _, line)| line.contains("remote-desktop-pass "))
    else {
        return P2pRemotePassWindow::default();
    };
    let (pass_file_id, pass_line_index, pass_at, pass_line) = &ios_entries[pass_index];
    let start_entry = ios_entries[..=pass_index]
        .iter()
        .rposition(|(_, _, _, line)| line.contains("remote-desktop pass-window-start "))
        .map(|index| &ios_entries[index]);
    P2pRemotePassWindow {
        start_at: start_entry.and_then(|(_, _, observed_at, _)| *observed_at),
        end_at: *pass_at,
        start_file_id: start_entry.map(|(file_id, _, _, _)| *file_id),
        start_line_index: start_entry.map(|(_, line_index, _, _)| *line_index),
        end_file_id: Some(*pass_file_id),
        end_line_index: Some(*pass_line_index),
        window_seconds: extract_text_f64(pass_line, "windowSeconds")
            .or_else(|| extract_text_f64(pass_line, "seconds")),
        requested_seconds: extract_text_f64(pass_line, "requestedSeconds")
            .or_else(|| extract_text_f64(pass_line, "windowSeconds"))
            .or_else(|| extract_text_f64(pass_line, "seconds")),
    }
}
