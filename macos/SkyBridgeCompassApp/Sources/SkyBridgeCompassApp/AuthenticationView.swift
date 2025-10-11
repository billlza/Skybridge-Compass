import SwiftUI
import AuthenticationServices
import AppKit

/// 登录界面，提供 Apple ID、星云、手机号、邮箱四种登录方式以及注册入口。
/// 针对macOS 14.0+进行优化，充分利用最新SwiftUI特性
@available(macOS 14.0, *)
struct AuthenticationView: View {
    @EnvironmentObject private var viewModel: AuthenticationViewModel
    @State private var showRegistration = false

    var body: some View {
        HStack(spacing: 0) {
            heroPanel
            Divider().background(Color.white.opacity(0.15))
            VStack(spacing: 24) {
                header
                methodSelector
                loginForm
                footer
            }
            .padding(40)
            .frame(minWidth: 460)
            .background(BlurView())
        }
        .frame(minWidth: 1200, minHeight: 720)
        .background(backgroundGradient)
        .sheet(isPresented: $showRegistration) {
            RegistrationView(isPresented: $showRegistration)
                .environmentObject(viewModel)
        }
        .alert("登录失败", isPresented: Binding(get: {
            viewModel.errorMessage != nil
        }, set: { _ in
            viewModel.errorMessage = nil
        })) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(gradient: Gradient(colors: [
            Color(red: 21/255, green: 31/255, blue: 63/255),
            Color(red: 35/255, green: 16/255, blue: 60/255)
        ]), startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea()
    }

    private var heroPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SkyBridge 云桥司南")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(.white)
            Text("统一的跨平台远程运维控制中枢，登录后即可实时访问真实环境中的设备、会话和文件。")
                .font(.title3)
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(maxWidth: 420, alignment: .leading)
            Spacer()
            HStack(spacing: 24) {
                featureBadge(icon: "lock.shield", title: "企业级安全")
                featureBadge(icon: "sparkle", title: "原生体验")
                featureBadge(icon: "antenna.radiowaves.left.and.right", title: "实时发现")
            }
            .padding(.bottom, 40)
        }
        .padding(48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(gradient: Gradient(colors: [
            Color(red: 41/255, green: 71/255, blue: 189/255).opacity(0.6),
            Color(red: 67/255, green: 31/255, blue: 143/255).opacity(0.4)
        ]), startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("登录您的 SkyBridge 账户")
                .font(.title.bold())
            Text("所有数据均来自真实线上环境，登录后将直接连接生产资源。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var methodSelector: some View {
        HStack(spacing: 12) {
            ForEach(AuthenticationViewModel.LoginMethod.allCases) { method in
                Button {
                    viewModel.selectedMethod = method
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(method.title, systemImage: method.icon)
                            .font(.headline)
                        Text(method.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(viewModel.selectedMethod == method ? Color.accentColor.opacity(0.18) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(viewModel.selectedMethod == method ? Color.accentColor : Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var loginForm: some View {
        switch viewModel.selectedMethod {
        case .apple:
            VStack(spacing: 16) {
                // 如果本机未启用 Sign in with Apple 能力，给出更清晰提示
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        Task { await viewModel.handleAppleAuthorization(authorization) }
                    case .failure(let error):
                        let ns = error as NSError
                        if ns.domain == ASAuthorizationError.errorDomain,
                           ns.code == ASAuthorizationError.Code.unknown.rawValue {
                            viewModel.errorMessage = "当前构建未启用 Sign in with Apple 能力或配置不完整，请在 Xcode Capabilities 打开并使用有效开发者签名。"
                        } else {
                            viewModel.errorMessage = error.localizedDescription
                        }
                    }
                }
                .signInWithAppleButtonStyle(.whiteOutline)
                .frame(height: 48)
                .cornerRadius(12)
                Text("支持原生 Apple ID 登录，登录信息会在钥匙串中安全存储。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .nebula:
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("星云账号")
                        .font(.headline)
                    TextField("请输入星云账号", text: $viewModel.nebulaAccount, onEditingChanged: { isEditing in
                        print("星云账号文本框编辑状态变化: \(isEditing)")
                    }, onCommit: {
                        print("星云账号文本框提交")
                    })
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .textContentType(.username)
                        .frame(width: 260)
                        .onTapGesture {
                            print("星云账号文本框被点击")
                        }
                        .onAppear {
                            print("星云账号文本框出现，当前处理状态: \(viewModel.isProcessing)")
                        }
                        .onChange(of: viewModel.nebulaAccount) { oldValue, newValue in
                            print("星云账号文本框内容变化: '\(oldValue)' -> '\(newValue)'")
                        }
                        .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidChangeNotification)) { notification in
                            print("收到文本变化通知: \(notification)")
                        }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("密码")
                        .font(.headline)
                    SecureField("请输入密码", text: $viewModel.nebulaPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                Button {
                    Task { await viewModel.loginNebula() }
                } label: {
                    Label("登录", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isProcessing)
            }
        case .phone:
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("手机号")
                        .font(.headline)
                    TextField("请输入手机号", text: $viewModel.phoneNumber, onEditingChanged: { isEditing in
                        print("手机号文本框编辑状态变化: \(isEditing)")
                    }, onCommit: {
                        print("手机号文本框提交")
                    })
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .textContentType(macOSVersionCheck() ? .telephoneNumber : nil)
                        .frame(width: 260)
                        .onTapGesture {
                            print("手机号文本框被点击")
                        }
                        .onAppear {
                            print("手机号文本框出现，当前处理状态: \(viewModel.isProcessing)")
                        }
                        .onChange(of: viewModel.phoneNumber) { oldValue, newValue in
                            print("手机号文本框内容变化: '\(oldValue)' -> '\(newValue)'")
                        }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("验证码")
                        .font(.headline)
                    HStack {
                        TextField("短信验证码", text: $viewModel.phoneCode)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                        Button("发送验证码") {
                            NotificationCenter.default.post(name: .init("SkyBridgeRequestOTP"), object: viewModel.phoneNumber)
                        }
                    }
                    .frame(width: 260)
                }
                Button {
                    Task { await viewModel.loginPhone() }
                } label: {
                    Label("登录", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isProcessing)
            }
        case .email:
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("邮箱")
                        .font(.headline)
                    TextField("name@example.com", text: $viewModel.emailAddress, onEditingChanged: { isEditing in
                        print("邮箱文本框编辑状态变化: \(isEditing)")
                    }, onCommit: {
                        print("邮箱文本框提交")
                    })
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .textContentType(macOSVersionCheck() ? .emailAddress : nil)
                        .frame(width: 260)
                        .onTapGesture {
                            print("邮箱文本框被点击")
                        }
                        .onAppear {
                            print("邮箱文本框出现，当前处理状态: \(viewModel.isProcessing)")
                        }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("密码")
                        .font(.headline)
                    SecureField("请输入邮箱密码", text: $viewModel.emailPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                Button {
                    Task { await viewModel.loginEmail() }
                } label: {
                    Label("登录", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isProcessing)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("立即注册") {
                showRegistration = true
            }
            .buttonStyle(.link)

            Spacer()

            // 游客模式按钮
            Button("游客模式") {
                viewModel.enterGuestMode()
            }
            .buttonStyle(.bordered)
            .foregroundColor(.secondary)

            if viewModel.isProcessing {
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
    }

    private func featureBadge(icon: String, title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.callout)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
    }
}

/// 自定义的毛玻璃背景，提升界面质感。
private struct BlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.state = .active
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// macOS版本检查辅助函数，用于确保在支持的系统版本上使用现代化特性
/// - Returns: 如果系统版本支持macOS 14.0+特性则返回true，否则返回false
@available(macOS 14.0, *)
private func macOSVersionCheck() -> Bool {
    return true // 由于已经有@available标记，这里总是返回true
}

/// 注册界面视图，提供多种注册方式
/// 针对macOS 14.0+进行优化
@available(macOS 14.0, *)
private struct RegistrationView: View {
    @EnvironmentObject private var viewModel: AuthenticationViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("创建 SkyBridge 账户")
                .font(.title2.bold())

            Picker("注册方式", selection: $viewModel.selectedRegistration) {
                Text("手机号注册").tag(AuthenticationViewModel.RegistrationMethod.phone)
                Text("邮箱注册").tag(AuthenticationViewModel.RegistrationMethod.email)
                Text("星云账号注册").tag(AuthenticationViewModel.RegistrationMethod.nebula)
            }
            .pickerStyle(.segmented)

            Group {
                switch viewModel.selectedRegistration {
                case .phone:
                    Form {
                        TextField("手机号", text: $viewModel.regPhoneNumber)
                            .disableAutocorrection(true)
                        HStack {
                            TextField("短信验证码", text: $viewModel.regPhoneCode)
                                .disableAutocorrection(true)
                            Button("发送验证码") {
                                NotificationCenter.default.post(name: .init("SkyBridgeRequestOTP"), object: viewModel.regPhoneNumber)
                            }
                        }
                        SecureField("设置密码", text: $viewModel.regPhonePassword)
                        SecureField("确认密码", text: $viewModel.regPhoneConfirm)
                    }
                case .email:
                    Form {
                        TextField("邮箱地址", text: $viewModel.regEmailAddress)
                            .disableAutocorrection(true)
                        SecureField("设置密码", text: $viewModel.regEmailPassword)
                        SecureField("确认密码", text: $viewModel.regEmailConfirm)
                    }
                case .nebula:
                    Form {
                        TextField("星云账号", text: $viewModel.regNebulaAccount)
                            .disableAutocorrection(true)
                        SecureField("设置密码", text: $viewModel.regNebulaPassword)
                        SecureField("确认密码", text: $viewModel.regNebulaConfirm)
                        TextField("绑定手机号", text: $viewModel.regNebulaPhone)
                            .disableAutocorrection(true)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("取消", role: .cancel) { isPresented = false }
                Spacer()
                Button("提交注册") {
                    Task {
                        await viewModel.register()
                        if viewModel.errorMessage == nil { isPresented = false }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
