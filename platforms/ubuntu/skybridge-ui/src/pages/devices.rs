//! Devices Page

use gtk4::prelude::*;
use gtk4::{self as gtk};
use libadwaita as adw;
use std::cell::RefCell;
use std::rc::Rc;

use crate::components::DeviceCard;
use crate::utils;
use skybridge_core::discovery::DiscoveredDevice;

type DeviceActivatedCallback = Rc<dyn Fn(DiscoveredDevice)>;
type SharedDeviceActivatedCallback = Rc<RefCell<Option<DeviceActivatedCallback>>>;

/// Devices page
pub struct DevicesPage {
    /// Root widget
    pub widget: gtk::Box,
    /// Device list
    device_list: gtk::ListBox,
    stack: gtk::Stack,
    /// Status label
    status_label: gtk::Label,
    /// Panel summary label
    panel_summary: gtk::Label,
    /// Activated callback
    on_device_activated: SharedDeviceActivatedCallback,
}

impl DevicesPage {
    /// Create a new devices page
    pub fn new() -> Self {
        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .css_classes(vec!["page-root".to_string()])
            .build();

        // Header
        let header = utils::build_shell_header(
            "Device Discovery",
            "No peers discovered",
            "status-discovering",
        );
        let chip = header.status_label.clone();

        root.append(&header.header);

        // Device list
        let scrolled = gtk::ScrolledWindow::builder().vexpand(true).build();
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
                "devices-surface-panel".to_string(),
            ])
            .build();
        let panel_header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();
        let panel_title = gtk::Label::builder()
            .label("Trusted Devices")
            .css_classes(vec!["panel-title".to_string()])
            .hexpand(true)
            .xalign(0.0)
            .build();
        let panel_summary = gtk::Label::builder()
            .label("Scanning…")
            .css_classes(vec!["caption".to_string(), "page-status".to_string()])
            .build();
        panel_header.append(&panel_title);
        panel_header.append(&panel_summary);
        panel.append(&panel_header);

        let list_frame = gtk::Frame::builder()
            .css_classes(vec![
                "panel-content".to_string(),
                "devices-panel-content".to_string(),
            ])
            .build();
        list_frame.set_height_request(316);

        let stack = gtk::Stack::builder().vexpand(true).build();

        let device_list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(vec!["page-list".to_string(), "device-list".to_string()])
            .build();
        let empty_icon = utils::resolved_icon_name("system-search-symbolic");
        let empty_state = adw::StatusPage::builder()
            .icon_name(&empty_icon)
            .title("No Devices Found")
            .description("Check your network connection")
            .build();
        stack.add_named(&empty_state, Some("empty"));
        let list_scrolled = gtk::ScrolledWindow::builder()
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();
        list_scrolled.set_child(Some(&device_list));
        stack.add_named(&list_scrolled, Some("list"));
        stack.set_visible_child_name("empty");

        list_frame.set_child(Some(&stack));
        panel.append(&list_frame);
        content.append(&panel);
        scrolled.set_child(Some(&content));
        root.append(&scrolled);

        Self {
            widget: root,
            device_list,
            stack,
            status_label: chip,
            panel_summary,
            on_device_activated: Rc::new(RefCell::new(None)),
        }
    }

    /// Update device list
    pub fn update_devices(&self, devices: &[DiscoveredDevice]) {
        // Clear existing
        while let Some(child) = self.device_list.first_child() {
            self.device_list.remove(&child);
        }

        let callback = self.on_device_activated.borrow().clone();
        if devices.is_empty() {
            self.status_label.set_text("No peers discovered");
            self.panel_summary.set_text("Empty");
            self.stack.set_visible_child_name("empty");
        } else {
            self.status_label.set_text("Trusted peers available");
            self.panel_summary.set_text("Populated");
            self.stack.set_visible_child_name("list");

            for device in devices {
                let card = DeviceCard::new(device);
                if let Some(cb) = callback.as_ref() {
                    let device_clone = device.clone();
                    let cb = cb.clone();
                    card.connect_activated(move || cb(device_clone.clone()));
                }
                self.device_list.append(&card.widget);
            }
        }
    }

    /// Set a callback to run when a device is activated.
    pub fn set_on_device_activated<F>(&self, callback: F)
    where
        F: Fn(DiscoveredDevice) + 'static,
    {
        *self.on_device_activated.borrow_mut() = Some(Rc::new(callback));
    }

    /// Set scanning state
    pub fn set_scanning(&self, scanning: bool) {
        if scanning {
            self.status_label.set_text("Scanning...");
            self.panel_summary.set_text("Scanning…");
            self.stack.set_visible_child_name("empty");
        } else if self.device_list.first_child().is_none() {
            self.status_label.set_text("No peers discovered");
            self.panel_summary.set_text("Empty");
        }
    }
}

impl Default for DevicesPage {
    fn default() -> Self {
        Self::new()
    }
}
