import SwiftUI
import SkyBridgeCore

/// 设备间文本消息会话视图（compose + 历史）。在线即时投递、离线自动排队、上线后投递并回填状态。
@available(macOS 14.0, *)
struct DeviceMessagingView: View {
    let fingerprint: String
    let deviceId: String
    let deviceName: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DeviceMessageStore.shared
    @State private var draft = ""

    private var messages: [DeviceMessageStore.Message] {
        store.messages(fingerprint: fingerprint)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.tint)
                Text(deviceName).font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { msg in
                            messageRow(msg)
                                .frame(maxWidth: .infinity, alignment: msg.direction == .outgoing ? .trailing : .leading)
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if messages.isEmpty {
                Text("还没有消息。对方离线时发送的消息会在其上线后自动投递。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("输入消息…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { sendDraft() }
                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await DeviceMessagingService.shared.send(text: text, toDeviceId: deviceId, fingerprint: fingerprint) }
    }

    @ViewBuilder
    private func messageRow(_ msg: DeviceMessageStore.Message) -> some View {
        VStack(alignment: msg.direction == .outgoing ? .trailing : .leading, spacing: 2) {
            Text(msg.text)
                .textSelection(.enabled)
                .padding(8)
                .background(
                    msg.direction == .outgoing ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            Text(stateLabel(msg))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func stateLabel(_ msg: DeviceMessageStore.Message) -> String {
        let time = msg.timestamp.formatted(date: .omitted, time: .shortened)
        if msg.direction == .incoming { return time }
        switch msg.deliveryState {
        case .pending: return "等待对方上线…"
        case .sent: return "已发送 · \(time)"
        case .delivered: return "已送达 · \(time)"
        }
    }
}
