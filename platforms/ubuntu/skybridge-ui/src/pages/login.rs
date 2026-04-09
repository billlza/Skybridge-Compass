//! Login Page

use gtk4::prelude::*;
use gtk4::{self as gtk};

use crate::utils;

/// Login page
pub struct LoginPage {
    /// Root widget
    pub widget: gtk::Box,
    /// Email entry
    email_entry: gtk::Entry,
    /// Password entry
    password_entry: gtk::PasswordEntry,
    /// Login button
    login_button: gtk::Button,
    /// Register button
    register_button: gtk::Button,
    /// Phone number entry
    phone_entry: gtk::Entry,
    /// SMS code entry
    phone_code_entry: gtk::Entry,
    /// Send code button
    send_code_button: gtk::Button,
    /// Phone login button
    phone_login_button: gtk::Button,
    /// Apple login button
    apple_button: gtk::Button,
    /// Status label
    status_label: gtk::Label,
}

impl LoginPage {
    /// Create a new login page
    pub fn new() -> Self {
        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .hexpand(true)
            .vexpand(true)
            .css_classes(vec!["page-root".to_string(), "login-root".to_string()])
            .build();

        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(18)
            .margin_start(32)
            .margin_end(32)
            .margin_top(32)
            .margin_bottom(32)
            .valign(gtk::Align::Center)
            .halign(gtk::Align::Center)
            .css_classes(vec!["login-content".to_string()])
            .build();

        // Logo/Title
        let logo = utils::brand_logo_image(40);
        logo.add_css_class("login-brand-icon");
        content.append(&logo);

        let title = gtk::Label::builder()
            .label("SkyBridge Compass")
            .css_classes(vec!["title-1".to_string(), "login-title".to_string()])
            .build();
        content.append(&title);

        let subtitle = gtk::Label::builder()
            .label("Select sign-in method")
            .css_classes(vec!["dim-label".to_string(), "login-subtitle".to_string()])
            .build();
        content.append(&subtitle);

        // Form container
        let form = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .width_request(340)
            .css_classes(vec!["login-box".to_string()])
            .build();

        let method_stack = gtk::Stack::builder()
            .transition_type(gtk::StackTransitionType::Crossfade)
            .build();

        let switcher = gtk::StackSwitcher::builder()
            .stack(&method_stack)
            .halign(gtk::Align::Center)
            .css_classes(vec!["login-method-switcher".to_string()])
            .build();
        form.append(&switcher);

        let email_form = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .build();

        let email_entry = gtk::Entry::builder()
            .placeholder_text("Email")
            .input_purpose(gtk::InputPurpose::Email)
            .build();
        email_form.append(&email_entry);

        let password_entry = gtk::PasswordEntry::builder()
            .placeholder_text("Password")
            .show_peek_icon(true)
            .build();
        email_form.append(&password_entry);

        let login_button = gtk::Button::builder()
            .label("Sign in with Email")
            .css_classes(vec!["suggested-action".to_string()])
            .build();
        email_form.append(&login_button);

        let register_button = gtk::Button::builder()
            .label("Create Account")
            .css_classes(vec!["flat".to_string()])
            .build();
        email_form.append(&register_button);

        method_stack.add_titled(&email_form, Some("email"), "Email");

        let phone_form = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .build();

        let phone_entry = gtk::Entry::builder()
            .placeholder_text("Phone number (+86...)")
            .input_purpose(gtk::InputPurpose::Phone)
            .build();
        phone_form.append(&phone_entry);

        let phone_code_entry = gtk::Entry::builder()
            .placeholder_text("SMS code")
            .input_purpose(gtk::InputPurpose::Digits)
            .build();
        phone_form.append(&phone_code_entry);

        let send_code_button = gtk::Button::builder()
            .label("Send sign-in code")
            .css_classes(vec!["flat".to_string()])
            .build();
        phone_form.append(&send_code_button);

        let phone_login_button = gtk::Button::builder()
            .label("Verify Sign In")
            .css_classes(vec!["suggested-action".to_string()])
            .build();
        phone_form.append(&phone_login_button);

        method_stack.add_titled(&phone_form, Some("phone"), "Phone");

        form.append(&method_stack);

        let separator = gtk::Separator::new(gtk::Orientation::Horizontal);
        separator.add_css_class("login-separator");
        form.append(&separator);

        let apple_button = gtk::Button::builder()
            .label("Sign in with Apple")
            .css_classes(vec!["suggested-action".to_string()])
            .build();
        form.append(&apple_button);

        let status_label = gtk::Label::builder()
            .label("")
            .wrap(true)
            .halign(gtk::Align::Center)
            .css_classes(vec![
                "dim-label".to_string(),
                "page-status".to_string(),
                "login-status".to_string(),
            ])
            .visible(false)
            .build();
        form.append(&status_label);

        content.append(&form);
        root.append(&content);

        Self {
            widget: root,
            email_entry,
            password_entry,
            login_button,
            register_button,
            phone_entry,
            phone_code_entry,
            send_code_button,
            phone_login_button,
            apple_button,
            status_label,
        }
    }

    /// Connect to login clicked
    pub fn connect_login<F: Fn(String, String) + 'static>(&self, callback: F) {
        let email = self.email_entry.clone();
        let password = self.password_entry.clone();

        self.login_button.connect_clicked(move |_| {
            let email_text = email.text().to_string();
            let password_text = password.text().to_string();
            callback(email_text, password_text);
        });
    }

    /// Connect to register clicked
    pub fn connect_register<F: Fn(String, String) + 'static>(&self, callback: F) {
        let email = self.email_entry.clone();
        let password = self.password_entry.clone();

        self.register_button.connect_clicked(move |_| {
            let email_text = email.text().to_string();
            let password_text = password.text().to_string();
            callback(email_text, password_text);
        });
    }

    /// Connect to send phone code
    pub fn connect_send_phone_code<F: Fn(String) + 'static>(&self, callback: F) {
        let phone = self.phone_entry.clone();
        self.send_code_button.connect_clicked(move |_| {
            callback(phone.text().to_string());
        });
    }

    /// Connect to phone login clicked
    pub fn connect_phone_login<F: Fn(String, String) + 'static>(&self, callback: F) {
        let phone = self.phone_entry.clone();
        let code = self.phone_code_entry.clone();
        self.phone_login_button.connect_clicked(move |_| {
            callback(phone.text().to_string(), code.text().to_string());
        });
    }

    /// Connect to Apple login clicked
    pub fn connect_apple_login<F: Fn() + 'static>(&self, callback: F) {
        self.apple_button.connect_clicked(move |_| {
            callback();
        });
    }

    /// Set loading state
    pub fn set_loading(&self, loading: bool) {
        self.login_button.set_sensitive(!loading);
        self.register_button.set_sensitive(!loading);
        self.email_entry.set_sensitive(!loading);
        self.password_entry.set_sensitive(!loading);
        self.phone_entry.set_sensitive(!loading);
        self.phone_code_entry.set_sensitive(!loading);
        self.send_code_button.set_sensitive(!loading);
        self.phone_login_button.set_sensitive(!loading);
        self.apple_button.set_sensitive(!loading);

        if loading {
            self.login_button.set_label("Signing in...");
        } else {
            self.login_button.set_label("Sign in with Email");
        }
    }

    /// Show error message
    pub fn show_error(&self, message: &str) {
        self.status_label.set_label(message);
        self.status_label.set_visible(true);
    }

    /// Clear status message
    pub fn clear_status(&self) {
        self.status_label.set_label("");
        self.status_label.set_visible(false);
    }
}

impl Default for LoginPage {
    fn default() -> Self {
        Self::new()
    }
}
