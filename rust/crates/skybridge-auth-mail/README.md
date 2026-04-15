# skybridge-auth-mail

Rust 边界服务，用于承接 SkyBridge 后续自有邮件能力。

当前职责：

- 提供邮件运行时配置与就绪校验
- 提供通知邮件模板渲染 API
- 为未来的 DirectMail / SMTP / 审计 / 队列能力预留清晰服务边界

当前不接管：

- Supabase Auth 注册验证邮件
- Supabase Auth 密码重置邮件
- Supabase Auth 邮箱变更确认邮件

1.0 认证邮件主链仍固定为：

`Supabase Auth -> Custom SMTP -> Aliyun DirectMail`
