import Foundation

/// 认证管理器 - 管理用户认证和会话
@MainActor
public class AuthenticationManager: ObservableObject {
    public static let instance = AuthenticationManager()
    
    // MARK: - Published Properties
    
    @Published public private(set) var currentUser: User?
    @Published public var isAuthenticated: Bool = false
    @Published public var isGuestMode: Bool = false

    private var session: AuthSession?
    private var didLogSupabaseConfigMissing = false
    private var lastTokenRefreshAttemptAt: Date?

    public enum AuthFlowError: LocalizedError {
        case emailVerificationRequired

        public var errorDescription: String? {
            switch self {
            case .emailVerificationRequired:
                return "注册成功！请检查邮箱并点击验证链接后再登录。"
            }
        }
    }
    
    private init() {
        loadSession()
    }
    
    // MARK: - Public Methods
    
    /// 注册
    public func register(email: String, password: String) async throws {
        // 与 macOS 端一致：注册时生成 nebula_id 并写入 Supabase metadata
        let nebulaId = try NebulaIDGenerator.shared.generateUserRegistrationID().fullId
        let displayName = email.components(separatedBy: "@").first ?? "用户"

        let session = try await SupabaseService.shared.signUp(
            email: email,
            password: password,
            metadata: [
                "display_name": displayName,
                "registration_source": "SkyBridge Compass iOS",
                "nebula_id": nebulaId
            ]
        )

        // 与 macOS 端一致：需要邮箱验证时，不进入已登录态
        if session.accessToken == "pending_verification" {
            SkyBridgeLogger.shared.info("📧 注册需要邮箱验证: \(email)")
            throw AuthFlowError.emailVerificationRequired
        }

        // 尝试写入 users 表（若 accessToken = pending_verification，则传 nil，保持与 macOS 行为一致）
        _ = try? await SupabaseService.shared.saveNebulaIdToDatabase(
            userId: session.userIdentifier,
            nebulaId: nebulaId,
            accessToken: session.accessToken == "pending_verification" ? nil : session.accessToken
        )

        // signup 返回 pending_verification 时没有 metadata；我们用本地生成的 nebula_id 先落盘，体验与 macOS 一致（可持久化）
        let enrichedSession = AuthSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userIdentifier: session.userIdentifier,
            displayName: session.displayName,
            email: session.email,
            avatarURL: session.avatarURL,
            nebulaId: nebulaId,
            issuedAt: session.issuedAt
        )

        applySession(enrichedSession, emailFallback: email)
        SkyBridgeLogger.shared.info("✅ 注册成功: \(email) (nebula_id=\(nebulaId))")
    }
    
    /// 登录
    public func signIn(email: String, password: String) async throws {
        let session = try await SupabaseService.shared.signInWithEmail(email: email, password: password)
        applySession(session, emailFallback: email)
        SkyBridgeLogger.shared.info("✅ 登录成功: \(email)")
    }

    /// Nebula 安全浏览器登录（OAuth 2.1 + PKCE）
    public func signInWithNebulaBrowser() async throws {
        let (tokenResponse, userInfo) = try await NebulaPublicClientOAuth.shared.authenticateUsingSystemBrowser()
        let displayName = userInfo.name ?? userInfo.preferredUsername ?? userInfo.email ?? "Nebula User"
        let email = userInfo.email ?? "\(userInfo.subject)@nebula.local"
        let session = AuthSession(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            userIdentifier: userInfo.subject,
            displayName: displayName,
            email: userInfo.email,
            avatarURL: userInfo.picture,
            nebulaId: nil,
            issuedAt: Date()
        )
        applySession(session, emailFallback: email)
        SkyBridgeLogger.shared.info("✅ Nebula 浏览器登录成功: \(displayName)")
    }

    /// Nebula 安全浏览器注册（OAuth 2.1 + PKCE）
    public func registerWithNebulaBrowser() async throws {
        let (tokenResponse, userInfo) = try await NebulaPublicClientOAuth.shared.registerUsingSystemBrowser()
        let displayName = userInfo.name ?? userInfo.preferredUsername ?? userInfo.email ?? "Nebula User"
        let email = userInfo.email ?? "\(userInfo.subject)@nebula.local"
        let session = AuthSession(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            userIdentifier: userInfo.subject,
            displayName: displayName,
            email: userInfo.email,
            avatarURL: userInfo.picture,
            nebulaId: nil,
            issuedAt: Date()
        )
        applySession(session, emailFallback: email)
        SkyBridgeLogger.shared.info("✅ Nebula 浏览器注册成功: \(displayName)")
    }

    /// 手动刷新账号资料（NebulaID/头像/昵称等），与 macOS 持久化体验对齐
    public func refreshProfile() async {
        await refreshProfileIfPossible()
    }
    
    /// 游客模式登录
    public func signInAsGuest() async {
        let guestUser = User(
            id: "guest-\(UUID().uuidString)",
            email: "guest@skybridge.local",
            displayName: "游客"
        )
        
        currentUser = guestUser
        isAuthenticated = true
        isGuestMode = true
        session = nil
        
        SkyBridgeLogger.shared.info("👤 游客模式登录")
    }
    
    /// 退出登录
    public func signOut() async {
        currentUser = nil
        isAuthenticated = false
        isGuestMode = false
        session = nil
        clearSession()
        
        SkyBridgeLogger.shared.info("👋 已退出登录")
    }
    
    /// 模拟认证（用于预览）
    public func mockAuthentication(userID: String) {
        currentUser = User(
            id: userID,
            email: "preview@skybridge.local",
            displayName: "Preview User"
        )
        isAuthenticated = true
    }
    
    // MARK: - Private Methods
    
    private func loadSession() {
        if let session = KeychainManager.shared.loadAuthSession() {
            self.session = session
            let email = session.email ?? (session.displayName.contains("@") ? session.displayName : "user@skybridge.local")
            let avatarURL = session.avatarURL.flatMap(URL.init(string:))
            currentUser = User(
                id: session.userIdentifier,
                email: email,
                displayName: session.displayName,
                avatarURL: avatarURL,
                nebulaId: session.nebulaId
            )
            isAuthenticated = true
            isGuestMode = false

            // 启动后后台刷新一次（不阻塞 UI）
            Task { [weak self] in
                await self?.refreshProfileIfPossible()
            }
        }
    }
    
    private func saveSession() {
        guard let session else { return }
        try? KeychainManager.shared.storeAuthSession(session)
    }
    
    private func clearSession() {
        KeychainManager.shared.deleteAuthSession()
    }

    private func applySession(_ session: AuthSession, emailFallback: String) {
        self.session = session
        let displayName = session.displayName.isEmpty ? (emailFallback.components(separatedBy: "@").first ?? "用户") : session.displayName
        let avatarURL = session.avatarURL.flatMap(URL.init(string:))
        currentUser = User(
            id: session.userIdentifier,
            email: emailFallback,
            displayName: displayName,
            avatarURL: avatarURL,
            nebulaId: session.nebulaId
        )
        isAuthenticated = true
        isGuestMode = false
        saveSession()

        // 登录成功后自动刷新一次，确保 iOS 与 macOS 的 nebula_id/avatar 等一致并持久化
        Task { [weak self] in
            await self?.refreshProfileIfPossible()
        }
    }

    private func refreshProfileIfPossible() async {
        guard isAuthenticated, !isGuestMode else { return }
        guard let session, session.accessToken != "pending_verification" else { return }
        guard SupabaseService.shared.isConfigured else {
            // 配置缺失时不刷屏：只提示一次即可
            if !didLogSupabaseConfigMissing {
                didLogSupabaseConfigMissing = true
                SkyBridgeLogger.shared.info("ℹ️ Supabase 配置缺失：跳过账号资料刷新（请在设置中配置或提供 SupabaseConfig.plist）")
            }
            return
        }

        do {
            let profile = try await SupabaseService.shared.fetchCurrentUserProfile(accessToken: session.accessToken)
            applyRemoteProfile(profile)
        } catch {
            // 若是 token 过期，尝试 refresh_token 后重试一次
            if await tryRefreshTokenIfNeeded(because: error) {
                if let updated = self.session {
                    let profile = try? await SupabaseService.shared.fetchCurrentUserProfile(accessToken: updated.accessToken)
                    if let profile { applyRemoteProfile(profile) }
                }
                return
            }

            // 网络/配置失败不影响主流程
            SkyBridgeLogger.shared.debug("ℹ️ 账号资料刷新失败（忽略）：\(error.localizedDescription)")
        }
    }

    private func tryRefreshTokenIfNeeded(because error: Error) async -> Bool {
        guard let session else { return false }
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else { return false }

        // 限制 refresh 重试频率，避免失败时刷网络/刷日志
        if let last = lastTokenRefreshAttemptAt, Date().timeIntervalSince(last) < 30 {
            return false
        }

        guard isSupabaseTokenExpiredError(error) else { return false }
        lastTokenRefreshAttemptAt = Date()

        do {
            let refreshed = try await SupabaseService.shared.refreshSession(refreshToken: refreshToken)
            // 保留本地 session 中的 display/email/avatar/nebulaId（refresh 响应可能为空/不全）
            let merged = AuthSession(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken ?? session.refreshToken,
                userIdentifier: session.userIdentifier,
                displayName: session.displayName,
                email: session.email,
                avatarURL: session.avatarURL,
                nebulaId: session.nebulaId,
                issuedAt: Date()
            )
            self.session = merged
            saveSession()
            SkyBridgeLogger.shared.info("🔄 Supabase access token 已刷新")
            return true
        } catch {
            SkyBridgeLogger.shared.warning("⚠️ Supabase token 刷新失败（忽略）：\(error.localizedDescription)")
            return false
        }
    }

    private func isSupabaseTokenExpiredError(_ error: Error) -> Bool {
        // 兼容 Supabase 返回：403 bad_jwt / token is expired
        if let err = error as? SupabaseService.SupabaseError {
            switch err {
            case .httpStatus(let code, let message):
                guard code == 401 || code == 403 else { return false }
                let msg = (message ?? "").lowercased()
                return msg.contains("bad_jwt") || msg.contains("token is expired") || msg.contains("expired")
            default:
                return false
            }
        }
        let msg = error.localizedDescription.lowercased()
        return msg.contains("bad_jwt") || msg.contains("token is expired") || msg.contains("expired")
    }

    private func applyRemoteProfile(_ profile: SupabaseService.RemoteUserProfile) {
        guard let session else { return }

        // 更新 session（写入 Keychain 持久化）
        let updatedSession = AuthSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userIdentifier: session.userIdentifier,
            displayName: profile.displayName ?? session.displayName,
            email: profile.email ?? session.email,
            avatarURL: profile.avatarURL ?? session.avatarURL,
            nebulaId: profile.nebulaId ?? session.nebulaId,
            issuedAt: session.issuedAt
        )
        self.session = updatedSession
        saveSession()

        // 更新 currentUser（驱动 UI）
        let email = updatedSession.email ?? (updatedSession.displayName.contains("@") ? updatedSession.displayName : (currentUser?.email ?? "user@skybridge.local"))
        let avatar = updatedSession.avatarURL.flatMap(URL.init(string:))
        currentUser = User(
            id: updatedSession.userIdentifier,
            email: email,
            displayName: updatedSession.displayName,
            avatarURL: avatar,
            nebulaId: updatedSession.nebulaId
        )
    }
}
