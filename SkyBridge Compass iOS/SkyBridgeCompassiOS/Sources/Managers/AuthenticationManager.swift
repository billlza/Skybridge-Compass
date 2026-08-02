import Foundation
import CryptoKit
import AuthenticationServices
import Security
import UIKit

public struct RemoteControlSecurityIdentityMetadata: Sendable, Equatable {
    public let accountDisplayName: String?
    public let nebulaId: String?
}

struct CurrentPathAuthenticationPrincipal: Sendable, Equatable {
    let userID: String
    let tenantID: String
}

/// 认证管理器 - 管理用户认证和会话
@MainActor
public class AuthenticationManager: ObservableObject {
    public static let instance = AuthenticationManager()
    
    // MARK: - Published Properties
    
    @Published public private(set) var currentUser: User?
    @Published public var isAuthenticated: Bool = false
    @Published public var isGuestMode: Bool = false
    @Published public var showCaptchaChallenge: Bool = false
    @Published public private(set) var appleAuthorizationState: ASAuthorizationAppleIDProvider.CredentialState = .notFound
    @Published public private(set) var isRestoringSession: Bool = true

    private var session: AuthSession?
    private var didLogSupabaseConfigMissing = false
    private var lastTokenRefreshAttemptAt: Date?
    private var captchaPassed = false
    private var captchaChallengeRequired = false
    private var pendingAppleSignInNonce: String?
    private var localLoginAttemptTimestamps: [String: [Date]] = [:]

    private static let localLoginThrottleWindow: TimeInterval = 10
    private static let localLoginThrottleMaxAttempts = 5

    private struct RiskCheckOutcome {
        let auditTicket: String?
        let deviceFingerprint: String
    }

#if DEBUG || SKYBRIDGE_TESTING
    private static var shouldResetStateForUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_RESET_STATE")
    }

    private static var shouldAutoAuthenticateAsGuestForUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_AUTH_GUEST")
    }
#endif

#if DEBUG || SKYBRIDGE_TESTING
    private static var shouldAutoAuthenticateAsGuestForP2PSmoke: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SKYBRIDGE_SMOKE_ROLE"] == "ios-p2p-client"
            && environment["SKYBRIDGE_SMOKE_EXPECT_REMOTE_DESKTOP"] == "1"
            && environment["SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB"] == "1"
            && environment["SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW"] == "1"
    }
#endif

    private static var appleSignInLaunchReady: Bool {
        if let override = ProcessInfo.processInfo.environment["SKYBRIDGE_ENABLE_APPLE_SIGN_IN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            return override == "1" || override == "true" || override == "yes"
        }

        return (Bundle.main.object(forInfoDictionaryKey: "SKYBRIDGE_ENABLE_APPLE_SIGN_IN") as? Bool) ?? false
    }

    public var isAppleSignInEnabled: Bool {
        Self.appleSignInLaunchReady
    }

    var currentPathAuthenticationPrincipal: CurrentPathAuthenticationPrincipal? {
        guard isAuthenticated, !isGuestMode, !isRestoringSession else { return nil }
        guard let session,
              let accessToken = Self.normalizedIdentityValue(session.accessToken),
              let sessionUserID = Self.normalizedIdentityValue(session.userIdentifier) else {
            return nil
        }
        let displayedUserID = Self.normalizedIdentityValue(currentUser?.id)
        if let displayedUserID, sessionUserID != displayedUserID {
            return nil
        }
        do {
            let identity = try SignalServerClientCompat.resolveAuthenticatedJWTIdentity(
                accessToken: accessToken,
                expectedUserIdentifier: sessionUserID
            )
            guard displayedUserID == nil || displayedUserID == identity.subject else {
                return nil
            }
            return CurrentPathAuthenticationPrincipal(
                userID: identity.subject,
                tenantID: identity.effectiveTenantID
            )
        } catch {
            SkyBridgeLogger.shared.error(
                "Current-path authentication principal rejected: \(error.localizedDescription)"
            )
            return nil
        }
    }

    public var remoteControlSecurityIdentityMetadata: RemoteControlSecurityIdentityMetadata {
#if DEBUG || SKYBRIDGE_TESTING
        let environment = ProcessInfo.processInfo.environment
        let isSmoke = environment["SKYBRIDGE_SMOKE_ROLE"] != nil
        let smokeAccount = isSmoke
            ? Self.normalizedIdentityValue(
                environment["SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME"]
                    ?? environment["SKYBRIDGE_DISPLAY_NAME"]
            )
            : nil
        let smokeNebulaId = isSmoke
            ? Self.normalizedIdentityValue(
                environment["SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID"]
                    ?? environment["SKYBRIDGE_NEBULA_ID"]
                    ?? environment["SKYBRIDGE_TENANT_ID"]
            )
            : nil
        let account = smokeAccount
            ?? Self.normalizedIdentityValue(currentUser?.displayName)
            ?? Self.normalizedIdentityValue(session?.displayName)
            ?? Self.normalizedIdentityValue(currentUser?.email)
            ?? Self.normalizedIdentityValue(session?.email)
            ?? Self.normalizedIdentityValue(currentUser?.id)
            ?? Self.normalizedIdentityValue(session?.userIdentifier)
        let nebulaId = smokeNebulaId
            ?? Self.normalizedIdentityValue(currentUser?.nebulaId)
            ?? Self.normalizedIdentityValue(session?.nebulaId)
#else
        let account = Self.normalizedIdentityValue(currentUser?.displayName)
            ?? Self.normalizedIdentityValue(session?.displayName)
            ?? Self.normalizedIdentityValue(currentUser?.email)
            ?? Self.normalizedIdentityValue(session?.email)
            ?? Self.normalizedIdentityValue(currentUser?.id)
            ?? Self.normalizedIdentityValue(session?.userIdentifier)
        let nebulaId = Self.normalizedIdentityValue(currentUser?.nebulaId)
            ?? Self.normalizedIdentityValue(session?.nebulaId)
#endif
        return RemoteControlSecurityIdentityMetadata(
            accountDisplayName: account,
            nebulaId: nebulaId
        )
    }

    internal static func resolvedNebulaId(from userInfo: NebulaPublicClientOAuth.UserInfo) -> String? {
        Self.normalizedIdentityValue(userInfo.nebulaId)
            ?? (Self.isCanonicalNebulaId(userInfo.subject)
                ? Self.normalizedIdentityValue(userInfo.subject)
                : nil)
    }

    public enum AuthFlowError: LocalizedError {
        case emailVerificationRequired
        case registrationBlocked(String)

        public var errorDescription: String? {
            switch self {
            case .emailVerificationRequired:
                return "注册成功！请检查邮箱并点击验证链接后再登录。"
            case .registrationBlocked(let message):
                return message
            }
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    enum SmokeRemoteDesktopSessionError: LocalizedError {
        case disabled
        case invalidCredentials

        var errorDescription: String? {
            switch self {
            case .disabled:
                return "real-device smoke authentication bootstrap is not enabled for this launch"
            case .invalidCredentials:
                return "real-device smoke authentication credentials are invalid"
            }
        }
    }
#endif
    
    private init() {
#if DEBUG || SKYBRIDGE_TESTING
        if SkyBridgeRuntimeEnvironment.isUITesting,
           Self.shouldAutoAuthenticateAsGuestForUITests {
            applyUITestGuestSession()
            isRestoringSession = false
            return
        }
#endif
#if DEBUG || SKYBRIDGE_TESTING
        if Self.shouldAutoAuthenticateAsGuestForP2PSmoke {
            applyP2PSmokeGuestSession()
            isRestoringSession = false
            return
        }
#endif
#if DEBUG || SKYBRIDGE_TESTING
        let shouldResetState = SkyBridgeRuntimeEnvironment.isUITesting
            && Self.shouldResetStateForUITests
#else
        let shouldResetState = false
#endif
        Task { [weak self] in
            await self?.restoreInitialAuthenticationState(resetPersistedSession: shouldResetState)
        }
    }

    private func restoreInitialAuthenticationState(resetPersistedSession: Bool) async {
#if DEBUG || SKYBRIDGE_TESTING
        if resetPersistedSession {
            do {
                try await clearSession()
            } catch {
                SkyBridgeLogger.shared.error("❌ UI 测试登录态清理失败: \(error.localizedDescription)")
            }
            isRestoringSession = false
            return
        }
#endif

        await loadSession()
        isRestoringSession = false
        await checkAppleIDCredentialState()
    }

    private func registrationDeviceFingerprint() async throws -> String {
        let identity = try await SkyBridgeiOSCore.shared
            .currentProtocolIdentitySnapshot()
        return Self.registrationDeviceFingerprint(
            deviceId: identity.deviceId,
            signingPublicKeyFingerprint: identity.signingPublicKeyFingerprint
        )
    }

    nonisolated static func registrationDeviceFingerprint(
        deviceId: String,
        signingPublicKeyFingerprint: String
    ) -> String {
        var material = Data("com.skybridge.registration-device-fingerprint.v1".utf8)
        for value in [deviceId, signingPublicKeyFingerprint] {
            let field = Data(value.utf8)
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
            material.append(field)
        }
        let digest = SHA256.hash(data: material)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedIdentityValue(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func isCanonicalNebulaId(_ raw: String?) -> Bool {
        normalizedIdentityValue(raw)?.hasPrefix("NEBULA-") == true
    }

    private func formattedRiskMessage(reason: String?, retryAfter: Int?, fallback: String) -> String {
        let base = reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? reason!.trimmingCharacters(in: .whitespacesAndNewlines)
            : fallback

        guard let retryAfter, retryAfter > 0 else { return base }

        if retryAfter >= 3600 {
            let hours = Int(ceil(Double(retryAfter) / 3600.0))
            return "\(base)（约 \(hours) 小时后可重试）"
        }

        let minutes = max(1, Int(ceil(Double(retryAfter) / 60.0)))
        return "\(base)（约 \(minutes) 分钟后可重试）"
    }

    private func ensureRegistrationAllowed(
        identifier: String,
        identifierType: SupabaseService.RegistrationIdentifierType,
        attemptType: SupabaseService.RegistrationAttemptType
    ) async throws -> RiskCheckOutcome {
        if attemptType == .login {
            try enforceLocalLoginThrottle(identifier: identifier, identifierType: identifierType)
            SkyBridgeLogger.shared.info("🔐 登录路径已通过本地短窗口软限流，继续执行服务端登录风控")
        }

        let fingerprint = try await registrationDeviceFingerprint()

        do {
            let decision = try await SupabaseService.shared.assessRegistrationRisk(
                identifier: identifier,
                identifierType: identifierType,
                deviceFingerprint: fingerprint,
                attemptType: attemptType
            )

            if !decision.allowed {
                let message = formattedRiskMessage(
                    reason: decision.reason,
                    retryAfter: decision.retryAfter,
                    fallback: "当前请求已触发额外风控，请稍后再试"
                )
                captchaChallengeRequired = decision.requiresCaptcha
                captchaPassed = false
                showCaptchaChallenge = false
                await SupabaseService.shared.recordRegistrationAttempt(
                    identifier: identifier,
                    identifierType: identifierType,
                    deviceFingerprint: fingerprint,
                    attemptType: attemptType,
                    success: false,
                    failureReason: message,
                    captchaRequired: decision.requiresCaptcha,
                    auditTicket: decision.auditTicket,
                    metadata: [
                        "client": "SkyBridge Compass iOS",
                        "attempt_type": attemptType.rawValue
                    ]
                )
                throw AuthFlowError.registrationBlocked(message)
            }

            if decision.requiresCaptcha && !captchaPassed {
                captchaChallengeRequired = true
                showCaptchaChallenge = true
                let message = decision.reason ?? "请先完成安全验证"
                throw AuthFlowError.registrationBlocked(message)
            }

            captchaChallengeRequired = decision.requiresCaptcha
            return RiskCheckOutcome(
                auditTicket: decision.auditTicket,
                deviceFingerprint: fingerprint
            )
        } catch let error as AuthFlowError {
            throw error
        } catch {
            let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
            captchaChallengeRequired = false
            captchaPassed = false
            showCaptchaChallenge = false
            SkyBridgeLogger.shared.error("❌ 服务端认证风控不可用，已拒绝继续请求: \(message)")
            throw AuthFlowError.registrationBlocked("认证风控暂时不可用，请稍后再试")
        }
    }

    private func enforceLocalLoginThrottle(
        identifier: String,
        identifierType: SupabaseService.RegistrationIdentifierType
    ) throws {
        let normalizedIdentifier = SupabaseService.normalizedRegistrationIdentifier(
            identifier,
            type: identifierType
        )
        let throttleKey = "\(identifierType.rawValue):\(normalizedIdentifier)"
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.localLoginThrottleWindow)
        var timestamps = localLoginAttemptTimestamps[throttleKey, default: []]
            .filter { $0 > cutoff }

        guard timestamps.count < Self.localLoginThrottleMaxAttempts else {
            localLoginAttemptTimestamps[throttleKey] = timestamps
            captchaChallengeRequired = false
            captchaPassed = false
            showCaptchaChallenge = false
            throw AuthFlowError.registrationBlocked("登录操作过于频繁，请稍后再试")
        }

        timestamps.append(now)
        localLoginAttemptTimestamps[throttleKey] = timestamps
    }

    private func recordRegistrationAttempt(
        identifier: String,
        identifierType: SupabaseService.RegistrationIdentifierType,
        attemptType: SupabaseService.RegistrationAttemptType,
        deviceFingerprint: String,
        success: Bool,
        failureReason: String? = nil,
        auditTicket: String? = nil
    ) async {
        await SupabaseService.shared.recordRegistrationAttempt(
            identifier: identifier,
            identifierType: identifierType,
            deviceFingerprint: deviceFingerprint,
            attemptType: attemptType,
            success: success,
            failureReason: failureReason,
            captchaRequired: captchaChallengeRequired,
            captchaPassed: captchaPassed,
            auditTicket: auditTicket,
            metadata: [
                "client": "SkyBridge Compass iOS",
                "attempt_type": attemptType.rawValue
            ]
        )
    }

    public func dismissCaptchaChallenge() {
        captchaPassed = false
        captchaChallengeRequired = false
        showCaptchaChallenge = false
    }

    public func completeCaptchaChallenge(success: Bool) {
        captchaPassed = success
        showCaptchaChallenge = false
    }

    public func resetCaptchaChallenge() {
        captchaPassed = false
        showCaptchaChallenge = false
        captchaChallengeRequired = false
    }

    public func configureAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard Self.appleSignInLaunchReady else {
            pendingAppleSignInNonce = nil
            return
        }

        let rawNonce = Self.generateAppleSignInNonce()
        pendingAppleSignInNonce = rawNonce
        request.nonce = Self.sha256(rawNonce)
    }

    public func handleAppleAuthorization(_ authorization: ASAuthorization, captchaToken: String? = nil) async throws {
        guard Self.appleSignInLaunchReady else {
            throw NSError(
                domain: "AuthenticationManager.AppleSignIn",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Apple 登录暂未开放"]
            )
        }

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw NSError(
                domain: "AuthenticationManager.AppleSignIn",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "无法获取 Apple ID 凭证"]
            )
        }

        guard let identityToken = credential.identityToken,
              let identityTokenString = String(data: identityToken, encoding: .utf8) else {
            throw NSError(
                domain: "AuthenticationManager.AppleSignIn",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: "无法获取有效的 Apple 身份令牌"]
            )
        }

        guard let rawNonce = pendingAppleSignInNonce else {
            throw NSError(
                domain: "AuthenticationManager.AppleSignIn",
                code: -13,
                userInfo: [NSLocalizedDescriptionKey: "Apple 登录上下文已失效，请重试"]
            )
        }
        pendingAppleSignInNonce = nil

        let auditIdentifier = Self.appleAuditIdentifier(for: credential)
        let riskOutcome = try await ensureRegistrationAllowed(
            identifier: auditIdentifier,
            identifierType: .username,
            attemptType: .login
        )

        do {
            let session = try await SupabaseService.shared.signInWithApple(
                identityToken: identityTokenString,
                nonce: rawNonce,
                captchaToken: captchaToken
            )
            try await KeychainManager.shared.storeAppleUserID(credential.user)
            let enrichedSession = await persistAppleProfileIfNeeded(from: credential, session: session)
            let hydratedSession = await hydrateSessionProfileIfPossible(enrichedSession)
            try await applySession(
                hydratedSession,
                emailFallback: credential.email ?? hydratedSession.email ?? "\(credential.user)@appleid.local"
            )
            await recordRegistrationAttempt(
                identifier: auditIdentifier,
                identifierType: .username,
                attemptType: .login,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: true,
                auditTicket: riskOutcome.auditTicket
            )
            resetCaptchaChallenge()
        } catch {
            let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
            await recordRegistrationAttempt(
                identifier: auditIdentifier,
                identifierType: .username,
                attemptType: .login,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: false,
                failureReason: message,
                auditTicket: riskOutcome.auditTicket
            )
            throw NSError(
                domain: "AuthenticationManager.AppleSignIn",
                code: -14,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
    
    // MARK: - Public Methods
    
    /// 注册
    public func register(email: String, password: String, captchaToken: String? = nil) async throws {
        let riskOutcome = try await ensureRegistrationAllowed(
            identifier: email,
            identifierType: .email,
            attemptType: .register
        )

        // 与 macOS 端一致：注册时生成 nebula_id 并写入 Supabase metadata
        let nebulaId = try NebulaIDGenerator.shared.generateUserRegistrationID().fullId
        let displayName = email.components(separatedBy: "@").first ?? "用户"

        let session: AuthSession
        do {
            session = try await SupabaseService.shared.signUp(
                email: email,
                password: password,
                metadata: [
                    "display_name": displayName,
                    "registration_source": "SkyBridge Compass iOS",
                    "nebula_id": nebulaId,
                    "device_fingerprint": riskOutcome.deviceFingerprint
                ],
                captchaToken: captchaToken
            )
        } catch {
            await recordRegistrationAttempt(
                identifier: email,
                identifierType: .email,
                attemptType: .register,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: false,
                failureReason: SupabaseService.userMessage(for: error) ?? error.localizedDescription,
                auditTicket: riskOutcome.auditTicket
            )
            throw error
        }

        // 与 macOS 端一致：需要邮箱验证时，不进入已登录态
        if session.accessToken == "pending_verification" {
            SkyBridgeLogger.shared.info("📧 注册需要邮箱验证: \(email)")
            await recordRegistrationAttempt(
                identifier: email,
                identifierType: .email,
                attemptType: .register,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: true,
                auditTicket: riskOutcome.auditTicket
            )
            resetCaptchaChallenge()
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

        let hydratedSession = await hydrateSessionProfileIfPossible(enrichedSession)
        try await applySession(hydratedSession, emailFallback: email)
        await recordRegistrationAttempt(
            identifier: email,
            identifierType: .email,
            attemptType: .register,
            deviceFingerprint: riskOutcome.deviceFingerprint,
            success: true,
            auditTicket: riskOutcome.auditTicket
        )
        resetCaptchaChallenge()
        SkyBridgeLogger.shared.info("✅ 注册成功: \(email) (nebula_id=\(nebulaId))")
    }
    
    /// 登录
    public func signIn(email: String, password: String, captchaToken: String? = nil) async throws {
        let riskOutcome = try await ensureRegistrationAllowed(
            identifier: email,
            identifierType: .email,
            attemptType: .login
        )

        let session: AuthSession
        do {
            session = try await SupabaseService.shared.signInWithEmail(
                email: email,
                password: password,
                captchaToken: captchaToken
            )
        } catch {
            let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
            await recordRegistrationAttempt(
                identifier: email,
                identifierType: .email,
                attemptType: .login,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: false,
                failureReason: message,
                auditTicket: riskOutcome.auditTicket
            )
            throw NSError(domain: "AuthenticationManager.SignIn", code: -1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
        let hydratedSession = await hydrateSessionProfileIfPossible(session)
        try await applySession(hydratedSession, emailFallback: email)
        await recordRegistrationAttempt(
            identifier: email,
            identifierType: .email,
            attemptType: .login,
            deviceFingerprint: riskOutcome.deviceFingerprint,
            success: true,
            auditTicket: riskOutcome.auditTicket
        )
        resetCaptchaChallenge()
        SkyBridgeLogger.shared.info("✅ 登录成功: \(email)")
    }

    /// 发送手机号验证码。Supabase 负责验证码校验与会话签发，短信投递由 send_sms hook 转发到阿里云。
    public func sendPhoneVerificationCode(phoneNumber: String, captchaToken: String? = nil) async throws {
        let riskOutcome = try await ensureRegistrationAllowed(
            identifier: phoneNumber,
            identifierType: .phone,
            attemptType: .verifyCode
        )

        do {
            try await SupabaseService.shared.sendPhoneOTP(phone: phoneNumber, captchaToken: captchaToken)
        } catch {
            await recordRegistrationAttempt(
                identifier: phoneNumber,
                identifierType: .phone,
                attemptType: .verifyCode,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: false,
                failureReason: SupabaseService.userMessage(for: error) ?? error.localizedDescription,
                auditTicket: riskOutcome.auditTicket
            )
            throw error
        }

        await recordRegistrationAttempt(
            identifier: phoneNumber,
            identifierType: .phone,
            attemptType: .verifyCode,
            deviceFingerprint: riskOutcome.deviceFingerprint,
            success: true,
            auditTicket: riskOutcome.auditTicket
        )
        resetCaptchaChallenge()
        SkyBridgeLogger.shared.info("📱 手机验证码已发出: ****\(phoneNumber.suffix(4))")
    }

    public func resetPassword(email: String, captchaToken: String? = nil) async throws {
        let riskOutcome = try await ensureRegistrationAllowed(
            identifier: email,
            identifierType: .email,
            attemptType: .verifyCode
        )

        do {
            try await SupabaseService.shared.resetPassword(email: email, captchaToken: captchaToken)
            await recordRegistrationAttempt(
                identifier: email,
                identifierType: .email,
                attemptType: .verifyCode,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: true,
                auditTicket: riskOutcome.auditTicket
            )
            resetCaptchaChallenge()
        } catch {
            let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
            await recordRegistrationAttempt(
                identifier: email,
                identifierType: .email,
                attemptType: .verifyCode,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: false,
                failureReason: message,
                auditTicket: riskOutcome.auditTicket
            )
            throw NSError(domain: "AuthenticationManager.ResetPassword", code: -1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    /// 使用手机号 + 短信验证码登录；若手机号首次使用，Supabase 会按项目策略自动创建账号。
    public func signInWithPhone(phoneNumber: String, code: String) async throws {
        let riskOutcome = try await ensureRegistrationAllowed(
            identifier: phoneNumber,
            identifierType: .phone,
            attemptType: .login
        )

        let session: AuthSession
        do {
            session = try await SupabaseService.shared.signInWithPhone(phone: phoneNumber, token: code)
        } catch {
            let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
            await recordRegistrationAttempt(
                identifier: phoneNumber,
                identifierType: .phone,
                attemptType: .login,
                deviceFingerprint: riskOutcome.deviceFingerprint,
                success: false,
                failureReason: message,
                auditTicket: riskOutcome.auditTicket
            )
            throw NSError(domain: "AuthenticationManager.PhoneSignIn", code: -1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
        let hydratedSession = await hydrateSessionProfileIfPossible(session)
        try await applySession(hydratedSession, emailFallback: phoneNumber)
        await recordRegistrationAttempt(
            identifier: phoneNumber,
            identifierType: .phone,
            attemptType: .login,
            deviceFingerprint: riskOutcome.deviceFingerprint,
            success: true,
            auditTicket: riskOutcome.auditTicket
        )
        resetCaptchaChallenge()
        SkyBridgeLogger.shared.info("✅ 手机登录成功: ****\(phoneNumber.suffix(4))")
    }

    /// Nebula 安全浏览器登录（OAuth 2.1 + PKCE）
    public func signInWithNebulaBrowser() async throws {
        let (tokenResponse, userInfo) = try await NebulaPublicClientOAuth.shared.authenticateUsingSystemBrowser()
        let displayName = userInfo.name ?? userInfo.preferredUsername ?? userInfo.email ?? "Nebula User"
        let email = userInfo.email ?? "\(userInfo.subject)@nebula.local"
        let nebulaId = Self.resolvedNebulaId(from: userInfo)
        let session = AuthSession(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            userIdentifier: userInfo.subject,
            displayName: displayName,
            email: userInfo.email,
            avatarURL: userInfo.picture,
            nebulaId: nebulaId,
            issuedAt: Date()
        )
        try await applySession(session, emailFallback: email)
        SkyBridgeLogger.shared.info("✅ Nebula 浏览器登录成功: \(displayName)")
    }

    /// Nebula 安全浏览器注册（OAuth 2.1 + PKCE）
    public func registerWithNebulaBrowser() async throws {
        let (tokenResponse, userInfo) = try await NebulaPublicClientOAuth.shared.registerUsingSystemBrowser()
        let displayName = userInfo.name ?? userInfo.preferredUsername ?? userInfo.email ?? "Nebula User"
        let email = userInfo.email ?? "\(userInfo.subject)@nebula.local"
        let nebulaId = Self.resolvedNebulaId(from: userInfo)
        let session = AuthSession(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            userIdentifier: userInfo.subject,
            displayName: displayName,
            email: userInfo.email,
            avatarURL: userInfo.picture,
            nebulaId: nebulaId,
            issuedAt: Date()
        )
        try await applySession(session, emailFallback: email)
        SkyBridgeLogger.shared.info("✅ Nebula 浏览器注册成功: \(displayName)")
    }

    /// 手动刷新账号资料（NebulaID/头像/昵称等），与 macOS 持久化体验对齐
    public func refreshProfile() async {
        await refreshProfileIfPossible()
    }
    
    /// 游客模式登录
    public func signInAsGuest() async throws {
        try await clearSession()

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
    public func signOut() async throws {
        let sessionToRevoke = session
        try await clearSession()

        currentUser = nil
        isAuthenticated = false
        isGuestMode = false
        session = nil

        if let sessionToRevoke {
            do {
                try await revokeRemoteSession(sessionToRevoke)
            } catch {
                SkyBridgeLogger.shared.warning("⚠️ 远端会话撤销失败，本地仍将退出: \(error.localizedDescription)")
            }
        }

        SkyBridgeLogger.shared.info("👋 已退出登录")
    }
    
    // MARK: - Private Methods
    
    private func loadSession() async {
        do {
            guard let session = try await KeychainManager.shared.loadAuthSessionStrict() else {
                return
            }
            applyPersistedSession(session)
        } catch {
            session = nil
            currentUser = nil
            isAuthenticated = false
            isGuestMode = false
            SkyBridgeLogger.shared.error("❌ 持久化登录态读取失败: \(error.localizedDescription)")
        }
    }
    
    private func persistSession(_ session: AuthSession) async throws {
        try await KeychainManager.shared.storeAuthSession(session)
    }
    
    private func clearSession() async throws {
        try await KeychainManager.shared.deleteAuthSession()
    }

#if DEBUG || SKYBRIDGE_TESTING
    func installSmokeRemoteDesktopSession(
        accessToken: String,
        effectiveTenantID: String
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SKYBRIDGE_SMOKE_ROLE"] == "ios-client",
              environment["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1",
              environment["SKYBRIDGE_SMOKE_BOOTSTRAP_RUN_ID"]?.isEmpty == false else {
            throw SmokeRemoteDesktopSessionError.disabled
        }

        let normalizedAccessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEffectiveTenantID = effectiveTenantID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedAccessToken == accessToken,
              !normalizedAccessToken.isEmpty,
              normalizedEffectiveTenantID == effectiveTenantID,
              !normalizedEffectiveTenantID.isEmpty,
              normalizedEffectiveTenantID.utf8.count <= 256,
              !normalizedEffectiveTenantID.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
              ) else {
            throw SmokeRemoteDesktopSessionError.invalidCredentials
        }
        let identity = try SignalServerClientCompat.resolveAuthenticatedJWTIdentity(
            accessToken: normalizedAccessToken
        )
        guard identity.effectiveTenantID == normalizedEffectiveTenantID else {
            throw SmokeRemoteDesktopSessionError.invalidCredentials
        }

        try Task.checkCancellation()
        let displayName = "Smoke Remote Viewer"
        let smokeSession = AuthSession(
            accessToken: normalizedAccessToken,
            refreshToken: nil,
            userIdentifier: identity.subject,
            displayName: displayName,
            email: "smoke@skybridge.local",
            nebulaId: identity.explicitTenantID,
            issuedAt: Date()
        )
        try await persistSession(smokeSession)

        // Persistence is the commit point. Once it succeeds, synchronously publish the matching
        // in-memory state so UI and signaling cannot observe different authentication identities.
        session = smokeSession
        currentUser = User(
            id: identity.subject,
            email: "smoke@skybridge.local",
            displayName: displayName,
            nebulaId: identity.effectiveTenantID
        )
        isAuthenticated = true
        isGuestMode = false
        isRestoringSession = false
        SkyBridgeLogger.shared.info("🧪 One-time real-device smoke authentication session installed")
    }

    /// Verifies that a physical acceptance run is using the already-persisted product session.
    /// The bootstrap token is authority material for comparison only; it is never written into the
    /// system Keychain, so a smoke run cannot replace the user's product login state.
    func validateSystemSmokeRemoteDesktopSession(
        accessToken: String,
        effectiveTenantID: String
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SKYBRIDGE_SMOKE_ROLE"] == "ios-client",
              environment["SKYBRIDGE_SMOKE_KEYCHAIN_MODE"] == "system",
              environment["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] != "1",
              environment["SKYBRIDGE_SMOKE_BOOTSTRAP_RUN_ID"]?.isEmpty == false else {
            throw SmokeRemoteDesktopSessionError.disabled
        }

        let bootstrapIdentity = try SignalServerClientCompat.resolveAuthenticatedJWTIdentity(
            accessToken: accessToken
        )
        guard bootstrapIdentity.effectiveTenantID == effectiveTenantID,
              let persistedSession = try await KeychainManager.shared.loadAuthSessionStrict() else {
            throw SmokeRemoteDesktopSessionError.invalidCredentials
        }
        let persistedIdentity = try SignalServerClientCompat.resolveAuthenticatedJWTIdentity(
            accessToken: persistedSession.accessToken
        )
        guard persistedIdentity.subject == bootstrapIdentity.subject,
              persistedIdentity.effectiveTenantID == bootstrapIdentity.effectiveTenantID else {
            throw SmokeRemoteDesktopSessionError.invalidCredentials
        }

        try Task.checkCancellation()
        applyPersistedSession(persistedSession)
        isRestoringSession = false
        SkyBridgeLogger.shared.info("🧪 Real-device smoke verified the existing system-Keychain product session")
    }
#endif

    private func revokeRemoteSession(_ session: AuthSession) async throws {
        let accessToken = session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty,
              accessToken != "guest_token",
              accessToken != "pending_verification" else {
            return
        }

        if SupabaseService.shared.isSupabaseAccessToken(accessToken) {
            try await SupabaseService.shared.revokeCurrentSession(accessToken: accessToken)
        } else {
            try await NebulaPublicClientOAuth.shared.revokeTokens(
                accessToken: accessToken,
                refreshToken: session.refreshToken
            )
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    private func applyUITestGuestSession() {
        currentUser = User(
            id: "uitest-guest",
            email: "guest@skybridge.local",
            displayName: "游客"
        )
        isAuthenticated = true
        isGuestMode = true
        session = nil
    }
#endif

#if DEBUG || SKYBRIDGE_TESTING
    private func applyP2PSmokeGuestSession() {
        currentUser = User(
            id: "p2p-smoke-guest",
            email: "p2p-smoke@skybridge.local",
            displayName: "P2P Smoke"
        )
        isAuthenticated = true
        isGuestMode = true
        session = nil
        SkyBridgeLogger.shared.info("🧪 P2P smoke guest session installed for visible RemoteDesktopView path")
    }
#endif

    private func applyPersistedSession(_ session: AuthSession) {
        self.session = session
        let email = session.email ?? (session.displayName.contains("@") ? session.displayName : "user@skybridge.local")
        let displayName = session.displayName.isEmpty ? (email.components(separatedBy: "@").first ?? "用户") : session.displayName
        let avatarURL = session.avatarURL.flatMap(URL.init(string:))
        currentUser = User(
            id: session.userIdentifier,
            email: email,
            displayName: displayName,
            avatarURL: avatarURL,
            nebulaId: session.nebulaId
        )
        isAuthenticated = true
        isGuestMode = false

        // 登录成功后自动刷新一次，确保 iOS 与 macOS 的 nebula_id/avatar 等一致并持久化
        Task { [weak self] in
            guard let self else { return }
            await self.refreshProfileIfPossible()
        }
    }

    private func applySession(_ session: AuthSession, emailFallback: String) async throws {
        try await persistSession(session)
        self.session = session
        let displayName = session.displayName.isEmpty ? (emailFallback.components(separatedBy: "@").first ?? "用户") : session.displayName
        let avatarURL = session.avatarURL.flatMap(URL.init(string:))
        currentUser = User(
            id: session.userIdentifier,
            email: session.email ?? emailFallback,
            displayName: displayName,
            avatarURL: avatarURL,
            nebulaId: session.nebulaId
        )
        isAuthenticated = true
        isGuestMode = false

        // 登录成功后自动刷新一次，确保 iOS 与 macOS 的 nebula_id/avatar 等一致并持久化
        Task { [weak self] in
            guard let self else { return }
            await self.refreshProfileIfPossible()
        }
    }

    private func hydrateSessionProfileIfPossible(_ session: AuthSession) async -> AuthSession {
        let isSupabaseConfigured = await hasSupabaseConfiguration()
        guard Self.shouldAttemptSupabaseProfileHydration(
            session: session,
            isSupabaseConfigured: isSupabaseConfigured
        ) else {
            return session
        }

        do {
            let profile = try await SupabaseService.shared.fetchCurrentUserProfile(
                accessToken: session.accessToken
            )
            return AuthSession(
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                userIdentifier: session.userIdentifier,
                displayName: profile.displayName ?? session.displayName,
                email: profile.email ?? session.email,
                avatarURL: profile.avatarURL ?? session.avatarURL,
                nebulaId: profile.nebulaId ?? session.nebulaId,
                issuedAt: session.issuedAt
            )
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ 登录态资料补水失败（忽略）：\(error.localizedDescription)")
            return session
        }
    }

    private func refreshProfileIfPossible() async {
        guard isAuthenticated, !isGuestMode else { return }
        guard let session, session.accessToken != "pending_verification" else { return }
        guard await hasSupabaseConfiguration() else {
            // 配置缺失时不刷屏：只提示一次即可
            if !didLogSupabaseConfigMissing {
                didLogSupabaseConfigMissing = true
                SkyBridgeLogger.shared.info("ℹ️ Supabase 配置缺失：跳过账号资料刷新（请在设置中配置或提供 SupabaseConfig.plist）")
            }
            return
        }
        guard Self.shouldAttemptSupabaseProfileHydration(
            session: session,
            isSupabaseConfigured: true
        ) else {
            return
        }

        do {
            let profile = try await SupabaseService.shared.fetchCurrentUserProfile(accessToken: session.accessToken)
            await applyRemoteProfile(profile)
        } catch {
            // 若是 token 过期，尝试 refresh_token 后重试一次
            if await tryRefreshTokenIfNeeded(because: error) {
                if let updated = self.session {
                    do {
                        let profile = try await SupabaseService.shared.fetchCurrentUserProfile(
                            accessToken: updated.accessToken
                        )
                        await applyRemoteProfile(profile)
                    } catch {
                        SkyBridgeLogger.shared.debug("ℹ️ 刷新令牌后的资料加载失败: \(error.localizedDescription)")
                    }
                }
                return
            }

            // 网络/配置失败不影响主流程
            SkyBridgeLogger.shared.debug("ℹ️ 账号资料刷新失败（忽略）：\(error.localizedDescription)")
        }
    }

    private func hasSupabaseConfiguration() async -> Bool {
        do {
            return try await SupabaseService.shared.availableConfiguration(logIfMissing: false) != nil
        } catch {
            SkyBridgeLogger.shared.error("❌ Supabase 安全配置读取失败: \(error.localizedDescription)")
            return false
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
            let merged = try SignalServerClientCompat.validatedRefreshedAuthSession(
                refreshed,
                replacing: session,
                explicitTenantID: nil,
                now: Date()
            )
            guard self.session == session else {
                throw SignalServerClientCompat.ClientError.authenticationSessionChanged
            }
            let replaced = try await KeychainManager.shared.replaceAuthSession(
                expected: session,
                with: merged
            )
            guard replaced, self.session == session else {
                throw SignalServerClientCompat.ClientError.authenticationSessionChanged
            }
            self.session = merged
            SkyBridgeLogger.shared.info("🔄 Supabase access token 已刷新")
            return true
        } catch {
            SkyBridgeLogger.shared.error("❌ Supabase token 刷新失败：\(error.localizedDescription)")
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

    private func applyRemoteProfile(_ profile: SupabaseService.RemoteUserProfile) async {
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
        do {
            try await persistSession(updatedSession)
        } catch {
            SkyBridgeLogger.shared.error("❌ 远端账号资料持久化失败: \(error.localizedDescription)")
            return
        }
        self.session = updatedSession

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

    internal static func shouldAttemptSupabaseProfileHydration(
        session: AuthSession,
        isSupabaseConfigured: Bool
    ) -> Bool {
        guard isSupabaseConfigured, session.accessToken != "pending_verification" else {
            return false
        }

        if SupabaseService.shared.isSupabaseAccessToken(session.accessToken) {
            return true
        }

        return UUID(uuidString: session.userIdentifier) != nil
    }

    private func checkAppleIDCredentialState() async {
        guard Self.appleSignInLaunchReady else {
            appleAuthorizationState = .notFound
            return
        }

        let userID: String
        do {
            guard let persistedUserID = try await KeychainManager.shared.retrieveAppleUserID() else {
                appleAuthorizationState = .notFound
                return
            }
            userID = persistedUserID
        } catch {
            appleAuthorizationState = .notFound
            SkyBridgeLogger.shared.error("❌ Apple 登录标识读取失败: \(error.localizedDescription)")
            return
        }

        let provider = ASAuthorizationAppleIDProvider()
        do {
            let state = try await provider.credentialState(forUserID: userID)
            appleAuthorizationState = state
            if state == .revoked || state == .notFound {
                try await KeychainManager.shared.deleteAppleUserID()
            }
        } catch {
            appleAuthorizationState = .notFound
            SkyBridgeLogger.shared.error("❌ Apple 凭据状态检查失败: \(error.localizedDescription)")
        }
    }

    private func persistAppleProfileIfNeeded(
        from credential: ASAuthorizationAppleIDCredential,
        session: AuthSession
    ) async -> AuthSession {
        guard let displayName = Self.formattedAppleDisplayName(from: credential.fullName) else {
            return session
        }

        if session.accessToken != "pending_verification",
           SupabaseService.shared.isSupabaseAccessToken(session.accessToken) {
            do {
                try await SupabaseService.shared.updateCurrentUserMetadata(
                    accessToken: session.accessToken,
                    metadata: [
                        "display_name": displayName,
                        "full_name": displayName,
                        "name": displayName,
                        "sign_in_provider": "apple"
                    ]
                )
            } catch {
                SkyBridgeLogger.shared.warning("⚠️ Apple 首登资料回写失败（忽略）：\(error.localizedDescription)")
            }
        }

        guard Self.shouldReplaceDisplayName(session.displayName) else {
            return session
        }

        return AuthSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userIdentifier: session.userIdentifier,
            displayName: displayName,
            email: session.email,
            avatarURL: session.avatarURL,
            nebulaId: session.nebulaId,
            issuedAt: session.issuedAt
        )
    }

    private static func appleAuditIdentifier(for credential: ASAuthorizationAppleIDCredential) -> String {
        "apple:\(credential.user)"
    }

    private static func formattedAppleDisplayName(from fullName: PersonNameComponents?) -> String? {
        guard let fullName else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let formatted = formatter.string(from: fullName).trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted.isEmpty ? nil : formatted
    }

    private static func shouldReplaceDisplayName(_ displayName: String) -> Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "用户" || trimmed == "新用户"
    }

    private static func generateAppleSignInNonce(length: Int = 32) -> String {
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
            result.append(charset[Int(byte) % charset.count])
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

}
