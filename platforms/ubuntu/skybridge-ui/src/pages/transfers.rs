//! Transfers Page

use gtk4::prelude::*;
use gtk4::{self as gtk};
use libadwaita as adw;

use crate::components::TransferRow;
use crate::utils;
use skybridge_core::transfer::FileTransfer;

/// Transfers page
pub struct TransfersPage {
    /// Root widget
    pub widget: gtk::Box,
    /// Transfer list
    transfer_list: gtk::ListBox,
    /// Stack for empty/list states
    stack: gtk::Stack,
    /// Summary badge
    summary_label: gtk::Label,
    /// Header status label
    top_status_label: gtk::Label,
}

impl TransfersPage {
    /// Create a new transfers page
    pub fn new() -> Self {
        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .css_classes(vec!["page-root".to_string()])
            .build();

        // Header
        let header =
            utils::build_shell_header("File Transfer", "Transfer queue idle", "status-discovering");
        let top_status_label = header.status_label.clone();
        root.append(&header.header);

        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(16)
            .margin_start(20)
            .margin_end(20)
            .margin_top(20)
            .margin_bottom(24)
            .build();
        let panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .css_classes(vec![
                "panel".to_string(),
                "feature-panel".to_string(),
                "transfers-surface-panel".to_string(),
            ])
            .build();
        let panel_header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();
        let panel_title = gtk::Label::builder()
            .label("Transfer Queue")
            .css_classes(vec!["panel-title".to_string()])
            .hexpand(true)
            .xalign(0.0)
            .build();
        let summary_label = gtk::Label::builder()
            .label("Empty")
            .css_classes(vec!["caption".to_string(), "page-status".to_string()])
            .build();
        panel_header.append(&panel_title);
        panel_header.append(&summary_label);
        panel.append(&panel_header);

        // Stack for empty/list states
        let stack = gtk::Stack::builder().vexpand(true).build();
        let list_frame = gtk::Frame::builder()
            .css_classes(vec![
                "panel-content".to_string(),
                "transfers-panel-content".to_string(),
            ])
            .build();
        list_frame.set_height_request(292);

        // Empty state
        let empty_state = adw::StatusPage::builder()
            .icon_name("folder-download-symbolic")
            .title("No Transfers")
            .description("Completed and in-progress jobs appear here")
            .build();
        empty_state.set_height_request(292);
        stack.add_named(&empty_state, Some("empty"));

        // Transfer list
        let scrolled = gtk::ScrolledWindow::builder().vexpand(true).build();

        let transfer_list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(vec!["page-list".to_string(), "transfer-list".to_string()])
            .build();

        scrolled.set_child(Some(&transfer_list));
        list_frame.set_child(Some(&scrolled));
        stack.add_named(&list_frame, Some("list"));

        stack.set_visible_child_name("empty");
        panel.append(&stack);
        content.append(&panel);
        let root_scrolled = gtk::ScrolledWindow::builder().vexpand(true).build();
        root_scrolled.set_child(Some(&content));
        root.append(&root_scrolled);

        Self {
            widget: root,
            transfer_list,
            stack,
            summary_label,
            top_status_label,
        }
    }

    /// Update transfer list
    pub fn update_transfers(&self, transfers: &[FileTransfer]) {
        // Clear existing
        while let Some(child) = self.transfer_list.first_child() {
            self.transfer_list.remove(&child);
        }

        if transfers.is_empty() {
            self.stack.set_visible_child_name("empty");
            self.summary_label.set_text("Empty");
            self.top_status_label.set_text("Transfer queue idle");
        } else {
            for transfer in transfers {
                let row = TransferRow::new(transfer);
                self.transfer_list.append(&row.widget);
            }
            self.stack.set_visible_child_name("list");
            self.summary_label.set_text("In-progress + completed");
            self.top_status_label
                .set_text("Quantum transfer in progress");
        }
    }
}

impl Default for TransfersPage {
    fn default() -> Self {
        Self::new()
    }
}
