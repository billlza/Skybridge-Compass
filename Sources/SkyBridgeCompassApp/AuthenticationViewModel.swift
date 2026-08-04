import Foundation
@preconcurrency import Combine
import SwiftUI
import AuthenticationServices
import LocalAuthentication
import CryptoKit
import Security
import SkyBridgeCore
#if canImport(AppKit)
import AppKit
#endif

/// 现代化登录视图模型，遵循Apple 2025设计规范和最佳实践
/// 支持Apple ID、星云、手机号、邮箱四种登录方式
@MainActor
final class AuthenticationViewModel: NSObject, ObservableObject {

 // MARK: - 登录方式枚举

 /// 登录方式选项，全部对接真实后端接口
    enum LoginMethod: String, CaseIterable, Identifiable {
        case apple = "apple"
        case nebula = "nebula"
        case phone = "phone"
        case email = "email"

        var id: String { rawValue }

        @MainActor
        var title: String {
            switch self {
            case .apple: return LocalizationManager.shared.localizedString("auth.method.apple.title")
            case .nebula: return LocalizationManager.shared.localizedString("auth.method.nebula.title")
            case .phone: return LocalizationManager.shared.localizedString("auth.method.phone.title")
            case .email: return LocalizationManager.shared.localizedString("auth.method.email.title")
            }
        }

        @MainActor
        var subtitle: String {
            switch self {
            case .apple: return LocalizationManager.shared.localizedString("auth.method.apple.subtitle")
            case .nebula: return LocalizationManager.shared.localizedString("auth.method.nebula.subtitle")
            case .phone: return LocalizationManager.shared.localizedString("auth.method.phone.subtitle")
            case .email: return LocalizationManager.shared.localizedString("auth.method.email.subtitle")
            }
        }

        var icon: String {
            switch self {
            case .apple: return "applelogo"
            case .nebula: return "cloud.circle.fill"
            case .phone: return "phone.circle.fill"
            case .email: return "envelope.circle.fill"
            }
        }

        var primaryColor: Color {
            switch self {
            case .apple: return .primary
            case .nebula: return .purple
            case .phone: return .green
            case .email: return .blue
            }
        }
    }

    enum AppleSignInMode: String {
        case disabled
        case native
        case webSession = "web_session"

        static func parse(_ rawValue: String) -> Self? {
            let normalized = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
                .lowercased()

            switch normalized {
            case "native":
                return .native
            case "web", "browser", "browser_session", "web_session", "aswebauthenticationsession", "secure_web_session":
                return .webSession
            case "disabled", "off", "none":
                return .disabled
            default:
                return nil
            }
        }
    }

    private static func boolOverride(named key: String) -> Bool? {
        guard let override = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }

        switch override {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    private static var appleSignInLaunchReady: Bool {
        appleSignInMode != .disabled
    }

    private static var nativeAppleSignInRuntimeReady: Bool {
        appleSignInMode == .native
    }

    private static var appleSignInMode: AppleSignInMode {
        if let modeOverride = ProcessInfo.processInfo.environment["SKYBRIDGE_APPLE_SIGN_IN_MODE"],
           let parsedMode = AppleSignInMode.parse(modeOverride) {
            return parsedMode
        }

        let appleSignInEnabled =
            boolOverride(named: "SKYBRIDGE_ENABLE_APPLE_SIGN_IN")
            ?? (Bundle.main.object(forInfoDictionaryKey: "SKYBRIDGE_ENABLE_APPLE_SIGN_IN") as? Bool)
            ?? false

        guard appleSignInEnabled else {
            return .disabled
        }

        if let nativeOverride = boolOverride(named: "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN") {
            return nativeOverride ? .native : .webSession
        }

        if let bundledMode = Bundle.main.object(forInfoDictionaryKey: "SKYBRIDGE_APPLE_SIGN_IN_MODE") as? String,
           let parsedMode = AppleSignInMode.parse(bundledMode) {
            return parsedMode
        }

        if let bundledValue = Bundle.main.object(forInfoDictionaryKey: "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN") as? Bool {
            return bundledValue ? .native : .webSession
        }

        return .native
    }

    static var availableLoginMethods: [LoginMethod] {
        appleSignInLaunchReady ? LoginMethod.allCases : LoginMethod.allCases.filter { $0 != .apple }
    }

    static var defaultLoginMethod: LoginMethod {
        availableLoginMethods.first ?? .email
    }

    var availableLoginMethods: [LoginMethod] {
        Self.availableLoginMethods
    }

    var appleSignInPresentationMode: AppleSignInMode {
        Self.appleSignInMode
    }

    var usesNativeAppleSignIn: Bool {
        Self.nativeAppleSignInRuntimeReady
    }

    private func t(_ key: String) -> String {
        LocalizationManager.shared.localizedString(key)
    }

    private func formatted(_ key: String, _ arguments: CVarArg...) -> String {
        let format = t(key)
        return withVaList(arguments) { pointer in
            NSString(
                format: format,
                locale: LocalizationManager.shared.locale as NSLocale,
                arguments: pointer
            ) as String
        }
    }

    internal static func resolvedNebulaId(from userInfo: NebulaPublicClientOAuth.UserInfo) -> String? {
        NebulaIdentityContract.normalizedNebulaId(userInfo.nebulaId)
            ?? (NebulaIdentityContract.isCanonicalNebulaId(userInfo.subject)
                ? NebulaIdentityContract.normalizedNebulaId(userInfo.subject)
                : nil)
    }

 // MARK: - 发布属性

    @Published var currentSession: AuthSession? {
        didSet {
            handleCurrentSessionChange(from: oldValue, to: currentSession)
        }
    }
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var showSignOutError = false
    @Published var selectedMethod: LoginMethod = AuthenticationViewModel.defaultLoginMethod
    @Published var isGuestMode = false
    @Published var supabaseNebulaId: String?
    @Published private(set) var nebulaIdentitySyncPhase: NebulaIdentitySyncPhase = .idle

 // Apple登录状态
    @Published var appleAuthorizationState: ASAuthorizationAppleIDProvider.CredentialState = .notFound

 // MARK: - 星云登录属性
    @Published var nebulaAccount: String = ""
    @Published var nebulaPassword: String = ""
    @Published var showMFAInput = false
    @Published var mfaToken: String = ""
    @Published var mfaCode: String = ""
    @Published var nebulaDisplayName: String = ""
    @Published var nebulaEmail: String = ""
    @Published var isNebulaRegistrationMode: Bool = false
    @Published var nebulaConfirmPassword: String = ""
    @Published var isUsernameAvailable: Bool? = nil
    @Published var usernameCheckInProgress: Bool = false

 // 手机号登录字段
    @Published var phoneNumber: String = ""
    @Published var phoneVerificationCode: String = ""
    @Published var isPhoneCodeSent = false
    @Published var phoneCodeCountdown = 0
    @Published var isPhoneRegistrationMode = false
    @Published var phoneDisplayName: String = ""
    @Published var phoneEmail: String = ""

 // 邮箱登录字段
    @Published var emailAddress: String = ""
    @Published var emailPassword: String = ""
    @Published var confirmPassword: String = ""
    @Published var isRegistrationMode = false
    @Published var emailVerificationSent = false
    @Published var rememberCredentials = false // 记住邮箱/账号偏好，不再保存原始密码
    @Published var showPasswordResetSheet = false
    @Published var resetPasswordValue: String = ""
    @Published var resetPasswordConfirmation: String = ""

 // MARK: - 安全验证属性
    @Published var requiresCaptcha: Bool = false  // 是否需要行为验证
    @Published var showCaptchaView: Bool = false  // 是否显示验证码视图
    @Published var captchaPassed: Bool = false    // 验证码是否通过

    private struct RiskCheckOutcome {
        let auditTicket: String?
        let deviceFingerprint: String
    }

    private static let localLoginThrottleWindow: TimeInterval = 10
    private static let localLoginThrottleMaxAttempts = 5
    private var localLoginAttemptTimestamps: [String: [Date]] = [:]

    private struct AuthRiskContext {
        let identifier: String
        let identifierType: RegistrationSecurityService.RegistrationContext.IdentifierType
        let attemptType: SupabaseService.RegistrationAttemptType
        let auditTicket: String?
        let deviceFingerprint: String
    }

    private struct SupabaseAuthCallbackResolution {
        let session: AuthSession
        let callbackType: SupabaseService.EmailAuthCallbackType?
    }

 // MARK: - 私有属性

    private let authService: AuthenticationService
    private var cancellables = Set<AnyCancellable>()
 // nonisolated(unsafe)：仅在 @MainActor 方法内读写（已串行化）；deinit 需从 nonisolated 上下文失效，实例已唯一引用，访问独占且安全。
    nonisolated(unsafe) private var phoneCodeTimer: Timer?
    private var browserAuthenticationSession: ASWebAuthenticationSession?
    private let nebulaPresentationContextProvider = NebulaBrowserPresentationContextProvider()
    private var sessionGeneration = 0
    private var activeNebulaIdentityLookupTask: Task<Void, Never>?
    private var pendingAppleSignInNonce: String?

 /// 当前设备指纹（懒加载）
    private var deviceFingerprint: String?

    private static let legacyPlaceholderDisplayNames: Set<String> = [
        "用户",
        "新用户",
        "游客用户",
        "Apple 用户",
        "Nebula 用户",
        "User",
        "New User",
        "Guest User",
        "Apple User",
        "Nebula User",
        "ユーザー",
        "新規ユーザー",
        "ゲストユーザー",
        "Appleユーザー",
        "Nebulaユーザー"
    ]

    /// 用于 UI 展示的“星云ID”（优先使用 Supabase user_metadata.nebula_id）
    var displayedNebulaId: String {
        NebulaIdentityContract.displayedNebulaId(
            resolvedNebulaId: supabaseNebulaId,
            sessionNebulaId: currentSession?.nebulaId,
            sessionUserIdentifier: currentSession?.userIdentifier
        )
    }

 // MARK: - 初始化

    init(authService: AuthenticationService = .shared) {
        self.authService = authService
        super.init()

 // 监听认证会话变化
        authService.sessionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.currentSession = session
            }
            .store(in: &cancellables)

        SupabaseConfiguration.shared.$isConfigured
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConfigured in
                guard let self else { return }
                if isConfigured {
                    self.scheduleNebulaIdentitySyncIfNeeded(reason: "supabase_config_ready")
                } else {
                    self.refreshNebulaIdentitySyncPhase()
                }
            }
            .store(in: &cancellables)

 // 检查Apple ID授权状态
        checkAppleIDCredentialState()

 // 加载已保存的登录凭据
        loadSavedCredentials()

 // 初始化设备指纹
        Task {
            do {
                try await loadDeviceFingerprint()
            } catch {
                SkyBridgeLogger.ui.error(
                    "❌ 设备指纹预加载失败: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

 // MARK: - 安全检查方法

 /// 加载设备指纹
    private func loadDeviceFingerprint() async throws {
        let fingerprint = try await SelfIdentityProvider.shared
            .generateRegistrationFingerprint(allowCreate: true)
        self.deviceFingerprint = fingerprint
        SkyBridgeLogger.ui.debugOnly("🔐 设备指纹已加载: \(fingerprint.prefix(16))...")
    }

    private func sessionSyncKey(for session: AuthSession?) -> String? {
        guard let session else { return nil }
        return "\(session.userIdentifier)|\(session.accessToken)"
    }

    private func handleCurrentSessionChange(from oldValue: AuthSession?, to newValue: AuthSession?) {
        let oldKey = sessionSyncKey(for: oldValue)
        let newKey = sessionSyncKey(for: newValue)

        if oldKey != newKey {
            sessionGeneration &+= 1
            activeNebulaIdentityLookupTask?.cancel()
        }

        guard let newValue else {
            supabaseNebulaId = nil
            nebulaIdentitySyncPhase = .idle
            return
        }

        supabaseNebulaId = NebulaIdentityContract.normalizedNebulaId(newValue.nebulaId)
        refreshNebulaIdentitySyncPhase(session: newValue)
        scheduleNebulaIdentitySyncIfNeeded(session: newValue, reason: "session_changed")
    }

    private func refreshNebulaIdentitySyncPhase(session: AuthSession? = nil) {
        guard let session = session ?? currentSession else {
            nebulaIdentitySyncPhase = .idle
            return
        }

        nebulaIdentitySyncPhase = NebulaIdentityContract.recommendedPhase(
            accessToken: session.accessToken,
            isSupabaseSession: SupabaseService.shared.isSupabaseAccessToken(session.accessToken),
            isSupabaseConfigured: SupabaseConfiguration.shared.isConfigured,
            resolvedNebulaId: supabaseNebulaId,
            sessionNebulaId: session.nebulaId
        )
    }

    private func scheduleNebulaIdentitySyncIfNeeded(
        session: AuthSession? = nil,
        reason: String,
        forceRemoteLoad: Bool = false
    ) {
        guard let session = session ?? currentSession else {
            nebulaIdentitySyncPhase = .idle
            return
        }

        let hasLocalNebulaId =
            NebulaIdentityContract.normalizedNebulaId(supabaseNebulaId) != nil ||
            NebulaIdentityContract.normalizedNebulaId(session.nebulaId) != nil

        refreshNebulaIdentitySyncPhase(session: session)

        guard session.accessToken != "pending_verification" else { return }
        guard SupabaseService.shared.isSupabaseAccessToken(session.accessToken) else { return }
        guard SupabaseConfiguration.shared.isConfigured else { return }
        guard forceRemoteLoad || !hasLocalNebulaId else { return }

        let expectedGeneration = sessionGeneration
        let expectedSessionKey = sessionSyncKey(for: session) ?? ""
        activeNebulaIdentityLookupTask?.cancel()
        nebulaIdentitySyncPhase = .loading

        activeNebulaIdentityLookupTask = Task { [weak self] in
            guard let self else { return }

            do {
                let nebulaId = try await SupabaseService.shared.getUserNebulaId(
                    userId: session.userIdentifier,
                    accessToken: session.accessToken
                )
                await self.finishNebulaIdentityLookup(
                    nebulaId: nebulaId,
                    expectedGeneration: expectedGeneration,
                    expectedSessionKey: expectedSessionKey,
                    reason: reason
                )
            } catch is CancellationError {
                await MainActor.run {
                    if NebulaIdentityContract.shouldApplyAsyncResult(
                        expectedGeneration: expectedGeneration,
                        currentGeneration: self.sessionGeneration,
                        expectedSessionKey: expectedSessionKey,
                        currentSessionKey: self.sessionSyncKey(for: self.currentSession)
                    ) {
                        self.refreshNebulaIdentitySyncPhase()
                    }
                }
            } catch {
                await MainActor.run {
                    self.failNebulaIdentityLookup(
                        error,
                        expectedGeneration: expectedGeneration,
                        expectedSessionKey: expectedSessionKey
                    )
                }
            }
        }
    }

    private func applyAuthenticatedSupabaseSession(
        _ session: AuthSession,
        displayNameOverride: String? = nil
    ) async {
        let updatedSession = AuthSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userIdentifier: session.userIdentifier,
            nebulaId: session.nebulaId,
            displayName: displayNameOverride ?? session.displayName,
            avatarURL: session.avatarURL,
            issuedAt: session.issuedAt
        )

        do {
            try await authService.updateSession(updatedSession)
            currentSession = updatedSession
        } catch {
            SkyBridgeLogger.ui.error("❌ [AuthenticationViewModel] 注册后持久化会话失败: \(error.localizedDescription, privacy: .private)")
            errorMessage = error.localizedDescription
            return
        }

        await loadUserAvatarAfterLogin(session: updatedSession)
    }

    private func preferredSessionDisplayName(_ session: AuthSession, fallback: String) -> String {
        let trimmedDisplayName = session.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isPlaceholderDisplayName(trimmedDisplayName) {
            return trimmedDisplayName
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? t("auth.displayName.default.user") : trimmedFallback
    }

    private func shouldBootstrapPhoneRegistration(
        currentUserProfile: SupabaseService.CurrentUserProfile?
    ) -> Bool {
        guard let currentUserProfile else {
            return false
        }

        let hasNebulaId = currentUserProfile.nebulaId?.isEmpty == false
        let hasEmail = currentUserProfile.email?.isEmpty == false
        let trimmedDisplayName = currentUserProfile.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasMeaningfulDisplayName = !isPlaceholderDisplayName(trimmedDisplayName)

        return !hasNebulaId && !hasEmail && !hasMeaningfulDisplayName
    }

    private func isPlaceholderDisplayName(_ displayName: String?) -> Bool {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }

        let localizedPlaceholders = Set([
            t("auth.displayName.default.user"),
            t("auth.displayName.default.newUser"),
            t("auth.displayName.default.guest"),
            t("auth.displayName.default.apple"),
            t("auth.displayName.default.nebula")
        ].filter { !$0.isEmpty })

        return localizedPlaceholders.contains(trimmed)
            || Self.legacyPlaceholderDisplayNames.contains(trimmed)
    }

    private func emailDisplayNameFallback(from email: String) -> String {
        let localPart = email
            .components(separatedBy: "@")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return localPart.isEmpty ? t("auth.displayName.default.user") : localPart
    }

    private func finishNebulaIdentityLookup(
        nebulaId: String?,
        expectedGeneration: Int,
        expectedSessionKey: String,
        reason: String
    ) async {
        guard NebulaIdentityContract.shouldApplyAsyncResult(
            expectedGeneration: expectedGeneration,
            currentGeneration: sessionGeneration,
            expectedSessionKey: expectedSessionKey,
            currentSessionKey: sessionSyncKey(for: currentSession)
        ) else {
            return
        }

        let normalizedNebulaId = NebulaIdentityContract.normalizedNebulaId(nebulaId)
        if let normalizedNebulaId {
            supabaseNebulaId = normalizedNebulaId
            nebulaIdentitySyncPhase = .hydrated
            await persistNebulaIdentityIfNeeded(normalizedNebulaId, reason: reason)
        } else {
            refreshNebulaIdentitySyncPhase()
        }
        activeNebulaIdentityLookupTask = nil
    }

    private func failNebulaIdentityLookup(
        _ error: Error,
        expectedGeneration: Int,
        expectedSessionKey: String
    ) {
        guard NebulaIdentityContract.shouldApplyAsyncResult(
            expectedGeneration: expectedGeneration,
            currentGeneration: sessionGeneration,
            expectedSessionKey: expectedSessionKey,
            currentSessionKey: sessionSyncKey(for: currentSession)
        ) else {
            return
        }

        if NebulaIdentityContract.normalizedNebulaId(supabaseNebulaId) != nil ||
            NebulaIdentityContract.normalizedNebulaId(currentSession?.nebulaId) != nil {
            nebulaIdentitySyncPhase = .hydrated
        } else {
            refreshNebulaIdentitySyncPhase()
        }
        activeNebulaIdentityLookupTask = nil
        SkyBridgeLogger.ui.debugOnly("ℹ️ [AuthenticationViewModel] NebulaID 加载失败（忽略）: \(error.localizedDescription)")
    }

    private func persistNebulaIdentityIfNeeded(_ nebulaId: String, reason: String) async {
        guard let session = currentSession else { return }
        guard NebulaIdentityContract.normalizedNebulaId(session.nebulaId) != nebulaId else { return }

        let updatedSession = AuthSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userIdentifier: session.userIdentifier,
            nebulaId: nebulaId,
            displayName: session.displayName,
            avatarURL: session.avatarURL,
            issuedAt: session.issuedAt
        )

        do {
            try await authService.updateSession(updatedSession)
            SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] NebulaID 已回写持久化会话: \(reason)")
        } catch {
            SkyBridgeLogger.ui.error("⚠️ [AuthenticationViewModel] NebulaID 会话回写失败: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func formattedRiskMessage(
        reason: String?,
        retryAfter: Int?,
        fallback: String
    ) -> String {
        let base = reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? reason!.trimmingCharacters(in: .whitespacesAndNewlines)
            : fallback

        guard let retryAfter, retryAfter > 0 else {
            return base
        }

        if retryAfter >= 3600 {
            let hours = Int(ceil(Double(retryAfter) / 3600.0))
            return formatted("auth.security.retryAfter.hours", base, hours)
        }

        let minutes = max(1, Int(ceil(Double(retryAfter) / 60.0)))
        return formatted("auth.security.retryAfter.minutes", base, minutes)
    }

    private static func remoteIdentifierType(
        from identifierType: RegistrationSecurityService.RegistrationContext.IdentifierType
    ) -> SupabaseService.RegistrationIdentifierType {
        switch identifierType {
        case .email:
            return .email
        case .phone:
            return .phone
        case .username:
            return .username
        }
    }

    private static func localAttemptType(
        from attemptType: SupabaseService.RegistrationAttemptType
    ) -> RegistrationSecurityService.AttemptType {
        switch attemptType {
        case .register:
            return .register
        case .verifyCode:
            return .verifyCode
        case .login:
            return .login
        }
    }

    private static var allowsRemoteRiskDegrade: Bool {
        #if DEBUG || SKYBRIDGE_TESTING
        let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_ALLOW_AUTH_RISK_DEGRADE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return raw == "1" || raw == "true" || raw == "yes"
        #else
        return false
        #endif
    }

    private func enforceLocalLoginThrottle(
        identifier: String,
        identifierType: RegistrationSecurityService.RegistrationContext.IdentifierType
    ) -> Bool {
        let normalizedIdentifier: String
        switch identifierType {
        case .email, .username:
            normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case .phone:
            normalizedIdentifier = identifier.filter { $0.isNumber || $0 == "+" }
        }
        let throttleKey = "\(identifierType.rawValue):\(normalizedIdentifier)"
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.localLoginThrottleWindow)
        var timestamps = localLoginAttemptTimestamps[throttleKey, default: []]
            .filter { $0 > cutoff }

        guard timestamps.count < Self.localLoginThrottleMaxAttempts else {
            localLoginAttemptTimestamps[throttleKey] = timestamps
            let message = t("auth.security.rateLimited.local")
            SkyBridgeLogger.ui.warning("⚠️ 本地登录软限流触发: \(identifierType.rawValue)")
            errorMessage = message
            return false
        }

        timestamps.append(now)
        localLoginAttemptTimestamps[throttleKey] = timestamps
        return true
    }

    private static let emailConfirmationRedirectURL = URL(string: "skybridge://auth/email-callback")!
    private static let passwordRecoveryRedirectURL = URL(string: "skybridge://auth/reset-password")!
    private static let appleOAuthRedirectURL = URL(string: "skybridge://auth/apple-callback")!
    private static let appleBrowserAuditIdentifier = "apple_browser_oauth"

    private func ensureDeviceFingerprint() async throws -> String {
        if let deviceFingerprint {
            return deviceFingerprint
        }
        try await loadDeviceFingerprint()
        guard let deviceFingerprint else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Registration fingerprint was not published after authority resolution"
            )
        }
        return deviceFingerprint
    }

 /// 执行认证前安全检查
 /// - Parameters:
 /// - identifier: 用户标识（手机号/邮箱）
 /// - identifierType: 标识类型
 /// - attemptType: 审计用途的尝试类型
 /// - Returns: 是否允许继续
    private func performSecurityCheck(
        identifier: String,
        identifierType: RegistrationSecurityService.RegistrationContext.IdentifierType,
        attemptType: SupabaseService.RegistrationAttemptType = .register
    ) async -> RiskCheckOutcome? {
        if attemptType == .login {
            guard enforceLocalLoginThrottle(identifier: identifier, identifierType: identifierType) else {
                return nil
            }
            SkyBridgeLogger.ui.info("🔐 登录路径已通过本地短窗口软限流，继续执行服务端登录风控")
        }

        let fingerprint: String
        do {
            fingerprint = try await ensureDeviceFingerprint()
        } catch {
            SkyBridgeLogger.ui.error("❌ 设备指纹获取失败")
            errorMessage = t("auth.security.deviceVerificationFailed")
            return nil
        }

        let context = RegistrationSecurityService.RegistrationContext(
            ip: "client",
            deviceFingerprint: fingerprint,
            identifier: identifier,
            identifierType: identifierType,
            attemptType: Self.localAttemptType(from: attemptType)
        )

        let localResult = await RegistrationSecurityService.shared.canRegister(context: context)
        if !localResult.allowed {
            let message = formattedRiskMessage(
                reason: localResult.reason,
                retryAfter: localResult.retryAfter.flatMap { Int($0) },
                fallback: t("auth.security.rateLimited.local")
            )
            SkyBridgeLogger.ui.warning("⚠️ 本地认证风控拒绝请求: \(message)")
            errorMessage = message
            return nil
        }

        if localResult.requiresCaptcha {
            requiresCaptcha = true
            if !captchaPassed {
                SkyBridgeLogger.ui.info("🔒 本地认证风控要求行为验证")
                errorMessage = localResult.reason ?? t("auth.security.captchaRequired")
                showCaptchaView = true
                return nil
            }
        }

        do {
            let remoteResult = try await SupabaseService.shared.assessRegistrationRisk(
                identifier: identifier,
                identifierType: Self.remoteIdentifierType(from: identifierType),
                deviceFingerprint: fingerprint,
                attemptType: attemptType
            )

            if !remoteResult.allowed {
                let message = formattedRiskMessage(
                    reason: remoteResult.reason,
                    retryAfter: remoteResult.retryAfter,
                    fallback: t("auth.security.rateLimited.remote")
                )
                SkyBridgeLogger.ui.warning("⚠️ 服务端认证风控拒绝请求: \(message)")
                requiresCaptcha = false
                showCaptchaView = false
                captchaPassed = false
                errorMessage = message
                return nil
            }

            if remoteResult.requiresCaptcha {
                requiresCaptcha = true
                if !captchaPassed {
                    SkyBridgeLogger.ui.info("🔒 服务端认证风控要求行为验证")
                    errorMessage = remoteResult.reason ?? t("auth.security.captchaRequired")
                    showCaptchaView = true
                    return nil
                }
            }

            return RiskCheckOutcome(
                auditTicket: remoteResult.auditTicket,
                deviceFingerprint: fingerprint
            )
        } catch {
            let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
            if attemptType != .login, Self.allowsRemoteRiskDegrade {
                SkyBridgeLogger.ui.warning("⚠️ 服务端认证风控不可用，按配置回退本地防护: \(message)")
                return RiskCheckOutcome(
                    auditTicket: nil,
                    deviceFingerprint: fingerprint
                )
            }

            let userFacingMessage = t("auth.security.checkUnavailable")
            SkyBridgeLogger.ui.error("❌ 服务端认证风控不可用，已拒绝继续请求: \(message, privacy: .private)")
            errorMessage = userFacingMessage
            return nil
        }
    }

 /// 处理行为验证完成
    func onCaptchaVerificationComplete(success: Bool, error: String?) {
        captchaPassed = success
        showCaptchaView = false

        errorMessage = success ? nil : (error ?? t("auth.captcha.verificationFailed"))
    }

 /// 记录注册/验证码尝试
    private func recordRegistrationAttempt(
        identifier: String,
        identifierType: RegistrationSecurityService.RegistrationContext.IdentifierType,
        deviceFingerprint fingerprint: String,
        attemptType: SupabaseService.RegistrationAttemptType = .register,
        success: Bool,
        failureReason: String? = nil,
        captchaRequired: Bool = false,
        captchaPassed: Bool = false,
        auditTicket: String? = nil
    ) async {
        let context = RegistrationSecurityService.RegistrationContext(
            ip: "client",
            deviceFingerprint: fingerprint,
            identifier: identifier,
            identifierType: identifierType,
            attemptType: Self.localAttemptType(from: attemptType)
        )

        await RegistrationSecurityService.shared.recordAttempt(
            context: context,
            success: success,
            failureReason: failureReason
        )

        await SupabaseService.shared.recordRegistrationAttempt(
            identifier: identifier,
            identifierType: Self.remoteIdentifierType(from: identifierType),
            deviceFingerprint: fingerprint,
            attemptType: attemptType,
            success: success,
            failureReason: failureReason,
            captchaRequired: captchaRequired,
            captchaPassed: captchaPassed,
            auditTicket: auditTicket,
            metadata: [
                "client": "SkyBridge Compass Pro",
                "attempt_type": attemptType.rawValue
            ]
        )
    }

 // MARK: - Apple登录

 /// 检查Apple ID凭据状态
    private func checkAppleIDCredentialState() {
        guard Self.nativeAppleSignInRuntimeReady else {
            appleAuthorizationState = .notFound
            return
        }

        guard let userID = KeychainManager.shared.retrieveAppleUserID() else {
            appleAuthorizationState = .notFound
            return
        }
        let provider = ASAuthorizationAppleIDProvider()
        provider.getCredentialState(forUserID: userID) { [weak self] state, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    self.appleAuthorizationState = .notFound
                    return
                }
                self.appleAuthorizationState = state
                if state == .revoked || state == .notFound {
                    KeychainManager.shared.deleteAppleUserID()
                }
            }
        }
    }

    func configureAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard Self.appleSignInLaunchReady, Self.nativeAppleSignInRuntimeReady else {
            pendingAppleSignInNonce = nil
            return
        }
        let rawNonce = Self.generateAppleSignInNonce()
        pendingAppleSignInNonce = rawNonce
        request.nonce = Self.sha256(rawNonce)
    }

    func loginWithApple(captchaToken: String? = nil) async {
        guard Self.appleSignInLaunchReady else {
            errorMessage = LocalizationManager.shared.localizedString("auth.apple.unavailable")
            return
        }

        guard !Self.nativeAppleSignInRuntimeReady else {
            errorMessage = LocalizationManager.shared.localizedString("auth.apple.native.enabled")
            return
        }

        guard let riskOutcome = await performSecurityCheck(
            identifier: Self.appleBrowserAuditIdentifier,
            identifierType: .username,
            attemptType: .login
        ) else {
            return
        }

        let riskContext = AuthRiskContext(
            identifier: Self.appleBrowserAuditIdentifier,
            identifierType: .username,
            attemptType: .login,
            auditTicket: riskOutcome.auditTicket,
            deviceFingerprint: riskOutcome.deviceFingerprint
        )

        await performAuthenticationTask(riskContext: riskContext) {
            try await self.loginWithAppleUsingBrowser(captchaToken: captchaToken)
        }
    }

 /// 处理Apple登录授权结果
    func handleAppleAuthorization(_ authorization: ASAuthorization, captchaToken: String? = nil) async {
        guard Self.appleSignInLaunchReady else {
            await MainActor.run {
                self.errorMessage = LocalizationManager.shared.localizedString("auth.apple.unavailable")
            }
            return
        }

        guard Self.nativeAppleSignInRuntimeReady else {
            await MainActor.run {
                self.errorMessage = LocalizationManager.shared.localizedString("auth.apple.web.only")
            }
            return
        }

        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            await MainActor.run {
                self.errorMessage = LocalizationManager.shared.localizedString("auth.apple.credential.missing")
            }
            return
        }

        guard let identityToken = appleIDCredential.identityToken else {
            await MainActor.run {
                self.errorMessage = LocalizationManager.shared.localizedString("auth.apple.identityToken.missing")
            }
            return
        }

        guard let rawNonce = pendingAppleSignInNonce else {
            await MainActor.run {
                self.errorMessage = LocalizationManager.shared.localizedString("auth.apple.context.expired")
            }
            return
        }

        let auditIdentifier = Self.appleAuditIdentifier(for: appleIDCredential)
        pendingAppleSignInNonce = nil

        guard let riskOutcome = await performSecurityCheck(
            identifier: auditIdentifier,
            identifierType: .username,
            attemptType: .login
        ) else {
            return
        }

        try? KeychainManager.shared.storeAppleUserID(appleIDCredential.user)

        let riskContext = AuthRiskContext(
            identifier: auditIdentifier,
            identifierType: .username,
            attemptType: .login,
            auditTicket: riskOutcome.auditTicket,
            deviceFingerprint: riskOutcome.deviceFingerprint
        )

        await performAuthenticationTask(riskContext: riskContext) {
            let session = try await self.authService.authenticateWithApple(
                identityToken: identityToken,
                authorizationCode: appleIDCredential.authorizationCode,
                rawNonce: rawNonce,
                captchaToken: captchaToken
            )
            return await self.applyAppleProfileIfNeeded(appleIDCredential, to: session)
        }
    }

 // MARK: - 星云登录

    /// 星云登录
    func loginWithNebula() async {
        await performAuthenticationTask {
            try await self.loginWithNebulaUsingBrowser()
        }
    }

    private func loginWithNebulaDirectCredentials() async throws -> AuthSession {
        guard !nebulaAccount.isEmpty && !nebulaPassword.isEmpty else {
            throw NSError(
                domain: "Nebula",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: t("auth.nebula.credentials.required")]
            )
        }

        return try await self.authService.authenticateWithNebula(
            username: self.nebulaAccount,
            password: self.nebulaPassword
        )
    }

    private func loginWithNebulaUsingBrowser() async throws -> AuthSession {
        let authorizationRequest = try NebulaPublicClientOAuth.shared.makeAuthorizationRequest(
            redirectURI: "skybridge://auth/nebula"
        )
        return try await completeNebulaBrowserAuthorization(authorizationRequest)
    }

    private func loginWithAppleUsingBrowser(captchaToken: String? = nil) async throws -> AuthSession {
        let authorizationURL = try SupabaseService.shared.makeAppleOAuthAuthorizationURL(
            redirectTo: Self.appleOAuthRedirectURL,
            captchaToken: captchaToken
        )
        let callbackURL = try await startBrowserAuthenticationSession(
            url: authorizationURL,
            callbackScheme: "skybridge",
            flowIdentifier: "apple_oauth",
            flowDisplayName: t("auth.browser.flow.apple.name")
        )

        guard let resolution = try await resolveSupabaseAuthCallback(callbackURL) else {
            throw NSError(
                domain: "AppleOAuth",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: t("auth.apple.browser.callbackSessionMissing")]
            )
        }

        let session = resolution.session
        let fallbackDisplayName = session.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? t("auth.displayName.default.apple")
            : session.displayName
        let resolvedDisplayName = preferredSessionDisplayName(session, fallback: fallbackDisplayName)
        let resolvedSession = AuthSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userIdentifier: session.userIdentifier,
            nebulaId: session.nebulaId,
            displayName: resolvedDisplayName,
            avatarURL: session.avatarURL,
            issuedAt: session.issuedAt
        )

        try await authService.updateSession(resolvedSession)
        return resolvedSession
    }

    private func registerWithNebulaUsingBrowser() async throws -> AuthSession {
        let authorizationRequest = try NebulaPublicClientOAuth.shared.makeRegistrationAuthorizationRequest(
            redirectURI: "skybridge://auth/nebula"
        )
        return try await completeNebulaBrowserAuthorization(authorizationRequest)
    }

    private func completeNebulaBrowserAuthorization(_ authorizationRequest: NebulaPublicClientOAuth.AuthorizationRequest) async throws -> AuthSession {
        let callbackURL = try await startBrowserAuthenticationSession(
            url: authorizationRequest.authorizationURL,
            callbackScheme: "skybridge",
            flowIdentifier: "nebula_oauth",
            flowDisplayName: t("auth.browser.flow.nebula.name")
        )

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: "Nebula",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: t("auth.nebula.browser.invalidCallback")]
            )
        }

        let queryItems = (components.queryItems ?? []).reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" }
        if let error = queryItems["error"], !error.isEmpty {
            let description = queryItems["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error
            throw NSError(domain: "Nebula", code: -3, userInfo: [NSLocalizedDescriptionKey: description])
        }

        let returnedState = queryItems["state"] ?? ""
        guard returnedState == authorizationRequest.state else {
            throw NSError(
                domain: "Nebula",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: t("auth.nebula.browser.stateMismatch")]
            )
        }

        guard let code = queryItems["code"], !code.isEmpty else {
            throw NSError(
                domain: "Nebula",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: t("auth.nebula.browser.authorizationCodeMissing")]
            )
        }

        let tokenResponse = try await NebulaPublicClientOAuth.shared.exchangeAuthorizationCode(
            code,
            authorizationRequest: authorizationRequest
        )
        let userInfo = try await NebulaPublicClientOAuth.shared.fetchUserInfo(accessToken: tokenResponse.accessToken)

        let displayName = userInfo.name ?? userInfo.preferredUsername ?? userInfo.email ?? t("auth.displayName.default.nebula")
        let nebulaId = Self.resolvedNebulaId(from: userInfo)
        let session = AuthSession(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            userIdentifier: userInfo.subject,
            nebulaId: nebulaId,
            displayName: displayName,
            avatarURL: userInfo.picture,
            issuedAt: Date()
        )
        try await authService.updateSession(session)
        return session
    }

    private func startBrowserAuthenticationSession(
        url: URL,
        callbackScheme: String,
        flowIdentifier: String,
        flowDisplayName: String
    ) async throws -> URL {
        let cancelledMessage = formatted("auth.browser.flow.cancelled", flowDisplayName)
        let startFailedMessage = formatted("auth.browser.flow.startFailed", flowDisplayName)

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = BrowserAuthenticationContinuationBox(continuation)
            let completionHandler = Self.makeBrowserAuthenticationCompletionHandler(
                flowIdentifier: flowIdentifier,
                cancelledMessage: cancelledMessage,
                continuationBox: continuationBox,
                viewModel: self
            )
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme,
                completionHandler: completionHandler
            )
            session.presentationContextProvider = nebulaPresentationContextProvider
            session.prefersEphemeralWebBrowserSession = false
            self.browserAuthenticationSession = session

            if !session.start() {
                self.browserAuthenticationSession = nil
                continuationBox.resume(
                    throwing: NSError(
                        domain: flowIdentifier,
                        code: -7,
                        userInfo: [NSLocalizedDescriptionKey: startFailedMessage]
                    )
                )
            }
        }
    }

    private nonisolated static func makeBrowserAuthenticationCompletionHandler(
        flowIdentifier: String,
        cancelledMessage: String,
        continuationBox: BrowserAuthenticationContinuationBox,
        viewModel: AuthenticationViewModel?
    ) -> (URL?, Error?) -> Void {
        { [weak viewModel] callbackURL, error in
            Task { @MainActor [weak viewModel] in
                viewModel?.browserAuthenticationSession = nil
            }

            if let callbackURL {
                continuationBox.resume(returning: callbackURL)
            } else if let error {
                continuationBox.resume(throwing: error)
            } else {
                continuationBox.resume(
                    throwing: NSError(
                        domain: flowIdentifier,
                        code: -6,
                        userInfo: [NSLocalizedDescriptionKey: cancelledMessage]
                    )
                )
            }
        }
    }

 /// 验证星云MFA
    @MainActor
    func verifyMFA() async {
        guard !mfaToken.isEmpty && !mfaCode.isEmpty else {
            errorMessage = t("auth.code.required")
            return
        }

        isProcessing = true
        errorMessage = nil

        do {
            let session = try await authService.verifyNebulaMFA(
                mfaToken: mfaToken,
                code: mfaCode
            )

            currentSession = session
            await loadUserAvatarAfterLogin(session: session)
            showMFAInput = false
            mfaToken = ""
            mfaCode = ""
        } catch {
            errorMessage = formatted("auth.mfa.verificationFailedWithReason", error.localizedDescription)
        }

        isProcessing = false
    }

 // MARK: - 手机号登录

 /// 发送手机验证码
    func sendPhoneVerificationCode(captchaToken: String? = nil) async {
        await sendPhoneCode(isResend: false, captchaToken: captchaToken)
    }

 /// 手机号登录
    func loginWithPhone() async {
        let sanitizedPhone = sanitizePhoneNumber(phoneNumber)

        guard isValidPhoneNumber(sanitizedPhone) else {
            errorMessage = t("auth.phone.invalid")
            return
        }

        guard !phoneVerificationCode.isEmpty else {
            errorMessage = t("auth.code.required")
            return
        }

        guard let riskOutcome = await performSecurityCheck(
            identifier: sanitizedPhone,
            identifierType: .phone,
            attemptType: .login
        ) else {
            return
        }

        phoneNumber = sanitizedPhone

        await performAuthenticationTask(
            riskContext: AuthRiskContext(
                identifier: sanitizedPhone,
                identifierType: .phone,
                attemptType: .login,
                auditTicket: riskOutcome.auditTicket,
                deviceFingerprint: riskOutcome.deviceFingerprint
            )
        ) {
            try await self.authService.loginPhone(
                number: sanitizedPhone,
                code: self.phoneVerificationCode
            )
        }
    }

 /// 重新发送验证码（收不到验证码）
    func resendPhoneVerificationCode(captchaToken: String? = nil) async {
        await sendPhoneCode(isResend: true, captchaToken: captchaToken)
    }

 /// 通过智能通道发送验证码（含重试/降级/风控）
    private func sendPhoneCode(isResend: Bool, captchaToken: String? = nil) async {
        guard isValidPhoneNumber(phoneNumber) else {
            await MainActor.run { errorMessage = t("auth.phone.invalid") }
            return
        }

        await MainActor.run {
            isProcessing = true
            errorMessage = nil
        }

        await MainActor.run {
            requiresCaptcha = false
            showCaptchaView = false
        }

        guard let riskOutcome = await performSecurityCheck(
            identifier: sanitizePhoneNumber(phoneNumber),
            identifierType: .phone,
            attemptType: .verifyCode
        ) else {
            await MainActor.run {
                isProcessing = false
            }
            return
        }

        do {
            _ = try await authService.sendPhoneVerificationCode(
                to: phoneNumber,
                captchaToken: captchaToken
            )
            await recordRegistrationAttempt(
                identifier: sanitizePhoneNumber(phoneNumber),
                identifierType: .phone,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                attemptType: .verifyCode,
                success: true,
                auditTicket: riskOutcome.auditTicket
            )
            await MainActor.run {
                isProcessing = false
                isPhoneCodeSent = true
                startPhoneCodeCountdown()
                captchaPassed = false
                errorMessage = isResend ? t("auth.phone.code.resent") : t("auth.phone.code.sent")
            }
        } catch {
            await recordRegistrationAttempt(
                identifier: sanitizePhoneNumber(phoneNumber),
                identifierType: .phone,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                attemptType: .verifyCode,
                success: false,
                failureReason: error.localizedDescription,
                auditTicket: riskOutcome.auditTicket
            )
            await MainActor.run {
                isProcessing = false
                errorMessage = isResend
                    ? self.formatted("auth.phone.code.resendFailedWithReason", error.localizedDescription)
                    : self.formatted("auth.phone.code.sendFailedWithReason", error.localizedDescription)
            }
        }
    }

 /// 开始验证码倒计时
    private func startPhoneCodeCountdown() {
        phoneCodeCountdown = 60
        phoneCodeTimer?.invalidate()
        phoneCodeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
 // 计时器调度在 @MainActor 的主 run-loop 上，此闭包体已在主线程执行：
 // 在此同步失效孤儿计时器，避免把非 Sendable 的 timer 送入 main.async 闭包（Swift 6 数据竞争诊断）。
            guard self != nil else {
                timer.invalidate()
                return
            }
            DispatchQueue.main.async {
                guard let self = self else { return }

                if self.phoneCodeCountdown > 0 {
                    self.phoneCodeCountdown -= 1
                } else {
                    self.phoneCodeTimer?.invalidate()
                    self.phoneCodeTimer = nil
                    self.isPhoneCodeSent = false
                }
            }
        }
    }

 /// 清空手机号登录字段
    private func clearPhoneFields() {
        phoneNumber = ""
        phoneVerificationCode = ""
        phoneDisplayName = ""
        phoneEmail = ""
        isPhoneCodeSent = false
        phoneCodeCountdown = 0
    }

 /// 验证手机号格式（支持国际号码）
 /// - Parameter phone: 手机号码
 /// - Returns: 是否有效
    private func isValidPhoneNumber(_ phone: String) -> Bool {
 // 清洗输入
        let sanitized = sanitizePhoneNumber(phone)

 // E.164 格式检查（国际手机号）
        let internationalRegex = "^\\+[1-9]\\d{1,14}$"
        let internationalPredicate = NSPredicate(format: "SELF MATCHES %@", internationalRegex)

 // 中国大陆手机号格式
        let chinaRegex = "^1[3-9]\\d{9}$"
        let chinaPredicate = NSPredicate(format: "SELF MATCHES %@", chinaRegex)

        return internationalPredicate.evaluate(with: sanitized) || chinaPredicate.evaluate(with: sanitized)
    }

 // MARK: - 输入清洗方法

 /// 清洗手机号输入
    private func sanitizePhoneNumber(_ input: String) -> String {
        var result = input
 // 去除所有空格和分隔符
        result = result.replacingOccurrences(of: " ", with: "")
        result = result.replacingOccurrences(of: "-", with: "")
        result = result.replacingOccurrences(of: "(", with: "")
        result = result.replacingOccurrences(of: ")", with: "")
 // 保留数字和+号
        result = result.filter { $0.isNumber || $0 == "+" }
        return result
    }

 /// 清洗邮箱输入
    private func sanitizeEmail(_ input: String) -> String {
        var result = input
 // 去除首尾空格
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
 // 转换为小写
        result = result.lowercased()
 // 移除不可见字符
        result = result.filter { !$0.isNewline && $0 != "\t" && $0 != "\r" }
        return result
    }

 /// 清洗用户名输入
    private func sanitizeUsername(_ input: String) -> String {
        var result = input
 // 去除首尾空格
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
 // 将连续空格替换为单个空格
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
 // 移除不可见字符
        result = result.filter { !$0.isNewline && $0 != "\t" && $0 != "\r" }
 // 移除潜在的SQL注入/XSS字符
        let dangerousChars = CharacterSet(charactersIn: "<>\"'`;\\")
        result = result.unicodeScalars.filter { !dangerousChars.contains($0) }.map { String($0) }.joined()
 // 转换为小写（用户名不区分大小写）
        result = result.lowercased()
        return result
    }

 /// 清洗密码输入（仅去除首尾空格）
    private func sanitizePassword(_ input: String) -> String {
        return input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

 // MARK: - 密码强度验证

 /// 密码强度级别
    enum PasswordStrength: Int, Comparable {
        case weak = 1
        case medium = 2
        case strong = 3
        case veryStrong = 4

        static func < (lhs: PasswordStrength, rhs: PasswordStrength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        @MainActor
        var description: String {
            switch self {
            case .weak: return LocalizationManager.shared.localizedString("auth.password.strength.weak")
            case .medium: return LocalizationManager.shared.localizedString("auth.password.strength.medium")
            case .strong: return LocalizationManager.shared.localizedString("auth.password.strength.strong")
            case .veryStrong: return LocalizationManager.shared.localizedString("auth.password.strength.veryStrong")
            }
        }

        var color: Color {
            switch self {
            case .weak: return .red
            case .medium: return .orange
            case .strong: return .green
            case .veryStrong: return .blue
            }
        }
    }

 /// 评估密码强度
 /// - Parameter password: 密码
 /// - Returns: 密码强度
    func evaluatePasswordStrength(_ password: String) -> PasswordStrength {
        var score = 0

 // 长度评分
        if password.count >= 8 { score += 1 }
        if password.count >= 12 { score += 1 }
        if password.count >= 16 { score += 1 }

 // 复杂度评分
        if password.contains(where: { $0.isLowercase }) { score += 1 }
        if password.contains(where: { $0.isUppercase }) { score += 1 }
        if password.contains(where: { $0.isNumber }) { score += 1 }
        if password.contains(where: { "!@#$%^&*()_+-=[]{}|;':\",./<>?".contains($0) }) { score += 1 }

 // 映射到强度级别
        switch score {
        case 0...2: return .weak
        case 3...4: return .medium
        case 5...6: return .strong
        default: return .veryStrong
        }
    }

 /// 验证密码是否满足强度要求
 /// - Parameters:
 /// - password: 密码
 /// - minimumStrength: 最低强度要求
 /// - Returns: (是否通过, 强度, 错误信息)
    func validatePasswordStrength(_ password: String, minimumStrength: PasswordStrength = .medium) -> (valid: Bool, strength: PasswordStrength, error: String?) {
        let sanitized = sanitizePassword(password)

 // 最小长度检查
        if sanitized.count < 8 {
            return (false, .weak, t("auth.password.tooShort"))
        }

 // 最大长度检查
        if sanitized.count > 128 {
            return (false, .weak, t("auth.password.tooLong"))
        }

        let strength = evaluatePasswordStrength(sanitized)

        if strength < minimumStrength {
            var requirements: [String] = []
            if !sanitized.contains(where: { $0.isUppercase }) {
                requirements.append(t("auth.password.requirement.uppercase"))
            }
            if !sanitized.contains(where: { $0.isLowercase }) {
                requirements.append(t("auth.password.requirement.lowercase"))
            }
            if !sanitized.contains(where: { $0.isNumber }) {
                requirements.append(t("auth.password.requirement.number"))
            }
            if !sanitized.contains(where: { "!@#$%^&*()_+-=[]{}|;':\",./<>?".contains($0) }) {
                requirements.append(t("auth.password.requirement.specialCharacter"))
            }

            if requirements.isEmpty {
                return (false, strength, t("auth.password.strengthInsufficient"))
            }

            let joinedRequirements = requirements.joined(separator: t("auth.list.separator"))
            return (
                false,
                strength,
                formatted("auth.password.strengthInsufficientWithSuggestions", joinedRequirements)
            )
        }

        return (true, strength, nil)
    }

 /// 验证用户名格式
 /// - Parameter username: 用户名
 /// - Returns: (是否通过, 错误信息)
    func validateUsername(_ username: String) -> (valid: Bool, error: String?) {
        let sanitized = sanitizeUsername(username)

 // 长度检查
        if sanitized.count < 4 {
            return (false, t("auth.username.tooShort"))
        }

        if sanitized.count > 20 {
            return (false, t("auth.username.tooLong"))
        }

 // 字符检查：只允许字母、数字和下划线
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let invalidChars = sanitized.unicodeScalars.filter { !allowedCharacters.contains($0) }
        if !invalidChars.isEmpty {
            return (false, t("auth.username.invalidCharacters"))
        }

 // 保留名检查
        let reservedNames: Set<String> = ["admin", "root", "system", "support", "help", "test", "null", "undefined"]
        if reservedNames.contains(sanitized) {
            return (false, t("auth.username.reserved"))
        }

 // 不能以数字开头
        if let first = sanitized.first, first.isNumber {
            return (false, t("auth.username.cannotStartWithNumber"))
        }

        return (true, nil)
    }

 // MARK: - 邮箱登录/注册

 /// 切换登录/注册模式
    func toggleRegistrationMode() {
        isRegistrationMode.toggle()
        errorMessage = nil
        clearEmailFields()
    }

 /// 邮件注册（增强安全校验）
    func registerWithEmail(captchaToken: String? = nil) async {
        SkyBridgeLogger.ui.debugOnly("🔧 [注册流程] 开始邮箱注册流程")
        SkyBridgeLogger.ui.debugOnly("   邮箱: \(emailAddress)")
        SkyBridgeLogger.ui.debugOnly("   密码长度: \(emailPassword.count)")

 // 清洗输入
        let sanitizedEmail = sanitizeEmail(emailAddress)
        let sanitizedPassword = sanitizePassword(emailPassword)
        let sanitizedConfirmPassword = sanitizePassword(confirmPassword)

 // 邮箱格式校验
        guard isValidEmail(sanitizedEmail) else {
            SkyBridgeLogger.ui.error("❌ [注册流程] 邮箱地址无效: \(self.emailAddress, privacy: .private)")
            errorMessage = t("auth.email.invalid")
            return
        }

 // 检查一次性邮箱
        guard !isDisposableEmail(sanitizedEmail) else {
            SkyBridgeLogger.ui.error("❌ [注册流程] 一次性邮箱被拦截: \(self.emailAddress, privacy: .private)")
            errorMessage = t("auth.email.disposableNotSupported")
            return
        }

 // 密码强度校验
        let passwordValidation = validatePasswordStrength(sanitizedPassword, minimumStrength: .medium)
        guard passwordValidation.valid else {
            SkyBridgeLogger.ui.error("❌ [注册流程] 密码强度不足: \(passwordValidation.strength.description)")
            errorMessage = passwordValidation.error ?? t("auth.password.weakGeneric")
            return
        }

 // 密码确认校验
        guard sanitizedPassword == sanitizedConfirmPassword else {
            SkyBridgeLogger.ui.error("❌ [注册流程] 密码确认不匹配")
            errorMessage = t("auth.password.confirmationMismatch")
            return
        }

 // 更新清洗后的值
        emailAddress = sanitizedEmail
        emailPassword = sanitizedPassword

        SkyBridgeLogger.ui.debugOnly("✅ [注册流程] 输入验证通过，开始安全检查")

 // 🔒 安全检查：限流和设备指纹验证
        guard let riskOutcome = await performSecurityCheck(
            identifier: sanitizedEmail,
            identifierType: .email
        ) else {
            SkyBridgeLogger.ui.warning("⚠️ [注册流程] 安全检查未通过")
            return
        }

        SkyBridgeLogger.ui.debugOnly("✅ [注册流程] 安全检查通过，开始生成 nebulaid")

 // 🔥 生成唯一的 nebulaid
        var nebulaId: String
        do {
            let nebulaIdInfo = try NebulaIDGenerator.shared.generateUserRegistrationID()
            nebulaId = nebulaIdInfo.fullId
            SkyBridgeLogger.ui.debugOnly("✅ [注册流程] NebulaID 生成成功: \(nebulaId)")
        } catch {
            SkyBridgeLogger.ui.error("❌ [注册流程] NebulaID 生成失败: \(error.localizedDescription, privacy: .private)")
            errorMessage = t("auth.registration.identifierGenerationFailed")
            return
        }

        SkyBridgeLogger.ui.debugOnly("✅ [注册流程] 开始调用Supabase API")

        await MainActor.run {
            isProcessing = true
            errorMessage = nil
        }

        do {
            SkyBridgeLogger.ui.debugOnly("🌐 [注册流程] 调用 SupabaseService.shared.signUp")
            SkyBridgeLogger.ui.debugOnly("   邮箱: \(emailAddress)")
            SkyBridgeLogger.ui.debugOnly("   NebulaID: \(nebulaId)")
            SkyBridgeLogger.ui.debugOnly("   元数据: display_name=\(emailDisplayNameFallback(from: emailAddress))")

 // 使用Supabase注册，将 nebulaid 添加到 metadata 中
            let authSession = try await SupabaseService.shared.signUp(
                email: emailAddress,
                password: emailPassword,
                metadata: [
                    "display_name": emailDisplayNameFallback(from: emailAddress),
                    "registration_source": "SkyBridge Compass Pro",
                    "nebula_id": nebulaId,  // 🔥 添加 nebulaid 到元数据
                    "device_fingerprint": riskOutcome.deviceFingerprint
                ],
                redirectTo: Self.emailConfirmationRedirectURL,
                captchaToken: captchaToken
            )

            SkyBridgeLogger.ui.debugOnly("✅ [注册流程] Supabase注册成功")
            SkyBridgeLogger.ui.debugOnly("   用户ID: \(authSession.userIdentifier)")
            SkyBridgeLogger.ui.debugOnly("   NebulaID: \(nebulaId)")
            SkyBridgeLogger.ui.debugOnly("   显示名称: \(authSession.displayName)")

 // 🔥 尝试将 nebulaid 保存到数据库表中
            do {
                SkyBridgeLogger.ui.debugOnly("💾 [注册流程] 尝试保存 NebulaID 到数据库表")
                let saved = try await SupabaseService.shared.saveNebulaIdToDatabase(
                    userId: authSession.userIdentifier,
                    nebulaId: nebulaId,
                    accessToken: authSession.accessToken == "pending_verification" ? nil : authSession.accessToken
                )
                if saved {
                    SkyBridgeLogger.ui.debugOnly("✅ [注册流程] NebulaID 已保存到数据库")
                } else {
                    SkyBridgeLogger.ui.debugOnly("⚠️ [注册流程] NebulaID 保存到数据库失败，但已保存在元数据中")
                }
            } catch {
                SkyBridgeLogger.ui.error("⚠️ [注册流程] NebulaID 保存到数据库时出错: \(error.localizedDescription, privacy: .private)")
                SkyBridgeLogger.ui.debugOnly("   NebulaID 已保存在用户元数据中，不影响注册流程")
            }

 // 📝 记录成功的注册尝试
            await recordRegistrationAttempt(
                identifier: emailAddress,
                identifierType: .email,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: true,
                auditTicket: riskOutcome.auditTicket
            )

            let requiresEmailVerification = authSession.accessToken == "pending_verification"
            if requiresEmailVerification {
                await MainActor.run {
                    self.emailVerificationSent = true
                    self.isProcessing = false
                    self.captchaPassed = false  // 重置验证码状态
                    self.requiresCaptcha = false
                    self.errorMessage = self.t("auth.registration.verifyEmailSent")
                    SkyBridgeLogger.ui.debugOnly("✅ [注册流程] UI状态已更新 - emailVerificationSent=true")
                }
            } else {
                let resolvedDisplayName = preferredSessionDisplayName(
                    authSession,
                    fallback: emailDisplayNameFallback(from: emailAddress)
                )
                await applyAuthenticatedSupabaseSession(authSession, displayNameOverride: resolvedDisplayName)
                await MainActor.run {
                    self.emailVerificationSent = false
                    self.isProcessing = false
                    self.captchaPassed = false
                    self.requiresCaptcha = false
                    self.errorMessage = nil
                    self.clearEmailFields()
                    SkyBridgeLogger.ui.debugOnly("✅ [注册流程] 自动确认项目已直接进入登录态")
                }
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [注册流程] 注册失败")
            SkyBridgeLogger.ui.error("   错误类型: \(String(describing: type(of: error)), privacy: .private)")
            SkyBridgeLogger.ui.error("   错误描述: \(error.localizedDescription, privacy: .private)")

            if let supabaseError = error as? SupabaseService.SupabaseError {
                SkyBridgeLogger.ui.error("   Supabase错误详情: \(String(describing: supabaseError), privacy: .private)")
            }

 // 📝 记录失败的注册尝试
            await recordRegistrationAttempt(
                identifier: emailAddress,
                identifierType: .email,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: false,
                failureReason: error.localizedDescription,
                auditTicket: riskOutcome.auditTicket
            )

            await MainActor.run {
                let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
                self.errorMessage = self.formatted("auth.registration.failedWithReason", message)
                self.isProcessing = false
                SkyBridgeLogger.ui.debugOnly("❌ [注册流程] UI状态已更新 - 显示错误信息")
            }
        }
    }

 /// 切换手机号注册/登录模式
    func togglePhoneRegistrationMode() {
        isPhoneRegistrationMode.toggle()
        clearPhoneFields()
        errorMessage = nil
    }

 /// 手机号用户注册
    @MainActor
    func registerWithPhone() async {
 // 验证输入
        guard !phoneNumber.isEmpty else {
            errorMessage = t("auth.phone.required")
            return
        }

        guard isValidPhoneNumber(phoneNumber) else {
            errorMessage = t("auth.phone.invalid")
            return
        }

        let sanitizedDisplayName = phoneDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedEmail = sanitizeEmail(phoneEmail)

        guard !sanitizedDisplayName.isEmpty else {
            errorMessage = t("auth.profile.displayName.required")
            return
        }

        guard !sanitizedEmail.isEmpty else {
            errorMessage = t("auth.email.required")
            return
        }

        guard isValidEmail(sanitizedEmail) else {
            errorMessage = t("auth.email.invalid")
            return
        }

        phoneDisplayName = sanitizedDisplayName
        phoneEmail = sanitizedEmail

        isProcessing = true
        errorMessage = nil

        await sendPhoneCode(isResend: false)

        isProcessing = false
    }

 /// 完成手机号注册
    @MainActor
    func completePhoneRegistration() async {
 // 验证验证码
        guard !phoneVerificationCode.isEmpty else {
            errorMessage = t("auth.code.required")
            return
        }

        let sanitizedDisplayName = phoneDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedEmail = sanitizeEmail(phoneEmail)
        let sanitizedPhone = sanitizePhoneNumber(phoneNumber)

        guard !sanitizedDisplayName.isEmpty else {
            errorMessage = t("auth.profile.displayName.required")
            return
        }

        guard isValidEmail(sanitizedEmail) else {
            errorMessage = t("auth.email.invalid")
            return
        }

        SkyBridgeLogger.ui.debugOnly("🔧 [手机号注册流程] 开始手机号注册流程")
        SkyBridgeLogger.ui.debugOnly("   手机号: \(sanitizedPhone)")

        isProcessing = true
        errorMessage = nil

        guard let riskOutcome = await performSecurityCheck(
            identifier: sanitizedPhone,
            identifierType: .phone,
            attemptType: .register
        ) else {
            isProcessing = false
            return
        }

        do {
 // 使用手机号和验证码完成注册登录
            let session = try await authService.loginPhone(
                number: sanitizedPhone,
                code: phoneVerificationCode
            )

            let currentUserProfile = try? await SupabaseService.shared.getCurrentUserProfile(
                accessToken: session.accessToken
            )
            let shouldBootstrapProfile = shouldBootstrapPhoneRegistration(
                currentUserProfile: currentUserProfile
            )
            let completedAttemptType: SupabaseService.RegistrationAttemptType =
                shouldBootstrapProfile ? .register : .login

            await recordRegistrationAttempt(
                identifier: sanitizedPhone,
                identifierType: .phone,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                attemptType: completedAttemptType,
                success: true,
                captchaRequired: requiresCaptcha,
                captchaPassed: captchaPassed,
                auditTicket: riskOutcome.auditTicket
            )

            SkyBridgeLogger.ui.debugOnly("✅ [手机号注册流程] 注册成功")
            SkyBridgeLogger.ui.debugOnly("   用户ID: \(session.userIdentifier)")

            if shouldBootstrapProfile {
                var nebulaId: String
                do {
                    let nebulaIdInfo = try NebulaIDGenerator.shared.generateUserRegistrationID()
                    nebulaId = nebulaIdInfo.fullId
                    SkyBridgeLogger.ui.debugOnly("✅ [手机号注册流程] NebulaID 生成成功: \(nebulaId)")
                } catch {
                    SkyBridgeLogger.ui.error("❌ [手机号注册流程] NebulaID 生成失败: \(error.localizedDescription, privacy: .private)")
                    errorMessage = t("auth.registration.identifierGenerationFailed")
                    isProcessing = false
                    return
                }

                SkyBridgeLogger.ui.debugOnly("   NebulaID: \(nebulaId)")

                do {
                    SkyBridgeLogger.ui.debugOnly("💾 [手机号注册流程] 尝试保存 NebulaID 到数据库表")
                    let saved = try await SupabaseService.shared.saveNebulaIdToDatabase(
                        userId: session.userIdentifier,
                        nebulaId: nebulaId,
                        accessToken: session.accessToken == "pending_verification" ? nil : session.accessToken
                    )
                    if saved {
                        SkyBridgeLogger.ui.debugOnly("✅ [手机号注册流程] NebulaID 已保存到数据库")
                    } else {
                        SkyBridgeLogger.ui.debugOnly("⚠️ [手机号注册流程] NebulaID 保存到数据库失败")
                    }
                } catch {
                    SkyBridgeLogger.ui.error("⚠️ [手机号注册流程] NebulaID 保存到数据库时出错: \(error.localizedDescription, privacy: .private)")
                    SkyBridgeLogger.ui.debugOnly("   继续注册流程，不影响用户体验")
                }

                do {
                    _ = try await SupabaseService.shared.updateUserProfile(
                        displayName: sanitizedDisplayName,
                        phoneNumber: sanitizedPhone,
                        email: sanitizedEmail,
                        accessToken: session.accessToken
                    )
                    SkyBridgeLogger.ui.debugOnly("✅ [手机号注册流程] 已回写显示名称/邮箱/手机号到用户资料")
                } catch {
                    SkyBridgeLogger.ui.warning("⚠️ [手机号注册流程] 用户资料回写失败: \(error.localizedDescription)")
                }
            } else {
                SkyBridgeLogger.ui.debugOnly("ℹ️ [手机号注册流程] 检测到已有手机号账号，跳过资料覆盖")
            }

            let fallbackDisplayName = currentUserProfile?.displayName ?? sanitizedDisplayName
            let resolvedDisplayName = preferredSessionDisplayName(session, fallback: fallbackDisplayName)
            await applyAuthenticatedSupabaseSession(session, displayNameOverride: resolvedDisplayName)

 // 注册成功，清空字段
            captchaPassed = false
            requiresCaptcha = false
            showCaptchaView = false
            clearPhoneFields()
            errorMessage = nil

        } catch {
            await recordRegistrationAttempt(
                identifier: sanitizedPhone,
                identifierType: .phone,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                attemptType: .register,
                success: false,
                failureReason: SupabaseService.userMessage(for: error) ?? error.localizedDescription,
                captchaRequired: requiresCaptcha,
                captchaPassed: captchaPassed,
                auditTicket: riskOutcome.auditTicket
            )
            SkyBridgeLogger.ui.error("❌ [手机号注册流程] 注册失败: \(error.localizedDescription, privacy: .private)")
            let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
            errorMessage = formatted("auth.registration.failedWithReason", message)
        }

        isProcessing = false
    }

 /// 邮箱登录
    func loginWithEmail(captchaToken: String? = nil) async {
        let sanitizedEmail = sanitizeEmail(emailAddress)

        guard isValidEmail(sanitizedEmail) else {
            errorMessage = t("auth.email.invalid")
            return
        }

        guard !emailPassword.isEmpty else {
            errorMessage = t("auth.password.required")
            return
        }

        guard let riskOutcome = await performSecurityCheck(
            identifier: sanitizedEmail,
            identifierType: .email,
            attemptType: .login
        ) else {
            return
        }

        emailAddress = sanitizedEmail

        await performAuthenticationTask(
            riskContext: AuthRiskContext(
                identifier: sanitizedEmail,
                identifierType: .email,
                attemptType: .login,
                auditTicket: riskOutcome.auditTicket,
                deviceFingerprint: riskOutcome.deviceFingerprint
            )
        ) {
            let shouldRememberCredentials = self.rememberCredentials
            let session = try await self.authService.loginEmail(
                email: sanitizedEmail,
                password: self.emailPassword,
                captchaToken: captchaToken
            )

 // 登录成功后只保留邮箱偏好，不再保存原始密码。
            if shouldRememberCredentials {
                self.saveCredentials()
            } else {
                self.clearSavedCredentials()
            }

            return session
        }
    }

 /// 发送密码重置邮件
    func resetPassword(captchaToken: String? = nil) async {
        let sanitizedEmail = sanitizeEmail(emailAddress)

        guard isValidEmail(sanitizedEmail) else {
            errorMessage = t("auth.email.invalid")
            return
        }

        emailAddress = sanitizedEmail

        guard let riskOutcome = await performSecurityCheck(
            identifier: sanitizedEmail,
            identifierType: .email,
            attemptType: .verifyCode
        ) else {
            return
        }

        await MainActor.run {
            isProcessing = true
            errorMessage = nil
        }

        do {
            try await SupabaseService.shared.resetPassword(
                email: sanitizedEmail,
                redirectTo: Self.passwordRecoveryRedirectURL,
                captchaToken: captchaToken
            )
            await recordRegistrationAttempt(
                identifier: sanitizedEmail,
                identifierType: .email,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                attemptType: .verifyCode,
                success: true,
                auditTicket: riskOutcome.auditTicket
            )

            await MainActor.run {
                self.isProcessing = false
                self.errorMessage = self.t("auth.passwordReset.emailSent")
            }
        } catch {
            await recordRegistrationAttempt(
                identifier: sanitizedEmail,
                identifierType: .email,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                attemptType: .verifyCode,
                success: false,
                failureReason: SupabaseService.userMessage(for: error) ?? error.localizedDescription,
                auditTicket: riskOutcome.auditTicket
            )
            await MainActor.run {
                let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
                self.errorMessage = self.formatted("auth.passwordReset.emailSendFailedWithReason", message)
                self.isProcessing = false
            }
        }
    }

    @MainActor
    func handleSupabaseAuthCallback(_ url: URL) async -> Bool {
        do {
            guard let resolution = try await resolveSupabaseAuthCallback(url) else {
                return url.pathComponents.contains("nebula")
            }

            let session = resolution.session
            let resolvedType = resolution.callbackType ?? .magiclink
            let resolvedDisplayName = preferredSessionDisplayName(session, fallback: session.displayName)
            await applyAuthenticatedSupabaseSession(session, displayNameOverride: resolvedDisplayName)

            switch resolvedType {
            case .recovery:
                resetPasswordValue = ""
                resetPasswordConfirmation = ""
                showPasswordResetSheet = true
            case .signup, .email, .emailChange, .invite, .magiclink:
                emailVerificationSent = false
                clearEmailFields()
            }

            errorMessage = nil
            return true
        } catch {
            errorMessage = SupabaseService.userMessage(for: error) ?? error.localizedDescription
            return true
        }
    }

    private func resolveSupabaseAuthCallback(_ url: URL) async throws -> SupabaseAuthCallbackResolution? {
        guard url.scheme == "skybridge", url.host == "auth" else {
            return nil
        }

        let parameters = Self.authCallbackParameters(from: url)
        if let error = parameters["error"], !error.isEmpty {
            let description = parameters["error_description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = description?.isEmpty == false ? description! : error
            throw NSError(
                domain: "SupabaseAuthCallback",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let callbackType = parameters["type"]
            .flatMap { SupabaseService.EmailAuthCallbackType(rawValue: $0) }

        let session: AuthSession
        if let tokenHash = parameters["token_hash"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tokenHash.isEmpty,
           let callbackType {
            session = try await SupabaseService.shared.verifyEmailAuthCallback(
                tokenHash: tokenHash,
                type: callbackType
            )
        } else if let accessToken = parameters["access_token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accessToken.isEmpty {
            let refreshToken = parameters["refresh_token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            session = try await SupabaseService.shared.sessionFromCallbackTokens(
                accessToken: accessToken,
                refreshToken: refreshToken?.isEmpty == false ? refreshToken : nil
            )
        } else {
            return nil
        }

        return SupabaseAuthCallbackResolution(session: session, callbackType: callbackType)
    }

    @MainActor
    func submitPasswordReset() async {
        let sanitizedPassword = sanitizePassword(resetPasswordValue)
        let sanitizedConfirmation = sanitizePassword(resetPasswordConfirmation)

        let passwordValidation = validatePasswordStrength(sanitizedPassword, minimumStrength: .medium)
        guard passwordValidation.valid else {
            errorMessage = passwordValidation.error ?? t("auth.password.weakGeneric")
            return
        }

        guard sanitizedPassword == sanitizedConfirmation else {
            errorMessage = t("auth.password.confirmationMismatch")
            return
        }

        guard let session = currentSession else {
            errorMessage = t("auth.passwordReset.sessionMissing")
            return
        }

        isProcessing = true
        errorMessage = nil

        do {
            try await SupabaseService.shared.updatePassword(
                newPassword: sanitizedPassword,
                accessToken: session.accessToken
            )
            resetPasswordValue = ""
            resetPasswordConfirmation = ""
            showPasswordResetSheet = false
            errorMessage = nil
        } catch {
            errorMessage = SupabaseService.userMessage(for: error) ?? error.localizedDescription
        }

        isProcessing = false
    }

    @MainActor
    func cancelPendingPasswordReset() {
        resetPasswordValue = ""
        resetPasswordConfirmation = ""
        showPasswordResetSheet = false
        signOut()
    }

    private static func authCallbackParameters(from url: URL) -> [String: String] {
        var parameters: [String: String] = [:]

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] {
                parameters[item.name] = item.value ?? ""
            }
        }

        if let fragment = url.fragment, !fragment.isEmpty {
            for pair in fragment.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = parts.first else { continue }
                let value = parts.count > 1 ? String(parts[1]) : ""
                parameters[String(key)] = value.removingPercentEncoding ?? value
            }
        }

        return parameters
    }

 /// 清空邮件相关字段
    private func clearEmailFields() {
        emailAddress = ""
        emailPassword = ""
        confirmPassword = ""
        emailVerificationSent = false
    }

 // MARK: - 验证邮箱格式
    private func isValidEmail(_ email: String) -> Bool {
 // 清洗输入
        let sanitized = sanitizeEmail(email)

 // 基础格式检查
        let emailRegex = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)

        if !emailPredicate.evaluate(with: sanitized) {
            return false
        }

 // 长度检查
        if sanitized.count > 254 {
            return false
        }

        return true
    }

 /// 检查是否为一次性邮箱域名
    private func isDisposableEmail(_ email: String) -> Bool {
        let disposableEmailDomains: Set<String> = [
            "tempmail.com", "guerrillamail.com", "10minutemail.com",
            "mailinator.com", "throwaway.email", "fakeinbox.com",
            "temp-mail.org", "dispostable.com", "maildrop.cc",
            "yopmail.com", "trashmail.com", "sharklasers.com"
        ]

        let domain = email.components(separatedBy: "@").last?.lowercased() ?? ""
        return disposableEmailDomains.contains(domain)
    }

 // MARK: - 游客模式

 /// 进入游客模式
    func enterGuestMode() {
        guard !isProcessing else { return }
        isProcessing = true
        errorMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }
            do {
                try await self.authService.activateGuestSession(
                    displayName: self.t("auth.displayName.default.guest")
                )
                self.isGuestMode = true
                self.supabaseNebulaId = nil
            } catch {
                self.errorMessage = error.localizedDescription
                SkyBridgeLogger.ui.error(
                    "❌ [AuthenticationViewModel] 游客模式本地会话清理失败: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

 // MARK: - 登出

 /// 登出当前用户
    func signOut() {
        guard !isProcessing else { return }
        isProcessing = true
        errorMessage = nil
        showSignOutError = false

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }
            let outcome = await self.authService.signOutAndWait()
            if case .localCleanupFailed(let message) = outcome {
                self.errorMessage = "无法清理本地登录状态：\(message)"
                self.showSignOutError = true
                return
            }

            self.currentSession = nil
            self.supabaseNebulaId = nil
            self.isGuestMode = false
            self.clearAllFields()
            if self.rememberCredentials {
                self.purgeLegacySavedPassword()
            } else {
                self.clearSavedCredentials()
            }

            if case .localOnlyAfterRemoteFailure(let message) = outcome {
                SkyBridgeLogger.ui.warning("⚠️ [AuthenticationViewModel] 远端会话撤销失败，本地已退出: \(message)")
            }
        }
    }

 /// 清空所有输入字段
    private func clearAllFields() {
        nebulaAccount = ""
        nebulaPassword = ""
        phoneNumber = ""
        phoneVerificationCode = ""
        emailAddress = ""
        emailPassword = ""
        isPhoneCodeSent = false
        phoneCodeCountdown = 0
        phoneCodeTimer?.invalidate()
        phoneCodeTimer = nil
    }

 // MARK: - 通用认证处理

 /// 执行认证任务的通用方法
    private func performAuthenticationTask(
        riskContext: AuthRiskContext? = nil,
        _ task: @escaping () async throws -> AuthSession
    ) async {
        SkyBridgeLogger.ui.debugOnly("🔧 [AuthenticationViewModel] 开始执行认证任务")

        await MainActor.run {
            isProcessing = true
            errorMessage = nil
        }

        do {
            let session = try await task()
            SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 认证任务成功")
            SkyBridgeLogger.ui.debugOnly("   用户ID: \(session.userIdentifier)")
            SkyBridgeLogger.ui.debugOnly("   显示名称: \(session.displayName)")

            if let riskContext {
                await recordRegistrationAttempt(
                    identifier: riskContext.identifier,
                    identifierType: riskContext.identifierType,
                    deviceFingerprint: riskContext.deviceFingerprint,
                    attemptType: riskContext.attemptType,
                    success: true,
                    captchaRequired: requiresCaptcha,
                    captchaPassed: captchaPassed,
                    auditTicket: riskContext.auditTicket
                )
            }

            await MainActor.run {
                SkyBridgeLogger.ui.debugOnly("🔄 [AuthenticationViewModel] 更新UI状态")

 // 直接更新状态，让SwiftUI自然处理更新
                self.currentSession = session
                self.isProcessing = false
                self.captchaPassed = false
                self.requiresCaptcha = false
                self.showCaptchaView = false
                self.clearAllFields()

                SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] UI状态更新完成")
                SkyBridgeLogger.ui.debugOnly("   currentSession 用户: \(self.currentSession?.userIdentifier ?? "无")")
            }

            await loadUserAvatarAfterLogin(session: session)
        } catch let error as AuthenticationService.AuthenticationError {
            if case .nebulaMFARequired(let token) = error {
                await MainActor.run {
                    self.mfaToken = token
                    self.showMFAInput = true
                    self.errorMessage = nil
                    self.isProcessing = false
                }
                return
            }

            SkyBridgeLogger.ui.error("❌ [AuthenticationViewModel] 认证任务失败: \(error.localizedDescription, privacy: .private)")
            if let riskContext {
                await recordRegistrationAttempt(
                    identifier: riskContext.identifier,
                    identifierType: riskContext.identifierType,
                    deviceFingerprint: riskContext.deviceFingerprint,
                    attemptType: riskContext.attemptType,
                    success: false,
                    failureReason: SupabaseService.userMessage(for: error) ?? error.localizedDescription,
                    captchaRequired: requiresCaptcha,
                    captchaPassed: captchaPassed,
                    auditTicket: riskContext.auditTicket
                )
            }
            await MainActor.run {
                self.errorMessage = SupabaseService.userMessage(for: error) ?? error.localizedDescription
                self.isProcessing = false
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [AuthenticationViewModel] 认证任务失败: \(error.localizedDescription, privacy: .private)")
            if let riskContext {
                await recordRegistrationAttempt(
                    identifier: riskContext.identifier,
                    identifierType: riskContext.identifierType,
                    deviceFingerprint: riskContext.deviceFingerprint,
                    attemptType: riskContext.attemptType,
                    success: false,
                    failureReason: SupabaseService.userMessage(for: error) ?? error.localizedDescription,
                    captchaRequired: requiresCaptcha,
                    captchaPassed: captchaPassed,
                    auditTicket: riskContext.auditTicket
                )
            }
            await MainActor.run {
                self.errorMessage = SupabaseService.userMessage(for: error) ?? error.localizedDescription
                self.isProcessing = false
            }
        }
    }

 /// 登录成功后加载用户头像
 /// - Parameter session: 认证会话
    private func loadUserAvatarAfterLogin(session: AuthSession) async {
 // 跳过待验证状态的会话
        guard session.accessToken != "pending_verification" else {
            SkyBridgeLogger.ui.debugOnly("ℹ️ [AuthenticationViewModel] 跳过待验证账户的头像加载")
            return
        }

        SkyBridgeLogger.ui.debugOnly("🔍 [AuthenticationViewModel] 开始加载用户头像")
        SkyBridgeLogger.ui.debugOnly("   用户ID: \(session.userIdentifier)")

        do {
 // 首先检查本地缓存
            if try await AvatarCacheManager.shared.loadCachedAvatar(for: session.userIdentifier) != nil {
                SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 从本地缓存加载头像")
                return
            }

            let avatarUrl: String?
            if let sessionAvatarURL = session.avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sessionAvatarURL.isEmpty {
                avatarUrl = sessionAvatarURL
            } else if SupabaseService.shared.isSupabaseAccessToken(session.accessToken) {
                avatarUrl = try await SupabaseService.shared.getUserAvatarUrl(
                    userId: session.userIdentifier,
                    accessToken: session.accessToken
                )
            } else {
                SkyBridgeLogger.ui.debugOnly("ℹ️ [AuthenticationViewModel] 当前会话未提供云头像 URL")
                avatarUrl = nil
            }

            if let avatarUrl {
                SkyBridgeLogger.ui.debugOnly("🔍 [AuthenticationViewModel] 找到用户头像URL: \(avatarUrl)")

 // 下载并缓存头像
                _ = try await AvatarCacheManager.shared.downloadAndCacheAvatar(
                    from: avatarUrl,
                    for: session.userIdentifier
                )

                SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 头像下载并缓存成功")
            } else {
                SkyBridgeLogger.ui.debugOnly("ℹ️ [AuthenticationViewModel] 用户未设置头像")
            }
        } catch {
 // 头像加载失败不影响登录流程，只记录日志
            SkyBridgeLogger.ui.error("⚠️ [AuthenticationViewModel] 头像加载失败: \(error.localizedDescription, privacy: .private)")
        }
    }

 /// 切换星云注册/登录模式
    func toggleNebulaRegistrationMode() {
        isNebulaRegistrationMode.toggle()
        clearNebulaFields()
        errorMessage = nil
    }

 /// 星云用户注册（增强安全校验）
    @MainActor
    func registerWithNebula() async {
        if isNebulaRegistrationMode {
            await performAuthenticationTask {
                try await self.registerWithNebulaUsingBrowser()
            }
            return
        }
 // 清洗输入
        let sanitizedUsername = sanitizeUsername(nebulaAccount)
        let sanitizedPassword = sanitizePassword(nebulaPassword)
        let sanitizedConfirmPassword = sanitizePassword(nebulaConfirmPassword)
        let sanitizedDisplayName = nebulaDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedEmail = sanitizeEmail(nebulaEmail)

 // 用户名校验
        let usernameValidation = validateUsername(sanitizedUsername)
        guard usernameValidation.valid else {
            errorMessage = usernameValidation.error ?? t("auth.username.invalid")
            return
        }

 // 密码强度校验
        let passwordValidation = validatePasswordStrength(sanitizedPassword, minimumStrength: .medium)
        guard passwordValidation.valid else {
            errorMessage = passwordValidation.error ?? t("auth.password.weakGeneric")
            return
        }

 // 密码确认校验
        guard sanitizedPassword == sanitizedConfirmPassword else {
            errorMessage = t("auth.password.confirmationMismatch")
            return
        }

 // 显示名称校验
        guard !sanitizedDisplayName.isEmpty else {
            errorMessage = t("auth.profile.displayName.required")
            return
        }

        guard sanitizedDisplayName.count <= 50 else {
            errorMessage = t("auth.profile.displayName.tooLong")
            return
        }

 // 邮箱校验
        guard isValidEmail(sanitizedEmail) else {
            errorMessage = t("auth.email.invalid")
            return
        }

 // 检查一次性邮箱
        guard !isDisposableEmail(sanitizedEmail) else {
            errorMessage = t("auth.email.disposableNotSupported")
            return
        }

 // 更新清洗后的值
        nebulaAccount = sanitizedUsername
        nebulaPassword = sanitizedPassword
        nebulaDisplayName = sanitizedDisplayName
        nebulaEmail = sanitizedEmail

        isProcessing = true
        errorMessage = nil

        do {
            SkyBridgeLogger.ui.debugOnly("🔧 [星云注册流程] 开始星云用户注册")
            SkyBridgeLogger.ui.debugOnly("   用户名: \(nebulaAccount)")
            SkyBridgeLogger.ui.debugOnly("   邮箱: \(nebulaEmail)")

            let result = try await NebulaService.shared.registerUser(
                username: nebulaAccount,
                password: nebulaPassword,
                email: nebulaEmail,
                displayName: nebulaDisplayName
            )

            if result.success {
                SkyBridgeLogger.ui.debugOnly("✅ [星云注册流程] 星云注册成功")
                SkyBridgeLogger.ui.debugOnly("   用户ID: \(result.userId ?? "无")")

 // 🔥 NebulaService 注册时已经生成了 nebulaid（作为 userId），现在需要保存到 Supabase 数据库
                if let nebulaId = result.userId {
                    SkyBridgeLogger.ui.debugOnly("   NebulaID: \(nebulaId)")

 // 如果注册后自动登录了，尝试保存 nebulaid 到 Supabase 数据库
                    if !result.requiresEmailVerification && !result.requiresAdminApproval {
 // 等待登录完成后再保存
                        let session = try await loginWithNebulaDirectCredentials()
                        currentSession = session
                        await loadUserAvatarAfterLogin(session: session)
                        clearAllFields()

 // 登录成功后，尝试保存 nebulaid 到数据库
                        if let session = currentSession {
                            do {
                                SkyBridgeLogger.ui.debugOnly("💾 [星云注册流程] 尝试保存 NebulaID 到 Supabase 数据库表")
                                let saved = try await SupabaseService.shared.saveNebulaIdToDatabase(
                                    userId: session.userIdentifier,
                                    nebulaId: nebulaId,
                                    accessToken: session.accessToken == "pending_verification" ? nil : session.accessToken
                                )
                                if saved {
                                    SkyBridgeLogger.ui.debugOnly("✅ [星云注册流程] NebulaID 已保存到 Supabase 数据库")
                                } else {
                                    SkyBridgeLogger.ui.debugOnly("⚠️ [星云注册流程] NebulaID 保存到数据库失败")
                                }
                            } catch {
                                SkyBridgeLogger.ui.error("⚠️ [星云注册流程] NebulaID 保存到数据库时出错: \(error.localizedDescription, privacy: .private)")
                            }
                        }
                    }
                }

                if result.requiresEmailVerification {
                    errorMessage = t("auth.registration.verifyEmailSent")
                } else if result.requiresAdminApproval {
                    errorMessage = t("auth.registration.pendingAdminApproval")
                } else {
 // 注册成功，自动登录（已在上面处理）
                }
            } else {
                SkyBridgeLogger.ui.error("❌ [星云注册流程] 注册失败: \((result.message ?? "未知错误"), privacy: .private)")
                errorMessage = result.message ?? t("auth.registration.failed")
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [星云注册流程] 注册异常: \(error.localizedDescription, privacy: .private)")
            errorMessage = formatted("auth.registration.failedWithReason", error.localizedDescription)
        }

        isProcessing = false
    }

 /// 检查用户名可用性
    @MainActor
    func checkUsernameAvailability() async {
        guard !nebulaAccount.isEmpty else {
            isUsernameAvailable = nil
            return
        }

        usernameCheckInProgress = true

        do {
            let isAvailable = try await NebulaService.shared.checkUsernameAvailability(nebulaAccount)
            isUsernameAvailable = isAvailable
        } catch {
            isUsernameAvailable = nil
        }

        usernameCheckInProgress = false
    }

    private func forceRefreshedSession(
        maintainingUserIdentifierFrom expectedSession: AuthSession
    ) async throws -> AuthSession {
        guard authService.currentSessionSnapshot()?.userIdentifier
                == expectedSession.userIdentifier else {
            throw AuthenticationService.AuthenticationError.sessionChangedDuringRefresh
        }
        guard let refreshed = try await authService.validSession(forceRefresh: true),
              refreshed.userIdentifier == expectedSession.userIdentifier else {
            throw AuthenticationService.AuthenticationError.sessionChangedDuringRefresh
        }
        return refreshed
    }

 // MARK: - 用户资料更新方法

 /// 更新用户显示名称
 /// - Parameter displayName: 新的显示名称
    @MainActor
    func updateDisplayName(_ displayName: String) async throws {
        guard let session = currentSession else {
            throw NSError(
                domain: "AuthenticationError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: t("auth.session.notLoggedIn")]
            )
        }

        SkyBridgeLogger.ui.debugOnly("🔄 [AuthenticationViewModel] 开始更新显示名称")
        SkyBridgeLogger.ui.debugOnly("   用户ID: \(session.userIdentifier)")
        SkyBridgeLogger.ui.debugOnly("   原显示名称: \(session.displayName)")
        SkyBridgeLogger.ui.debugOnly("   新显示名称: \(displayName)")

        // Supabase 用户：优先写入 Supabase user_metadata（跨端可见）
        if SupabaseConfiguration.shared.isConfigured,
           session.accessToken != "pending_verification",
           SupabaseService.shared.isSupabaseAccessToken(session.accessToken) {
            var activeSession = session
            if session.refreshToken != nil {
                // Best-effort refresh for 403/expired tokens
                do {
                    let refreshed = try await forceRefreshedSession(
                        maintainingUserIdentifierFrom: session
                    )
                    activeSession = refreshed
                    currentSession = refreshed
                } catch AuthenticationService.AuthenticationError.sessionChangedDuringRefresh {
                    throw AuthenticationService.AuthenticationError.sessionChangedDuringRefresh
                } catch {
                    // Preserve the existing best-effort boundary for transient failures.
                }
            }

            _ = try await SupabaseService.shared.updateUserProfile(
                displayName: displayName,
                phoneNumber: nil,
                email: nil,
                accessToken: activeSession.accessToken
            )

            let updatedSession = AuthSession(
                accessToken: activeSession.accessToken,
                refreshToken: activeSession.refreshToken,
                userIdentifier: activeSession.userIdentifier,
                nebulaId: activeSession.nebulaId,
                displayName: displayName,
                avatarURL: activeSession.avatarURL,
                issuedAt: activeSession.issuedAt
            )
            try await AuthenticationService.shared.updateSession(updatedSession)
            currentSession = updatedSession
            SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 显示名称更新成功(Supabase): \(displayName)")
            return
        }

        // 非 Supabase 用户：沿用 NebulaService
        let updatedUserInfo = try await NebulaService.shared.updateDisplayName(
            userId: session.userIdentifier,
            displayName: displayName,
            accessToken: session.accessToken
        )

        let updatedSession = AuthSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userIdentifier: session.userIdentifier,
            nebulaId: session.nebulaId,
            displayName: updatedUserInfo.displayName,
            avatarURL: updatedUserInfo.avatar ?? session.avatarURL,
            issuedAt: session.issuedAt
        )

        try await AuthenticationService.shared.updateSession(updatedSession)
        currentSession = updatedSession
        SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 显示名称更新成功: \(updatedUserInfo.displayName)")
    }

 /// 上传用户头像
 /// - Parameter imageData: 头像图片数据
    @MainActor
    func uploadAvatar(_ imageData: Data) async throws {
        guard let session = currentSession else {
            throw NSError(
                domain: "AuthenticationError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: t("auth.session.notLoggedIn")]
            )
        }

        SkyBridgeLogger.ui.debugOnly("🔄 [AuthenticationViewModel] 开始上传头像")
        SkyBridgeLogger.ui.debugOnly("   用户ID: \(session.userIdentifier)")
        SkyBridgeLogger.ui.debugOnly("   图片大小: \(imageData.count) bytes")

        // Supabase 用户：优先上传到 Supabase Storage 并写入 avatar_url（跨端可见）
        if SupabaseConfiguration.shared.isConfigured,
           session.accessToken != "pending_verification",
           SupabaseService.shared.isSupabaseAccessToken(session.accessToken) {
            var activeSession = session
            if session.refreshToken != nil {
                do {
                    let refreshed = try await forceRefreshedSession(
                        maintainingUserIdentifierFrom: session
                    )
                    activeSession = refreshed
                    currentSession = refreshed
                } catch AuthenticationService.AuthenticationError.sessionChangedDuringRefresh {
                    throw AuthenticationService.AuthenticationError.sessionChangedDuringRefresh
                } catch {
                    // Preserve the existing best-effort boundary for transient failures.
                }
            }

            let avatarUrl = try await SupabaseService.shared.uploadAvatarToStorage(
                userId: activeSession.userIdentifier,
                imageData: imageData,
                accessToken: activeSession.accessToken
            )

            if let image = NSImage(data: imageData) {
                AvatarCacheManager.shared.cacheAvatar(image, for: activeSession.userIdentifier)
            }

            let updatedSession = AuthSession(
                accessToken: activeSession.accessToken,
                refreshToken: activeSession.refreshToken,
                userIdentifier: activeSession.userIdentifier,
                nebulaId: activeSession.nebulaId,
                displayName: activeSession.displayName,
                avatarURL: avatarUrl,
                issuedAt: activeSession.issuedAt
            )
            try await AuthenticationService.shared.updateSession(updatedSession)
            currentSession = updatedSession

            SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 头像上传成功(Supabase): \(avatarUrl)")
            return
        }

        // 非 Supabase 用户：沿用 NebulaService 上传头像
        let avatarUrl = try await NebulaService.shared.uploadAvatar(
            userId: session.userIdentifier,
            imageData: imageData,
            accessToken: session.accessToken
        )

 // 缓存新头像到本地
        if let image = NSImage(data: imageData) {
            AvatarCacheManager.shared.cacheAvatar(image, for: session.userIdentifier)
        }

        let updatedSession = AuthSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userIdentifier: session.userIdentifier,
            nebulaId: session.nebulaId,
            displayName: session.displayName,
            avatarURL: avatarUrl,
            issuedAt: session.issuedAt
        )
        try await AuthenticationService.shared.updateSession(updatedSession)
        currentSession = updatedSession

        SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 头像上传成功: \(avatarUrl)")
    }

 /// 清空星云登录字段
    private func clearNebulaFields() {
        nebulaAccount = ""
        nebulaPassword = ""
        mfaCode = ""
        nebulaDisplayName = ""
        nebulaEmail = ""
        nebulaConfirmPassword = ""
        showMFAInput = false
        isUsernameAvailable = nil
        usernameCheckInProgress = false
    }

 // MARK: - 清理资源
    deinit {
 // Combine会自动清理cancellables；但run-loop调度的Timer不会随deinit自动释放，需显式失效以避免孤儿计时器持续触发
        phoneCodeTimer?.invalidate()
    }

 /// 强制重新认证 - 清除无效的访问令牌
    func forceReauthentication() {
        SkyBridgeLogger.ui.debugOnly("🔄 [AuthenticationViewModel] 强制重新认证")
        SkyBridgeLogger.ui.debugOnly("   清除当前会话和所有认证状态")

 // 清除当前会话
        currentSession = nil
        isGuestMode = false

 // 清除所有输入字段
        clearAllFields()

 // 清除错误消息
        errorMessage = nil

        SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 强制重新认证完成，用户需要重新登录")
    }

// MARK: - KeyChain 凭据管理

    private func makeNonInteractiveAuthContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

 /// 保存登录凭据到KeyChain
    private func saveCredentials() {
        let sanitizedEmail = sanitizeEmail(emailAddress)
        guard !sanitizedEmail.isEmpty else { return }

 // 仅保存邮箱地址，原始密码不再持久化。
        UserDefaults.standard.set(sanitizedEmail, forKey: "saved_email_address")
        purgeLegacySavedPassword(for: sanitizedEmail)
        SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 已保存登录邮箱偏好")
    }

 /// 从KeyChain加载已保存的凭据
    private func loadSavedCredentials() {
 // 从UserDefaults加载邮箱地址
        if let savedEmail = UserDefaults.standard.string(forKey: "saved_email_address") {
            emailAddress = savedEmail
            rememberCredentials = true
            purgeLegacySavedPassword(for: savedEmail)
            SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 已加载登录邮箱偏好")
        }
    }

 /// 清除保存的凭据
    private func clearSavedCredentials() {
        let account = savedCredentialAccount()
 // 清除UserDefaults中的邮箱地址
        UserDefaults.standard.removeObject(forKey: "saved_email_address")
        purgeLegacySavedPassword(for: account)
        SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 已清除保存的登录偏好")
    }

    private func savedCredentialAccount() -> String? {
        let current = sanitizeEmail(emailAddress)
        if !current.isEmpty {
            return current
        }
        return UserDefaults.standard.string(forKey: "saved_email_address")
    }

    private func purgeLegacySavedPassword(for account: String? = nil) {
        guard let account = account ?? savedCredentialAccount(),
              !account.isEmpty else { return }

        let context = makeNonInteractiveAuthContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: "SkyBridgeCompass_EmailLogin",
            kSecUseAuthenticationContext as String: context,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            SkyBridgeLogger.ui.debugOnly("🧹 [AuthenticationViewModel] 已清除旧版密码存储")
        } else if status != errSecItemNotFound {
            SkyBridgeLogger.ui.debugOnly("ℹ️ [AuthenticationViewModel] 清除旧版密码存储失败: \(status)")
        }
    }

    private nonisolated static func generateAppleSignInNonce(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        var result = ""
        result.reserveCapacity(length)
        for byte in randomBytes {
            let index = Int(byte) % charset.count
            result.append(charset[index])
        }
        return result
    }

    private nonisolated static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func applyAppleProfileIfNeeded(
        _ credential: ASAuthorizationAppleIDCredential,
        to session: AuthSession
    ) async -> AuthSession {
        guard let appleDisplayName = Self.formattedAppleDisplayName(from: credential.fullName) else {
            return session
        }

        if session.accessToken != "pending_verification",
           SupabaseService.shared.isSupabaseAccessToken(session.accessToken) {
            do {
                _ = try await SupabaseService.shared.updateUserProfile(
                    displayName: appleDisplayName,
                    accessToken: session.accessToken
                )
            } catch {
                SkyBridgeLogger.ui.warning("⚠️ [AuthenticationViewModel] Apple 首登资料回写失败: \(error.localizedDescription, privacy: .private)")
            }
        }

        guard shouldReplaceDisplayName(session.displayName) else {
            return session
        }

        return AuthSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userIdentifier: session.userIdentifier,
            nebulaId: session.nebulaId,
            displayName: appleDisplayName,
            avatarURL: session.avatarURL,
            issuedAt: session.issuedAt
        )
    }

    private nonisolated static func appleAuditIdentifier(for credential: ASAuthorizationAppleIDCredential) -> String {
        "apple:\(credential.user)"
    }

    private nonisolated static func formattedAppleDisplayName(from fullName: PersonNameComponents?) -> String? {
        guard let fullName else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let formatted = formatter.string(from: fullName).trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted.isEmpty ? nil : formatted
    }

    private func shouldReplaceDisplayName(_ displayName: String) -> Bool {
        isPlaceholderDisplayName(displayName)
    }
}

private final class BrowserAuthenticationContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func resume(returning url: URL) {
        takeContinuation()?.resume(returning: url)
    }

    func resume(throwing error: Error) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<URL, Error>? {
        lock.lock()
        defer { lock.unlock() }

        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}

private final class NebulaBrowserPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if canImport(AppKit)
        return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
#else
        return ASPresentationAnchor()
#endif
    }
}
