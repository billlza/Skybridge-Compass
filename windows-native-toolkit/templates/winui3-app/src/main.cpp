#include <windows.h>
#include <winrt/base.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Navigation.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Web.Http.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.System.Threading.h>
#include <iostream>
#include <memory>
#include <thread>
#include <chrono>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Markup;
using namespace Windows::Foundation;
using namespace Windows::Web::Http;
using namespace Windows::Storage::Streams;
using namespace Windows::System::Threading;

// 全局变量
static std::unique_ptr<Application> g_app;
static Window g_mainWindow{ nullptr };

// 性能监控类
class PerformanceMonitor {
private:
    std::chrono::high_resolution_clock::time_point m_startTime;
    size_t m_frameCount = 0;
    double m_fps = 0.0;
    
public:
    PerformanceMonitor() : m_startTime(std::chrono::high_resolution_clock::now()) {}
    
    void Update() {
        m_frameCount++;
        auto now = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now - m_startTime);
        
        if (duration.count() >= 1000) {
            m_fps = static_cast<double>(m_frameCount) * 1000.0 / duration.count();
            m_frameCount = 0;
            m_startTime = now;
        }
    }
    
    double GetFPS() const { return m_fps; }
};

// 网络客户端类
class NetworkClient {
private:
    HttpClient m_httpClient;
    
public:
    NetworkClient() {
        // 配置 HTTP 客户端
        m_httpClient.DefaultRequestHeaders().UserAgent().ParseAdd(L"WinUI3App/1.0");
    }
    
    IAsyncOperation<hstring> GetAsync(const Uri& uri) {
        try {
            auto response = co_await m_httpClient.GetAsync(uri);
            response.EnsureSuccessStatusCode();
            auto content = co_await response.Content().ReadAsStringAsync();
            co_return content;
        }
        catch (const std::exception& e) {
            std::wcerr << L"Network error: " << e.what() << std::endl;
            co_return L"";
        }
    }
    
    IAsyncOperation<void> PostAsync(const Uri& uri, const hstring& data) {
        try {
            HttpStringContent content(data);
            content.Headers().ContentType().ParseAdd(L"application/json");
            auto response = co_await m_httpClient.PostAsync(uri, content);
            response.EnsureSuccessStatusCode();
        }
        catch (const std::exception& e) {
            std::wcerr << L"Network error: " << e.what() << std::endl;
        }
    }
};

// 主窗口类
class MainWindow {
private:
    Window m_window;
    Grid m_rootGrid;
    TextBlock m_titleText;
    Button m_networkButton;
    TextBlock m_statusText;
    ProgressBar m_progressBar;
    ListView m_dataList;
    PerformanceMonitor m_perfMonitor;
    NetworkClient m_networkClient;
    
public:
    MainWindow() {
        InitializeComponent();
        SetupEventHandlers();
        StartPerformanceMonitoring();
    }
    
    Window GetWindow() const { return m_window; }
    
private:
    void InitializeComponent() {
        // 创建主窗口
        m_window = Window();
        m_window.Title(L"高性能 WinUI 3 应用");
        m_window.ExtendsContentIntoTitleBar(true);
        
        // 创建根网格
        m_rootGrid = Grid();
        m_rootGrid.RowDefinitions().Append(RowDefinition());
        m_rootGrid.RowDefinitions().Append(RowDefinition());
        m_rootGrid.RowDefinitions().Append(RowDefinition());
        m_rootGrid.RowDefinitions().Append(RowDefinition());
        m_rootGrid.ColumnDefinitions().Append(ColumnDefinition());
        m_rootGrid.ColumnDefinitions().Append(ColumnDefinition());
        
        // 创建标题
        m_titleText = TextBlock();
        m_titleText.Text(L"🚀 高性能 WinUI 3 应用");
        m_titleText.FontSize(24);
        m_titleText.FontWeight(FontWeights::Bold());
        m_titleText.HorizontalAlignment(HorizontalAlignment::Center);
        m_titleText.Margin(Thickness(0, 20, 0, 20));
        Grid::SetRow(m_titleText, 0);
        Grid::SetColumnSpan(m_titleText, 2);
        
        // 创建网络按钮
        m_networkButton = Button();
        m_networkButton.Content(box_value(L"🌐 测试网络连接"));
        m_networkButton.FontSize(16);
        m_networkButton.Padding(Thickness(20, 10, 20, 10));
        m_networkButton.HorizontalAlignment(HorizontalAlignment::Center);
        m_networkButton.Margin(Thickness(0, 10, 0, 10));
        Grid::SetRow(m_networkButton, 1);
        Grid::SetColumn(m_networkButton, 0);
        
        // 创建状态文本
        m_statusText = TextBlock();
        m_statusText.Text(L"状态: 就绪");
        m_statusText.FontSize(14);
        m_statusText.HorizontalAlignment(HorizontalAlignment::Center);
        m_statusText.Margin(Thickness(0, 10, 0, 10));
        Grid::SetRow(m_statusText, 1);
        Grid::SetColumn(m_statusText, 1);
        
        // 创建进度条
        m_progressBar = ProgressBar();
        m_progressBar.IsIndeterminate(true);
        m_progressBar.Visibility(Visibility::Collapsed);
        m_progressBar.Margin(Thickness(0, 10, 0, 10));
        Grid::SetRow(m_progressBar, 2);
        Grid::SetColumnSpan(m_progressBar, 2);
        
        // 创建数据列表
        m_dataList = ListView();
        m_dataList.Margin(Thickness(20, 10, 20, 20));
        Grid::SetRow(m_dataList, 3);
        Grid::SetColumnSpan(m_dataList, 2);
        
        // 添加控件到网格
        m_rootGrid.Children().Append(m_titleText);
        m_rootGrid.Children().Append(m_networkButton);
        m_rootGrid.Children().Append(m_statusText);
        m_rootGrid.Children().Append(m_progressBar);
        m_rootGrid.Children().Append(m_dataList);
        
        // 设置窗口内容
        m_window.Content(m_rootGrid);
    }
    
    void SetupEventHandlers() {
        // 网络按钮点击事件
        m_networkButton.Click([this](const IInspectable&, const RoutedEventArgs&) {
            TestNetworkConnection();
        });
        
        // 窗口关闭事件
        m_window.Closed([this](const IInspectable&, const WindowEventArgs&) {
            g_app->Exit();
        });
    }
    
    void StartPerformanceMonitoring() {
        // 启动性能监控线程
        ThreadPool::RunAsync([this](const IAsyncAction&) {
            while (true) {
                m_perfMonitor.Update();
                std::this_thread::sleep_for(std::chrono::milliseconds(16)); // ~60 FPS
            }
        });
    }
    
    void TestNetworkConnection() {
        m_statusText.Text(L"状态: 连接中...");
        m_progressBar.Visibility(Visibility::Visible);
        m_networkButton.IsEnabled(false);
        
        // 异步网络测试
        ThreadPool::RunAsync([this](const IAsyncAction&) {
            try {
                Uri uri(L"https://httpbin.org/json");
                auto response = m_networkClient.GetAsync(uri).get();
                
                // 更新 UI (需要在 UI 线程上)
                m_window.Dispatcher().RunAsync(CoreDispatcherPriority::Normal, [this, response]() {
                    m_statusText.Text(L"状态: 连接成功");
                    m_progressBar.Visibility(Visibility::Collapsed);
                    m_networkButton.IsEnabled(true);
                    
                    // 显示响应数据
                    if (!response.empty()) {
                        m_dataList.Items().Append(box_value(L"✅ 网络连接成功"));
                        m_dataList.Items().Append(box_value(L"📊 响应数据: " + response));
                    }
                });
            }
            catch (const std::exception& e) {
                // 更新 UI (需要在 UI 线程上)
                m_window.Dispatcher().RunAsync(CoreDispatcherPriority::Normal, [this]() {
                    m_statusText.Text(L"状态: 连接失败");
                    m_progressBar.Visibility(Visibility::Collapsed);
                    m_networkButton.IsEnabled(true);
                    m_dataList.Items().Append(box_value(L"❌ 网络连接失败"));
                });
            }
        });
    }
};

// 应用程序类
class App : public ApplicationT<App> {
public:
    void OnLaunched(const LaunchActivatedEventArgs&) {
        // 创建主窗口
        auto mainWindow = std::make_unique<MainWindow>();
        g_mainWindow = mainWindow->GetWindow();
        g_mainWindow.Activate();
    }
};

// 程序入口点
int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow) {
    try {
        // 初始化 WinRT
        init_apartment();
        
        // 创建应用程序
        g_app = std::make_unique<Application>();
        g_app->Start({ name_of<App>(), &App::OnLaunched });
        
        return 0;
    }
    catch (const std::exception& e) {
        std::wcerr << L"Application error: " << e.what() << std::endl;
        return 1;
    }
}
