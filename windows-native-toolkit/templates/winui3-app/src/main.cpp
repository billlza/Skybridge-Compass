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
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.System.h>
#include <iostream>
#include <memory>
#include <thread>
#include <chrono>
#include <atomic>
#include <vector>
#include <string>
#include <mutex>
#include <condition_variable>
#include <queue>
#include <functional>
#include <future>
#include <algorithm>
#include <numeric>
#include <cmath>
#include <random>
#include <sstream>
#include <iomanip>
#include <fstream>
#include <map>
#include <unordered_map>
#include <set>
#include <unordered_set>
#include <array>
#include <tuple>
#include <optional>
#include <variant>
#include <any>
#include <type_traits>
#include <concepts>
#include <ranges>
#include <format>
#include <source_location>
#include <stacktrace>
#include <exception>
#include <stdexcept>
#include <system_error>
#include <filesystem>
#include <regex>
#include <locale>
#include <codecvt>
#include <memory_resource>
#include <bit>
#include <numbers>
#include <coroutine>
#include <generator>
#include <latch>
#include <barrier>
#include <semaphore>
#include <stop_token>
#include <jthread>
#include <syncstream>
#include <print>
#include <span>
#include <mdspan>
#include <expected>
#include <flat_map>
#include <flat_set>
#include <unordered_flat_map>
#include <unordered_flat_set>
#include <mdarray>
#include <text_encoding>
#include <print>
#include <format>
#include <source_location>
#include <stacktrace>
#include <exception>
#include <stdexcept>
#include <system_error>
#include <filesystem>
#include <regex>
#include <locale>
#include <codecvt>
#include <memory_resource>
#include <bit>
#include <numbers>
#include <coroutine>
#include <generator>
#include <latch>
#include <barrier>
#include <semaphore>
#include <stop_token>
#include <jthread>
#include <syncstream>
#include <print>
#include <span>
#include <mdspan>
#include <expected>
#include <flat_map>
#include <flat_set>
#include <unordered_flat_map>
#include <unordered_flat_set>
#include <mdarray>
#include <text_encoding>
#include "config.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Markup;
using namespace Windows::Foundation;
using namespace Windows::Web::Http;
using namespace Windows::Storage::Streams;
using namespace Windows::System::Threading;
using namespace Windows::Networking;
using namespace Windows::Networking::Connectivity;
using namespace Windows::Networking::Sockets;
using namespace Windows::Storage;
using namespace Windows::ApplicationModel;
using namespace Windows::System;

// 全局变量
static std::unique_ptr<Application> g_app;
static Window g_mainWindow{ nullptr };

// 性能监控类
class PerformanceMonitor {
private:
    std::chrono::high_resolution_clock::time_point m_startTime;
    std::atomic<size_t> m_frameCount{ 0 };
    std::atomic<double> m_fps{ 0.0 };
    std::atomic<double> m_cpuUsage{ 0.0 };
    std::atomic<double> m_memoryUsage{ 0.0 };
    std::atomic<double> m_networkThroughput{ 0.0 };
    std::thread m_monitoringThread;
    std::atomic<bool> m_isRunning{ false };
    
public:
    PerformanceMonitor() : m_startTime(std::chrono::high_resolution_clock::now()) {
        StartMonitoring();
    }
    
    ~PerformanceMonitor() {
        StopMonitoring();
    }
    
    void StartMonitoring() {
        m_isRunning = true;
        m_monitoringThread = std::thread([this]() {
            while (m_isRunning) {
                UpdateMetrics();
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        });
    }
    
    void StopMonitoring() {
        m_isRunning = false;
        if (m_monitoringThread.joinable()) {
            m_monitoringThread.join();
        }
    }
    
    void UpdateMetrics() {
        m_frameCount++;
        auto now = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now - m_startTime);
        
        if (duration.count() >= 1000) {
            m_fps = static_cast<double>(m_frameCount) * 1000.0 / duration.count();
            m_frameCount = 0;
            m_startTime = now;
        }
        
        // 更新 CPU 使用率
        UpdateCPUUsage();
        
        // 更新内存使用率
        UpdateMemoryUsage();
        
        // 更新网络吞吐量
        UpdateNetworkThroughput();
    }
    
    void UpdateCPUUsage() {
        // 简化的 CPU 使用率计算
        static auto lastTime = std::chrono::high_resolution_clock::now();
        static auto lastIdleTime = std::chrono::high_resolution_clock::now();
        
        auto now = std::chrono::high_resolution_clock::now();
        auto idleTime = std::chrono::high_resolution_clock::now();
        
        auto totalTime = std::chrono::duration_cast<std::chrono::microseconds>(now - lastTime).count();
        auto idleTimeDiff = std::chrono::duration_cast<std::chrono::microseconds>(idleTime - lastIdleTime).count();
        
        if (totalTime > 0) {
            double cpuUsage = 100.0 * (1.0 - static_cast<double>(idleTimeDiff) / totalTime);
            m_cpuUsage = std::clamp(cpuUsage, 0.0, 100.0);
        }
        
        lastTime = now;
        lastIdleTime = idleTime;
    }
    
    void UpdateMemoryUsage() {
        // 简化的内存使用率计算
        MEMORYSTATUSEX memInfo;
        memInfo.dwLength = sizeof(memInfo);
        if (GlobalMemoryStatusEx(&memInfo)) {
            double memoryUsage = 100.0 * (1.0 - static_cast<double>(memInfo.ullAvailPhys) / memInfo.ullTotalPhys);
            m_memoryUsage = std::clamp(memoryUsage, 0.0, 100.0);
        }
    }
    
    void UpdateNetworkThroughput() {
        // 简化的网络吞吐量计算
        static auto lastTime = std::chrono::high_resolution_clock::now();
        static uint64_t lastBytesReceived = 0;
        static uint64_t lastBytesSent = 0;
        
        auto now = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastTime);
        
        if (duration.count() >= 1000) {
            // 这里应该从实际的网络接口获取数据
            // 为了演示，使用随机数据
            std::random_device rd;
            std::mt19937 gen(rd());
            std::uniform_int_distribution<uint64_t> dis(0, 1024 * 1024);
            
            uint64_t currentBytesReceived = dis(gen);
            uint64_t currentBytesSent = dis(gen);
            
            double throughput = static_cast<double>(currentBytesReceived + currentBytesSent) / duration.count() * 1000.0;
            m_networkThroughput = throughput;
            
            lastTime = now;
            lastBytesReceived = currentBytesReceived;
            lastBytesSent = currentBytesSent;
        }
    }
    
    double GetFPS() const { return m_fps.load(); }
    double GetCPUUsage() const { return m_cpuUsage.load(); }
    double GetMemoryUsage() const { return m_memoryUsage.load(); }
    double GetNetworkThroughput() const { return m_networkThroughput.load(); }
};

// 网络管理器类
class NetworkManager {
private:
    HttpClient m_httpClient;
    std::atomic<bool> m_isInitialized{ false };
    std::thread m_networkThread;
    std::atomic<bool> m_isRunning{ false };
    std::queue<std::function<void()>> m_requestQueue;
    std::mutex m_queueMutex;
    std::condition_variable m_queueCondition;
    
public:
    NetworkManager() {
        Initialize();
    }
    
    ~NetworkManager() {
        Shutdown();
    }
    
    void Initialize() {
        if (m_isInitialized) {
            return;
        }
        
        try {
            // 配置 HTTP 客户端
            m_httpClient.DefaultRequestHeaders().UserAgent().ParseAdd(L"SkybridgeCompassApp/1.0");
            
            // 启动网络线程
            m_isRunning = true;
            m_networkThread = std::thread([this]() {
                while (m_isRunning) {
                    std::function<void()> request;
                    
                    {
                        std::unique_lock<std::mutex> lock(m_queueMutex);
                        m_queueCondition.wait(lock, [this]() {
                            return !m_requestQueue.empty() || !m_isRunning;
                        });
                        
                        if (!m_isRunning) {
                            break;
                        }
                        
                        if (!m_requestQueue.empty()) {
                            request = m_requestQueue.front();
                            m_requestQueue.pop();
                        }
                    }
                    
                    if (request) {
                        request();
                    }
                }
            });
            
            m_isInitialized = true;
        }
        catch (const std::exception& e) {
            std::wcerr << L"NetworkManager initialization failed: " << e.what() << std::endl;
        }
    }
    
    void Shutdown() {
        m_isRunning = false;
        m_queueCondition.notify_all();
        
        if (m_networkThread.joinable()) {
            m_networkThread.join();
        }
        
        m_isInitialized = false;
    }
    
    IAsyncOperation<hstring> GetAsync(const Uri& uri) {
        if (!m_isInitialized) {
            co_return L"";
        }
        
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
    
    void PostRequestAsync(const Uri& uri, const hstring& data, std::function<void(bool, const hstring&)> callback) {
        if (!m_isInitialized) {
            if (callback) {
                callback(false, L"NetworkManager not initialized");
            }
            return;
        }
        
        {
            std::lock_guard<std::mutex> lock(m_queueMutex);
            m_requestQueue.push([this, uri, data, callback]() {
                try {
                    HttpStringContent content(data);
                    content.Headers().ContentType().ParseAdd(L"application/json");
                    auto response = m_httpClient.PostAsync(uri, content).get();
                    response.EnsureSuccessStatusCode();
                    
                    if (callback) {
                        callback(true, L"Success");
                    }
                }
                catch (const std::exception& e) {
                    if (callback) {
                        callback(false, std::wstring(e.what(), e.what() + strlen(e.what())));
                    }
                }
            });
        }
        m_queueCondition.notify_one();
    }
};

// 遥测管理器类
class TelemetryManager {
private:
    std::atomic<bool> m_isEnabled{ true };
    std::vector<std::pair<std::chrono::high_resolution_clock::time_point, double>> m_cpuHistory;
    std::vector<std::pair<std::chrono::high_resolution_clock::time_point, double>> m_memoryHistory;
    std::vector<std::pair<std::chrono::high_resolution_clock::time_point, double>> m_networkHistory;
    std::mutex m_historyMutex;
    std::thread m_collectionThread;
    std::atomic<bool> m_isRunning{ false };
    
public:
    TelemetryManager() {
        StartCollection();
    }
    
    ~TelemetryManager() {
        StopCollection();
    }
    
    void StartCollection() {
        m_isRunning = true;
        m_collectionThread = std::thread([this]() {
            while (m_isRunning) {
                if (m_isEnabled) {
                    CollectMetrics();
                }
                std::this_thread::sleep_for(std::chrono::seconds(1));
            }
        });
    }
    
    void StopCollection() {
        m_isRunning = false;
        if (m_collectionThread.joinable()) {
            m_collectionThread.join();
        }
    }
    
    void CollectMetrics() {
        auto now = std::chrono::high_resolution_clock::now();
        
        // 收集 CPU 指标
        double cpuUsage = GetCurrentCPUUsage();
        {
            std::lock_guard<std::mutex> lock(m_historyMutex);
            m_cpuHistory.push_back({now, cpuUsage});
            if (m_cpuHistory.size() > 100) {
                m_cpuHistory.erase(m_cpuHistory.begin());
            }
        }
        
        // 收集内存指标
        double memoryUsage = GetCurrentMemoryUsage();
        {
            std::lock_guard<std::mutex> lock(m_historyMutex);
            m_memoryHistory.push_back({now, memoryUsage});
            if (m_memoryHistory.size() > 100) {
                m_memoryHistory.erase(m_memoryHistory.begin());
            }
        }
        
        // 收集网络指标
        double networkThroughput = GetCurrentNetworkThroughput();
        {
            std::lock_guard<std::mutex> lock(m_historyMutex);
            m_networkHistory.push_back({now, networkThroughput});
            if (m_networkHistory.size() > 100) {
                m_networkHistory.erase(m_networkHistory.begin());
            }
        }
    }
    
    double GetCurrentCPUUsage() {
        // 简化的 CPU 使用率计算
        static auto lastTime = std::chrono::high_resolution_clock::now();
        static auto lastIdleTime = std::chrono::high_resolution_clock::now();
        
        auto now = std::chrono::high_resolution_clock::now();
        auto idleTime = std::chrono::high_resolution_clock::now();
        
        auto totalTime = std::chrono::duration_cast<std::chrono::microseconds>(now - lastTime).count();
        auto idleTimeDiff = std::chrono::duration_cast<std::chrono::microseconds>(idleTime - lastIdleTime).count();
        
        if (totalTime > 0) {
            double cpuUsage = 100.0 * (1.0 - static_cast<double>(idleTimeDiff) / totalTime);
            lastTime = now;
            lastIdleTime = idleTime;
            return std::clamp(cpuUsage, 0.0, 100.0);
        }
        
        return 0.0;
    }
    
    double GetCurrentMemoryUsage() {
        MEMORYSTATUSEX memInfo;
        memInfo.dwLength = sizeof(memInfo);
        if (GlobalMemoryStatusEx(&memInfo)) {
            return 100.0 * (1.0 - static_cast<double>(memInfo.ullAvailPhys) / memInfo.ullTotalPhys);
        }
        return 0.0;
    }
    
    double GetCurrentNetworkThroughput() {
        // 简化的网络吞吐量计算
        static auto lastTime = std::chrono::high_resolution_clock::now();
        static uint64_t lastBytes = 0;
        
        auto now = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastTime);
        
        if (duration.count() >= 1000) {
            std::random_device rd;
            std::mt19937 gen(rd());
            std::uniform_int_distribution<uint64_t> dis(0, 1024 * 1024);
            
            uint64_t currentBytes = dis(gen);
            double throughput = static_cast<double>(currentBytes) / duration.count() * 1000.0;
            
            lastTime = now;
            lastBytes = currentBytes;
            return throughput;
        }
        
        return 0.0;
    }
    
    std::vector<double> GetCPUHistory() const {
        std::lock_guard<std::mutex> lock(m_historyMutex);
        std::vector<double> result;
        result.reserve(m_cpuHistory.size());
        for (const auto& entry : m_cpuHistory) {
            result.push_back(entry.second);
        }
        return result;
    }
    
    std::vector<double> GetMemoryHistory() const {
        std::lock_guard<std::mutex> lock(m_historyMutex);
        std::vector<double> result;
        result.reserve(m_memoryHistory.size());
        for (const auto& entry : m_memoryHistory) {
            result.push_back(entry.second);
        }
        return result;
    }
    
    std::vector<double> GetNetworkHistory() const {
        std::lock_guard<std::mutex> lock(m_historyMutex);
        std::vector<double> result;
        result.reserve(m_networkHistory.size());
        for (const auto& entry : m_networkHistory) {
            result.push_back(entry.second);
        }
        return result;
    }
    
    void SetEnabled(bool enabled) {
        m_isEnabled = enabled;
    }
    
    bool IsEnabled() const {
        return m_isEnabled.load();
    }
};

// 设备发现类
class DeviceDiscovery {
private:
    std::atomic<bool> m_isScanning{ false };
    std::vector<std::wstring> m_discoveredDevices;
    std::mutex m_devicesMutex;
    std::thread m_scanThread;
    
public:
    DeviceDiscovery() = default;
    
    ~DeviceDiscovery() {
        StopScanning();
    }
    
    void StartScanning() {
        if (m_isScanning) {
            return;
        }
        
        m_isScanning = true;
        m_scanThread = std::thread([this]() {
            while (m_isScanning) {
                ScanForDevices();
                std::this_thread::sleep_for(std::chrono::seconds(5));
            }
        });
    }
    
    void StopScanning() {
        m_isScanning = false;
        if (m_scanThread.joinable()) {
            m_scanThread.join();
        }
    }
    
    void ScanForDevices() {
        // 简化的设备发现逻辑
        std::vector<std::wstring> newDevices;
        
        // 模拟发现设备
        std::random_device rd;
        std::mt19937 gen(rd());
        std::uniform_int_distribution<int> dis(1, 5);
        
        int deviceCount = dis(gen);
        for (int i = 0; i < deviceCount; ++i) {
            std::wstringstream ss;
            ss << L"Device_" << i << L"_" << std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::high_resolution_clock::now().time_since_epoch()).count();
            newDevices.push_back(ss.str());
        }
        
        {
            std::lock_guard<std::mutex> lock(m_devicesMutex);
            m_discoveredDevices = std::move(newDevices);
        }
    }
    
    std::vector<std::wstring> GetDiscoveredDevices() const {
        std::lock_guard<std::mutex> lock(m_devicesMutex);
        return m_discoveredDevices;
    }
    
    bool IsScanning() const {
        return m_isScanning.load();
    }
};

// 远程桌面类
class RemoteDesktop {
private:
    std::atomic<bool> m_isConnected{ false };
    std::wstring m_connectedDevice;
    
public:
    RemoteDesktop() = default;
    
    bool ConnectToDevice(const std::wstring& deviceName) {
        if (m_isConnected) {
            return false;
        }
        
        // 简化的连接逻辑
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        
        m_connectedDevice = deviceName;
        m_isConnected = true;
        
        return true;
    }
    
    void Disconnect() {
        m_isConnected = false;
        m_connectedDevice.clear();
    }
    
    bool IsConnected() const {
        return m_isConnected.load();
    }
    
    std::wstring GetConnectedDevice() const {
        return m_connectedDevice;
    }
};

// ETW 跟踪助手类
class ETWTraceHelper {
private:
    std::atomic<bool> m_isTracing{ false };
    std::thread m_traceThread;
    
public:
    ETWTraceHelper() = default;
    
    ~ETWTraceHelper() {
        StopTracing();
    }
    
    void StartTracing() {
        if (m_isTracing) {
            return;
        }
        
        m_isTracing = true;
        m_traceThread = std::thread([this]() {
            while (m_isTracing) {
                // 简化的 ETW 跟踪逻辑
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        });
    }
    
    void StopTracing() {
        m_isTracing = false;
        if (m_traceThread.joinable()) {
            m_traceThread.join();
        }
    }
    
    bool IsTracing() const {
        return m_isTracing.load();
    }
};

// 主窗口类
class MainWindow {
private:
    Window m_window;
    Grid m_rootGrid;
    TextBlock m_titleText;
    Button m_networkButton;
    Button m_deviceButton;
    Button m_remoteButton;
    TextBlock m_statusText;
    ProgressBar m_progressBar;
    ListView m_dataList;
    ListView m_deviceList;
    TextBlock m_performanceText;
    
    // 管理器实例
    std::unique_ptr<PerformanceMonitor> m_perfMonitor;
    std::unique_ptr<NetworkManager> m_networkManager;
    std::unique_ptr<TelemetryManager> m_telemetryManager;
    std::unique_ptr<DeviceDiscovery> m_deviceDiscovery;
    std::unique_ptr<RemoteDesktop> m_remoteDesktop;
    std::unique_ptr<ETWTraceHelper> m_etwHelper;
    
    // 性能更新线程
    std::thread m_performanceUpdateThread;
    std::atomic<bool> m_isRunning{ false };
    
public:
    MainWindow() {
        InitializeManagers();
        InitializeComponent();
        SetupEventHandlers();
        StartPerformanceUpdates();
    }
    
    ~MainWindow() {
        StopPerformanceUpdates();
    }
    
    Window GetWindow() const { return m_window; }
    
private:
    void InitializeManagers() {
        m_perfMonitor = std::make_unique<PerformanceMonitor>();
        m_networkManager = std::make_unique<NetworkManager>();
        m_telemetryManager = std::make_unique<TelemetryManager>();
        m_deviceDiscovery = std::make_unique<DeviceDiscovery>();
        m_remoteDesktop = std::make_unique<RemoteDesktop>();
        m_etwHelper = std::make_unique<ETWTraceHelper>();
    }
    
    void InitializeComponent() {
        // 创建主窗口
        m_window = Window();
        m_window.Title(L"🚀 Skybridge Compass - 高性能 Windows 应用");
        m_window.ExtendsContentIntoTitleBar(true);
        
        // 创建根网格
        m_rootGrid = Grid();
        m_rootGrid.RowDefinitions().Append(RowDefinition());
        m_rootGrid.RowDefinitions().Append(RowDefinition());
        m_rootGrid.RowDefinitions().Append(RowDefinition());
        m_rootGrid.RowDefinitions().Append(RowDefinition());
        m_rootGrid.RowDefinitions().Append(RowDefinition());
        m_rootGrid.ColumnDefinitions().Append(ColumnDefinition());
        m_rootGrid.ColumnDefinitions().Append(ColumnDefinition());
        
        // 创建标题
        m_titleText = TextBlock();
        m_titleText.Text(L"🚀 Skybridge Compass - 高性能 Windows 应用");
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
        
        // 创建设备按钮
        m_deviceButton = Button();
        m_deviceButton.Content(box_value(L"🔍 扫描设备"));
        m_deviceButton.FontSize(16);
        m_deviceButton.Padding(Thickness(20, 10, 20, 10));
        m_deviceButton.HorizontalAlignment(HorizontalAlignment::Center);
        m_deviceButton.Margin(Thickness(0, 10, 0, 10));
        Grid::SetRow(m_deviceButton, 1);
        Grid::SetColumn(m_deviceButton, 1);
        
        // 创建远程按钮
        m_remoteButton = Button();
        m_remoteButton.Content(box_value(L"🖥️ 远程桌面"));
        m_remoteButton.FontSize(16);
        m_remoteButton.Padding(Thickness(20, 10, 20, 10));
        m_remoteButton.HorizontalAlignment(HorizontalAlignment::Center);
        m_remoteButton.Margin(Thickness(0, 10, 0, 10));
        Grid::SetRow(m_remoteButton, 2);
        Grid::SetColumn(m_remoteButton, 0);
        
        // 创建状态文本
        m_statusText = TextBlock();
        m_statusText.Text(L"状态: 就绪");
        m_statusText.FontSize(14);
        m_statusText.HorizontalAlignment(HorizontalAlignment::Center);
        m_statusText.Margin(Thickness(0, 10, 0, 10));
        Grid::SetRow(m_statusText, 2);
        Grid::SetColumn(m_statusText, 1);
        
        // 创建进度条
        m_progressBar = ProgressBar();
        m_progressBar.IsIndeterminate(true);
        m_progressBar.Visibility(Visibility::Collapsed);
        m_progressBar.Margin(Thickness(0, 10, 0, 10));
        Grid::SetRow(m_progressBar, 3);
        Grid::SetColumnSpan(m_progressBar, 2);
        
        // 创建数据列表
        m_dataList = ListView();
        m_dataList.Margin(Thickness(20, 10, 20, 20));
        Grid::SetRow(m_dataList, 4);
        Grid::SetColumn(m_dataList, 0);
        
        // 创建设备列表
        m_deviceList = ListView();
        m_deviceList.Margin(Thickness(20, 10, 20, 20));
        Grid::SetRow(m_deviceList, 4);
        Grid::SetColumn(m_deviceList, 1);
        
        // 创建性能文本
        m_performanceText = TextBlock();
        m_performanceText.Text(L"性能监控: 启动中...");
        m_performanceText.FontSize(12);
        m_performanceText.HorizontalAlignment(HorizontalAlignment::Center);
        m_performanceText.Margin(Thickness(0, 10, 0, 10));
        Grid::SetRow(m_performanceText, 5);
        Grid::SetColumnSpan(m_performanceText, 2);
        
        // 添加控件到网格
        m_rootGrid.Children().Append(m_titleText);
        m_rootGrid.Children().Append(m_networkButton);
        m_rootGrid.Children().Append(m_deviceButton);
        m_rootGrid.Children().Append(m_remoteButton);
        m_rootGrid.Children().Append(m_statusText);
        m_rootGrid.Children().Append(m_progressBar);
        m_rootGrid.Children().Append(m_dataList);
        m_rootGrid.Children().Append(m_deviceList);
        m_rootGrid.Children().Append(m_performanceText);
        
        // 设置窗口内容
        m_window.Content(m_rootGrid);
    }
    
    void SetupEventHandlers() {
        // 网络按钮点击事件
        m_networkButton.Click([this](const IInspectable&, const RoutedEventArgs&) {
            TestNetworkConnection();
        });
        
        // 设备按钮点击事件
        m_deviceButton.Click([this](const IInspectable&, const RoutedEventArgs&) {
            ScanForDevices();
        });
        
        // 远程按钮点击事件
        m_remoteButton.Click([this](const IInspectable&, const RoutedEventArgs&) {
            ToggleRemoteDesktop();
        });
        
        // 窗口关闭事件
        m_window.Closed([this](const IInspectable&, const WindowEventArgs&) {
            g_app->Exit();
        });
    }
    
    void StartPerformanceUpdates() {
        m_isRunning = true;
        m_performanceUpdateThread = std::thread([this]() {
            while (m_isRunning) {
                UpdatePerformanceDisplay();
                std::this_thread::sleep_for(std::chrono::milliseconds(500));
            }
        });
    }
    
    void StopPerformanceUpdates() {
        m_isRunning = false;
        if (m_performanceUpdateThread.joinable()) {
            m_performanceUpdateThread.join();
        }
    }
    
    void UpdatePerformanceDisplay() {
        if (!m_perfMonitor) {
            return;
        }
        
        double fps = m_perfMonitor->GetFPS();
        double cpuUsage = m_perfMonitor->GetCPUUsage();
        double memoryUsage = m_perfMonitor->GetMemoryUsage();
        double networkThroughput = m_perfMonitor->GetNetworkThroughput();
        
        std::wstringstream ss;
        ss << L"性能监控 - FPS: " << std::fixed << std::setprecision(1) << fps
           << L" | CPU: " << cpuUsage << L"%"
           << L" | 内存: " << memoryUsage << L"%"
           << L" | 网络: " << networkThroughput / 1024.0 << L" KB/s";
        
        // 更新 UI (需要在 UI 线程上)
        m_window.Dispatcher().RunAsync(CoreDispatcherPriority::Normal, [this, ss]() {
            m_performanceText.Text(ss.str());
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
                auto response = m_networkManager->GetAsync(uri).get();
                
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
    
    void ScanForDevices() {
        m_statusText.Text(L"状态: 扫描设备中...");
        m_progressBar.Visibility(Visibility::Visible);
        m_deviceButton.IsEnabled(false);
        
        // 启动设备扫描
        m_deviceDiscovery->StartScanning();
        
        // 更新设备列表
        ThreadPool::RunAsync([this](const IAsyncAction&) {
            std::this_thread::sleep_for(std::chrono::seconds(2));
            
            auto devices = m_deviceDiscovery->GetDiscoveredDevices();
            
            // 更新 UI (需要在 UI 线程上)
            m_window.Dispatcher().RunAsync(CoreDispatcherPriority::Normal, [this, devices]() {
                m_statusText.Text(L"状态: 扫描完成");
                m_progressBar.Visibility(Visibility::Collapsed);
                m_deviceButton.IsEnabled(true);
                
                // 清空设备列表
                m_deviceList.Items().Clear();
                
                // 添加发现的设备
                for (const auto& device : devices) {
                    m_deviceList.Items().Append(box_value(L"🔍 " + device));
                }
                
                if (devices.empty()) {
                    m_deviceList.Items().Append(box_value(L"❌ 未发现设备"));
                }
            });
        });
    }
    
    void ToggleRemoteDesktop() {
        if (m_remoteDesktop->IsConnected()) {
            m_remoteDesktop->Disconnect();
            m_statusText.Text(L"状态: 远程桌面已断开");
            m_remoteButton.Content(box_value(L"🖥️ 远程桌面"));
        } else {
            auto devices = m_deviceDiscovery->GetDiscoveredDevices();
            if (!devices.empty()) {
                if (m_remoteDesktop->ConnectToDevice(devices[0])) {
                    m_statusText.Text(L"状态: 远程桌面已连接");
                    m_remoteButton.Content(box_value(L"🔌 断开连接"));
                } else {
                    m_statusText.Text(L"状态: 连接失败");
                }
            } else {
                m_statusText.Text(L"状态: 无可用设备");
            }
        }
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
