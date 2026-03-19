import SwiftUI
import SkyBridgeCore
import AuthenticationServices

/// 现代化登录界面，遵循macOS 2025设计规范
/// 采用革命性彩色Liquid Glass设计语言，支持多种登录方式
/// 应用Apple 2025高性能最佳实践，针对Apple Silicon优化
@available(macOS 14.0, *)
struct AuthenticationView: View {
    @StateObject private var viewModel = AuthenticationViewModel()
    @StateObject private var hazeClearManager = InteractiveClearManager()
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @Environment(\.colorScheme) private var colorScheme
    @State private var isAnimating = false
    @State private var selectedTab = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
 // macOS原生材质背景
                dashboardAlignedBackground
                
 // 主要内容 - 使用Apple 2025性能优化
                VStack(spacing: 0) {
 // 顶部品牌区域
                    brandHeader
                        .frame(height: geometry.size.height * 0.35)
                    
 // 登录卡片 - macOS原生材质效果
                    macOSNativeLoginCard
                        .frame(maxHeight: geometry.size.height * 0.65)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
 // 使用Apple 2025推荐的弹性动画
            withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.8)) {
                isAnimating = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GlobalMouseTracker.mouseMovedNotification)) { notification in
            guard let locationValue = notification.userInfo?["location"] as? NSValue else { return }
            let pt = locationValue.pointValue
            let flipped = CGPoint(x: pt.x, y: pt.y)
            hazeClearManager.handleMouseMove(flipped)
        }
    }
    
 // MARK: - 统一的仪表盘风格背景
    
    private var dashboardAlignedBackground: some View {
        ZStack {
            DashboardBackgroundView(hazeClearManager: hazeClearManager)
            
 // 轻度对比度遮罩，保证登录表单可读性
            LinearGradient(
                colors: [
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.15),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

 // MARK: - 顶部品牌区域
    
    private var brandHeader: some View {
        let primary = themeConfiguration.currentTheme.primaryColor
        let secondary = themeConfiguration.currentTheme.secondaryColor
        
        return VStack(spacing: 12) {
            VStack(spacing: 8) {
                Text(LocalizationManager.shared.localizedString("auth.hero.tagline"))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                
                HStack(spacing: 12) {
                    heroBadge(icon: "network", textKey: "auth.hero.benefit.reach")
                    heroBadge(icon: "lock.shield.fill", textKey: "auth.hero.benefit.trust")
                    heroBadge(icon: "bolt.fill", textKey: "auth.hero.benefit.setup")
                }
            }
            .padding(.top, 16)
            
            VStack(spacing: 8) {
 // 统一风格的玻璃图标
                ZStack {
 // 玻璃底座
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(themeConfiguration.cardBackgroundMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            primary.opacity(0.35),
                                            secondary.opacity(0.2),
                                            Color.clear
                                        ],
                                        center: .topLeading,
                                        startRadius: 12,
                                        endRadius: 90
                                    )
                                )
                                .blendMode(.overlay)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(themeConfiguration.borderColor, lineWidth: 0.8)
                        }
                        .frame(width: 40, height: 40)
                        .shadow(color: primary.opacity(0.35), radius: 24, x: 0, y: 14)
                    
                    CustomGlobeIconView(cornerRadius: 12)
                        .frame(width: 40, height: 40)
                }
                .frame(width: 40, height: 40)
                .scaleEffect(isAnimating ? 1.0 : 0.9)
                .animation(.interactiveSpring(response: 0.8, dampingFraction: 0.6), value: isAnimating)
                
                Text(LocalizationManager.shared.localizedString("brand.title"))
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.primary, primary, secondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        }
        .opacity(themeConfiguration.glassOpacity)
        .padding(.horizontal, 40)
    }

    private func heroBadge(icon: String, textKey: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(LocalizationManager.shared.localizedString(textKey))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(themeConfiguration.cardBackgroundMaterial)
                .opacity(0.6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(themeConfiguration.borderColor.opacity(0.7), lineWidth: 0.6)
        )
    }
    
 // MARK: - macOS原生登录卡片
    
    private var macOSNativeLoginCard: some View {
        VStack(spacing: 0) {
 // 登录方式选择器
            loginMethodPicker
                .padding(.top, 32)
                .padding(.horizontal, 32)
            
 // 登录表单区域
            ScrollView {
                VStack(spacing: 24) {
 // 高性能登录表单
                    performantLoginForm
                        .padding(.horizontal, 32)
                        .padding(.top, 24)
                    
 // 游客模式按钮
                    guestModeButton
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                }
            }
        }
        .background {
 // 仪表盘一致的玻璃卡片
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(themeConfiguration.cardBackgroundMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(themeConfiguration.borderColor, lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.18), radius: 22, x: 0, y: 12)
        }
        .modifier(GlassStyleModifier(cornerRadius: 24))
        .padding(.horizontal, 40)
        .opacity(themeConfiguration.glassOpacity)
        .offset(y: isAnimating ? 0 : 50)
        .opacity(isAnimating ? 1.0 : 0.0)
        .animation(.interactiveSpring(response: 0.8, dampingFraction: 0.8).delay(0.5), value: isAnimating)
    }
    
 // MARK: - macOS原生登录方式选择器
    
    private var loginMethodPicker: some View {
        VStack(spacing: 16) {
            Text(LocalizationManager.shared.localizedString("auth.selectMethod"))
                .font(.headline)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.primary, .blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            
 // 使用HStack替代LazyVGrid，提升性能
            HStack(spacing: 12) {
                ForEach(Array(AuthenticationViewModel.LoginMethod.allCases.enumerated()), id: \.element) { index, method in
                    macOSNativeMethodButton(method: method, index: index)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
    
 // MARK: - macOS原生方法按钮
    
    private func macOSNativeMethodButton(method: AuthenticationViewModel.LoginMethod, index: Int) -> some View {
        let isSelected = viewModel.selectedMethod == method
        
        return Button {
 // Apple 2025高性能动画 - 防重复点击
            if !isSelected {
 // 使用轻量级弹性动画
                withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.8)) {
                    viewModel.selectedMethod = method
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: method.icon)
                    .font(.title2)
                    .foregroundStyle(
                        isSelected ? 
                        LinearGradient(
                            colors: [method.primaryColor, method.primaryColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ) : 
                        LinearGradient(
                            colors: [.secondary, .secondary.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Text(method.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .background {
 // macOS原生按钮背景
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(
                                    method.primaryColor.opacity(0.1)
                                )
                                .blendMode(.overlay)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isSelected ? 
                                method.primaryColor.opacity(0.3) :
                                Color.primary.opacity(0.1),
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    }
            }
        }
        .buttonStyle(.plain)
        .modifier(GlassStyleModifier(cornerRadius: 12))
        .contentShape(Rectangle())
    }
    
 // MARK: - 高性能登录表单 - Apple 2025最佳实践
    
    @ViewBuilder
    private var performantLoginForm: some View {
 // 使用条件渲染，避免预加载所有表单
 // 应用Apple 2025推荐的视图优化策略
        Group {
            switch viewModel.selectedMethod {
            case .apple:
                appleLoginForm
                    .id("apple") // 强制视图身份，优化重用
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)).combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .move(edge: .leading)).combined(with: .scale(scale: 1.05))
                    ))
            case .nebula:
                nebulaLoginForm
                    .id("nebula")
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)).combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .move(edge: .leading)).combined(with: .scale(scale: 1.05))
                    ))
            case .phone:
                phoneLoginForm
                    .id("phone")
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)).combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .move(edge: .leading)).combined(with: .scale(scale: 1.05))
                    ))
            case .email:
                emailLoginForm
                    .id("email")
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)).combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .move(edge: .leading)).combined(with: .scale(scale: 1.05))
                    ))
            }
        }
 // 使用Apple 2025推荐的高性能动画
        .animation(.interactiveSpring(response: 0.5, dampingFraction: 0.8), value: viewModel.selectedMethod)
    }

 // MARK: - Apple登录表单
    
    private var appleLoginForm: some View {
        VStack(spacing: 20) {
 // Apple登录按钮 - 彩色液态玻璃风格
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task {
                    switch result {
                    case .success(let authorization):
                        await viewModel.handleAppleAuthorization(authorization)
                    case .failure(let error):
                        await MainActor.run {
                            viewModel.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.3), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            
            Text(LocalizationManager.shared.localizedString("auth.apple.tip"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
 // MARK: - 星云登录表单
    
    private var nebulaLoginForm: some View {
        VStack(spacing: 20) {
 // 注册/登录模式切换
            HStack {
                Button {
                    withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.toggleNebulaRegistrationMode()
                    }
                } label: {
                    Text(viewModel.isNebulaRegistrationMode ? LocalizationManager.shared.localizedString("auth.nebula.toggle.hasAccount") : LocalizationManager.shared.localizedString("auth.nebula.toggle.noAccount"))
                        .font(.caption)
                        .foregroundColor(.purple)
                }
                .buttonStyle(.plain)
                
                Spacer()
            }

            nebulaBrowserLoginHint

 // 主要操作按钮
            if #available(macOS 14.0, *) {
                    LiquidGlassButton(
                        title: viewModel.isNebulaRegistrationMode ? "在安全浏览器中注册" : "在安全浏览器中登录",
                    icon: viewModel.isNebulaRegistrationMode ? "person.badge.plus.fill" : "safari.fill",
                    primaryColor: .purple,
                    isLoading: viewModel.isProcessing
                ) {
                    Task {
                        if viewModel.isNebulaRegistrationMode {
                            await viewModel.registerWithNebula()
                        } else {
                            await viewModel.loginWithNebula()
                        }
                    }
                }
            } else {
                ModernButton(
                    title: viewModel.isNebulaRegistrationMode ? "在安全浏览器中注册" : "在安全浏览器中登录",
                    isLoading: viewModel.isProcessing
                ) {
                    Task {
                        if viewModel.isNebulaRegistrationMode {
                            await viewModel.registerWithNebula()
                        } else {
                            await viewModel.loginWithNebula()
                        }
                    }
                }
            }
            
 // MFA输入（如果需要）
            if viewModel.showMFAInput {
                if #available(macOS 14.0, *) {
                    LiquidGlassTextField(
                        title: LocalizationManager.shared.localizedString("auth.mfa.code"),
                        text: $viewModel.mfaCode,
                        icon: "shield.lefthalf.filled",
                        primaryColor: .purple
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
                } else {
                    ModernTextField(
                        title: LocalizationManager.shared.localizedString("auth.mfa.code"),
                        text: $viewModel.mfaCode,
                        placeholder: "请输入多因素认证码",
                        icon: "shield.lefthalf.filled"
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
                }
                
                if #available(macOS 14.0, *) {
                    LiquidGlassButton(
                        title: LocalizationManager.shared.localizedString("auth.mfa.verify"),
                        icon: "shield.checkered",
                        primaryColor: .purple,
                        isLoading: viewModel.isProcessing
                    ) {
                        Task {
                            await viewModel.verifyMFA()
                        }
                    }
                } else {
                    ModernButton(
                        title: LocalizationManager.shared.localizedString("auth.mfa.verify"),
                        isLoading: viewModel.isProcessing
                    ) {
                        Task {
                            await viewModel.verifyMFA()
                        }
                    }
                }
            }
        }
    }

    private var nebulaBrowserLoginHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(viewModel.isNebulaRegistrationMode ? "推荐使用安全浏览器注册" : "推荐使用安全浏览器登录", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(.purple)

            Text(viewModel.isNebulaRegistrationMode
                 ? "Nebula 注册会在系统浏览器中完成，邮箱验证与二次验证都会留在浏览器授权会话里。"
                 : "Nebula 登录会在系统浏览器中完成，授权与二次验证都会留在浏览器授权会话里。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(viewModel.isNebulaRegistrationMode ? "支持 PKCE、浏览器内注册与 MFA" : "支持 PKCE 与浏览器内 MFA")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(themeConfiguration.cardBackgroundMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(themeConfiguration.borderColor.opacity(0.7), lineWidth: 0.8)
                )
        )
    }
    
 // MARK: - 手机号登录表单
    
    private var phoneLoginForm: some View {
        VStack(spacing: 20) {
 // 注册/登录模式切换
            HStack {
                Button {
                    withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.togglePhoneRegistrationMode()
                    }
                } label: {
                    Text(viewModel.isPhoneRegistrationMode ? LocalizationManager.shared.localizedString("auth.phone.toggle.hasAccount") : LocalizationManager.shared.localizedString("auth.phone.toggle.noAccount"))
                        .font(.caption)
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
            
 // 手机号码输入
            if #available(macOS 14.0, *) {
                LiquidGlassTextField(
                        title: LocalizationManager.shared.localizedString("auth.phone.number"),
                    text: $viewModel.phoneNumber,
                    icon: "phone.circle.fill",
                    primaryColor: .green
                )
            } else {
                    ModernTextField(
                        title: LocalizationManager.shared.localizedString("auth.phone.number"),
                    text: $viewModel.phoneNumber,
                        placeholder: LocalizationManager.shared.localizedString("auth.phone.number.placeholder"),
                    icon: "phone.circle.fill"
                )
            }
            
 // 注册模式下的额外字段
            if viewModel.isPhoneRegistrationMode {
                if #available(macOS 14.0, *) {
                    LiquidGlassTextField(
                        title: LocalizationManager.shared.localizedString("auth.displayName"),
                        text: $viewModel.phoneDisplayName,
                        icon: "person.circle.fill",
                        primaryColor: .green
                    )
                } else {
                    ModernTextField(
                        title: LocalizationManager.shared.localizedString("auth.displayName"),
                        text: $viewModel.phoneDisplayName,
                        placeholder: LocalizationManager.shared.localizedString("auth.displayName.placeholder"),
                        icon: "person.circle.fill"
                    )
                }
                
                if #available(macOS 14.0, *) {
                    LiquidGlassTextField(
                        title: LocalizationManager.shared.localizedString("auth.emailAddress"),
                        text: $viewModel.phoneEmail,
                        icon: "envelope.circle.fill",
                        primaryColor: .green
                    )
                } else {
                    ModernTextField(
                        title: LocalizationManager.shared.localizedString("auth.emailAddress"),
                        text: $viewModel.phoneEmail,
                        placeholder: LocalizationManager.shared.localizedString("auth.emailAddress.placeholder"),
                        icon: "envelope.circle.fill"
                    )
                }
            }
            
 // 验证码输入（发送验证码后显示）
            if viewModel.isPhoneCodeSent {
                if #available(macOS 14.0, *) {
                    LiquidGlassTextField(
                        title: LocalizationManager.shared.localizedString("auth.phone.code"),
                        text: $viewModel.phoneVerificationCode,
                        icon: "number.circle.fill",
                        primaryColor: .green
                    )
                } else {
                    ModernTextField(
                        title: LocalizationManager.shared.localizedString("auth.phone.code"),
                        text: $viewModel.phoneVerificationCode,
                        placeholder: LocalizationManager.shared.localizedString("auth.phone.code.placeholder"),
                        icon: "number.circle.fill"
                    )
                }
                
 // 倒计时显示
                if viewModel.phoneCodeCountdown > 0 {
                    HStack {
                        Text(String(format: LocalizationManager.shared.localizedString("auth.phone.codeSentCountdown"), viewModel.phoneCodeCountdown))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            
 // 主要操作按钮
            if #available(macOS 14.0, *) {
                LiquidGlassButton(
                    title: {
                        if viewModel.isPhoneCodeSent {
                            return viewModel.isPhoneRegistrationMode ? LocalizationManager.shared.localizedString("auth.phone.register.complete") : LocalizationManager.shared.localizedString("auth.phone.login.verify")
                        } else {
                            return viewModel.isPhoneRegistrationMode ? LocalizationManager.shared.localizedString("auth.phone.register.sendCode") : LocalizationManager.shared.localizedString("auth.phone.login.sendCode")
                        }
                    }(),
                    icon: {
                        if viewModel.isPhoneCodeSent {
                            return "checkmark.circle.fill"
                        } else {
                            return "paperplane.circle.fill"
                        }
                    }(),
                    primaryColor: .green,
                    isLoading: viewModel.isProcessing
                ) {
                    Task {
                        if viewModel.isPhoneCodeSent {
                            if viewModel.isPhoneRegistrationMode {
                                await viewModel.registerWithPhone()
                            } else {
                                await viewModel.loginWithPhone()
                            }
                        } else {
                            await viewModel.sendPhoneVerificationCode()
                        }
                    }
                }
            } else {
                ModernButton(
                    title: {
                        if viewModel.isPhoneCodeSent {
                            return viewModel.isPhoneRegistrationMode ? LocalizationManager.shared.localizedString("auth.phone.register.complete") : LocalizationManager.shared.localizedString("auth.phone.login.verify")
                        } else {
                            return viewModel.isPhoneRegistrationMode ? LocalizationManager.shared.localizedString("auth.phone.register.sendCode") : LocalizationManager.shared.localizedString("auth.phone.login.sendCode")
                        }
                    }(),
                    isLoading: viewModel.isProcessing
                ) {
                    Task {
                        if viewModel.isPhoneCodeSent {
                            if viewModel.isPhoneRegistrationMode {
                                await viewModel.registerWithPhone()
                            } else {
                                await viewModel.loginWithPhone()
                            }
                        } else {
                            await viewModel.sendPhoneVerificationCode()
                        }
                    }
                }
            }
            
 // 重新发送验证码按钮（倒计时结束后显示）
            if viewModel.isPhoneCodeSent && viewModel.phoneCodeCountdown == 0 {
                Button {
                    Task {
                        await viewModel.resendPhoneVerificationCode()
                    }
                } label: {
                    Text(LocalizationManager.shared.localizedString("auth.phone.resendCode"))
                        .font(.caption)
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
 // MARK: - 邮箱登录表单
    
    private var emailLoginForm: some View {
        VStack(spacing: 20) {
 // 注册/登录模式切换
            HStack {
                Button {
                    withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.toggleRegistrationMode()
                    }
                } label: {
                    Text(viewModel.isRegistrationMode ? LocalizationManager.shared.localizedString("auth.email.toggle.hasAccount") : LocalizationManager.shared.localizedString("auth.email.toggle.noAccount"))
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
            
 // 邮箱地址输入
            if #available(macOS 14.0, *) {
                LiquidGlassTextField(
                        title: LocalizationManager.shared.localizedString("auth.emailAddress"),
                    text: $viewModel.emailAddress,
                    icon: "envelope.circle.fill",
                    primaryColor: .blue
                )
            } else {
                    ModernTextField(
                        title: LocalizationManager.shared.localizedString("auth.emailAddress"),
                    text: $viewModel.emailAddress,
                        placeholder: LocalizationManager.shared.localizedString("auth.emailAddress.placeholder"),
                    icon: "envelope.circle.fill"
                )
            }
            
 // 密码输入
            if #available(macOS 14.0, *) {
                    LiquidGlassSecureField(
                        title: LocalizationManager.shared.localizedString("auth.password"),
                    text: $viewModel.emailPassword,
                    icon: "lock.circle.fill",
                    primaryColor: .blue
                )
            } else {
                    ModernSecureField(
                        title: LocalizationManager.shared.localizedString("auth.password"),
                    text: $viewModel.emailPassword,
                        placeholder: LocalizationManager.shared.localizedString("auth.password.placeholder"),
                    icon: "lock.circle.fill"
                )
            }
            
 // 注册模式下显示确认密码
            if viewModel.isRegistrationMode {
                if #available(macOS 14.0, *) {
                    LiquidGlassSecureField(
                        title: LocalizationManager.shared.localizedString("auth.confirmPassword"),
                        text: $viewModel.confirmPassword,
                        icon: "lock.shield.fill",
                        primaryColor: .blue
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 1.05))
                    ))
                } else {
                    ModernSecureField(
                        title: LocalizationManager.shared.localizedString("auth.confirmPassword"),
                        text: $viewModel.confirmPassword,
                        placeholder: LocalizationManager.shared.localizedString("auth.confirmPassword.placeholder"),
                        icon: "lock.shield.fill"
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 1.05))
                    ))
                }
            }
            
 // 记住密码开关（仅在登录模式下显示）
            if !viewModel.isRegistrationMode {
                HStack(spacing: 12) {
                    Toggle(isOn: $viewModel.rememberCredentials) {
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .font(.caption)
                                .foregroundColor(.blue)
                            
                            Text(LocalizationManager.shared.localizedString("auth.rememberCredentials"))
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    
                    Spacer()
                }
                .padding(.horizontal, 4)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.95)),
                    removal: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 1.05))
                ))
            }
            
 // 错误信息显示
            if let errorMessage = viewModel.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                    
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.leading)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.red.opacity(0.3), lineWidth: 1)
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.95)),
                    removal: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 1.05))
                ))
            }
            
 // 邮件验证提示
            if viewModel.emailVerificationSent {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.badge.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizationManager.shared.localizedString("auth.email.verification.sent"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                        
                        Text(LocalizationManager.shared.localizedString("auth.email.verification.tip"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.green.opacity(0.3), lineWidth: 1)
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
            }
            
 // 主要操作按钮
            if #available(macOS 14.0, *) {
                    LiquidGlassButton(
                        title: viewModel.isRegistrationMode ? LocalizationManager.shared.localizedString("auth.email.register") : LocalizationManager.shared.localizedString("auth.email.login"),
                    icon: viewModel.isRegistrationMode ? "person.badge.plus.fill" : "envelope.badge.fill",
                    primaryColor: .blue,
                    isLoading: viewModel.isProcessing
                ) {
                    Task {
                        if viewModel.isRegistrationMode {
                            await viewModel.registerWithEmail()
                        } else {
                            await viewModel.loginWithEmail()
                        }
                    }
                }
            } else {
                ModernButton(
                    title: viewModel.isRegistrationMode ? LocalizationManager.shared.localizedString("auth.email.register") : LocalizationManager.shared.localizedString("auth.email.login"),
                    isLoading: viewModel.isProcessing
                ) {
                    Task {
                        if viewModel.isRegistrationMode {
                            await viewModel.registerWithEmail()
                        } else {
                            await viewModel.loginWithEmail()
                        }
                    }
                }
            }
            
 // 登录模式下显示重置密码选项
            if !viewModel.isRegistrationMode {
                Button {
                    Task {
                        await viewModel.resetPassword()
                    }
                } label: {
                    Text(LocalizationManager.shared.localizedString("auth.password.forgot"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .move(edge: .bottom))
                ))
            }
        }
        .animation(.interactiveSpring(response: 0.5, dampingFraction: 0.8), value: viewModel.isRegistrationMode)
    }
    
 // MARK: - 游客模式按钮
    
    private var guestModeButton: some View {
        Button {
            withAnimation(.interactiveSpring(response: 0.5, dampingFraction: 0.8)) {
                viewModel.enterGuestMode()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.dashed")
                    .font(.title3)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.secondary, .secondary.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Text("游客模式体验")
                    .font(.headline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Image(systemName: "arrow.right.circle")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background {
 // 彩色液态玻璃游客按钮背景
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.gray.opacity(0.15),
                                        Color.gray.opacity(0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .blendMode(.overlay)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.secondary.opacity(0.3),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

//

// MARK: - macOS 14 Liquid Glass 文本输入框
@available(macOS 14.0, *)
struct LiquidGlassTextField: View {
    let title: String
    @Binding var text: String
    let icon: String
    let primaryColor: Color
    
 // 🎯 焦点状态管理 - 遵循 Apple 2025 最佳实践
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(
 // 🎯 使用 macOS 26 自适应颜色系统
                    .tint.opacity(isFocused ? 1.0 : 0.7)
                )
                .frame(width: 24)
 // macOS 兼容的动画效果
                .scaleEffect(isFocused ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isFocused)
            
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isFocused)
                .onAppear {
 // 🎯 优化的焦点设置 - 遵循 Apple Silicon 最佳实践
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if text.isEmpty {
                            isFocused = true
                        }
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
 // macOS 26 Liquid Glass 材质效果 - 使用原生macOS API
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.1),
                                    .clear,
                                    .black.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.overlay)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
 // 🎯 自适应液态玻璃渐变
                            .tint.opacity(isFocused ? 0.15 : 0.08)
                        )
                        .blendMode(.overlay)
                }
        }
        .overlay {
             RoundedRectangle(cornerRadius: 12)
                 .stroke(
 // 🎯 智能边框 - 根据焦点状态自适应
                     .tint.opacity(isFocused ? 0.6 : 0.2),
                     lineWidth: isFocused ? 2 : 1
                 )
         }
         .shadow(
             color: isFocused ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.05),
             radius: isFocused ? 12 : 6,
             x: 0,
             y: isFocused ? 6 : 3
         )
         .scaleEffect(isFocused ? 1.02 : 1.0)
         .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: isFocused)
    }
}

// MARK: - macOS 14 Liquid Glass 安全输入框
@available(macOS 14.0, *)
struct LiquidGlassSecureField: View {
    let title: String
    @Binding var text: String
    let icon: String
    let primaryColor: Color
    
 // 🎯 焦点状态管理 - 遵循 Apple 2025 最佳实践
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(
 // 🎯 使用 macOS 26 自适应颜色系统
                    .tint.opacity(isFocused ? 1.0 : 0.7)
                )
                .frame(width: 24)
 // macOS 兼容的动画效果
                .scaleEffect(isFocused ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isFocused)
            
            SecureField(title, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
 // macOS 26 Liquid Glass 材质效果 - 使用原生macOS API
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.1),
                                    .clear,
                                    .black.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.overlay)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
 // 🎯 自适应液态玻璃渐变
                            .tint.opacity(isFocused ? 0.15 : 0.08)
                        )
                        .blendMode(.overlay)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
 // 🎯 智能边框 - 根据焦点状态自适应
                    .tint.opacity(isFocused ? 0.6 : 0.2),
                    lineWidth: isFocused ? 2 : 1
                )
        }
        .shadow(
              color: isFocused ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.05),
              radius: isFocused ? 12 : 6,
              x: 0,
              y: isFocused ? 6 : 3
          )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: isFocused)
    }
}

// MARK: - macOS 26 Liquid Glass 按钮
@available(macOS 14.0, *)
struct LiquidGlassButton: View {
    let title: String
    let icon: String
    let primaryColor: Color
    let isLoading: Bool
    let action: () -> Void
    
    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
 // macOS 兼容的动画效果
                        .opacity(isLoading ? 1.0 : 0.0)
                        .animation(.easeInOut(duration: 0.3), value: isLoading)
                } else {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.white)
 // macOS 兼容的动画效果
                        .scaleEffect(!isLoading ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: !isLoading)
                }
                
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
 // macOS 26 Liquid Glass 材质效果 - 使用原生macOS API
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.1),
                                    .clear,
                                    .black.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.overlay)
                }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
 // 🎯 自适应液态玻璃渐变
                                .tint.opacity(0.8)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(
 // 🎯 增强液态玻璃层次感
                                        .tint.opacity(0.3)
                                    )
                                    .blendMode(.overlay)
                            }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
 // 🎯 智能边框 - 使用自适应颜色
                        .white.opacity(0.3),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.accentColor.opacity(0.4), radius: 12, x: 0, y: 6)
            .shadow(color: Color.accentColor.opacity(0.2), radius: 24, x: 0, y: 12)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .scaleEffect(isLoading ? 0.98 : 1.0)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: isLoading)
    }
}

// MARK: - 现代化输入组件

/// 现代化文本输入框
struct ModernTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .frame(width: 20)
                
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.body)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.quaternary, lineWidth: 1)
            )
        }
    }
}

/// 现代化安全输入框
struct ModernSecureField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let icon: String
    @State private var isSecure = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .frame(width: 20)
                
                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.body)
                
                Button {
                    isSecure.toggle()
                } label: {
                    Image(systemName: isSecure ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.quaternary, lineWidth: 1)
            )
        }
    }
}

/// 现代化按钮
struct ModernButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
                
                Text(title)
                    .font(.body)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [.blue, .purple],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.8 : 1.0)
    }
}

// MARK: - 预览

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        if #available(macOS 14.0, *) {
            AuthenticationView()
                .frame(width: 800, height: 600)
                .environmentObject(ThemeConfiguration.shared)
                .environmentObject(WeatherIntegrationManager.shared)
                .environmentObject(WeatherEffectsSettings.shared)
        } else {
            Text("需要 macOS 14.0 或更高版本")
        }
    }
}
