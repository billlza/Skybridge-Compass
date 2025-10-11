import Foundation
import Combine
import SwiftUI
import AuthenticationServices
import SkyBridgeCore

/// 登录视图模型，封装苹果登录、星云账号、手机号、邮箱以及注册流程。
@MainActor
final class AuthenticationViewModel: NSObject, ObservableObject {
    /// 登录方式选项，全部对接真实后端接口。
    enum LoginMethod: String, CaseIterable, Identifiable {
        case apple
        case nebula
        case phone
        case email

        var id: String { rawValue }

        var title: String {
            switch self {
            case .apple: return "Apple ID"
            case .nebula: return "星云账号"
            case .phone: return "手机号"
            case .email: return "邮箱"
            }
        }

        var subtitle: String {
            switch self {
            case .apple: return "使用原生 Apple ID 快速登录"
            case .nebula: return "连接企业星云账户"
            case .phone: return "输入手机号与验证码"
            case .email: return "使用企业邮箱登录"
            }
        }

        var icon: String {
            switch self {
            case .apple: return "applelogo"
            case .nebula: return "icloud"
            case .phone: return "phone"
            case .email: return "envelope"
            }
        }
    }

    /// 注册所需的表单字段。
    struct RegistrationForm {
        var displayName: String = ""
        var email: String = ""
        var phone: String = ""
        var password: String = ""
        var confirmPassword: String = ""
    }

    @Published var currentSession: AuthSession?
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var selectedMethod: LoginMethod = .apple
    @Published var isGuestMode = false // 游客模式状态
    @Published var nebulaAccount: String = ""
    @Published var nebulaPassword: String = ""
    @Published var phoneNumber: String = ""
    @Published var phoneCode: String = ""
    @Published var emailAddress: String = ""
    @Published var emailPassword: String = ""
    @Published var registration = RegistrationForm()
    
    // 注册方式：手机号 / 邮箱 / 星云账号（注册后需绑定手机号）
    enum RegistrationMethod: String, CaseIterable, Identifiable { case phone, email, nebula; var id: String { rawValue } }
    @Published var selectedRegistration: RegistrationMethod = .phone

    // 分渠道的注册字段（更贴合你的期望）
    @Published var regPhoneNumber: String = ""
    @Published var regPhoneCode: String = ""
    @Published var regPhonePassword: String = ""
    @Published var regPhoneConfirm: String = ""

    @Published var regEmailAddress: String = ""
    @Published var regEmailPassword: String = ""
    @Published var regEmailConfirm: String = ""

    @Published var regNebulaAccount: String = ""
    @Published var regNebulaPassword: String = ""
    @Published var regNebulaConfirm: String = ""
    @Published var regNebulaPhone: String = ""

    private let service: AuthenticationService
    private var cancellables = Set<AnyCancellable>()

    init(service: AuthenticationService = .shared) {
        self.service = service
        currentSession = nil
        super.init()
        service.sessionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in self?.currentSession = session }
            .store(in: &cancellables)
    }

    /// 调用星云账号接口登录。
    func loginNebula() async {
        guard !nebulaAccount.isEmpty, !nebulaPassword.isEmpty else {
            errorMessage = "请输入完整的星云账号与密码"
            return
        }
        await performAuthTask { [service, nebulaAccount, nebulaPassword] in
            try await service.loginNebula(account: nebulaAccount, password: nebulaPassword)
        }
    }

    /// 使用手机号与验证码登录。
    func loginPhone() async {
        guard phoneNumber.count >= 6, !phoneCode.isEmpty else {
            errorMessage = "请输入正确的手机号和验证码"
            return
        }
        await performAuthTask { [service, phoneNumber, phoneCode] in
            try await service.loginPhone(number: phoneNumber, code: phoneCode)
        }
    }

    /// 使用邮箱登录。
    func loginEmail() async {
        guard emailAddress.contains("@"), !emailPassword.isEmpty else {
            errorMessage = "请输入有效的邮箱地址和密码"
            return
        }
        await performAuthTask { [service, emailAddress, emailPassword] in
            try await service.loginEmail(email: emailAddress, password: emailPassword)
        }
    }

    // 旧的统一注册入口已被新的分渠道注册替代

    /// 注销当前会话。
    func signOut() {
        service.signOut()
        currentSession = nil
        isGuestMode = false // 退出游客模式
    }

    /// 进入游客模式，无需登录直接访问主界面
    func enterGuestMode() {
        isGuestMode = true
        // 创建一个临时的游客会话，用于标识游客状态
        currentSession = AuthSession(
            accessToken: "guest_token",
            refreshToken: nil,
            userIdentifier: "guest_user",
            displayName: "游客用户",
            issuedAt: Date()
        )
    }

    /// 处理 Sign in with Apple 返回的授权结果。
    func handleAppleAuthorization(_ authorization: ASAuthorization) async {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken else {
            errorMessage = "未能获取 Apple ID 凭据"
            return
        }
        await performAuthTask { [service] in
            try await service.authenticateWithApple(identityToken: identityToken,
                                                    authorizationCode: credential.authorizationCode)
        }
    }

    /// 根据所选注册方式分派处理
    func register() async {
        switch selectedRegistration {
        case .phone:
            await registerWithPhone()
        case .email:
            await registerWithEmail()
        case .nebula:
            await registerNebulaWithPhoneBinding()
        }
    }

    /// 手机号注册（短信验证码 + 设置密码）
    private func registerWithPhone() async {
        guard regPhoneNumber.count >= 6 else { errorMessage = "请输入正确的手机号"; return }
        guard !regPhoneCode.isEmpty else { errorMessage = "请输入短信验证码"; return }
        guard regPhonePassword == regPhoneConfirm, !regPhonePassword.isEmpty else { errorMessage = "两次输入的密码不一致"; return }

        await performAuthTask { [service, regPhoneNumber, regPhonePassword] in
            // 简化表单：仅携带必要字段，邮箱留空
            try await service.register(displayName: regPhoneNumber,
                                       email: "",
                                       phone: regPhoneNumber,
                                       password: regPhonePassword)
        }
    }

    /// 邮箱注册（邮箱 + 设置密码）
    private func registerWithEmail() async {
        guard regEmailAddress.contains("@") else { errorMessage = "请输入有效的邮箱地址"; return }
        guard regEmailPassword == regEmailConfirm, !regEmailPassword.isEmpty else { errorMessage = "两次输入的密码不一致"; return }

        await performAuthTask { [service, regEmailAddress, regEmailPassword] in
            // 简化表单：仅携带必要字段，手机号留空
            try await service.register(displayName: regEmailAddress,
                                       email: regEmailAddress,
                                       phone: "",
                                       password: regEmailPassword)
        }
    }

    /// 星云账号注册 -> 绑定手机号（一次性收集后提交）
    private func registerNebulaWithPhoneBinding() async {
        guard !regNebulaAccount.isEmpty else { errorMessage = "请输入星云账号"; return }
        guard regNebulaPassword == regNebulaConfirm, !regNebulaPassword.isEmpty else { errorMessage = "两次输入的密码不一致"; return }
        guard regNebulaPhone.count >= 6 else { errorMessage = "请输入要绑定的手机号"; return }

        await performAuthTask { [service, regNebulaAccount, regNebulaPhone, regNebulaPassword] in
            // 后端暂统一注册入口：以星云账号为展示名，绑定手机号
            try await service.register(displayName: regNebulaAccount,
                                       email: "",
                                       phone: regNebulaPhone,
                                       password: regNebulaPassword)
        }
    }

    // 避免与 NSObject 的 perform(_:) 选择器 API 名称冲突
    private func performAuthTask(_ task: @escaping () async throws -> AuthSession) async {
        isProcessing = true
        do {
            _ = try await task()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isProcessing = false
    }
}
