# 离线构建最小依赖包

## 重要说明

⚠️ **这个包只包含构建APK的最小必要依赖，不是完整的离线构建方案！**

## 包含的依赖

- Android Gradle Plugin 8.9.0
- Kotlin 2.0.20 核心库
- Compose BOM 2024.09.02
- 基础 AndroidX 库

## 使用方法

1. **解压到项目根目录**：
   ```bash
   # 将 third_party/essential/ 复制到项目根目录
   cp -r third_party/essential/ ./
   ```

2. **运行离线构建**：
   ```bash
   ./scripts/codex-env-check.sh
   ./scripts/codex-build-offline.sh assembleDebug
   ```

## 限制

- 只包含核心依赖，可能仍需要网络下载部分依赖
- 主要用于减少网络依赖，不是完全离线构建
- 建议在CodeX环境中先运行一次在线构建，然后使用此包

## 文件结构

```
third_party/essential/
├── README.md
├── gradle-wrapper.jar
└── m2repository/
    ├── com.android.application/
    ├── org.jetbrains.kotlin/
    └── androidx.compose/
```
