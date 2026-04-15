use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MailMode {
    Disabled,
    DirectMailSmtp,
}

impl MailMode {
    fn from_env(raw: Option<String>) -> Self {
        match raw
            .unwrap_or_else(|| "disabled".to_string())
            .trim()
            .to_ascii_lowercase()
            .as_str()
        {
            "directmail" | "direct_mail" | "directmail_smtp" | "smtp" => Self::DirectMailSmtp,
            "postal" | "postal_smtp" => Self::DirectMailSmtp,
            _ => Self::Disabled,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SmtpConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    #[serde(skip_serializing)]
    pub password: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MailIdentityConfig {
    pub sender_email: String,
    pub bounce_email: String,
    pub domain: String,
    pub dkim_selector: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MailServiceConfig {
    pub mode: MailMode,
    pub require_smtp_ready: bool,
    pub listen_addr: String,
    pub smtp: Option<SmtpConfig>,
    pub identity: MailIdentityConfig,
}

impl MailServiceConfig {
    pub fn from_env() -> Self {
        let mode = MailMode::from_env(std::env::var("SKYBRIDGE_MAIL_MODE").ok());
        let smtp_host = env_string("SKYBRIDGE_MAIL_SMTP_HOST");
        let smtp_port = env_u16("SKYBRIDGE_MAIL_SMTP_PORT").unwrap_or(587);
        let smtp_username = env_string("SKYBRIDGE_MAIL_SMTP_USERNAME");
        let smtp_password = env_string("SKYBRIDGE_MAIL_SMTP_PASSWORD");

        let smtp = if smtp_host.is_empty()
            && smtp_username.is_empty()
            && smtp_password.is_empty()
            && mode == MailMode::Disabled
        {
            None
        } else {
            Some(SmtpConfig {
                host: smtp_host,
                port: smtp_port,
                username: smtp_username,
                password: smtp_password,
            })
        };

        Self {
            mode,
            require_smtp_ready: env_bool("SKYBRIDGE_MAIL_REQUIRE_SMTP_READY").unwrap_or(false),
            listen_addr: std::env::var("SKYBRIDGE_MAIL_LISTEN_ADDR")
                .unwrap_or_else(|_| "127.0.0.1:8585".to_string()),
            smtp,
            identity: MailIdentityConfig {
                sender_email: env_string("SKYBRIDGE_MAIL_SENDER_EMAIL"),
                bounce_email: env_string("SKYBRIDGE_MAIL_BOUNCE_EMAIL"),
                domain: env_string("SKYBRIDGE_MAIL_DOMAIN"),
                dkim_selector: env_string("SKYBRIDGE_MAIL_DKIM_SELECTOR"),
            },
        }
    }
}

fn env_string(key: &str) -> String {
    std::env::var(key).unwrap_or_default().trim().to_string()
}

fn env_u16(key: &str) -> Option<u16> {
    std::env::var(key)
        .ok()
        .and_then(|raw| raw.trim().parse::<u16>().ok())
}

fn env_bool(key: &str) -> Option<bool> {
    std::env::var(key)
        .ok()
        .and_then(|raw| match raw.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" => Some(true),
            "0" | "false" | "no" => Some(false),
            _ => None,
        })
}
