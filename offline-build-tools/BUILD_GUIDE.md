# 云桥司南构建指南

## CodeX 自动化构建

### 快速开始

对于 CodeX 环境，使用自动化构建脚本：

```bash
# 1. 克隆仓库
git clone https://github.com/billlza/Skybridge-Compass.git
cd Skybridge-Compass

# 2. 复制工具包
cp -r offline-build-tools/* .

# 3. 运行 CodeX 自动化构建
./codex-build-ultimate.sh
```

### 脚本说明

#### `codex-build-ultimate.sh` - CodeX 终极构建脚本
- **功能**: 自动发现可用的 Java 21 运行时
- **特点**: 完全离线构建，无网络依赖
- **兼容性**: 专为 CodeX 环境优化
- **使用**: `./codex-build-ultimate.sh`

#### `codex-env-check.sh` - 环境检测脚本
- **功能**: 检测 CodeX 环境配置
- **用途**: 诊断构建问题
- **使用**: `./codex-env-check.sh`

### 构建流程

1. **环境检测**: 自动检测 Java 环境
2. **配置清理**: 清除环境变量冲突
3. **AGP 安装**: 安装 Android Gradle Plugin 8.7.3
4. **离线构建**: 执行 `assembleDebug`
5. **结果验证**: 检查 APK 输出

### 故障排除

如果构建失败，请：

1. 运行环境检测：
   ```bash
   ./codex-env-check.sh
   ```

2. 检查 Java 环境：
   ```bash
   java -version
   ```

3. 查看构建日志：
   ```bash
   ./codex-build-ultimate.sh 2>&1 | tee build.log
   ```

### 技术规格

- **Gradle**: 9.0.0
- **Android Gradle Plugin**: 8.7.3
- **Kotlin**: 2.0.20
- **Java**: 21 LTS (自动检测)
- **构建模式**: 完全离线

### 支持

如有问题，请检查：
- [项目状态报告](project-status.md)
- [静态分析脚本](static-analysis.sh)
- [离线验证脚本](offline-verify.sh)
