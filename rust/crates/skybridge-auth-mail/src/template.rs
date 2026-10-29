use serde::{Deserialize, Serialize};
use time::{OffsetDateTime, format_description::FormatItem, macros::format_description};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RegistrationSuccessEmailContent {
    pub recipient_email: String,
    pub username: String,
    pub nebula_id: String,
    pub registration_time: OffsetDateTime,
    pub app_name: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RenderedEmail {
    pub subject: String,
    pub html: String,
}

pub fn render_registration_success_email(
    content: &RegistrationSuccessEmailContent,
) -> RenderedEmail {
    let app_name = if content.app_name.trim().is_empty() {
        "SkyBridge Compass Pro"
    } else {
        content.app_name.trim()
    };

    let registration_time = content
        .registration_time
        .format(shanghai_timestamp_format())
        .unwrap_or_else(|_| "未知时间".to_string());

    let subject = format!("欢迎加入 {app_name}");
    let html = format!(
        r#"<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background-color: #f5f5f5; padding: 20px; }}
        .container {{ max-width: 600px; margin: 0 auto; background: white; border-radius: 12px; padding: 40px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }}
        .header {{ text-align: center; margin-bottom: 30px; }}
        .logo {{ font-size: 24px; font-weight: bold; color: #007AFF; }}
        .content {{ color: #333; line-height: 1.6; }}
        .highlight {{ background: linear-gradient(135deg, #007AFF, #5856D6); color: white; padding: 20px; border-radius: 8px; margin: 20px 0; }}
        .footer {{ text-align: center; margin-top: 30px; color: #999; font-size: 12px; }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="logo">{app_name}</div>
        </div>

        <div class="content">
            <h2>欢迎加入 SkyBridge！</h2>

            <p>亲爱的 <strong>{username}</strong>，</p>

            <p>恭喜您成功注册 {app_name} 账户！现在您可以开始使用我们的跨平台设备连接和远程控制功能了。</p>

            <div class="highlight">
                <h3 style="margin-top: 0;">账户信息</h3>
                <p><strong>Nebula ID:</strong> {nebula_id}</p>
                <p><strong>注册时间:</strong> {registration_time}</p>
            </div>

            <h3>开始使用</h3>
            <ul>
                <li>下载并安装 SkyBridge 客户端</li>
                <li>使用您的账户登录</li>
                <li>添加您的设备并开始连接</li>
            </ul>

            <h3>安全提示</h3>
            <ul>
                <li>请妥善保管您的账户密码</li>
                <li>建议开启双重认证（MFA）</li>
                <li>如非本人操作，请立即修改密码</li>
            </ul>
        </div>

        <div class="footer">
            <p>此邮件由 SkyBridge 系统自动发送，请勿直接回复</p>
            <p>© 2026 SkyBridge. All rights reserved.</p>
        </div>
    </div>
</body>
</html>"#,
        username = escape_html(content.username.trim()),
        nebula_id = escape_html(content.nebula_id.trim()),
        registration_time = escape_html(&registration_time),
    );

    RenderedEmail { subject, html }
}

fn escape_html(input: &str) -> String {
    input
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn shanghai_timestamp_format() -> &'static [FormatItem<'static>] {
    format_description!("[year]年[month]月[day]日 [hour]:[minute]:[second]")
}

#[cfg(test)]
mod tests {
    use time::{Date, Month, PrimitiveDateTime, Time, UtcOffset};

    use super::{RegistrationSuccessEmailContent, render_registration_success_email};

    #[test]
    fn registration_template_renders_key_fields() {
        let registration_time = PrimitiveDateTime::new(
            Date::from_calendar_date(2026, Month::April, 13).unwrap(),
            Time::from_hms(10, 30, 0).unwrap(),
        )
        .assume_offset(UtcOffset::from_hms(8, 0, 0).unwrap());

        let rendered = render_registration_success_email(&RegistrationSuccessEmailContent {
            recipient_email: "user@example.com".to_string(),
            username: "Bill".to_string(),
            nebula_id: "NB-001".to_string(),
            registration_time,
            app_name: "SkyBridge Compass Pro".to_string(),
        });

        assert!(rendered.subject.contains("SkyBridge Compass Pro"));
        assert!(rendered.html.contains("Bill"));
        assert!(rendered.html.contains("NB-001"));
        assert!(rendered.html.contains("2026年04月13日 10:30:00"));
    }
}
