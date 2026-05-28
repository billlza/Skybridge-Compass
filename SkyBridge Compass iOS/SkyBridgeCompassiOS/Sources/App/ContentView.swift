import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 主内容视图 - 应用入口
@available(iOS 17.0, *)
struct ContentView: View {
    @EnvironmentObject private var appState: AppStateManager
    @EnvironmentObject private var authManager: AuthenticationManager
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    @StateObject private var crossNetworkManager = CrossNetworkWebRTCManager.instance

    private var contentTransitionAnimation: Animation? {
        ProcessInfo.processInfo.arguments.contains("UITEST_DISABLE_ANIMATIONS") ? nil : .easeInOut
    }
    
    var body: some View {
        Group {
            if authManager.isAuthenticated {
                // 已认证 - 显示主控制台
                DashboardView()
                    .accessibilityIdentifier("content.dashboard")
            } else {
                // 未认证 - 显示登录界面
                AuthenticationView()
                    .accessibilityIdentifier("content.authentication")
            }
        }
        .animation(contentTransitionAnimation, value: authManager.isAuthenticated)
        .background(
            PairingTrustPromptWindowPresenter(
                request: connectionManager.pendingPairingTrustRequest,
                onDecision: { req, decision in
                    Task { @MainActor in
                        await connectionManager.resolvePairingTrustRequest(req, decision: decision)
                    }
                }
            )
            .frame(width: 0, height: 0)
        )
        .alert(
            RuntimeLocalization.string("idleConnection.prompt.title"),
            isPresented: Binding(
                get: { crossNetworkManager.idleConnectionPrompt != nil },
                set: { presenting in
                    if !presenting {
                        crossNetworkManager.dismissIdleConnectionPrompt()
                    }
                }
            )
        ) {
            Button(RuntimeLocalization.string("idleConnection.keep"), role: .cancel) {
                crossNetworkManager.dismissIdleConnectionPrompt()
            }
            Button(RuntimeLocalization.string("idleConnection.disconnect"), role: .destructive) {
                Task {
                    await crossNetworkManager.disconnect()
                    await MainActor.run {
                        crossNetworkManager.dismissIdleConnectionPrompt()
                    }
                }
            }
        } message: {
            Text(
                String(
                    format: RuntimeLocalization.string("idleConnection.prompt.message"),
                    crossNetworkManager.idleConnectionPrompt?.deviceName
                        ?? RuntimeLocalization.string("idleConnection.notification.defaultDevice")
                )
            )
        }
    }
}

#if canImport(UIKit)
@available(iOS 17.0, *)
private struct PairingTrustPromptWindowPresenter: UIViewControllerRepresentable {
    let request: P2PConnectionManager.PairingTrustRequest?
    let onDecision: @MainActor (P2PConnectionManager.PairingTrustRequest, P2PConnectionManager.PairingTrustDecision) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.update(
            request: request,
            hostViewController: uiViewController,
            onDecision: onDecision
        )
    }

    @MainActor
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        _ = uiViewController
        coordinator.dismissWindow()
    }

    @MainActor
    final class Coordinator {
        private var window: UIWindow?
        private var currentRequestId: UUID?

        func update(
            request: P2PConnectionManager.PairingTrustRequest?,
            hostViewController: UIViewController,
            onDecision: @escaping @MainActor (P2PConnectionManager.PairingTrustRequest, P2PConnectionManager.PairingTrustDecision) -> Void
        ) {
            guard let request else {
                dismissWindow()
                return
            }

            guard let scene = hostViewController.view.window?.windowScene ?? Self.activeForegroundScene() else {
                return
            }

            if window?.windowScene !== scene || currentRequestId != request.id {
                dismissWindow()
                let promptWindow = UIWindow(windowScene: scene)
                promptWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
                promptWindow.backgroundColor = .clear
                window = promptWindow
                currentRequestId = request.id
            }

            let rootView = PairingTrustPromptWindowContent(
                request: request,
                onDecision: { [weak self] decision in
                    self?.dismissWindow()
                    onDecision(request, decision)
                }
            )
            let hostingController = UIHostingController(rootView: rootView)
            hostingController.view.backgroundColor = .clear
            window?.rootViewController = hostingController
            window?.isHidden = false
        }

        func dismissWindow() {
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
            currentRequestId = nil
        }

        private static func activeForegroundScene() -> UIWindowScene? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
        }
    }
}

@available(iOS 17.0, *)
private struct PairingTrustPromptWindowContent: View {
    let request: P2PConnectionManager.PairingTrustRequest
    let onDecision: @MainActor (P2PConnectionManager.PairingTrustDecision) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture {
                    onDecision(.reject)
                }

            PairingTrustRequestSheet(
                request: request,
                onDecision: onDecision
            )
            .frame(maxWidth: 540, maxHeight: 660)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 24)
            .padding(20)
            .accessibilityIdentifier("pairing.overlay")
        }
    }
}
#endif

@available(iOS 17.0, *)
private struct PairingTrustRequestSheet: View {
    let request: P2PConnectionManager.PairingTrustRequest
    let onDecision: @MainActor (P2PConnectionManager.PairingTrustDecision) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section(RuntimeLocalization.string("设备信息")) {
                    LabeledContent(RuntimeLocalization.string("名称"), value: request.deviceName)
                    LabeledContent(RuntimeLocalization.string("平台"), value: request.platform.displayName)
                    if !request.modelName.isEmpty {
                        LabeledContent(RuntimeLocalization.string("型号"), value: request.modelName)
                    }
                    LabeledContent(RuntimeLocalization.string("系统"), value: request.osVersion)
                }

                if request.purpose == .protocolIdentityBinding,
                   let code = request.verificationCode,
                   !code.isEmpty {
                    Section {
                        Text(code)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("pairing.verificationCode")
                        if let fingerprint = request.protocolIdentityFingerprint, !fingerprint.isEmpty {
                            LabeledContent(RuntimeLocalization.string("协议身份指纹"), value: fingerprint)
                        }
                    } header: {
                        Text(RuntimeLocalization.string("设备确认码"))
                    } footer: {
                        Text(RuntimeLocalization.string("请确认 Mac 上显示的 6 位确认码完全一致后再允许。该流程只绑定协议身份；KEM 仍会通过 SKR-1 签名刷新导入。"))
                    }
                }
                
                Section(RuntimeLocalization.string("识别信息")) {
                    LabeledContent(RuntimeLocalization.string("Peer ID"), value: request.peerId)
                    if !request.declaredDeviceId.isEmpty {
                        LabeledContent(RuntimeLocalization.string("声明的 Device ID"), value: request.declaredDeviceId)
                    }
                    if request.kemKeyCount > 0 {
                        LabeledContent(RuntimeLocalization.string("KEM Keys"), value: "\(request.kemKeyCount)")
                    }
                }
                
                Section {
                    Button {
                        onDecision(.alwaysAllow)
                    } label: {
                        Text(RuntimeLocalization.string("始终允许"))
                    }
                    .accessibilityIdentifier("pairing.alwaysAllow")
                    
                    Button {
                        onDecision(.allowOnce)
                    } label: {
                        Text(RuntimeLocalization.string("允许本次"))
                    }
                    .accessibilityIdentifier("pairing.allowOnce")
                    
                    Button(role: .destructive) {
                        onDecision(.reject)
                    } label: {
                        Text(RuntimeLocalization.string("拒绝"))
                    }
                    .accessibilityIdentifier("pairing.reject")
                } footer: {
                    Text(request.purpose == .protocolIdentityBinding
                         ? RuntimeLocalization.string("这是协议身份重新绑定申请。允许后系统会重新固定该设备身份，然后通过 SKR-1 刷新 KEM；不会启用 classic fallback。")
                         : RuntimeLocalization.string("这是对端发起的配对/受信任申请。若选择“始终允许”，系统会记住该设备并允许后续的 PQC 引导流程。"))
                }
            }
            .accessibilityIdentifier("pairing.sheet")
            .navigationTitle(RuntimeLocalization.string("受信任申请"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(RuntimeLocalization.string("关闭")) { onDecision(.reject) }
                }
            }
        }
    }
}

// MARK: - Preview
#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppStateManager())
            .environmentObject(AuthenticationManager.instance)
            .environmentObject(ThemeConfiguration.instance)
            .environmentObject(LocalizationManager.instance)
            .environmentObject(P2PConnectionManager.instance)
    }
}
#endif
