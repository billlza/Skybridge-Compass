#pragma once
#include <windows.h>
#include <winhttp.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Web.Http.h>
#include <winrt/Windows.Storage.Streams.h>
#include <string>
#include <vector>
#include <memory>
#include <functional>
#include <atomic>
#include <thread>
#include <queue>
#include <mutex>
#include <condition_variable>
#include <chrono>

using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Web::Http;
using namespace Windows::Storage::Streams;

namespace Network {
    // HTTP 方法枚举
    enum class HttpMethod {
        GET,
        POST,
        PUT,
        DELETE,
        PATCH,
        HEAD,
        OPTIONS
    };

    // HTTP 状态码
    enum class HttpStatusCode {
        OK = 200,
        Created = 201,
        Accepted = 202,
        NoContent = 204,
        BadRequest = 400,
        Unauthorized = 401,
        Forbidden = 403,
        NotFound = 404,
        InternalServerError = 500,
        BadGateway = 502,
        ServiceUnavailable = 503
    };

    // HTTP 请求配置
    struct HttpRequestConfig {
        std::wstring url;
        HttpMethod method = HttpMethod::GET;
        std::wstring userAgent = L"WinUI3App/1.0";
        std::wstring contentType = L"application/json";
        std::wstring body;
        std::vector<std::pair<std::wstring, std::wstring>> headers;
        std::chrono::milliseconds timeout = std::chrono::milliseconds(30000);
        bool enableCompression = true;
        bool enableKeepAlive = true;
        int maxRedirects = 5;
    };

    // HTTP 响应
    struct HttpResponse {
        HttpStatusCode statusCode;
        std::wstring statusText;
        std::wstring body;
        std::vector<std::pair<std::wstring, std::wstring>> headers;
        std::chrono::milliseconds responseTime;
        size_t contentLength = 0;
        bool success = false;
    };

    // 异步回调类型
    using HttpCallback = std::function<void(const HttpResponse&)>;
    using ErrorCallback = std::function<void(const std::wstring&)>;

    // 高性能 HTTP 客户端
    class WinHttpClient {
    private:
        HINTERNET m_hSession;
        HINTERNET m_hConnect;
        std::atomic<bool> m_isInitialized{ false };
        std::atomic<bool> m_isShuttingDown{ false };
        
        // 连接池
        struct ConnectionPool {
            std::queue<HINTERNET> connections;
            std::mutex mutex;
            std::condition_variable condition;
            size_t maxConnections = 10;
            size_t currentConnections = 0;
        };
        
        std::unique_ptr<ConnectionPool> m_connectionPool;
        
        // 请求队列
        struct RequestQueue {
            std::queue<std::function<void()>> requests;
            std::mutex mutex;
            std::condition_variable condition;
            std::atomic<bool> isRunning{ false };
        };
        
        std::unique_ptr<RequestQueue> m_requestQueue;
        std::vector<std::thread> m_workerThreads;
        
        // 性能统计
        struct PerformanceStats {
            std::atomic<uint64_t> totalRequests{ 0 };
            std::atomic<uint64_t> successfulRequests{ 0 };
            std::atomic<uint64_t> failedRequests{ 0 };
            std::atomic<uint64_t> totalBytes{ 0 };
            std::atomic<double> averageResponseTime{ 0.0 };
            std::chrono::high_resolution_clock::time_point startTime;
        };
        
        std::unique_ptr<PerformanceStats> m_stats;

    public:
        WinHttpClient();
        ~WinHttpClient();
        
        // 初始化和清理
        bool Initialize();
        void Shutdown();
        
        // 同步请求
        HttpResponse SendRequest(const HttpRequestConfig& config);
        
        // 异步请求
        void SendRequestAsync(const HttpRequestConfig& config, 
                            HttpCallback onSuccess, 
                            ErrorCallback onError = nullptr);
        
        // 批量请求
        void SendBatchRequests(const std::vector<HttpRequestConfig>& configs,
                             std::function<void(const std::vector<HttpResponse>&)> onComplete);
        
        // 流式请求
        void SendStreamRequest(const HttpRequestConfig& config,
                             std::function<void(const std::vector<uint8_t>&)> onData,
                             std::function<void()> onComplete,
                             ErrorCallback onError = nullptr);
        
        // 性能监控
        struct PerformanceMetrics {
            uint64_t totalRequests;
            uint64_t successfulRequests;
            uint64_t failedRequests;
            uint64_t totalBytes;
            double averageResponseTime;
            double requestsPerSecond;
            double successRate;
        };
        
        PerformanceMetrics GetPerformanceMetrics() const;
        void ResetPerformanceMetrics();
        
        // 配置选项
        void SetConnectionTimeout(std::chrono::milliseconds timeout);
        void SetMaxConnections(size_t maxConnections);
        void SetUserAgent(const std::wstring& userAgent);
        void EnableCompression(bool enable);
        void EnableKeepAlive(bool enable);
        
        // 工具方法
        static std::wstring HttpMethodToString(HttpMethod method);
        static HttpMethod StringToHttpMethod(const std::wstring& method);
        static std::wstring HttpStatusCodeToString(HttpStatusCode statusCode);
        static bool IsSuccessStatusCode(HttpStatusCode statusCode);

    private:
        // 内部方法
        HINTERNET GetConnection(const std::wstring& host, INTERNET_PORT port);
        void ReturnConnection(HINTERNET hConnect);
        HttpResponse ProcessRequest(HINTERNET hRequest, const HttpRequestConfig& config);
        void WorkerThreadFunction();
        void UpdatePerformanceStats(const HttpResponse& response, std::chrono::milliseconds responseTime);
        
        // 错误处理
        std::wstring GetLastErrorString() const;
        void LogError(const std::wstring& message) const;
        
        // 压缩支持
        std::vector<uint8_t> CompressData(const std::vector<uint8_t>& data) const;
        std::vector<uint8_t> DecompressData(const std::vector<uint8_t>& compressedData) const;
        
        // 缓存支持
        struct CacheEntry {
            std::wstring key;
            HttpResponse response;
            std::chrono::high_resolution_clock::time_point timestamp;
            std::chrono::milliseconds ttl;
        };
        
        std::unordered_map<std::wstring, CacheEntry> m_cache;
        std::mutex m_cacheMutex;
        std::chrono::milliseconds m_defaultCacheTTL = std::chrono::minutes(5);
        
        bool GetCachedResponse(const std::wstring& key, HttpResponse& response) const;
        void SetCachedResponse(const std::wstring& key, const HttpResponse& response);
        void CleanupExpiredCache();
        
        // 重试机制
        struct RetryConfig {
            int maxRetries = 3;
            std::chrono::milliseconds initialDelay = std::chrono::milliseconds(1000);
            double backoffMultiplier = 2.0;
            std::vector<HttpStatusCode> retryableStatusCodes = {
                HttpStatusCode::InternalServerError,
                HttpStatusCode::BadGateway,
                HttpStatusCode::ServiceUnavailable
            };
        };
        
        RetryConfig m_retryConfig;
        HttpResponse SendRequestWithRetry(const HttpRequestConfig& config);
    };

    // WebSocket 客户端
    class WebSocketClient {
    private:
        HINTERNET m_hSession;
        HINTERNET m_hConnect;
        HINTERNET m_hRequest;
        std::atomic<bool> m_isConnected{ false };
        std::atomic<bool> m_isShuttingDown{ false };
        
        std::thread m_receiveThread;
        std::mutex m_sendMutex;
        
        // 事件回调
        std::function<void()> m_onOpen;
        std::function<void(const std::wstring&)> m_onMessage;
        std::function<void()> m_onClose;
        std::function<void(const std::wstring&)> m_onError;

    public:
        WebSocketClient();
        ~WebSocketClient();
        
        // 连接管理
        bool Connect(const std::wstring& url);
        void Disconnect();
        bool IsConnected() const { return m_isConnected; }
        
        // 消息发送
        bool SendMessage(const std::wstring& message);
        bool SendBinaryMessage(const std::vector<uint8_t>& data);
        
        // 事件处理
        void SetOnOpen(std::function<void()> callback) { m_onOpen = callback; }
        void SetOnMessage(std::function<void(const std::wstring&)> callback) { m_onMessage = callback; }
        void SetOnClose(std::function<void()> callback) { m_onClose = callback; }
        void SetOnError(std::function<void(const std::wstring&)> callback) { m_onError = callback; }
        
        // 状态查询
        std::wstring GetConnectionState() const;
        size_t GetQueuedMessageCount() const;

    private:
        void ReceiveThreadFunction();
        bool PerformHandshake(const std::wstring& url);
        std::vector<uint8_t> CreateWebSocketFrame(const std::vector<uint8_t>& data, bool isBinary = false);
        std::vector<uint8_t> ParseWebSocketFrame(const std::vector<uint8_t>& frame);
    };

    // HTTP/3 客户端 (实验性)
    class Http3Client {
    private:
        // HTTP/3 实现 (需要 Windows 11 和最新 WinHTTP)
        std::atomic<bool> m_isInitialized{ false };
        
    public:
        Http3Client();
        ~Http3Client();
        
        bool Initialize();
        void Shutdown();
        
        HttpResponse SendRequest(const HttpRequestConfig& config);
        void SendRequestAsync(const HttpRequestConfig& config, 
                            HttpCallback onSuccess, 
                            ErrorCallback onError = nullptr);
        
        bool IsSupported() const;
    };

    // 网络工具类
    class NetworkUtils {
    public:
        // URL 处理
        static std::wstring EncodeUrl(const std::wstring& url);
        static std::wstring DecodeUrl(const std::wstring& encodedUrl);
        static bool IsValidUrl(const std::wstring& url);
        
        // 域名解析
        static std::vector<std::wstring> ResolveHostname(const std::wstring& hostname);
        static std::wstring GetLocalIPAddress();
        
        // 网络检测
        static bool IsNetworkAvailable();
        static bool IsInternetAvailable();
        static std::chrono::milliseconds PingHost(const std::wstring& hostname);
        
        // 数据转换
        static std::vector<uint8_t> StringToBytes(const std::wstring& str);
        static std::wstring BytesToString(const std::vector<uint8_t>& bytes);
        static std::wstring Base64Encode(const std::vector<uint8_t>& data);
        static std::vector<uint8_t> Base64Decode(const std::wstring& encoded);
    };
}
