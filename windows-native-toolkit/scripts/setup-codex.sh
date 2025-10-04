#!/bin/bash
echo "=== CodeX Windows 开发环境设置 ==="

# 检测操作系统
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "✅ 检测到 Linux 环境 (CodeX)"
    
    # 更新包管理器
    echo "📦 更新包管理器..."
    sudo apt-get update
    
    # 安装基础开发工具
    echo "📦 安装基础开发工具..."
    sudo apt-get install -y build-essential
    sudo apt-get install -y cmake
    sudo apt-get install -y ninja-build
    sudo apt-get install -y pkg-config
    
    # 安装 MinGW-w64 交叉编译器
    echo "📦 安装 MinGW-w64 交叉编译器..."
    sudo apt-get install -y mingw-w64
    
    # 安装 Windows 开发库
    echo "📦 安装 Windows 开发库..."
    sudo apt-get install -y libc6-dev-i386
    sudo apt-get install -y gcc-multilib
    
    # 安装 Wine (可选)
    echo "📦 安装 Wine 环境..."
    sudo apt-get install -y wine
    
    # 安装 Git
    echo "📦 安装 Git..."
    sudo apt-get install -y git
    
    # 安装 Python (用于构建脚本)
    echo "📦 安装 Python..."
    sudo apt-get install -y python3
    sudo apt-get install -y python3-pip
    
    # 安装 Node.js (用于前端工具)
    echo "📦 安装 Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
    
    # 验证安装
    echo "🔍 验证安装..."
    echo "GCC 版本:"
    gcc --version | head -1
    
    echo "MinGW-w64 版本:"
    x86_64-w64-mingw32-gcc --version | head -1
    
    echo "CMake 版本:"
    cmake --version | head -1
    
    echo "Wine 版本:"
    wine --version
    
    echo "Git 版本:"
    git --version
    
    echo "Python 版本:"
    python3 --version
    
    echo "Node.js 版本:"
    node --version
    
    echo "✅ 环境设置完成"
    
elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "✅ 检测到 macOS 环境"
    
    # 检查 Homebrew
    if ! command -v brew &> /dev/null; then
        echo "📦 安装 Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    
    # 安装开发工具
    echo "📦 安装开发工具..."
    brew install cmake
    brew install ninja
    brew install mingw-w64
    brew install wine
    
    echo "✅ macOS 环境设置完成"
    
else
    echo "❌ 不支持的操作系统: $OSTYPE"
    echo "支持的平台: Linux (CodeX), macOS"
    exit 1
fi

# 创建工具目录
echo "📁 创建工具目录..."
mkdir -p tools/msvc
mkdir -p tools/windows-sdk
mkdir -p tools/cpp-winrt
mkdir -p tools/winui3
mkdir -p libraries/network
mkdir -p libraries/crypto
mkdir -p libraries/compression
mkdir -p libraries/performance
mkdir -p templates/winui3-app
mkdir -p templates/console-app
mkdir -p templates/service-app
mkdir -p examples/basic-winui3
mkdir -p examples/network-client
mkdir -p examples/performance-demo
mkdir -p examples/advanced-features

# 设置环境变量
echo "🔧 设置环境变量..."
export CC=x86_64-w64-mingw32-gcc
export CXX=x86_64-w64-mingw32-g++
export AR=x86_64-w64-mingw32-ar
export STRIP=x86_64-w64-mingw32-strip
export RANLIB=x86_64-w64-mingw32-ranlib

# 创建环境配置文件
cat > .env << 'ENVEOF'
# Windows 开发环境配置
export CC=x86_64-w64-mingw32-gcc
export CXX=x86_64-w64-mingw32-g++
export AR=x86_64-w64-mingw32-ar
export STRIP=x86_64-w64-mingw32-strip
export RANLIB=x86_64-w64-mingw32-ranlib

# 工具路径
export WINDOWS_SDK_PATH=/usr/x86_64-w64-mingw32
export CPP_WINRT_PATH=./tools/cpp-winrt
export WINUI3_PATH=./tools/winui3

# 编译选项
export CFLAGS="-O3 -march=native -mtune=native"
export CXXFLAGS="-O3 -march=native -mtune=native -std=c++20"
export LDFLAGS="-static-libgcc -static-libstdc++"

# 性能优化
export MAKEFLAGS="-j$(nproc)"
ENVEOF

echo "📝 环境配置文件已创建: .env"
echo "💡 使用 'source .env' 加载环境变量"

echo ""
echo "=== 设置完成 ==="
echo "🚀 现在可以开始开发 Windows 应用了！"
echo ""
echo "下一步:"
echo "1. 运行 'source .env' 加载环境变量"
echo "2. 运行 './scripts/build-windows.sh' 构建项目"
echo "3. 运行 './scripts/test-performance.sh' 测试性能"
