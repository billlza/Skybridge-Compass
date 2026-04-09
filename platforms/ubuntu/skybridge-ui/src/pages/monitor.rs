//! System Monitor Page

use gtk4::prelude::*;
use gtk4::{self as gtk};

use crate::utils;

/// Snapshot used by the monitor page.
#[derive(Debug, Clone)]
pub struct MonitorSnapshot {
    /// CPU utilization percent.
    pub cpu_percent: f64,
    /// Memory utilization percent.
    pub memory_percent: f64,
    /// Network throughput in Mbps.
    pub network_mbps: f64,
    /// Thermal estimate in celsius.
    pub thermal_c: f64,
    /// Headline mode label.
    pub mode_label: String,
    /// Free-form alert lines.
    pub alerts: Vec<String>,
}

impl Default for MonitorSnapshot {
    fn default() -> Self {
        Self {
            cpu_percent: 0.0,
            memory_percent: 0.0,
            network_mbps: 0.0,
            thermal_c: 0.0,
            mode_label: "Telemetry stable".to_string(),
            alerts: vec![
                "Remote stream FPS stable above 58 fps".to_string(),
                "No thermal throttling detected".to_string(),
                "Transfer queue healthy · zero retries".to_string(),
            ],
        }
    }
}

/// System monitor page skeleton.
pub struct MonitorPage {
    /// Root widget.
    pub widget: gtk::Box,
    top_status_label: gtk::Label,
    cpu_value: gtk::Label,
    memory_value: gtk::Label,
    network_value: gtk::Label,
    thermal_value: gtk::Label,
    summary_label: gtk::Label,
    bars: [gtk::ProgressBar; 3],
    lines: [gtk::Label; 3],
}

impl MonitorPage {
    /// Create a new monitor page.
    pub fn new() -> Self {
        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .css_classes(vec!["page-root".to_string()])
            .build();

        let header =
            utils::build_shell_header("System Monitor", "Telemetry stable", "status-discovering");
        let pulse = utils::image_from_icon_name("activity-symbolic");
        pulse.add_css_class("page-header-decor");
        header.actions_box.prepend(&pulse);
        root.append(&header.header);
        let top_status_label = header.status_label.clone();

        let scrolled = gtk::ScrolledWindow::builder()
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();

        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(16)
            .margin_start(20)
            .margin_end(20)
            .margin_top(20)
            .margin_bottom(24)
            .build();

        let cards = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(16)
            .homogeneous(true)
            .build();
        let (cpu_card, cpu_value) =
            Self::create_stat_card("CPU", "0%", "cpu-symbolic", "monitor-card monitor-cpu");
        let (memory_card, memory_value) = Self::create_stat_card(
            "Memory",
            "0%",
            "memory-symbolic",
            "monitor-card monitor-memory",
        );
        let (network_card, network_value) = Self::create_stat_card(
            "Bandwidth",
            "0 Mb/s",
            "network-workgroup-symbolic",
            "monitor-card monitor-bandwidth",
        );
        let (thermal_card, thermal_value) = Self::create_stat_card(
            "Thermal",
            "0°C",
            "emblem-system-symbolic",
            "monitor-card monitor-thermal",
        );
        cards.append(&cpu_card);
        cards.append(&memory_card);
        cards.append(&network_card);
        cards.append(&thermal_card);
        content.append(&cards);

        let snapshot_panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(14)
            .css_classes(vec![
                "panel".to_string(),
                "feature-panel".to_string(),
                "monitor-surface-panel".to_string(),
            ])
            .build();
        let panel_header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();
        let panel_title = gtk::Label::builder()
            .label("Live Snapshot")
            .css_classes(vec!["panel-title".to_string()])
            .xalign(0.0)
            .hexpand(true)
            .build();
        let summary_label = gtk::Label::builder()
            .label("Active monitoring")
            .css_classes(vec!["caption".to_string(), "page-status".to_string()])
            .build();
        panel_header.append(&panel_title);
        panel_header.append(&summary_label);
        snapshot_panel.append(&panel_header);

        let mut bars: Vec<gtk::ProgressBar> = Vec::new();
        let mut lines: Vec<gtk::Label> = Vec::new();
        for (text, css_class) in [
            (
                "Remote stream FPS stable above 58 fps",
                "monitor-progress-good",
            ),
            ("No thermal throttling detected", "monitor-progress-accent"),
            (
                "Transfer queue healthy · zero retries",
                "monitor-progress-warn",
            ),
        ] {
            let line = gtk::Label::builder()
                .label(text)
                .xalign(0.0)
                .css_classes(vec!["monitor-line".to_string()])
                .build();
            snapshot_panel.append(&line);
            let bar = gtk::ProgressBar::builder().show_text(false).build();
            bar.add_css_class("monitor-progress");
            bar.add_css_class(css_class);
            snapshot_panel.append(&bar);
            bars.push(bar);
            lines.push(line);
        }

        content.append(&snapshot_panel);
        scrolled.set_child(Some(&content));
        root.append(&scrolled);

        let page = Self {
            widget: root,
            top_status_label,
            cpu_value,
            memory_value,
            network_value,
            thermal_value,
            summary_label,
            bars: [bars.remove(0), bars.remove(0), bars.remove(0)],
            lines: [lines.remove(0), lines.remove(0), lines.remove(0)],
        };
        page.update_snapshot(&MonitorSnapshot::default());
        page
    }

    fn create_stat_card(
        title: &str,
        value: &str,
        icon_name: &str,
        extra_class: &str,
    ) -> (gtk::Box, gtk::Label) {
        let card = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(6)
            .css_classes(vec!["card".to_string(), extra_class.to_string()])
            .build();
        let icon = utils::image_from_icon_name(icon_name);
        icon.set_pixel_size(22);
        icon.add_css_class("card-icon");
        card.append(&icon);

        let title_label = gtk::Label::builder()
            .label(title)
            .css_classes(vec!["card-title".to_string()])
            .xalign(0.0)
            .build();
        card.append(&title_label);

        let value_label = gtk::Label::builder()
            .label(value)
            .css_classes(vec!["card-value".to_string()])
            .xalign(0.0)
            .build();
        card.append(&value_label);

        (card, value_label)
    }

    /// Update the shown snapshot.
    pub fn update_snapshot(&self, snapshot: &MonitorSnapshot) {
        self.cpu_value
            .set_text(&format!("{:.0}%", snapshot.cpu_percent));
        self.memory_value
            .set_text(&format!("{:.0}%", snapshot.memory_percent));
        self.network_value
            .set_text(&format!("{:.0} Mb/s", snapshot.network_mbps));
        self.thermal_value
            .set_text(&format!("{:.0}°C", snapshot.thermal_c));
        self.summary_label.set_text("Active monitoring");
        self.top_status_label.set_text(&snapshot.mode_label);

        let defaults = [
            snapshot.cpu_percent / 100.0,
            snapshot.memory_percent / 100.0,
            (snapshot.network_mbps / 160.0).clamp(0.0, 1.0),
        ];

        for (index, bar) in self.bars.iter().enumerate() {
            bar.set_fraction(defaults[index].clamp(0.0, 1.0));
        }

        for (index, line) in self.lines.iter().enumerate() {
            if let Some(text) = snapshot.alerts.get(index) {
                line.set_text(text);
            }
        }
    }
}

impl Default for MonitorPage {
    fn default() -> Self {
        Self::new()
    }
}
