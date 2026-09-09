#if os(macOS)
import AppKit
import Combine
@_spi(RemoteControlSecurityNoticeUI) import SkyBridgeCore
import SwiftUI

public enum RemoteControlSecurityNoticeLocalizationContract {
    public static let requiredKeys: [String] = [
        "remoteControl.securityNotice.account",
        "remoteControl.securityNotice.activeTitle",
        "remoteControl.securityNotice.appName",
        "remoteControl.securityNotice.approve",
        "remoteControl.securityNotice.approveView",
        "remoteControl.securityNotice.inputController",
        "remoteControl.securityNotice.observer",
        "remoteControl.securityNotice.transferInput",
        "remoteControl.securityNotice.close",
        "remoteControl.securityNotice.collapse",
        "remoteControl.securityNotice.device",
        "remoteControl.securityNotice.disconnect",
        "remoteControl.securityNotice.expand",
        "remoteControl.securityNotice.nebulaID",
        "remoteControl.securityNotice.pendingTitle",
        "remoteControl.securityNotice.pqc",
        "remoteControl.securityNotice.reject",
        "remoteControl.securityNotice.remoteIP",
        "remoteControl.securityNotice.subtitle",
        "remoteControl.securityNotice.transport",
        "remoteControl.securityNotice.transport.p2p",
        "remoteControl.securityNotice.transport.webrtc",
        "remoteControl.securityNotice.valueUnavailable",
        "remoteControl.securityNotice.windowTitle",
    ]
}

@available(macOS 14.0, *)
@MainActor
public final class RemoteControlSecurityNoticePanelController: NSObject, ObservableObject {
    public static let shared = RemoteControlSecurityNoticePanelController(center: .shared)

    private let center: RemoteControlSecurityNoticeCenter
    private var cancellable: AnyCancellable?
    private var panel: NSPanel?
    private var lastRenderedNotice: RemoteControlSecurityNotice?
    private var presentedNotices: [UUID: RemoteControlSecurityNotice] = [:]
    private var collapsedNoticeIDs = Set<UUID>()
    private var lifecycleGeneration: UInt64 = 0

    init(center: RemoteControlSecurityNoticeCenter) {
        self.center = center
        super.init()
    }

    public func start() {
        guard cancellable == nil else { return }
        lifecycleGeneration &+= 1
        let subscribedGeneration = lifecycleGeneration
        cancellable = center.$currentNotice
            .sink { [weak self] notice in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.cancellable != nil,
                          self.lifecycleGeneration == subscribedGeneration,
                          self.center.currentNotice == notice else {
                        return
                    }
                    self.render(notice)
                }
            }
    }

    /// Stops presentation and fails closed any notice currently owned by this presenter.
    /// A generation check prevents already-enqueued publisher deliveries from reopening
    /// the panel after shutdown.
    public func stop() {
        guard cancellable != nil else { return }
        lifecycleGeneration &+= 1
        cancellable?.cancel()
        cancellable = nil
        center.closeAllNoticesFailClosed()
        hidePanel(clearPanel: true)
    }

    private func render(_ notice: RemoteControlSecurityNotice?) {
        guard let notice else {
            hidePanel(clearPanel: false)
            return
        }
        if lastRenderedNotice?.id != notice.id {
            collapsedNoticeIDs.removeAll(keepingCapacity: true)
        }

        let content = makeContent(for: notice)
        if let panel {
            panel.contentView = NSHostingView(rootView: content)
            position(
                panel: panel,
                notice: notice,
                isCollapsed: collapsedNoticeIDs.contains(notice.id)
            )
            lastRenderedNotice = notice
            panel.orderFrontRegardless()
            recordPresentedEvidence(
                panel: panel,
                notice: notice,
                isCollapsed: collapsedNoticeIDs.contains(notice.id)
            )
            return
        }

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.title = LocalizationManager.shared.localizedString("remoteControl.securityNotice.windowTitle")
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovable = false
        newPanel.isMovableByWindowBackground = false
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.level = .statusBar
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.contentView = NSHostingView(rootView: content)
        newPanel.isReleasedWhenClosed = false
        position(
            panel: newPanel,
            notice: notice,
            isCollapsed: collapsedNoticeIDs.contains(notice.id)
        )
        panel = newPanel
        lastRenderedNotice = notice
        newPanel.orderFrontRegardless()
        recordPresentedEvidence(
            panel: newPanel,
            notice: notice,
            isCollapsed: collapsedNoticeIDs.contains(notice.id)
        )
    }

    private func hidePanel(clearPanel: Bool) {
        lastRenderedNotice = nil
        panel?.orderOut(nil)
        if let panel, !panel.isVisible {
            finishPresentations(retaining: [])
        }
        guard clearPanel else { return }
        panel?.contentView = nil
        panel = nil
        collapsedNoticeIDs.removeAll(keepingCapacity: false)
    }

    /// A shared panel can outlive one of its notices. End only presentations
    /// removed from its actual content; selecting another live notice is not terminal.
    private func finishPresentations(retaining noticeIDs: Set<UUID>) {
        let removed = presentedNotices.values.filter { !noticeIDs.contains($0.id) }
        for notice in removed {
            presentedNotices.removeValue(forKey: notice.id)
            collapsedNoticeIDs.remove(notice.id)
            center.recordPanelHiddenEvidence(descriptor: notice.descriptor, phase: notice.phase)
        }
    }

    private func makeContent(for notice: RemoteControlSecurityNotice) -> RemoteControlSecurityNoticePanelView {
        RemoteControlSecurityNoticePanelView(
            center: center,
            notice: notice,
            isInitiallyCollapsed: collapsedNoticeIDs.contains(notice.id)
        ) { [weak self] isCollapsed in
            self?.setCollapsed(isCollapsed, for: notice)
        }
    }

    private func setCollapsed(
        _ isCollapsed: Bool,
        for notice: RemoteControlSecurityNotice
    ) {
        guard lastRenderedNotice?.id == notice.id,
              center.currentNotice == notice,
              let panel else {
            return
        }
        if isCollapsed {
            collapsedNoticeIDs.insert(notice.id)
        } else {
            collapsedNoticeIDs.remove(notice.id)
        }
        position(panel: panel, notice: notice, isCollapsed: isCollapsed)
    }

    private func position(
        panel: NSPanel,
        notice: RemoteControlSecurityNotice,
        isCollapsed: Bool
    ) {
        let phase = notice.phase
        let visibleFrame = currentScreen()?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let width = isCollapsed
            ? min(max(visibleFrame.width - 48, 360), 520)
            : min(max(visibleFrame.width - 48, 360), 760)
        let height: CGFloat = {
            if isCollapsed { return 82 }
            let sessionsHeight: CGFloat = center.notices.count > 1 ? 42 : 0
            let errorHeight: CGFloat = center.controlHandoffError == nil ? 0 : 36
            return (phase == .awaitingApproval ? 218 : 214) + sessionsHeight + errorHeight
        }()
        let origin = CGPoint(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.maxY - height - 18
        )
        panel.setFrame(
            CGRect(origin: origin, size: CGSize(width: width, height: height)),
            display: true
        )
    }

    /// Records presentation only after `orderFrontRegardless()` has run on the
    /// real product panel. Layout alone is not proof that AppKit presented it.
    private func recordPresentedEvidence(
        panel: NSPanel,
        notice: RemoteControlSecurityNotice,
        isCollapsed: Bool
    ) {
        guard panel.isVisible else { return }
        finishPresentations(retaining: Set(center.notices.map(\.id)))
        presentedNotices[notice.id] = notice
        let visibleFrame = currentScreen()?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panelFrame = panel.frame
        let centerDelta = abs(panelFrame.midX - visibleFrame.midX)
        let topOffset = visibleFrame.maxY - panelFrame.maxY
        let topCentered = centerDelta <= 1.0 && topOffset >= 0 && topOffset <= 32
        center.recordPanelPresentedEvidence(
            descriptor: notice.descriptor,
            phase: notice.phase,
            frame: statusRect(panelFrame),
            visibleFrame: statusRect(visibleFrame),
            windowLevel: "statusBar",
            collectionBehavior: ["canJoinAllSpaces", "fullScreenAuxiliary", "transient"],
            buttons: buttons(for: notice.phase, isCollapsed: isCollapsed),
            topCentered: topCentered
        )
    }

    private func currentScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func buttons(
        for phase: RemoteControlSecurityNoticePhase,
        isCollapsed: Bool
    ) -> [String] {
        if isCollapsed {
            return ["expand", "close"]
        }
        switch phase {
        case .awaitingApproval:
            return ["collapse", "close", "reject", "approve"]
        case .active:
            return ["collapse", "close", "disconnect"]
        }
    }

    private func statusRect(_ rect: CGRect) -> String {
        String(
            format: "%.1f,%.1f,%.1f,%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(rect.origin.x),
            Double(rect.origin.y),
            Double(rect.size.width),
            Double(rect.size.height)
        )
    }

#if DEBUG || SKYBRIDGE_TESTING
    var isStartedForTesting: Bool {
        cancellable != nil
    }

    var hasPanelForTesting: Bool {
        panel != nil
    }

    var renderedNoticeIDForTesting: UUID? { lastRenderedNotice?.id }
    var contentViewForTesting: NSView? { panel?.contentView }
#endif
}

@available(macOS 14.0, *)
private struct RemoteControlSecurityNoticePanelView: View {
    @ObservedObject private var center: RemoteControlSecurityNoticeCenter
    let notice: RemoteControlSecurityNotice
    let onCollapsedChange: (Bool) -> Void

    @State private var isCollapsed: Bool

    init(
        center: RemoteControlSecurityNoticeCenter,
        notice: RemoteControlSecurityNotice,
        isInitiallyCollapsed: Bool,
        onCollapsedChange: @escaping (Bool) -> Void
    ) {
        self.center = center
        self.notice = notice
        self.onCollapsedChange = onCollapsedChange
        _isCollapsed = State(initialValue: isInitiallyCollapsed)
    }

    private var descriptor: RemoteControlSecurityDescriptor {
        notice.descriptor
    }

    private var isPending: Bool {
        notice.phase == .awaitingApproval
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCollapsed ? 0 : 14) {
            HStack(spacing: 12) {
                Image(systemName: isPending ? "hand.raised.fill" : "display.and.arrow.down")
                    .font(.system(size: 24, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isPending ? Color.orange : Color.green)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(titleText)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(isCollapsed ? 1 : 2)
                    Text(subtitleText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(isCollapsed ? 1 : 2)
                }

                Spacer(minLength: 12)

                Button {
                    isCollapsed.toggle()
                    onCollapsedChange(isCollapsed)
                } label: {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("remoteControlSecurityNoticeCollapseButton")
                .help(localized(isCollapsed ? "remoteControl.securityNotice.expand" : "remoteControl.securityNotice.collapse"))

                Button {
                    center.closeNoticeFailClosed(id: notice.id)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("remoteControlSecurityNoticeCloseButton")
                .help(localized("remoteControl.securityNotice.close"))
            }

            if !isCollapsed {
                if center.notices.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(center.notices) { session in
                            Button {
                                center.selectNotice(id: session.id)
                            } label: {
                                Label(
                                    session.descriptor.remoteDeviceName ?? RemoteControlSecurityNoticePresenter.deviceIdentity(session.descriptor),
                                    systemImage: session.phase == .awaitingApproval ? "clock"
                                        : center.inputControllerNoticeID == session.id ? "keyboard" : "eye"
                                )
                                .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .tint(session.id == notice.id ? .accentColor : .secondary)
                        }
                    }
                }
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 160), spacing: 12),
                        GridItem(.flexible(minimum: 160), spacing: 12)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    field(localized("remoteControl.securityNotice.remoteIP"), descriptor.remoteIPAddress)
                    field(localized("remoteControl.securityNotice.transport"), transportText)
                    field(
                        localized("remoteControl.securityNotice.account"),
                        masked(descriptor.remoteAccountDisplayName)
                    )
                    field(
                        localized("remoteControl.securityNotice.nebulaID"),
                        masked(descriptor.remoteNebulaId)
                    )
                    field(localized("remoteControl.securityNotice.device"), RemoteControlSecurityNoticePresenter.deviceIdentity(descriptor))
                    field(localized("remoteControl.securityNotice.pqc"), descriptor.cryptoSuite)
                }

                HStack(spacing: 10) {
                    Spacer()
                    if isPending {
                        Button {
                            center.rejectNotice(id: notice.id)
                        } label: {
                            Label(localized("remoteControl.securityNotice.reject"), systemImage: "xmark.circle")
                        }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("remoteControlSecurityNoticeRejectButton")

                        Button {
                            center.approveNoticeFromUserInteraction(id: notice.id)
                        } label: {
                            Label(localized(center.inputControllerNoticeID == nil && !center.isTransferringControl
                                ? "remoteControl.securityNotice.approve"
                                : "remoteControl.securityNotice.approveView"), systemImage: "checkmark.shield")
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("remoteControlSecurityNoticeApproveButton")
                    } else {
                        if center.controlAccess(for: notice.id) != nil {
                            Text(localized(center.inputControllerNoticeID == notice.id
                                ? "remoteControl.securityNotice.inputController"
                                : "remoteControl.securityNotice.observer"))
                                .font(.caption)
                            if center.inputControllerNoticeID != notice.id {
                                Button {
                                    Task {
                                        await center.transferInputControl(to: notice.id)
                                        if let error = center.controlHandoffError {
                                            let alert = NSAlert()
                                            alert.messageText = localized("remoteControl.securityNotice.transferInput")
                                            alert.informativeText = error
                                            alert.alertStyle = .critical
                                            alert.runModal()
                                        }
                                    }
                                } label: {
                                    Label(localized("remoteControl.securityNotice.transferInput"), systemImage: "keyboard")
                                }
                                .disabled(!center.canTransferInputControl(to: notice.id))
                                .accessibilityIdentifier("remoteControlSecurityNoticeTransferInputButton")
                            }
                        }
                        Button(role: .destructive) {
                            center.disconnectNotice(id: notice.id)
                        } label: {
                            Label(localized("remoteControl.securityNotice.disconnect"), systemImage: "power")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("remoteControlSecurityNoticeDisconnectButton")
                    }
                }
                if let error = center.controlHandoffError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .accessibilityIdentifier("remoteControlSecurityNoticePanel")
    }

    private var titleText: String {
        let key = isPending
            ? "remoteControl.securityNotice.pendingTitle"
            : "remoteControl.securityNotice.activeTitle"
        return String(
            format: localized(key),
            RemoteControlSecurityNoticePresenter.appName()
        )
    }

    private var subtitleText: String {
        String(
            format: localized("remoteControl.securityNotice.subtitle"),
            transportText
        )
    }

    private var transportText: String {
        RemoteControlSecurityNoticePresenter.transportName(descriptor.transportKind)
    }

    private func field(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(valueText(value))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func masked(_ value: String?) -> String {
        RemoteControlSecurityNoticePresenter.maskedIdentity(value)
    }

    private func valueText(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return RemoteControlSecurityNoticePresenter.unavailableValue()
        }
        return value
    }

    private func localized(_ key: String) -> String {
        LocalizationManager.shared.localizedString(key)
    }
}
#endif
