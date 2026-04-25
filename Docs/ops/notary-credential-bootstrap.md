# 本地 Notary 凭据自动化

## 目标

把本地 macOS 发版所需的 Apple notarization 认证参数自动化固化下来，避免每次重新人工查找：

- `NOTARYTOOL_KEY`
- `NOTARYTOOL_KEY_ID`
- `NOTARYTOOL_ISSUER`
- `NOTARYTOOL_KEYCHAIN_PROFILE`

本文档对应的自动化脚本是：

[`Scripts/bootstrap_notarytool_credentials.sh`](</Users/bill/Desktop/SkyBridge Compass Pro release/Scripts/bootstrap_notarytool_credentials.sh>)

发布前的本机自愈入口是：

[`Scripts/ensure_notarytool_credentials.sh`](</Users/bill/Desktop/SkyBridge Compass Pro release/Scripts/ensure_notarytool_credentials.sh>)

## 官方依据

- Apple 官方说明 `notarytool` 支持两类认证：
  - App Store Connect API key
  - Apple ID + app-specific password
- Apple 官方推荐把凭据保存到 Keychain profile 复用。

参考：

- [TN3147: Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## 本仓库的标准做法

### 一次性 bootstrap

在这台机器上第一次配置或 API key 轮换后，执行：

```bash
./Scripts/bootstrap_notarytool_credentials.sh
```

脚本会自动完成：

1. 从 `~/.appstoreconnect/private_keys/AuthKey_*.p8` 找到本地 API key
2. 从文件名推断 `NOTARYTOOL_KEY_ID`
3. 使用本机已有的 App Store Connect 会话，通过 `iris/v1/apiKeys/<KEY_ID>/provider` 自动解析 provider UUID
4. 将该 UUID 作为 `NOTARYTOOL_ISSUER`
5. 用 `xcrun notarytool history` 做一次真实认证校验
6. 将凭据保存为本机 Keychain profile，默认名为 `skybridge-notary`
7. 生成本地 env 文件：`~/.config/skybridge/notarytool.env`

## 以后每次发版

### 标准路径

bootstrap 完成后，后续每次只需要跑正式发版链：

```bash
bundle exec fastlane release
```

`fastlane release` 会先执行 `Scripts/ensure_notarytool_credentials.sh`：

1. 先检测当前 notary 凭据是否已经可用
2. 若不可用，则自动调用 `bootstrap_notarytool_credentials.sh`
3. bootstrap 后再做一次 `notarytool history` 级别的真实认证校验
4. 只有验证通过，才进入正式构建 / 签名 / 公证链

或者直接脚本：

```bash
./Scripts/build_dmg.sh --identity "Developer ID Application: ..."
./Scripts/check_macos_release_readiness.sh --require-notarization
```

现有脚本会自动加载：

`~/.config/skybridge/notarytool.env`

因此不再需要每次手动 export notary 参数。

## 可选参数

### 显式指定 Apple ID

```bash
./Scripts/bootstrap_notarytool_credentials.sh --apple-id you@example.com
```

### 显式指定 key 或 key id

```bash
./Scripts/bootstrap_notarytool_credentials.sh \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
```

```bash
./Scripts/bootstrap_notarytool_credentials.sh --key-id <KEY_ID>
```

### 显式指定 profile 名

```bash
./Scripts/bootstrap_notarytool_credentials.sh --profile-name skybridge-notary
```

### 只解析，不写 Keychain profile

```bash
./Scripts/bootstrap_notarytool_credentials.sh --skip-store
```

## 本机验证范围

不要把真实 Apple ID、API key ID、provider UUID 或其它账号标识写入仓库文档。需要记录机器上的已验证事实时，保存在本机私有笔记或 `~/.config/skybridge/notarytool.env` 旁边的本地说明中。

每台发版机器都应该验证：

- API key 文件存在：`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`
- `bootstrap_notarytool_credentials.sh` 能从本机 App Store Connect 会话解析 provider UUID
- 解析出的 issuer 可被 `notarytool` 接受并成功查询 submission history

换句话说，本地 notary 认证的可靠来源不是手工抄值，而是：

1. 本地 `.p8`
2. 本机可用的 App Store Connect 会话
3. `iris/v1/apiKeys/<KEY_ID>/provider`

## 故障排查

### 1. `401 Unauthenticated` / `Invalid credentials`

优先执行：

```bash
./Scripts/bootstrap_notarytool_credentials.sh
```

如果 bootstrap 也失败，说明当前本机 Apple 会话失效。先刷新本机会话，再重跑：

- 在 Xcode 里确认开发者账号仍已登录
- 或重新访问 App Store Connect
- 或使用 fastlane 刷新登录态

### 2. 找不到 `.p8`

把 API key 放回：

```text
~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
```

再重新执行 bootstrap。

### 3. API key 轮换

只要 `.p8` 或 key id 变了，就重新执行一次 bootstrap：

```bash
./Scripts/bootstrap_notarytool_credentials.sh
```

### 4. 不想依赖 env 文件

脚本已经同时把凭据写入 Keychain profile。只要 profile 仍有效，也可以直接使用：

```bash
xcrun notarytool history --keychain-profile skybridge-notary
```

## 建议

以后不要再手工记忆或手工粘贴 `NOTARYTOOL_ISSUER`。

统一流程：

1. API key 初次配置或轮换后运行 `bootstrap_notarytool_credentials.sh`
2. 平时发版直接走 `fastlane release`
3. 公证失败时，先重跑 bootstrap，再查发版链本身
