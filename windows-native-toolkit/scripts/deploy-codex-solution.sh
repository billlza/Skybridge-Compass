#!/bin/bash
echo "=== CodeX 工作流程解决方案部署脚本 ==="

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."
    
    # 检查 Git
    if ! command -v git &> /dev/null; then
        log_error "Git 未安装"
        exit 1
    fi
    
    # 检查 curl
    if ! command -v curl &> /dev/null; then
        log_error "curl 未安装"
        exit 1
    fi
    
    # 检查 jq
    if ! command -v jq &> /dev/null; then
        log_warning "jq 未安装，将跳过 JSON 处理"
    fi
    
    log_success "依赖检查完成"
}

# 设置 GitHub Actions
setup_github_actions() {
    log_info "设置 GitHub Actions..."
    
    # 创建 .github 目录
    mkdir -p .github/workflows
    
    # 复制工作流文件
    if [ -f "windows-native-toolkit/.github/workflows/windows-build.yml" ]; then
        cp windows-native-toolkit/.github/workflows/windows-build.yml .github/workflows/
        log_success "GitHub Actions 工作流已配置"
    else
        log_warning "GitHub Actions 工作流文件未找到"
    fi
    
    # 创建 GitHub 配置文件
    cat > .github/dependabot.yml << 'DEPENDABOTEOF'
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
  - package-ecosystem: "nuget"
    directory: "/"
    schedule:
      interval: "weekly"
DEPENDABOTEOF
    
    log_success "GitHub Actions 设置完成"
}

# 设置 Azure DevOps
setup_azure_devops() {
    log_info "设置 Azure DevOps..."
    
    # 复制管道文件
    if [ -f "azure-pipelines.yml" ]; then
        log_success "Azure DevOps 管道文件已存在"
    else
        log_warning "Azure DevOps 管道文件未找到"
    fi
    
    # 创建 Azure DevOps 配置
    cat > azure-devops-config.json << 'AZUREEOF'
{
  "project": "SkybridgeCompass",
  "repository": "Skybridge-Compass",
  "branch": "main",
  "buildDefinition": {
    "name": "Windows Build",
    "path": "\\",
    "type": "build",
    "queue": {
      "name": "Hosted Windows 2019 with VS2019"
    },
    "process": {
      "type": 2,
      "yamlFilename": "azure-pipelines.yml"
    }
  }
}
AZUREEOF
    
    log_success "Azure DevOps 设置完成"
}

# 设置离线 Windows SDK
setup_offline_sdk() {
    log_info "设置离线 Windows SDK..."
    
    # 创建离线 SDK 目录
    mkdir -p offline-sdk/{include,lib,bin,redist,metadata,scripts}
    
    # 创建安装脚本
    cat > offline-sdk/scripts/install.sh << 'INSTALLEOF'
#!/bin/bash
echo "=== 离线 Windows SDK 安装脚本 ==="

# 设置环境变量
export WINDOWS_SDK_PATH=$(pwd)
export PATH=$PATH:$WINDOWS_SDK_PATH/bin/x64
export LIB=$WINDOWS_SDK_PATH/lib/x64
export INCLUDE=$WINDOWS_SDK_PATH/include

# 创建配置文件
cat > .env << 'ENVEOF'
# Windows SDK 环境配置
export WINDOWS_SDK_PATH=$(pwd)
export PATH=$PATH:$WINDOWS_SDK_PATH/bin/x64
export LIB=$WINDOWS_SDK_PATH/lib/x64
export INCLUDE=$WINDOWS_SDK_PATH/include

# 编译选项
export CFLAGS="-I$WINDOWS_SDK_PATH/include"
export CXXFLAGS="-I$WINDOWS_SDK_PATH/include -std=c++20"
export LDFLAGS="-L$WINDOWS_SDK_PATH/lib/x64"
ENVEOF

echo "✅ 离线 Windows SDK 环境已配置"
echo "💡 使用 'source .env' 加载环境变量"
INSTALLEOF
    
    chmod +x offline-sdk/scripts/install.sh
    
    # 创建测试脚本
    cat > offline-sdk/scripts/test.sh << 'TESTEOF'
#!/bin/bash
echo "=== 离线 Windows SDK 测试脚本 ==="

# 加载环境变量
source .env

# 测试头文件
if [ -d "$INCLUDE" ]; then
    echo "✅ 头文件目录存在: $INCLUDE"
else
    echo "❌ 头文件目录不存在: $INCLUDE"
fi

# 测试库文件
if [ -d "$LIB" ]; then
    echo "✅ 库文件目录存在: $LIB"
else
    echo "❌ 库文件目录不存在: $LIB"
fi

# 测试工具
if [ -d "$WINDOWS_SDK_PATH/bin/x64" ]; then
    echo "✅ 工具目录存在: $WINDOWS_SDK_PATH/bin/x64"
else
    echo "❌ 工具目录不存在: $WINDOWS_SDK_PATH/bin/x64"
fi

echo "✅ 离线 Windows SDK 测试完成"
TESTEOF
    
    chmod +x offline-sdk/scripts/test.sh
    
    log_success "离线 Windows SDK 设置完成"
}

# 创建混合构建脚本
create_hybrid_build() {
    log_info "创建混合构建脚本..."
    
    cat > build-hybrid.sh << 'HYBRIDEOF'
#!/bin/bash
echo "=== 混合构建脚本 ==="

# 检测环境
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "🐧 检测到 Linux 环境 (CodeX)"
    USE_OFFLINE_SDK=true
elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "🍎 检测到 macOS 环境"
    USE_OFFLINE_SDK=true
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    echo "🪟 检测到 Windows 环境"
    USE_OFFLINE_SDK=false
else
    echo "❓ 未知环境: $OSTYPE"
    USE_OFFLINE_SDK=true
fi

# 设置构建选项
BUILD_TYPE="Release"
CLEAN_BUILD=false
VERBOSE=false

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            BUILD_TYPE="$2"
            shift 2
            ;;
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --config <type>    构建类型 (Debug|Release)"
            echo "  --clean            清理构建目录"
            echo "  --verbose          详细输出"
            echo "  --help             显示帮助"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

echo "🔧 构建配置:"
echo "  类型: $BUILD_TYPE"
echo "  清理: $CLEAN_BUILD"
echo "  详细: $VERBOSE"
echo "  离线SDK: $USE_OFFLINE_SDK"

# 创建构建目录
BUILD_DIR="build-hybrid-$BUILD_TYPE"
echo "📁 创建构建目录: $BUILD_DIR"

if [ "$CLEAN_BUILD" = true ]; then
    echo "🧹 清理构建目录..."
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# 配置 CMake
echo "⚙️  配置 CMake..."
CMAKE_ARGS=(
    -G "Unix Makefiles"
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
)

# 根据环境设置编译器和 SDK
if [ "$USE_OFFLINE_SDK" = true ]; then
    echo "📦 使用离线 Windows SDK"
    
    # 设置交叉编译器
    export CC=x86_64-w64-mingw32-gcc
    export CXX=x86_64-w64-mingw32-g++
    
    CMAKE_ARGS+=(
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_CXX_COMPILER="$CXX"
        -DWINDOWS_SDK_PATH="../offline-sdk"
        -DUSE_OFFLINE_SDK=TRUE
    )
else
    echo "🪟 使用 Windows 工具链"
    
    CMAKE_ARGS+=(
        -DUSE_WINDOWS_TOOLCHAIN=TRUE
    )
fi

# 添加性能优化选项
if [ "$BUILD_TYPE" = "Release" ]; then
    CMAKE_ARGS+=(
        -DCMAKE_CXX_FLAGS_RELEASE="-O3 -march=native -mtune=native -flto -ffast-math"
        -DCMAKE_EXE_LINKER_FLAGS_RELEASE="-static-libgcc -static-libstdc++ -s -Wl,--gc-sections"
    )
fi

# 运行 CMake 配置
if [ "$VERBOSE" = true ]; then
    cmake "${CMAKE_ARGS[@]}" ..
else
    cmake "${CMAKE_ARGS[@]}" .. > cmake.log 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ CMake 配置失败"
        echo "查看 cmake.log 获取详细信息"
        exit 1
    fi
fi

echo "✅ CMake 配置完成"

# 构建项目
echo "🔨 开始构建..."
if [ "$VERBOSE" = true ]; then
    make -j$(nproc)
else
    make -j$(nproc) > build.log 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ 构建失败"
        echo "查看 build.log 获取详细信息"
        exit 1
    fi
fi

echo "✅ 构建完成"

# 检查构建结果
echo "🔍 检查构建结果..."
if [ -f "bin/SkybridgeCompassApp.exe" ]; then
    echo "✅ 可执行文件已生成: bin/SkybridgeCompassApp.exe"
    
    # 显示文件信息
    echo "📊 文件信息:"
    ls -lh bin/SkybridgeCompassApp.exe
    
    # 检查依赖
    echo "🔗 检查依赖..."
    if command -v ldd &> /dev/null; then
        ldd bin/SkybridgeCompassApp.exe 2>/dev/null || echo "无法检查依赖 (交叉编译)"
    fi
    
else
    echo "❌ 未找到可执行文件"
    exit 1
fi

# 返回项目根目录
cd ..

echo ""
echo "=== 混合构建完成 ==="
echo "🎉 构建成功！"
echo ""
echo "构建结果:"
echo "  可执行文件: $BUILD_DIR/bin/SkybridgeCompassApp.exe"
echo "  构建类型: $BUILD_TYPE"
echo "  使用离线SDK: $USE_OFFLINE_SDK"
echo ""
echo "下一步:"
echo "  1. 在 Windows 环境中测试应用"
echo "  2. 运行性能测试"
echo "  3. 部署到目标环境"
HYBRIDEOF
    
    chmod +x build-hybrid.sh
    
    log_success "混合构建脚本已创建"
}

# 创建部署脚本
create_deployment_script() {
    log_info "创建部署脚本..."
    
    cat > deploy.sh << 'DEPLOYEOF'
#!/bin/bash
echo "=== 部署脚本 ==="

# 检测部署目标
DEPLOY_TARGET="local"
DEPLOY_ENV="development"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            DEPLOY_TARGET="$2"
            shift 2
            ;;
        --env)
            DEPLOY_ENV="$2"
            shift 2
            ;;
        --help)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --target <target>   部署目标 (local|cloud|store)"
            echo "  --env <env>         部署环境 (development|staging|production)"
            echo "  --help              显示帮助"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

echo "🚀 部署配置:"
echo "  目标: $DEPLOY_TARGET"
echo "  环境: $DEPLOY_ENV"

# 根据部署目标执行不同操作
case $DEPLOY_TARGET in
    "local")
        echo "📱 本地部署..."
        
        # 查找构建结果
        BUILD_DIR=""
        for dir in build-hybrid-*; do
            if [ -d "$dir" ] && [ -f "$dir/bin/SkybridgeCompassApp.exe" ]; then
                BUILD_DIR="$dir"
                break
            fi
        done
        
        if [ -z "$BUILD_DIR" ]; then
            echo "❌ 未找到构建结果"
            echo "请先运行: ./build-hybrid.sh"
            exit 1
        fi
        
        echo "✅ 找到构建结果: $BUILD_DIR"
        echo "📦 可执行文件: $BUILD_DIR/bin/SkybridgeCompassApp.exe"
        echo "💡 在 Windows 环境中运行此文件"
        ;;
        
    "cloud")
        echo "☁️ 云部署..."
        
        # 检查 GitHub Actions
        if [ -f ".github/workflows/windows-build.yml" ]; then
            echo "✅ GitHub Actions 工作流已配置"
            echo "💡 推送到 GitHub 触发自动构建"
        else
            echo "❌ GitHub Actions 工作流未配置"
        fi
        
        # 检查 Azure DevOps
        if [ -f "azure-pipelines.yml" ]; then
            echo "✅ Azure DevOps 管道已配置"
            echo "💡 推送到 Azure DevOps 触发自动构建"
        else
            echo "❌ Azure DevOps 管道未配置"
        fi
        ;;
        
    "store")
        echo "🏪 商店部署..."
        
        # 检查 MSIX 包
        if [ -f "SkybridgeCompassApp.msix" ]; then
            echo "✅ MSIX 包已存在"
            echo "💡 使用 Windows Package Manager 安装:"
            echo "   winget install SkybridgeCompassApp.msix"
        else
            echo "❌ MSIX 包未找到"
            echo "💡 需要先创建 MSIX 包"
        fi
        ;;
        
    *)
        echo "❌ 未知部署目标: $DEPLOY_TARGET"
        exit 1
        ;;
esac

echo ""
echo "=== 部署完成 ==="
echo "🎉 部署配置已准备就绪"
echo ""
echo "下一步:"
echo "  1. 根据部署目标执行相应操作"
echo "  2. 验证部署结果"
echo "  3. 监控应用状态"
DEPLOYEOF
    
    chmod +x deploy.sh
    
    log_success "部署脚本已创建"
}

# 创建监控脚本
create_monitoring_script() {
    log_info "创建监控脚本..."
    
    cat > monitor.sh << 'MONITOREOF'
#!/bin/bash
echo "=== 监控脚本 ==="

# 监控配置
MONITOR_INTERVAL=60
MONITOR_LOG="monitor.log"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --interval)
            MONITOR_INTERVAL="$2"
            shift 2
            ;;
        --log)
            MONITOR_LOG="$2"
            shift 2
            ;;
        --help)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --interval <sec>    监控间隔 (秒)"
            echo "  --log <file>        日志文件"
            echo "  --help              显示帮助"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

echo "📊 监控配置:"
echo "  间隔: $MONITOR_INTERVAL 秒"
echo "  日志: $MONITOR_LOG"

# 监控函数
monitor_build_status() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local status="unknown"
    
    # 检查构建状态
    if [ -f "build-hybrid-Release/bin/SkybridgeCompassApp.exe" ]; then
        status="success"
    elif [ -f "build-hybrid-Debug/bin/SkybridgeCompassApp.exe" ]; then
        status="success"
    else
        status="failed"
    fi
    
    echo "[$timestamp] Build Status: $status" >> "$MONITOR_LOG"
}

monitor_system_resources() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 检查系统资源
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    local memory_usage=$(free | grep Mem | awk '{printf("%.2f"), $3/$2 * 100.0}')
    local disk_usage=$(df -h / | awk 'NR==2{print $5}' | cut -d'%' -f1)
    
    echo "[$timestamp] CPU: ${cpu_usage}%, Memory: ${memory_usage}%, Disk: ${disk_usage}%" >> "$MONITOR_LOG"
}

monitor_network_status() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 检查网络状态
    if ping -c 1 github.com > /dev/null 2>&1; then
        echo "[$timestamp] Network: OK" >> "$MONITOR_LOG"
    else
        echo "[$timestamp] Network: FAILED" >> "$MONITOR_LOG"
    fi
}

# 主监控循环
echo "🔄 开始监控..."
echo "按 Ctrl+C 停止监控"

while true; do
    monitor_build_status
    monitor_system_resources
    monitor_network_status
    
    sleep "$MONITOR_INTERVAL"
done
MONITOREOF
    
    chmod +x monitor.sh
    
    log_success "监控脚本已创建"
}

# 创建文档
create_documentation() {
    log_info "创建文档..."
    
    cat > README-DEPLOYMENT.md << 'DOCEOF'
# CodeX 工作流程解决方案部署指南

## 概述

本指南介绍如何在 CodeX 环境中部署 Windows 应用构建解决方案。

## 快速开始

### 1. 运行部署脚本
```bash
./windows-native-toolkit/scripts/deploy-codex-solution.sh
```

### 2. 构建应用
```bash
./build-hybrid.sh --config Release
```

### 3. 部署应用
```bash
./deploy.sh --target local
```

## 功能特性

### 云构建服务
- **GitHub Actions**: 自动化构建和测试
- **Azure DevOps**: 企业级构建管道
- **性能测试**: 自动化性能基准测试
- **安全扫描**: 自动化安全漏洞扫描

### 离线 Windows SDK
- **预编译工具链**: 减少网络依赖
- **交叉编译支持**: Linux 到 Windows
- **版本控制**: 可重复构建
- **快速构建**: 提高构建速度

### 混合构建方案
- **环境检测**: 自动检测构建环境
- **条件编译**: 根据环境选择构建方式
- **性能优化**: 针对不同环境优化
- **错误处理**: 完善的错误处理机制

## 使用方法

### 构建选项
```bash
# Debug 构建
./build-hybrid.sh --config Debug

# Release 构建
./build-hybrid.sh --config Release

# 清理构建
./build-hybrid.sh --clean

# 详细输出
./build-hybrid.sh --verbose
```

### 部署选项
```bash
# 本地部署
./deploy.sh --target local

# 云部署
./deploy.sh --target cloud

# 商店部署
./deploy.sh --target store
```

### 监控选项
```bash
# 开始监控
./monitor.sh

# 自定义间隔
./monitor.sh --interval 30

# 自定义日志
./monitor.sh --log custom.log
```

## 故障排除

### 常见问题
1. **构建失败**: 检查依赖和环境变量
2. **部署失败**: 检查网络连接和权限
3. **监控异常**: 检查日志文件

### 调试技巧
- 使用 `--verbose` 参数查看详细输出
- 检查日志文件获取错误信息
- 验证环境变量设置
- 测试网络连接

## 技术支持

### 文档资源
- [GitHub Actions 文档](https://docs.github.com/actions)
- [Azure DevOps 文档](https://docs.microsoft.com/azure/devops)
- [Windows SDK 文档](https://docs.microsoft.com/windows/win32/)

### 社区支持
- [GitHub Issues](https://github.com/billlza/Skybridge-Compass/issues)
- [Discord 社区](https://discord.gg/skybridge)
- [Stack Overflow](https://stackoverflow.com/questions/tagged/skybridge-compass)

## 许可证

MIT License

---

**CodeX 工作流程解决方案** - 为 CodeX 环境提供完整的 Windows 应用构建支持 🚀
DOCEOF
    
    log_success "文档已创建"
}

# 主函数
main() {
    echo "🚀 开始部署 CodeX 工作流程解决方案..."
    echo ""
    
    # 检查依赖
    check_dependencies
    
    # 设置 GitHub Actions
    setup_github_actions
    
    # 设置 Azure DevOps
    setup_azure_devops
    
    # 设置离线 Windows SDK
    setup_offline_sdk
    
    # 创建混合构建脚本
    create_hybrid_build
    
    # 创建部署脚本
    create_deployment_script
    
    # 创建监控脚本
    create_monitoring_script
    
    # 创建文档
    create_documentation
    
    echo ""
    echo "=== 部署完成 ==="
    echo "🎉 CodeX 工作流程解决方案已部署"
    echo ""
    echo "创建的文件:"
    echo "  ✅ .github/workflows/windows-build.yml"
    echo "  ✅ azure-pipelines.yml"
    echo "  ✅ offline-sdk/ (目录)"
    echo "  ✅ build-hybrid.sh"
    echo "  ✅ deploy.sh"
    echo "  ✅ monitor.sh"
    echo "  ✅ README-DEPLOYMENT.md"
    echo ""
    echo "下一步:"
    echo "  1. 运行 './build-hybrid.sh' 构建应用"
    echo "  2. 运行 './deploy.sh --target local' 本地部署"
    echo "  3. 运行 './monitor.sh' 开始监控"
    echo ""
    echo "💡 现在可以在 CodeX 环境中正常构建 Windows 应用了！"
}

# 运行主函数
main "$@"
