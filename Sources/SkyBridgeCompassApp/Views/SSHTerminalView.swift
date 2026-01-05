import SwiftUI
import AppKit
import SkyBridgeCore

/// SSH 交互式终端窗口视图
struct SSHTerminalView: View {
    @EnvironmentObject private var sshLaunch: SSHLaunchContext
    @State private var session: SSHSession?
    @State private var inputLine: String = ""
    @State private var connectError: String?
 // 终端滚动与缓冲控制
    @State private var autoScrollToBottom: Bool = true // 是否在新输出时自动滚动到底部
    @State private var bufferedOutput: String = ""     // 环形缓冲区的当前文本视图
    private let bufferLineLimit: Int = 2000             // 缓冲区行数上限，避免内存无限增长

    var body: some View {
        VStack(spacing: 0) {
 // 工具栏
            HStack(spacing: 12) {
                Button {
                    session?.disconnect(); session = nil
                } label: { Label("断开", systemImage: "xmark.circle") }
                Spacer()
                if let host = sshLaunch.host, let port = sshLaunch.port, let username = sshLaunch.username {
                    Text("SSH: \(username)@\(host):\(port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("等待连接参数")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(.ultraThinMaterial)

 // 输出区（支持选择复制、滚动缓冲与自动滚动）
            ScrollViewReader { proxy in
                ScrollView {
                    Text(formatANSI(bufferedOutput))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .font(.system(.body, design: .monospaced))
                        .background(Color.black.opacity(0.85))
                        .textSelection(.enabled) // 启用文本选择，支持复制
                    Color.clear.frame(height: 1).id("terminal-bottom-anchor")
                }
                .onChange(of: session?.outputText ?? "") { _, newValue in
 // 当输出变化时更新缓冲并根据设置滚动到底部
                    bufferedOutput = trimToBufferLimit(newValue, limit: bufferLineLimit)
                    if autoScrollToBottom {
                        proxy.scrollTo("terminal-bottom-anchor", anchor: .bottom)
                    }
                }
            }

 // 输入区
            HStack {
 // 使用 App 内封装的 NSTextFieldRepresentable 保持更好键盘体验
                NSTextFieldRepresentable.textField(
                    text: $inputLine,
                    placeholder: "输入命令...",
                    onRawKeyInput: { seq in
 // 将方向键等控制序列直接发送到远端 Shell（不追加换行）
                        session?.send(seq)
                    }
                )
                    .onSubmit {
                        guard !inputLine.isEmpty else { return }
                        session?.sendLine(inputLine)
                        inputLine = ""
                    }
 /* 原 TextField 作为备用
                TextField("输入命令...", text: $inputLine, onCommit: {
                    guard !inputLine.isEmpty else { return }
                    session?.sendLine(inputLine)
                    inputLine = ""
                })
                .textFieldStyle(.roundedBorder) */
                Button("发送") {
                    guard !inputLine.isEmpty else { return }
                    session?.sendLine(inputLine)
                    inputLine = ""
                }
 // 自动滚动开关与复制/清空辅助按钮
                Toggle("自动滚动", isOn: $autoScrollToBottom)
                    .toggleStyle(.switch)
                    .help("新输出到达时自动滚动到底部")
                Button {
 // 复制缓冲区全部文本到粘贴板
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(bufferedOutput, forType: .string)
                } label: { Label("复制全部", systemImage: "doc.on.doc") }
                Button {
 // 清空缓冲区（不影响会话内部输出累积，仅清理视图缓冲）
                    bufferedOutput = ""
                } label: { Label("清空缓冲", systemImage: "trash") }
            }
            .padding(8)
        }
        .task { await startIfNeeded() }
        .alert("连接失败", isPresented: Binding(get: { connectError != nil }, set: { if !$0 { connectError = nil } })) {
            Button("确定") { connectError = nil }
        } message: { Text(connectError ?? "") }
    }

    private func startIfNeeded() async {
        guard session == nil,
              let host = sshLaunch.host,
              let port = sshLaunch.port,
              let username = sshLaunch.username,
              let password = sshLaunch.password else { return }
        let s = SSHSession(host: host, port: port, username: username)
        session = s
        do { try await s.connect(password: password) } catch { await MainActor.run { self.connectError = error.localizedDescription } }
 // 初始化缓冲区为当前输出的剪裁结果
        bufferedOutput = trimToBufferLimit(session?.outputText ?? "", limit: bufferLineLimit)
    }

 /// ANSI 颜色与样式格式化（简化版，支持常见SGR）
    private func formatANSI(_ text: String) -> AttributedString {
        var result = AttributedString("")
        var currentAttrs = AttributeContainer()
        var isBold = false
        let parts = text.split(separator: "\u{001B}", omittingEmptySubsequences: false)
        for part in parts {
            if part.isEmpty { continue }
            let str = String(part)
            if str.first == "[" {
 // 解析 SGR 序列，如 "[31m" 或 "[0m"
                if let mIdx = str.firstIndex(of: "m") {
                    let codeStr = String(str[str.index(after: str.startIndex)..<mIdx])
                    let remaining = String(str[str.index(after: mIdx)..<str.endIndex])
 // 更新样式
                    for code in codeStr.split(separator: ";") {
                        switch code {
                        case "0": currentAttrs = AttributeContainer() // reset
                        case "1": isBold = true
                        case "4": currentAttrs.underlineStyle = .single
                        case "30": currentAttrs.foregroundColor = .black
                        case "31": currentAttrs.foregroundColor = .red
                        case "32": currentAttrs.foregroundColor = .green
                        case "33": currentAttrs.foregroundColor = .yellow
                        case "34": currentAttrs.foregroundColor = .blue
                        case "35": currentAttrs.foregroundColor = .purple
                        case "36": currentAttrs.foregroundColor = .cyan
                        case "37": currentAttrs.foregroundColor = .white
                        default: break
                        }
                    }
                    var segment = AttributedString(remaining)
                    segment.mergeAttributes(currentAttrs)
                    if isBold {
 // 使用粗体字体作为近似效果
                        segment.font = .system(.body, design: .monospaced).bold()
                    }
                    result += segment
                } else {
                    result += AttributedString(str)
                }
            } else {
                result += AttributedString(str)
            }
        }
        return result
    }

 /// 将原始输出按行截断到指定上限（环形缓冲思路）
 /// - Parameters:
 /// - text: 原始完整输出文本
 /// - limit: 保留的最大行数
 /// - Returns: 截断后的文本
    private func trimToBufferLimit(_ text: String, limit: Int) -> String {
 // 为保证性能，仅按换行分割并保留最后 N 行
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return text }
        let start = max(0, lines.count - limit)
        return lines[start...].joined(separator: "\n")
    }
}