## CodeX 离线构建指南（Android/Gradle）

### 目标
- 在无外网的 CodeX 环境中，稳定完成 `./gradlew assembleDebug` 等任务。
- 通过本地 Maven 仓库 `third_party/m2repository` 提供依赖。

### 目录结构
- `third_party/m2repository/`: 本地 Maven 仓库（.jar/.pom）。
- `scripts/codex-env-check.sh`: 环境自检。
- `scripts/codex-build-offline.sh`: 离线构建入口。
- `scripts/codex-offline-import.sh`: 从本机 Gradle 缓存导入依赖。
- `scripts/codex-generate-deps.sh`: 导出依赖清单以预热仓库。

### 准备步骤（联网机器执行一次）
1) 在联网环境执行一次构建，拉齐依赖：
```bash
./gradlew :app:assembleDebug
```
2) 导入本机缓存到离线仓：
```bash
./scripts/codex-offline-import.sh
```
完成后将项目连同 `third_party/m2repository` 一并同步到 CodeX。

可选：生成依赖清单以核对覆盖率
```bash
./scripts/codex-generate-deps.sh app
cat build/codex/app-coordinates.txt
```

### 在 CodeX 中构建（离线）
1) 自检环境：
```bash
./scripts/codex-env-check.sh
```
2) 离线构建：
```bash
./scripts/codex-build-offline.sh assembleDebug
```

### 常见问题
- 缺少某些 `com.android.tools` 或 `androidx` 组件：
  - 确认离线仓内存在对应 group/name/version 的 `.jar` 与 `.pom`。
  - 如缺失，请在联网机构建后重新运行 `codex-offline-import.sh` 并同步。
- 版本不一致报错（AGP/Kotlin）：
  - 确认根 `build.gradle.kts` 与 `gradle/libs.versions.toml` 的版本一致。
- AAPT/资源链接失败：
  - 核对 `res/values/themes.xml` 与 `compileSdk`/`targetSdk` 设置是否匹配。

### 备注
- `settings.gradle.kts` 已优先接入 `third_party/m2repository`（若存在）。
- 如需完全禁网，可在 CI 中加入 `--offline` 并屏蔽外部仓库访问。

