import SkyBridgeProtocolCore
import SwiftUI

@available(iOS 17.0, *)
struct DeviceMessagingView: View {
    let device: DiscoveredDevice

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DeviceMessageStore.shared
    @ObservedObject private var offlineQueue = OfflineMessageQueue.shared
    @State private var draft = ""
    @State private var conversationFingerprint: String?
    @State private var errorMessage: String?
    @State private var isSending = false

    private var messages: [DeviceMessageStore.Message] {
        guard let conversationFingerprint else { return [] }
        return store.messages(conversationFingerprint: conversationFingerprint)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                offlineQueueNotice
                messageList
                Divider()
                composer
            }
            .navigationTitle(device.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(RuntimeLocalization.string("关闭")) {
                        dismiss()
                    }
                }
            }
            .task {
                resolveConversation()
            }
            .alert(
                RuntimeLocalization.string("消息发送失败"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { presenting in
                        if !presenting { errorMessage = nil }
                    }
                )
            ) {
                Button(RuntimeLocalization.string("好的")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var offlineQueueNotice: some View {
        if offlineQueue.isPersistenceBlocked {
            Label(
                RuntimeLocalization.string("离线消息队列不可用，自动投递已暂停。"),
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(.horizontal)
            .padding(.vertical, 8)
        } else if offlineQueue.lastPersistenceError
                    == OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue {
            Label(
                RuntimeLocalization.string("离线消息存储空间不足，自动投递会在队列状态变化后重试。"),
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var messageList: some View {
        if store.isPersistenceBlocked {
            ContentUnavailableView(
                RuntimeLocalization.string("消息存储不可用"),
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(
                    RuntimeLocalization.string("本地消息数据无法安全读取。为避免覆盖损坏数据，消息功能已停止写入。")
                )
            )
        } else if let errorMessage, conversationFingerprint == nil {
            ContentUnavailableView(
                RuntimeLocalization.string("无法打开消息"),
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if messages.isEmpty {
            ContentUnavailableView(
                RuntimeLocalization.string("暂无消息"),
                systemImage: "bubble.left.and.bubble.right",
                description: Text(RuntimeLocalization.string("对方离线时发送的消息会在上线后自动投递。"))
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(RuntimeLocalization.string("输入消息"), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .disabled(conversationFingerprint == nil || isSending)

            Button {
                sendDraft()
            } label: {
                if isSending {
                    ProgressView()
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
        }
        .padding()
    }

    private func messageRow(_ message: DeviceMessageStore.Message) -> some View {
        HStack {
            if message.direction == .outgoing { Spacer(minLength: 48) }

            VStack(alignment: message.direction == .outgoing ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.primary)
                    .background(
                        message.direction == .outgoing
                            ? Color.accentColor.opacity(0.22)
                            : Color.secondary.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                Text(statusText(for: message))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if message.direction == .incoming { Spacer(minLength: 48) }
        }
    }

    private var canSend: Bool {
        !isSending
            && !store.isPersistenceBlocked
            && !offlineQueue.isPersistenceBlocked
            && conversationFingerprint != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resolveConversation() {
        guard !store.isPersistenceBlocked else {
            conversationFingerprint = nil
            errorMessage = RuntimeLocalization.string("本地消息存储不可用，已阻止继续写入。")
            return
        }
        do {
            conversationFingerprint = try DeviceMessagingService.shared.conversationFingerprint(for: device)
            errorMessage = nil
        } catch {
            conversationFingerprint = nil
            errorMessage = RuntimeLocalization.string("该设备缺少唯一受信任身份，无法打开消息会话。")
            SkyBridgeLogger.shared.error(
                "Device message conversation unavailable: \(DeviceMessagingService.logSafeErrorSummary(error))"
            )
        }
    }

    private func sendDraft() {
        let submittedDraft = draft
        let text = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        Task { @MainActor in
            do {
                try await DeviceMessagingService.shared.send(text: text, to: device)
                if draft == submittedDraft {
                    draft = ""
                }
                isSending = false
            } catch {
                isSending = false
                errorMessage = RuntimeLocalization.string("消息未发送，请检查设备连接或受信任身份。")
                SkyBridgeLogger.shared.error(
                    "Device message send failed: \(DeviceMessagingService.logSafeErrorSummary(error))"
                )
            }
        }
    }

    private func statusText(for message: DeviceMessageStore.Message) -> String {
        let time = message.timestamp.formatted(date: .omitted, time: .shortened)
        guard message.direction == .outgoing else { return time }
        switch message.deliveryState {
        case .pending:
            return RuntimeLocalization.string("等待对方上线")
        case .sent:
            return "\(RuntimeLocalization.string("已发送")) · \(time)"
        case .delivered:
            return "\(RuntimeLocalization.string("已送达")) · \(time)"
        case .failed:
            return "\(RuntimeLocalization.string("发送失败")) · \(time)"
        }
    }
}
