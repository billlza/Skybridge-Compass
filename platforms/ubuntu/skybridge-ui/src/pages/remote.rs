//! Remote Desktop Page

use gtk4::prelude::*;
use gtk4::{self as gtk};

use crate::utils;

/// Summary for the remote desktop overview cards.
#[derive(Debug, Clone)]
pub struct RemoteSnapshot {
    /// Active sessions count.
    pub active_sessions: u32,
    /// Verified peers count.
    pub trusted_peers: u32,
    /// Average RTT / first-frame latency.
    pub avg_latency_ms: u32,
    /// Preferred transport label.
    pub transport: String,
}

impl Default for RemoteSnapshot {
    fn default() -> Self {
        Self {
            active_sessions: 0,
            trusted_peers: 0,
            avg_latency_ms: 0,
            transport: "Awaiting session".to_string(),
        }
    }
}

/// Row model for active remote sessions.
#[derive(Debug, Clone)]
pub struct RemoteSessionSummary {
    /// Remote peer display name.
    pub title: String,
    /// Secondary identity line.
    pub subtitle: String,
    /// Transport chip.
    pub transport: String,
    /// Current session state.
    pub state: String,
    /// Resolution / quality hint.
    pub quality: String,
}

/// Remote desktop page skeleton.
pub struct RemotePage {
    /// Root widget.
    pub widget: gtk::Box,
    top_status_label: gtk::Label,
    sessions_summary: gtk::Label,
    primary_session_value: gtk::Label,
    primary_session_note: gtk::Label,
    transport_value: gtk::Label,
    transport_note: gtk::Label,
    latency_value: gtk::Label,
    latency_note: gtk::Label,
    preview_title: gtk::Label,
    preview_body: gtk::Label,
}

impl RemotePage {
    /// Create a new remote desktop page.
    pub fn new() -> Self {
        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .css_classes(vec!["page-root".to_string()])
            .build();

        let header = utils::build_shell_header("Remote", "No active session", "status-discovering");
        let top_status_label = header.status_label.clone();
        let action = utils::button_from_icon_name("video-display-symbolic");
        action.set_tooltip_text(Some("Start trusted remote session"));
        action.add_css_class("page-header-action");
        header.actions_box.prepend(&action);
        root.append(&header.header);

        let scrolled = gtk::ScrolledWindow::builder()
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();

        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(18)
            .margin_start(20)
            .margin_end(20)
            .margin_top(20)
            .margin_bottom(24)
            .build();

        let sessions_panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(14)
            .css_classes(vec![
                "panel".to_string(),
                "feature-panel".to_string(),
                "remote-surface-panel".to_string(),
            ])
            .build();
        let sessions_header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();
        let sessions_title = gtk::Label::builder()
            .label("Trusted Active Sessions")
            .css_classes(vec!["panel-title".to_string()])
            .hexpand(true)
            .xalign(0.0)
            .build();
        let sessions_summary = gtk::Label::builder()
            .label("No active session")
            .css_classes(vec!["caption".to_string(), "page-status".to_string()])
            .build();
        sessions_header.append(&sessions_title);
        sessions_header.append(&sessions_summary);
        sessions_panel.append(&sessions_header);

        let cards = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(14)
            .homogeneous(true)
            .build();
        let (primary_card, primary_session_value, primary_session_note) = Self::create_summary_tile(
            "Primary Session",
            "No active session",
            "Trusted peers will surface here once a verified remote session is established.",
        );
        let (transport_card, transport_value, transport_note) = Self::create_summary_tile(
            "Transport",
            "Awaiting peer",
            "Mirrors the Apple smart-code flow.",
        );
        let (latency_card, latency_value, latency_note) =
            Self::create_summary_tile("Latency", "Idle", "Mirrors the Apple smart-code flow.");
        cards.append(&primary_card);
        cards.append(&transport_card);
        cards.append(&latency_card);
        sessions_panel.append(&cards);
        content.append(&sessions_panel);

        let preview_panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(14)
            .css_classes(vec![
                "panel".to_string(),
                "feature-panel".to_string(),
                "remote-preview-panel".to_string(),
            ])
            .build();
        let preview_header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();
        let preview_header_title = gtk::Label::builder()
            .label("Preview")
            .css_classes(vec!["panel-title".to_string()])
            .xalign(0.0)
            .hexpand(true)
            .build();
        preview_header.append(&preview_header_title);
        preview_panel.append(&preview_header);

        let preview = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .vexpand(true)
            .valign(gtk::Align::Fill)
            .css_classes(vec!["remote-preview".to_string()])
            .build();
        let preview_icon = utils::image_from_icon_name("video-display-symbolic");
        preview_icon.set_pixel_size(56);
        preview.append(&preview_icon);
        let preview_title = gtk::Label::builder()
            .label("Streaming with verified input")
            .css_classes(vec![
                "panel-title".to_string(),
                "remote-preview-title".to_string(),
            ])
            .wrap(true)
            .justify(gtk::Justification::Center)
            .build();
        preview.append(&preview_title);
        let preview_body = gtk::Label::builder()
            .label("Session quality, transport choice, and clipboard/input policy surface here once a peer connects.")
            .css_classes(vec![
                "dim-label".to_string(),
                "remote-preview-body".to_string(),
            ])
            .max_width_chars(52)
            .wrap(true)
            .justify(gtk::Justification::Center)
            .build();
        preview.append(&preview_body);
        preview_panel.append(&preview);
        content.append(&preview_panel);

        scrolled.set_child(Some(&content));
        root.append(&scrolled);

        Self {
            widget: root,
            top_status_label,
            sessions_summary,
            primary_session_value,
            primary_session_note,
            transport_value,
            transport_note,
            latency_value,
            latency_note,
            preview_title,
            preview_body,
        }
    }

    fn create_summary_tile(
        title: &str,
        value: &str,
        note: &str,
    ) -> (gtk::Box, gtk::Label, gtk::Label) {
        let card = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .css_classes(vec!["card".to_string(), "remote-summary-card".to_string()])
            .build();

        let title_label = gtk::Label::builder()
            .label(title)
            .css_classes(vec!["card-title".to_string()])
            .xalign(0.0)
            .build();
        let value_label = gtk::Label::builder()
            .label(value)
            .css_classes(vec![
                "card-value".to_string(),
                "remote-summary-value".to_string(),
            ])
            .xalign(0.0)
            .wrap(true)
            .build();
        let note_label = gtk::Label::builder()
            .label(note)
            .css_classes(vec![
                "dim-label".to_string(),
                "remote-summary-note".to_string(),
            ])
            .xalign(0.0)
            .wrap(true)
            .build();

        card.append(&title_label);
        card.append(&value_label);
        card.append(&note_label);

        (card, value_label, note_label)
    }

    /// Update overview cards.
    pub fn update_snapshot(&self, snapshot: &RemoteSnapshot) {
        self.transport_value.set_text(&snapshot.transport);
        self.transport_note
            .set_text("Mirrors the Apple smart-code flow.");
        self.latency_value
            .set_text(&format!("{} ms", snapshot.avg_latency_ms));
        self.latency_note
            .set_text("Mirrors the Apple smart-code flow.");

        if snapshot.active_sessions == 0 {
            self.sessions_summary.set_text("No active session");
            self.top_status_label.set_text("No active session");
        } else {
            let text = format!("{} active", snapshot.active_sessions);
            self.sessions_summary.set_text(&text);
            self.top_status_label.set_text("Verified active sessions");
        }
    }

    /// Update active sessions.
    pub fn update_sessions(&self, sessions: &[RemoteSessionSummary]) {
        if let Some(primary) = sessions.first() {
            self.primary_session_value.set_text(&primary.title);
            self.primary_session_note
                .set_text(&format!("{} • {}", primary.transport, primary.quality));
            self.top_status_label.set_text("Verified active sessions");
            self.sessions_summary
                .set_text(&format!("{} active", sessions.len()));
        } else {
            self.primary_session_value.set_text("No active session");
            self.primary_session_note.set_text(
                "Trusted peers will surface here once a verified remote session is established.",
            );
            self.top_status_label.set_text("No active session");
            self.sessions_summary.set_text("No active session");
        }
    }

    /// Update preview text block.
    pub fn set_preview_status(&self, title: &str, body: &str) {
        self.preview_title.set_text(title);
        self.preview_body.set_text(body);
    }
}

impl Default for RemotePage {
    fn default() -> Self {
        Self::new()
    }
}
