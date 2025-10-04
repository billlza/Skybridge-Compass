# 离线 Windows SDK 包

## 项目简介

专为 CodeX 环境设计的离线 Windows SDK 包，包含完整的 Windows 开发工具链，支持离线构建 Windows 应用。

## 包内容

### 核心组件
- **Windows SDK**: 10.0.22621.0 (Windows 11 SDK)
- **C++/WinRT**: 2.0.240111.4
- **WinUI 3**: 1.5.240311000
- **Windows App SDK**: 1.5.240311000
- **MSVC 工具链**: 19.40.33806

### 网络库
- **WinHTTP**: Windows 原生 HTTP 客户端
- **WinSock2**: 高性能 Socket 通信
- **WebSocket**: 实时双向通信
- **HTTP/3**: 下一代 HTTP 协议
- **QUIC**: 快速 UDP 互联网连接

### 安全库
- **BCrypt**: Windows 加密 API
- **Cert**: 证书管理
- **TLS**: 传输层安全
- **Defender**: Windows Defender API
- **Firewall**: Windows 防火墙 API

### 性能库
- **ETW**: 事件跟踪
- **WPT**: Windows 性能工具包
- **WPA**: Windows 性能分析器
- **XPerf**: 性能分析工具

## 目录结构

```
offline-sdk/
├── README.md                    # 说明文档
├── INSTALL.md                   # 安装指南
├── BUILD.md                     # 构建指南
├── include/                     # 头文件
│   ├── windows/                 # Windows API 头文件
│   ├── winrt/                   # C++/WinRT 头文件
│   ├── winui3/                  # WinUI 3 头文件
│   └── sdk/                     # Windows SDK 头文件
├── lib/                         # 静态库
│   ├── x64/                     # 64位库
│   ├── x86/                     # 32位库
│   └── arm64/                   # ARM64库
├── bin/                         # 工具
│   ├── x64/                     # 64位工具
│   ├── x86/                     # 32位工具
│   └── arm64/                   # ARM64工具
├── redist/                      # 运行时库
│   ├── x64/                     # 64位运行时
│   ├── x86/                     # 32位运行时
│   └── arm64/                   # ARM64运行时
├── metadata/                    # 元数据
│   ├── manifests/               # 清单文件
│   ├── catalogs/                # 目录文件
│   └── signatures/              # 签名文件
└── scripts/                     # 脚本
    ├── install.sh               # 安装脚本
    ├── build.sh                 # 构建脚本
    └── test.sh                  # 测试脚本
```

## 安装方法

### 1. 自动安装
```bash
# 下载并安装
curl -fsSL https://raw.githubusercontent.com/billlza/Skybridge-Compass/main/windows-native-toolkit/offline-sdk/install.sh | bash

# 验证安装
./scripts/test.sh
```

### 2. 手动安装
```bash
# 解压包
tar -xzf windows-sdk-offline.tar.gz
cd windows-sdk-offline

# 设置环境变量
export WINDOWS_SDK_PATH=$(pwd)
export PATH=$PATH:$WINDOWS_SDK_PATH/bin/x64
export LIB=$WINDOWS_SDK_PATH/lib/x64
export INCLUDE=$WINDOWS_SDK_PATH/include

# 验证安装
./scripts/test.sh
```

### 3. Docker 安装
```bash
# 构建镜像
docker build -t windows-sdk-offline .

# 运行容器
docker run -it --rm windows-sdk-offline
```

## 使用方法

### 1. CMake 配置
```cmake
# 设置 Windows SDK 路径
set(WINDOWS_SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/offline-sdk)

# 包含头文件
include_directories(${WINDOWS_SDK_PATH}/include)

# 链接库
link_directories(${WINDOWS_SDK_PATH}/lib/x64)
target_link_libraries(${PROJECT_NAME} 
    windowsapp
    user32
    kernel32
    winhttp
    ws2_32
    bcrypt
    crypt32
)
```

### 2. 交叉编译
```bash
# 设置交叉编译器
export CC=x86_64-w64-mingw32-gcc
export CXX=x86_64-w64-mingw32-g++

# 配置 CMake
cmake -DCMAKE_SYSTEM_NAME=Windows \
      -DCMAKE_C_COMPILER=$CC \
      -DCMAKE_CXX_COMPILER=$CXX \
      -DWINDOWS_SDK_PATH=./offline-sdk \
      ..

# 构建
make -j$(nproc)
```

### 3. 静态链接
```bash
# 静态链接所有库
g++ -static-libgcc -static-libstdc++ \
    -L./offline-sdk/lib/x64 \
    -I./offline-sdk/include \
    main.cpp -o app.exe
```

## 功能特性

### 网络功能
- **ICMP 延迟采样**: 实时网络延迟监控
- **TLS 证书验证**: 安全连接验证
- **设备发现**: 自动网络设备发现
- **零信任状态**: 安全策略验证

### 安全功能
- **防火墙策略**: 自动防火墙配置
- **Defender 扫描**: 实时安全扫描
- **证书管理**: 数字证书处理
- **加密通信**: 端到端加密

### 性能功能
- **ETW 跟踪**: 事件跟踪
- **性能监控**: 实时性能统计
- **内存分析**: 内存使用分析
- **CPU 分析**: CPU 使用分析

## 构建选项

### Debug 构建
```bash
cmake -DCMAKE_BUILD_TYPE=Debug \
      -DWINDOWS_SDK_PATH=./offline-sdk \
      ..
make -j$(nproc)
```

### Release 构建
```bash
cmake -DCMAKE_BUILD_TYPE=Release \
      -DWINDOWS_SDK_PATH=./offline-sdk \
      ..
make -j$(nproc)
```

### 静态构建
```bash
cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++" \
      -DWINDOWS_SDK_PATH=./offline-sdk \
      ..
make -j$(nproc)
```

## 测试验证

### 1. 功能测试
```bash
# 运行功能测试
./scripts/test.sh

# 运行性能测试
./scripts/performance-test.sh

# 运行安全测试
./scripts/security-test.sh
```

### 2. 集成测试
```bash
# 测试网络功能
./test-network.sh

# 测试安全功能
./test-security.sh

# 测试性能功能
./test-performance.sh
```

### 3. 兼容性测试
```bash
# 测试不同 Windows 版本
./test-compatibility.sh

# 测试不同架构
./test-architecture.sh
```

## 故障排除

### 常见问题
1. **头文件未找到**: 检查 INCLUDE 环境变量
2. **库文件未找到**: 检查 LIB 环境变量
3. **工具未找到**: 检查 PATH 环境变量
4. **权限问题**: 使用管理员权限运行

### 调试技巧
- 使用 `-v` 参数查看详细输出
- 检查环境变量设置
- 验证文件路径正确性
- 查看错误日志

## 更新维护

### 版本更新
```bash
# 检查更新
./scripts/check-updates.sh

# 下载更新
./scripts/download-updates.sh

# 安装更新
./scripts/install-updates.sh
```

### 备份恢复
```bash
# 备份配置
./scripts/backup.sh

# 恢复配置
./scripts/restore.sh
```

## 技术支持

### 文档资源
- [Windows SDK 文档](https://docs.microsoft.com/windows/win32/)
- [C++/WinRT 文档](https://docs.microsoft.com/windows/uwp/cpp-and-winrt-apis/)
- [WinUI 3 文档](https://docs.microsoft.com/windows/apps/winui/winui3/)

### 社区支持
- [GitHub Issues](https://github.com/billlza/Skybridge-Compass/issues)
- [Discord 社区](https://discord.gg/skybridge)
- [Stack Overflow](https://stackoverflow.com/questions/tagged/skybridge-compass)

## 许可证

MIT License

---

**离线 Windows SDK 包** - 为 CodeX 环境提供完整的 Windows 开发支持 🚀
