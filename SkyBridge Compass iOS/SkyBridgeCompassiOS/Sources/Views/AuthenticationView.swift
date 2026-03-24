import SwiftUI

/// 认证视图 - 登录、注册和游客模式
@available(iOS 17.0, *)
struct AuthenticationView: View {
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
        .alert("错误", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showSupabaseSettings, onDismiss: refreshSupabaseConfigurationStatus) {
            NavigationStack {
                SupabaseSettingsView()
            }
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
            } else if isPhoneCodeSent && phoneCodeCountdown == 0 {
                Button("重新发送验证码") {
                    performAction()
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }
        }
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
                    if isRegistering {
                        try await authManager.register(email: email, password: password)
                    } else {
                        try await authManager.signIn(email: email, password: password)
                    }
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

    private func performPhoneAction() async throws {
        let normalizedPhone = sanitizePhoneNumber(phoneNumber)
        if !isPhoneCodeSent {
            try await authManager.sendPhoneVerificationCode(phoneNumber: normalizedPhone)
            await MainActor.run {
                phoneNumber = normalizedPhone
                isPhoneCodeSent = true
                phoneCode = ""
                startPhoneCountdown()
            }
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
