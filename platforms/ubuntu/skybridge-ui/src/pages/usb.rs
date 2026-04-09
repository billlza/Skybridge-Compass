//! USB Management Page

use gtk4::prelude::*;
use gtk4::{self as gtk};
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::utils;

/// USB device class shown in the management page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsbDeviceKind {
    /// Apple device with direct-trust / MFi style path.
    AppleTrusted,
    /// Android device via ADB / MTP.
    Android,
    /// External disk / flash drive.
    Storage,
    /// Other accessory.
    Accessory,
}

impl UsbDeviceKind {
    fn label(self) -> &'static str {
        match self {
            Self::AppleTrusted => "Attached",
            Self::Android => "Ready",
            Self::Storage => "Secure",
            Self::Accessory => "Review",
        }
    }
}

/// Row model for USB device display.
#[derive(Debug, Clone)]
pub struct UsbDeviceSummary {
    /// Primary device name.
    pub name: String,
    /// Device family / connection description.
    pub subtitle: String,
    /// Device type.
    pub kind: UsbDeviceKind,
    /// Whether the device is trusted for direct actions.
    pub trusted: bool,
    /// Optional route / mount point.
    pub route_hint: Option<String>,
}

/// USB management page.
pub struct UsbPage {
    /// Root widget.
    pub widget: gtk::Box,
    top_status_label: gtk::Label,
    panel_summary: gtk::Label,
    device_list: gtk::ListBox,
}

impl UsbPage {
    /// Create a new USB page.
    pub fn new() -> Self {
        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .css_classes(vec!["page-root".to_string()])
            .build();

        let header = utils::build_shell_header("USB", "USB bridge ready", "status-discovering");
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

        let panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .css_classes(vec![
                "panel".to_string(),
                "feature-panel".to_string(),
                "usb-surface-panel".to_string(),
            ])
            .build();
        let panel_header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();
        let panel_title = gtk::Label::builder()
            .label("USB Inventory")
            .css_classes(vec!["panel-title".to_string()])
            .hexpand(true)
            .xalign(0.0)
            .build();
        let panel_summary = gtk::Label::builder()
            .label("Attached device inventory")
            .css_classes(vec!["caption".to_string(), "page-status".to_string()])
            .build();
        panel_header.append(&panel_title);
        panel_header.append(&panel_summary);
        panel.append(&panel_header);

        let list_frame = gtk::Frame::builder()
            .css_classes(vec![
                "panel-content".to_string(),
                "usb-panel-content".to_string(),
            ])
            .build();
        list_frame.set_height_request(228);

        let device_list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(vec!["page-list".to_string(), "usb-device-list".to_string()])
            .build();
        let empty_state = adw::StatusPage::builder()
            .icon_name("usb-symbolic")
            .title("No USB devices")
            .description("Attached device inventory will appear here")
            .build();
        device_list.set_placeholder(Some(&empty_state));
        list_frame.set_child(Some(&device_list));
        panel.append(&list_frame);

        content.append(&panel);
        scrolled.set_child(Some(&content));
        root.append(&scrolled);

        Self {
            widget: root,
            top_status_label,
            panel_summary,
            device_list,
        }
    }

    fn create_device_row(device: &UsbDeviceSummary) -> adw::ActionRow {
        let subtitle = match &device.route_hint {
            Some(route) if !route.is_empty() => format!("{} • {}", device.subtitle, route),
            _ => device.subtitle.clone(),
        };
        let row = adw::ActionRow::builder()
            .title(&device.name)
            .subtitle(&subtitle)
            .activatable(false)
            .css_classes(vec!["usb-device-row".to_string()])
            .build();

        let state = gtk::Label::builder()
            .label(device.kind.label())
            .css_classes(vec!["caption".to_string(), "status-pill".to_string()])
            .valign(gtk::Align::Center)
            .build();
        row.add_suffix(&state);
        row
    }

    /// Update the last scan label.
    pub fn set_last_scan(&self, text: &str) {
        self.top_status_label.set_text(text);
    }

    /// Update the shown USB devices.
    pub fn update_devices(&self, devices: &[UsbDeviceSummary]) {
        while let Some(child) = self.device_list.first_child() {
            self.device_list.remove(&child);
        }

        for device in devices {
            self.device_list.append(&Self::create_device_row(device));
        }

        if devices.is_empty() {
            self.panel_summary.set_text("Empty");
            self.top_status_label.set_text("No USB bridge");
        } else {
            self.panel_summary.set_text("Attached device inventory");
            self.top_status_label.set_text("USB bridge ready");
        }
    }
}

impl Default for UsbPage {
    fn default() -> Self {
        Self::new()
    }
}
