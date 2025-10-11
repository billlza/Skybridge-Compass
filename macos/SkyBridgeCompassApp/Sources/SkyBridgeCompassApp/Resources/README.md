将应用图标放在本目录，文件名建议如下：

- AppIcon.icns（优先使用）
- AppIcon.png（作为后备方案，建议 1024×1024）

SwiftPM 会在构建时打包本目录资源。应用启动时会优先从 `Bundle.module` 读取图标，若未找到则回退至 `Bundle.main`。

注意：更新图标后请重新构建并运行。

自动生成 .icns：

- 将源图放为 `AppIcon.png`（建议 1024×1024）。
- 运行脚本：`bash scripts/generate-app-icon.sh`。
- 生成结果：`Resources/AppIcon.icns`，随构建自动打包。

CI 集成：

- 已在 `.github/workflows/macos-build.yml` 集成，CI 会在构建前尝试生成 `.icns`（若有 `AppIcon.png`）。