import SwiftUI
import SkyBridgeCore

/// VNC 查看器窗口视图
struct VNCViewerView: View {
    @EnvironmentObject private var vncLaunch: VNCLaunchContext
    @State private var session: VNCSession?
    @State private var error: String?

    var body: some View {
        ZStack {
            if let session {
                RemoteDisplayView(
                    textureFeed: session.textureFeed,
                    onMouseEvent: { point, eventType, button in
                        let x = Int(point.x), y = Int(point.y)
                        let evt: String
                        switch eventType {
                        case .leftMouseDown: evt = "leftMouseDown"
                        case .leftMouseUp: evt = "leftMouseUp"
                        case .rightMouseDown: evt = "rightMouseDown"
                        case .rightMouseUp: evt = "rightMouseUp"
                        case .mouseMoved, .leftMouseDragged, .rightMouseDragged: evt = "mouseMoved"
                        default: evt = "mouseMoved"
                        }
                        Task { await session.sendPointerEvent(x: x, y: y, eventType: evt, button: button) }
                    },
                    onKeyboardEvent: { keyCode, isPressed in
                        Task { await session.sendKeyEvent(down: isPressed, keyCode: UInt32(keyCode)) }
                    },
                    onScrollEvent: { dx, dy in
                        let evt = dy > 0 ? "scrollUp" : "scrollDown"
                        Task { await session.sendPointerEvent(x: 0, y: 0, eventType: evt, button: 0) }
                    }
                )
                    .background(Color.black)
                    .overlay(alignment: .top) { toolbar }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.icloud")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("等待连接参数")
                        .foregroundColor(.secondary)
                }
            }
        }
        .task { await startIfNeeded() }
        .alert("连接失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("确定") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                session?.stop(); session = nil
            } label: { Label("断开", systemImage: "xmark.circle") }
            Spacer()
            if let host = vncLaunch.host, let port = vncLaunch.port {
                Text("VNC: \(host):\(port)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
    }

    private func startIfNeeded() async {
        guard session == nil, let host = vncLaunch.host, let port = vncLaunch.port else { return }
        let s = VNCSession(host: host, port: port)
        session = s
        do { try await s.start() } catch { await MainActor.run { self.error = error.localizedDescription } }
    }
}