//! Device Card Component

use gtk4::{self as gtk};
use libadwaita as adw;
use libadwaita::prelude::*;

use skybridge_core::discovery::DiscoveredDevice;

/// Device card widget
pub struct DeviceCard {
    /// Root widget
    pub widget: adw::ActionRow,
}

impl DeviceCard {
    /// Create a new device card
    pub fn new(device: &DiscoveredDevice) -> Self {
        let subtitle = if device.is_online {
            "Trusted • cross-network ready"
        } else {
            "Trusted • recently seen"
        };
        let row = adw::ActionRow::builder()
            .title(&device.name)
            .subtitle(subtitle)
            .activatable(true)
            .css_classes(vec!["device-card".to_string()])
            .build();

        // Add online indicator
        if device.is_online {
            let badge = gtk::Label::builder()
                .label("Online")
                .css_classes(vec!["caption".to_string(), "status-pill".to_string()])
                .build();
            row.add_suffix(&badge);
        } else {
            let badge = gtk::Label::builder()
                .label("Offline")
                .css_classes(vec!["caption".to_string(), "status-pill".to_string()])
                .build();
            row.add_suffix(&badge);
        }

        Self { widget: row }
    }

    /// Connect to the activated signal
    pub fn connect_activated<F: Fn() + 'static>(&self, callback: F) {
        self.widget.connect_activated(move |_| callback());
    }
}
