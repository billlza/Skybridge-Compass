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
    @ObservedObject private var queue = OfflineMessageQueue.shared
    @State private var draft = ""
    @State private var isSending = false
    @State private var operationError: String?

    private var messages: [DeviceMessageStore.Message] {
        switch conversationProjection {
        case .success(let messages):
            return messages
        case .failure:
            return []
        }
    }

    private var conversationProjection: Result<[DeviceMessageStore.Message], Error> {
        Result { try store.messages(fingerprint: fingerprint) }
    }

    private var availabilityIssue: String? {
        if case .failure = conversationProjection {
            return "该会话的认证身份指纹无效，消息功能已停用。"
        }
        if case .blocked = store.persistenceState {
            return "消息历史持久化不可用。数据会保持原样，需使用受控隔离恢复流程；本版本不会自动清空。"
        }
        if case .blocked = queue.configurationPersistenceState {
            return "离线队列配置不可用，请先在离线队列设置中显式恢复。"
        }
        if case .blocked = queue.persistenceState {
            return "离线队列持久化不可用，消息不会被假定为已排队。"
        }
        return nil
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

            if let availabilityIssue {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(availabilityIssue)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
            }

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
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSending
                        || availabilityIssue != nil
                )
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 520)
        .alert(
            "消息发送失败",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("好", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "消息操作失败")
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, availabilityIssue == nil else { return }
        isSending = true
        operationError = nil
        Task { @MainActor in
            defer { isSending = false }
            do {
                try await DeviceMessagingService.shared.send(
                    text: text,
                    toDeviceID: deviceId,
                    fingerprint: fingerprint
                )
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    draft = ""
                }
            } catch {
                operationError = error.localizedDescription
            }
        }
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
        case .failed: return "发送失败 · \(time)"
        }
    }
}
