//! UI Utilities

use gtk4::prelude::*;
use gtk4::{self, Align, Orientation};
use libadwaita as adw;

fn fallback_icon_names(icon_name: &str) -> &'static [&'static str] {
    match icon_name {
        "com.skybridge.compass.ubuntu" => &["network-workgroup-symbolic", "view-grid-symbolic"],
        "go-home-symbolic" => &["view-grid-symbolic", "network-workgroup-symbolic"],
        "system-search-symbolic" => &["view-grid-symbolic", "computer-symbolic"],
        "applications-graphics-symbolic" => {
            &["preferences-system-symbolic", "emblem-system-symbolic"]
        }
        "computer-apple-symbolic" => &[
            "computer-symbolic",
            "network-workgroup-symbolic",
            "view-grid-symbolic",
        ],
        "computer-symbolic" => &["network-workgroup-symbolic", "view-grid-symbolic"],
        "phone-symbolic" | "phone-apple-iphone-symbolic" => {
            &["network-workgroup-symbolic", "computer-symbolic"]
        }
        "usb-symbolic" => &["drive-harddisk-symbolic", "folder-symbolic"],
        "video-display-symbolic" => &[
            "network-wireless-symbolic",
            "network-workgroup-symbolic",
            "view-grid-symbolic",
        ],
        "checkmark.seal-symbolic" => &["emblem-ok-symbolic"],
        "speedometer-symbolic" => &["network-wireless-symbolic", "view-grid-symbolic"],
        "activity-symbolic" => &["face-smile-symbolic", "network-workgroup-symbolic"],
        "cpu-symbolic" => &["emblem-system-symbolic", "view-grid-symbolic"],
        "memory-symbolic" => &["folder-symbolic", "view-grid-symbolic"],
        "preferences-system-symbolic" => &["emblem-system-symbolic", "view-grid-symbolic"],
        "emblem-synchronizing-symbolic" => &["view-refresh-symbolic"],
        "channel-secure-symbolic" => &["emblem-ok-symbolic", "dialog-password-symbolic"],
        _ => &[],
    }
}

/// Resolve an icon name against the current icon theme with sensible fallbacks.
pub fn resolved_icon_name(icon_name: &str) -> String {
    if let Some(display) = gtk4::gdk::Display::default() {
        let theme = gtk4::IconTheme::for_display(&display);
        for candidate in
            std::iter::once(icon_name).chain(fallback_icon_names(icon_name).iter().copied())
        {
            if theme.has_icon(candidate) {
                return candidate.to_string();
            }
        }
    }

    fallback_icon_names(icon_name)
        .first()
        .copied()
        .unwrap_or(icon_name)
        .to_string()
}

/// Create an image from an icon name with theme-aware fallbacks.
pub fn image_from_icon_name(icon_name: &str) -> gtk4::Image {
    gtk4::Image::from_icon_name(&resolved_icon_name(icon_name))
}

/// Create a button from an icon name with theme-aware fallbacks.
pub fn button_from_icon_name(icon_name: &str) -> gtk4::Button {
    gtk4::Button::from_icon_name(&resolved_icon_name(icon_name))
}

/// Create the bundled SkyBridge brand logo image.
pub fn brand_logo_image(pixel_size: i32) -> gtk4::Image {
    let bytes = gtk4::glib::Bytes::from_static(include_bytes!(
        "../../assets/icons/skybridge-app-icon-512.png"
    ));

    match gtk4::gdk::Texture::from_bytes(&bytes) {
        Ok(texture) => {
            let image = gtk4::Image::from_paintable(Some(&texture));
            image.set_pixel_size(pixel_size);
            image
        }
        Err(_) => {
            let image = image_from_icon_name("com.skybridge.compass.ubuntu");
            image.set_pixel_size(pixel_size);
            image
        }
    }
}

pub struct ShellHeader {
    pub header: adw::HeaderBar,
    pub status_label: gtk4::Label,
    pub status_dot: gtk4::Label,
    pub actions_box: gtk4::Box,
}

fn theme_toggle_button() -> gtk4::Button {
    let button = gtk4::Button::builder()
        .icon_name(resolved_icon_name("applications-graphics-symbolic"))
        .tooltip_text("Toggle light and dark appearance")
        .build();
    button.add_css_class("flat");
    button.add_css_class("circular");
    button.add_css_class("page-header-action");
    button.connect_clicked(|_| {
        let style_manager = adw::StyleManager::default();
        let next_scheme = if style_manager.is_dark() {
            adw::ColorScheme::ForceLight
        } else {
            adw::ColorScheme::ForceDark
        };
        style_manager.set_color_scheme(next_scheme);
    });
    button
}

pub fn build_shell_header(title: &str, status_text: &str, status_class: &str) -> ShellHeader {
    let header = adw::HeaderBar::builder()
        .css_classes(vec!["page-header".to_string(), "shell-topbar".to_string()])
        .build();

    let title_box = gtk4::Box::builder()
        .orientation(Orientation::Horizontal)
        .spacing(12)
        .build();
    let app_icon = brand_logo_image(24);
    app_icon.add_css_class("page-brand-icon");
    let title_label = gtk4::Label::builder()
        .label(title)
        .css_classes(vec!["title".to_string(), "page-title".to_string()])
        .build();
    title_box.append(&app_icon);
    title_box.append(&title_label);
    header.set_title_widget(Some(&title_box));

    let actions_box = gtk4::Box::builder()
        .orientation(Orientation::Horizontal)
        .spacing(10)
        .valign(Align::Center)
        .build();

    let status_capsule = gtk4::Box::builder()
        .orientation(Orientation::Horizontal)
        .spacing(8)
        .css_classes(vec!["page-status-capsule".to_string()])
        .valign(Align::Center)
        .build();
    let status_dot = gtk4::Label::builder()
        .label("\u{25CF}")
        .css_classes(vec![
            "status-indicator".to_string(),
            status_class.to_string(),
        ])
        .valign(Align::Center)
        .build();
    let status_label = gtk4::Label::builder()
        .label(status_text)
        .css_classes(vec!["page-status".to_string()])
        .valign(Align::Center)
        .build();
    status_capsule.append(&status_dot);
    status_capsule.append(&status_label);
    actions_box.append(&status_capsule);

    let fps_chip = gtk4::Label::builder()
        .label("120 FPS")
        .css_classes(vec!["status-pill".to_string(), "caption".to_string()])
        .valign(Align::Center)
        .build();
    actions_box.append(&fps_chip);

    let bell_button = button_from_icon_name("bell-symbolic");
    bell_button.set_tooltip_text(Some("Notifications"));
    bell_button.add_css_class("flat");
    bell_button.add_css_class("circular");
    bell_button.add_css_class("page-header-action");
    actions_box.append(&bell_button);

    let theme_button = theme_toggle_button();
    actions_box.append(&theme_button);

    header.pack_end(&actions_box);

    ShellHeader {
        header,
        status_label,
        status_dot,
        actions_box,
    }
}

/// Initialize CSS styling
pub fn init_css() {
    let provider = gtk4::CssProvider::new();
    provider.load_from_string(include_str!("style.css"));

    gtk4::style_context_add_provider_for_display(
        &gtk4::gdk::Display::default().expect("Could not get display"),
        &provider,
        gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}
