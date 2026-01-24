import SwiftUI

/// 认证视图 - 登录、注册和游客模式
@available(iOS 17.0, *)
struct AuthenticationView: View {
    @EnvironmentObject private var authManager: AuthenticationManager
    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isLoading = false
    @State private var showSupabaseSettings = false

    init(isRegistering: Bool = false) {
        _isRegistering = State(initialValue: isRegistering)
    }
    
    var body: some View {
        ZStack {
            // 背景渐变
            backgroundGradient
            
            ScrollView {
                VStack(spacing: 28) {
                    // Logo 和标题
                    headerSection
                    
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
        .alert("错误", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showSupabaseSettings) {
            NavigationStack {
                SupabaseSettingsView()
            }
        }
    }
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.05, blue: 0.2),
                Color(red: 0.1, green: 0.05, blue: 0.25),
                Color(red: 0.05, green: 0.1, blue: 0.3)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            // App 图标
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 80))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .cyan, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text("SkyBridge Compass")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
            
            Text("跨平台设备管理与远程控制")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }
    
    private var formSection: some View {
        VStack(spacing: 16) {
            // 邮箱输入
            HStack {
                Image(systemName: "envelope.fill")
                    .foregroundColor(.gray)
                    .frame(width: 20)
                
                TextField("邮箱", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .foregroundColor(.white)
            }
            .padding()
            .background(Color.white.opacity(0.1))
            .cornerRadius(12)
            
            // 密码输入
            HStack {
                Image(systemName: "lock.fill")
                    .foregroundColor(.gray)
                    .frame(width: 20)
                
                SecureField("密码", text: $password)
                    .textContentType(isRegistering ? .newPassword : .password)
                    .foregroundColor(.white)
            }
            .padding()
            .background(Color.white.opacity(0.1))
            .cornerRadius(12)
        }
    }
    
    private var actionButtons: some View {
        VStack(spacing: 16) {
            // 主操作按钮（登录/注册）
            Button(action: performAction) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(isRegistering ? "注册" : "登录")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                LinearGradient(
                    colors: [.blue, .purple],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .cornerRadius(12)
            .disabled(isLoading || !isFormValid)
            .opacity(isFormValid ? 1.0 : 0.6)
            
            // 切换登录/注册
            Button(action: { isRegistering.toggle() }) {
                Text(isRegistering ? "已有账号？登录" : "没有账号？注册")
                    .font(.subheadline)
                    .foregroundColor(.blue)
            }
        }
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
            .frame(height: 50)
            .background(Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
        }
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
                .frame(height: 44)
                .background(Color.white.opacity(0.08))
                .foregroundColor(.white)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
            }
        }
    }

    private var isSupabaseConfigured: Bool {
        SupabaseService.Configuration.fromEnvironment() != nil
    }
    
    private var isFormValid: Bool {
        !email.isEmpty && !password.isEmpty && password.count >= 6
    }
    
    // MARK: - Actions
    
    private func performAction() {
        isLoading = true
        
        Task {
            do {
                if isRegistering {
                    try await authManager.register(email: email, password: password)
                } else {
                    try await authManager.signIn(email: email, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            
            isLoading = false
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
