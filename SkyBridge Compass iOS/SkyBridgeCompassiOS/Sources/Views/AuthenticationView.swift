import Foundation
import SwiftUI
import WebKit
import AuthenticationServices

/// 认证视图 - 登录、注册和游客模式
@available(iOS 17.0, *)
struct AuthenticationView: View {
    private enum SupabaseTurnstileAction {
        case signInWithApple
        case registerEmail
        case loginEmail
        case sendPhoneOTP
        case resetPassword

        var actionName: String {
            switch self {
            case .signInWithApple: return "apple_signin"
            case .registerEmail: return "signup"
            case .loginEmail: return "password_login"
            case .sendPhoneOTP: return "phone_otp"
            case .resetPassword: return "password_reset"
            }
        }
    }

    private enum AuthMethod: String, CaseIterable, Identifiable {
        case email
        case phone

        var id: String { rawValue }

        var title: String {
            switch self {
            case .email: return "邮箱"
            case .phone: return "手机号"
            }
        }

        var icon: String {
            switch self {
            case .email: return "envelope.fill"
            case .phone: return "phone.fill"
            }
        }
    }

    @EnvironmentObject private var authManager: AuthenticationManager
    @State private var selectedMethod: AuthMethod = .email
    @State private var email = ""
    @State private var password = ""
    @State private var phoneNumber = ""
    @State private var phoneCode = ""
    @State private var isPhoneCodeSent = false
    @State private var phoneCodeCountdown = 0
    @State private var phoneCountdownTask: Task<Void, Never>?
    @State private var isRegistering = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isLoading = false
    @State private var isNebulaLoading = false
    @State private var showSupabaseSettings = false
    @State private var isSupabaseConfigured = false
    @State private var pendingSupabaseTurnstileContext: IOSSupabaseTurnstileChallengeContext?
    @State private var pendingSupabaseTurnstileAction: SupabaseTurnstileAction?
    @State private var pendingAppleAuthorization: ASAuthorization?

    init(isRegistering: Bool = false) {
        _isRegistering = State(initialValue: isRegistering)
    }
    
    var body: some View {
        ZStack {
            DashboardView.QuantumGlassBackground()

            ScrollView {
                VStack(spacing: 28) {
                    // Logo 和标题
                    headerSection

                    authMethodPicker
                    
                    // 登录/注册表单
                    formSection
                    
                    // 操作按钮
                    actionButtons
                    
                    // 或者分隔线
                    divider
                    
                    // 游客模式
                    guestModeButton

                    // Supabase 配置入口（避免首次启动无法登录/注册）
                    supabaseSettingsEntry
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 44)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture { hideKeyboard() }
        .accessibilityIdentifier("auth.root")
        .alert("提示", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showSupabaseSettings, onDismiss: refreshSupabaseConfigurationStatus) {
            NavigationStack {
                SupabaseSettingsView()
            }
        }
        .sheet(item: $pendingSupabaseTurnstileContext) { context in
            IOSSupabaseTurnstileSheet(
                context: context,
                onToken: { token in
                    guard let action = pendingSupabaseTurnstileAction else { return }
                    pendingSupabaseTurnstileAction = nil
                    pendingSupabaseTurnstileContext = nil
                    runSupabaseTurnstileAction(action, token: token)
                },
                onCancel: {
                    pendingSupabaseTurnstileAction = nil
                    pendingSupabaseTurnstileContext = nil
                    pendingAppleAuthorization = nil
                    isLoading = false
                    errorMessage = "已取消 Cloudflare Turnstile 验证"
                    showError = true
                },
                onError: { message in
                    pendingSupabaseTurnstileAction = nil
                    pendingSupabaseTurnstileContext = nil
                    pendingAppleAuthorization = nil
                    isLoading = false
                    errorMessage = "Cloudflare Turnstile 验证失败：\(message)"
                    showError = true
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(
            isPresented: Binding(
                get: { authManager.showCaptchaChallenge },
                set: { isPresented in
                    if !isPresented {
                        authManager.dismissCaptchaChallenge()
                    }
                }
            )
        ) {
            IOSBehaviorCaptchaView(
                onVerificationComplete: { success, error in
                    authManager.completeCaptchaChallenge(success: success)
                    if success {
                        errorMessage = "安全验证已完成，请再次点击继续"
                    } else {
                        errorMessage = error ?? "安全验证失败，请重试"
                    }
                    showError = true
                },
                onCancel: {
                    authManager.dismissCaptchaChallenge()
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onAppear(perform: refreshSupabaseConfigurationStatus)
        .onDisappear {
            phoneCountdownTask?.cancel()
        }
        .preferredColorScheme(.dark)
    }
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            iOSBrandIcon(size: 92)
            
            Text("SkyBridge Compass")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
            
            Text("跨平台设备管理与远程控制")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }

    private var authMethodPicker: some View {
        HStack(spacing: 12) {
            ForEach(AuthMethod.allCases) { method in
                Button {
                    if selectedMethod != method {
                        if method == .email {
                            resetPhoneFlow(clearPhoneNumber: false)
                        }
                        selectedMethod = method
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: method.icon)
                        Text(method.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(selectedMethod == method ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selectedMethod == method ? .white.opacity(0.4) : .white.opacity(0.14), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func iOSBrandIcon(size: CGFloat) -> some View {
        Image("BrandIcon")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .shadow(color: .blue.opacity(0.28), radius: 18, x: 0, y: 10)
    }
    
    private var formSection: some View {
        VStack(spacing: 16) {
            if selectedMethod == .email {
                inputRow(systemImage: "envelope.fill") {
                    TextField("邮箱", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundColor(.white)
                }

                inputRow(systemImage: "lock.fill") {
                    SecureField("密码", text: $password)
                        .textContentType(isRegistering ? .newPassword : .password)
                        .foregroundColor(.white)
                }
            } else {
                inputRow(systemImage: "phone.fill") {
                    TextField("手机号（中国大陆）", text: $phoneNumber)
                        .keyboardType(.numberPad)
                        .textContentType(.telephoneNumber)
                        .foregroundColor(.white)
                }

                if isPhoneCodeSent {
                    inputRow(systemImage: "number.square.fill") {
                        TextField("短信验证码", text: $phoneCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .foregroundColor(.white)
                    }
                }

                Text("短信由 Aliyun 发送，验证码校验与会话签发由 Supabase Auth 负责。未注册手机号会按项目配置自动创建账号。")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                if !isSupabaseConfigured {
                    Text("请先配置可用的 Supabase 项目，并在 Auth 中启用 send_sms hook。")
                        .font(.footnote)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }

                if phoneCodeCountdown > 0 {
                    Text("验证码已发送，\(phoneCodeCountdown) 秒后可重新发送")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
        }
    }
    
    private var actionButtons: some View {
        VStack(spacing: 16) {
            if authManager.isAppleSignInEnabled {
                appleSignInButton
            }

            Button(action: performNebulaAction) {
                HStack(spacing: 10) {
                    if isNebulaLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "safari.fill")
                        Text(isRegistering ? "使用 Nebula 安全注册" : "使用 Nebula 安全登录")
                            .font(.headline)
                            .fontWeight(.bold)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                LinearGradient(
                    colors: [.indigo, .blue],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .blue.opacity(0.28), radius: 10, x: 0, y: 5)
            .disabled(isNebulaLoading || !SkyBridgeServerConfig.hasNebulaConfiguration)
            .opacity(SkyBridgeServerConfig.hasNebulaConfiguration ? 1.0 : 0.55)

            if SkyBridgeServerConfig.hasNebulaConfiguration {
                Text(isRegistering
                     ? "Nebula 注册将在系统浏览器中完成，邮箱验证与二次验证都会留在浏览器授权会话里。"
                     : "Nebula 登录将在系统浏览器中完成，授权与二次验证均不在 App 内处理。")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            } else {
                Text("Nebula 配置缺失：请先提供 NEBULA_BASE_URL / NEBULA_CLIENT_ID。")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            Button(action: performAction) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(primaryActionTitle)
                        .font(.headline)
                        .fontWeight(.bold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                LinearGradient(
                    colors: [.cyan, .purple],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .cyan.opacity(0.3), radius: 10, x: 0, y: 5)
            .disabled(isLoading || !isFormValid)
            .opacity(isFormValid ? 1.0 : 0.6)
            
            if selectedMethod == .email {
                Button(action: { isRegistering.toggle() }) {
                    Text(isRegistering ? "已有账号？登录" : "没有账号？注册")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }

                if !isRegistering {
                    Button(action: performPasswordReset) {
                        Text("忘记密码？")
                            .font(.subheadline)
                            .foregroundColor(.blue.opacity(0.9))
                    }
                }
            } else if isPhoneCodeSent && phoneCodeCountdown == 0 {
                Button("重新发送验证码") {
                    performAction()
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }
        }
    }

    private var appleSignInButton: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [
                ASAuthorization.Scope.fullName,
                ASAuthorization.Scope.email
            ]
            authManager.configureAppleSignInRequest(request)
        } onCompletion: { result in
            performAppleSignIn(result)
        }
        .signInWithAppleButtonStyle(SignInWithAppleButton.Style.black)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .disabled(isLoading || isNebulaLoading)
        .opacity((isLoading || isNebulaLoading) ? 0.7 : 1.0)
    }

    private func inputRow<Content: View>(systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundColor(.gray)
                .frame(width: 20)

            content()
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
    
    private var divider: some View {
        HStack {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
            
            Text("或者")
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.horizontal, 8)
            
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
    }
    
    private var guestModeButton: some View {
        Button(action: loginAsGuest) {
            HStack {
                Image(systemName: "person.fill.questionmark")
                Text("以游客身份继续")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.ultraThinMaterial)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
        }
        .accessibilityIdentifier("auth.guest")
    }

    private var supabaseSettingsEntry: some View {
        VStack(spacing: 10) {
            if !isSupabaseConfigured {
                Text("未检测到 Supabase 配置：请先配置 SUPABASE_URL / SUPABASE_ANON_KEY")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            Button {
                showSupabaseSettings = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                    Text("Supabase 配置")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(.ultraThinMaterial)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
            }
        }
    }

    private func refreshSupabaseConfigurationStatus() {
        isSupabaseConfigured = SupabaseService.Configuration.fromEnvironment(logIfMissing: false) != nil
    }
    
    private var isFormValid: Bool {
        switch selectedMethod {
        case .email:
            return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.isEmpty
                && password.count >= 6
        case .phone:
            guard isSupabaseConfigured, isValidPhoneNumber(phoneNumber) else { return false }
            return isPhoneCodeSent ? !phoneCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : true
        }
    }

    private var primaryActionTitle: String {
        switch selectedMethod {
        case .email:
            return isRegistering ? "注册" : "登录"
        case .phone:
            return isPhoneCodeSent ? "验证并继续" : "发送验证码"
        }
    }
    
    // MARK: - Actions
    
    private func performAction() {
        isLoading = true
        
        Task {
            do {
                if selectedMethod == .phone {
                    try await performPhoneAction()
                } else {
                    await MainActor.run {
                        isLoading = false
                    }
                    beginSupabaseTurnstileAction(isRegistering ? .registerEmail : .loginEmail)
                    return
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            
            isLoading = false
        }
    }

    private func performNebulaAction() {
        isNebulaLoading = true

        Task {
            do {
                if isRegistering {
                    try await authManager.registerWithNebulaBrowser()
                } else {
                    try await authManager.signInWithNebulaBrowser()
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }

            isNebulaLoading = false
        }
    }

    private func performAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        Task {
            do {
                let authorization: ASAuthorization
                switch result {
                case .success(let success):
                    authorization = success
                case .failure(let error):
                    if let authError = error as? ASAuthorizationError,
                       authError.code == .canceled {
                        await MainActor.run {
                            isLoading = false
                        }
                        return
                    }
                    throw error
                }

                await MainActor.run {
                    beginAppleSignInFlow(with: authorization)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func performPhoneAction() async throws {
        let normalizedPhone = sanitizePhoneNumber(phoneNumber)
        if !isPhoneCodeSent {
            await MainActor.run {
                isLoading = false
            }
            phoneNumber = normalizedPhone
            beginSupabaseTurnstileAction(.sendPhoneOTP)
            return
        }

        try await authManager.signInWithPhone(
            phoneNumber: normalizedPhone,
            code: phoneCode.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        await MainActor.run {
            resetPhoneFlow(clearPhoneNumber: false)
        }
    }
    
    private func loginAsGuest() {
        Task {
            await authManager.signInAsGuest()
        }
    }

    private func performPasswordReset() {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else {
            errorMessage = "请输入邮箱地址后再重置密码"
            showError = true
            return
        }

        email = normalizedEmail
        beginSupabaseTurnstileAction(.resetPassword)
    }

    private func hideKeyboard() {
#if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
#endif
    }

    private func sanitizePhoneNumber(_ rawPhone: String) -> String {
        rawPhone.filter { $0.isNumber || $0 == "+" }
    }

    private func isValidPhoneNumber(_ rawPhone: String) -> Bool {
        let sanitized = sanitizePhoneNumber(rawPhone)
        if sanitized.hasPrefix("+") {
            return sanitized.range(of: #"^\+[1-9]\d{7,14}$"#, options: .regularExpression) != nil
        }
        return sanitized.range(of: #"^1[3-9]\d{9}$"#, options: .regularExpression) != nil
    }

    private func startPhoneCountdown() {
        phoneCountdownTask?.cancel()
        phoneCodeCountdown = 60
        phoneCountdownTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run {
                    guard phoneCodeCountdown > 0 else {
                        phoneCountdownTask?.cancel()
                        phoneCountdownTask = nil
                        return
                    }
                    phoneCodeCountdown -= 1
                }
            }
        }
    }

    private func resetPhoneFlow(clearPhoneNumber: Bool) {
        phoneCountdownTask?.cancel()
        phoneCountdownTask = nil
        phoneCode = ""
        phoneCodeCountdown = 0
        isPhoneCodeSent = false
        if clearPhoneNumber {
            phoneNumber = ""
        }
    }

    private func beginSupabaseTurnstileAction(_ action: SupabaseTurnstileAction) {
        pendingAppleAuthorization = nil

        guard let originURL = SupabaseService.Configuration.fromEnvironment(logIfMissing: false)?.url else {
            runSupabaseTurnstileAction(action, token: nil)
            return
        }

        guard let baseContext = IOSSupabaseTurnstileConfig.current(originURL: originURL) else {
            if IOSSupabaseTurnstileConfig.requiresSiteKey(for: originURL) {
                errorMessage = "客户端缺少 Cloudflare Turnstile 配置，请检查 TURNSTILE_SITE_KEY"
                showError = true
                return
            }

            runSupabaseTurnstileAction(action, token: nil)
            return
        }

        pendingSupabaseTurnstileAction = action
        pendingSupabaseTurnstileContext = IOSSupabaseTurnstileChallengeContext(
            siteKey: baseContext.siteKey,
            originURL: baseContext.originURL,
            action: action.actionName
        )
    }

    private func beginAppleSignInFlow(with authorization: ASAuthorization) {
        guard let originURL = SupabaseService.Configuration.fromEnvironment(logIfMissing: false)?.url else {
            isLoading = true
            Task {
                do {
                    try await authManager.handleAppleAuthorization(authorization)
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        showError = true
                        isLoading = false
                    }
                }
            }
            return
        }

        guard let baseContext = IOSSupabaseTurnstileConfig.current(originURL: originURL) else {
            if IOSSupabaseTurnstileConfig.requiresSiteKey(for: originURL) {
                errorMessage = "客户端缺少 Cloudflare Turnstile 配置，请检查 TURNSTILE_SITE_KEY"
                showError = true
                isLoading = false
                return
            }

            isLoading = true
            Task {
                do {
                    try await authManager.handleAppleAuthorization(authorization)
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }

                await MainActor.run {
                    isLoading = false
                }
            }
            return
        }

        pendingAppleAuthorization = authorization
        pendingSupabaseTurnstileAction = .signInWithApple
        pendingSupabaseTurnstileContext = IOSSupabaseTurnstileChallengeContext(
            siteKey: baseContext.siteKey,
            originURL: baseContext.originURL,
            action: SupabaseTurnstileAction.signInWithApple.actionName
        )
    }

    private func runSupabaseTurnstileAction(_ action: SupabaseTurnstileAction, token: String?) {
        isLoading = true

        Task {
            do {
                switch action {
                case .signInWithApple:
                    guard let authorization = pendingAppleAuthorization else {
                        throw NSError(
                            domain: "AuthenticationView",
                            code: -20,
                            userInfo: [NSLocalizedDescriptionKey: "Apple 登录上下文已失效，请重试"]
                        )
                    }
                    pendingAppleAuthorization = nil
                    try await authManager.handleAppleAuthorization(authorization, captchaToken: token)
                case .registerEmail:
                    try await authManager.register(email: email, password: password, captchaToken: token)
                case .loginEmail:
                    try await authManager.signIn(email: email, password: password, captchaToken: token)
                case .sendPhoneOTP:
                    try await authManager.sendPhoneVerificationCode(phoneNumber: phoneNumber, captchaToken: token)
                    await MainActor.run {
                        isPhoneCodeSent = true
                        phoneCode = ""
                        startPhoneCountdown()
                    }
                case .resetPassword:
                    try await authManager.resetPassword(email: email, captchaToken: token)
                    await MainActor.run {
                        errorMessage = "密码重置邮件已发送，请检查邮箱"
                        showError = true
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }

            await MainActor.run {
                isLoading = false
            }
        }
    }
}

private struct IOSBehaviorCaptchaView: View {
    let onVerificationComplete: (Bool, String?) -> Void
    let onCancel: () -> Void

    @State private var puzzleOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var targetPosition: CGFloat = 0
    @State private var statusMessage: String?
    @State private var verificationState: VerificationState = .pending
    @State private var points: [TrackPoint] = []
    @State private var dragStartTime: Date?

    private let puzzleSize: CGFloat = 46
    private let sliderTrackWidth: CGFloat = 300
    private let sliderTrackHeight: CGFloat = 48
    private let positionTolerance: CGFloat = 6

    private enum VerificationState {
        case pending
        case success
        case failure
    }

    private struct TrackPoint {
        let x: CGFloat
        let y: CGFloat
        let timestampMs: Double
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 36))
                    .foregroundStyle(
                        LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("安全验证")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text("请拖动滑块完成拼图验证")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.18, green: 0.32, blue: 0.48),
                                Color(red: 0.13, green: 0.22, blue: 0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 118)

                Canvas { context, size in
                    let step: CGFloat = 20
                    for x in stride(from: 0, through: size.width, by: step) {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                    }
                    for y in stride(from: 0, through: size.height, by: step) {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                    }
                }
                .frame(height: 118)

                IOSPuzzlePieceShape()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: puzzleSize, height: puzzleSize)
                    .overlay(
                        IOSPuzzlePieceShape()
                            .stroke(Color.white.opacity(0.4), lineWidth: 2)
                    )
                    .offset(x: targetPosition - sliderTrackWidth / 2 + puzzleSize / 2)

                IOSPuzzlePieceShape()
                    .fill(
                        LinearGradient(
                            colors: verificationState == .success ? [.green, .mint] : [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: puzzleSize, height: puzzleSize)
                    .overlay(
                        IOSPuzzlePieceShape()
                            .stroke(Color.white.opacity(0.8), lineWidth: 2)
                    )
                    .overlay(
                        Image(systemName: verificationState == .success ? "checkmark" : "puzzlepiece.fill")
                            .foregroundStyle(.white.opacity(0.85))
                    )
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
                    .offset(x: puzzleOffset - sliderTrackWidth / 2 + puzzleSize / 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: sliderTrackHeight / 2, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: sliderTrackWidth, height: sliderTrackHeight)

                RoundedRectangle(cornerRadius: sliderTrackHeight / 2, style: .continuous)
                    .fill(
                        LinearGradient(colors: [.cyan.opacity(0.3), .blue.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(puzzleOffset + puzzleSize / 2, sliderTrackHeight), height: sliderTrackHeight)

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: verificationState == .failure ? [.orange, .red] : [.white, .white.opacity(0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: puzzleSize - 2, height: puzzleSize - 2)
                    Image(systemName: verificationState == .failure ? "xmark" : "arrow.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.black.opacity(0.72))
                }
                .offset(x: puzzleOffset)
                .gesture(dragGesture)

                if puzzleOffset < 10 && verificationState == .pending {
                    Text("向右滑动完成验证")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: sliderTrackWidth, height: sliderTrackHeight)

            Group {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(verificationState == .success ? .green : .orange)
                } else {
                    Text("拖动时保持自然，不要过快或过于机械。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 18)

            HStack {
                Button("换一张") {
                    resetPuzzle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
        .onAppear(perform: generateNewPuzzle)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard verificationState == .pending else { return }
                if !isDragging {
                    isDragging = true
                    dragStartTime = Date()
                    points = []
                    statusMessage = nil
                }

                let limitedOffset = max(0, min(sliderTrackWidth - puzzleSize, value.translation.width))
                puzzleOffset = limitedOffset
                recordPoint(x: value.location.x, y: value.location.y)
            }
            .onEnded { _ in
                guard verificationState == .pending else { return }
                isDragging = false
                verify()
            }
    }

    private func recordPoint(x: CGFloat, y: CGFloat) {
        guard let dragStartTime else { return }
        let timestampMs = Date().timeIntervalSince(dragStartTime) * 1000
        points.append(TrackPoint(x: x, y: y, timestampMs: timestampMs))
    }

    private func verify() {
        let positionError = abs(puzzleOffset - targetPosition)
        guard positionError <= positionTolerance else {
            fail(reason: "位置不准确，请重试")
            return
        }

        guard let reason = analyzeTrack() else {
            verificationState = .success
            statusMessage = "验证成功"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                onVerificationComplete(true, nil)
            }
            return
        }

        fail(reason: reason)
    }

    private func analyzeTrack() -> String? {
        guard let dragStartTime,
              let lastTimestamp = points.last?.timestampMs else {
            return "轨迹数据异常"
        }

        let duration = max(lastTimestamp, Date().timeIntervalSince(dragStartTime) * 1000)
        guard points.count >= 10 else {
            return "轨迹数据不足"
        }

        guard duration >= 220 else {
            return "滑动过快，请自然拖动"
        }

        guard duration <= 6000 else {
            return "滑动过慢，请重新尝试"
        }

        let deltas = zip(points, points.dropFirst()).map { lhs, rhs in
            (dx: rhs.x - lhs.x, dy: rhs.y - lhs.y, dt: max(rhs.timestampMs - lhs.timestampMs, 1))
        }

        let horizontalMovement = deltas.reduce(CGFloat.zero) { $0 + abs($1.dx) }
        guard horizontalMovement >= sliderTrackWidth * 0.45 else {
            return "滑动距离不足"
        }

        let verticalVariance = deltas.reduce(CGFloat.zero) { $0 + abs($1.dy) }
        let speedSamples = deltas.map { Double(abs($0.dx)) / $0.dt }
        let meanSpeed = speedSamples.reduce(0, +) / Double(max(speedSamples.count, 1))
        let speedVariance = speedSamples.reduce(0) { partial, sample in
            partial + pow(sample - meanSpeed, 2)
        } / Double(max(speedSamples.count, 1))

        if verticalVariance < 2 && speedVariance < 0.0008 {
            return "滑动轨迹过于机械，请重试"
        }

        return nil
    }

    private func fail(reason: String) {
        verificationState = .failure
        statusMessage = reason
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            resetPuzzle()
        }
        onVerificationComplete(false, reason)
    }

    private func resetPuzzle() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            puzzleOffset = 0
            verificationState = .pending
            statusMessage = nil
            points = []
            dragStartTime = nil
        }
        generateNewPuzzle()
    }

    private func generateNewPuzzle() {
        let minPosition = sliderTrackWidth * 0.38
        let maxPosition = sliderTrackWidth - puzzleSize - 18
        targetPosition = CGFloat.random(in: minPosition...maxPosition)
    }
}

private struct IOSPuzzlePieceShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let notchSize = rect.width * 0.24
        let notchOffset = rect.height * 0.34

        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: notchOffset))
        path.addArc(
            center: CGPoint(x: rect.width + notchSize / 2, y: notchOffset + notchSize / 2),
            radius: notchSize / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

@available(iOS 17.0, *)
private struct IOSSupabaseTurnstileChallengeContext: Identifiable, Equatable {
    let id = UUID()
    let siteKey: String
    let originURL: URL
    let action: String
}

@available(iOS 17.0, *)
private enum IOSSupabaseTurnstileConfig {
    static func current(originURL: URL?) -> IOSSupabaseTurnstileChallengeContext? {
        let envSiteKey = ProcessInfo.processInfo.environment["TURNSTILE_SITE_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let infoSiteKey = (Bundle.main.object(forInfoDictionaryKey: "TURNSTILE_SITE_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plistSiteKey: String? = {
            guard let url = Bundle.main.url(forResource: "SupabaseConfig", withExtension: "plist"),
                  let dict = NSDictionary(contentsOf: url) as? [String: Any],
                  let siteKey = dict["TURNSTILE_SITE_KEY"] as? String else {
                return nil
            }
            return siteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        let siteKeyCandidates: [String?] = [envSiteKey, infoSiteKey, plistSiteKey]
        guard let siteKey = siteKeyCandidates.compactMap({ $0 }).first(where: { !$0.isEmpty }),
              let originURL else {
            return nil
        }

        return IOSSupabaseTurnstileChallengeContext(siteKey: siteKey, originURL: originURL, action: "auth")
    }

    static func requiresSiteKey(for originURL: URL?) -> Bool {
        guard let host = originURL?.host?.lowercased(), !host.isEmpty else {
            return false
        }

        return !["localhost", "127.0.0.1", "::1"].contains(host) && !host.hasSuffix(".local")
    }
}

@available(iOS 17.0, *)
private struct IOSSupabaseTurnstileSheet: View {
    let context: IOSSupabaseTurnstileChallengeContext
    let onToken: (String) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(
                        LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("安全检查")
                    .font(.headline)
                Text("请完成 Cloudflare Turnstile 验证后继续。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            IOSTurnstileWebView(
                siteKey: context.siteKey,
                originURL: context.originURL,
                action: context.action,
                onToken: onToken,
                onError: onError
            )
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
            }
        }
        .padding(24)
    }
}

@available(iOS 17.0, *)
private struct IOSTurnstileWebView: UIViewRepresentable {
    let siteKey: String
    let originURL: URL
    let action: String
    let onToken: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "turnstile")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.loadHTMLString(
            Self.html(siteKey: siteKey, action: action),
            baseURL: originURL
        )
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "turnstile")
    }

    private static func html(siteKey: String, action: String) -> String {
        let escapedSiteKey = siteKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAction = action
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" async defer></script>
          <style>
            body {
              margin: 0;
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
              background: transparent;
              color: #fff;
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 100vh;
            }
          </style>
        </head>
        <body>
          <div id="widget"></div>
          <script>
            function post(payload) {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.turnstile) {
                window.webkit.messageHandlers.turnstile.postMessage(payload);
              }
            }

            function renderWidget() {
              if (!window.turnstile) {
                window.setTimeout(renderWidget, 60);
                return;
              }
              try {
                window.turnstile.render("#widget", {
                  sitekey: "\(escapedSiteKey)",
                  action: "\(escapedAction)",
                  callback: function(token) {
                    post({ type: "success", token: token });
                  },
                  "error-callback": function(code) {
                    post({ type: "error", message: String(code || "turnstile_error") });
                  },
                  "expired-callback": function() {
                    post({ type: "error", message: "turnstile_token_expired" });
                  }
                });
              } catch (error) {
                post({ type: "error", message: String(error) });
              }
            }

            window.addEventListener("load", renderWidget);
          </script>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let onToken: (String) -> Void
        private let onError: (String) -> Void

        init(onToken: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onToken = onToken
            self.onError = onError
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "turnstile",
                  let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else {
                onError("turnstile_message_invalid")
                return
            }

            if type == "success",
               let token = payload["token"] as? String,
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onToken(token)
                return
            }

            onError((payload["message"] as? String) ?? "turnstile_failed")
        }
    }
}

// MARK: - Preview
#if DEBUG
struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            AuthenticationView()
                .environmentObject(AuthenticationManager.instance)
            AuthenticationView(isRegistering: true)
                .environmentObject(AuthenticationManager.instance)
        }
    }
}
#endif
