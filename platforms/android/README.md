# SkyBridge Compass - Android应用

SkyBridge Compass是一个跨平台设备连接和控制应用的Android客户端，提供设备发现、屏幕镜像、远程控制和文件传输功能。

## 功能特性

### 🔍 设备发现
- 自动扫描局域网内的可连接设备
- 支持多种设备类型（iOS、Android、Windows、macOS）
- 实时设备状态监控
- 智能设备分类和过滤

### 📱 屏幕镜像
- 高质量屏幕投射
- 可调节镜像质量和帧率
- 支持横屏和竖屏模式
- 低延迟传输优化

### 🎮 远程控制
- 触摸手势映射
- 键盘输入支持
- 鼠标操作模拟
- 多点触控支持

### 📁 文件传输
- 拖拽式文件传输
- 批量文件操作
- 传输进度监控
- 断点续传支持

### 🎨 现代化UI
- Material Design 3设计语言
- 响应式布局适配
- 深色模式支持
- 流畅的动画效果

## 技术架构

当前实现是 Kotlin-first 的多模块 Compose 应用。协议、安全和平台基线以 [`docs/ADR-2026-07-01-ANDROID-P2P-QPERIAPT-STACK.md`](docs/ADR-2026-07-01-ANDROID-P2P-QPERIAPT-STACK.md) 为准；跨平台协议所有权及同平台快路径以 [`docs/ADR-2026-07-23-PEER-FAMILY-PROTOCOL-LANES.md`](docs/ADR-2026-07-23-PEER-FAMILY-PROTOCOL-LANES.md) 为准；Compose UI、设置页和玻璃视觉以 [`docs/ADR-2026-07-23-ANDROID-UI-GLASS-PARITY.md`](docs/ADR-2026-07-23-ANDROID-UI-GLASS-PARITY.md) 为准。根目录 2025 规格和早期跨平台设计中的示例目录、版本或统一 wire-format 假设若与 ADR/源码冲突，按历史资料处理。

### 核心技术栈
- **Kotlin** - 主要开发语言
- **Jetpack Compose** - 现代化UI框架
- **Hilt** - 依赖注入框架
- **Room** - 本地数据库
- **Retrofit** - 网络请求库
- **Coroutines** - 异步编程

### 架构模式
- **MVVM** - Model-View-ViewModel架构
- **Repository Pattern** - 数据访问层抽象
- **Clean Architecture** - 分层架构设计
- **Dependency Injection** - 依赖注入模式

### 项目结构
```
app/
├── src/
│   ├── main/
│   │   ├── kotlin/com/skybridge/compass/android/
│   │   │   ├── ui/                    # UI层
│   │   │   │   ├── screens/           # 屏幕组件
│   │   │   │   ├── components/        # 通用UI组件
│   │   │   │   ├── navigation/        # 导航配置
│   │   │   │   └── theme/             # 主题配置
│   │   │   ├── data/                  # 数据层
│   │   │   │   ├── repository/        # 仓库实现
│   │   │   │   ├── local/             # 本地数据源
│   │   │   │   └── remote/            # 远程数据源
│   │   │   ├── domain/                # 业务逻辑层
│   │   │   │   ├── usecase/           # 用例
│   │   │   │   └── model/             # 领域模型
│   │   │   ├── di/                    # 依赖注入配置
│   │   │   └── utils/                 # 工具类
│   │   └── res/                       # 资源文件
│   ├── test/                          # 单元测试
│   └── androidTest/                   # UI测试
└── build.gradle.kts                   # 构建配置
```

## 开发环境要求

### 必需软件
- **Android Studio** Meerkat | 2024.3.1 Patch 1 或更高版本（匹配当前 `compileSdk = 37`）
- **JDK** 21（项目通过 Gradle toolchain 固定到 JDK 21）
- **Android SDK** Platform 37 与 Build Tools 37.x
- **Kotlin / Compose Gradle 插件** 由 Gradle 配置统一管理

### 设备基线
- 当前应用 `minSdk = 36`、`targetSdk = 37`，真机必须运行 Android 16 / API 36 或更高版本。
- Android 15 / API 35 及以下设备安装当前 APK 会失败，预期错误是 `INSTALL_FAILED_OLDER_SDK`。
- 旧设备不能通过临时降低 `minSdk` 作为修复；协议、权限和 PQC 路径按 Android 16+ 设计，需要单独的兼容迁移评审。
- `shared` 模块原生 PQC 库当前只打包 `arm64-v8a` 和 `x86_64` ABI。
- 2026-06-11 本机实测：Meitu M6 / MP1503 仍是 Android 6.0 / API 23，只能作为旧设备负向证据，不能运行当前 APK。
- 2026-06-11 的 API 35 AVD 记录只保留为历史负向/宿主诊断证据；当前开发、安装和互通验证必须使用 API 36+ 模拟器或真机，详见 `docs/ANDROID_PORTING_STATUS_2026-06-11.md`。

### 推荐配置
- **内存**: 8GB RAM 或更多
- **存储**: 至少 4GB 可用空间
- **网络**: 稳定的互联网连接（用于依赖下载）

## 快速开始

### 1. 克隆项目
```bash
git clone https://github.com/your-org/skybridge-compass.git
cd skybridge-compass/SkyBridgeCompass-Android
```

### 2. 导入项目
1. 打开Android Studio
2. 选择 "Open an existing project"
3. 选择项目根目录
4. 等待Gradle同步完成

### 3. 配置环境
1. 确保Android SDK已正确安装
2. 创建 API 36+ 虚拟设备或连接 API 36+ 真机
3. 用 `adb devices -l` 确认设备状态为 `device`
4. 用 `adb shell getprop ro.build.version.sdk` 确认设备 API level
5. 检查网络权限配置

### 4. 运行应用
```bash
# 调试版本
./gradlew assembleDebug

# 安装到设备
./gradlew installDebug

# 运行测试
./gradlew test
./gradlew connectedAndroidTest
```

## 构建配置

### 构建变体
- **debug** - 开发调试版本
  - 启用日志输出
  - 启用性能监控
  - 连接本地开发服务器
  
- **staging** - 预发布测试版本
  - 启用日志输出
  - 启用性能监控
  - 连接测试服务器
  
- **release** - 生产发布版本
  - 禁用日志输出
  - 禁用性能监控
  - 连接生产服务器
  - 启用代码混淆

### 环境变量配置
```bash
# 发布签名配置
export KEYSTORE_PATH="/absolute/path/to/production-upload-key.jks"
export KEYSTORE_PASSWORD="your_keystore_password"
export KEY_ALIAS="your_key_alias"
export KEY_PASSWORD="your_key_password"

# 发布运行时配置（也可放在未提交的 local.properties）
export SUPABASE_URL="https://your-project.supabase.co"
export SUPABASE_ANON_KEY="your_public_anon_key"
```

### 构建命令
```bash
# 构建所有变体
./gradlew build

# 构建特定变体
./gradlew assembleDebug
./gradlew assembleStaging
./gradlew assembleRelease

# 生成签名 AAB（商店/正式分发）
./gradlew bundleRelease

# 生成签名 APK（物理设备验收）
./gradlew assembleRelease
```

Release APK/AAB/install 的实际 variant 任务都依赖 `verifyReleaseArtifactConfiguration`；无论使用
qualified、缩写还是 aggregate Gradle 入口，运行时配置不完整、任一签名变量缺失、keystore
不存在/不是普通文件/为符号链接、alias 不是可解锁私钥，或证书当前无效时都会直接失败。
`compileReleaseKotlin` 与 `lintRelease` 不生成可分发 artifact，因此刻意不要求发布凭据；它们的
成功不能代替 release preflight 或已签名 artifact 验证。构建级入口覆盖可运行：

```bash
bash scripts/tests/test_release_artifact_preflight.sh
```

正式 APK 还必须从 clean canonical Git worktree 生成并通过 source/signing/mapping 绑定审计；
`EXPECTED_ANDROID_SIGNING_CERT_SHA256` 从批准的发布密钥渠道取得，禁止从待验 APK 自取：

```bash
bash scripts/check_android_packaged_placeholders.sh \
  --mode formal \
  --apk app/build/outputs/apk/release/app-release.apk \
  --mapping app/build/outputs/mapping/release/mapping.txt \
  --audit-metadata app/build/outputs/release-audit/release/metadata.properties \
  --expected-cert-sha256 "$EXPECTED_ANDROID_SIGNING_CERT_SHA256" \
  --expected-commit "$(git -C "$(git rev-parse --show-toplevel)" rev-parse HEAD)"
```

正式商店 AAB 是独立的 formal gate，不能由上面的 APK gate 代替。`bundleRelease` 会在
`app/build/outputs/release-audit/release/aab-metadata.properties` 生成 AAB/R8 mapping/clean
commit 绑定。审计脚本要求调用方提供 Google 官方 release 页面中的可执行
`bundletool-all-1.18.3.jar`，不会联网下载，也不能使用 Gradle cache 中没有 `Main-Class` 的
bundletool library JAR：

```bash
export BUNDLETOOL_JAR="/absolute/path/to/bundletool-all-1.18.3.jar"
export EXPECTED_ANDROID_UPLOAD_CERT_SHA256="AA:BB:...:FF"

bash scripts/check_android_release_aab.sh \
  --aab app/build/outputs/bundle/release/app-release.aab \
  --mapping app/build/outputs/mapping/release/mapping.txt \
  --audit-metadata app/build/outputs/release-audit/release/aab-metadata.properties \
  --bundletool "$BUNDLETOOL_JAR" \
  --expected-upload-cert-sha256 "$EXPECTED_ANDROID_UPLOAD_CERT_SHA256" \
  --expected-commit "$(git -C "$(git rev-parse --show-toplevel)" rev-parse HEAD)"
```

固定 bundletool 版本避免 floating tool 改变 APK 生成/校验语义；升级时必须同时审查官方
release、更新脚本中的版本、回归测试和本文档，这是该依赖的显式维护成本。AAB 上可本地验证的
是独立批准的 **upload certificate**；启用 Play App Signing 后，Google Play 使用另一个
**app-signing/distribution certificate** 签最终下发 APK，该身份只能由 Play Console 的
App signing 页面或从目标测试轨下载的 APK 独立验证，AAB gate 不会声称已证明它。
Formal gate 还要求 bundle config 为 `PAGE_ALIGNMENT_16K`、universal APK 通过
`zipalign -c -P 16 -v 4`，并使用 NDK `30.0.14904198` 的 `llvm-objdump -p` 逐一确认
`arm64-v8a`/`x86_64` ELF 的每个 `PT_LOAD p_align >= 0x4000`；32 位 ELF 只记录、不误作
当前官方 64 位强制门。静态对齐仍不能代替在真实 16KB kernel 模拟器/设备上的安装、启动和功能验收。

密钥文件和密码不得提交到仓库。`bundleRelease` 输出的 AAB 用于正式商店交付；APK 仅用于同源码物理设备验收。

## 测试

### 单元测试
```bash
# 运行所有单元测试
./gradlew test

# 运行特定测试类
./gradlew test --tests "DeviceDiscoveryRepositoryTest"

# 生成测试报告
./gradlew testDebugUnitTest
```

### UI测试
```bash
# 运行所有UI测试
./gradlew connectedAndroidTest

# 运行特定测试
./gradlew connectedAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.skybridge.compass.android.DashboardScreenTest
```

### 测试覆盖率
```bash
# 生成测试覆盖率报告
./gradlew jacocoTestReport
```

## 代码质量

### 静态分析
```bash
# 运行Lint检查
./gradlew lint

# 运行Detekt检查
./gradlew detekt
```

### 代码格式化
```bash
# 格式化代码
./gradlew ktlintFormat

# 检查代码格式
./gradlew ktlintCheck
```

## 性能优化

### 内存优化
- 使用LeakCanary检测内存泄漏
- 实现自定义性能监控
- 优化图片加载和缓存

### 网络优化
- 实现请求缓存机制
- 使用连接池优化
- 支持离线模式

### UI优化
- 使用Compose性能最佳实践
- 实现懒加载和虚拟化
- 优化重组性能

## 部署

### 内部测试
1. 构建staging版本
2. 上传到内部测试平台
3. 进行功能和性能测试

### 生产发布
1. 更新版本号和变更日志
2. 构建release版本
3. 进行最终测试
4. 上传到Google Play Console
5. 发布到生产环境

## 故障排除

### 常见问题

**Q: Gradle同步失败**
A: 检查网络连接，清理Gradle缓存：`./gradlew clean`

**Q: 应用无法连接到服务器**
A: 检查网络权限，确认服务器地址配置正确

**Q: 测试运行失败**
A: 确保测试设备已连接，检查测试权限配置

**Q: 构建速度慢**
A: 启用Gradle并行构建，增加JVM堆内存大小

### 调试技巧
- 使用Android Studio的调试器
- 查看Logcat输出
- 使用网络抓包工具
- 启用开发者选项

## 贡献指南

### 开发流程
1. Fork项目到个人仓库
2. 创建功能分支
3. 提交代码变更
4. 创建Pull Request
5. 代码审查和合并

### 代码规范
- 遵循Kotlin编码规范
- 使用有意义的变量和函数名
- 添加适当的注释和文档
- 编写单元测试

### 提交规范
```
type(scope): description

[optional body]

[optional footer]
```

类型：
- `feat`: 新功能
- `fix`: 错误修复
- `docs`: 文档更新
- `style`: 代码格式
- `refactor`: 重构
- `test`: 测试相关
- `chore`: 构建过程或辅助工具的变动

## 许可证

本项目采用MIT许可证，详见[LICENSE](LICENSE)文件。

## 联系方式

- **项目主页**: https://github.com/your-org/skybridge-compass
- **问题反馈**: https://github.com/your-org/skybridge-compass/issues
- **邮箱**: support@skybridge-compass.com

## 更新日志

### v1.0.0 (2024-01-XX)
- 🎉 首次发布
- ✨ 实现设备发现功能
- ✨ 实现屏幕镜像功能
- ✨ 实现远程控制功能
- ✨ 实现文件传输功能
- 🎨 现代化UI设计
- 📱 响应式布局支持
- 🧪 完整的测试覆盖
- 📚 详细的文档说明
