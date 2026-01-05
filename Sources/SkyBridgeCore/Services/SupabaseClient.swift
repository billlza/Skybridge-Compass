import Foundation
import OSLog

/// Supabase REST 客户端封装
/// 统一管理请求头、超时与会话配置，避免散布在各模块的重复逻辑
public final class SupabaseClient {
    private let baseURL: URL
    private let anonKey: String
    private let jwtProvider: (@Sendable () async -> String?)?
    private let session: URLSession
    private let logger = Logger(subsystem: "com.skybridge.supabase", category: "RESTClient")

 /// 统一重试策略配置（可自定义）
    private var maxRetries = 3
    private var baseDelay: TimeInterval = 0.2
    private var retryStatusCodes: Set<Int> = Set(500...599)

 /// 初始化客户端
 /// - Parameters:
 /// - baseURL: Supabase 项目根URL（https://xxx.supabase.co）
 /// - anonKey: 匿名密钥（apikey）
 /// - jwtProvider: 用户JWT提供者（可选），存在时将添加 Authorization 头
    public init(
        baseURL: URL,
        anonKey: String,
        jwtProvider: (@Sendable () async -> String?)? = nil,
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 0.2,
        retryStatusCodes: Set<Int> = Set(500...599)
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.jwtProvider = jwtProvider
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.retryStatusCodes = retryStatusCodes
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

 /// 执行 GET 请求
 /// - Parameters:
 /// - path: 路径（形如 "/rest/v1/user_devices"）
 /// - query: 查询参数
 /// - Returns: （Data, HTTPURLResponse）
    public func get(path: String, query: [String: String] = [:], enableRetry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        req.addValue(anonKey, forHTTPHeaderField: "apikey")
        if let jwtProvider, let jwt = await jwtProvider() {
            req.addValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")
        }
        logger.info("➡️ GET \(url.absoluteString)")
        let (data, resp) = try await perform(req, enableRetry: enableRetry)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        logger.info("⬅️ GET \(url.absoluteString) status=\(http.statusCode) bytes=\(data.count)")
        return (data, http)
    }

 // MARK: - 通用错误类型
    public enum SupabaseError: LocalizedError {
        case badURL
        case httpStatus(code: Int, body: String?)
        case decodeFailed(String)
        case network(Error)

        public var errorDescription: String? {
            switch self {
            case .badURL: return "请求URL无效"
            case .httpStatus(let code, let body): return "HTTP状态异常: \(code) \(body ?? "")"
            case .decodeFailed(let reason): return "JSON解码失败: \(reason)"
            case .network(let err): return "网络请求失败: \(err.localizedDescription)"
            }
        }
    }

 /// 执行 GET 并解码 JSON 响应
    public func getJSON<T: Decodable>(path: String, query: [String: String] = [:], decoder: JSONDecoder = JSONDecoder(), enableRetry: Bool = true) async throws -> T {
        do {
            let (data, http) = try await get(path: path, query: query, enableRetry: enableRetry)
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                throw SupabaseError.httpStatus(code: http.statusCode, body: body)
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw SupabaseError.decodeFailed(error.localizedDescription)
            }
        } catch let err as SupabaseError {
            throw err
        } catch {
            throw SupabaseError.network(error)
        }
    }

 /// 执行 POST 并解码 JSON 响应
    public func postJSON<Body: Encodable, Response: Decodable>(path: String, body: Body, encoder: JSONEncoder = JSONEncoder(), decoder: JSONDecoder = JSONDecoder(), enableRetry: Bool = false) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(anonKey, forHTTPHeaderField: "apikey")
        if let jwtProvider, let jwt = await jwtProvider() {
            req.addValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")
        }
        do {
            req.httpBody = try encoder.encode(body)
        } catch {
            throw SupabaseError.decodeFailed("请求体编码失败: \(error.localizedDescription)")
        }
        do {
            logger.info("➡️ POST \(url.absoluteString) bytes=\(req.httpBody?.count ?? 0)")
            logger.info("➡️ POST \(url.absoluteString) bytes=\(req.httpBody?.count ?? 0)")
            let (data, resp) = try await perform(req, enableRetry: enableRetry)
            guard let http = resp as? HTTPURLResponse else { throw SupabaseError.badURL }
            guard (200...299).contains(http.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8)
                logger.error("❌ POST \(url.absoluteString) status=\(http.statusCode) body=\(bodyStr ?? "<empty>")")
                throw SupabaseError.httpStatus(code: http.statusCode, body: bodyStr)
            }
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw SupabaseError.decodeFailed(error.localizedDescription)
            }
        } catch let err as SupabaseError {
            throw err
        } catch {
            throw SupabaseError.network(error)
        }
    }

 /// 执行 PUT 并解码 JSON 响应
    public func putJSON<Body: Encodable, Response: Decodable>(path: String, body: Body, encoder: JSONEncoder = JSONEncoder(), decoder: JSONDecoder = JSONDecoder(), enableRetry: Bool = false) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(anonKey, forHTTPHeaderField: "apikey")
        if let jwtProvider, let jwt = await jwtProvider() {
            req.addValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")
        }
        do { req.httpBody = try encoder.encode(body) } catch { throw SupabaseError.decodeFailed("请求体编码失败: \(error.localizedDescription)") }
        do {
            logger.info("➡️ PUT \(url.absoluteString) bytes=\(req.httpBody?.count ?? 0)")
            let (data, resp) = try await perform(req, enableRetry: enableRetry)
            guard let http = resp as? HTTPURLResponse else { throw SupabaseError.badURL }
            guard (200...299).contains(http.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8)
                logger.error("❌ PUT \(url.absoluteString) status=\(http.statusCode) body=\(bodyStr ?? "<empty>")")
                throw SupabaseError.httpStatus(code: http.statusCode, body: bodyStr)
            }
            do { return try decoder.decode(Response.self, from: data) } catch { throw SupabaseError.decodeFailed(error.localizedDescription) }
        } catch let err as SupabaseError { throw err } catch { throw SupabaseError.network(error) }
    }

 /// 执行 DELETE 并解码 JSON 响应
    public func deleteJSON<Response: Decodable>(path: String, query: [String: String] = [:], decoder: JSONDecoder = JSONDecoder(), enableRetry: Bool = true) async throws -> Response {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw SupabaseError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        req.addValue(anonKey, forHTTPHeaderField: "apikey")
        if let jwtProvider, let jwt = await jwtProvider() { req.addValue("Bearer " + jwt, forHTTPHeaderField: "Authorization") }
        do {
            logger.info("➡️ DELETE \(url.absoluteString)")
            let (data, resp) = try await perform(req, enableRetry: enableRetry)
            guard let http = resp as? HTTPURLResponse else { throw SupabaseError.badURL }
            guard (200...299).contains(http.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8)
                logger.error("❌ DELETE \(url.absoluteString) status=\(http.statusCode) body=\(bodyStr ?? "<empty>")")
                throw SupabaseError.httpStatus(code: http.statusCode, body: bodyStr)
            }
            do { return try decoder.decode(Response.self, from: data) } catch { throw SupabaseError.decodeFailed(error.localizedDescription) }
        } catch let err as SupabaseError { throw err } catch { throw SupabaseError.network(error) }
    }

 /// 非解码版本的 DELETE 请求（返回原始数据与响应）
    public func delete(path: String, query: [String: String] = [:], enableRetry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw SupabaseError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        req.addValue(anonKey, forHTTPHeaderField: "apikey")
        if let jwtProvider, let jwt = await jwtProvider() { req.addValue("Bearer " + jwt, forHTTPHeaderField: "Authorization") }
        logger.info("➡️ DELETE \(url.absoluteString)")
        let (data, resp) = try await perform(req, enableRetry: enableRetry)
        guard let http = resp as? HTTPURLResponse else { throw SupabaseError.badURL }
        logger.info("⬅️ DELETE \(url.absoluteString) status=\(http.statusCode) bytes=\(data.count)")
        return (data, http)
    }

 /// 带统一重试策略的请求执行器
    private func perform(_ request: URLRequest, enableRetry: Bool = true) async throws -> (Data, URLResponse) {
        var attempt = 0
        var lastError: Error?
        while enableRetry && attempt < maxRetries {
            do {
                let (data, resp) = try await session.data(for: request)
                if let http = resp as? HTTPURLResponse, retryStatusCodes.contains(http.statusCode) {
                    throw SupabaseError.httpStatus(code: http.statusCode, body: String(data: data, encoding: .utf8))
                }
                return (data, resp)
            } catch {
                lastError = error
                attempt += 1
                if attempt >= maxRetries { break }
                let jitter = Double.random(in: 0...0.1)
                let delay = baseDelay * pow(2, Double(attempt - 1)) + jitter
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        if !enableRetry {
 // 不重试：直接执行一次请求
            do {
                return try await session.data(for: request)
            } catch {
                throw SupabaseError.network(error)
            }
        } else {
            throw lastError ?? SupabaseError.network(URLError(.cannotConnectToHost))
        }
    }
}