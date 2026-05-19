import SwiftUI

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
        .sheet(
            item: Binding(
                get: { connectionManager.pendingPairingTrustRequest },
                set: { _ in }
            )
        ) { req in
            PairingTrustRequestSheet(
                request: req,
                onDecision: { decision in
                    Task { @MainActor in
                        await connectionManager.resolvePairingTrustRequest(req, decision: decision)
                    }
                }
            )
        }
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

@available(iOS 17.0, *)
private struct PairingTrustRequestSheet: View {
    let request: P2PConnectionManager.PairingTrustRequest
    let onDecision: (P2PConnectionManager.PairingTrustDecision) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
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
                        dismiss()
                    } label: {
                        Text(RuntimeLocalization.string("始终允许"))
                    }
                    .accessibilityIdentifier("pairing.alwaysAllow")
                    
                    Button {
                        onDecision(.allowOnce)
                        dismiss()
                    } label: {
                        Text(RuntimeLocalization.string("允许本次"))
                    }
                    .accessibilityIdentifier("pairing.allowOnce")
                    
                    Button(role: .destructive) {
                        onDecision(.reject)
                        dismiss()
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
                    Button(RuntimeLocalization.string("关闭")) { dismiss() }
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
