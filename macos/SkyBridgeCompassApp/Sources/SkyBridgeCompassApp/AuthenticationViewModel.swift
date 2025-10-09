import Foundation
import Combine
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
    @Published var nebulaAccount: String = ""
    @Published var nebulaPassword: String = ""
    @Published var phoneNumber: String = ""
    @Published var phoneCode: String = ""
    @Published var emailAddress: String = ""
    @Published var emailPassword: String = ""
    @Published var registration = RegistrationForm()

    private let service: AuthenticationService
    private var cancellables = Set<AnyCancellable>()

    init(service: AuthenticationService = .shared) {
        self.service = service
        currentSession = nil
        super.init()
        service.sessionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.currentSession = $0 }
            .store(in: &cancellables)
    }

    /// 调用星云账号接口登录。
    func loginNebula() async {
        guard !nebulaAccount.isEmpty, !nebulaPassword.isEmpty else {
            errorMessage = "请输入完整的星云账号与密码"
            return
        }
        await perform { [service, nebulaAccount, nebulaPassword] in
            try await service.loginNebula(account: nebulaAccount, password: nebulaPassword)
        }
    }

    /// 使用手机号与验证码登录。
    func loginPhone() async {
        guard phoneNumber.count >= 6, !phoneCode.isEmpty else {
            errorMessage = "请输入正确的手机号和验证码"
            return
        }
        await perform { [service, phoneNumber, phoneCode] in
            try await service.loginPhone(number: phoneNumber, code: phoneCode)
        }
    }

    /// 使用邮箱登录。
    func loginEmail() async {
        guard emailAddress.contains("@"), !emailPassword.isEmpty else {
            errorMessage = "请输入有效的邮箱地址和密码"
            return
        }
        await perform { [service, emailAddress, emailPassword] in
            try await service.loginEmail(email: emailAddress, password: emailPassword)
        }
    }

    /// 提交注册表单。
    func register() async {
        guard !registration.displayName.isEmpty else {
            errorMessage = "请填写展示名称"
            return
        }
        guard registration.password == registration.confirmPassword else {
            errorMessage = "两次输入的密码不一致"
            return
        }
        await perform { [service, registration] in
            try await service.register(displayName: registration.displayName,
                                       email: registration.email,
                                       phone: registration.phone,
                                       password: registration.password)
        }
    }

    /// 注销当前会话。
    func signOut() {
        service.signOut()
        currentSession = nil
    }

    /// 处理 Sign in with Apple 返回的授权结果。
    func handleAppleAuthorization(_ authorization: ASAuthorization) async {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken else {
            errorMessage = "未能获取 Apple ID 凭据"
            return
        }
        await perform { [service] in
            try await service.authenticateWithApple(identityToken: identityToken,
                                                    authorizationCode: credential.authorizationCode)
        }
    }

    private func perform(_ task: @escaping () async throws -> AuthSession) async {
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
