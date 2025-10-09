import SwiftUI

struct RemoteShellView: View {
    @Environment(DashboardViewModel.self) private var viewModel
    @State private var endpointText: String = ""
    @State private var token: String = ""
    @State private var command: String = ""
    @State private var autoScroll: Bool = true

    var body: some View {
        VStack(spacing: 16) {
            connectionSection
            Divider()
            terminalSection
        }
        .padding(24)
        .onAppear {
            if let endpoint = viewModel.remoteShell.endpoint {
                endpointText = endpoint.absoluteString
            }
        }
        .navigationTitle("远程 Shell")
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接设置")
                .font(.headline)
            TextField("WebSocket 地址，例如 wss://example.com/shell", text: $endpointText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
            SecureField("可选鉴权 Token", text: $token)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button(viewModel.remoteShell.isConnected ? "断开" : "连接") {
                    Task {
                        if viewModel.remoteShell.isConnected {
                            await viewModel.disconnectShell()
                        } else if let url = URL(string: endpointText) {
                            await viewModel.connectShell(endpoint: url, token: token.isEmpty ? nil : token)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                if let latency = viewModel.remoteShell.latency {
                    Text("延迟 \(Int(latency * 1000)) ms")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .liquidGlass()
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("终端输出")
                .font(.headline)
            TerminalMessagesView(messages: viewModel.remoteShell.messages, autoScroll: autoScroll)
                .frame(maxHeight: .infinity)
                .background(Color(.black).opacity(0.3), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Toggle("自动滚动", isOn: $autoScroll)
                .toggleStyle(.switch)
            HStack {
                TextField("输入命令…", text: $command, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.system(.body, design: .monospaced))
                Button("发送") {
                    let content = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else { return }
                    Task {
                        await viewModel.sendCommand(content)
                    }
                    command = ""
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.remoteShell.isConnected)
            }
        }
        .liquidGlass()
    }
}

private struct TerminalMessagesView: View {
    let messages: [RemoteShellMessage]
    var autoScroll: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        TerminalBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onChange(of: messages.last?.id) { _, id in
                guard autoScroll, let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

private struct TerminalBubble: View {
    let message: RemoteShellMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.role == .user ? "我" : "系统")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(message.text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(message.role == .user ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
