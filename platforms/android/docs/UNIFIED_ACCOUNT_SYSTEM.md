# SkyBridge 统一用户系统（架构提案）

## 目标
- 提供跨平台统一账号（手机、邮箱、Nebula OIDC），在 Android/iOS/Web/桌面端一致。
- 支持多账号、主账号（Primary Account）与快速切换。
- 安全存储凭据，完善的会话管理与状态稳定性（避免闪断）。
- 面向企业的设备信任、受管账号与策略下发能力（MDM/策略中心）。

## macOS 用户系统要点（参考）
- 本地用户与组由 `opendirectoryd` 管理，GUI 入口为登录窗口（loginwindow）。
- 凭据与密钥由 Keychain/`securityd` 管理；应用权限由 TCC 控制。
- Apple ID 作为“主账号”，统一 iCloud 同步与设备信任；企业有受管 Apple ID 与 MDM 策略。
- 关键特性：
  - 账户层（Directory/Identity）、凭据层（Keychain）、会话层（登录窗口）、策略层（MDM/TCC）。

## SkyBridge 统一架构
1. 身份层（Identity Layer）
   - 统一抽象接口：Email/Password、Phone OTP、Nebula OIDC。
   - 后端采用 Supabase Auth（可扩展至企业 IdP）。

2. 凭据层（Credential Store）
   - Android：EncryptedSharedPreferences → 长期 Key/Refresh Token。
   - iOS：Keychain；Web：Secure Storage；桌面：OS Keychain（macOS Keychain / Windows DPAPI）。

3. 账号层（Account Manager）
   - 主账号（Primary Account）与多账号列表；设备信任与登录历史。
   - 数据结构示例：`AccountProfile(id, displayName, email, phone, avatarUrl)`。

4. 会话层（Session Manager）
   - 稳定状态流：去抖动与容错（避免刷新期间 UI 闪断）。
   - Token 刷新与网络切换策略；后台刷新与失败回退。

5. 策略层（Policy/MDM 可选）
   - 企业场景下的受管设备、策略下发与合规审计接口。

## 分阶段里程碑
M1：会话稳定性修复（已完成）
- 对 `sessionStatus` 引入 `debounce + distinctUntilChanged`，避免 3–5 秒闪断。
- 登出操作立即更新 UI，绕过去抖动延迟。

M2：账号骨架与持久化
- `AccountStore`（shared 模块）维护主账号；后续接入安全存储。
- 登录成功后写入主账号；设置页新增“切换/移除账号”。

M3：多账号与设备信任
- 支持添加/移除多个账号，标注主账号。
- 设备信任列表与登录历史（后端接口与本地缓存）。

M4：统一入口与跨端 SSO
- 统一“账户中心”界面：头像、昵称、账号、设备、会话。
- 深链与共享凭据以支持 Android/iOS/Web 之间快速登录。

M5：企业策略（可选）
- 受管账号（Managed Account）、设备合规与策略下发。

## 安全设计建议
- 所有长期凭据必须进入平台安全存储；应用内只保留短期会话。
- 会话状态必须具备去抖与容错；刷新失败回退策略明确。
- 明确数据分类与隐私边界；对外接口最小可用权限原则。

## 下一步
- 接入安全存储实现（Android 端 EncryptedSharedPreferences）。
- 在登录成功流程中写入 `AccountStore.setPrimaryAccount(...)`。
- 构建“账户中心”页面与“切换账号”功能。