import Foundation
@preconcurrency import Combine
import SwiftUI
import AuthenticationServices
import LocalAuthentication
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

        var title: String {
            switch self {
            case .apple: return "Apple ID"
            case .nebula: return "星云账号"
            case .phone: return "手机号码"
            case .email: return "电子邮箱"
            }
        }

        var subtitle: String {
            switch self {
            case .apple: return "使用Face ID或Touch ID快速登录"
            case .nebula: return "企业专属星云身份认证"
            case .phone: return "短信验证码安全登录"
            case .email: return "邮箱密码传统登录"
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

 // MARK: - 发布属性

    @Published var currentSession: AuthSession?
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var selectedMethod: LoginMethod = .apple
    @Published var isGuestMode = false
    @Published var supabaseNebulaId: String?

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
    @Published var rememberCredentials = false // 记住账号密码开关

 // MARK: - 安全验证属性
    @Published var requiresCaptcha: Bool = false  // 是否需要行为验证
    @Published var showCaptchaView: Bool = false  // 是否显示验证码视图
    @Published var captchaPassed: Bool = false    // 验证码是否通过
    @Published var currentPasswordStrength: PasswordStrength = .weak  // 当前密码强度

 // MARK: - 私有属性

    private let authService: AuthenticationService
    private var cancellables = Set<AnyCancellable>()
    private var phoneCodeTimer: Timer?
    private var nebulaBrowserSession: ASWebAuthenticationSession?
    private let nebulaPresentationContextProvider = NebulaBrowserPresentationContextProvider()

 /// 当前设备指纹（懒加载）
    private var deviceFingerprint: String?

    /// 用于 UI 展示的“星云ID”（优先使用 Supabase user_metadata.nebula_id）
    var displayedNebulaId: String {
        if let value = supabaseNebulaId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let fallback = currentSession?.userIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
           Self.isCanonicalNebulaId(fallback) {
            return fallback
        }
        return "未同步"
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
                guard let self, let session else { return }
                Task {
                    await self.loadUserNebulaIdAfterLogin(session: session)
                }
            }
            .store(in: &cancellables)

 // 检查Apple ID授权状态
        checkAppleIDCredentialState()

 // 加载已保存的登录凭据
        loadSavedCredentials()

 // 初始化设备指纹
        Task {
            await loadDeviceFingerprint()
        }
    }

 // MARK: - 安全检查方法

 /// 加载设备指纹
    private func loadDeviceFingerprint() async {
        let fingerprint = await SelfIdentityProvider.shared.generateRegistrationFingerprint()
        self.deviceFingerprint = fingerprint
        SkyBridgeLogger.ui.debugOnly("🔐 设备指纹已加载: \(fingerprint.prefix(16))...")
    }

 /// 执行注册前安全检查
 /// - Parameters:
 /// - identifier: 用户标识（手机号/邮箱）
 /// - identifierType: 标识类型
 /// - Returns: 是否允许继续注册
    private func performSecurityCheck(identifier: String, identifierType: RegistrationSecurityService.RegistrationContext.IdentifierType) async -> Bool {
 // 确保设备指纹已加载
        if deviceFingerprint == nil {
            await loadDeviceFingerprint()
        }

        guard let fingerprint = deviceFingerprint else {
            SkyBridgeLogger.ui.error("❌ 设备指纹获取失败")
            errorMessage = "设备验证失败，请重试"
            return false
        }

 // 构建注册上下文
        let context = RegistrationSecurityService.RegistrationContext(
            ip: "client",  // 客户端无法获取真实IP，由服务端获取
            deviceFingerprint: fingerprint,
            identifier: identifier,
            identifierType: identifierType
        )

 // 检查是否允许注册
        let result = await RegistrationSecurityService.shared.canRegister(context: context)

        if !result.allowed {
            SkyBridgeLogger.ui.warning("⚠️ 注册被拒绝: \(result.reason ?? "未知原因")")
            errorMessage = result.reason ?? "注册失败，请稍后再试"

            if let retryAfter = result.retryAfter {
                let minutes = Int(retryAfter / 60)
                if minutes > 0 {
                    errorMessage = "\(errorMessage ?? "")（\(minutes)分钟后可重试）"
                }
            }

            return false
        }

        if result.requiresCaptcha {
            SkyBridgeLogger.ui.info("🔒 需要行为验证")
            requiresCaptcha = true

 // 如果验证码未通过，显示验证码视图
            if !captchaPassed {
                showCaptchaView = true
                return false
            }
        }

        return true
    }

 /// 处理行为验证完成
    func onCaptchaVerificationComplete(success: Bool, error: String?) {
        captchaPassed = success
        showCaptchaView = false

        if !success {
            errorMessage = error ?? "验证失败，请重试"
        }
    }

 /// 记录注册尝试
    private func recordRegistrationAttempt(identifier: String, identifierType: RegistrationSecurityService.RegistrationContext.IdentifierType, success: Bool, failureReason: String? = nil) async {
        guard let fingerprint = deviceFingerprint else { return }

        let context = RegistrationSecurityService.RegistrationContext(
            ip: "client",
            deviceFingerprint: fingerprint,
            identifier: identifier,
            identifierType: identifierType
        )

        await RegistrationSecurityService.shared.recordAttempt(
            context: context,
            success: success,
            failureReason: failureReason
        )
    }

 // MARK: - Apple登录

 /// 检查Apple ID凭据状态
    private func checkAppleIDCredentialState() {
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

 /// 处理Apple登录授权结果
    func handleAppleAuthorization(_ authorization: ASAuthorization) async {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            await MainActor.run {
                self.errorMessage = "无法获取Apple ID凭证"
            }
            return
        }

        guard let identityToken = appleIDCredential.identityToken else {
            await MainActor.run {
                self.errorMessage = "无法获取身份令牌"
            }
            return
        }

        try? KeychainManager.shared.storeAppleUserID(appleIDCredential.user)

        await performAuthenticationTask {
            try await self.authService.authenticateWithApple(
                identityToken: identityToken,
                authorizationCode: appleIDCredential.authorizationCode
            )
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
            throw NSError(domain: "Nebula", code: -1, userInfo: [NSLocalizedDescriptionKey: "请输入完整的账号和密码"])
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

    private func registerWithNebulaUsingBrowser() async throws -> AuthSession {
        let authorizationRequest = try NebulaPublicClientOAuth.shared.makeRegistrationAuthorizationRequest(
            redirectURI: "skybridge://auth/nebula"
        )
        return try await completeNebulaBrowserAuthorization(authorizationRequest)
    }

    private func completeNebulaBrowserAuthorization(_ authorizationRequest: NebulaPublicClientOAuth.AuthorizationRequest) async throws -> AuthSession {
        let callbackURL = try await startNebulaBrowserSession(
            url: authorizationRequest.authorizationURL,
            callbackScheme: "skybridge"
        )

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "Nebula", code: -2, userInfo: [NSLocalizedDescriptionKey: "Nebula 回调地址无效"])
        }

        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let error = queryItems["error"], !error.isEmpty {
            let description = queryItems["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error
            throw NSError(domain: "Nebula", code: -3, userInfo: [NSLocalizedDescriptionKey: description])
        }

        let returnedState = queryItems["state"] ?? ""
        guard returnedState == authorizationRequest.state else {
            throw NSError(domain: "Nebula", code: -4, userInfo: [NSLocalizedDescriptionKey: "Nebula 登录状态校验失败"])
        }

        guard let code = queryItems["code"], !code.isEmpty else {
            throw NSError(domain: "Nebula", code: -5, userInfo: [NSLocalizedDescriptionKey: "Nebula 未返回授权码"])
        }

        let tokenResponse = try await NebulaPublicClientOAuth.shared.exchangeAuthorizationCode(
            code,
            authorizationRequest: authorizationRequest
        )
        let userInfo = try await NebulaPublicClientOAuth.shared.fetchUserInfo(accessToken: tokenResponse.accessToken)

        let displayName = userInfo.name ?? userInfo.preferredUsername ?? userInfo.email ?? "Nebula User"
        let session = AuthSession(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            userIdentifier: userInfo.subject,
            displayName: displayName,
            issuedAt: Date()
        )
        try authService.updateSession(session)
        return session
    }

    private func startNebulaBrowserSession(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                Task { @MainActor in
                    self.nebulaBrowserSession = nil
                }

                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: NSError(domain: "Nebula", code: -6, userInfo: [NSLocalizedDescriptionKey: "Nebula 浏览器登录已取消"]))
                }
            }
            session.presentationContextProvider = nebulaPresentationContextProvider
            session.prefersEphemeralWebBrowserSession = false
            self.nebulaBrowserSession = session

            if !session.start() {
                self.nebulaBrowserSession = nil
                continuation.resume(throwing: NSError(domain: "Nebula", code: -7, userInfo: [NSLocalizedDescriptionKey: "无法启动 Nebula 浏览器登录"]))
            }
        }
    }

 /// 验证星云MFA
    @MainActor
    func verifyMFA() async {
        guard !mfaToken.isEmpty && !mfaCode.isEmpty else {
            errorMessage = "请输入验证码"
            return
        }

        isProcessing = true
        errorMessage = nil

        do {
            let session = try await authService.verifyNebulaMFA(
                mfaToken: mfaToken,
                code: mfaCode
            )

            await loadUserAvatarAfterLogin(session: session)
            await loadUserNebulaIdAfterLogin(session: session)

            currentSession = session
            showMFAInput = false
            mfaToken = ""
            mfaCode = ""
        } catch {
            errorMessage = "MFA验证失败: \(error.localizedDescription)"
        }

        isProcessing = false
    }

 // MARK: - 手机号登录

 /// 发送手机验证码
    func sendPhoneVerificationCode() async {
        await sendPhoneCode(isResend: false)
    }

 /// 手机号登录
    func loginWithPhone() async {
        guard isValidPhoneNumber(phoneNumber) else {
            errorMessage = "请输入有效的手机号码"
            return
        }

        guard !phoneVerificationCode.isEmpty else {
            errorMessage = "请输入验证码"
            return
        }

        await performAuthenticationTask {
            try await self.authService.loginPhone(
                number: self.phoneNumber,
                code: self.phoneVerificationCode
            )
        }
    }

 /// 重新发送验证码（收不到验证码）
    func resendPhoneVerificationCode() async {
        await sendPhoneCode(isResend: true)
    }

 /// 通过智能通道发送验证码（含重试/降级/风控）
    private func sendPhoneCode(isResend: Bool) async {
 // 基础校验
        guard isValidPhoneNumber(phoneNumber) else {
            await MainActor.run { errorMessage = "请输入正确的手机号码" }
            return
        }

 // 确保设备指纹
        if deviceFingerprint == nil {
            await loadDeviceFingerprint()
        }
        guard let fingerprint = deviceFingerprint else {
            await MainActor.run { errorMessage = "设备校验失败，请重试" }
            return
        }

        await MainActor.run {
            isProcessing = true
            errorMessage = nil
        }

 // 发送验证码
        let context = VerificationCodeService.SendContext(
            phoneNumber: phoneNumber,
            deviceFingerprint: fingerprint,
            ip: "client", // 服务器侧获取真实IP
            isResend: isResend,
            captchaPassed: captchaPassed
        )

        let result = await VerificationCodeService.shared.sendVerificationCode(
            context: context
        )

        await MainActor.run {
            isProcessing = false

            if result.success {
 // 发送成功，启动倒计时
                isPhoneCodeSent = true
                startPhoneCodeCountdown()
                captchaPassed = false
                requiresCaptcha = false
                errorMessage = "验证码已发送"
            } else {
 // 需要验证码
                if result.requiresCaptcha {
                    requiresCaptcha = true
                    showCaptchaView = true
                    errorMessage = result.errorMessage ?? "请完成安全验证"
                    return
                }

 // 普通失败，显示原因
                errorMessage = result.errorMessage ?? "发送验证码失败，请稍后重试"

 // 如果有下一次可重试时间，则更新倒计时提示
                if let nextRetry = result.nextRetryAvailableAt {
                    let seconds = Int(nextRetry.timeIntervalSinceNow)
                    if seconds > 0 {
                        phoneCodeCountdown = seconds
                        isPhoneCodeSent = false
                    }
                }
            }
        }
    }

 /// 开始验证码倒计时
    private func startPhoneCodeCountdown() {
        phoneCodeCountdown = 60
        phoneCodeTimer?.invalidate()
        phoneCodeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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

        var description: String {
            switch self {
            case .weak: return "弱"
            case .medium: return "中等"
            case .strong: return "强"
            case .veryStrong: return "非常强"
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
            return (false, .weak, "密码至少需要8个字符")
        }

 // 最大长度检查
        if sanitized.count > 128 {
            return (false, .weak, "密码最多128个字符")
        }

        let strength = evaluatePasswordStrength(sanitized)

        if strength < minimumStrength {
            var requirements: [String] = []
            if !sanitized.contains(where: { $0.isUppercase }) {
                requirements.append("大写字母")
            }
            if !sanitized.contains(where: { $0.isLowercase }) {
                requirements.append("小写字母")
            }
            if !sanitized.contains(where: { $0.isNumber }) {
                requirements.append("数字")
            }
            if !sanitized.contains(where: { "!@#$%^&*()_+-=[]{}|;':\",./<>?".contains($0) }) {
                requirements.append("特殊字符")
            }

            let requirementText = requirements.isEmpty ? "" : "，建议添加：\(requirements.joined(separator: "、"))"
            return (false, strength, "密码强度不足\(requirementText)")
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
            return (false, "用户名至少需要4个字符")
        }

        if sanitized.count > 20 {
            return (false, "用户名最多20个字符")
        }

 // 字符检查：只允许字母、数字和下划线
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let invalidChars = sanitized.unicodeScalars.filter { !allowedCharacters.contains($0) }
        if !invalidChars.isEmpty {
            return (false, "用户名只能包含字母、数字和下划线")
        }

 // 保留名检查
        let reservedNames: Set<String> = ["admin", "root", "system", "support", "help", "test", "null", "undefined"]
        if reservedNames.contains(sanitized) {
            return (false, "该用户名已被保留")
        }

 // 不能以数字开头
        if let first = sanitized.first, first.isNumber {
            return (false, "用户名不能以数字开头")
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
    func registerWithEmail() async {
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
            errorMessage = "请输入有效的邮箱地址"
            return
        }

 // 检查一次性邮箱
        guard !isDisposableEmail(sanitizedEmail) else {
            SkyBridgeLogger.ui.error("❌ [注册流程] 一次性邮箱被拦截: \(self.emailAddress, privacy: .private)")
            errorMessage = "不支持使用临时邮箱注册"
            return
        }

 // 密码强度校验
        let passwordValidation = validatePasswordStrength(sanitizedPassword, minimumStrength: .medium)
        guard passwordValidation.valid else {
            SkyBridgeLogger.ui.error("❌ [注册流程] 密码强度不足: \(passwordValidation.strength.description)")
            errorMessage = passwordValidation.error ?? "密码强度不足"
            return
        }

 // 密码确认校验
        guard sanitizedPassword == sanitizedConfirmPassword else {
            SkyBridgeLogger.ui.error("❌ [注册流程] 密码确认不匹配")
            errorMessage = "两次输入的密码不一致"
            return
        }

 // 更新清洗后的值
        emailAddress = sanitizedEmail
        emailPassword = sanitizedPassword

        SkyBridgeLogger.ui.debugOnly("✅ [注册流程] 输入验证通过，开始安全检查")

 // 🔒 安全检查：限流和设备指纹验证
        let securityCheckPassed = await performSecurityCheck(
            identifier: sanitizedEmail,
            identifierType: .email
        )

        guard securityCheckPassed else {
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
            errorMessage = "ID生成失败，请重试"
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
            SkyBridgeLogger.ui.debugOnly("   元数据: display_name=\(emailAddress.components(separatedBy: "@").first ?? "用户")")

 // 使用Supabase注册，将 nebulaid 添加到 metadata 中
            let authSession = try await SupabaseService.shared.signUp(
                email: emailAddress,
                password: emailPassword,
                metadata: [
                    "display_name": emailAddress.components(separatedBy: "@").first ?? "用户",
                    "registration_source": "SkyBridge Compass Pro",
                    "nebula_id": nebulaId  // 🔥 添加 nebulaid 到元数据
                ]
            )

            SkyBridgeLogger.ui.debugOnly("✅ [注册流程] Supabase注册成功")
            SkyBridgeLogger.ui.debugOnly("   用户ID: \(authSession.userIdentifier)")
            SkyBridgeLogger.ui.debugOnly("   NebulaID: \(nebulaId)")
            SkyBridgeLogger.ui.debugOnly("   显示名称: \(authSession.displayName)")
            SkyBridgeLogger.ui.debugOnly("   访问令牌: \(String(authSession.accessToken.prefix(10)))...")

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

 // 📧 发送注册成功邮件通知
            Task {
                do {
                    let username = emailAddress.components(separatedBy: "@").first ?? "用户"
                    _ = try await EmailService.shared.sendRegistrationSuccessEmail(
                        to: emailAddress,
                        username: username,
                        nebulaId: nebulaId
                    )
                    SkyBridgeLogger.ui.debugOnly("📧 [注册流程] 注册成功邮件已发送")
                } catch {
                    SkyBridgeLogger.ui.warning("⚠️ [注册流程] 注册成功邮件发送失败: \(error.localizedDescription)")
 // 不阻塞注册流程
                }
            }

 // 📝 记录成功的注册尝试
            await recordRegistrationAttempt(
                identifier: emailAddress,
                identifierType: .email,
                success: true
            )

            await MainActor.run {
                self.emailVerificationSent = true
                self.isProcessing = false
                self.captchaPassed = false  // 重置验证码状态
                self.requiresCaptcha = false
                self.errorMessage = "注册成功！请检查邮箱并点击验证链接"
                SkyBridgeLogger.ui.debugOnly("✅ [注册流程] UI状态已更新 - emailVerificationSent=true")
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
                success: false,
                failureReason: error.localizedDescription
            )

            await MainActor.run {
                let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
                self.errorMessage = "注册失败：\(message)"
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
            errorMessage = "请输入手机号码"
            return
        }

        guard isValidPhoneNumber(phoneNumber) else {
            errorMessage = "请输入有效的手机号码"
            return
        }

        guard !phoneDisplayName.isEmpty else {
            errorMessage = "请输入显示名称"
            return
        }

        guard !phoneEmail.isEmpty else {
            errorMessage = "请输入邮箱地址"
            return
        }

        guard isValidEmail(phoneEmail) else {
            errorMessage = "请输入有效的邮箱地址"
            return
        }

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
            errorMessage = "请输入验证码"
            return
        }

        SkyBridgeLogger.ui.debugOnly("🔧 [手机号注册流程] 开始手机号注册流程")
        SkyBridgeLogger.ui.debugOnly("   手机号: \(phoneNumber)")

 // 🔥 生成唯一的 nebulaid
        var nebulaId: String
        do {
            let nebulaIdInfo = try NebulaIDGenerator.shared.generateUserRegistrationID()
            nebulaId = nebulaIdInfo.fullId
            SkyBridgeLogger.ui.debugOnly("✅ [手机号注册流程] NebulaID 生成成功: \(nebulaId)")
        } catch {
            SkyBridgeLogger.ui.error("❌ [手机号注册流程] NebulaID 生成失败: \(error.localizedDescription, privacy: .private)")
            errorMessage = "ID生成失败，请重试"
            return
        }

        isProcessing = true
        errorMessage = nil

        do {
 // 使用手机号和验证码完成注册登录
            let session = try await authService.loginPhone(
                number: phoneNumber,
                code: phoneVerificationCode
            )

            SkyBridgeLogger.ui.debugOnly("✅ [手机号注册流程] 注册成功")
            SkyBridgeLogger.ui.debugOnly("   用户ID: \(session.userIdentifier)")
            SkyBridgeLogger.ui.debugOnly("   NebulaID: \(nebulaId)")

 // 🔥 将 nebulaid 保存到用户元数据和数据库表中
            do {
 // 保存到数据库表
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

 // 注册成功，清空字段
            clearPhoneFields()
            errorMessage = "注册成功！"

        } catch {
            SkyBridgeLogger.ui.error("❌ [手机号注册流程] 注册失败: \(error.localizedDescription, privacy: .private)")
            let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
            errorMessage = "注册失败: \(message)"
        }

        isProcessing = false
    }

 /// 邮箱登录
    func loginWithEmail() async {
        guard isValidEmail(emailAddress) else {
            errorMessage = "请输入有效的邮箱地址"
            return
        }

        guard !emailPassword.isEmpty else {
            errorMessage = "请输入密码"
            return
        }

        await performAuthenticationTask {
            let session = try await self.authService.loginEmail(
                email: self.emailAddress,
                password: self.emailPassword
            )

 // 如果登录成功且用户选择记住凭据，则保存到KeyChain
            if self.rememberCredentials {
                self.saveCredentials()
            }

            return session
        }
    }

 /// 发送密码重置邮件
    func resetPassword() async {
        guard isValidEmail(emailAddress) else {
            errorMessage = "请输入有效的邮箱地址"
            return
        }

        await MainActor.run {
            isProcessing = true
            errorMessage = nil
        }

        do {
            try await SupabaseService.shared.resetPassword(email: emailAddress)

            await MainActor.run {
                self.isProcessing = false
                self.errorMessage = "密码重置邮件已发送，请检查邮箱"
            }
        } catch {
            await MainActor.run {
                let message = SupabaseService.userMessage(for: error) ?? error.localizedDescription
                self.errorMessage = "发送重置邮件失败：\(message)"
                self.isProcessing = false
            }
        }
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
        isGuestMode = true
        supabaseNebulaId = nil
        currentSession = AuthSession(
            accessToken: "guest_token",
            refreshToken: nil,
            userIdentifier: "guest_user",
            displayName: "游客用户",
            issuedAt: Date()
        )
    }

 // MARK: - 登出

 /// 登出当前用户
    func signOut() {
        authService.signOut()
        currentSession = nil
        supabaseNebulaId = nil
        isGuestMode = false
        clearAllFields()
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
    private func performAuthenticationTask(_ task: @escaping () async throws -> AuthSession) async {
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
            SkyBridgeLogger.ui.debugOnly("   访问令牌: \(String(session.accessToken.prefix(10)))...")

 // 登录成功后，尝试从Supabase加载用户头像
            await loadUserAvatarAfterLogin(session: session)
            await loadUserNebulaIdAfterLogin(session: session)

            await MainActor.run {
                SkyBridgeLogger.ui.debugOnly("🔄 [AuthenticationViewModel] 更新UI状态")

 // 直接更新状态，让SwiftUI自然处理更新
                self.currentSession = session
                self.isProcessing = false
                self.clearAllFields()

                SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] UI状态更新完成")
                SkyBridgeLogger.ui.debugOnly("   currentSession 用户: \(self.currentSession?.userIdentifier ?? "无")")
            }
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
            await MainActor.run {
                self.errorMessage = SupabaseService.userMessage(for: error) ?? error.localizedDescription
                self.isProcessing = false
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [AuthenticationViewModel] 认证任务失败: \(error.localizedDescription, privacy: .private)")
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
            guard SupabaseService.shared.isSupabaseAccessToken(session.accessToken) else {
                SkyBridgeLogger.ui.debugOnly("ℹ️ [AuthenticationViewModel] 非Supabase会话，跳过云头像加载")
                return
            }
 // 首先检查本地缓存
            if AvatarCacheManager.shared.getAvatar(for: session.userIdentifier) != nil {
                SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 从本地缓存加载头像")
                return
            }

 // 从Supabase获取头像URL
            if let avatarUrl = try await SupabaseService.shared.getUserAvatarUrl(
                userId: session.userIdentifier,
                accessToken: session.accessToken
            ) {
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

    /// 登录成功后加载用户 NebulaID（跨端一致：Supabase user_metadata.nebula_id）
    private func loadUserNebulaIdAfterLogin(session: AuthSession) async {
        // 跳过待验证状态的会话
        guard session.accessToken != "pending_verification" else { return }

        // 非 Supabase 会话：不覆盖（保持原 userIdentifier 语义）
        guard SupabaseService.shared.isSupabaseAccessToken(session.accessToken) else {
            await MainActor.run {
                self.supabaseNebulaId = nil
            }
            return
        }

        do {
            let nebulaId = try await SupabaseService.shared.getUserNebulaId(
                userId: session.userIdentifier,
                accessToken: session.accessToken
            )
            await MainActor.run {
                self.supabaseNebulaId = nebulaId
            }
        } catch {
            // 不阻塞登录流程
            SkyBridgeLogger.ui.debugOnly("ℹ️ [AuthenticationViewModel] NebulaID 加载失败（忽略）: \(error.localizedDescription)")
        }
    }

    private static func isCanonicalNebulaId(_ value: String) -> Bool {
        value.hasPrefix("NEBULA-")
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
            errorMessage = usernameValidation.error ?? "用户名格式不正确"
            return
        }

 // 密码强度校验
        let passwordValidation = validatePasswordStrength(sanitizedPassword, minimumStrength: .medium)
        guard passwordValidation.valid else {
            errorMessage = passwordValidation.error ?? "密码强度不足"
            return
        }

 // 密码确认校验
        guard sanitizedPassword == sanitizedConfirmPassword else {
            errorMessage = "两次输入的密码不一致"
            return
        }

 // 显示名称校验
        guard !sanitizedDisplayName.isEmpty else {
            errorMessage = "请输入显示名称"
            return
        }

        guard sanitizedDisplayName.count <= 50 else {
            errorMessage = "显示名称最多50个字符"
            return
        }

 // 邮箱校验
        guard isValidEmail(sanitizedEmail) else {
            errorMessage = "请输入有效的邮箱地址"
            return
        }

 // 检查一次性邮箱
        guard !isDisposableEmail(sanitizedEmail) else {
            errorMessage = "不支持使用临时邮箱注册"
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
                        await loadUserAvatarAfterLogin(session: session)
                        await loadUserNebulaIdAfterLogin(session: session)
                        currentSession = session
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
                    errorMessage = "注册成功！请检查您的邮箱并验证账户。"
                } else if result.requiresAdminApproval {
                    errorMessage = "注册成功！您的账户正在等待管理员审核。"
                } else {
 // 注册成功，自动登录（已在上面处理）
                }
            } else {
                SkyBridgeLogger.ui.error("❌ [星云注册流程] 注册失败: \((result.message ?? "未知错误"), privacy: .private)")
                errorMessage = result.message ?? "注册失败"
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [星云注册流程] 注册异常: \(error.localizedDescription, privacy: .private)")
            errorMessage = "注册失败: \(error.localizedDescription)"
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

 // MARK: - 用户资料更新方法

 /// 更新用户显示名称
 /// - Parameter displayName: 新的显示名称
    @MainActor
    func updateDisplayName(_ displayName: String) async throws {
        guard let session = currentSession else {
            throw NSError(domain: "AuthenticationError", code: -1, userInfo: [NSLocalizedDescriptionKey: "用户未登录"])
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
            if let refreshToken = session.refreshToken {
                // Best-effort refresh for 403/expired tokens
                if let refreshed = try? await SupabaseService.shared.refreshAccessToken(refreshToken) {
                    activeSession = refreshed
                    currentSession = refreshed
                    try? AuthenticationService.shared.updateSession(refreshed)
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
                displayName: displayName,
                issuedAt: activeSession.issuedAt
            )
            currentSession = updatedSession
            do {
                try AuthenticationService.shared.updateSession(updatedSession)
            } catch {
                SkyBridgeLogger.ui.error("❌ [AuthenticationViewModel] 会话写入失败: \(error.localizedDescription, privacy: .private)")
            }
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
            displayName: updatedUserInfo.displayName,
            issuedAt: session.issuedAt
        )

        currentSession = updatedSession
        do {
            try AuthenticationService.shared.updateSession(updatedSession)
        } catch {
            SkyBridgeLogger.ui.error("❌ [AuthenticationViewModel] 会话写入失败: \(error.localizedDescription, privacy: .private)")
        }
        SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 显示名称更新成功: \(updatedUserInfo.displayName)")
    }

 /// 上传用户头像
 /// - Parameter imageData: 头像图片数据
    @MainActor
    func uploadAvatar(_ imageData: Data) async throws {
        guard let session = currentSession else {
            throw NSError(domain: "AuthenticationError", code: -1, userInfo: [NSLocalizedDescriptionKey: "用户未登录"])
        }

        SkyBridgeLogger.ui.debugOnly("🔄 [AuthenticationViewModel] 开始上传头像")
        SkyBridgeLogger.ui.debugOnly("   用户ID: \(session.userIdentifier)")
        SkyBridgeLogger.ui.debugOnly("   图片大小: \(imageData.count) bytes")

        // Supabase 用户：优先上传到 Supabase Storage 并写入 avatar_url（跨端可见）
        if SupabaseConfiguration.shared.isConfigured,
           session.accessToken != "pending_verification",
           SupabaseService.shared.isSupabaseAccessToken(session.accessToken) {
            var activeSession = session
            if let refreshToken = session.refreshToken {
                if let refreshed = try? await SupabaseService.shared.refreshAccessToken(refreshToken) {
                    activeSession = refreshed
                    currentSession = refreshed
                    try? AuthenticationService.shared.updateSession(refreshed)
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
 // Combine会自动清理cancellables，Timer在deinit时也会自动清理
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
        guard !emailAddress.isEmpty && !emailPassword.isEmpty else { return }

 // 保存邮箱地址到UserDefaults（非敏感信息）
        UserDefaults.standard.set(emailAddress, forKey: "saved_email_address")

 // 保存密码到KeyChain（敏感信息）
        let passwordData = emailPassword.data(using: .utf8) ?? Data()
        let context = makeNonInteractiveAuthContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: emailAddress,
            kSecAttrService as String: "SkyBridgeCompass_EmailLogin",
            kSecUseAuthenticationContext as String: context,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        var status = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.removeValue(forKey: kSecUseAuthenticationContext as String)
            addQuery[kSecValueData as String] = passwordData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status == errSecSuccess {
            SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 凭据保存成功")
        } else {
            SkyBridgeLogger.ui.error("❌ [AuthenticationViewModel] 凭据保存失败: \(status, privacy: .private)")
        }
    }

 /// 从KeyChain加载已保存的凭据
    private func loadSavedCredentials() {
 // 从UserDefaults加载邮箱地址
        if let savedEmail = UserDefaults.standard.string(forKey: "saved_email_address") {
            emailAddress = savedEmail

 // 从KeyChain加载密码
            let context = makeNonInteractiveAuthContext()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: savedEmail,
                kSecAttrService as String: "SkyBridgeCompass_EmailLogin",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context,
                ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecSuccess,
               let passwordData = result as? Data,
               let password = String(data: passwordData, encoding: .utf8) {
                emailPassword = password
                rememberCredentials = true
                SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 已加载保存的凭据")
            } else {
                SkyBridgeLogger.ui.debugOnly("ℹ️ [AuthenticationViewModel] 未找到保存的凭据或加载失败: \(status)")
            }
        }
    }

 /// 清除保存的凭据
    private func clearSavedCredentials() {
 // 清除UserDefaults中的邮箱地址
        UserDefaults.standard.removeObject(forKey: "saved_email_address")

 // 清除KeyChain中的密码
        if !emailAddress.isEmpty {
            let context = makeNonInteractiveAuthContext()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: emailAddress,
                kSecAttrService as String: "SkyBridgeCompass_EmailLogin",
                kSecUseAuthenticationContext as String: context,
                ]

            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                SkyBridgeLogger.ui.debugOnly("✅ [AuthenticationViewModel] 已清除保存的凭据")
            } else {
                SkyBridgeLogger.ui.debugOnly("ℹ️ [AuthenticationViewModel] 清除凭据失败或不存在: \(status)")
            }
        }
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
