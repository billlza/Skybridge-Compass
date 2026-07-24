import SwiftUI
#if canImport(UIKit)
import QuartzCore
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
    @StateObject private var inboundFileTransferApproval = InboundFileTransferApprovalService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var pairingTrustError: String?

    var body: some View {
        Group {
            if authManager.isRestoringSession {
                ZStack {
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                }
                .accessibilityIdentifier("content.restoringSession")
            } else if authManager.isAuthenticated {
                // 已认证 - 显示主控制台
                DashboardView()
                    .accessibilityIdentifier("content.dashboard")
            } else {
                // 未认证 - 显示登录界面
                AuthenticationView()
                    .accessibilityIdentifier("content.authentication")
            }
        }
        .background(
            PairingTrustPromptWindowPresenter(
                request: connectionManager.pendingPairingTrustRequest,
                sceneIsActive: scenePhase == .active,
                onDecision: { req, decision in
                    Task { @MainActor in
                        do {
                            try await connectionManager.resolvePairingTrustRequest(
                                req,
                                decision: decision
                            )
                        } catch {
                            pairingTrustError = error.localizedDescription
                        }
                    }
                }
            )
            .frame(width: 0, height: 0)
        )
        .alert(
            "配对/信任更新失败",
            isPresented: Binding(
                get: { pairingTrustError != nil },
                set: { if !$0 { pairingTrustError = nil } }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(pairingTrustError ?? "未知错误")
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
        .sheet(
            item: Binding(
                get: { inboundFileTransferApproval.pendingRequest },
                set: { request in
                    if request == nil {
                        inboundFileTransferApproval.rejectPendingRequestBecausePresentationEnded()
                    }
                }
            )
        ) { request in
            InboundFileTransferApprovalView(
                pendingRequest: request,
                onApprove: { inboundFileTransferApproval.approve(request) },
                onReject: { inboundFileTransferApproval.reject(request) }
            )
        }
    }
}

#if canImport(UIKit)
@available(iOS 17.0, *)
struct PairingTrustPromptWindowPresenter: UIViewControllerRepresentable {
    let request: P2PConnectionManager.PairingTrustRequest?
    let sceneIsActive: Bool
    let onDecision: @MainActor (P2PConnectionManager.PairingTrustRequest, P2PConnectionManager.PairingTrustDecision) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let hostViewController = UIViewController()
        let hostView = PairingTrustPromptHostView()
        hostViewViewControllerAttach(
            hostView,
            to: hostViewController,
            coordinator: context.coordinator
        )
        return hostViewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.update(
            request: request,
            hostViewController: uiViewController,
            sceneIsActive: sceneIsActive,
            onDecision: onDecision
        )
    }

    @MainActor
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        (uiViewController.viewIfLoaded as? PairingTrustPromptHostView)?.onWindowSceneChange = nil
        coordinator.retireWindow()
    }

    @MainActor
    private func hostViewViewControllerAttach(
        _ hostView: PairingTrustPromptHostView,
        to hostViewController: UIViewController,
        coordinator: Coordinator
    ) {
        hostViewController.view = hostView
        coordinator.attach(hostViewController: hostViewController)
        hostView.onWindowSceneChange = { [weak coordinator] scene in
            coordinator?.hostWindowSceneDidChange(scene)
        }
    }

    @MainActor
    final class Coordinator {
        private struct PendingPresentation {
            let request: P2PConnectionManager.PairingTrustRequest
            let onDecision: @MainActor (
                P2PConnectionManager.PairingTrustRequest,
                P2PConnectionManager.PairingTrustDecision
            ) -> Void
        }

        private var window: UIWindow?
        private var hostingController: PairingTrustPromptHostingController?
        private weak var hostViewController: UIViewController?
        private var pendingPresentation: PendingPresentation?
        private var sceneIsActive = false
        private var currentRequestId: UUID?
        private var presentationToken: UUID?
        private var settledRequestId: UUID?
        private weak var previousKeyWindow: UIWindow?
        private let sceneActivationEvaluator: @MainActor (UIWindowScene) -> Bool

        init(
            sceneActivationEvaluator: @escaping @MainActor (UIWindowScene) -> Bool = {
                $0.activationState == .foregroundActive
            }
        ) {
            self.sceneActivationEvaluator = sceneActivationEvaluator
        }

        func attach(hostViewController: UIViewController) {
            self.hostViewController = hostViewController
        }

        func hostWindowSceneDidChange(_ scene: UIWindowScene?) {
            if let window,
               window.windowScene !== scene {
                retirePresentationWindow()
            }
            guard let scene else {
                return
            }
            guard sceneIsActive, sceneActivationEvaluator(scene) else {
                suspendWindowForInactiveScene()
                return
            }
            presentPendingPresentationIfPossible()
        }

        func update(
            request: P2PConnectionManager.PairingTrustRequest?,
            hostViewController: UIViewController,
            sceneIsActive: Bool,
            onDecision: @escaping @MainActor (P2PConnectionManager.PairingTrustRequest, P2PConnectionManager.PairingTrustDecision) -> Void
        ) {
            attach(hostViewController: hostViewController)
            self.sceneIsActive = sceneIsActive
            retirePresentationWindowIfHostSceneChanged()

            guard let request else {
                settledRequestId = nil
                dismissWindow()
                return
            }

            guard settledRequestId != request.id else {
                suspendWindowForInactiveScene()
                return
            }
            if settledRequestId != nil {
                settledRequestId = nil
            }

            pendingPresentation = PendingPresentation(
                request: request,
                onDecision: onDecision
            )
            guard sceneIsActive else {
                suspendWindowForInactiveScene()
                return
            }
            presentPendingPresentationIfPossible()
        }

        private func presentPendingPresentationIfPossible() {
            guard sceneIsActive,
                  let pendingPresentation,
                  let scene = hostViewController?.viewIfLoaded?.window?.windowScene,
                  sceneActivationEvaluator(scene) else {
                return
            }

            let request = pendingPresentation.request
            let onDecision = pendingPresentation.onDecision

            ensureWindow(for: scene)

            let token: UUID
            if currentRequestId == request.id, let existingToken = presentationToken {
                token = existingToken
            } else {
                token = UUID()
            }
            currentRequestId = request.id
            presentationToken = token
            let presentation = PairingTrustPromptWindowPresentation(
                request: request,
                onDecision: { [weak self] decision in
                    guard let self,
                          self.canClaimDecision(requestId: request.id, token: token) else {
                        return
                    }
                    self.settledRequestId = request.id
                    self.dismissWindow()
                    onDecision(request, decision)
                }
            )
            hostingController?.rootView = PairingTrustPromptWindowContent(
                presentation: presentation
            )
            presentWindowIfReady()
        }

        func dismissWindow() {
            pendingPresentation = nil
            let hadPresentation = currentRequestId != nil || presentationToken != nil
            currentRequestId = nil
            presentationToken = nil

            guard let dismissedWindow = window,
                  let dismissedHostingController = hostingController,
                  hadPresentation || dismissedHostingController.rootView.presentation != nil else {
                return
            }

            dismissedWindow.isUserInteractionEnabled = false
            dismissedWindow.accessibilityElementsHidden = true
            dismissedWindow.alpha = 0
            relinquishPromptKeyWindowIfNeeded()

            // Keep the additional window and hosting controller alive. Toggling UIWindow.isHidden
            // while UIKit is still presenting this controller can leave appearance calls unbalanced.
            // A newer request invalidates this cleanup by changing the request/token state.
            DispatchQueue.main.async { [weak self, weak dismissedWindow, weak dismissedHostingController] in
                guard let self,
                      let dismissedWindow,
                      let dismissedHostingController,
                      self.window === dismissedWindow,
                      self.hostingController === dismissedHostingController,
                      self.currentRequestId == nil,
                      self.presentationToken == nil else {
                    return
                }
                dismissedHostingController.rootView = PairingTrustPromptWindowContent(
                    presentation: nil
                )
            }
        }

        func retireWindow() {
            pendingPresentation = nil
            settledRequestId = nil
            sceneIsActive = false
            hostViewController = nil
            retirePresentationWindow()
        }

        private func retirePresentationWindow() {
            currentRequestId = nil
            presentationToken = nil
            relinquishPromptKeyWindowIfNeeded()

            guard let retiringWindow = window else {
                precondition(
                    hostingController == nil,
                    "The pairing prompt window and hosting controller must share one lifetime."
                )
                return
            }
            guard let retiringHostingController = hostingController else {
                preconditionFailure(
                    "A pairing prompt window must never exist without its hosting controller."
                )
            }
            window = nil
            hostingController = nil

            retiringWindow.isUserInteractionEnabled = false
            retiringWindow.accessibilityElementsHidden = true
            retiringWindow.alpha = 0
            retiringHostingController.retire(from: retiringWindow)
        }

#if DEBUG || SKYBRIDGE_TESTING
        var testOnlyHostingControllerIdentifier: ObjectIdentifier? {
            hostingController.map(ObjectIdentifier.init)
        }

        var testOnlyWindowIdentifier: ObjectIdentifier? {
            window.map(ObjectIdentifier.init)
        }

        var testOnlyWindowObject: UIWindow? {
            window
        }

        var testOnlyHostingControllerObject: UIViewController? {
            hostingController
        }

        var testOnlyIsWindowHidden: Bool? {
            window?.isHidden
        }

        var testOnlyIsWindowKey: Bool? {
            window?.isKeyWindow
        }

        var testOnlyIsWindowConcealed: Bool {
            guard let window else { return true }
            return window.alpha == 0
                && !window.isUserInteractionEnabled
                && window.accessibilityElementsHidden
        }

        var testOnlyHasPromptContent: Bool {
            hostingController?.rootView.presentation != nil
        }

        func testOnlyDecisionHandler() -> (@MainActor (P2PConnectionManager.PairingTrustDecision) -> Void)? {
            hostingController?.rootView.presentation?.onDecision
        }
#endif

        private func presentWindowIfReady() {
            guard let window,
                  currentRequestId != nil,
                  presentationToken != nil,
                  let scene = window.windowScene,
                  sceneActivationEvaluator(scene) else {
                return
            }

            window.accessibilityElementsHidden = false
            window.alpha = 1
            window.isUserInteractionEnabled = true
            if window.isHidden {
                if let currentKeyWindow = window.windowScene?.windows.first(where: \.isKeyWindow),
                   currentKeyWindow !== window {
                    previousKeyWindow = currentKeyWindow
                }
                window.makeKeyAndVisible()
            } else if !window.isKeyWindow {
                if let currentKeyWindow = window.windowScene?.windows.first(where: \.isKeyWindow),
                   currentKeyWindow !== window {
                    previousKeyWindow = currentKeyWindow
                }
                window.makeKey()
            }
        }

        private func suspendWindowForInactiveScene() {
            guard let window else { return }
            currentRequestId = nil
            presentationToken = nil
            window.isUserInteractionEnabled = false
            window.accessibilityElementsHidden = true
            window.alpha = 0
            relinquishPromptKeyWindowIfNeeded()
        }

        private func retirePresentationWindowIfHostSceneChanged() {
            guard let window else { return }
            guard let hostScene = hostViewController?.viewIfLoaded?.window?.windowScene,
                  window.windowScene === hostScene else {
                retirePresentationWindow()
                return
            }
        }

        private func canClaimDecision(requestId: UUID, token: UUID) -> Bool {
            guard currentRequestId == requestId,
                  presentationToken == token,
                  sceneIsActive,
                  let window,
                  !window.isHidden,
                  window.alpha > 0,
                  window.isUserInteractionEnabled,
                  !window.accessibilityElementsHidden,
                  window.isKeyWindow,
                  let scene = window.windowScene,
                  hostViewController?.viewIfLoaded?.window?.windowScene === scene,
                  sceneActivationEvaluator(scene) else {
                return false
            }
            return true
        }

        private func relinquishPromptKeyWindowIfNeeded() {
            guard let promptWindow = window, promptWindow.isKeyWindow else {
                previousKeyWindow = nil
                return
            }

            let owningScene = promptWindow.windowScene
            let cachedWindow: UIWindow?
            if let candidate = previousKeyWindow,
               candidate !== promptWindow,
               candidate.windowScene === owningScene,
               !candidate.isHidden {
                cachedWindow = candidate
            } else {
                cachedWindow = nil
            }
            let fallbackWindow = owningScene?.windows.first { candidate in
                candidate !== promptWindow
                    && !candidate.isHidden
                    && candidate.alpha > 0
                    && candidate.windowLevel == .normal
                    && candidate.rootViewController != nil
            }

            promptWindow.resignKey()
            (cachedWindow ?? fallbackWindow)?.makeKey()
            previousKeyWindow = nil
        }

        private func ensureWindow(for scene: UIWindowScene) {
            if let window,
               window.windowScene === scene,
               hostingController != nil {
                return
            }

            retirePresentationWindow()

            let hostingController = PairingTrustPromptHostingController()
            hostingController.view.backgroundColor = .clear

            let promptWindow = UIWindow(windowScene: scene)
            promptWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            promptWindow.backgroundColor = .clear
            promptWindow.rootViewController = hostingController
            promptWindow.isUserInteractionEnabled = false
            promptWindow.accessibilityElementsHidden = true
            promptWindow.alpha = 0
            promptWindow.isHidden = true

            self.hostingController = hostingController
            window = promptWindow
        }

    }
}

@available(iOS 17.0, *)
private final class PairingTrustPromptHostView: UIView {
    var onWindowSceneChange: (@MainActor (UIWindowScene?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowSceneChange?(window?.windowScene)
    }
}

@available(iOS 17.0, *)
private struct PairingTrustPromptWindowPresentation {
    let request: P2PConnectionManager.PairingTrustRequest
    let onDecision: @MainActor (P2PConnectionManager.PairingTrustDecision) -> Void
}

@available(iOS 17.0, *)
private struct PairingTrustPromptWindowContent: View {
    let presentation: PairingTrustPromptWindowPresentation?

    @ViewBuilder
    var body: some View {
        if let presentation {
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture {
                        presentation.onDecision(.reject)
                    }

                PairingTrustRequestSheet(
                    request: presentation.request,
                    onDecision: presentation.onDecision
                )
                .frame(maxWidth: 540, maxHeight: 660)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(radius: 24)
                .padding(20)
                .accessibilityIdentifier("pairing.overlay")
            }
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }
}

@available(iOS 17.0, *)
@MainActor
private final class PairingTrustPromptHostingController:
    UIHostingController<PairingTrustPromptWindowContent>
{
    private enum AppearanceState {
        case detached
        case appearing
        case visible
        case disappearing
    }

    private struct PendingRetirement {
        let token: UUID
        let window: UIWindow
    }

    private var appearanceState = AppearanceState.detached
    private var pendingRetirement: PendingRetirement?
    private var scheduledRetirementToken: UUID?

    init() {
        super.init(rootView: PairingTrustPromptWindowContent(presentation: nil))
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("PairingTrustPromptHostingController is programmatic-only.")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appearanceState = .appearing
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appearanceState = .visible
        scheduleRetirementAdvanceIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appearanceState = .disappearing
        guard !animated, let token = pendingRetirement?.token else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.appearanceState == .disappearing,
                  let retirement = self.pendingRetirement,
                  retirement.token == token,
                  retirement.window.isHidden else {
                return
            }
            // Secondary UIWindow teardown does not consistently deliver viewDidDisappear for a
            // non-animated hide. Once the next main turn observes the window as hidden, UIKit's
            // synchronous disappearance transaction has ended and the graph can advance safely.
            self.appearanceState = .detached
            self.scheduleRetirementAdvanceIfNeeded()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appearanceState = .detached
        scheduleRetirementAdvanceIfNeeded()
    }

    func retire(from window: UIWindow) {
        precondition(
            pendingRetirement == nil,
            "A pairing prompt hosting controller may only retire once."
        )
        precondition(
            window.rootViewController === self,
            "The retiring pairing prompt window must own this hosting controller."
        )

        pendingRetirement = PendingRetirement(token: UUID(), window: window)
        scheduleRetirementAdvanceIfNeeded()
    }

    private func scheduleRetirementAdvanceIfNeeded() {
        guard let retirement = pendingRetirement,
              scheduledRetirementToken != retirement.token else {
            return
        }
        scheduledRetirementToken = retirement.token
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduledRetirementToken = nil
            self.advanceRetirement(token: retirement.token)
        }
    }

    private func advanceRetirement(token: UUID) {
        guard let retirement = pendingRetirement,
              retirement.token == token else {
            return
        }

        switch appearanceState {
        case .appearing, .disappearing:
            return
        case .visible:
            if !retirement.window.isHidden {
                retirement.window.isHidden = true
                scheduleRetirementAdvanceIfNeeded()
                return
            }
            // Some secondary-window hides do not start a controller disappearance transaction.
            // Reaching this branch on a later main turn proves that appearance completed before
            // the hide and UIKit kept the controller stable while the window became hidden.
            appearanceState = .detached
            completeRetirement(token: token)
        case .detached:
            guard retirement.window.isHidden else {
                // A visible UIWindow whose root has not reached viewDidAppear is still entering
                // UIKit's appearance transaction. viewDidAppear will continue retirement on the
                // following main-queue turn.
                return
            }
            completeRetirement(token: token)
        }
    }

    private func completeRetirement(token: UUID) {
        guard let retirement = pendingRetirement,
              retirement.token == token else {
            return
        }
        pendingRetirement = nil
        rootView = PairingTrustPromptWindowContent(presentation: nil)
        retirement.window.rootViewController = nil
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
