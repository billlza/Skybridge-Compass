import SwiftUI
import SkyBridgeCore
import SkyBridgeProtocolCore

/// Presents one engine's frame feed. Background engines never share this display's input binding.
struct NearFieldControlCanvas: View {
    @ObservedObject var manager: RemoteControlManager
    @ObservedObject private var feed: RemoteTextureFeed
    let inputEnabled: Bool
    let onMouse: (RemoteMouseEvent) -> Void
    let onKeyboard: (RemoteKeyboardEvent) -> Void

    init(
        manager: RemoteControlManager,
        inputEnabled: Bool,
        onMouse: @escaping (RemoteMouseEvent) -> Void,
        onKeyboard: @escaping (RemoteKeyboardEvent) -> Void
    ) {
        self.manager = manager
        _feed = ObservedObject(wrappedValue: manager.textureFeed)
        self.inputEnabled = inputEnabled
        self.onMouse = onMouse
        self.onKeyboard = onKeyboard
    }

    var body: some View {
        let inputAccess = manager.viewerInputAccess
        GeometryReader { geometry in
            ZStack {
                Color.black
                RemoteDisplayView(
                    textureFeed: feed,
                    mapsPointerToRemoteFrame: true,
                    onMouseEvent: acceptsInput ? { point, type, _ in
                        sendMouse(point, type: type, access: inputAccess)
                    } : nil,
                    onKeyboardEvent: acceptsInput ? { code, pressed in
                        guard manager.viewerInputAccess == inputAccess else { return }
                        onKeyboard(RemoteKeyboardEvent(
                            type: pressed ? .keyDown : .keyUp,
                            keyCode: Int(code), timestamp: Date().timeIntervalSince1970
                        ))
                    } : nil,
                    onScrollEvent: acceptsInput ? { _, deltaY in sendScroll(deltaY, access: inputAccess) } : nil
                )
                .id(inputAccess.access?.lease)
                .aspectRatio(frameAspectRatio, contentMode: .fit)
                .frame(width: geometry.size.width, height: geometry.size.height)
                if feed.frame == nil {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("安全会话已建立，等待远端画面…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if inputAccess.hasAcknowledgement, !inputAccess.canSendInput {
                    Label(
                        LocalizationManager.shared.localizedString("remoteControl.securityNotice.observer"),
                        systemImage: "eye"
                    )
                        .font(.callout)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 12) {
                    Text("\(manager.estimatedFPS) FPS")
                    Text(String(format: "%.1f Mbps", manager.bandwidthMbps))
                    Text(String(format: "%.0f ms", manager.latencyMs))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
        }
    }

    private var acceptsInput: Bool {
        inputEnabled && manager.viewerInputAccess.canSendInput && feed.frame != nil
    }

    private var frameAspectRatio: CGFloat {
        guard let frame = feed.frame else { return 16 / 10 }
        return CGFloat(frame.texture.width) / CGFloat(frame.texture.height)
    }

    private func sendMouse(_ point: CGPoint, type: NSEvent.EventType, access: RemoteControlAccessTracker) {
        guard manager.viewerInputAccess == access else { return }
        let settings = RemoteDesktopSettingsManager.shared.settings.interactionSettings
        let mapped: MouseEventType
        switch type {
        case .leftMouseDown: mapped = .leftMouseDown
        case .leftMouseUp: mapped = .leftMouseUp
        case .rightMouseDown:
            guard settings.enableContextMenu else { return }
            mapped = .rightMouseDown
        case .rightMouseUp: mapped = .rightMouseUp
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged: mapped = .mouseMoved
        default: return
        }
        onMouse(RemoteMouseEvent(type: mapped, x: point.x, y: point.y, timestamp: Date().timeIntervalSince1970))
    }

    private func sendScroll(_ deltaY: CGFloat, access: RemoteControlAccessTracker) {
        guard manager.viewerInputAccess == access else { return }
        let settings = RemoteDesktopSettingsManager.shared.settings.interactionSettings
        guard settings.enableTrackpadGestures, deltaY.isFinite, deltaY != 0 else { return }
        let requestedCount = Double(abs(deltaY)) * settings.scrollSensitivity / 8
        guard requestedCount.isFinite else { return }
        let count = Int(min(8, max(1, requestedCount.rounded(.up))))
        for _ in 0..<count {
            onMouse(RemoteMouseEvent(
                type: deltaY > 0 ? .scrollUp : .scrollDown,
                x: 0, y: 0, timestamp: Date().timeIntervalSince1970
            ))
        }
    }
}
