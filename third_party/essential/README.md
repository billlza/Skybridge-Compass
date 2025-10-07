# 离线构建关键依赖

## 使用方法

1. 将 `third_party/essential/` 目录复制到你的项目根目录
2. 运行 `./scripts/codex-env-check.sh` 检查环境
3. 运行 `./scripts/codex-build-offline.sh assembleDebug` 构建

## 包含的关键依赖

- Android Gradle Plugin 8.9.0
- Kotlin 2.0.20
- Compose BOM 2024.09.02
- 核心 AndroidX 库

注意：完整依赖列表请参考 `scripts/codex-generate-deps.sh`

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

## 离线构建说明

这些文件是从本地 Gradle 缓存中提取的关键依赖，用于在 CodeX Linux 环境中进行离线构建。