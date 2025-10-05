#include "winhttp_client.h"
#include <iostream>
#include <sstream>
#include <iomanip>
#include <algorithm>
#include <regex>

namespace Network {

// WinHttpClient 实现
WinHttpClient::WinHttpClient() 
    : m_hSession(nullptr)
    , m_hConnect(nullptr)
    , m_connectionPool(std::make_unique<ConnectionPool>())
    , m_requestQueue(std::make_unique<RequestQueue>())
    , m_stats(std::make_unique<PerformanceStats>()) {
    m_stats->startTime = std::chrono::high_resolution_clock::now();
}

WinHttpClient::~WinHttpClient() {
    Shutdown();
}

bool WinHttpClient::Initialize() {
    if (m_isInitialized) {
        return true;
    }

    try {
        // 初始化 WinHTTP 会话
        m_hSession = WinHttpOpen(
            L"WinUI3App/1.0",
            WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
            WINHTTP_NO_PROXY_NAME,
            WINHTTP_NO_PROXY_BYPASS,
            WINHTTP_FLAG_ASYNC
        );

        if (!m_hSession) {
            LogError(L"Failed to initialize WinHTTP session");
            return false;
        }

        // 设置会话选项
        DWORD optionValue = WINHTTP_DISABLE_COOKIES;
        WinHttpSetOption(m_hSession, WINHTTP_OPTION_DISABLE_FEATURE, &optionValue, sizeof(optionValue));

        // 启动工作线程
        m_requestQueue->isRunning = true;
        for (int i = 0; i < std::thread::hardware_concurrency(); ++i) {
            m_workerThreads.emplace_back(&WinHttpClient::WorkerThreadFunction, this);
        }

        m_isInitialized = true;
        return true;
    }
    catch (const std::exception& e) {
        LogError(L"Exception during initialization: " + std::wstring(e.what(), e.what() + strlen(e.what())));
        return false;
    }
}

void WinHttpClient::Shutdown() {
    if (!m_isInitialized) {
        return;
    }

    m_isShuttingDown = true;
    m_requestQueue->isRunning = false;
    m_requestQueue->condition.notify_all();

    // 等待工作线程结束
    for (auto& thread : m_workerThreads) {
        if (thread.joinable()) {
            thread.join();
        }
    }
    m_workerThreads.clear();

    // 清理连接池
    {
        std::lock_guard<std::mutex> lock(m_connectionPool->mutex);
        while (!m_connectionPool->connections.empty()) {
            HINTERNET hConnect = m_connectionPool->connections.front();
            m_connectionPool->connections.pop();
            WinHttpCloseHandle(hConnect);
        }
    }

    // 清理 WinHTTP 句柄
    if (m_hConnect) {
        WinHttpCloseHandle(m_hConnect);
        m_hConnect = nullptr;
    }

    if (m_hSession) {
        WinHttpCloseHandle(m_hSession);
        m_hSession = nullptr;
    }

    m_isInitialized = false;
}

HttpResponse WinHttpClient::SendRequest(const HttpRequestConfig& config) {
    if (!m_isInitialized) {
        return HttpResponse{};
    }

    return SendRequestWithRetry(config);
}

void WinHttpClient::SendRequestAsync(const HttpRequestConfig& config, 
                                   HttpCallback onSuccess, 
                                   ErrorCallback onError) {
    if (!m_isInitialized) {
        if (onError) {
            onError(L"Client not initialized");
        }
        return;
    }

    // 添加到请求队列
    {
        std::lock_guard<std::mutex> lock(m_requestQueue->mutex);
        m_requestQueue->requests.push([this, config, onSuccess, onError]() {
            try {
                HttpResponse response = SendRequestWithRetry(config);
                if (response.success && onSuccess) {
                    onSuccess(response);
                } else if (!response.success && onError) {
                    onError(L"Request failed: " + response.statusText);
                }
            }
            catch (const std::exception& e) {
                if (onError) {
                    onError(L"Exception: " + std::wstring(e.what(), e.what() + strlen(e.what())));
                }
            }
        });
    }
    m_requestQueue->condition.notify_one();
}

void WinHttpClient::SendBatchRequests(const std::vector<HttpRequestConfig>& configs,
                                    std::function<void(const std::vector<HttpResponse>&)> onComplete) {
    if (!m_isInitialized) {
        return;
    }

    std::vector<HttpResponse> responses;
    responses.reserve(configs.size());

    // 使用线程池并行处理请求
    std::vector<std::future<HttpResponse>> futures;
    for (const auto& config : configs) {
        futures.push_back(std::async(std::launch::async, [this, config]() {
            return SendRequestWithRetry(config);
        }));
    }

    // 收集结果
    for (auto& future : futures) {
        responses.push_back(future.get());
    }

    if (onComplete) {
        onComplete(responses);
    }
}

void WinHttpClient::SendStreamRequest(const HttpRequestConfig& config,
                                    std::function<void(const std::vector<uint8_t>&)> onData,
                                    std::function<void()> onComplete,
                                    ErrorCallback onError) {
    if (!m_isInitialized) {
        if (onError) {
            onError(L"Client not initialized");
        }
        return;
    }

    // 实现流式请求
    std::thread([this, config, onData, onComplete, onError]() {
        try {
            // 解析 URL
            URL_COMPONENTS urlComp = {};
            urlComp.dwStructSize = sizeof(urlComp);
            urlComp.dwSchemeLength = -1;
            urlComp.dwHostNameLength = -1;
            urlComp.dwUrlPathLength = -1;

            if (!WinHttpCrackUrl(config.url.c_str(), 0, 0, &urlComp)) {
                if (onError) {
                    onError(L"Failed to parse URL");
                }
                return;
            }

            // 创建连接
            HINTERNET hConnect = WinHttpConnect(
                m_hSession,
                std::wstring(urlComp.lpszHostName, urlComp.dwHostNameLength).c_str(),
                urlComp.nPort,
                0
            );

            if (!hConnect) {
                if (onError) {
                    onError(L"Failed to connect to host");
                }
                return;
            }

            // 创建请求
            HINTERNET hRequest = WinHttpOpenRequest(
                hConnect,
                HttpMethodToString(config.method).c_str(),
                std::wstring(urlComp.lpszUrlPath, urlComp.dwUrlPathLength).c_str(),
                nullptr,
                WINHTTP_NO_REFERER,
                WINHTTP_DEFAULT_ACCEPT_TYPES,
                WINHTTP_FLAG_SECURE
            );

            if (!hRequest) {
                WinHttpCloseHandle(hConnect);
                if (onError) {
                    onError(L"Failed to create request");
                }
                return;
            }

            // 设置请求头
            for (const auto& header : config.headers) {
                std::wstring headerLine = header.first + L": " + header.second;
                WinHttpAddRequestHeaders(hRequest, headerLine.c_str(), -1, WINHTTP_ADDREQ_FLAG_ADD);
            }

            // 发送请求
            if (!WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0, 
                                  const_cast<wchar_t*>(config.body.c_str()), 
                                  static_cast<DWORD>(config.body.length() * sizeof(wchar_t)), 
                                  static_cast<DWORD>(config.body.length() * sizeof(wchar_t)), 0)) {
                WinHttpCloseHandle(hRequest);
                WinHttpCloseHandle(hConnect);
                if (onError) {
                    onError(L"Failed to send request");
                }
                return;
            }

            // 接收响应
            if (!WinHttpReceiveResponse(hRequest, nullptr)) {
                WinHttpCloseHandle(hRequest);
                WinHttpCloseHandle(hConnect);
                if (onError) {
                    onError(L"Failed to receive response");
                }
                return;
            }

            // 读取数据流
            DWORD bytesRead = 0;
            std::vector<uint8_t> buffer(8192);
            
            do {
                if (WinHttpReadData(hRequest, buffer.data(), static_cast<DWORD>(buffer.size()), &bytesRead)) {
                    if (bytesRead > 0) {
                        buffer.resize(bytesRead);
                        if (onData) {
                            onData(buffer);
                        }
                    }
                }
            } while (bytesRead > 0);

            WinHttpCloseHandle(hRequest);
            WinHttpCloseHandle(hConnect);

            if (onComplete) {
                onComplete();
            }
        }
        catch (const std::exception& e) {
            if (onError) {
                onError(L"Exception: " + std::wstring(e.what(), e.what() + strlen(e.what())));
            }
        }
    }).detach();
}

WinHttpClient::PerformanceMetrics WinHttpClient::GetPerformanceMetrics() const {
    PerformanceMetrics metrics;
    metrics.totalRequests = m_stats->totalRequests.load();
    metrics.successfulRequests = m_stats->successfulRequests.load();
    metrics.failedRequests = m_stats->failedRequests.load();
    metrics.totalBytes = m_stats->totalBytes.load();
    metrics.averageResponseTime = m_stats->averageResponseTime.load();
    
    auto now = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::seconds>(now - m_stats->startTime);
    if (duration.count() > 0) {
        metrics.requestsPerSecond = static_cast<double>(metrics.totalRequests) / duration.count();
    }
    
    if (metrics.totalRequests > 0) {
        metrics.successRate = static_cast<double>(metrics.successfulRequests) / metrics.totalRequests * 100.0;
    }
    
    return metrics;
}

void WinHttpClient::ResetPerformanceMetrics() {
    m_stats->totalRequests = 0;
    m_stats->successfulRequests = 0;
    m_stats->failedRequests = 0;
    m_stats->totalBytes = 0;
    m_stats->averageResponseTime = 0.0;
    m_stats->startTime = std::chrono::high_resolution_clock::now();
}

// 工具方法实现
std::wstring WinHttpClient::HttpMethodToString(HttpMethod method) {
    switch (method) {
        case HttpMethod::GET: return L"GET";
        case HttpMethod::POST: return L"POST";
        case HttpMethod::PUT: return L"PUT";
        case HttpMethod::DELETE: return L"DELETE";
        case HttpMethod::PATCH: return L"PATCH";
        case HttpMethod::HEAD: return L"HEAD";
        case HttpMethod::OPTIONS: return L"OPTIONS";
        default: return L"GET";
    }
}

HttpMethod WinHttpClient::StringToHttpMethod(const std::wstring& method) {
    if (method == L"GET") return HttpMethod::GET;
    if (method == L"POST") return HttpMethod::POST;
    if (method == L"PUT") return HttpMethod::PUT;
    if (method == L"DELETE") return HttpMethod::DELETE;
    if (method == L"PATCH") return HttpMethod::PATCH;
    if (method == L"HEAD") return HttpMethod::HEAD;
    if (method == L"OPTIONS") return HttpMethod::OPTIONS;
    return HttpMethod::GET;
}

std::wstring WinHttpClient::HttpStatusCodeToString(HttpStatusCode statusCode) {
    switch (statusCode) {
        case HttpStatusCode::OK: return L"200 OK";
        case HttpStatusCode::Created: return L"201 Created";
        case HttpStatusCode::Accepted: return L"202 Accepted";
        case HttpStatusCode::NoContent: return L"204 No Content";
        case HttpStatusCode::BadRequest: return L"400 Bad Request";
        case HttpStatusCode::Unauthorized: return L"401 Unauthorized";
        case HttpStatusCode::Forbidden: return L"403 Forbidden";
        case HttpStatusCode::NotFound: return L"404 Not Found";
        case HttpStatusCode::InternalServerError: return L"500 Internal Server Error";
        case HttpStatusCode::BadGateway: return L"502 Bad Gateway";
        case HttpStatusCode::ServiceUnavailable: return L"503 Service Unavailable";
        default: return L"Unknown";
    }
}

bool WinHttpClient::IsSuccessStatusCode(HttpStatusCode statusCode) {
    return static_cast<int>(statusCode) >= 200 && static_cast<int>(statusCode) < 300;
}

// 内部方法实现
void WinHttpClient::WorkerThreadFunction() {
    while (m_requestQueue->isRunning) {
        std::function<void()> request;
        
        {
            std::unique_lock<std::mutex> lock(m_requestQueue->mutex);
            m_requestQueue->condition.wait(lock, [this]() {
                return !m_requestQueue->requests.empty() || !m_requestQueue->isRunning;
            });
            
            if (!m_requestQueue->isRunning) {
                break;
            }
            
            if (!m_requestQueue->requests.empty()) {
                request = m_requestQueue->requests.front();
                m_requestQueue->requests.pop();
            }
        }
        
        if (request) {
            request();
        }
    }
}

HttpResponse WinHttpClient::SendRequestWithRetry(const HttpRequestConfig& config) {
    HttpResponse response;
    int retryCount = 0;
    
    while (retryCount <= m_retryConfig.maxRetries) {
        auto startTime = std::chrono::high_resolution_clock::now();
        
        try {
            // 解析 URL
            URL_COMPONENTS urlComp = {};
            urlComp.dwStructSize = sizeof(urlComp);
            urlComp.dwSchemeLength = -1;
            urlComp.dwHostNameLength = -1;
            urlComp.dwUrlPathLength = -1;

            if (!WinHttpCrackUrl(config.url.c_str(), 0, 0, &urlComp)) {
                response.statusText = L"Failed to parse URL";
                break;
            }

            // 获取连接
            HINTERNET hConnect = GetConnection(
                std::wstring(urlComp.lpszHostName, urlComp.dwHostNameLength),
                urlComp.nPort
            );

            if (!hConnect) {
                response.statusText = L"Failed to get connection";
                break;
            }

            // 创建请求
            HINTERNET hRequest = WinHttpOpenRequest(
                hConnect,
                HttpMethodToString(config.method).c_str(),
                std::wstring(urlComp.lpszUrlPath, urlComp.dwUrlPathLength).c_str(),
                nullptr,
                WINHTTP_NO_REFERER,
                WINHTTP_DEFAULT_ACCEPT_TYPES,
                WINHTTP_FLAG_SECURE
            );

            if (!hRequest) {
                ReturnConnection(hConnect);
                response.statusText = L"Failed to create request";
                break;
            }

            // 处理请求
            response = ProcessRequest(hRequest, config);
            
            // 清理资源
            WinHttpCloseHandle(hRequest);
            ReturnConnection(hConnect);
            
            // 检查是否需要重试
            if (response.success || retryCount >= m_retryConfig.maxRetries) {
                break;
            }
            
            // 检查状态码是否可重试
            bool shouldRetry = false;
            for (auto retryableCode : m_retryConfig.retryableStatusCodes) {
                if (response.statusCode == retryableCode) {
                    shouldRetry = true;
                    break;
                }
            }
            
            if (!shouldRetry) {
                break;
            }
            
            // 等待重试
            std::this_thread::sleep_for(
                std::chrono::milliseconds(
                    static_cast<int>(m_retryConfig.initialDelay.count() * 
                                   std::pow(m_retryConfig.backoffMultiplier, retryCount))
                )
            );
            
            retryCount++;
        }
        catch (const std::exception& e) {
            response.statusText = L"Exception: " + std::wstring(e.what(), e.what() + strlen(e.what()));
            break;
        }
    }
    
    // 更新性能统计
    auto endTime = std::chrono::high_resolution_clock::now();
    auto responseTime = std::chrono::duration_cast<std::chrono::milliseconds>(endTime - startTime);
    response.responseTime = responseTime;
    UpdatePerformanceStats(response, responseTime);
    
    return response;
}

HttpResponse WinHttpClient::ProcessRequest(HINTERNET hRequest, const HttpRequestConfig& config) {
    HttpResponse response;
    
    // 设置请求头
    for (const auto& header : config.headers) {
        std::wstring headerLine = header.first + L": " + header.second;
        WinHttpAddRequestHeaders(hRequest, headerLine.c_str(), -1, WINHTTP_ADDREQ_FLAG_ADD);
    }
    
    // 设置超时
    DWORD timeout = static_cast<DWORD>(config.timeout.count());
    WinHttpSetOption(hRequest, WINHTTP_OPTION_SEND_TIMEOUT, &timeout, sizeof(timeout));
    WinHttpSetOption(hRequest, WINHTTP_OPTION_RECEIVE_TIMEOUT, &timeout, sizeof(timeout));
    
    // 发送请求
    if (!WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0, 
                          const_cast<wchar_t*>(config.body.c_str()), 
                          static_cast<DWORD>(config.body.length() * sizeof(wchar_t)), 
                          static_cast<DWORD>(config.body.length() * sizeof(wchar_t)), 0)) {
        response.statusText = L"Failed to send request";
        return response;
    }
    
    // 接收响应
    if (!WinHttpReceiveResponse(hRequest, nullptr)) {
        response.statusText = L"Failed to receive response";
        return response;
    }
    
    // 获取状态码
    DWORD statusCode = 0;
    DWORD statusCodeSize = sizeof(statusCode);
    WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                       WINHTTP_HEADER_NAME_BY_INDEX, &statusCode, &statusCodeSize, WINHTTP_NO_HEADER_INDEX);
    
    response.statusCode = static_cast<HttpStatusCode>(statusCode);
    response.success = IsSuccessStatusCode(response.statusCode);
    
    // 获取状态文本
    wchar_t statusText[256] = {};
    DWORD statusTextSize = sizeof(statusText);
    WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_STATUS_TEXT,
                       WINHTTP_HEADER_NAME_BY_INDEX, statusText, &statusTextSize, WINHTTP_NO_HEADER_INDEX);
    response.statusText = statusText;
    
    // 读取响应体
    std::vector<uint8_t> responseData;
    DWORD bytesRead = 0;
    std::vector<uint8_t> buffer(8192);
    
    do {
        if (WinHttpReadData(hRequest, buffer.data(), static_cast<DWORD>(buffer.size()), &bytesRead)) {
            if (bytesRead > 0) {
                responseData.insert(responseData.end(), buffer.begin(), buffer.begin() + bytesRead);
            }
        }
    } while (bytesRead > 0);
    
    // 转换响应体为字符串
    if (!responseData.empty()) {
        response.body = std::wstring(responseData.begin(), responseData.end());
        response.contentLength = responseData.size();
    }
    
    return response;
}

void WinHttpClient::UpdatePerformanceStats(const HttpResponse& response, std::chrono::milliseconds responseTime) {
    m_stats->totalRequests++;
    
    if (response.success) {
        m_stats->successfulRequests++;
    } else {
        m_stats->failedRequests++;
    }
    
    m_stats->totalBytes += response.contentLength;
    
    // 更新平均响应时间
    double currentAvg = m_stats->averageResponseTime.load();
    double newAvg = (currentAvg * (m_stats->totalRequests - 1) + responseTime.count()) / m_stats->totalRequests;
    m_stats->averageResponseTime = newAvg;
}

HINTERNET WinHttpClient::GetConnection(const std::wstring& host, INTERNET_PORT port) {
    // 尝试从连接池获取连接
    {
        std::lock_guard<std::mutex> lock(m_connectionPool->mutex);
        if (!m_connectionPool->connections.empty()) {
            HINTERNET hConnect = m_connectionPool->connections.front();
            m_connectionPool->connections.pop();
            m_connectionPool->currentConnections--;
            return hConnect;
        }
    }
    
    // 创建新连接
    return WinHttpConnect(m_hSession, host.c_str(), port, 0);
}

void WinHttpClient::ReturnConnection(HINTERNET hConnect) {
    if (!hConnect) {
        return;
    }
    
    std::lock_guard<std::mutex> lock(m_connectionPool->mutex);
    if (m_connectionPool->currentConnections < m_connectionPool->maxConnections) {
        m_connectionPool->connections.push(hConnect);
        m_connectionPool->currentConnections++;
    } else {
        WinHttpCloseHandle(hConnect);
    }
}

std::wstring WinHttpClient::GetLastErrorString() const {
    DWORD error = GetLastError();
    wchar_t* errorText = nullptr;
    
    if (FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM,
                      nullptr, error, 0, reinterpret_cast<LPWSTR>(&errorText), 0, nullptr)) {
        std::wstring result(errorText);
        LocalFree(errorText);
        return result;
    }
    
    return L"Unknown error: " + std::to_wstring(error);
}

void WinHttpClient::LogError(const std::wstring& message) const {
    std::wcerr << L"[WinHttpClient] " << message << std::endl;
}

} // namespace Network
