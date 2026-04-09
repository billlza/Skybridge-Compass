//! Settings Page
//!
//! Comprehensive settings interface for SkyBridge Compass.

use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio};
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::settings::{AppSettings, LogLevel};
use crate::utils;
use skybridge_core::auth::{AuthenticationService, SupabaseConfig};
use skybridge_core::discovery::DeviceCapability;
use skybridge_core::p2p::TrustStore;
use skybridge_core::remote::{EncoderPreset, HardwareEncoder, VideoCodec};
use skybridge_core::transfer::CompressionStrategy;

type SharedVoidCallback = Rc<RefCell<Option<Box<dyn Fn()>>>>;

/// Settings page with all configuration sections
pub struct SettingsPage {
    /// Root widget
    pub widget: gtk::Box,
    /// Settings state
    settings: Rc<RefCell<AppSettings>>,
    /// Cached account session state
    account_session: Rc<RefCell<Option<skybridge_core::auth::AuthSession>>>,
    /// Account row (Signed in / Not signed in)
    account_row: adw::ActionRow,
    /// Account avatar
    account_avatar: adw::Avatar,
    /// Account action button (Sign In / Sign Out)
    account_action_btn: gtk::Button,
    /// Sync status row
    sync_row: adw::ActionRow,
    /// Sync action button
    sync_btn: gtk::Button,
    /// Whether an account sync is currently in progress
    sync_busy: std::cell::Cell<bool>,
    /// Overview summary group shown at the top
    summary_group: adw::PreferencesGroup,
    /// Default account overview group
    account_group: adw::PreferencesGroup,
    /// Security overview group used by parity captures
    security_overview_group: adw::PreferencesGroup,
}

impl SettingsPage {
    /// Create a new settings page
    pub fn new() -> Self {
        let settings = Rc::new(RefCell::new(AppSettings::load()));

        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .css_classes(vec!["page-root".to_string(), "settings-root".to_string()])
            .build();

        // Header
        let header =
            utils::build_shell_header("Settings", "Preferences synchronized", "status-discovering");
        header.header.add_css_class("settings-header");
        root.append(&header.header);

        // Content
        let scrolled = gtk::ScrolledWindow::builder()
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build();

        let content = adw::PreferencesPage::builder().build();
        content.add_css_class("settings-page");

        // Build all sections
        let summary_handles = Self::build_summary_section(&content, &settings);
        let account_handles = Self::build_account_section(&content, &settings);
        let security_overview_group = Self::build_security_overview_section(&content, &settings);
        Self::build_supabase_section(&content);
        Self::build_device_section(&content, &settings);
        Self::build_transfer_section(&content, &settings);
        Self::build_remote_desktop_section(&content, &settings);
        Self::build_security_section(&content, &settings);
        Self::build_network_section(&content, &settings);
        Self::build_developer_section(&content, &settings);
        Self::build_about_section(&content, &settings);

        let clamp = adw::Clamp::builder()
            .maximum_size(920)
            .tightening_threshold(640)
            .margin_top(22)
            .margin_bottom(28)
            .margin_start(24)
            .margin_end(24)
            .build();
        clamp.add_css_class("settings-clamp");
        clamp.set_child(Some(&content));

        scrolled.set_child(Some(&clamp));
        root.append(&scrolled);

        Self {
            widget: root,
            settings,
            account_session: account_handles.session,
            account_row: account_handles.user_row,
            account_avatar: account_handles.avatar,
            account_action_btn: account_handles.action_btn,
            sync_row: account_handles.sync_row,
            sync_btn: account_handles.sync_btn,
            sync_busy: std::cell::Cell::new(false),
            summary_group: summary_handles.group,
            account_group: account_handles.group,
            security_overview_group,
        }
    }

    fn build_summary_section(
        page: &adw::PreferencesPage,
        settings: &Rc<RefCell<AppSettings>>,
    ) -> SummarySectionHandles {
        let group = adw::PreferencesGroup::builder()
            .title("Preferences")
            .description("Default")
            .build();
        group.add_css_class("settings-panel");
        group.add_css_class("settings-overview-panel");

        let appearance_row = adw::ActionRow::builder()
            .title("Appearance")
            .subtitle("Adaptive glass")
            .build();
        appearance_row.add_css_class("settings-summary-row");
        let appearance_badge = gtk::Label::builder()
            .label("Adaptive glass")
            .css_classes(vec!["status-pill".to_string(), "caption".to_string()])
            .build();
        appearance_row.add_suffix(&appearance_badge);
        group.add(&appearance_row);

        let transport_title = if settings.borrow().network.enable_webrtc {
            "WebRTC preferred"
        } else {
            "LAN transport"
        };
        let transport_row = adw::ActionRow::builder()
            .title("Cross-network transport")
            .subtitle(transport_title)
            .build();
        transport_row.add_css_class("settings-summary-row");
        let transport_badge = gtk::Label::builder()
            .label(transport_title)
            .css_classes(vec!["status-pill".to_string(), "caption".to_string()])
            .build();
        transport_row.add_suffix(&transport_badge);
        group.add(&transport_row);

        let clipboard_row = adw::ActionRow::builder()
            .title("Clipboard policy")
            .subtitle("Trusted peers only")
            .build();
        clipboard_row.add_css_class("settings-summary-row");
        let clipboard_badge = gtk::Label::builder()
            .label("Trusted peers only")
            .css_classes(vec!["status-pill".to_string(), "caption".to_string()])
            .build();
        clipboard_row.add_suffix(&clipboard_badge);
        group.add(&clipboard_row);

        page.add(&group);
        SummarySectionHandles { group }
    }

    /// Build account settings section
    fn build_account_section(
        page: &adw::PreferencesPage,
        _settings: &Rc<RefCell<AppSettings>>,
    ) -> AccountSectionHandles {
        let group = adw::PreferencesGroup::builder()
            .title("Account")
            .description("Manage your SkyBridge account")
            .build();
        group.add_css_class("settings-panel");
        group.add_css_class("settings-overview-panel");

        let session = AuthenticationService::new()
            .ok()
            .and_then(|mut svc| svc.load_persisted_session().ok().flatten().cloned())
            .filter(|s| s.is_valid());

        let (row_title, row_subtitle, avatar_text, button_label, destructive) = match &session {
            Some(s) => {
                let email = s
                    .user
                    .email
                    .clone()
                    .unwrap_or_else(|| s.user.user_id.clone());
                let name = s.user.display_name.clone().unwrap_or_else(|| email.clone());
                ("Signed In", email, name, "Sign Out", true)
            }
            None => (
                "Not Signed In",
                "Sign in from the Login page to sync settings and profile".to_string(),
                "Guest".to_string(),
                "Sign In",
                false,
            ),
        };

        let session_state: Rc<RefCell<Option<skybridge_core::auth::AuthSession>>> =
            Rc::new(RefCell::new(session));

        // User info row
        let user_row = adw::ActionRow::builder()
            .title(row_title)
            .subtitle(&row_subtitle)
            .build();
        user_row.add_css_class("settings-summary-row");

        let avatar = adw::Avatar::builder()
            .size(40)
            .text(&avatar_text)
            .show_initials(true)
            .build();
        user_row.add_prefix(&avatar);

        // Sync status
        let sync_row = adw::ActionRow::builder()
            .title("Sync Status")
            .subtitle("Last synced: -")
            .build();
        sync_row.add_css_class("settings-summary-row");
        let sync_icon = utils::resolved_icon_name("emblem-synchronizing-symbolic");
        let sync_btn = gtk::Button::builder()
            .icon_name(&sync_icon)
            .valign(gtk::Align::Center)
            .css_classes(vec!["flat".to_string()])
            .tooltip_text("Sync now")
            .sensitive(session_state.borrow().is_some())
            .build();
        let sync_row_action = sync_row.clone();
        let sync_btn_action = sync_btn.clone();
        sync_btn.connect_clicked(move |_| {
            sync_row_action.set_subtitle("Syncing...");
            sync_btn_action.set_sensitive(false);
            let _ = sync_row_action.activate_action("app.sync-account", None);
        });
        sync_row.add_suffix(&sync_btn);

        let action_btn = gtk::Button::builder()
            .label(button_label)
            .valign(gtk::Align::Center)
            .css_classes(vec![
                if destructive {
                    "destructive-action"
                } else {
                    "suggested-action"
                }
                .to_string(),
            ])
            .build();
        let user_row_update = user_row.clone();
        let action_btn_update = action_btn.clone();
        let avatar_update = avatar.clone();
        let sync_row_update = sync_row.clone();
        let sync_btn_update = sync_btn.clone();
        let session_state_update = session_state.clone();
        action_btn.connect_clicked(move |_| {
            let signed_in = session_state_update.borrow().is_some();
            if signed_in {
                let mut svc = match AuthenticationService::new() {
                    Ok(svc) => svc,
                    Err(err) => {
                        tracing::warn!("Failed to init auth service for logout: {}", err);
                        return;
                    }
                };
                let _ = svc.load_persisted_session();
                if let Err(err) = svc.clear_local_session() {
                    tracing::warn!("Logout failed: {}", err);
                    return;
                }
                *session_state_update.borrow_mut() = None;
                user_row_update.set_title("Not Signed In");
                user_row_update
                    .set_subtitle("Sign in from the Login page to sync settings and profile");
                avatar_update.set_text(Some("Guest"));
                action_btn_update.set_label("Sign In");
                action_btn_update.set_css_classes(&["suggested-action"]);
                sync_row_update.set_subtitle("Last synced: -");
                sync_btn_update.set_sensitive(false);
            } else {
                let _ = user_row_update.activate_action("app.show-login", None);
            }
        });
        user_row.add_suffix(&action_btn);
        group.add(&user_row);
        group.add(&sync_row);

        page.add(&group);

        AccountSectionHandles {
            group,
            session: session_state,
            user_row,
            avatar,
            action_btn,
            sync_row,
            sync_btn,
        }
    }

    fn build_security_overview_section(
        page: &adw::PreferencesPage,
        settings: &Rc<RefCell<AppSettings>>,
    ) -> adw::PreferencesGroup {
        let group = adw::PreferencesGroup::builder()
            .title("Security")
            .description("Security section")
            .build();
        group.add_css_class("settings-panel");
        group.add_css_class("settings-overview-panel");
        group.set_visible(false);

        let security = &settings.borrow().security;
        let pqc_policy = if security.enable_pqc && security.prefer_hybrid {
            "Require PQC"
        } else if security.enable_pqc {
            "Pure PQC"
        } else {
            "Classic fallback"
        };
        let trusted_peer_count = TrustStore::load()
            .ok()
            .map(|store| store.list_peers().len())
            .unwrap_or(0);
        let fallback_cooldown = if security.allow_classic_only {
            "Enabled"
        } else {
            "Disabled"
        };

        for (title, subtitle) in [
            ("Post-quantum policy", pqc_policy.to_string()),
            ("Trusted KEM cache", format!("{} peers", trusted_peer_count)),
            ("Fallback cooldown", fallback_cooldown.to_string()),
        ] {
            let row = adw::ActionRow::builder()
                .title(title)
                .subtitle(&subtitle)
                .build();
            row.add_css_class("settings-summary-row");
            let badge = gtk::Label::builder()
                .label(&subtitle)
                .css_classes(vec!["status-pill".to_string(), "caption".to_string()])
                .build();
            row.add_suffix(&badge);
            group.add(&row);
        }

        page.add(&group);
        group
    }

    /// Build Supabase configuration section
    fn build_supabase_section(page: &adw::PreferencesPage) {
        let group = adw::PreferencesGroup::builder()
            .title("Supabase")
            .description("Shared auth config for macOS/iOS data interoperability")
            .build();

        let keyring_cfg = AuthenticationService::load_supabase_config().ok().flatten();
        let env_cfg = SupabaseConfig::from_env();
        let default_cfg = SupabaseConfig::default_config();
        let effective_cfg = keyring_cfg
            .clone()
            .or(env_cfg.clone())
            .or(default_cfg.clone());

        let initial_url = effective_cfg
            .as_ref()
            .map(|cfg| cfg.url.clone())
            .unwrap_or_default();
        let initial_key = effective_cfg
            .as_ref()
            .map(|cfg| cfg.anon_key.clone())
            .unwrap_or_default();

        let status_subtitle = if keyring_cfg.is_some() {
            "Configured (Keyring)"
        } else if env_cfg.is_some() {
            "Configured (Env)"
        } else if default_cfg.is_some() {
            "Configured (Default)"
        } else {
            "Not configured"
        };

        let status_row = adw::ActionRow::builder()
            .title("Status")
            .subtitle(status_subtitle)
            .build();
        group.add(&status_row);

        let url_row = adw::EntryRow::builder()
            .title("SUPABASE_URL")
            .text(&initial_url)
            .build();
        url_row.set_input_purpose(gtk::InputPurpose::Url);
        group.add(&url_row);

        let anon_row = adw::PasswordEntryRow::builder()
            .title("SUPABASE_ANON_KEY")
            .text(&initial_key)
            .build();
        group.add(&anon_row);

        let action_row = adw::ActionRow::builder().title("Actions").build();
        let save_button = gtk::Button::builder()
            .label("Save & Apply")
            .css_classes(vec!["suggested-action".to_string()])
            .build();
        let clear_button = gtk::Button::builder()
            .label("Clear")
            .css_classes(vec!["destructive-action".to_string()])
            .build();
        action_row.add_suffix(&save_button);
        action_row.add_suffix(&clear_button);
        group.add(&action_row);

        let url_ok = !url_row.text().is_empty();
        let key_ok = !anon_row.text().is_empty();
        save_button.set_sensitive(url_ok && key_ok);

        let status_row_save = status_row.clone();
        let url_row_save = url_row.clone();
        let anon_row_save = anon_row.clone();
        save_button.connect_clicked(move |_| {
            let url = url_row_save.text().to_string();
            let anon_key = anon_row_save.text().to_string();
            if url.trim().is_empty() || anon_key.trim().is_empty() {
                status_row_save.set_subtitle("Please provide SUPABASE_URL and SUPABASE_ANON_KEY");
                return;
            }
            match AuthenticationService::store_supabase_config(&url, &anon_key) {
                Ok(()) => {
                    status_row_save.set_subtitle("Saved to keyring. Re-login to apply.");
                }
                Err(err) => {
                    status_row_save.set_subtitle(&format!("Save failed: {}", err));
                }
            }
        });

        let status_row_clear = status_row.clone();
        let url_row_clear = url_row.clone();
        let anon_row_clear = anon_row.clone();
        let save_button_clear = save_button.clone();
        let default_url = default_cfg
            .as_ref()
            .map(|cfg| cfg.url.clone())
            .unwrap_or_default();
        let default_key = default_cfg
            .as_ref()
            .map(|cfg| cfg.anon_key.clone())
            .unwrap_or_default();
        clear_button.connect_clicked(move |_| {
            let _ = AuthenticationService::clear_supabase_config();
            url_row_clear.set_text(&default_url);
            anon_row_clear.set_text(&default_key);
            status_row_clear.set_subtitle("Reverted to default (re-login to apply)");
            save_button_clear.set_sensitive(!default_url.is_empty() && !default_key.is_empty());
        });

        let url_row_changed = url_row.clone();
        let anon_row_changed = anon_row.clone();
        let save_button_update = save_button.clone();
        url_row.connect_changed(move |_| {
            let url_ok = !url_row_changed.text().is_empty();
            let key_ok = !anon_row_changed.text().is_empty();
            save_button_update.set_sensitive(url_ok && key_ok);
        });

        let url_row_changed = url_row.clone();
        let anon_row_changed = anon_row.clone();
        let save_button_update = save_button.clone();
        anon_row.connect_changed(move |_| {
            let url_ok = !url_row_changed.text().is_empty();
            let key_ok = !anon_row_changed.text().is_empty();
            save_button_update.set_sensitive(url_ok && key_ok);
        });

        page.add(&group);
    }

    /// Build device settings section
    fn build_device_section(page: &adw::PreferencesPage, settings: &Rc<RefCell<AppSettings>>) {
        let group = adw::PreferencesGroup::builder()
            .title("This Device")
            .description("Configure device identity and capabilities")
            .build();

        // Device name
        let settings_clone = settings.clone();
        let name_row = adw::EntryRow::builder()
            .title("Device Name")
            .text(&settings.borrow().device.name)
            .build();
        name_row.connect_changed(move |entry| {
            settings_clone.borrow_mut().device.name = entry.text().to_string();
            let _ = settings_clone.borrow().save();
        });
        group.add(&name_row);

        // Platform (read-only)
        let platform_row = adw::ActionRow::builder()
            .title("Platform")
            .subtitle("Ubuntu Linux")
            .build();
        let platform_icon = utils::image_from_icon_name("computer-symbolic");
        platform_row.add_prefix(&platform_icon);
        group.add(&platform_row);

        // Device ID
        let device_id = settings.borrow().device.device_id.clone();
        let device_id_row = adw::ActionRow::builder()
            .title("Device ID")
            .subtitle(if device_id.is_empty() {
                "Unavailable"
            } else {
                device_id.as_str()
            })
            .build();
        let copy_btn = gtk::Button::builder()
            .icon_name("edit-copy-symbolic")
            .valign(gtk::Align::Center)
            .css_classes(vec!["flat".to_string()])
            .tooltip_text("Copy Device ID")
            .build();
        let settings_clone = settings.clone();
        copy_btn.connect_clicked(move |_| {
            let device_id = settings_clone.borrow().device.device_id.clone();
            if device_id.is_empty() {
                return;
            }
            if let Some(display) = gtk::gdk::Display::default() {
                display.clipboard().set_text(&device_id);
            }
        });
        device_id_row.add_suffix(&copy_btn);
        group.add(&device_id_row);

        // Device fingerprint
        let fingerprint = settings.borrow().device.public_key_fingerprint.clone();
        let fingerprint_row = adw::ActionRow::builder()
            .title("Device Fingerprint")
            .subtitle(if fingerprint.is_empty() {
                "Unavailable"
            } else {
                fingerprint.as_str()
            })
            .build();
        let fp_copy_btn = gtk::Button::builder()
            .icon_name("edit-copy-symbolic")
            .valign(gtk::Align::Center)
            .css_classes(vec!["flat".to_string()])
            .tooltip_text("Copy Fingerprint")
            .build();
        let settings_clone = settings.clone();
        fp_copy_btn.connect_clicked(move |_| {
            let fingerprint = settings_clone
                .borrow()
                .device
                .public_key_fingerprint
                .clone();
            if fingerprint.is_empty() {
                return;
            }
            if let Some(display) = gtk::gdk::Display::default() {
                display.clipboard().set_text(&fingerprint);
            }
        });
        fingerprint_row.add_suffix(&fp_copy_btn);
        group.add(&fingerprint_row);

        page.add(&group);

        // Capabilities group
        let cap_group = adw::PreferencesGroup::builder()
            .title("Device Capabilities")
            .description("Services this device offers to other devices")
            .build();

        let capabilities = [
            (
                DeviceCapability::FileTransfer,
                "File Transfer",
                "Send and receive files",
            ),
            (
                DeviceCapability::Clipboard,
                "Clipboard Sync",
                "Share clipboard between devices",
            ),
            (
                DeviceCapability::RemoteDesktopView,
                "Screen Sharing",
                "Allow others to view your screen",
            ),
            (
                DeviceCapability::RemoteDesktopControl,
                "Remote Control",
                "Allow others to control your device",
            ),
            (
                DeviceCapability::AudioStream,
                "Audio Streaming",
                "Stream audio to other devices",
            ),
        ];

        for (cap, title, subtitle) in capabilities {
            let settings_clone = settings.clone();
            let has_cap = settings.borrow().device.capabilities.contains(&cap);
            let row = adw::SwitchRow::builder()
                .title(title)
                .subtitle(subtitle)
                .active(has_cap)
                .build();

            row.connect_active_notify(move |switch| {
                let mut settings = settings_clone.borrow_mut();
                if switch.is_active() {
                    if !settings.device.capabilities.contains(&cap) {
                        settings.device.capabilities.push(cap);
                    }
                } else {
                    settings.device.capabilities.retain(|c| *c != cap);
                }
                let _ = settings.save();
            });
            cap_group.add(&row);
        }

        page.add(&cap_group);

        // Startup group
        let startup_group = adw::PreferencesGroup::builder().title("Startup").build();

        let settings_clone = settings.clone();
        let autostart_row = adw::SwitchRow::builder()
            .title("Start on Login")
            .subtitle("Launch SkyBridge when you log in")
            .active(settings.borrow().device.start_on_login)
            .build();
        autostart_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().device.start_on_login = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        startup_group.add(&autostart_row);

        let settings_clone = settings.clone();
        let tray_row = adw::SwitchRow::builder()
            .title("Show Tray Icon")
            .subtitle("Display icon in system tray")
            .active(settings.borrow().device.show_tray_icon)
            .build();
        tray_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().device.show_tray_icon = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        startup_group.add(&tray_row);

        let settings_clone = settings.clone();
        let minimize_row = adw::SwitchRow::builder()
            .title("Minimize to Tray")
            .subtitle("Hide window to tray instead of closing")
            .active(settings.borrow().device.minimize_to_tray)
            .build();
        minimize_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().device.minimize_to_tray = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        startup_group.add(&minimize_row);

        page.add(&startup_group);
    }

    /// Build transfer settings section
    fn build_transfer_section(page: &adw::PreferencesPage, settings: &Rc<RefCell<AppSettings>>) {
        let group = adw::PreferencesGroup::builder()
            .title("File Transfer")
            .description("Configure file transfer behavior")
            .build();

        // Save location
        let save_row = adw::ActionRow::builder()
            .title("Save Location")
            .subtitle(
                settings
                    .borrow()
                    .transfer
                    .save_location
                    .to_string_lossy()
                    .to_string(),
            )
            .activatable(true)
            .build();
        let folder_icon = gtk::Image::from_icon_name("folder-symbolic");
        save_row.add_suffix(&folder_icon);

        let settings_clone = settings.clone();
        save_row.connect_activated(move |row| {
            let dialog = gtk::FileDialog::builder()
                .title("Select Save Location")
                .modal(true)
                .build();

            let settings = settings_clone.clone();
            let row = row.clone();
            dialog.select_folder(gtk::Window::NONE, gio::Cancellable::NONE, move |result| {
                if let Ok(folder) = result
                    && let Some(path) = folder.path()
                {
                    settings.borrow_mut().transfer.save_location = path.clone();
                    row.set_subtitle(&path.to_string_lossy());
                    let _ = settings.borrow().save();
                }
            });
        });
        group.add(&save_row);

        // Compression strategy
        let compression_items = gtk::StringList::new(&[
            "Adaptive (Recommended)",
            "LZ4 (Fast, LAN)",
            "Zstd (Balanced)",
            "None",
        ]);
        let settings_clone = settings.clone();
        let compression_idx = match settings.borrow().transfer.compression {
            CompressionStrategy::Adaptive => 0,
            CompressionStrategy::Lz4 => 1,
            CompressionStrategy::Zstd => 2,
            CompressionStrategy::None => 3,
        };
        let compression_row = adw::ComboRow::builder()
            .title("Compression")
            .subtitle("Compression strategy for file transfers")
            .model(&compression_items)
            .selected(compression_idx)
            .build();
        compression_row.connect_selected_notify(move |combo| {
            let compression = match combo.selected() {
                0 => CompressionStrategy::Adaptive,
                1 => CompressionStrategy::Lz4,
                2 => CompressionStrategy::Zstd,
                _ => CompressionStrategy::None,
            };
            settings_clone.borrow_mut().transfer.compression = compression;
            let _ = settings_clone.borrow().save();
        });
        group.add(&compression_row);

        // Zstd level
        let settings_clone = settings.clone();
        let zstd_row = adw::SpinRow::builder()
            .title("Zstd Compression Level")
            .subtitle("Higher = better compression, slower (1-22)")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().transfer.zstd_level as f64,
                1.0,
                22.0,
                1.0,
                5.0,
                0.0,
            ))
            .build();
        zstd_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().transfer.zstd_level = spin.value() as i32;
            let _ = settings_clone.borrow().save();
        });
        group.add(&zstd_row);

        page.add(&group);

        // Performance group
        let perf_group = adw::PreferencesGroup::builder()
            .title("Performance")
            .build();

        // Chunk size
        let settings_clone = settings.clone();
        let chunk_row = adw::SpinRow::builder()
            .title("Chunk Size (MB)")
            .subtitle("Larger chunks reduce overhead, smaller enable finer resume")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().transfer.chunk_size_mb as f64,
                1.0,
                16.0,
                1.0,
                2.0,
                0.0,
            ))
            .build();
        chunk_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().transfer.chunk_size_mb = spin.value() as usize;
            let _ = settings_clone.borrow().save();
        });
        perf_group.add(&chunk_row);

        // Max concurrent
        let settings_clone = settings.clone();
        let concurrent_row = adw::SpinRow::builder()
            .title("Max Concurrent Transfers")
            .subtitle("Number of simultaneous file transfers")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().transfer.max_concurrent as f64,
                1.0,
                16.0,
                1.0,
                2.0,
                0.0,
            ))
            .build();
        concurrent_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().transfer.max_concurrent = spin.value() as usize;
            let _ = settings_clone.borrow().save();
        });
        perf_group.add(&concurrent_row);

        // Parallel chunks
        let settings_clone = settings.clone();
        let parallel_row = adw::SpinRow::builder()
            .title("Parallel Chunks")
            .subtitle("Number of chunks to transfer in parallel")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().transfer.max_parallel_chunks as f64,
                1.0,
                16.0,
                1.0,
                2.0,
                0.0,
            ))
            .build();
        parallel_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().transfer.max_parallel_chunks = spin.value() as usize;
            let _ = settings_clone.borrow().save();
        });
        perf_group.add(&parallel_row);

        page.add(&perf_group);

        // Behavior group
        let behavior_group = adw::PreferencesGroup::builder().title("Behavior").build();

        let settings_clone = settings.clone();
        let resume_row = adw::SwitchRow::builder()
            .title("Enable Resume")
            .subtitle("Save progress to resume interrupted transfers")
            .active(settings.borrow().transfer.enable_resume)
            .build();
        resume_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().transfer.enable_resume = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        behavior_group.add(&resume_row);

        let settings_clone = settings.clone();
        let verify_row = adw::SwitchRow::builder()
            .title("Verify Chunks")
            .subtitle("Use BLAKE3 hash to verify each chunk")
            .active(settings.borrow().transfer.verify_chunks)
            .build();
        verify_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().transfer.verify_chunks = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        behavior_group.add(&verify_row);

        let settings_clone = settings.clone();
        let auto_accept_row = adw::SwitchRow::builder()
            .title("Auto-accept from Trusted")
            .subtitle("Automatically accept transfers from trusted devices")
            .active(settings.borrow().transfer.auto_accept_trusted)
            .build();
        auto_accept_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().transfer.auto_accept_trusted = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        behavior_group.add(&auto_accept_row);

        let settings_clone = settings.clone();
        let overwrite_row = adw::SwitchRow::builder()
            .title("Confirm Overwrite")
            .subtitle("Ask before overwriting existing files")
            .active(settings.borrow().transfer.confirm_overwrite)
            .build();
        overwrite_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().transfer.confirm_overwrite = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        behavior_group.add(&overwrite_row);

        let settings_clone = settings.clone();
        let notify_row = adw::SwitchRow::builder()
            .title("Notification on Complete")
            .subtitle("Show notification when transfer completes")
            .active(settings.borrow().transfer.notify_on_complete)
            .build();
        notify_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().transfer.notify_on_complete = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        behavior_group.add(&notify_row);

        page.add(&behavior_group);
    }

    /// Build remote desktop settings section
    fn build_remote_desktop_section(
        page: &adw::PreferencesPage,
        settings: &Rc<RefCell<AppSettings>>,
    ) {
        let group = adw::PreferencesGroup::builder()
            .title("Remote Desktop")
            .description("Configure screen sharing and remote access")
            .build();

        // Hardware encoder detection
        let hw_status = if skybridge_core::remote::HardwareEncoder::is_nvenc_available() {
            "NVIDIA NVENC"
        } else if skybridge_core::remote::HardwareEncoder::is_vaapi_available() {
            "VAAPI (Intel/AMD)"
        } else {
            "Software (OpenH264)"
        };

        let hw_row = adw::ActionRow::builder()
            .title("Detected Encoder")
            .subtitle(hw_status)
            .build();
        let hw_icon = utils::image_from_icon_name("video-display-symbolic");
        hw_row.add_prefix(&hw_icon);
        group.add(&hw_row);

        // Video codec
        let codec_items =
            gtk::StringList::new(&["Auto (Production-safe)", "H.264", "H.265/HEVC", "AV1"]);
        let settings_clone = settings.clone();
        let codec_idx = match settings.borrow().remote_desktop.codec {
            VideoCodec::Auto => 0,
            VideoCodec::H264 => 1,
            VideoCodec::H265 => 2,
            VideoCodec::Av1 => 3,
        };
        let codec_row = adw::ComboRow::builder()
            .title("Video Codec")
            .subtitle("Codec for screen capture encoding")
            .model(&codec_items)
            .selected(codec_idx)
            .build();
        codec_row.connect_selected_notify(move |combo| {
            let codec = match combo.selected() {
                0 => VideoCodec::Auto,
                1 => VideoCodec::H264,
                2 => VideoCodec::H265,
                _ => VideoCodec::Av1,
            };
            settings_clone.borrow_mut().remote_desktop.codec = codec;
            let _ = settings_clone.borrow().save();
        });
        group.add(&codec_row);

        // Encoder preference
        let encoder_items = gtk::StringList::new(&[
            "Auto-detect (Recommended)",
            "NVIDIA NVENC",
            "VAAPI (Intel/AMD)",
            "Software",
        ]);
        let settings_clone = settings.clone();
        let encoder_idx = match settings.borrow().remote_desktop.hardware_encoder {
            HardwareEncoder::Auto => 0,
            HardwareEncoder::Nvenc => 1,
            HardwareEncoder::Vaapi => 2,
            HardwareEncoder::Software => 3,
        };
        let encoder_row = adw::ComboRow::builder()
            .title("Encoder")
            .subtitle("Hardware or software encoding")
            .model(&encoder_items)
            .selected(encoder_idx)
            .build();
        encoder_row.connect_selected_notify(move |combo| {
            let encoder = match combo.selected() {
                0 => HardwareEncoder::Auto,
                1 => HardwareEncoder::Nvenc,
                2 => HardwareEncoder::Vaapi,
                _ => HardwareEncoder::Software,
            };
            settings_clone.borrow_mut().remote_desktop.hardware_encoder = encoder;
            let _ = settings_clone.borrow().save();
        });
        group.add(&encoder_row);

        // Preset
        let preset_items = gtk::StringList::new(&[
            "Ultra Fast",
            "Very Fast",
            "Fast (Recommended)",
            "Medium",
            "Slow",
            "Low Latency",
        ]);
        let settings_clone = settings.clone();
        let preset_idx = match settings.borrow().remote_desktop.preset {
            EncoderPreset::UltraFast => 0,
            EncoderPreset::VeryFast => 1,
            EncoderPreset::Fast => 2,
            EncoderPreset::Medium => 3,
            EncoderPreset::Slow => 4,
            EncoderPreset::LowLatency => 5,
        };
        let preset_row = adw::ComboRow::builder()
            .title("Encoding Preset")
            .subtitle("Trade-off between speed and quality")
            .model(&preset_items)
            .selected(preset_idx)
            .build();
        preset_row.connect_selected_notify(move |combo| {
            let preset = match combo.selected() {
                0 => EncoderPreset::UltraFast,
                1 => EncoderPreset::VeryFast,
                2 => EncoderPreset::Fast,
                3 => EncoderPreset::Medium,
                4 => EncoderPreset::Slow,
                _ => EncoderPreset::LowLatency,
            };
            settings_clone.borrow_mut().remote_desktop.preset = preset;
            let _ = settings_clone.borrow().save();
        });
        group.add(&preset_row);

        page.add(&group);

        // Quality group
        let quality_group = adw::PreferencesGroup::builder().title("Quality").build();

        // Bitrate
        let settings_clone = settings.clone();
        let bitrate_row = adw::SpinRow::builder()
            .title("Bitrate (Mbps)")
            .subtitle("Target video bitrate")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().remote_desktop.bitrate_mbps as f64,
                1.0,
                50.0,
                1.0,
                5.0,
                0.0,
            ))
            .build();
        bitrate_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().remote_desktop.bitrate_mbps = spin.value() as u32;
            let _ = settings_clone.borrow().save();
        });
        quality_group.add(&bitrate_row);

        // Framerate
        let settings_clone = settings.clone();
        let fps_row = adw::SpinRow::builder()
            .title("Framerate (FPS)")
            .subtitle("Target frames per second")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().remote_desktop.framerate as f64,
                15.0,
                120.0,
                5.0,
                15.0,
                0.0,
            ))
            .build();
        fps_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().remote_desktop.framerate = spin.value() as u32;
            let _ = settings_clone.borrow().save();
        });
        quality_group.add(&fps_row);

        // Quality (CRF)
        let settings_clone = settings.clone();
        let crf_row = adw::SpinRow::builder()
            .title("Quality (CRF)")
            .subtitle("Lower = better quality, larger files (1-51)")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().remote_desktop.quality as f64,
                1.0,
                51.0,
                1.0,
                5.0,
                0.0,
            ))
            .build();
        crf_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().remote_desktop.quality = spin.value() as u8;
            let _ = settings_clone.borrow().save();
        });
        quality_group.add(&crf_row);

        page.add(&quality_group);

        // Options group
        let options_group = adw::PreferencesGroup::builder().title("Options").build();

        let settings_clone = settings.clone();
        let low_latency_row = adw::SwitchRow::builder()
            .title("Low Latency Mode")
            .subtitle("Optimize for minimal delay")
            .active(settings.borrow().remote_desktop.low_latency)
            .build();
        low_latency_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().remote_desktop.low_latency = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        options_group.add(&low_latency_row);

        let settings_clone = settings.clone();
        let tune_screen_row = adw::SwitchRow::builder()
            .title("Screen Content Tuning")
            .subtitle("Optimize for text and UI elements")
            .active(settings.borrow().remote_desktop.tune_screen)
            .build();
        tune_screen_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().remote_desktop.tune_screen = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        options_group.add(&tune_screen_row);

        let settings_clone = settings.clone();
        let cursor_row = adw::SwitchRow::builder()
            .title("Show Cursor")
            .subtitle("Include cursor in screen capture")
            .active(settings.borrow().remote_desktop.show_cursor)
            .build();
        cursor_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().remote_desktop.show_cursor = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        options_group.add(&cursor_row);

        // NOTE: Audio capture is not implemented in the Ubuntu build yet (no pipeline is wired).
        // Keep a non-interactive row to avoid a "clickable but ineffective" setting.
        let audio_row = adw::ActionRow::builder()
            .title("Capture Audio")
            .subtitle("Not available yet on Ubuntu")
            .build();
        let audio_badge = gtk::Label::builder()
            .label("Coming soon")
            .css_classes(vec!["caption".to_string(), "dim-label".to_string()])
            .valign(gtk::Align::Center)
            .build();
        audio_row.add_suffix(&audio_badge);
        options_group.add(&audio_row);

        page.add(&options_group);

        // Access control group
        let access_group = adw::PreferencesGroup::builder()
            .title("Access Control")
            .build();

        let settings_clone = settings.clone();
        let control_row = adw::SwitchRow::builder()
            .title("Allow Remote Control")
            .subtitle("Allow other devices to control this computer")
            .active(settings.borrow().remote_desktop.allow_control)
            .build();
        control_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().remote_desktop.allow_control = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        access_group.add(&control_row);

        let settings_clone = settings.clone();
        let confirm_row = adw::SwitchRow::builder()
            .title("Require Confirmation")
            .subtitle("Ask before allowing remote access")
            .active(settings.borrow().remote_desktop.require_confirmation)
            .build();
        confirm_row.connect_active_notify(move |switch| {
            settings_clone
                .borrow_mut()
                .remote_desktop
                .require_confirmation = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        access_group.add(&confirm_row);

        page.add(&access_group);
    }

    /// Build security settings section
    fn build_security_section(page: &adw::PreferencesPage, settings: &Rc<RefCell<AppSettings>>) {
        let group = adw::PreferencesGroup::builder()
            .title("Security")
            .description("Configure encryption and device trust")
            .build();

        // Current crypto suite info
        let crypto_info = adw::ActionRow::builder()
            .title("Encryption")
            .subtitle("X-Wing (Hybrid PQC) + AES-256-GCM + ML-DSA-65")
            .build();
        let lock_icon = utils::image_from_icon_name("channel-secure-symbolic");
        lock_icon.add_css_class("success");
        crypto_info.add_prefix(&lock_icon);
        group.add(&crypto_info);

        let settings_clone = settings.clone();
        let pqc_row = adw::SwitchRow::builder()
            .title("Post-Quantum Cryptography")
            .subtitle("Use quantum-resistant encryption (ML-KEM-768, ML-DSA-65)")
            .active(settings.borrow().security.enable_pqc)
            .build();
        pqc_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().security.enable_pqc = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        group.add(&pqc_row);

        let settings_clone = settings.clone();
        let hybrid_row = adw::SwitchRow::builder()
            .title("Prefer Hybrid Mode")
            .subtitle("X-Wing combines X25519 + ML-KEM-768 for dual protection")
            .active(settings.borrow().security.prefer_hybrid)
            .build();
        hybrid_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().security.prefer_hybrid = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        group.add(&hybrid_row);

        let settings_clone = settings.clone();
        let classic_row = adw::SwitchRow::builder()
            .title("Allow Classic-Only")
            .subtitle("Connect with devices that don't support PQC")
            .active(settings.borrow().security.allow_classic_only)
            .build();
        classic_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().security.allow_classic_only = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        group.add(&classic_row);

        page.add(&group);

        // Trust group
        let trust_group = adw::PreferencesGroup::builder()
            .title("Device Trust")
            .build();

        let settings_clone = settings.clone();
        let verify_row = adw::SwitchRow::builder()
            .title("Require Verification")
            .subtitle("Require a trusted pin or discovered fingerprint before outbound connect")
            .active(settings.borrow().security.require_verification)
            .build();
        verify_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().security.require_verification = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        trust_group.add(&verify_row);

        let settings_clone = settings.clone();
        let block_row = adw::SwitchRow::builder()
            .title("Block Unknown Devices")
            .subtitle("Only allow devices that already have a trusted fingerprint pin")
            .active(settings.borrow().security.block_unknown)
            .build();
        block_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().security.block_unknown = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        trust_group.add(&block_row);

        // Trusted devices count
        let trusted_row = adw::ExpanderRow::builder()
            .title("Trusted Devices")
            .subtitle("0 device(s)")
            .build();
        trust_group.add(&trusted_row);

        let trusted_rows: Rc<RefCell<Vec<adw::ActionRow>>> = Rc::new(RefCell::new(Vec::new()));
        let refresh_trusted: SharedVoidCallback = Rc::new(RefCell::new(None));
        let refresh_trusted_clone = refresh_trusted.clone();
        let trusted_row_refresh = trusted_row.clone();
        let trusted_rows_refresh = trusted_rows.clone();
        *refresh_trusted.borrow_mut() = Some(Box::new(move || {
            for row in trusted_rows_refresh.borrow_mut().drain(..) {
                trusted_row_refresh.remove(&row);
            }

            let peers = TrustStore::load()
                .map(|store| store.list_peers())
                .unwrap_or_default();
            trusted_row_refresh.set_subtitle(&format!("{} device(s)", peers.len()));

            if peers.is_empty() {
                let empty_row = adw::ActionRow::builder()
                    .title("No trusted devices")
                    .subtitle("Handshake with a device to add it here")
                    .build();
                trusted_row_refresh.add_row(&empty_row);
                trusted_rows_refresh.borrow_mut().push(empty_row);
                return;
            }

            for peer in peers {
                let subtitle = if peer.signing_fingerprint.is_empty() {
                    peer.signing_algorithm
                        .map(|alg| format!("{:?}", alg))
                        .unwrap_or_else(|| "Unknown".to_string())
                } else {
                    let alg = peer
                        .signing_algorithm
                        .map(|alg| format!("{:?}", alg))
                        .unwrap_or_else(|| "Unknown".to_string());
                    format!("{} • {}", alg, peer.signing_fingerprint)
                };

                let row = adw::ActionRow::builder()
                    .title(&peer.device_id)
                    .subtitle(&subtitle)
                    .build();
                let remove_btn = gtk::Button::builder()
                    .label("Remove")
                    .css_classes(vec!["destructive-action".to_string()])
                    .build();
                let peer_id = peer.device_id.clone();
                let refresh_trusted_inner = refresh_trusted_clone.clone();
                remove_btn.connect_clicked(move |_| {
                    if let Ok(mut store) = TrustStore::load() {
                        let _ = store.remove_peer(&peer_id);
                    }
                    if let Some(cb) = refresh_trusted_inner.borrow().as_ref() {
                        cb();
                    }
                });
                row.add_suffix(&remove_btn);

                trusted_row_refresh.add_row(&row);
                trusted_rows_refresh.borrow_mut().push(row);
            }
        }));

        if let Some(cb) = refresh_trusted.borrow().as_ref() {
            cb();
        }

        let settings_clone = settings.clone();
        let clear_keys_row = adw::SwitchRow::builder()
            .title("Clear Keys on Disconnect")
            .subtitle("Remove session keys when connection ends")
            .active(settings.borrow().security.clear_keys_on_disconnect)
            .build();
        clear_keys_row.connect_active_notify(move |switch| {
            settings_clone
                .borrow_mut()
                .security
                .clear_keys_on_disconnect = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        trust_group.add(&clear_keys_row);

        let clear_trust_row = adw::ActionRow::builder()
            .title("Clear Trust Store")
            .subtitle("Remove all trusted devices")
            .build();
        let clear_trust_btn = gtk::Button::builder()
            .label("Clear")
            .css_classes(vec!["destructive-action".to_string()])
            .build();
        clear_trust_row.add_suffix(&clear_trust_btn);
        trust_group.add(&clear_trust_row);

        let refresh_trusted_clear = refresh_trusted.clone();
        clear_trust_btn.connect_clicked(move |_| {
            if let Ok(mut store) = TrustStore::load() {
                let _ = store.clear_all();
            }
            if let Some(cb) = refresh_trusted_clear.borrow().as_ref() {
                cb();
            }
        });

        page.add(&trust_group);
    }

    /// Build network settings section
    fn build_network_section(page: &adw::PreferencesPage, settings: &Rc<RefCell<AppSettings>>) {
        let group = adw::PreferencesGroup::builder()
            .title("Network")
            .description("Configure network and discovery settings")
            .build();

        // QUIC port
        let settings_clone = settings.clone();
        let port_row = adw::SpinRow::builder()
            .title("QUIC Port")
            .subtitle("Port for P2P connections (restart required)")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().network.quic_port as f64,
                1024.0,
                65535.0,
                1.0,
                100.0,
                0.0,
            ))
            .build();
        port_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().network.quic_port = spin.value() as u16;
            let _ = settings_clone.borrow().save();
        });
        group.add(&port_row);

        // Remote control server toggle (macOS/iOS compatible, _skybridge-remote._tcp)
        let remote_row = adw::SwitchRow::builder()
            .title("Enable Remote Control Server")
            .subtitle(
                "Opt-in: expose macOS/iOS compatible remote view/control on your LAN (TCP 5901)",
            )
            .active(settings.borrow().network.enable_remote_control_server)
            .build();
        group.add(&remote_row);

        // Remote control port
        let settings_clone = settings.clone();
        let remote_port_row = adw::SpinRow::builder()
            .title("Remote Control Port")
            .subtitle("Restart required to apply")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().network.remote_control_port as f64,
                1024.0,
                65535.0,
                1.0,
                100.0,
                0.0,
            ))
            .build();
        remote_port_row.set_sensitive(settings.borrow().network.enable_remote_control_server);
        remote_port_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().network.remote_control_port = spin.value() as u16;
            let _ = settings_clone.borrow().save();
        });
        group.add(&remote_port_row);

        let settings_clone = settings.clone();
        let remote_port_row_toggle = remote_port_row.clone();
        remote_row.connect_active_notify(move |switch| {
            settings_clone
                .borrow_mut()
                .network
                .enable_remote_control_server = switch.is_active();
            remote_port_row_toggle.set_sensitive(switch.is_active());
            let _ = settings_clone.borrow().save();
        });

        // VNC server toggle
        let vnc_row = adw::SwitchRow::builder()
            .title("Enable VNC Server")
            .subtitle("Opt-in: legacy VNC server for third-party clients on your LAN")
            .active(settings.borrow().network.enable_vnc_server)
            .build();
        group.add(&vnc_row);

        // VNC port
        let settings_clone = settings.clone();
        let vnc_port_row = adw::SpinRow::builder()
            .title("VNC Port")
            .subtitle("Restart required to apply")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().network.vnc_port as f64,
                1024.0,
                65535.0,
                1.0,
                100.0,
                0.0,
            ))
            .build();
        vnc_port_row.set_sensitive(settings.borrow().network.enable_vnc_server);
        vnc_port_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().network.vnc_port = spin.value() as u16;
            let _ = settings_clone.borrow().save();
        });
        group.add(&vnc_port_row);

        let settings_clone = settings.clone();
        let vnc_port_row_toggle = vnc_port_row.clone();
        vnc_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().network.enable_vnc_server = switch.is_active();
            vnc_port_row_toggle.set_sensitive(switch.is_active());
            let _ = settings_clone.borrow().save();
        });

        // Transfer server toggle
        let transfer_row = adw::SwitchRow::builder()
            .title("Enable File Transfer Server")
            .subtitle("Accept incoming file transfers")
            .active(settings.borrow().network.enable_transfer_server)
            .build();
        group.add(&transfer_row);

        // Transfer port
        let settings_clone = settings.clone();
        let transfer_port_row = adw::SpinRow::builder()
            .title("Transfer Port")
            .subtitle("Restart required to apply")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().network.transfer_port as f64,
                1024.0,
                65535.0,
                1.0,
                100.0,
                0.0,
            ))
            .build();
        transfer_port_row.set_sensitive(settings.borrow().network.enable_transfer_server);
        transfer_port_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().network.transfer_port = spin.value() as u16;
            let _ = settings_clone.borrow().save();
        });
        group.add(&transfer_port_row);

        let settings_clone = settings.clone();
        let transfer_port_row_toggle = transfer_port_row.clone();
        transfer_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().network.enable_transfer_server = switch.is_active();
            transfer_port_row_toggle.set_sensitive(switch.is_active());
            let _ = settings_clone.borrow().save();
        });

        let settings_clone = settings.clone();
        let ipv6_row = adw::SwitchRow::builder()
            .title("Prefer IPv6")
            .subtitle("Use IPv6 when available")
            .active(settings.borrow().network.prefer_ipv6)
            .build();
        ipv6_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().network.prefer_ipv6 = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        group.add(&ipv6_row);

        page.add(&group);

        // Cross-network (WebRTC) group
        let webrtc_group = adw::PreferencesGroup::builder()
            .title("Cross-Network (WebRTC)")
            .description("Use WebRTC DataChannel over TURN/STUN when LAN P2P is not available")
            .build();

        let webrtc_row = adw::SwitchRow::builder()
            .title("Enable WebRTC")
            .subtitle("Allows cross-network connections using connection codes")
            .active(settings.borrow().network.enable_webrtc)
            .build();
        webrtc_group.add(&webrtc_row);

        let settings_clone = settings.clone();
        let signaling_row = adw::EntryRow::builder()
            .title("WebSocket URL")
            .text(settings.borrow().network.webrtc_signaling_url.clone())
            .build();
        signaling_row.set_sensitive(settings.borrow().network.enable_webrtc);
        signaling_row.connect_changed(move |row| {
            settings_clone.borrow_mut().network.webrtc_signaling_url = row.text().to_string();
            let _ = settings_clone.borrow().save();
        });
        webrtc_group.add(&signaling_row);

        let settings_clone = settings.clone();
        let signaling_server_row = adw::EntryRow::builder()
            .title("Control Plane URL")
            .text(
                settings
                    .borrow()
                    .network
                    .webrtc_signaling_server_url
                    .clone(),
            )
            .build();
        signaling_server_row.set_sensitive(settings.borrow().network.enable_webrtc);
        signaling_server_row.connect_changed(move |row| {
            settings_clone
                .borrow_mut()
                .network
                .webrtc_signaling_server_url = row.text().to_string();
            let _ = settings_clone.borrow().save();
        });
        webrtc_group.add(&signaling_server_row);

        let settings_clone = settings.clone();
        let api_key_row = adw::PasswordEntryRow::builder()
            .title("Client API Key")
            .text(settings.borrow().network.webrtc_client_api_key.clone())
            .build();
        api_key_row.set_sensitive(settings.borrow().network.enable_webrtc);
        api_key_row.connect_changed(move |row| {
            settings_clone.borrow_mut().network.webrtc_client_api_key = row.text().to_string();
            let _ = settings_clone.borrow().save();
        });
        webrtc_group.add(&api_key_row);

        let settings_clone = settings.clone();
        let stun_row = adw::EntryRow::builder()
            .title("STUN URL")
            .text(settings.borrow().network.webrtc_stun_url.clone())
            .build();
        stun_row.set_sensitive(settings.borrow().network.enable_webrtc);
        stun_row.connect_changed(move |row| {
            settings_clone.borrow_mut().network.webrtc_stun_url = row.text().to_string();
            let _ = settings_clone.borrow().save();
        });
        webrtc_group.add(&stun_row);

        let settings_clone = settings.clone();
        let turn_row = adw::EntryRow::builder()
            .title("TURN Override URL")
            .text(settings.borrow().network.webrtc_turn_url.clone())
            .build();
        turn_row.set_sensitive(settings.borrow().network.enable_webrtc);
        turn_row.connect_changed(move |row| {
            settings_clone.borrow_mut().network.webrtc_turn_url = row.text().to_string();
            let _ = settings_clone.borrow().save();
        });
        webrtc_group.add(&turn_row);

        let settings_clone = settings.clone();
        let turn_user_row = adw::EntryRow::builder()
            .title("TURN Override Username")
            .text(settings.borrow().network.webrtc_turn_username.clone())
            .build();
        turn_user_row.set_sensitive(settings.borrow().network.enable_webrtc);
        turn_user_row.connect_changed(move |row| {
            settings_clone.borrow_mut().network.webrtc_turn_username = row.text().to_string();
            let _ = settings_clone.borrow().save();
        });
        webrtc_group.add(&turn_user_row);

        let settings_clone = settings.clone();
        let turn_pass_row = adw::PasswordEntryRow::builder()
            .title("TURN Override Password")
            .text(settings.borrow().network.webrtc_turn_password.clone())
            .build();
        turn_pass_row.set_sensitive(settings.borrow().network.enable_webrtc);
        turn_pass_row.connect_changed(move |row| {
            settings_clone.borrow_mut().network.webrtc_turn_password = row.text().to_string();
            let _ = settings_clone.borrow().save();
        });
        webrtc_group.add(&turn_pass_row);

        let signaling_row_toggle = signaling_row.clone();
        let signaling_server_row_toggle = signaling_server_row.clone();
        let api_key_row_toggle = api_key_row.clone();
        let stun_row_toggle = stun_row.clone();
        let turn_row_toggle = turn_row.clone();
        let turn_user_row_toggle = turn_user_row.clone();
        let turn_pass_row_toggle = turn_pass_row.clone();
        let settings_clone = settings.clone();
        webrtc_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().network.enable_webrtc = switch.is_active();
            let enabled = switch.is_active();
            signaling_row_toggle.set_sensitive(enabled);
            signaling_server_row_toggle.set_sensitive(enabled);
            api_key_row_toggle.set_sensitive(enabled);
            stun_row_toggle.set_sensitive(enabled);
            turn_row_toggle.set_sensitive(enabled);
            turn_user_row_toggle.set_sensitive(enabled);
            turn_pass_row_toggle.set_sensitive(enabled);
            let _ = settings_clone.borrow().save();
        });

        page.add(&webrtc_group);

        // Discovery group
        let discovery_group = adw::PreferencesGroup::builder().title("Discovery").build();

        let settings_clone = settings.clone();
        let mdns_row = adw::SwitchRow::builder()
            .title("mDNS Discovery")
            .subtitle("Discover devices on local network")
            .active(settings.borrow().network.enable_mdns)
            .build();
        mdns_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().network.enable_mdns = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        discovery_group.add(&mdns_row);

        let settings_clone = settings.clone();
        let bluetooth_row = adw::SwitchRow::builder()
            .title("Bluetooth Discovery")
            .subtitle("Discover nearby devices via Bluetooth")
            .active(settings.borrow().network.enable_bluetooth)
            .build();
        bluetooth_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().network.enable_bluetooth = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        discovery_group.add(&bluetooth_row);

        let settings_clone = settings.clone();
        let wifi_direct_row = adw::SwitchRow::builder()
            .title("Wi-Fi Direct")
            .subtitle("Connect directly without router")
            .active(settings.borrow().network.enable_wifi_direct)
            .build();
        wifi_direct_row.connect_active_notify(move |switch| {
            settings_clone.borrow_mut().network.enable_wifi_direct = switch.is_active();
            let _ = settings_clone.borrow().save();
        });
        discovery_group.add(&wifi_direct_row);

        page.add(&discovery_group);

        // Timeouts group
        let timeout_group = adw::PreferencesGroup::builder().title("Timeouts").build();

        // NOTE: Connection timeout is not wired yet. Keep the UI free of ineffective controls.

        let settings_clone = settings.clone();
        let discovery_timeout_row = adw::SpinRow::builder()
            .title("Discovery Timeout (seconds)")
            .subtitle("Time to scan for devices")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().network.discovery_timeout_secs as f64,
                5.0,
                60.0,
                5.0,
                10.0,
                0.0,
            ))
            .build();
        discovery_timeout_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().network.discovery_timeout_secs = spin.value() as u32;
            let _ = settings_clone.borrow().save();
        });
        timeout_group.add(&discovery_timeout_row);

        let settings_clone = settings.clone();
        let lan_threshold_row = adw::SpinRow::builder()
            .title("LAN Latency Threshold (ms)")
            .subtitle("Below this latency, assume LAN connection")
            .adjustment(&gtk::Adjustment::new(
                settings.borrow().network.lan_latency_threshold_ms as f64,
                1.0,
                50.0,
                1.0,
                5.0,
                0.0,
            ))
            .build();
        lan_threshold_row.connect_value_notify(move |spin| {
            settings_clone.borrow_mut().network.lan_latency_threshold_ms = spin.value() as u32;
            let _ = settings_clone.borrow().save();
        });
        timeout_group.add(&lan_threshold_row);

        page.add(&timeout_group);
    }

    /// Build developer settings section
    fn build_developer_section(page: &adw::PreferencesPage, settings: &Rc<RefCell<AppSettings>>) {
        let group = adw::PreferencesGroup::builder()
            .title("Developer")
            .description("Advanced settings and diagnostics")
            .build();

        // Log level
        let log_items = gtk::StringList::new(&["Error", "Warn", "Info", "Debug", "Trace"]);
        let log_idx = match settings.borrow().developer.log_level {
            LogLevel::Error => 0,
            LogLevel::Warn => 1,
            LogLevel::Info => 2,
            LogLevel::Debug => 3,
            LogLevel::Trace => 4,
        };
        let settings_clone = settings.clone();
        let log_row = adw::ComboRow::builder()
            .title("Log Level")
            .subtitle("Applied on next launch")
            .model(&log_items)
            .selected(log_idx)
            .build();
        log_row.connect_selected_notify(move |combo| {
            let level = match combo.selected() {
                0 => LogLevel::Error,
                1 => LogLevel::Warn,
                2 => LogLevel::Info,
                3 => LogLevel::Debug,
                _ => LogLevel::Trace,
            };
            settings_clone.borrow_mut().developer.log_level = level;
            let _ = settings_clone.borrow().save();
        });
        group.add(&log_row);

        let status_row = adw::ActionRow::builder()
            .title("Settings Status")
            .subtitle("Ready")
            .build();
        group.add(&status_row);

        // Export settings
        let export_row = adw::ActionRow::builder()
            .title("Export Settings")
            .subtitle("Save settings to a JSON file")
            .build();
        let export_button = gtk::Button::builder()
            .label("Export")
            .css_classes(vec!["suggested-action".to_string()])
            .build();
        export_row.add_suffix(&export_button);
        group.add(&export_row);

        let settings_export = settings.clone();
        let status_export = status_row.clone();
        export_button.connect_clicked(move |_| {
            let dialog = gtk::FileDialog::builder()
                .title("Export Settings")
                .accept_label("Export")
                .build();
            let settings = settings_export.clone();
            let status = status_export.clone();
            dialog.save(gtk::Window::NONE, gio::Cancellable::NONE, move |result| {
                if let Ok(file) = result
                    && let Some(path) = file.path()
                {
                    match settings.borrow().save_to_path(&path) {
                        Ok(()) => status.set_subtitle("Exported settings successfully"),
                        Err(err) => status.set_subtitle(&format!("Export failed: {}", err)),
                    }
                }
            });
        });

        // Import settings
        let import_row = adw::ActionRow::builder()
            .title("Import Settings")
            .subtitle("Load settings from a JSON file")
            .build();
        let import_button = gtk::Button::builder()
            .label("Import")
            .css_classes(vec!["suggested-action".to_string()])
            .build();
        import_row.add_suffix(&import_button);
        group.add(&import_row);

        let settings_import = settings.clone();
        let status_import = status_row.clone();
        import_button.connect_clicked(move |_| {
            let dialog = gtk::FileDialog::builder().title("Import Settings").build();
            let settings = settings_import.clone();
            let status = status_import.clone();
            dialog.open(gtk::Window::NONE, gio::Cancellable::NONE, move |result| {
                if let Ok(file) = result
                    && let Some(path) = file.path()
                {
                    match AppSettings::load_from_path(&path) {
                        Ok(imported) => {
                            *settings.borrow_mut() = imported.clone();
                            let _ = imported.save();
                            status.set_subtitle("Imported settings. Restart recommended.");
                        }
                        Err(err) => {
                            status.set_subtitle(&format!("Import failed: {}", err));
                        }
                    }
                }
            });
        });

        page.add(&group);
    }

    /// Build about section
    fn build_about_section(page: &adw::PreferencesPage, settings: &Rc<RefCell<AppSettings>>) {
        let group = adw::PreferencesGroup::builder().title("About").build();

        // Version
        let version_row = adw::ActionRow::builder()
            .title("Version")
            .subtitle(env!("CARGO_PKG_VERSION"))
            .build();
        group.add(&version_row);

        // Protocol version
        let protocol_row = adw::ActionRow::builder()
            .title("Protocol Version")
            .subtitle(skybridge_core::PROTOCOL_VERSION)
            .build();
        group.add(&protocol_row);

        // Build info
        let build_row = adw::ActionRow::builder()
            .title("Build")
            .subtitle(format!(
                "Rust {} on {}",
                env!("CARGO_PKG_RUST_VERSION"),
                std::env::consts::OS
            ))
            .build();
        group.add(&build_row);

        page.add(&group);

        // Diagnostics group
        let diag_group = adw::PreferencesGroup::builder()
            .title("Diagnostics")
            .build();

        // Config directory
        let config_path = AppSettings::config_dir()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| "Unknown".to_string());
        let config_row = adw::ActionRow::builder()
            .title("Config Directory")
            .subtitle(&config_path)
            .activatable(true)
            .build();
        let folder_icon = gtk::Image::from_icon_name("folder-symbolic");
        config_row.add_suffix(&folder_icon);
        config_row.connect_activated(move |_| {
            if let Some(path) = AppSettings::config_dir() {
                let _ = std::process::Command::new("xdg-open").arg(path).spawn();
            }
        });
        diag_group.add(&config_row);

        // Data directory
        let data_path = AppSettings::data_dir()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| "Unknown".to_string());
        let data_row = adw::ActionRow::builder()
            .title("Data Directory")
            .subtitle(&data_path)
            .activatable(true)
            .build();
        let folder_icon = gtk::Image::from_icon_name("folder-symbolic");
        data_row.add_suffix(&folder_icon);
        data_row.connect_activated(move |_| {
            if let Some(path) = AppSettings::data_dir() {
                let _ = std::process::Command::new("xdg-open").arg(path).spawn();
            }
        });
        diag_group.add(&data_row);

        // View logs
        let logs_row = adw::ActionRow::builder()
            .title("View Logs")
            .subtitle("Open application logs")
            .activatable(true)
            .build();
        let chevron = gtk::Image::from_icon_name("go-next-symbolic");
        logs_row.add_suffix(&chevron);
        logs_row.connect_activated(move |_| {
            if let Some(cache_dir) = AppSettings::cache_dir() {
                let log_path = cache_dir.join("skybridge.log");
                let _ = std::process::Command::new("xdg-open").arg(log_path).spawn();
            }
        });
        diag_group.add(&logs_row);

        // Reset settings
        let reset_row = adw::ActionRow::builder()
            .title("Reset All Settings")
            .subtitle("Restore default settings (restart required)")
            .activatable(true)
            .build();
        reset_row.add_css_class("error");
        let reset_icon = gtk::Image::from_icon_name("edit-clear-all-symbolic");
        reset_row.add_suffix(&reset_icon);
        let settings_reset = settings.clone();
        let reset_row_status = reset_row.clone();
        reset_row.connect_activated(move |_| {
            let dialog = adw::AlertDialog::new(
                Some("Reset all settings?"),
                Some("This will restore defaults. Restart is required to apply all changes."),
            );
            dialog.add_response("cancel", "Cancel");
            dialog.add_response("reset", "Reset");
            dialog.set_response_appearance("reset", adw::ResponseAppearance::Destructive);

            let settings = settings_reset.clone();
            let reset_row = reset_row_status.clone();
            dialog.connect_response(None, move |dialog, response| {
                if response == "reset" {
                    match AppSettings::reset_on_disk() {
                        Ok(()) => {
                            *settings.borrow_mut() = AppSettings::load();
                            reset_row.set_subtitle("Reset complete. Restart required.");
                        }
                        Err(err) => {
                            reset_row.set_subtitle(&format!("Reset failed: {}", err));
                        }
                    }
                }
                dialog.close();
            });
            dialog.present(None::<&gtk::Window>);
        });
        diag_group.add(&reset_row);

        page.add(&diag_group);

        // Links group
        let links_group = adw::PreferencesGroup::builder().title("Links").build();

        let website_row = adw::ActionRow::builder()
            .title("Website")
            .subtitle("github.com/skybridge/compass")
            .activatable(true)
            .build();
        let link_icon = gtk::Image::from_icon_name("web-browser-symbolic");
        website_row.add_suffix(&link_icon);
        website_row.connect_activated(|_| {
            let _ = std::process::Command::new("xdg-open")
                .arg("https://github.com/skybridge/compass")
                .spawn();
        });
        links_group.add(&website_row);

        let report_row = adw::ActionRow::builder()
            .title("Report Issue")
            .subtitle("Submit a bug report or feature request")
            .activatable(true)
            .build();
        let bug_icon = gtk::Image::from_icon_name("dialog-warning-symbolic");
        report_row.add_suffix(&bug_icon);
        report_row.connect_activated(|_| {
            let _ = std::process::Command::new("xdg-open")
                .arg("https://github.com/skybridge/compass/issues")
                .spawn();
        });
        links_group.add(&report_row);

        let license_row = adw::ActionRow::builder()
            .title("License")
            .subtitle("Apache 2.0 / MIT")
            .build();
        links_group.add(&license_row);

        page.add(&links_group);
    }

    /// Get the settings state
    pub fn settings(&self) -> Rc<RefCell<AppSettings>> {
        self.settings.clone()
    }

    pub fn is_signed_in(&self) -> bool {
        self.account_session.borrow().is_some()
    }

    pub fn set_sync_busy(&self, busy: bool) {
        self.sync_busy.set(busy);
        let signed_in = self.account_session.borrow().is_some();
        self.sync_btn.set_sensitive(signed_in && !busy);
        if busy {
            self.sync_row.set_subtitle("Syncing...");
        }
    }

    pub fn set_sync_status(&self, subtitle: &str) {
        self.sync_row.set_subtitle(subtitle);
        let signed_in = self.account_session.borrow().is_some();
        self.sync_btn
            .set_sensitive(signed_in && !self.sync_busy.get());
    }

    pub fn show_default_overview(&self) {
        self.summary_group.set_description(Some("Default"));
        self.account_group.set_visible(true);
        self.security_overview_group.set_visible(false);
    }

    pub fn show_security_overview(&self) {
        self.summary_group.set_description(Some("Security section"));
        self.account_group.set_visible(false);
        self.security_overview_group.set_visible(true);
    }

    pub fn refresh_account_state(&self) {
        let session = AuthenticationService::new()
            .ok()
            .and_then(|mut svc| svc.load_persisted_session().ok().flatten().cloned())
            .filter(|s| s.is_valid());

        *self.account_session.borrow_mut() = session.clone();

        match session {
            Some(s) => {
                let email = s
                    .user
                    .email
                    .clone()
                    .unwrap_or_else(|| s.user.user_id.clone());
                let name = s.user.display_name.clone().unwrap_or_else(|| email.clone());

                self.account_row.set_title("Signed In");
                self.account_row.set_subtitle(&email);
                self.account_avatar.set_text(Some(&name));
                self.account_action_btn.set_label("Sign Out");
                self.account_action_btn
                    .set_css_classes(&["destructive-action"]);
            }
            None => {
                self.account_row.set_title("Not Signed In");
                self.account_row
                    .set_subtitle("Sign in from the Login page to sync settings and profile");
                self.account_avatar.set_text(Some("Guest"));
                self.account_action_btn.set_label("Sign In");
                self.account_action_btn
                    .set_css_classes(&["suggested-action"]);
            }
        }

        let signed_in = self.account_session.borrow().is_some();
        self.sync_btn
            .set_sensitive(signed_in && !self.sync_busy.get());
    }
}

impl Default for SettingsPage {
    fn default() -> Self {
        Self::new()
    }
}

struct AccountSectionHandles {
    group: adw::PreferencesGroup,
    session: Rc<RefCell<Option<skybridge_core::auth::AuthSession>>>,
    user_row: adw::ActionRow,
    avatar: adw::Avatar,
    action_btn: gtk::Button,
    sync_row: adw::ActionRow,
    sync_btn: gtk::Button,
}

struct SummarySectionHandles {
    group: adw::PreferencesGroup,
}
