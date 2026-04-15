# 认证邮件与短信 1.0 生产化 Runbook

本 runbook 固定 1.0 认证链路，避免继续并行半成品。

- 短信主链：`Supabase Phone OTP -> send_sms hook -> skybridge-signaling -> Aliyun`
- 认证邮件主链：`Supabase Auth -> Custom SMTP -> Aliyun DirectMail`
- Apple 登录主链：`Sign in with Apple -> Supabase Auth Apple provider`
- 非认证类邮件：不纳入 1.0 上线范围

官方参考：
- Supabase 自定义 SMTP: <https://supabase.com/docs/guides/auth/auth-smtp>
- Supabase `send_sms` hook: <https://supabase.com/docs/guides/auth/auth-hooks/send-sms-hook>
- 阿里云 DirectMail 产品页: <https://www.alibabacloud.com/en/product/directmail>
- 阿里云 DirectMail 定价: <https://www.alibabacloud.com/en/product/product/directmail/pricing>
- 阿里云 DirectMail SMTP 指南: <https://www.alibabacloud.com/help/en/direct-mail/user-guide/smtp-send>
- Supabase Apple Auth: <https://supabase.com/docs/guides/auth/social-login/auth-apple>

## 1. 目标状态

### 短信

- 客户端只调用 Supabase Phone OTP，不持有生产短信密钥。
- `skybridge-signaling` 负责接收 Supabase hook、验签、调用阿里云 provider。
- 生产环境必须开启 `REQUIRE_SMS_AUTH_READY=true`。
- `/health` 和 `/readyz` 必须暴露：
  - `smsProvider`
  - `smsHookConfigured`
  - `smsProviderConfigured`
  - `smsReady`
  - `smsReadinessReasons`
  - `sms.counters`

### 邮件

- Supabase Auth 继续负责注册验证、密码重置、邮箱变更语义。
- Supabase 默认认证邮件在生产环境关闭，改为自定义 SMTP。
- 1.0 默认不再为邮件额外购买新 ECS，直接使用阿里云 DirectMail 的托管 SMTP。
- 仓库中的 Rust `skybridge-auth-mail` 服务只作为未来自有邮件边界与运行时就绪校验落点，
  1.0 不替代 Supabase Auth + SMTP 这条认证主链。
- 认证 SMTP 身份固定为：
  - `mail.<主域名>`
  - `no-reply@<主域名>`
  - `bounces@<主域名>`
  - DKIM selector: `sb1`

### Apple 登录

- Apple 登录对外语义固定为：
  - macOS 原生 `Sign in with Apple`
  - iOS 原生 `Sign in with Apple`
  - 服务端统一由 Supabase Auth Apple provider 完成 token exchange 与会话签发
- Apple 登录的主 `client_id` 采用 `Services ID`
- 原生 App Bundle ID 通过同一组 client IDs 共同接入
- 首次登录返回的 `fullName` / `email` 需要立即回写 user metadata；否则后续很可能拿不回
- Apple 登录不应成为风控旁路：
  - 上线前必须确认客户端 Apple 登录同样接入注册/登录审计
  - `before_user_created` hook 必须保持开启
- Apple client secret 属于定期轮换资产，不是“一次配置永久有效”

## 2. 短信上线前检查

### Provider 选择规则

1. 先审计现有阿里云账号是否已开通 `PNVS`。
2. 如果 `PNVS` 可用且签名/模板有效，使用 `ALIYUN_SMS_PROVIDER=pnvs`。
3. 如果 `PNVS` 不可用，则切到 `ALIYUN_SMS_PROVIDER=dysms`。
4. 两者都不可用时，手机验证码不允许作为 1.0 可上线能力。

### signaling 必填配置

- `REQUIRE_SMS_AUTH_READY=true`
- `SUPABASE_SEND_SMS_HOOK_SECRET`
- `ALIYUN_SMS_PROVIDER`
- `ALIBABA_CLOUD_ACCESS_KEY_ID`
- `ALIBABA_CLOUD_ACCESS_KEY_SECRET`

`pnvs` 额外需要：
- `ALIYUN_PNVS_REGION_ID`
- `ALIYUN_PNVS_ENDPOINT`
- `ALIYUN_PNVS_SIGN_NAME`
- `ALIYUN_PNVS_TEMPLATE_CODE`
- `SUPABASE_SMS_OTP_EXP_SECONDS`
  - 必须与 Supabase Auth `sms_otp_exp` 保持一致，当前项目 staging 现值为 `60`
  - 对 PNVS 标准模板 `100001`，signaling 会据此推导模板变量 `min`
- 可选：`ALIYUN_SMS_TEMPLATE_PARAMS_JSON`
  - 用于补充自定义模板变量，格式必须是 JSON object

`dysms` 额外需要：
- `ALIYUN_SMS_SIGN_NAME`
- `ALIYUN_SMS_TEMPLATE_CODE`
- `ALIYUN_SMS_ENDPOINT`

### staging 验收

- `/readyz` 返回 `200`，且 `smsReady=true`
- `smsReadinessReasons=[]`
- 有效签名 hook 可成功发码
- 无效签名返回 `401`
- provider 缺配置时 `/readyz` 返回 `503`
- 阿里云超时、模板拒绝、非法手机号在 `/health.sms.counters` 中有明确分类
- macOS / iOS 手机 OTP 发码与登录全链路通过

建议先用仓库内探测脚本做一次真实手机号验证：

```bash
SUPABASE_SEND_SMS_HOOK_SECRET='<staging hook secret>' \
bash Server/skybridge-signaling/deploy/scripts/probe_supabase_send_sms_hook.sh \
  https://<staging-host> \
  <mainland-test-phone>
```

说明：

- 手机号只作为运行时参数传入，不要写进仓库。
- 探测脚本会先检查 `/readyz` 是否返回 `smsProvider=pnvs` 与 `smsReady=true`。
- 请求成功后，还需要在 PNVS 控制台“发送记录”中确认出现对应发送记录。

如果需要通过 Management API 配置 Supabase Phone + `send_sms` hook，可使用：

```bash
bash Scripts/configure_supabase_phone_sms_hook.sh \
  --project-ref hloqytmhjludmuhwyyzb \
  --hook-url https://api.nebula-technologies.net/api/hooks/supabase/send-sms \
  --hook-secret '<shared secret>' \
  --enable-hook \
  --enable-phone
```

说明：

- 脚本默认从本机 Keychain 的 `Supabase CLI` 登录项读取管理 token。
- 先保证 signaling 服务端 `production.env` 中已经写入同一个 `SUPABASE_SEND_SMS_HOOK_SECRET`。
- 不要在服务器未就绪时提前启用 `Phone` provider，否则真实发码会直接失败。

## 3. DirectMail + Supabase SMTP 上线前检查

### DirectMail 基础架构

- 开通阿里云 DirectMail
- 创建发信域名与发信地址
- 创建 SMTP 用户与 SMTP 密码
- 根据阿里云控制台完成域名验证

成本说明：

- DirectMail 官方页面当前标注支持 `Pay-As-You-Go`
- 当前公开页还提供小额免费额度与按量阶梯价，明显低于再维护一台独立 ECS 的固定成本

1.0 取舍：

- 不再为了认证邮件单独购买新服务器
- 不自建额外邮件服务器
- 优先完成“可投递、可验证、可运维”的托管 SMTP 主链

### DNS / Deliverability 前置门槛

上线前必须全部完成：

- `A` / `AAAA`
- `MX`
- `SPF`
- `DKIM`
- `DMARC`
- 反向解析 `PTR`
- `mail.<主域名>` TLS 证书
- HELO/EHLO 与 PTR 一致

DirectMail 注意事项：

- 如果使用 Supabase Custom SMTP，真正发起 SMTP 连接的是 Supabase，而不是你的本地客户端
- 因此 DirectMail 控制台里的 SMTP `IP Protection` 在 1.0 阶段不要贸然开启
- 如果后续必须做固定源 IP 限制，再考虑让 Rust `skybridge-auth-mail` 作为自有发送边界接入 DirectMail

### Supabase Dashboard 配置

在 Supabase Auth 的 SMTP 设置中填写：

- Host: DirectMail 控制台给出的 SMTP Host
- Port: DirectMail 控制台给出的 SMTP Port
  - 常见做法是 SSL `465`
  - 或按官方文档使用 `80`
- Username: DirectMail SMTP 用户
- Password: DirectMail SMTP 密码
- Sender name: `SkyBridge Compass Pro`
- Sender email: `no-reply@<主域名>`

仓库已提供 Supabase 管理 API 脚本：

```bash
bash Scripts/configure_supabase_auth_smtp.sh \
  --project-ref hloqytmhjludmuhwyyzb \
  --smtp-host <smtp-host> \
  --smtp-port 465 \
  --smtp-user <smtp-user> \
  --smtp-pass '<smtp-pass>' \
  --sender-email no-reply@nebula-technologies.net \
  --sender-name 'SkyBridge Compass Pro' \
  --enable-email
```

切换顺序：

1. 先在 staging 完成自定义 SMTP 验证
2. 再关闭生产 Supabase 默认认证邮件
3. 切到 DirectMail SMTP
4. 观察队列、退信、投诉和主要收件箱投递情况

如果 DirectMail 发送行为或收件箱表现明显异常，暂停生产切换，不允许回到“默认邮件临时顶着”的灰色状态上线。

## 4. 邮件验收矩阵

1. 注册验证邮件
2. 密码重置邮件
3. 邮箱变更确认邮件

至少验证这些目标邮箱：

- QQ 邮箱
- 163 / 126
- Outlook
- Gmail

每项都需要确认：

- 邮件可送达
- SPF 通过
- DKIM 通过
- DMARC 对齐通过
- TLS 正常
- 链接回跳到正确环境

## 5. 当前代码边界

1.0 已明确停用的链路：

- 客户端直连短信 AK/SK
- `EmailService` 注册成功通知邮件占位调用
- `VerificationCodeService` 客户端邮件验证码旧通道

1.0 仍保留的主链：

- Supabase Phone OTP
- Supabase Auth 认证邮件语义
- Supabase Auth Apple provider
- signaling `send_sms` hook + Aliyun
- Supabase 自定义 SMTP + Aliyun DirectMail

未来 Rust 边界：

- `rust/crates/skybridge-auth-mail`
- 适合承接：
  - 运行时 SMTP/域名身份就绪校验
  - 非认证类产品通知邮件模板渲染
  - 未来需要自有审计/队列/重试策略的邮件投递逻辑
  - 当 DirectMail 需要固定源 IP、额外审计或发送策略时，作为自有邮件边界服务
- 当前不接管：
  - Supabase Auth 注册验证邮件
  - Supabase Auth 密码重置邮件
  - Supabase Auth 邮箱变更确认邮件

## 6. Apple 登录配置与轮换

### 当前固定值

- Services ID: `com.skybridge.compass.auth`
- macOS App ID: `com.skybridge.compass.pro`
- iOS App ID: `com.skybridge.compass.ios`
- Team ID: `YKUPL7Z869`
- 当前 Key ID: `FSFS2WP466`

说明：

- Supabase Management API 当前会把多 client IDs 收敛到同一个 `external_apple_client_id` 字段，
  表现为逗号分隔字符串；不要误以为 `external_apple_additional_client_ids` 一定会单独持久化。
- 这不是脚本异常，而是当前 API 的真实行为。

### 配置 / 轮换命令

```bash
bash Scripts/configure_supabase_auth_apple.sh \
  --project-ref hloqytmhjludmuhwyyzb \
  --team-id YKUPL7Z869 \
  --key-id <new-key-id> \
  --client-id com.skybridge.compass.auth \
  --additional-client-ids 'com.skybridge.compass.pro,com.skybridge.compass.ios' \
  --private-key-file /absolute/path/to/AuthKey-<new-key-id>.p8 \
  --secret-ttl-days 170 \
  --enable-apple
```

推荐：

- 不要把 TTL 拉满 180 天，保留几天轮换缓冲
- 每次轮换后都重新做一次 macOS / iOS 真机登录验收
- 新 key 生效后，再删除 Apple Developer 后台中的旧 key
- 脚本会把非敏感轮换元数据写到 `Docs/ops/.state/supabase_apple_secret_rotation.json`
  这个文件已加入 `.gitignore`，用于本机巡检，不应提交到仓库

### 日常巡检

仓库内置认证 readiness 体检脚本：

```bash
bash Scripts/check_supabase_auth_readiness.sh \
  --project-ref hloqytmhjludmuhwyyzb \
  --expect-apple-client-ids 'com.skybridge.compass.auth,com.skybridge.compass.pro,com.skybridge.compass.ios'
```

这个脚本会检查：

- `before_user_created` hook
- `send_sms` hook
- SMTP 配置
- Apple provider 开关
- Apple client secret 是否存在、是否接近过期
- macOS / iOS feature flag 与 entitlements 是否已写入仓库
- iOS Xcode 工程是否真的绑定 entitlements

如果准备把 Turnstile 也作为上线硬门槛，可以加：

```bash
bash Scripts/check_supabase_auth_readiness.sh \
  --project-ref hloqytmhjludmuhwyyzb \
  --expect-apple-client-ids 'com.skybridge.compass.auth,com.skybridge.compass.pro,com.skybridge.compass.ios' \
  --require-captcha
```

## 7. 切换完成标准

只有满足以下条件才能视为 1.0 认证能力 ready：

1. staging 上短信与认证邮件都已全链路跑通
2. production `/readyz` 通过且 `smsReady=true`
3. 客户端不存在写入生产短信密钥的入口
4. Supabase 默认认证邮件已关闭
5. DirectMail 域名验证 / DNS / TLS / deliverability 验收全部完成
6. Supabase Apple provider 已开启，且 macOS / iOS 真机原生 Apple 登录通过
7. `before_user_created` hook 已开启，Apple / 邮箱 / 手机登录都不会绕过审计
8. Apple client secret 已记录轮换日期，并确认剩余有效期充足
