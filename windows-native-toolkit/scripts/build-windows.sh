#!/bin/bash
echo "=== Windows 应用构建脚本 ==="

# 加载环境变量
if [ -f ".env" ]; then
    echo "📋 加载环境变量..."
    source .env
else
    echo "⚠️  未找到 .env 文件，使用默认配置"
    export CC=x86_64-w64-mingw32-gcc
    export CXX=x86_64-w64-mingw32-g++
    export AR=x86_64-w64-mingw32-ar
    export STRIP=x86_64-w64-mingw32-strip
fi

# 检查交叉编译器
if ! command -v $CC &> /dev/null; then
    echo "❌ 交叉编译器未找到: $CC"
    echo "请运行 ./scripts/setup-codex.sh 安装开发环境"
    exit 1
fi

echo "✅ 使用编译器: $CC"
echo "✅ 使用 C++ 编译器: $CXX"

# 解析命令行参数
BUILD_TYPE="Release"
CLEAN_BUILD=false
VERBOSE=false
PARALLEL_JOBS=$(nproc)

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
        --jobs)
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        --help)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --config <type>    构建类型 (Debug|Release|RelWithDebInfo|MinSizeRel)"
            echo "  --clean            清理构建目录"
            echo "  --verbose          详细输出"
            echo "  --jobs <num>       并行作业数"
            echo "  --help             显示帮助"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

echo "🔧 构建配置:"
echo "  类型: $BUILD_TYPE"
echo "  清理: $CLEAN_BUILD"
echo "  详细: $VERBOSE"
echo "  并行: $PARALLEL_JOBS"

# 创建构建目录
BUILD_DIR="build/windows-$BUILD_TYPE"
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
    -DCMAKE_SYSTEM_NAME=Windows
    -DCMAKE_C_COMPILER="$CC"
    -DCMAKE_CXX_COMPILER="$CXX"
    -DCMAKE_AR="$AR"
    -DCMAKE_RANLIB="$RANLIB"
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    -DCMAKE_VERBOSE_MAKEFILE="$VERBOSE"
)

# 添加性能优化选项
if [ "$BUILD_TYPE" = "Release" ]; then
    CMAKE_ARGS+=(
        -DCMAKE_CXX_FLAGS_RELEASE="-O3 -march=native -mtune=native -flto -ffast-math"
        -DCMAKE_EXE_LINKER_FLAGS_RELEASE="-static-libgcc -static-libstdc++ -s -Wl,--gc-sections"
    )
fi

# 添加调试选项
if [ "$BUILD_TYPE" = "Debug" ]; then
    CMAKE_ARGS+=(
        -DCMAKE_CXX_FLAGS_DEBUG="-g -O0 -DDEBUG"
        -DCMAKE_EXE_LINKER_FLAGS_DEBUG="-g"
    )
fi

# 运行 CMake 配置
if [ "$VERBOSE" = true ]; then
    cmake "${CMAKE_ARGS[@]}" ../..
else
    cmake "${CMAKE_ARGS[@]}" ../.. > cmake.log 2>&1
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
    make -j"$PARALLEL_JOBS"
else
    make -j"$PARALLEL_JOBS" > build.log 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ 构建失败"
        echo "查看 build.log 获取详细信息"
        exit 1
    fi
fi

echo "✅ 构建完成"

# 检查构建结果
echo "🔍 检查构建结果..."
if [ -f "bin/MyWinUI3App.exe" ]; then
    echo "✅ 可执行文件已生成: bin/MyWinUI3App.exe"
    
    # 显示文件信息
    echo "📊 文件信息:"
    ls -lh bin/MyWinUI3App.exe
    
    # 检查依赖
    echo "🔗 检查依赖..."
    if command -v ldd &> /dev/null; then
        ldd bin/MyWinUI3App.exe 2>/dev/null || echo "无法检查依赖 (交叉编译)"
    fi
    
    # 检查符号
    echo "🔍 检查符号..."
    if command -v nm &> /dev/null; then
        nm bin/MyWinUI3App.exe 2>/dev/null | head -10 || echo "无法检查符号"
    fi
    
else
    echo "❌ 未找到可执行文件"
    exit 1
fi

# 生成构建报告
echo "📋 生成构建报告..."
cat > build-report.txt << 'REPORTEOF'
# Windows 应用构建报告

## 构建信息
- 构建时间: $(date)
- 构建类型: $BUILD_TYPE
- 编译器: $CC
- C++ 编译器: $CXX
- 并行作业: $PARALLEL_JOBS

## 构建结果
- 可执行文件: bin/MyWinUI3App.exe
- 文件大小: $(ls -lh bin/MyWinUI3App.exe | awk '{print $5}')

## 性能优化
- 编译优化: -O3 -march=native -mtune=native
- 链接优化: -static-libgcc -static-libstdc++ -s
- LTO: 启用
- 快速数学: 启用

## 下一步
1. 运行应用程序进行测试
2. 运行性能基准测试
3. 部署到目标环境
REPORTEOF

echo "📄 构建报告已生成: build-report.txt"

# 返回项目根目录
cd ../..

echo ""
echo "=== 构建完成 ==="
echo "🎉 Windows 应用构建成功！"
echo ""
echo "构建结果:"
echo "  可执行文件: $BUILD_DIR/bin/MyWinUI3App.exe"
echo "  构建报告: $BUILD_DIR/build-report.txt"
echo ""
echo "下一步:"
echo "  1. 运行 './scripts/test-performance.sh' 测试性能"
echo "  2. 运行 './scripts/package-windows.sh' 打包应用"
echo "  3. 部署到 Windows 环境进行测试"
