//! Dashboard Page
//!
//! Main control console with status overview, device discovery, and session management.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk};
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::utils;
use skybridge_core::discovery::DiscoveredDevice;

type DeviceConnectCallback = Rc<dyn Fn(DiscoveredDevice)>;
type WebRtcHostCallback = Rc<dyn Fn()>;
type WebRtcJoinCallback = Rc<dyn Fn(String)>;
type SharedDeviceConnectCallback = Rc<RefCell<Option<DeviceConnectCallback>>>;
type SharedWebRtcHostCallback = Rc<RefCell<Option<WebRtcHostCallback>>>;
type SharedWebRtcJoinCallback = Rc<RefCell<Option<WebRtcJoinCallback>>>;

/// Dashboard statistics
#[derive(Debug, Clone, Default)]
pub struct DashboardStats {
    /// Online devices count
    pub online_devices: u32,
    /// Active sessions count
    pub active_sessions: u32,
    /// Transfer tasks count
    pub transfer_tasks: u32,
    /// System status (0-100)
    pub system_health: u32,
}

/// Connection phase for UI status indicators.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionPhase {
    /// Discovering devices (no active connection).
    Discovering,
    /// Connection in progress.
    Connecting,
    /// Handshake in progress.
    Handshaking,
    /// Connection established.
    Connected,
    /// Connection failed or closed.
    Failed,
}

/// Connection update payload for UI.
#[derive(Debug, Clone)]
pub struct ConnectionUpdate {
    /// Status message to display.
    pub message: String,
    /// Current connection phase.
    pub phase: ConnectionPhase,
    /// Connection ID if available.
    pub connection_id: Option<String>,
    /// Peer device ID if known.
    pub peer_id: Option<String>,
    /// Peer display name if known.
    pub peer_name: Option<String>,
    /// Streaming status (if any).
    pub streaming: Option<StreamingStatus>,
}

#[derive(Debug, Clone)]
pub struct StreamingStatus {
    /// True when streaming is active.
    pub active: bool,
    /// Optional human-readable status.
    pub message: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AmbientSnapshot {
    pub location: String,
    pub condition: String,
    pub temperature: String,
    pub humidity: String,
    pub visibility: String,
    pub wind: String,
    pub updated: String,
}

#[derive(Debug, Clone)]
struct SessionInfo {
    name: String,
    peer_id: Option<String>,
    streaming: StreamingStatus,
}

/// Dashboard page
pub struct DashboardPage {
    /// Root widget
    pub widget: gtk::Box,
    /// Stats state
    stats: Rc<RefCell<DashboardStats>>,
    /// Status cards
    devices_label: gtk::Label,
    sessions_label: gtk::Label,
    transfers_label: gtk::Label,
    status_label: gtk::Label,
    status_icon: gtk::Image,
    /// Device list
    device_list: gtk::ListBox,
    /// Session list
    session_list: gtk::ListBox,
    /// Discovery status
    discovery_status: gtk::Label,
    /// Connection status
    connection_status: gtk::Label,
    /// Connection status dot
    connection_dot: gtk::Label,
    /// Active sessions by connection ID
    active_sessions: Rc<RefCell<HashMap<String, SessionInfo>>>,
    /// Device connect callback
    on_device_connect: SharedDeviceConnectCallback,
    /// Cross-network host callback (generate code / start offerer)
    on_webrtc_host: SharedWebRtcHostCallback,
    /// Cross-network join callback (code)
    on_webrtc_join: SharedWebRtcJoinCallback,
    /// Cross-network connection code label
    cross_network_code: gtk::Label,
    /// Cross-network peer mapping label
    cross_network_peer_hint: gtk::Label,
    /// Cross-network signaling / room status label
    cross_network_room_status: gtk::Label,
    /// Ambient hero labels (macOS-style overview strip)
    ambient_location: gtk::Label,
    ambient_condition: gtk::Label,
    ambient_temperature: gtk::Label,
    ambient_humidity: gtk::Label,
    ambient_visibility: gtk::Label,
    ambient_wind: gtk::Label,
    ambient_updated: gtk::Label,
}

impl DashboardPage {
    /// Create a new dashboard page
    pub fn new() -> Self {
        let stats = Rc::new(RefCell::new(DashboardStats {
            online_devices: 0,
            active_sessions: 0,
            transfer_tasks: 0,
            system_health: 100,
        }));

        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .css_classes(vec!["page-root".to_string(), "dashboard".to_string()])
            .build();

        // Header bar
        let header = utils::build_shell_header(
            "Main Console",
            "Searching for trusted devices",
            "status-discovering",
        );
        let connection_status = header.status_label.clone();
        let conn_dot = header.status_dot.clone();
        root.append(&header.header);

        // Main content
        let scrolled = gtk::ScrolledWindow::builder()
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();

        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(24)
            .margin_start(24)
            .margin_end(24)
            .margin_top(16)
            .margin_bottom(24)
            .build();

        // Status cards row
        let cards_row = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(16)
            .homogeneous(true)
            .build();

        let (devices_card, devices_label) =
            Self::create_status_card("computer-symbolic", "Online Devices", "0", "card-devices");
        let (sessions_card, sessions_label) = Self::create_status_card(
            "video-display-symbolic",
            "Active Sessions",
            "0",
            "card-sessions",
        );
        let (transfers_card, transfers_label) = Self::create_status_card(
            "folder-download-symbolic",
            "Transfer Tasks",
            "0",
            "card-transfers",
        );
        let (status_card, status_label, status_icon) = Self::create_system_status_card();

        cards_row.append(&devices_card);
        cards_row.append(&sessions_card);
        cards_row.append(&transfers_card);
        cards_row.append(&status_card);
        content.append(&cards_row);

        let (
            ambient_panel,
            ambient_location,
            ambient_condition,
            ambient_temperature,
            ambient_humidity,
            ambient_visibility,
            ambient_wind,
            ambient_updated,
        ) = Self::create_ambient_panel();
        content.append(&ambient_panel);

        // Main panels row
        let panels_row = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(16)
            .vexpand(true)
            .build();

        let on_device_connect: SharedDeviceConnectCallback = Rc::new(RefCell::new(None));
        let on_webrtc_host: SharedWebRtcHostCallback = Rc::new(RefCell::new(None));
        let on_webrtc_join: SharedWebRtcJoinCallback = Rc::new(RefCell::new(None));

        // Left column: discovery + cross-network
        let left_col = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(16)
            .hexpand(true)
            .vexpand(true)
            .build();

        // Device Discovery Panel
        let (discovery_panel, device_list, discovery_status) = Self::create_discovery_panel();
        left_col.append(&discovery_panel);

        // Cross-network (WebRTC) panel
        let (
            cross_panel,
            cross_code_label,
            cross_peer_hint,
            cross_room_status,
            join_entry,
            host_btn,
            join_btn,
        ) = Self::create_cross_network_panel();
        {
            let cb = on_webrtc_host.clone();
            host_btn.connect_clicked(move |_| {
                if let Some(cb) = cb.borrow().as_ref() {
                    cb();
                }
            });
        }
        {
            let cb = on_webrtc_join.clone();
            let entry = join_entry.clone();
            join_btn.connect_clicked(move |_| {
                let code = entry.text().to_string();
                if let Some(cb) = cb.borrow().as_ref() {
                    cb(code);
                }
            });
        }
        left_col.append(&cross_panel);

        panels_row.append(&left_col);

        // Remote Sessions Panel
        let (sessions_panel, session_list) = Self::create_sessions_panel();
        sessions_panel.set_width_request(360);
        panels_row.append(&sessions_panel);

        content.append(&panels_row);

        scrolled.set_child(Some(&content));
        root.append(&scrolled);

        Self {
            widget: root,
            stats,
            devices_label,
            sessions_label,
            transfers_label,
            status_label,
            status_icon,
            device_list,
            session_list,
            discovery_status,
            connection_status,
            connection_dot: conn_dot,
            active_sessions: Rc::new(RefCell::new(HashMap::new())),
            on_device_connect,
            on_webrtc_host,
            on_webrtc_join,
            cross_network_code: cross_code_label,
            cross_network_peer_hint: cross_peer_hint,
            cross_network_room_status: cross_room_status,
            ambient_location,
            ambient_condition,
            ambient_temperature,
            ambient_humidity,
            ambient_visibility,
            ambient_wind,
            ambient_updated,
        }
    }

    fn create_ambient_panel() -> (
        gtk::Box,
        gtk::Label,
        gtk::Label,
        gtk::Label,
        gtk::Label,
        gtk::Label,
        gtk::Label,
        gtk::Label,
    ) {
        let panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(20)
            .hexpand(true)
            .css_classes(vec!["panel".to_string(), "ambient-hero".to_string()])
            .build();

        let left = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(18)
            .hexpand(true)
            .valign(gtk::Align::Center)
            .build();

        let weather_icon = utils::image_from_icon_name("weather-clear-symbolic");
        weather_icon.set_pixel_size(46);
        weather_icon.add_css_class("ambient-hero-icon");
        left.append(&weather_icon);

        let summary = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(6)
            .valign(gtk::Align::Center)
            .build();
        let location = gtk::Label::builder()
            .label("SkyBridge Ambient")
            .css_classes(vec!["ambient-hero-location".to_string()])
            .xalign(0.0)
            .build();
        let condition = gtk::Label::builder()
            .label("Ready for trusted discovery")
            .css_classes(vec!["ambient-hero-condition".to_string()])
            .xalign(0.0)
            .build();
        let updated = gtk::Label::builder()
            .label("Awaiting weather feed")
            .css_classes(vec!["ambient-hero-updated".to_string()])
            .xalign(0.0)
            .build();
        summary.append(&location);
        summary.append(&condition);
        summary.append(&updated);
        left.append(&summary);

        let temperature = gtk::Label::builder()
            .label("—°")
            .css_classes(vec!["ambient-hero-temperature".to_string()])
            .hexpand(true)
            .xalign(0.0)
            .valign(gtk::Align::Center)
            .build();
        left.append(&temperature);
        panel.append(&left);

        let metrics = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(18)
            .halign(gtk::Align::End)
            .valign(gtk::Align::Center)
            .build();
        let humidity = gtk::Label::builder()
            .label("Humidity —")
            .css_classes(vec!["ambient-hero-metric".to_string()])
            .build();
        let visibility = gtk::Label::builder()
            .label("Visibility —")
            .css_classes(vec!["ambient-hero-metric".to_string()])
            .build();
        let wind = gtk::Label::builder()
            .label("Wind —")
            .css_classes(vec!["ambient-hero-metric".to_string()])
            .build();
        metrics.append(&humidity);
        metrics.append(&visibility);
        metrics.append(&wind);
        panel.append(&metrics);

        (
            panel,
            location,
            condition,
            temperature,
            humidity,
            visibility,
            wind,
            updated,
        )
    }

    fn create_cross_network_panel() -> (
        gtk::Box,
        gtk::Label,
        gtk::Label,
        gtk::Label,
        gtk::Entry,
        gtk::Button,
        gtk::Button,
    ) {
        let panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .hexpand(true)
            .css_classes(vec![
                "panel".to_string(),
                "dashboard-discovery-panel".to_string(),
            ])
            .build();

        let header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();

        let header_icon = utils::image_from_icon_name("network-wireless-symbolic");
        let header_title = gtk::Label::builder()
            .label("Cross-Network Connection")
            .css_classes(vec!["panel-title".to_string()])
            .hexpand(true)
            .xalign(0.0)
            .build();
        header.append(&header_icon);
        header.append(&header_title);
        panel.append(&header);

        let subtitle = gtk::Label::builder()
            .label("Mirror the Apple smart-code flow: generate a server-issued code for this device, or enter the code shown on macOS/iOS.")
            .wrap(true)
            .xalign(0.0)
            .css_classes(vec!["dim-label".to_string(), "page-subtitle".to_string()])
            .build();
        panel.append(&subtitle);

        let split = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(12)
            .hexpand(true)
            .build();

        let host_card = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .hexpand(true)
            .css_classes(vec!["cross-network-card".to_string()])
            .build();
        let host_title = gtk::Label::builder()
            .label("My Connection Code")
            .css_classes(vec!["panel-title".to_string()])
            .xalign(0.0)
            .build();
        let code_label = gtk::Label::builder()
            .label("—")
            .css_classes(vec!["cross-network-code".to_string()])
            .xalign(0.0)
            .hexpand(true)
            .build();
        let peer_hint = gtk::Label::builder()
            .label("Mapped peer: waiting for signaling")
            .wrap(true)
            .xalign(0.0)
            .css_classes(vec![
                "dim-label".to_string(),
                "cross-network-mapping".to_string(),
            ])
            .build();
        let room_status = gtk::Label::builder()
            .label("Room status: idle")
            .wrap(true)
            .xalign(0.0)
            .css_classes(vec![
                "dim-label".to_string(),
                "cross-network-mapping".to_string(),
            ])
            .build();
        let host_help = gtk::Label::builder()
            .label("Enter this server-issued connection code on macOS/iOS to connect to this Ubuntu device.")
            .wrap(true)
            .xalign(0.0)
            .css_classes(vec!["dim-label".to_string(), "page-subtitle".to_string()])
            .build();
        let host_btn = gtk::Button::builder()
            .label("Generate and Wait")
            .css_classes(vec!["suggested-action".to_string()])
            .build();
        host_card.append(&host_title);
        host_card.append(&code_label);
        host_card.append(&peer_hint);
        host_card.append(&room_status);
        host_card.append(&host_help);
        host_card.append(&host_btn);

        let join_card = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .hexpand(true)
            .css_classes(vec!["cross-network-card".to_string()])
            .build();
        let join_title = gtk::Label::builder()
            .label("Enter Connection Code")
            .css_classes(vec!["panel-title".to_string()])
            .xalign(0.0)
            .build();
        let join_help = gtk::Label::builder()
            .label("Enter the active smart code currently shown on macOS/iOS.")
            .wrap(true)
            .xalign(0.0)
            .css_classes(vec!["dim-label".to_string(), "page-subtitle".to_string()])
            .build();
        let join_entry = gtk::Entry::builder()
            .placeholder_text("AB12CD")
            .hexpand(true)
            .css_classes(vec!["cross-network-entry".to_string()])
            .build();
        join_entry.connect_changed(|entry| {
            let normalized: String = entry
                .text()
                .chars()
                .map(|ch| ch.to_ascii_uppercase())
                .filter(|ch| "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains(*ch))
                .take(6)
                .collect();
            if normalized != entry.text().as_str() {
                entry.set_text(&normalized);
                entry.set_position(-1);
            }
        });
        let join_btn = gtk::Button::builder().label("Connect").build();
        join_card.append(&join_title);
        join_card.append(&join_help);
        join_card.append(&join_entry);
        join_card.append(&join_btn);

        split.append(&host_card);
        split.append(&join_card);
        panel.append(&split);

        (
            panel,
            code_label,
            peer_hint,
            room_status,
            join_entry,
            host_btn,
            join_btn,
        )
    }

    /// Create a status card widget
    fn create_status_card(
        icon_name: &str,
        title: &str,
        value: &str,
        css_class: &str,
    ) -> (gtk::Box, gtk::Label) {
        let card = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .css_classes(vec!["card".to_string(), css_class.to_string()])
            .build();

        let icon = utils::image_from_icon_name(icon_name);
        icon.set_pixel_size(28);
        icon.add_css_class("card-icon");
        card.append(&icon);

        let title_label = gtk::Label::builder()
            .label(title)
            .css_classes(vec!["card-title".to_string(), "dim-label".to_string()])
            .build();
        card.append(&title_label);

        let value_label = gtk::Label::builder()
            .label(value)
            .css_classes(vec!["card-value".to_string()])
            .build();
        card.append(&value_label);

        (card, value_label)
    }

    /// Create system status card
    fn create_system_status_card() -> (gtk::Box, gtk::Label, gtk::Image) {
        let card = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .css_classes(vec!["card".to_string(), "card-status".to_string()])
            .build();

        let icon = utils::image_from_icon_name("face-smile-symbolic");
        icon.set_pixel_size(28);
        icon.add_css_class("status-excellent");
        card.append(&icon);

        let title_label = gtk::Label::builder()
            .label("System Status")
            .css_classes(vec!["card-title".to_string(), "dim-label".to_string()])
            .build();
        card.append(&title_label);

        let value_label = gtk::Label::builder()
            .label("Excellent")
            .css_classes(vec![
                "card-value".to_string(),
                "status-excellent".to_string(),
            ])
            .build();
        card.append(&value_label);

        (card, value_label, icon)
    }

    /// Create device discovery panel
    fn create_discovery_panel() -> (gtk::Box, gtk::ListBox, gtk::Label) {
        let panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .hexpand(true)
            .css_classes(vec!["panel".to_string()])
            .build();

        // Panel header
        let header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();

        let header_icon = utils::image_from_icon_name("system-search-symbolic");
        let header_title = gtk::Label::builder()
            .label("Device Discovery")
            .css_classes(vec!["panel-title".to_string()])
            .hexpand(true)
            .xalign(0.0)
            .build();
        header.append(&header_icon);
        header.append(&header_title);

        let header_status = gtk::Label::builder()
            .label("Scanning…")
            .css_classes(vec!["caption".to_string(), "page-status".to_string()])
            .build();
        header.append(&header_status);

        // Refresh button
        let refresh_btn = gtk::Button::builder()
            .icon_name("view-refresh-symbolic")
            .css_classes(vec![
                "flat".to_string(),
                "circular".to_string(),
                "page-header-action".to_string(),
            ])
            .tooltip_text("Refresh")
            .build();
        header.append(&refresh_btn);

        panel.append(&header);

        // Controls row
        let controls = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();

        // Compatibility toggle
        let compat_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(4)
            .build();
        let compat_label = gtk::Label::builder()
            .label("Compatibility/More Devices")
            .css_classes(vec!["dim-label".to_string()])
            .build();
        let compat_switch = gtk::Switch::builder()
            .active(true)
            .valign(gtk::Align::Center)
            .build();
        compat_box.append(&compat_label);
        compat_box.append(&compat_switch);
        controls.append(&compat_box);

        // Search entry
        let search_entry = gtk::SearchEntry::builder()
            .placeholder_text("Search devices...")
            .hexpand(true)
            .build();
        controls.append(&search_entry);

        // Manual connect button
        let manual_btn = gtk::Button::builder()
            .label("Manual")
            .css_classes(vec!["flat".to_string()])
            .build();
        controls.append(&manual_btn);

        panel.append(&controls);

        // Device list
        let list_frame = gtk::Frame::builder()
            .css_classes(vec![
                "panel-content".to_string(),
                "discovery-panel-content".to_string(),
            ])
            .vexpand(true)
            .build();

        let device_list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(vec!["boxed-list".to_string()])
            .build();

        // Empty state placeholder
        let empty_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .valign(gtk::Align::Center)
            .halign(gtk::Align::Center)
            .vexpand(true)
            .build();

        let empty_icon = utils::image_from_icon_name("system-search-symbolic");
        empty_icon.set_pixel_size(64);
        empty_icon.add_css_class("dim-label");
        empty_box.append(&empty_icon);

        let empty_label = gtk::Label::builder()
            .label("No Devices Found")
            .css_classes(vec!["title-3".to_string(), "empty-state-title".to_string()])
            .build();
        empty_box.append(&empty_label);

        let empty_subtitle = gtk::Label::builder()
            .label("Check your network connection")
            .css_classes(vec![
                "dim-label".to_string(),
                "empty-state-subtitle".to_string(),
            ])
            .build();
        empty_box.append(&empty_subtitle);

        device_list.set_placeholder(Some(&empty_box));
        list_frame.set_child(Some(&device_list));
        panel.append(&list_frame);

        // Status bar
        let status = gtk::Label::builder()
            .label("Scanning…")
            .css_classes(vec!["caption".to_string(), "page-status".to_string()])
            .xalign(0.0)
            .build();
        header_status
            .bind_property("label", &status, "label")
            .sync_create()
            .build();

        (panel, device_list, status)
    }

    /// Create remote sessions panel
    fn create_sessions_panel() -> (gtk::Box, gtk::ListBox) {
        let panel = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .css_classes(vec![
                "panel".to_string(),
                "dashboard-sessions-panel".to_string(),
            ])
            .build();

        // Panel header
        let header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();

        let header_icon = utils::image_from_icon_name("video-display-symbolic");
        let header_title = gtk::Label::builder()
            .label("Remote Sessions")
            .css_classes(vec!["panel-title".to_string()])
            .hexpand(true)
            .xalign(0.0)
            .build();
        header.append(&header_icon);
        header.append(&header_title);

        // New session button
        let new_btn = gtk::Button::builder()
            .icon_name("list-add-symbolic")
            .css_classes(vec![
                "flat".to_string(),
                "circular".to_string(),
                "page-header-action".to_string(),
            ])
            .tooltip_text("New Session")
            .build();
        header.append(&new_btn);

        panel.append(&header);

        // Session list
        let list_frame = gtk::Frame::builder()
            .css_classes(vec![
                "panel-content".to_string(),
                "remote-sessions-content".to_string(),
            ])
            .vexpand(true)
            .build();

        let session_list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(vec!["boxed-list".to_string()])
            .build();

        // Empty state placeholder
        let empty_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .valign(gtk::Align::Center)
            .halign(gtk::Align::Center)
            .vexpand(true)
            .build();

        let empty_icon = utils::image_from_icon_name("video-display-symbolic");
        empty_icon.set_pixel_size(64);
        empty_icon.add_css_class("dim-label");
        empty_box.append(&empty_icon);

        let empty_label = gtk::Label::builder()
            .label("No Active Sessions")
            .css_classes(vec!["title-3".to_string(), "empty-state-title".to_string()])
            .build();
        empty_box.append(&empty_label);

        let empty_subtitle = gtk::Label::builder()
            .label("Start a session from Device Discovery")
            .css_classes(vec![
                "dim-label".to_string(),
                "empty-state-subtitle".to_string(),
            ])
            .build();
        empty_box.append(&empty_subtitle);

        session_list.set_placeholder(Some(&empty_box));
        list_frame.set_child(Some(&session_list));
        panel.append(&list_frame);

        (panel, session_list)
    }

    /// Update statistics display
    pub fn update_stats(&self, stats: DashboardStats) {
        self.devices_label
            .set_text(&stats.online_devices.to_string());
        self.sessions_label
            .set_text(&stats.active_sessions.to_string());
        self.transfers_label
            .set_text(&stats.transfer_tasks.to_string());

        // Update system status
        let (status_text, status_class) = if stats.system_health >= 90 {
            ("Excellent", "status-excellent")
        } else if stats.system_health >= 70 {
            ("Good", "status-good")
        } else if stats.system_health >= 50 {
            ("Fair", "status-fair")
        } else {
            ("Poor", "status-poor")
        };

        self.status_label.set_text(status_text);
        self.status_label
            .set_css_classes(&["card-value", status_class]);
        self.status_icon.set_css_classes(&[status_class]);

        *self.stats.borrow_mut() = stats;
    }

    /// Update device list
    pub fn update_devices(&self, devices: &[DiscoveredDevice]) {
        // Clear existing
        while let Some(child) = self.device_list.first_child() {
            self.device_list.remove(&child);
        }

        // Update count
        let online_count = devices.iter().filter(|d| d.is_online).count() as u32;
        self.devices_label.set_text(&online_count.to_string());

        let callback = self.on_device_connect.borrow().clone();
        // Add device rows
        for device in devices.iter().filter(|d| d.is_online) {
            let row = Self::create_device_row(device, callback.as_ref().cloned());
            self.device_list.append(&row);
        }

        // Update status
        if devices.is_empty() {
            self.discovery_status.set_text("Scanning...");
        } else {
            self.discovery_status
                .set_text(&format!("Found {} device(s)", online_count));
        }
    }

    /// Update connection status and session list.
    pub fn update_connection_status(&self, update: ConnectionUpdate) {
        self.connection_status.set_text(&update.message);
        self.apply_connection_phase(update.phase);

        let mut refresh_sessions = false;
        if let Some(connection_id) = update.connection_id.clone() {
            let mut sessions = self.active_sessions.borrow_mut();
            match update.phase {
                ConnectionPhase::Connected => {
                    let name = update
                        .peer_name
                        .clone()
                        .or(update.peer_id.clone())
                        .unwrap_or_else(|| connection_id.clone());
                    sessions.insert(
                        connection_id,
                        SessionInfo {
                            name,
                            peer_id: update.peer_id.clone(),
                            streaming: update.streaming.clone().unwrap_or(StreamingStatus {
                                active: false,
                                message: None,
                            }),
                        },
                    );
                    refresh_sessions = true;
                }
                ConnectionPhase::Failed => {
                    sessions.remove(&connection_id);
                    refresh_sessions = true;
                }
                _ => {}
            }
        }

        if let Some(connection_id) = update.connection_id.as_ref()
            && let Some(streaming) = update.streaming.as_ref()
        {
            let mut sessions = self.active_sessions.borrow_mut();
            if let Some(session) = sessions.get_mut(connection_id) {
                session.streaming = streaming.clone();
                refresh_sessions = true;
            }
        }

        if refresh_sessions {
            self.refresh_sessions();
        }
    }

    /// Create a device row widget
    fn create_device_row(
        device: &DiscoveredDevice,
        on_connect: Option<Rc<dyn Fn(DiscoveredDevice)>>,
    ) -> adw::ActionRow {
        let subtitle = device
            .addresses
            .first()
            .map(|addr| addr.ip().to_string())
            .unwrap_or_else(|| "Unknown IP".to_string());
        let row = adw::ActionRow::builder()
            .title(&device.name)
            .subtitle(subtitle)
            .activatable(true)
            .build();
        row.add_css_class("device-card");

        // Platform icon
        let icon_name = match device.platform {
            skybridge_core::discovery::Platform::MacOS => "computer-apple-symbolic",
            skybridge_core::discovery::Platform::IOS
            | skybridge_core::discovery::Platform::IPadOS => "phone-apple-iphone-symbolic",
            skybridge_core::discovery::Platform::Android => "phone-symbolic",
            skybridge_core::discovery::Platform::Windows => "computer-symbolic",
            skybridge_core::discovery::Platform::Linux
            | skybridge_core::discovery::Platform::Ubuntu => "computer-symbolic",
            _ => "computer-symbolic",
        };
        let icon = utils::image_from_icon_name(icon_name);
        icon.set_pixel_size(32);
        row.add_prefix(&icon);

        // Online indicator
        let status_dot = gtk::Label::builder()
            .label("\u{25CF}")
            .css_classes(vec!["status-online".to_string()])
            .build();
        row.add_suffix(&status_dot);

        // Connect button
        let connect_btn = gtk::Button::builder()
            .icon_name("go-next-symbolic")
            .css_classes(vec!["flat".to_string()])
            .valign(gtk::Align::Center)
            .build();
        if let Some(callback) = on_connect {
            let device_clone = device.clone();
            let cb = callback.clone();
            connect_btn.connect_clicked(move |_| {
                cb(device_clone.clone());
            });
            let device_clone = device.clone();
            let cb = callback.clone();
            row.connect_activated(move |_| {
                cb(device_clone.clone());
            });
        }
        row.add_suffix(&connect_btn);

        row
    }

    /// Set a callback for device connect actions.
    pub fn set_on_device_connect<F>(&self, callback: F)
    where
        F: Fn(DiscoveredDevice) + 'static,
    {
        *self.on_device_connect.borrow_mut() = Some(Rc::new(callback));
    }

    /// Set a callback for hosting a cross-network session.
    pub fn set_on_webrtc_host<F>(&self, callback: F)
    where
        F: Fn() + 'static,
    {
        *self.on_webrtc_host.borrow_mut() = Some(Rc::new(callback));
    }

    /// Set a callback for joining a cross-network session.
    pub fn set_on_webrtc_join<F>(&self, callback: F)
    where
        F: Fn(String) + 'static,
    {
        *self.on_webrtc_join.borrow_mut() = Some(Rc::new(callback));
    }

    /// Trigger the configured cross-network join callback.
    pub fn trigger_webrtc_join(&self, code: impl Into<String>) {
        if let Some(callback) = self.on_webrtc_join.borrow().as_ref() {
            callback(code.into());
        }
    }

    /// Update the shown cross-network code.
    pub fn set_cross_network_code(&self, code: &str) {
        self.cross_network_code.set_text(code);
        self.cross_network_peer_hint
            .set_text("Mapped peer: waiting for signaling");
        self.cross_network_room_status
            .set_text(&format!("Room status for {}: waiting for signaling", code));
    }

    /// Update the shown cross-network peer mapping for the active code.
    pub fn set_cross_network_peer_hint(
        &self,
        code: &str,
        peer_id: Option<&str>,
        peer_fingerprint: Option<&str>,
    ) {
        let peer_id = peer_id.unwrap_or("waiting for signaling");
        let peer_fingerprint = peer_fingerprint.unwrap_or("none");
        self.cross_network_peer_hint.set_text(&format!(
            "Mapped peer for {}: {} · Fingerprint hint: {}",
            code, peer_id, peer_fingerprint
        ));
    }

    /// Update the shown signaling/room status for the active cross-network session.
    pub fn set_cross_network_room_status(&self, code: &str, status: &str) {
        self.cross_network_room_status
            .set_text(&format!("Room status for {}: {}", code, status));
    }

    pub fn set_ambient_snapshot(&self, snapshot: &AmbientSnapshot) {
        self.ambient_location.set_text(&snapshot.location);
        self.ambient_condition.set_text(&snapshot.condition);
        self.ambient_temperature.set_text(&snapshot.temperature);
        self.ambient_humidity.set_text(&snapshot.humidity);
        self.ambient_visibility.set_text(&snapshot.visibility);
        self.ambient_wind.set_text(&snapshot.wind);
        self.ambient_updated.set_text(&snapshot.updated);
    }

    /// Set connection status
    pub fn set_connection_status(&self, status: &str, connected: bool) {
        self.connection_status.set_text(status);
        let phase = if connected {
            ConnectionPhase::Connected
        } else {
            ConnectionPhase::Discovering
        };
        self.apply_connection_phase(phase);
    }

    /// Set discovery status
    pub fn set_discovery_status(&self, status: &str) {
        self.discovery_status.set_text(status);
    }

    fn apply_connection_phase(&self, phase: ConnectionPhase) {
        let (label_class, dot_class) = match phase {
            ConnectionPhase::Connected => ("status-connected", "status-connected"),
            ConnectionPhase::Failed => ("status-disconnected", "status-disconnected"),
            ConnectionPhase::Discovering
            | ConnectionPhase::Connecting
            | ConnectionPhase::Handshaking => ("dim-label", "status-discovering"),
        };

        self.connection_status.set_css_classes(&[label_class]);
        self.connection_dot
            .set_css_classes(&["status-indicator", dot_class]);
    }

    fn refresh_sessions(&self) {
        while let Some(child) = self.session_list.first_child() {
            self.session_list.remove(&child);
        }

        let sessions = self.active_sessions.borrow();
        self.sessions_label.set_text(&sessions.len().to_string());

        for (connection_id, info) in sessions.iter() {
            let subtitle = info.peer_id.as_deref().unwrap_or(connection_id);
            let row = Self::create_session_row(&info.name, subtitle, &info.streaming);
            self.session_list.append(&row);
        }
    }

    fn create_session_row(
        title: &str,
        subtitle: &str,
        streaming: &StreamingStatus,
    ) -> adw::ActionRow {
        let row = adw::ActionRow::builder()
            .title(title)
            .subtitle(subtitle)
            .activatable(false)
            .build();

        let status_text = streaming
            .message
            .clone()
            .unwrap_or_else(|| "Streaming".to_string());
        let (label_text, label_class) = if streaming.active {
            (status_text, "status-connected")
        } else {
            ("Connected".to_string(), "dim-label")
        };
        let status = gtk::Label::builder()
            .label(&label_text)
            .css_classes(vec![label_class.to_string(), "caption".to_string()])
            .build();
        row.add_suffix(&status);

        row
    }
}

impl Default for DashboardPage {
    fn default() -> Self {
        Self::new()
    }
}
