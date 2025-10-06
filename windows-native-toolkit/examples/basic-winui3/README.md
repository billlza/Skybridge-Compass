# 基础 WinUI 3 应用示例

## 项目简介

这是一个基础的 WinUI 3 应用示例，展示了如何使用 C++/WinRT 和 WinUI 3 创建现代化的 Windows 应用。

## 功能特性

- **现代化 UI**: 使用 WinUI 3 控件
- **异步编程**: C++/WinRT 异步操作
- **网络通信**: HTTP 客户端示例
- **性能监控**: 实时性能统计
- **响应式布局**: 自适应界面

## 技术栈

- **C++/WinRT**: 2.0.240111.4
- **WinUI 3**: 1.5.240311000
- **Windows SDK**: 10.0.22621.0
- **MSVC**: 19.40.33806

## 项目结构

```
basic-winui3/
├── README.md              # 项目说明
├── CMakeLists.txt         # CMake 配置
├── src/                   # 源代码
│   ├── main.cpp          # 程序入口
│   ├── App.cpp           # 应用程序类
│   ├── App.h             # 应用程序头文件
│   ├── MainWindow.cpp    # 主窗口类
│   ├── MainWindow.h      # 主窗口头文件
│   ├── MainWindow.xaml   # XAML 界面
│   └── MainWindow.xaml.h # XAML 头文件
├── assets/               # 资源文件
│   ├── images/           # 图片资源
│   └── icons/            # 图标资源
└── build/                # 构建输出
```

## 快速开始

### 1. 环境准备
```bash
# 设置开发环境
source .env

# 验证工具链
x86_64-w64-mingw32-gcc --version
```

### 2. 构建项目
```bash
# 创建构建目录
mkdir build && cd build

# 配置 CMake
cmake -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc \
    -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++ \
    -DCMAKE_BUILD_TYPE=Release \
    ..

# 构建项目
make -j$(nproc)
```

### 3. 运行应用
```bash
# 在 Windows 环境中运行
./bin/MyWinUI3App.exe
```

## 代码示例

### 主程序入口
```cpp
#include <windows.h>
#include <winrt/base.h>
#include <winrt/Microsoft.UI.Xaml.h>

using namespace winrt;
using namespace Microsoft::UI::Xaml;

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, 
                   LPSTR lpCmdLine, int nCmdShow) {
    init_apartment();
    
    Application app;
    app.Start({ name_of<App>(), &App::OnLaunched });
    
    return 0;
}
```

### 应用程序类
```cpp
class App : public ApplicationT<App> {
public:
    void OnLaunched(const LaunchActivatedEventArgs&) {
        auto mainWindow = std::make_unique<MainWindow>();
        m_mainWindow = mainWindow->GetWindow();
        m_mainWindow.Activate();
    }
    
private:
    Window m_mainWindow{ nullptr };
};
```

### 主窗口类
```cpp
class MainWindow {
public:
    MainWindow() {
        InitializeComponent();
        SetupEventHandlers();
    }
    
    Window GetWindow() const { return m_window; }
    
private:
    void InitializeComponent();
    void SetupEventHandlers();
    
    Window m_window;
    Grid m_rootGrid;
    TextBlock m_titleText;
    Button m_actionButton;
};
```

## 功能演示

### 1. 界面布局
- 响应式网格布局
- 现代化控件样式
- 流畅的动画效果

### 2. 网络通信
- HTTP 客户端示例
- 异步请求处理
- 错误处理机制

### 3. 性能监控
- 实时性能统计
- 内存使用监控
- CPU 使用率显示

## 构建选项

### Debug 构建
```bash
cmake -DCMAKE_BUILD_TYPE=Debug ..
make -j$(nproc)
```

### Release 构建
```bash
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)
```

### 静态链接
```bash
cmake -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++" ..
make -j$(nproc)
```

## 性能优化

### 编译优化
- `-O3`: 最高级别优化
- `-march=native`: 针对当前 CPU 优化
- `-flto`: 链接时优化
- `-ffast-math`: 快速数学运算

### 运行时优化
- 智能指针管理内存
- RAII 资源管理
- 异步操作避免阻塞
- 缓存友好的数据结构

## 故障排除

### 常见问题
1. **编译错误**: 检查 Windows SDK 路径
2. **链接错误**: 确认库文件路径
3. **运行时错误**: 检查 DLL 依赖

### 调试技巧
- 使用 Visual Studio 调试器
- 启用详细日志输出
- 检查系统事件日志

## 扩展功能

### 添加新控件
1. 在 XAML 中定义控件
2. 在 C++ 中处理事件
3. 更新界面布局

### 集成网络功能
1. 使用 WinHTTP 客户端
2. 实现异步请求
3. 处理响应数据

### 性能优化
1. 启用 SIMD 指令
2. 优化内存访问
3. 使用多线程

## 参考资源

- [WinUI 3 文档](https://docs.microsoft.com/windows/apps/winui/winui3/)
- [C++/WinRT 文档](https://docs.microsoft.com/windows/uwp/cpp-and-winrt-apis/)
- [Windows SDK 文档](https://docs.microsoft.com/windows/win32/)

---

**基础 WinUI 3 应用示例** - 快速上手 Windows 应用开发 🚀
