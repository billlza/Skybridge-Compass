import SwiftUI
import AuthenticationServices
import AppKit

/// 登录界面，提供 Apple ID、星云、手机号、邮箱四种登录方式以及注册入口。
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
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        Task { await viewModel.handleAppleAuthorization(authorization) }
                    case .failure(let error):
                        viewModel.errorMessage = error.localizedDescription
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
                LabeledContent("星云账号") {
                    TextField("请输入星云账号", text: $viewModel.nebulaAccount)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                LabeledContent("密码") {
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
                LabeledContent("手机号") {
                    TextField("请输入手机号", text: $viewModel.phoneNumber)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                LabeledContent("验证码") {
                    HStack {
                        TextField("短信验证码", text: $viewModel.phoneCode)
                            .textFieldStyle(.roundedBorder)
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
                LabeledContent("邮箱") {
                    TextField("name@example.com", text: $viewModel.emailAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                LabeledContent("密码") {
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

/// 注册表单界面。
private struct RegistrationView: View {
    @EnvironmentObject private var viewModel: AuthenticationViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 24) {
            Text("创建 SkyBridge 账户")
                .font(.title2.bold())
            Form {
                TextField("展示名称", text: $viewModel.registration.displayName)
                TextField("企业邮箱", text: $viewModel.registration.email)
                TextField("手机号", text: $viewModel.registration.phone)
                SecureField("密码", text: $viewModel.registration.password)
                SecureField("确认密码", text: $viewModel.registration.confirmPassword)
            }
            .formStyle(.grouped)
            HStack {
                Button("取消", role: .cancel) {
                    isPresented = false
                }
                Spacer()
                Button("提交注册") {
                    Task {
                        await viewModel.register()
                        if viewModel.errorMessage == nil {
                            isPresented = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 520, height: 420)
    }
}
