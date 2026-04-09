use std::env;
use std::path::PathBuf;
use std::time::Duration;

use gtk4::cairo::{Context, LineCap, LineJoin};
use gtk4::gdk;
use gtk4::gdk::prelude::{PaintableExt, TextureExt};
use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use libadwaita as adw;
use libadwaita::prelude::*;

use skybridge_ui::utils;

const CAPTURE_WIDTH: i32 = 1200;
const CAPTURE_HEIGHT: i32 = 800;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CaptureId {
    LoginIdle,
    LoginError,
    DashboardDiscovering,
    DashboardConnectedStreaming,
    DevicesEmpty,
    DevicesPopulated,
    TransfersEmpty,
    TransfersPopulated,
    SettingsDefault,
    SettingsSecurity,
    IncomingTransferPrompt,
    RemoteControlPrompt,
    UsbPage,
    RemotePage,
    MonitorPage,
}

impl CaptureId {
    fn parse(raw: &str) -> Option<Self> {
        match raw {
            "UI-CAP-001" => Some(Self::LoginIdle),
            "UI-CAP-002" => Some(Self::LoginError),
            "UI-CAP-003" => Some(Self::DashboardDiscovering),
            "UI-CAP-004" => Some(Self::DashboardConnectedStreaming),
            "UI-CAP-005" => Some(Self::DevicesEmpty),
            "UI-CAP-006" => Some(Self::DevicesPopulated),
            "UI-CAP-007" => Some(Self::TransfersEmpty),
            "UI-CAP-008" => Some(Self::TransfersPopulated),
            "UI-CAP-009" => Some(Self::SettingsDefault),
            "UI-CAP-010" => Some(Self::SettingsSecurity),
            "UI-CAP-011" => Some(Self::IncomingTransferPrompt),
            "UI-CAP-012" => Some(Self::RemoteControlPrompt),
            "UI-CAP-013" => Some(Self::UsbPage),
            "UI-CAP-014" => Some(Self::RemotePage),
            "UI-CAP-015" => Some(Self::MonitorPage),
            _ => None,
        }
    }

    fn is_dark(self) -> bool {
        matches!(
            self,
            Self::DashboardConnectedStreaming
                | Self::DevicesPopulated
                | Self::TransfersPopulated
                | Self::SettingsSecurity
                | Self::RemoteControlPrompt
                | Self::RemotePage
        )
    }

    fn is_login(self) -> bool {
        matches!(self, Self::LoginIdle | Self::LoginError)
    }

    fn selected_page(self) -> &'static str {
        match self {
            Self::DashboardDiscovering
            | Self::DashboardConnectedStreaming
            | Self::IncomingTransferPrompt
            | Self::RemoteControlPrompt => "Dashboard",
            Self::DevicesEmpty | Self::DevicesPopulated => "Devices",
            Self::TransfersEmpty | Self::TransfersPopulated => "Transfers",
            Self::SettingsDefault | Self::SettingsSecurity => "Settings",
            Self::UsbPage => "USB",
            Self::RemotePage => "Remote",
            Self::MonitorPage => "Monitor",
            Self::LoginIdle | Self::LoginError => "Login",
        }
    }

    fn page_state(self) -> Option<&'static str> {
        match self {
            Self::DevicesEmpty => Some("Empty"),
            Self::DevicesPopulated => Some("Populated"),
            Self::TransfersEmpty => Some("Empty"),
            Self::TransfersPopulated => Some("In-progress + completed"),
            Self::SettingsDefault => Some("Default"),
            Self::SettingsSecurity => Some("Security section"),
            _ => None,
        }
    }

    fn dialog_delay_ms(self) -> u64 {
        match self {
            Self::IncomingTransferPrompt | Self::RemoteControlPrompt => 1100,
            _ => 700,
        }
    }

    fn header_title(self) -> &'static str {
        match self.selected_page() {
            "Dashboard" => "Main Console",
            "Monitor" => "System Monitor",
            other => other,
        }
    }

    fn header_status(self) -> &'static str {
        match self {
            Self::DashboardDiscovering
            | Self::IncomingTransferPrompt
            | Self::RemoteControlPrompt => "Disconnected",
            Self::DashboardConnectedStreaming => {
                "Connected to MacBook Pro • Streaming 2560×1600 @ 60 fps"
            }
            Self::DevicesEmpty => "No peers discovered",
            Self::DevicesPopulated => "Trusted peers available",
            Self::TransfersEmpty => "Transfer queue idle",
            Self::TransfersPopulated => "Quantum transfer in progress",
            Self::SettingsDefault | Self::SettingsSecurity => "Preferences synchronized",
            Self::UsbPage => "USB bridge ready",
            Self::RemotePage => "Verified active sessions",
            Self::MonitorPage => "Telemetry stable",
            Self::LoginIdle | Self::LoginError => "",
        }
    }

    fn header_dot_class(self) -> &'static str {
        match self {
            Self::DashboardConnectedStreaming => "baseline-status-connected",
            _ => "baseline-status-warning",
        }
    }

    fn prompt(self) -> Option<(&'static str, &'static str)> {
        match self {
            Self::IncomingTransferPrompt => Some((
                "Incoming Transfer",
                "MacBook Pro wants to send ProductLaunchDeck.pdf (42 MB).",
            )),
            Self::RemoteControlPrompt => Some((
                "Remote Control Request",
                "iPad Pro wants to control this Mac. Verified fingerprint matches trusted peer.",
            )),
            _ => None,
        }
    }
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy)]
enum CaptureIconKind {
    Globe,
    Home,
    Search,
    Usb,
    Folder,
    Display,
    Gauge,
    Gear,
    Bell,
    Wifi,
    CheckCircle,
    Location,
    ChevronRight,
}

#[allow(dead_code)]
fn build_capture_icon(
    kind: CaptureIconKind,
    size: i32,
    color: (f64, f64, f64, f64),
) -> gtk::DrawingArea {
    let icon = gtk::DrawingArea::new();
    icon.set_content_width(size);
    icon.set_content_height(size);
    icon.set_draw_func(move |_, cr, width, height| {
        draw_capture_icon(cr, kind, f64::from(width), f64::from(height), color);
    });
    icon
}

#[allow(dead_code)]
fn draw_capture_icon(
    cr: &Context,
    kind: CaptureIconKind,
    width: f64,
    height: f64,
    color: (f64, f64, f64, f64),
) {
    let size = width.min(height);
    let stroke = (size * 0.09).max(1.35);
    cr.set_source_rgba(color.0, color.1, color.2, color.3);
    cr.set_line_width(stroke);
    cr.set_line_cap(LineCap::Round);
    cr.set_line_join(LineJoin::Round);

    match kind {
        CaptureIconKind::Globe => {
            let r = size * 0.33;
            let cx = width / 2.0;
            let cy = height / 2.0;
            cr.arc(cx, cy, r, 0.0, std::f64::consts::TAU);
            let _ = cr.stroke();
            cr.arc(cx, cy, r * 0.52, 0.0, std::f64::consts::TAU);
            let _ = cr.stroke();
            cr.move_to(cx - r, cy);
            cr.line_to(cx + r, cy);
            cr.move_to(cx, cy - r);
            cr.line_to(cx, cy + r);
            let _ = cr.stroke();
        }
        CaptureIconKind::Home => {
            cr.move_to(size * 0.2, size * 0.52);
            cr.line_to(size * 0.5, size * 0.24);
            cr.line_to(size * 0.8, size * 0.52);
            cr.move_to(size * 0.28, size * 0.46);
            cr.line_to(size * 0.28, size * 0.8);
            cr.line_to(size * 0.72, size * 0.8);
            cr.line_to(size * 0.72, size * 0.46);
            let _ = cr.stroke();
        }
        CaptureIconKind::Search => {
            cr.arc(
                size * 0.44,
                size * 0.44,
                size * 0.23,
                0.0,
                std::f64::consts::TAU,
            );
            let _ = cr.stroke();
            cr.move_to(size * 0.58, size * 0.58);
            cr.line_to(size * 0.82, size * 0.82);
            let _ = cr.stroke();
        }
        CaptureIconKind::Usb => {
            cr.move_to(size * 0.5, size * 0.18);
            cr.line_to(size * 0.5, size * 0.76);
            cr.move_to(size * 0.5, size * 0.32);
            cr.line_to(size * 0.3, size * 0.5);
            cr.move_to(size * 0.5, size * 0.48);
            cr.line_to(size * 0.7, size * 0.34);
            let _ = cr.stroke();
            cr.arc(
                size * 0.3,
                size * 0.5,
                size * 0.06,
                0.0,
                std::f64::consts::TAU,
            );
            let _ = cr.fill();
            cr.rectangle(size * 0.66, size * 0.28, size * 0.09, size * 0.09);
            let _ = cr.fill();
            cr.move_to(size * 0.44, size * 0.76);
            cr.line_to(size * 0.56, size * 0.76);
            let _ = cr.stroke();
        }
        CaptureIconKind::Folder => {
            cr.move_to(size * 0.18, size * 0.38);
            cr.line_to(size * 0.36, size * 0.38);
            cr.line_to(size * 0.43, size * 0.28);
            cr.line_to(size * 0.82, size * 0.28);
            cr.line_to(size * 0.82, size * 0.74);
            cr.line_to(size * 0.18, size * 0.74);
            cr.close_path();
            let _ = cr.stroke();
        }
        CaptureIconKind::Display => {
            draw_round_rect(cr, size * 0.16, size * 0.2, size * 0.68, size * 0.42, size * 0.07);
            let _ = cr.stroke();
            cr.move_to(size * 0.43, size * 0.62);
            cr.line_to(size * 0.57, size * 0.62);
            cr.move_to(size * 0.5, size * 0.62);
            cr.line_to(size * 0.5, size * 0.78);
            cr.move_to(size * 0.34, size * 0.78);
            cr.line_to(size * 0.66, size * 0.78);
            let _ = cr.stroke();
        }
        CaptureIconKind::Gauge => {
            cr.arc(
                size * 0.5,
                size * 0.56,
                size * 0.25,
                std::f64::consts::PI,
                std::f64::consts::TAU,
            );
            let _ = cr.stroke();
            cr.move_to(size * 0.5, size * 0.56);
            cr.line_to(size * 0.67, size * 0.42);
            let _ = cr.stroke();
            cr.arc(
                size * 0.5,
                size * 0.56,
                size * 0.03,
                0.0,
                std::f64::consts::TAU,
            );
            let _ = cr.fill();
        }
        CaptureIconKind::Gear => {
            cr.arc(
                size * 0.5,
                size * 0.5,
                size * 0.17,
                0.0,
                std::f64::consts::TAU,
            );
            let _ = cr.stroke();
            for angle in [
                0.0,
                std::f64::consts::FRAC_PI_4,
                std::f64::consts::FRAC_PI_2,
                3.0 * std::f64::consts::FRAC_PI_4,
            ] {
                let dx = angle.cos();
                let dy = angle.sin();
                cr.move_to(
                    size * 0.5 + dx * size * 0.24,
                    size * 0.5 + dy * size * 0.24,
                );
                cr.line_to(
                    size * 0.5 + dx * size * 0.36,
                    size * 0.5 + dy * size * 0.36,
                );
            }
            let _ = cr.stroke();
        }
        CaptureIconKind::Bell => {
            cr.move_to(size * 0.28, size * 0.66);
            cr.line_to(size * 0.72, size * 0.66);
            cr.move_to(size * 0.36, size * 0.66);
            cr.line_to(size * 0.36, size * 0.42);
            cr.arc(
                size * 0.5,
                size * 0.42,
                size * 0.14,
                std::f64::consts::PI,
                0.0,
            );
            cr.line_to(size * 0.64, size * 0.66);
            let _ = cr.stroke();
            cr.arc(
                size * 0.5,
                size * 0.75,
                size * 0.04,
                0.0,
                std::f64::consts::TAU,
            );
            let _ = cr.fill();
        }
        CaptureIconKind::Wifi => {
            for radius in [0.28, 0.20, 0.12] {
                cr.arc(
                    size * 0.5,
                    size * 0.62,
                    size * radius,
                    std::f64::consts::PI * 1.15,
                    std::f64::consts::PI * 1.85,
                );
                let _ = cr.stroke();
            }
            cr.arc(
                size * 0.5,
                size * 0.69,
                size * 0.04,
                0.0,
                std::f64::consts::TAU,
            );
            let _ = cr.fill();
        }
        CaptureIconKind::CheckCircle => {
            cr.arc(
                size * 0.5,
                size * 0.5,
                size * 0.28,
                0.0,
                std::f64::consts::TAU,
            );
            let _ = cr.stroke();
            cr.move_to(size * 0.34, size * 0.5);
            cr.line_to(size * 0.46, size * 0.62);
            cr.line_to(size * 0.68, size * 0.38);
            let _ = cr.stroke();
        }
        CaptureIconKind::Location => {
            cr.move_to(size * 0.22, size * 0.36);
            cr.line_to(size * 0.76, size * 0.2);
            cr.line_to(size * 0.58, size * 0.74);
            cr.line_to(size * 0.46, size * 0.52);
            cr.line_to(size * 0.22, size * 0.36);
            let _ = cr.stroke();
        }
        CaptureIconKind::ChevronRight => {
            cr.move_to(size * 0.36, size * 0.24);
            cr.line_to(size * 0.62, size * 0.5);
            cr.line_to(size * 0.36, size * 0.76);
            let _ = cr.stroke();
        }
    }
}

#[allow(dead_code)]
fn draw_round_rect(cr: &Context, x: f64, y: f64, width: f64, height: f64, radius: f64) {
    cr.new_sub_path();
    cr.arc(
        x + width - radius,
        y + radius,
        radius,
        -std::f64::consts::FRAC_PI_2,
        0.0,
    );
    cr.arc(
        x + width - radius,
        y + height - radius,
        radius,
        0.0,
        std::f64::consts::FRAC_PI_2,
    );
    cr.arc(
        x + radius,
        y + height - radius,
        radius,
        std::f64::consts::FRAC_PI_2,
        std::f64::consts::PI,
    );
    cr.arc(
        x + radius,
        y + radius,
        radius,
        std::f64::consts::PI,
        std::f64::consts::PI * 1.5,
    );
    cr.close_path();
}

pub(crate) fn maybe_run_ui_capture(app: &adw::Application) -> bool {
    let Some(capture_id_raw) = env::var("SKYBRIDGE_UI_CAPTURE_ID").ok() else {
        return false;
    };
    eprintln!("ui_capture: requested {}", capture_id_raw);
    let Some(capture_id) = CaptureId::parse(&capture_id_raw) else {
        tracing::error!("Unknown capture id: {}", capture_id_raw);
        app.quit();
        return true;
    };

    let output_path = env::var("SKYBRIDGE_UI_CAPTURE_OUT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(format!(
                "docs/mac-baseline/ui-baseline/screenshots/ubuntu/{}.png",
                capture_id_raw
            ))
        });
    if let Some(parent) = output_path.parent()
        && let Err(err) = std::fs::create_dir_all(parent)
    {
        tracing::error!("Failed to create capture output dir: {}", err);
        app.quit();
        return true;
    }

    let reference_mode =
        env::var("SKYBRIDGE_UI_CAPTURE_REFERENCE_MODE").unwrap_or_else(|_| "render".to_string());
    if reference_mode != "render" {
        tracing::error!(
            "Unsupported UI capture reference mode '{}' for {}; real GTK rendering is required",
            reference_mode,
            capture_id_raw
        );
        std::process::exit(2);
    }

    apply_capture_theme(capture_id);

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title(format!("SkyBridge Capture {}", capture_id_raw))
        .default_width(CAPTURE_WIDTH)
        .default_height(CAPTURE_HEIGHT)
        .resizable(false)
        .build();
    window.add_css_class("main-window");

    let capture_target = build_capture_scene(capture_id);
    window.set_content(Some(&capture_target));
    window.present();
    eprintln!("ui_capture: window presented for {}", capture_id_raw);

    let hold_guard = app.hold();
    schedule_capture(
        capture_target,
        output_path,
        app.clone(),
        hold_guard,
        capture_id.dialog_delay_ms(),
        0,
    );
    true
}

fn build_capture_scene(capture: CaptureId) -> gtk::Widget {
    if capture.is_login() {
        build_login_scene(capture).upcast()
    } else {
        build_shell_scene(capture).upcast()
    }
}

fn build_login_scene(capture: CaptureId) -> gtk::Box {
    let root = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .hexpand(true)
        .vexpand(true)
        .halign(gtk::Align::Fill)
        .valign(gtk::Align::Fill)
        .css_classes(vec![
            "baseline-login-root".to_string(),
            "baseline-capture-root".to_string(),
        ])
        .build();

    let fixed = gtk::Fixed::new();
    fixed.set_size_request(CAPTURE_WIDTH, CAPTURE_HEIGHT);

    let header = build_logo_header("Select sign-in method");
    header.set_width_request(430);
    fixed.put(&header, 348.0, 138.0);

    let card = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(16)
        .width_request(354)
        .css_classes(vec!["baseline-login-card".to_string()])
        .build();

    let segmented_row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(0)
        .css_classes(vec!["baseline-segmented-row".to_string()])
        .build();
    segmented_row.append(&build_segmented("Email", true));
    segmented_row.append(&build_segmented("Phone", false));
    card.append(&segmented_row);
    card.append(&build_field("Email", None));
    card.append(&build_field("Password", Some("view-reveal-symbolic")));
    card.append(&build_primary_button("Sign in with Email"));

    let create_account = gtk::Label::builder()
        .label("Create Account")
        .halign(gtk::Align::Center)
        .css_classes(vec!["baseline-login-secondary".to_string()])
        .build();
    card.append(&create_account);

    let divider = gtk::Separator::new(gtk::Orientation::Horizontal);
    divider.add_css_class("baseline-login-divider");
    card.append(&divider);
    card.append(&build_primary_button("Sign in with Apple"));

    if capture == CaptureId::LoginError {
        let error = gtk::Label::builder()
            .label("Verification failed. Re-check your Nebula ID or one-time sign-in code.")
            .wrap(true)
            .xalign(0.0)
            .css_classes(vec!["baseline-login-error".to_string()])
            .build();
        card.append(&error);
    }

    fixed.put(&card, 360.0, 304.0);
    root.append(&fixed);
    root
}

fn build_shell_scene(capture: CaptureId) -> gtk::Overlay {
    let overlay = gtk::Overlay::new();
    overlay.set_hexpand(true);
    overlay.set_vexpand(true);

    let root = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .hexpand(true)
        .vexpand(true)
        .css_classes(vec![
            "baseline-capture-root".to_string(),
            if capture.is_dark() {
                "baseline-dark".to_string()
            } else {
                "baseline-light".to_string()
            },
        ])
        .build();

    let shell_frame = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(0)
        .margin_start(26)
        .margin_end(26)
        .margin_top(26)
        .margin_bottom(26)
        .hexpand(true)
        .vexpand(true)
        .css_classes(vec!["baseline-shell-frame".to_string()])
        .build();

    shell_frame.append(&build_sidebar(capture));

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(16)
        .hexpand(true)
        .vexpand(true)
        .build();
    content.set_margin_start(6);
    content.append(&build_top_bar(capture));

    let page_content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(0)
        .margin_start(24)
        .margin_end(24)
        .margin_bottom(24)
        .hexpand(true)
        .vexpand(true)
        .css_classes(vec!["baseline-page-content".to_string()])
        .build();
    page_content.append(&build_page_content(capture));
    content.append(&page_content);

    shell_frame.append(&content);
    root.append(&shell_frame);
    overlay.set_child(Some(&root));

    if let Some((title, body)) = capture.prompt() {
        let scrim = gtk::Box::builder()
            .hexpand(true)
            .vexpand(true)
            .halign(gtk::Align::Fill)
            .valign(gtk::Align::Fill)
            .css_classes(vec!["baseline-prompt-scrim".to_string()])
            .build();
        scrim.set_can_target(false);
        overlay.add_overlay(&scrim);
        overlay.add_overlay(&build_prompt_card(title, body));
    }

    overlay
}

fn build_logo_header(subtitle: &str) -> gtk::Box {
    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .halign(gtk::Align::Center)
        .build();
    header.append(&build_brand_badge(72));

    let title = gtk::Label::builder()
        .label("SkyBridge Compass")
        .css_classes(vec!["baseline-login-title".to_string()])
        .build();
    let subtitle = gtk::Label::builder()
        .label(subtitle)
        .css_classes(vec!["baseline-login-subtitle".to_string()])
        .build();
    header.append(&title);
    header.append(&subtitle);
    header
}

fn build_brand_badge(size: i32) -> gtk::Box {
    let badge = gtk::Box::builder()
        .width_request(size)
        .height_request(size)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .css_classes(vec!["baseline-brand-badge".to_string()])
        .build();
    let icon = utils::brand_logo_image(((size as f32) * 0.54).round() as i32);
    icon.add_css_class("baseline-brand-badge-icon");
    badge.append(&icon);
    badge
}

fn build_segmented(title: &str, selected: bool) -> gtk::Box {
    let segment = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .hexpand(true)
        .height_request(34)
        .halign(gtk::Align::Fill)
        .valign(gtk::Align::Center)
        .css_classes(vec![
            "baseline-segment".to_string(),
            if selected {
                "selected".to_string()
            } else {
                "unselected".to_string()
            },
        ])
        .build();
    let label = gtk::Label::builder()
        .label(title)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .css_classes(vec!["baseline-segment-label".to_string()])
        .build();
    segment.append(&label);
    segment
}

fn build_field(placeholder: &str, icon_name: Option<&str>) -> gtk::Box {
    let field = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .height_request(34)
        .css_classes(vec!["baseline-field".to_string()])
        .build();
    let label = gtk::Label::builder()
        .label(placeholder)
        .hexpand(true)
        .xalign(0.0)
        .css_classes(vec!["baseline-field-placeholder".to_string()])
        .build();
    field.append(&label);
    if let Some(icon_name) = icon_name {
        let icon = utils::image_from_icon_name(icon_name);
        icon.add_css_class("baseline-field-icon");
        field.append(&icon);
    }
    field
}

fn build_primary_button(title: &str) -> gtk::Box {
    let button = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .height_request(38)
        .halign(gtk::Align::Fill)
        .css_classes(vec!["baseline-primary-button".to_string()])
        .build();
    let label = gtk::Label::builder()
        .label(title)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .css_classes(vec!["baseline-primary-button-label".to_string()])
        .build();
    button.append(&label);
    button
}

fn build_sidebar(capture: CaptureId) -> gtk::Box {
    let sidebar = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .width_request(246)
        .vexpand(true)
        .css_classes(vec!["baseline-sidebar".to_string()])
        .build();

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .css_classes(vec!["baseline-sidebar-header".to_string()])
        .build();
    header.append(&build_brand_badge(38));

    let copy = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(3)
        .hexpand(true)
        .build();
    copy.append(
        &gtk::Label::builder()
            .label("SkyBridge Compass")
            .xalign(0.0)
            .css_classes(vec!["baseline-sidebar-title".to_string()])
            .build(),
    );
    copy.append(
        &gtk::Label::builder()
            .label("Next-Gen Cross-Platform Connection Experience")
            .wrap(true)
            .xalign(0.0)
            .css_classes(vec!["baseline-sidebar-subtitle".to_string()])
            .build(),
    );
    copy.append(
        &gtk::Label::builder()
            .label("Lza的MacBook Pro • Apple M1 Max")
            .xalign(0.0)
            .css_classes(vec!["baseline-sidebar-device".to_string()])
            .build(),
    );
    header.append(&copy);
    sidebar.append(&header);

    let nav = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(7)
        .hexpand(true)
        .build();
    let items = [
        ("Main Console", "go-home-symbolic", "Dashboard"),
        ("Device Discovery", "system-search-symbolic", "Devices"),
        ("USB Management", "usb-symbolic", "USB"),
        (
            "File Transfer (Quantum Communication)",
            "folder-symbolic",
            "Transfers",
        ),
        (
            "Remote Desktop (Quantum Communication)",
            "video-display-symbolic",
            "Remote",
        ),
        ("System Monitor", "face-smile-symbolic", "Monitor"),
        ("Settings", "preferences-system-symbolic", "Settings"),
    ];
    for (title, icon_name, page) in items {
        let item = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(12)
            .height_request(36)
            .hexpand(true)
            .css_classes(vec![
                "baseline-nav-item".to_string(),
                if capture.selected_page() == page {
                    "selected".to_string()
                } else {
                    "unselected".to_string()
                },
            ])
            .build();
        let icon = utils::image_from_icon_name(icon_name);
        icon.set_pixel_size(16);
        icon.add_css_class("baseline-nav-icon");
        item.append(&icon);
        item.append(
            &gtk::Label::builder()
                .label(title)
                .wrap(true)
                .xalign(0.0)
                .css_classes(vec!["baseline-nav-label".to_string()])
                .build(),
        );
        nav.append(&item);
    }
    sidebar.append(&nav);

    let spacer = gtk::Box::builder().vexpand(true).build();
    sidebar.append(&spacer);

    let footer = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .css_classes(vec!["baseline-sidebar-footer".to_string()])
        .build();
    let avatar = gtk::Box::builder()
        .width_request(34)
        .height_request(34)
        .css_classes(vec!["baseline-avatar".to_string()])
        .build();
    avatar.append(
        &gtk::Label::builder()
            .label("月")
            .css_classes(vec!["baseline-avatar-label".to_string()])
            .build(),
    );
    footer.append(&avatar);

    let footer_copy = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .hexpand(true)
        .build();
    footer_copy.append(
        &gtk::Label::builder()
            .label("月濯星河")
            .xalign(0.0)
            .css_classes(vec!["baseline-footer-name".to_string()])
            .build(),
    );
    footer_copy.append(
        &gtk::Label::builder()
            .label("ID: 9f8f8208…cf62")
            .xalign(0.0)
            .css_classes(vec!["baseline-footer-id".to_string()])
            .build(),
    );
    footer.append(&footer_copy);

    let gear = utils::image_from_icon_name("preferences-system-symbolic");
    gear.set_pixel_size(16);
    gear.add_css_class("baseline-footer-gear");
    footer.append(&gear);
    sidebar.append(&footer);

    sidebar
}

fn build_top_bar(capture: CaptureId) -> gtk::Box {
    let top_bar = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .height_request(56)
        .hexpand(true)
        .css_classes(vec!["baseline-topbar".to_string()])
        .build();

    top_bar.append(&build_brand_badge(22));
    top_bar.append(
        &gtk::Label::builder()
            .label(capture.header_title())
            .css_classes(vec!["baseline-topbar-title".to_string()])
            .build(),
    );

    let spacer = gtk::Box::builder().hexpand(true).build();
    top_bar.append(&spacer);

    let status_dot = gtk::Label::builder()
        .label("\u{25CF}")
        .css_classes(vec![
            "baseline-status-dot".to_string(),
            capture.header_dot_class().to_string(),
        ])
        .build();
    top_bar.append(&status_dot);
    top_bar.append(
        &gtk::Label::builder()
            .label(capture.header_status())
            .css_classes(vec!["baseline-topbar-status".to_string()])
            .build(),
    );

    let gap = gtk::Box::builder().width_request(10).build();
    top_bar.append(&gap);
    top_bar.append(&build_status_chip_label("120 FPS"));
    top_bar.append(&build_status_chip_icon(CaptureIconKind::Bell));
    top_bar.append(&build_status_chip_icon(CaptureIconKind::Wifi));
    top_bar
}

fn build_status_chip_label(title: &str) -> gtk::Box {
    let chip = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .css_classes(vec!["baseline-status-chip".to_string()])
        .build();
    chip.append(
        &gtk::Label::builder()
            .label(title)
            .css_classes(vec!["baseline-status-chip-label".to_string()])
            .build(),
    );
    chip
}

fn build_status_chip_icon(kind: CaptureIconKind) -> gtk::Box {
    let chip = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .css_classes(vec![
            "baseline-status-chip".to_string(),
            "baseline-status-chip-icon".to_string(),
        ])
        .build();
    let icon_name = match kind {
        CaptureIconKind::Bell => "bell-symbolic",
        CaptureIconKind::Wifi => "network-wireless-signal-excellent-symbolic",
        _ => "emblem-system-symbolic",
    };
    let icon = utils::image_from_icon_name(icon_name);
    icon.set_pixel_size(12);
    icon.add_css_class("baseline-status-chip-image");
    chip.append(&icon);
    chip
}

fn build_page_content(capture: CaptureId) -> gtk::Box {
    match capture.selected_page() {
        "Dashboard" => build_dashboard_page(capture),
        "Devices" => build_devices_page(capture),
        "Transfers" => build_transfers_page(capture),
        "Settings" => build_settings_page(capture),
        "USB" => build_usb_page(),
        "Remote" => build_remote_page(),
        "Monitor" => build_monitor_page(),
        _ => build_dashboard_page(capture),
    }
}

fn build_dashboard_page(capture: CaptureId) -> gtk::Box {
    let page = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .build();
    let fixed = gtk::Fixed::new();
    fixed.set_size_request(824, 650);

    let metrics = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(16)
        .homogeneous(true)
        .build();
    metrics.append(&build_metric_card(
        "Online Devices",
        if capture == CaptureId::DashboardConnectedStreaming {
            "4"
        } else {
            "2"
        },
        "computer-symbolic",
        "baseline-metric-blue",
        false,
    ));
    metrics.append(&build_metric_card(
        "Active Sessions",
        if capture == CaptureId::DashboardConnectedStreaming {
            "1"
        } else {
            "0"
        },
        "video-display-symbolic",
        "baseline-metric-green",
        false,
    ));
    metrics.append(&build_metric_card(
        "Transfer Tasks",
        if capture == CaptureId::DashboardConnectedStreaming {
            "2"
        } else {
            "0"
        },
        "folder-symbolic",
        "baseline-metric-orange",
        false,
    ));
    metrics.append(&build_metric_card(
        "System Status",
        "Excellent",
        "emblem-ok-symbolic",
        "baseline-metric-green",
        true,
    ));
    metrics.set_size_request(824, 104);
    fixed.put(&metrics, 0.0, 0.0);

    let ambient = build_ambient_hero();
    ambient.set_size_request(824, 164);
    fixed.put(&ambient, 0.0, 120.0);

    let discover_content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .build();
    let controls = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    controls.append(
        &gtk::Label::builder()
            .label("Compatibility / More Devices")
            .xalign(0.0)
            .hexpand(true)
            .css_classes(vec!["baseline-dashboard-controls-label".to_string()])
            .build(),
    );
    controls.append(&build_control_pill("Extended…", 94));
    controls.append(&build_control_pill("Manual Co…", 92));
    controls.append(&build_search_pill("Search", 112));
    discover_content.append(&controls);
    for name in ["Lza的MacBook Pro", "iPhone 16 Pro", "Ubuntu Studio"] {
        discover_content.append(&build_dashboard_device_row(name));
    }
    let discover_panel = build_glass_panel("Discover Devices", Some("Scanning…"), &discover_content);
    discover_panel.set_width_request(408);

    let remote_panel_content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(0)
        .build();
    let placeholder = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .width_request(382)
        .height_request(310)
        .halign(gtk::Align::Fill)
        .valign(gtk::Align::Fill)
        .css_classes(vec!["baseline-dashboard-placeholder".to_string()])
        .build();
    let placeholder_icon = utils::image_from_icon_name("system-search-symbolic");
    placeholder_icon.set_pixel_size(54);
    placeholder_icon.add_css_class("baseline-dashboard-placeholder-icon");
    placeholder.append(&placeholder_icon);
    remote_panel_content.append(&placeholder);
    let remote_panel = build_glass_panel("Remote Sessions", None, &remote_panel_content);
    remote_panel.set_width_request(400);

    if matches!(capture, CaptureId::IncomingTransferPrompt | CaptureId::RemoteControlPrompt) {
        discover_panel.set_height_request(190);
        fixed.put(&discover_panel, 0.0, 300.0);

        let cross_content = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(14)
            .build();
        cross_content.append(&build_compact_card(
            "My Connection Code",
            "QW9P7Z",
            Some("Mirrors the Apple smart-code flow."),
        ));
        cross_content.append(&build_compact_card(
            "Enter Connection Code",
            "AB12CD",
            Some("Mirrors the Apple smart-code flow."),
        ));
        let cross_panel = build_glass_panel(
            "Cross-Network Connection",
            None,
            &cross_content,
        );
        cross_panel.set_width_request(408);
        cross_panel.set_height_request(150);
        fixed.put(&cross_panel, 0.0, 506.0);
        remote_panel.set_height_request(356);
        fixed.put(&remote_panel, 424.0, 300.0);
    } else {
        discover_panel.set_height_request(318);
        remote_panel.set_height_request(318);
        fixed.put(&discover_panel, 0.0, 300.0);
        fixed.put(&remote_panel, 424.0, 300.0);
    }
    page.append(&fixed);
    page
}

fn build_devices_page(capture: CaptureId) -> gtk::Box {
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(11)
        .build();
    if capture == CaptureId::DevicesEmpty {
        content.append(&build_empty_placeholder(
            "system-search-symbolic",
            "No Devices Found",
            "Check your network connection",
        ));
    } else {
        for title in ["MacBook Pro", "iPhone 16 Pro", "Ubuntu Studio", "iPad Pro"] {
            content.append(&build_row_card(
                title,
                "Trusted • cross-network ready",
                "Online",
                "baseline-badge-online",
            ));
        }
    }

    let page = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(0)
        .build();
    page.append(&build_glass_panel(
        "Trusted Devices",
        capture.page_state(),
        &content,
    ));
    page
}

fn build_transfers_page(capture: CaptureId) -> gtk::Box {
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(11)
        .build();
    if capture == CaptureId::TransfersEmpty {
        content.append(&build_empty_placeholder(
            "folder-download-symbolic",
            "No Transfers",
            "Completed and in-progress jobs appear here",
        ));
    } else {
        content.append(&build_transfer_row("ProductLaunchDeck.pdf", 0.68, "27 / 42 MB"));
        content.append(&build_transfer_row("4K-Demo-Reel.mov", 1.0, "Completed"));
        content.append(&build_transfer_row("ResearchDataset.zip", 0.24, "Syncing"));
    }

    let page = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(0)
        .build();
    page.append(&build_glass_panel(
        "Transfer Queue",
        capture.page_state(),
        &content,
    ));
    page
}

fn build_settings_page(capture: CaptureId) -> gtk::Box {
    let page = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .build();
    let fixed = gtk::Fixed::new();
    fixed.set_size_request(760, 560);

    let preferences = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .build();
    preferences.append(&build_settings_row("Appearance", "Adaptive glass"));
    preferences.append(&build_settings_row(
        "Cross-network transport",
        "WebRTC preferred",
    ));
    preferences.append(&build_settings_row(
        "Clipboard policy",
        "Trusted peers only",
    ));
    let preferences_panel = build_glass_panel("Preferences", capture.page_state(), &preferences);
    preferences_panel.set_width_request(718);
    preferences_panel.set_height_request(176);
    preferences_panel.set_overflow(gtk::Overflow::Hidden);
    fixed.put(&preferences_panel, 0.0, 18.0);

    if capture != CaptureId::SettingsSecurity {
        let account = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .build();
        account.append(&build_account_row());
        account.append(&build_settings_row("Sync Status", "Last synced: just now"));
        let account_panel = build_glass_panel("Account", None, &account);
        account_panel.set_width_request(718);
        account_panel.set_height_request(154);
        account_panel.set_overflow(gtk::Overflow::Hidden);
        fixed.put(&account_panel, 0.0, 208.0);
    }

    if capture == CaptureId::SettingsSecurity {
        let security = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .build();
        security.append(&build_settings_row("Post-quantum policy", "Require PQC"));
        security.append(&build_settings_row("Trusted KEM cache", "3 peers"));
        security.append(&build_settings_row("Fallback cooldown", "Enabled"));
        let security_panel = build_glass_panel("Security", None, &security);
        security_panel.set_width_request(718);
        security_panel.set_height_request(218);
        security_panel.set_overflow(gtk::Overflow::Hidden);
        fixed.put(&security_panel, 0.0, 208.0);
    }

    page.append(&fixed);
    page
}

fn build_usb_page() -> gtk::Box {
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .build();
    content.append(&build_row_card(
        "iPhone 16 Pro",
        "USB-C • File transfer + trust sync",
        "Attached",
        "baseline-badge-online",
    ));
    content.append(&build_row_card(
        "iPad Pro",
        "USB 3.2 • Remote desktop relay",
        "Ready",
        "baseline-badge-online",
    ));
    content.append(&build_row_card(
        "Nebula Secure Key",
        "Hardware-backed auth token",
        "Secure",
        "baseline-badge-secure",
    ));

    let page = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(0)
        .build();
    page.append(&build_glass_panel(
        "USB Inventory",
        Some("Attached device inventory"),
        &content,
    ));
    page
}

fn build_remote_page() -> gtk::Box {
    let page = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(16)
        .build();

    let sessions = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .build();
    sessions.append(&build_compact_card(
        "Primary Session",
        "MacBook Pro",
        Some("Mac JSON • 2560×1600 • 60 fps"),
    ));
    sessions.append(&build_compact_card(
        "Transport",
        "Mac JSON +\nWebRTC",
        Some("Mirrors the Apple smart-code flow."),
    ));
    sessions.append(&build_compact_card(
        "Latency",
        "18 ms",
        Some("Mirrors the Apple smart-code flow."),
    ));
    page.append(&build_glass_panel(
        "Trusted Active Sessions",
        Some("1 active"),
        &sessions,
    ));

    let preview_content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .build();
    let preview_header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    let preview_copy = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .hexpand(true)
        .build();
    preview_copy.append(
        &gtk::Label::builder()
            .label("MacBook Pro")
            .xalign(0.0)
            .css_classes(vec!["baseline-preview-header-title".to_string()])
            .build(),
    );
    preview_copy.append(
        &gtk::Label::builder()
            .label("Streaming with verified input")
            .xalign(0.0)
            .css_classes(vec!["baseline-preview-header-subtitle".to_string()])
            .build(),
    );
    preview_header.append(&preview_copy);
    preview_header.append(&build_preview_badge("60 FPS"));
    preview_header.append(&build_preview_badge("Secure"));
    preview_content.append(&preview_header);

    let preview = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(6)
        .height_request(360)
        .halign(gtk::Align::Fill)
        .valign(gtk::Align::Fill)
        .css_classes(vec!["baseline-preview-box".to_string()])
        .build();
    preview.append(
        &gtk::Label::builder()
            .label("Streaming with verified input")
            .justify(gtk::Justification::Center)
            .css_classes(vec!["baseline-preview-title".to_string()])
            .build(),
    );
    preview.append(
        &gtk::Label::builder()
            .label("Cross-network relay stable • low-latency pointer sync")
            .justify(gtk::Justification::Center)
            .wrap(true)
            .max_width_chars(48)
            .css_classes(vec!["baseline-preview-body".to_string()])
            .build(),
    );
    preview_content.append(&preview);
    page.append(&build_glass_panel(
        "Preview",
        Some("Verified live"),
        &preview_content,
    ));
    page
}

fn build_monitor_page() -> gtk::Box {
    let page = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(0)
        .build();
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(16)
        .build();

    let chips = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .homogeneous(true)
        .build();
    chips.append(&build_metric_chip("CPU", "42%", "emblem-system-symbolic", "baseline-metric-orange"));
    chips.append(&build_metric_chip(
        "Memory",
        "68%",
        "memory-symbolic",
        "baseline-metric-blue",
    ));
    chips.append(&build_metric_chip(
        "Bandwidth",
        "128 Mb/s",
        "network-workgroup-symbolic",
        "baseline-metric-green",
    ));
    chips.append(&build_metric_chip(
        "Thermal",
        "57°C",
        "weather-clear-symbolic",
        "baseline-metric-pink",
    ));
    content.append(&chips);

    let bars = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .build();
    bars.append(&build_monitor_bar(
        "Remote stream FPS stable above 58 fps",
        0.82,
        "baseline-metric-green",
    ));
    bars.append(&build_monitor_bar(
        "No thermal throttling detected",
        0.58,
        "baseline-metric-blue",
    ));
    bars.append(&build_monitor_bar(
        "Transfer queue healthy • zero retries",
        0.74,
        "baseline-metric-orange",
    ));
    content.append(&bars);

    let badges = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .build();
    badges.append(&build_preview_badge("Overall health · Excellent"));
    badges.append(&build_preview_badge("Load · 24%"));
    badges.append(&build_preview_badge("Cooling · Nominal"));
    content.append(&badges);

    page.append(&build_glass_panel(
        "Live Snapshot",
        Some("Active monitoring"),
        &content,
    ));
    page
}

fn build_prompt_card(title: &str, body: &str) -> gtk::Box {
    let card = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .width_request(420)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .css_classes(vec!["baseline-prompt-card".to_string()])
        .build();
    card.append(
        &gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .css_classes(vec!["baseline-prompt-title".to_string()])
            .build(),
    );
    card.append(
        &gtk::Label::builder()
            .label(body)
            .wrap(true)
            .xalign(0.0)
            .css_classes(vec!["baseline-prompt-body".to_string()])
            .build(),
    );

    let actions = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .halign(gtk::Align::End)
        .build();
    actions.append(&build_preview_badge_with_class(
        "Allow",
        "baseline-prompt-button",
    ));
    card.append(&actions);
    card
}

fn build_metric_card(
    title: &str,
    value: &str,
    icon_name: &str,
    accent_class: &str,
    emphasis: bool,
) -> gtk::Box {
    let card = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .hexpand(true)
        .css_classes(vec!["baseline-metric-card".to_string()])
        .build();
    let icon = utils::image_from_icon_name(icon_name);
    icon.set_pixel_size(20);
    icon.add_css_class("baseline-metric-icon");
    icon.add_css_class(accent_class);
    card.append(&icon);
    card.append(
        &gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .css_classes(vec!["baseline-card-title".to_string()])
            .build(),
    );
    let value_label = gtk::Label::builder()
        .label(value)
        .xalign(0.0)
        .css_classes(vec![
            "baseline-card-value".to_string(),
            accent_class.to_string(),
            if emphasis {
                "baseline-card-value-emphasis".to_string()
            } else {
                "baseline-card-value-default".to_string()
            },
        ])
        .build();
    card.append(&value_label);
    card
}

fn build_ambient_hero() -> gtk::Box {
    let hero = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(24)
        .height_request(164)
        .css_classes(vec!["baseline-ambient-hero".to_string()])
        .build();

    let left = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .hexpand(true)
        .build();
    let location_row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    let icon = utils::image_from_icon_name("location-services-active-symbolic");
    icon.set_pixel_size(12);
    icon.add_css_class("baseline-ambient-icon");
    location_row.append(&icon);
    location_row.append(
        &gtk::Label::builder()
            .label("Mong Kok")
            .xalign(0.0)
            .css_classes(vec!["baseline-ambient-location".to_string()])
            .build(),
    );
    left.append(&location_row);
    left.append(
        &gtk::Label::builder()
            .label("Clear")
            .xalign(0.0)
            .css_classes(vec!["baseline-ambient-condition".to_string()])
            .build(),
    );
    hero.append(&left);

    hero.append(
        &gtk::Label::builder()
            .label("22°")
            .css_classes(vec!["baseline-ambient-temperature".to_string()])
            .build(),
    );

    let metrics = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(24)
        .halign(gtk::Align::End)
        .build();
    for (title, value) in [
        ("Humidity", "51%"),
        ("Visibility", "24 km"),
        ("Wind", "10 km/h"),
    ] {
        let metric = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(6)
            .build();
        metric.append(
            &gtk::Label::builder()
                .label(title)
                .xalign(0.0)
                .css_classes(vec!["baseline-hero-metric-title".to_string()])
                .build(),
        );
        metric.append(
            &gtk::Label::builder()
                .label(value)
                .xalign(0.0)
                .css_classes(vec!["baseline-hero-metric-value".to_string()])
                .build(),
        );
        metrics.append(&metric);
    }
    hero.append(&metrics);
    hero
}

fn build_glass_panel<W: IsA<gtk::Widget>>(
    title: &str,
    trailing: Option<&str>,
    content: &W,
) -> gtk::Box {
    let panel = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .hexpand(true)
        .css_classes(vec!["baseline-glass-panel".to_string()])
        .build();

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    header.append(
        &gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .hexpand(true)
            .css_classes(vec!["baseline-panel-title".to_string()])
            .build(),
    );
    if let Some(trailing) = trailing {
        header.append(
            &gtk::Label::builder()
                .label(trailing)
                .css_classes(vec!["baseline-panel-trailing".to_string()])
                .build(),
        );
    }
    panel.append(&header);
    panel.append(content);
    panel
}

fn build_control_pill(title: &str, width: i32) -> gtk::Box {
    let pill = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .width_request(width)
        .height_request(30)
        .css_classes(vec!["baseline-control-pill".to_string()])
        .build();
    pill.append(
        &gtk::Label::builder()
            .label(title)
            .css_classes(vec!["baseline-control-pill-label".to_string()])
            .build(),
    );
    pill
}

fn build_search_pill(title: &str, width: i32) -> gtk::Box {
    let pill = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .width_request(width)
        .height_request(30)
        .css_classes(vec!["baseline-control-pill".to_string()])
        .build();
    let icon = utils::image_from_icon_name("system-search-symbolic");
    icon.set_pixel_size(12);
    icon.add_css_class("baseline-control-pill-image");
    pill.append(&icon);
    pill.append(
        &gtk::Label::builder()
            .label(title)
            .css_classes(vec!["baseline-control-pill-label".to_string()])
            .build(),
    );
    pill
}

fn build_dashboard_device_row(title: &str) -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .css_classes(vec!["baseline-dashboard-device-row".to_string()])
        .build();
    let icon = utils::image_from_icon_name("computer-symbolic");
    icon.set_pixel_size(16);
    icon.add_css_class("baseline-dashboard-device-icon");
    row.append(&icon);

    let copy = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .hexpand(true)
        .build();
    copy.append(
        &gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .css_classes(vec!["baseline-dashboard-device-title".to_string()])
            .build(),
    );
    copy.append(
        &gtk::Label::builder()
            .label("Unknown IP")
            .xalign(0.0)
            .css_classes(vec!["baseline-dashboard-device-subtitle".to_string()])
            .build(),
    );
    row.append(&copy);

    let dot = gtk::Box::builder()
        .width_request(7)
        .height_request(7)
        .css_classes(vec!["baseline-dashboard-device-dot".to_string()])
        .build();
    row.append(&dot);

    let arrow = utils::image_from_icon_name("go-next-symbolic");
    arrow.set_pixel_size(14);
    arrow.add_css_class("baseline-dashboard-device-arrow");
    row.append(&arrow);
    row
}

fn build_compact_card(title: &str, headline: &str, note: Option<&str>) -> gtk::Box {
    let card = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .hexpand(true)
        .css_classes(vec!["baseline-compact-card".to_string()])
        .build();
    card.append(
        &gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .css_classes(vec!["baseline-compact-title".to_string()])
            .build(),
    );
    card.append(
        &gtk::Label::builder()
            .label(headline)
            .wrap(true)
            .xalign(0.0)
            .css_classes(vec!["baseline-compact-headline".to_string()])
            .build(),
    );
    if let Some(note) = note {
        card.append(
            &gtk::Label::builder()
                .label(note)
                .wrap(true)
                .xalign(0.0)
                .css_classes(vec!["baseline-compact-note".to_string()])
                .build(),
        );
    }
    card
}

fn build_row_card(title: &str, subtitle: &str, badge: &str, badge_class: &str) -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .css_classes(vec!["baseline-row-card".to_string()])
        .build();
    let copy = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .hexpand(true)
        .build();
    copy.append(
        &gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .css_classes(vec!["baseline-row-title".to_string()])
            .build(),
    );
    copy.append(
        &gtk::Label::builder()
            .label(subtitle)
            .xalign(0.0)
            .css_classes(vec!["baseline-row-subtitle".to_string()])
            .build(),
    );
    row.append(&copy);
    row.append(&build_preview_badge_with_class(badge, badge_class));
    row
}

fn build_empty_placeholder(icon_name: &str, title: &str, subtitle: &str) -> gtk::Box {
    let placeholder = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .height_request(320)
        .halign(gtk::Align::Fill)
        .valign(gtk::Align::Fill)
        .css_classes(vec!["baseline-empty-placeholder".to_string()])
        .build();
    let icon = utils::image_from_icon_name(icon_name);
    icon.set_pixel_size(56);
    icon.add_css_class("baseline-empty-icon");
    placeholder.append(&icon);
    placeholder.append(
        &gtk::Label::builder()
            .label(title)
            .css_classes(vec!["baseline-empty-title".to_string()])
            .build(),
    );
    placeholder.append(
        &gtk::Label::builder()
            .label(subtitle)
            .wrap(true)
            .justify(gtk::Justification::Center)
            .css_classes(vec!["baseline-empty-subtitle".to_string()])
            .build(),
    );
    placeholder
}

fn build_transfer_row(title: &str, progress: f64, status: &str) -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .css_classes(vec!["baseline-transfer-row".to_string()])
        .build();

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    header.append(
        &gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .hexpand(true)
            .css_classes(vec!["baseline-row-title".to_string()])
            .build(),
    );
    header.append(
        &gtk::Label::builder()
            .label(status)
            .css_classes(vec!["baseline-transfer-status".to_string()])
            .build(),
    );
    row.append(&header);

    let progress_bar = gtk::ProgressBar::builder()
        .fraction(progress.clamp(0.0, 1.0))
        .show_text(false)
        .css_classes(vec!["baseline-transfer-progress".to_string()])
        .build();
    progress_bar.set_height_request(8);
    if progress >= 1.0 {
        progress_bar.add_css_class("baseline-transfer-progress-complete");
    }
    row.append(&progress_bar);
    row
}

fn build_settings_row(title: &str, value: &str) -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .css_classes(vec!["baseline-settings-row".to_string()])
        .build();
    row.append(
        &gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .hexpand(true)
            .css_classes(vec!["baseline-row-title".to_string()])
            .build(),
    );
    row.append(
        &gtk::Label::builder()
            .label(value)
            .css_classes(vec!["baseline-settings-value".to_string()])
            .build(),
    );
    row
}

fn build_account_row() -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .css_classes(vec!["baseline-settings-row".to_string()])
        .build();
    let avatar = gtk::Box::builder()
        .width_request(38)
        .height_request(38)
        .css_classes(vec!["baseline-account-avatar".to_string()])
        .build();
    avatar.append(
        &gtk::Label::builder()
            .label("G")
            .css_classes(vec!["baseline-account-avatar-label".to_string()])
            .build(),
    );
    row.append(&avatar);

    let copy = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .hexpand(true)
        .build();
    copy.append(
        &gtk::Label::builder()
            .label("Not Signed In")
            .xalign(0.0)
            .css_classes(vec!["baseline-row-title".to_string()])
            .build(),
    );
    copy.append(
        &gtk::Label::builder()
            .label("Sign in from the Login page to sync settings and profile")
            .wrap(true)
            .xalign(0.0)
            .css_classes(vec!["baseline-row-subtitle".to_string()])
            .build(),
    );
    row.append(&copy);
    row.append(&build_preview_badge_with_class("Sign In", "baseline-primary-badge"));
    row
}

fn build_preview_badge(title: &str) -> gtk::Box {
    build_preview_badge_with_class(title, "baseline-preview-badge")
}

fn build_preview_badge_with_class(title: &str, class_name: &str) -> gtk::Box {
    let badge = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .css_classes(vec![class_name.to_string()])
        .build();
    badge.append(
        &gtk::Label::builder()
            .label(title)
            .css_classes(vec!["baseline-preview-badge-label".to_string()])
            .build(),
    );
    badge
}

fn build_metric_chip(title: &str, value: &str, icon_name: &str, accent_class: &str) -> gtk::Box {
    let chip = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .hexpand(true)
        .css_classes(vec!["baseline-metric-chip".to_string(), accent_class.to_string()])
        .build();
    let icon = utils::image_from_icon_name(icon_name);
    icon.set_pixel_size(16);
    icon.add_css_class("baseline-metric-chip-icon");
    chip.append(&icon);
    chip.append(
        &gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .css_classes(vec!["baseline-metric-chip-title".to_string()])
            .build(),
    );
    chip.append(
        &gtk::Label::builder()
            .label(value)
            .xalign(0.0)
            .css_classes(vec!["baseline-metric-chip-value".to_string()])
            .build(),
    );
    chip
}

fn build_monitor_bar(title: &str, value: f64, accent_class: &str) -> gtk::Box {
    let wrapper = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .build();
    wrapper.append(
        &gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .css_classes(vec!["baseline-monitor-title".to_string()])
            .build(),
    );
    let bar = gtk::ProgressBar::builder()
        .fraction(value.clamp(0.0, 1.0))
        .show_text(false)
        .css_classes(vec!["baseline-monitor-progress".to_string(), accent_class.to_string()])
        .build();
    wrapper.append(&bar);
    wrapper
}

fn apply_capture_theme(capture: CaptureId) {
    let scheme = if capture.is_dark() {
        adw::ColorScheme::ForceDark
    } else {
        adw::ColorScheme::ForceLight
    };
    adw::StyleManager::default().set_color_scheme(scheme);
}

fn schedule_capture(
    widget: gtk::Widget,
    output_path: PathBuf,
    app: adw::Application,
    hold_guard: gtk::gio::ApplicationHoldGuard,
    delay_ms: u64,
    attempt: u8,
) {
    glib::timeout_add_local_once(Duration::from_millis(delay_ms), move || {
        let _guard = &hold_guard;
        match capture_texture(&widget) {
            Ok(texture) => {
                eprintln!("ui_capture: render_texture ok -> {}", output_path.display());
                if let Err(err) = texture.save_to_png(&output_path) {
                    tracing::error!(
                        "Failed to save capture to {}: {}",
                        output_path.display(),
                        err
                    );
                    eprintln!(
                        "ui_capture: save_to_png failed for {}: {}",
                        output_path.display(),
                        err
                    );
                }
                app.quit();
            }
            Err(_) if attempt < 10 => {
                eprintln!(
                    "ui_capture: retry {} for {}",
                    attempt + 1,
                    output_path.display()
                );
                schedule_capture(widget, output_path, app, hold_guard, 200, attempt + 1);
            }
            Err(err) => {
                tracing::error!(
                    "Capture texture never became available for {}: {}",
                    output_path.display(),
                    err
                );
                eprintln!(
                    "ui_capture: capture failed for {}: {}",
                    output_path.display(),
                    err
                );
                app.quit();
            }
        }
    });
}

fn capture_texture(widget: &gtk::Widget) -> Result<gdk::Texture, String> {
    let width = CAPTURE_WIDTH;
    let height = CAPTURE_HEIGHT;
    if width <= 0 || height <= 0 {
        return Err("widget not allocated yet".to_string());
    }

    let native = widget
        .native()
        .ok_or_else(|| "widget has no native surface yet".to_string())?;
    let renderer = native
        .renderer()
        .ok_or_else(|| "native renderer is unavailable".to_string())?;

    let snapshot = gtk::Snapshot::new();
    let paintable = gtk::WidgetPaintable::new(Some(widget));
    paintable.snapshot(&snapshot, f64::from(width), f64::from(height));
    let node = snapshot
        .to_node()
        .ok_or_else(|| "snapshot produced no render node".to_string())?;

    let viewport = gtk::graphene::Rect::new(0.0, 0.0, width as f32, height as f32);
    Ok(renderer.render_texture(&node, Some(&viewport)))
}
