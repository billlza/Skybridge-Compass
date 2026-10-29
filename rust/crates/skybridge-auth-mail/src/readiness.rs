use serde::Serialize;

use crate::config::{MailMode, MailServiceConfig};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MailReadiness {
    pub required: bool,
    pub mode: MailMode,
    pub smtp_configured: bool,
    pub ready: bool,
    pub reasons: Vec<String>,
    pub missing_configuration: Vec<String>,
}

impl MailReadiness {
    pub fn from_config(config: &MailServiceConfig) -> Self {
        let mut missing = Vec::new();

        if matches!(config.mode, MailMode::DirectMailSmtp) {
            let smtp = config.smtp.as_ref();
            if smtp.is_none() || smtp.is_some_and(|smtp| smtp.host.is_empty()) {
                missing.push("smtp.host".to_string());
            }
            if smtp.is_none() || smtp.is_some_and(|smtp| smtp.username.is_empty()) {
                missing.push("smtp.username".to_string());
            }
            if smtp.is_none() || smtp.is_some_and(|smtp| smtp.password.is_empty()) {
                missing.push("smtp.password".to_string());
            }
            if config.identity.sender_email.is_empty() {
                missing.push("identity.sender_email".to_string());
            }
            if config.identity.bounce_email.is_empty() {
                missing.push("identity.bounce_email".to_string());
            }
            if config.identity.domain.is_empty() {
                missing.push("identity.domain".to_string());
            }
            if config.identity.dkim_selector.is_empty() {
                missing.push("identity.dkim_selector".to_string());
            }
            if !config.identity.domain.is_empty() {
                if !email_matches_domain(&config.identity.sender_email, &config.identity.domain) {
                    missing.push("identity.sender_email_domain_match".to_string());
                }
                if !email_matches_domain(&config.identity.bounce_email, &config.identity.domain) {
                    missing.push("identity.bounce_email_domain_match".to_string());
                }
            }
        }

        let smtp_configured = missing.is_empty();
        let mut reasons = Vec::new();

        match config.mode {
            MailMode::Disabled => {
                if config.require_smtp_ready {
                    reasons.push("mail_mode_disabled".to_string());
                }
            }
            MailMode::DirectMailSmtp => {
                if !smtp_configured {
                    reasons.push("smtp_not_configured".to_string());
                }
            }
        }

        let ready = match config.mode {
            MailMode::Disabled => !config.require_smtp_ready,
            MailMode::DirectMailSmtp => smtp_configured,
        };

        Self {
            required: config.require_smtp_ready,
            mode: config.mode,
            smtp_configured,
            ready,
            reasons,
            missing_configuration: missing,
        }
    }
}

fn email_matches_domain(email: &str, domain: &str) -> bool {
    let email = email.trim();
    let domain = domain.trim();
    if email.is_empty() || domain.is_empty() {
        return false;
    }
    email
        .rsplit_once('@')
        .map(|(_, email_domain)| email_domain.eq_ignore_ascii_case(domain))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use crate::config::{MailIdentityConfig, MailMode, MailServiceConfig, SmtpConfig};

    use super::MailReadiness;

    #[test]
    fn directmail_smtp_requires_identity_and_smtp_settings() {
        let readiness = MailReadiness::from_config(&MailServiceConfig {
            mode: MailMode::DirectMailSmtp,
            require_smtp_ready: true,
            listen_addr: "127.0.0.1:8585".to_string(),
            smtp: Some(SmtpConfig {
                host: String::new(),
                port: 587,
                username: String::new(),
                password: String::new(),
            }),
            identity: MailIdentityConfig {
                sender_email: String::new(),
                bounce_email: String::new(),
                domain: String::new(),
                dkim_selector: String::new(),
            },
        });

        assert!(!readiness.ready);
        assert_eq!(readiness.reasons, vec!["smtp_not_configured"]);
        assert!(
            readiness
                .missing_configuration
                .contains(&"smtp.host".to_string())
        );
        assert!(
            readiness
                .missing_configuration
                .contains(&"identity.sender_email".to_string())
        );
    }

    #[test]
    fn directmail_smtp_ready_when_all_required_fields_exist() {
        let readiness = MailReadiness::from_config(&MailServiceConfig {
            mode: MailMode::DirectMailSmtp,
            require_smtp_ready: true,
            listen_addr: "127.0.0.1:8585".to_string(),
            smtp: Some(SmtpConfig {
                host: "mail.nebula-technologies.net".to_string(),
                port: 587,
                username: "submission".to_string(),
                password: "secret".to_string(),
            }),
            identity: MailIdentityConfig {
                sender_email: "no-reply@nebula-technologies.net".to_string(),
                bounce_email: "bounces@nebula-technologies.net".to_string(),
                domain: "nebula-technologies.net".to_string(),
                dkim_selector: "sb1".to_string(),
            },
        });

        assert!(readiness.ready);
        assert!(readiness.missing_configuration.is_empty());
    }
}
