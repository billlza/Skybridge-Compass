import Foundation
import OSLog
import SkyBridgeProtocolCore

// MARK: - TURN 动态凭据服务
/// 从后端动态获取 TURN 凭据，避免硬编码凭据带来的安全风险
/// 支持 TURN REST API (RFC 7635) 风格的短期凭据
public actor TURNCredentialService {
    
    // MARK: - 单例
    
    public static let shared = TURNCredentialService()
    
    // MARK: - 配置
    
    /// TURN 凭据请求端点
    private var credentialEndpoint: URL? {
        URL(string: "\(SkyBridgeServerConfig.signalingServerURL)/api/turn/credentials")
    }
    
    /// 缓存的凭据
    private var cachedCredentials: TURNCredentials?
    
    /// 凭据有效期缓冲（提前 5 分钟刷新）
    private let expirationBuffer: TimeInterval = 300
    
    /// 日志
    private let logger = Logger(subsystem: "com.skybridge.turn", category: "CredentialService")
    
    // MARK: - 数据类型
    
    /// TURN 凭据
    public struct TURNCredentials: Sendable, Codable {
        public let username: String
        public let password: String
        public let ttl: Int  // 有效期（秒）
        public let uris: [String]  // TURN 服务器 URIs
        public let expiresAt: Date
        
        public init(username: String, password: String, ttl: Int, uris: [String], expiresAt: Date) {
            self.username = username
            self.password = password
            self.ttl = ttl
            self.uris = uris
            self.expiresAt = expiresAt
        }
        
        /// 检查凭据是否仍然有效
        public func isValid(buffer: TimeInterval = 300) -> Bool {
            Date().addingTimeInterval(buffer) < expiresAt
        }
    }
    
    /// 服务器响应格式 (遵循 TURN REST API 标准)
    private struct ServerResponse: Codable {
        let username: String
        let password: String
        let ttl: Int
        let uris: [String]?
        let expiresAt: Int?
        let mode: String?
    }
    
    // MARK: - 错误类型
    
    public enum TURNCredentialError: Error, LocalizedError {
        case endpointNotConfigured
        case networkError(Error)
        case invalidResponse(String)
        case serverError(Int, String?)
        case decodingFailed(Error)
        
        public var errorDescription: String? {
            switch self {
            case .endpointNotConfigured:
                return "TURN 凭据端点未配置"
            case .networkError(let error):
                return "网络请求失败: \(error.localizedDescription)"
            case .invalidResponse(let msg):
                return "无效的服务器响应: \(msg)"
            case .serverError(let code, let msg):
                return "服务器错误 (\(code)): \(msg ?? "未知错误")"
            case .decodingFailed(let error):
                return "凭据解析失败: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - 公开 API
    
    /// 获取有效的 TURN 凭据
    /// 如果缓存凭据仍然有效，返回缓存；否则从服务器获取新凭据
    /// 如果服务器不可用，回退到静态凭据
    public func getCredentials() async -> TURNCredentials {
        // 检查缓存是否有效
        if let cached = cachedCredentials, cached.isValid(buffer: expirationBuffer) {
            logger.debug("📦 使用缓存的 TURN 凭据 (有效期至 \(cached.expiresAt))")
            return cached
        }
        
        // 尝试从服务器获取
        do {
            let fresh = try await fetchFromServer()
            cachedCredentials = fresh
            logger.info("✅ 获取到新的 TURN 凭据 ttl=\(fresh.ttl)s")
            return fresh
        } catch {
            logger.warning("⚠️ 动态凭据获取失败，回退到静态凭据: \(error.localizedDescription)")
            return fallbackCredentials()
        }
    }
    
    /// 强制刷新凭据
    public func refreshCredentials() async throws -> TURNCredentials {
        cachedCredentials = nil
        let fresh = try await fetchFromServer()
        cachedCredentials = fresh
        return fresh
    }
    
    /// 清除缓存的凭据
    public func clearCache() {
        cachedCredentials = nil
        logger.info("🗑️ TURN 凭据缓存已清除")
    }
    
    // MARK: - 私有方法
    
    /// 从服务器获取凭据
    private func fetchFromServer() async throws -> TURNCredentials {
        guard let endpoint = credentialEndpoint else {
            throw TURNCredentialError.endpointNotConfigured
        }
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let clientAPIKey = SkyBridgeServerConfig.clientAPIKey
        if !clientAPIKey.isEmpty {
            request.setValue(clientAPIKey, forHTTPHeaderField: "X-API-Key")
        }
        if let deviceId = resolvedDeviceIdentifier() {
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        }
        request.timeoutInterval = 10
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TURNCredentialError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TURNCredentialError.invalidResponse("非 HTTP 响应")
        }
        let instance = httpResponse.value(forHTTPHeaderField: "X-SkyBridge-Instance") ?? "unknown"
        let backend = httpResponse.value(forHTTPHeaderField: "X-SkyBridge-State-Backend") ?? "unknown"
        let prefixes = httpResponse.value(forHTTPHeaderField: "X-SkyBridge-Code-Prefixes") ?? "-"
        logger.info("🌐 TURN credentials served by instance=\(instance, privacy: .public) backend=\(backend, privacy: .public) prefixes=\(prefixes, privacy: .public)")
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw TURNCredentialError.serverError(httpResponse.statusCode, body)
        }
        
        do {
            let serverResp = try JSONDecoder().decode(ServerResponse.self, from: data)
            let ttl = max(60, serverResp.ttl)
            let expiresAt: Date
            if let expiresAtEpoch = serverResp.expiresAt, expiresAtEpoch > 0 {
                expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtEpoch))
            } else {
                expiresAt = Date().addingTimeInterval(TimeInterval(ttl))
            }
            let uris = SkyBridgeServerConfig.preferredTurnURIs(
                from: serverResp.uris ?? [],
                fallback: SkyBridgeServerConfig.turnURLs
            )
            
            return TURNCredentials(
                username: serverResp.username,
                password: serverResp.password,
                ttl: ttl,
                uris: uris,
                expiresAt: expiresAt
            )
        } catch {
            throw TURNCredentialError.decodingFailed(error)
        }
    }
    
    /// 静态凭据回退（仅在动态获取失败时使用）
    /// ⚠️ 这是临时兜底方案，生产环境应确保动态凭据服务可用
    private func fallbackCredentials() -> TURNCredentials {
        let username = SkyBridgeServerConfig.turnUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = SkyBridgeServerConfig.turnPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, !password.isEmpty else {
            logger.warning("⚠️ 静态回退 TURN 凭据不完整（缺少用户名或密码），将降级为 STUN-only")
            return TURNCredentials(
                username: "",
                password: "",
                ttl: 3600,
                uris: [],
                expiresAt: Date().addingTimeInterval(3600)
            )
        }

        logger.warning("⚠️ 使用静态回退凭据 - 请确保后端 TURN 凭据服务正常运行")
        return TURNCredentials(
            username: username,
            password: password,
            ttl: 3600,
            uris: SkyBridgeServerConfig.turnURLs,
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    private func resolvedDeviceIdentifier() -> String? {
        let envID = ProcessInfo.processInfo.environment["SKYBRIDGE_DEVICE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envID.isEmpty {
            return envID
        }

        let keychainID = KeychainManager.shared.getOrGenerateDeviceId()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return keychainID.isEmpty ? nil : keychainID
    }
}

// MARK: - 扩展 SkyBridgeServerConfig

extension SkyBridgeServerConfig {
    /// 动态获取 TURN 凭据的 ICE 配置
    public static func dynamicICEConfig() async -> SkyBridgeICEConfiguration {
        let creds = await TURNCredentialService.shared.getCredentials()
        let turnUsername = creds.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnPassword = creds.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnURIs = preferredTurnURIs(from: creds.uris, fallback: self.turnURLs)
        let shouldUseTURN = !turnUsername.isEmpty && !turnPassword.isEmpty && !turnURIs.isEmpty

        return SkyBridgeICEConfiguration(
            stunURL: stunURL,
            turnURLs: shouldUseTURN ? turnURIs : [],
            turnUsername: shouldUseTURN ? turnUsername : "",
            turnPassword: shouldUseTURN ? turnPassword : ""
        )
    }
}
