# 合并与依赖校验快速指南

为了顺利把当前 `work` 分支的最新代码同步到你本地环境，并解决常见的导入或依赖缺失问题，可依照以下步骤操作。

## 1. 同步最新提交
1. `git fetch origin work`
2. 在本地特性分支上执行 `git rebase origin/work`（或使用 `git merge origin/work`）。
3. 如果出现冲突，优先保留「Incoming」(来自 `work` 分支) 的修改，这些内容包含了我们补充的 Compose/Android 导入与修复后的 UI 代码。

## 2. 解决冲突后的验证
1. 运行 `./static-analysis.sh` 确认 Kotlin 文件无语法问题。
2. 若你具备完整的离线依赖缓存，可执行 `./codex-build-ultimate.sh` 或 `./assemble-offline.sh` 进行离线构建；否则在联网环境执行 `./gradlew assembleDebug` 验证 Gradle 构建。

## 3. 常见导入/依赖问题排查
- **Compose 组件缺少导入**：确保 `app/build.gradle.kts` 中包含 `foundation`、`foundation-layout`、`material3` 等依赖；在 IDE 中触发 *Sync Project with Gradle Files* 以刷新索引。
- **Android 平台类缺失（如 `PowerManager`, `WpsInfo`）**：确认编译 SDK 设为 34+，并在 `gradle/libs.versions.toml` 与根 `build.gradle.kts` 中保持 Android Gradle Plugin 版本一致（当前为 `8.7.3`）。
- **Kotlin 扩展函数（`coerceAtLeast`、`coerceIn` 等）未解析**：这些函数位于 `kotlin.math` 包，IDE 同步后即可识别；如仍报错，可在文件顶部手动补充 `import kotlin.math.coerceAtLeast` 等语句。

## 4. 推送与提交
1. 冲突解决并验证通过后执行 `git status`，确认所有文件已标记为已解决。
2. 运行 `git add .`，随后 `git commit`，填写合适的提交信息。
3. 将分支推送到远端：`git push origin <your-branch>`。
4. 在 GitHub 创建或更新 Pull Request，说明已对齐 `work` 分支的依赖和导入修复。

按照以上流程即可在本地成功复现并集成最新代码，同时避免再次遇到缺少导入或版本不匹配的问题。
