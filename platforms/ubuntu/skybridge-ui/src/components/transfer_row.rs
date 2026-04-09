//! Transfer Row Component

use gtk4::prelude::*;
use gtk4::{self as gtk};

use skybridge_core::transfer::{FileTransfer, TransferState};

/// Transfer row widget
pub struct TransferRow {
    /// Root widget
    pub widget: gtk::Box,
    /// Progress bar
    progress_bar: gtk::ProgressBar,
    /// Status label
    status_label: gtk::Label,
}

impl TransferRow {
    /// Create a new transfer row
    pub fn new(transfer: &FileTransfer) -> Self {
        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(6)
            .margin_start(12)
            .margin_end(12)
            .margin_top(6)
            .margin_bottom(6)
            .css_classes(vec!["transfer-row".to_string()])
            .build();

        // Header with icon and filename
        let header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(10)
            .build();

        let filename = gtk::Label::builder()
            .label(&transfer.metadata.name)
            .halign(gtk::Align::Start)
            .hexpand(true)
            .ellipsize(gtk::pango::EllipsizeMode::Middle)
            .css_classes(vec!["transfer-filename".to_string()])
            .build();
        header.append(&filename);

        let status_label = gtk::Label::builder()
            .label(Self::trailing_text(transfer))
            .halign(gtk::Align::End)
            .css_classes(vec!["transfer-status".to_string()])
            .build();
        header.append(&status_label);

        root.append(&header);

        // Progress bar
        let progress_bar = gtk::ProgressBar::builder()
            .fraction(transfer.progress.percentage() / 100.0)
            .show_text(true)
            .text(transfer.progress.format())
            .build();
        root.append(&progress_bar);

        Self {
            widget: root,
            progress_bar,
            status_label,
        }
    }

    /// Update the transfer display
    pub fn update(&self, transfer: &FileTransfer) {
        self.progress_bar
            .set_fraction(transfer.progress.percentage() / 100.0);
        self.progress_bar
            .set_text(Some(&Self::progress_text(transfer)));
        self.status_label.set_text(&Self::trailing_text(transfer));
        self.progress_bar
            .set_css_classes(&[Self::progress_css_class(transfer.state)]);
    }

    fn progress_text(transfer: &FileTransfer) -> String {
        match transfer.state {
            TransferState::Completed => "Completed".to_string(),
            TransferState::Failed => "Failed".to_string(),
            TransferState::Cancelled => "Cancelled".to_string(),
            _ => transfer.progress.format(),
        }
    }

    fn trailing_text(transfer: &FileTransfer) -> String {
        match transfer.state {
            TransferState::Completed => "Completed".to_string(),
            TransferState::Failed => "Failed".to_string(),
            TransferState::Cancelled => "Cancelled".to_string(),
            TransferState::Paused => "Paused".to_string(),
            TransferState::Pending => "Pending".to_string(),
            TransferState::InProgress => format!(
                "{} / {}",
                Self::format_size(transfer.progress.bytes_transferred),
                Self::format_size(transfer.progress.total_bytes),
            ),
        }
    }

    fn progress_css_class(state: TransferState) -> &'static str {
        match state {
            TransferState::Completed => "transfer-progress-complete",
            TransferState::Failed | TransferState::Cancelled => "transfer-progress-failed",
            _ => "transfer-progress-active",
        }
    }

    fn format_size(bytes: u64) -> String {
        const KB: u64 = 1024;
        const MB: u64 = KB * 1024;
        const GB: u64 = MB * 1024;

        if bytes >= GB {
            format!("{:.0} GB", bytes as f64 / GB as f64)
        } else if bytes >= MB {
            format!("{:.0} MB", bytes as f64 / MB as f64)
        } else if bytes >= KB {
            format!("{:.0} KB", bytes as f64 / KB as f64)
        } else {
            format!("{} B", bytes)
        }
    }
}
