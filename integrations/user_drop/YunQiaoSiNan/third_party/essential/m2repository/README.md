# 本地Maven仓库

这个目录包含离线构建所需的所有依赖项。

## 使用方法

1. 确保 `settings.gradle.kts` 中已配置本地仓库
2. 运行 `./gradlew assembleDebug --offline` 进行离线构建

## 目录结构

```
m2repository/
├── com/
│   └── android/
│       └── tools/
│           └── build/
│               └── gradle/
├── org/
│   └── jetbrains/
│       └── kotlin/
└── androidx/
    └── compose/
```
