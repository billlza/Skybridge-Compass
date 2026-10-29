import AppKit
import Combine
import Foundation
import SkyBridgeCore
import SwiftUI

/// SSH 交互式终端窗口视图。
///
/// 输出由单个 `NSTextStorage` 增量维护。SwiftUI 不接收完整 transcript，也不会在每个网络
/// 批次上重新 split、解析 ANSI 或构造整份 `AttributedString`。
struct SSHTerminalView: View {
    let launchRequestID: UUID

    @EnvironmentObject private var sshLaunch: SSHLaunchContext
    @State private var session: SSHSession?
    @State private var inputLine = ""
    @State private var connectError: String?
    @State private var terminalOperationError: String?
    @StateObject private var terminalActions = SSHTerminalSurfaceActions()
    @AppStorage("ssh.autoScrollToBottom") private var autoScrollToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    session?.disconnect()
                    session = nil
                } label: {
                    Label("断开", systemImage: "xmark.circle")
                }
                Spacer()
                if let presentation = connectionPresentation {
                    Text("SSH: \(presentation.username)@\(presentation.host):\(presentation.port)")
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

            Group {
                if let session {
                    SSHTerminalTranscriptView(
                        session: session,
                        autoScrollToBottom: autoScrollToBottom,
                        actions: terminalActions
                    )
                } else {
                    Color.black.opacity(0.85)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                NSTextFieldRepresentable.textField(
                    text: $inputLine,
                    placeholder: "输入命令...",
                    onRawKeyInput: { sequence in
                        session?.send(sequence)
                    }
                )
                .onSubmit { sendInputLine() }

                Button("发送") { sendInputLine() }

                Toggle("自动滚动", isOn: $autoScrollToBottom)
                    .toggleStyle(.switch)
                    .help("新输出到达时自动滚动到底部")

                Button {
                    do {
                        try terminalActions.copyAll()
                    } catch {
                        terminalOperationError = error.localizedDescription
                    }
                } label: {
                    Label("复制全部", systemImage: "doc.on.doc")
                }

                Button {
                    terminalActions.clear()
                } label: {
                    Label("清空缓冲", systemImage: "trash")
                }
            }
            .padding(8)
        }
        .task(id: launchRequestID) { await startIfNeeded() }
        .onDisappear {
            session?.disconnect()
            session = nil
            sshLaunch.clearPendingCredentials(requestID: launchRequestID)
        }
        .alert(
            "连接失败",
            isPresented: Binding(
                get: { connectError != nil },
                set: { if !$0 { connectError = nil } }
            )
        ) {
            Button("确定") { connectError = nil }
        } message: {
            Text(connectError ?? "")
        }
        .alert(
            "终端操作失败",
            isPresented: Binding(
                get: { terminalOperationError != nil },
                set: { if !$0 { terminalOperationError = nil } }
            )
        ) {
            Button("确定") { terminalOperationError = nil }
        } message: {
            Text(terminalOperationError ?? "")
        }
    }

    private func sendInputLine() {
        guard !inputLine.isEmpty else { return }
        session?.sendLine(inputLine)
        inputLine = ""
    }

    private func startIfNeeded() async {
        guard session == nil else { return }
        guard let request = sshLaunch.consumeConnectionRequest(requestID: launchRequestID) else {
            connectError = SSHLaunchContextError.requestExpired.localizedDescription
            return
        }
        let newSession = SSHSession(
            host: request.host,
            port: request.port,
            username: request.username
        )
        session = newSession
        do {
            try await newSession.connect(password: request.password)
        } catch is CancellationError {
            newSession.disconnect()
        } catch {
            connectError = error.localizedDescription
        }
    }

    private var connectionPresentation: SSHLaunchPresentation? {
        if let session {
            return SSHLaunchPresentation(
                host: session.host,
                port: session.port,
                username: session.username
            )
        }
        return sshLaunch.presentation(for: launchRequestID)
    }
}

@MainActor
private protocol SSHTerminalSurfaceCommandTarget: AnyObject {
    func copyAll() throws
    func clear()
}

@MainActor
private final class SSHTerminalSurfaceActions: ObservableObject {
    private weak var target: (any SSHTerminalSurfaceCommandTarget)?

    func attach(_ target: any SSHTerminalSurfaceCommandTarget) {
        self.target = target
    }

    func detach(_ target: any SSHTerminalSurfaceCommandTarget) {
        guard self.target === target else { return }
        self.target = nil
    }

    func copyAll() throws {
        guard let target else { throw SSHTerminalSurfaceError.unavailable }
        try target.copyAll()
    }

    func clear() {
        target?.clear()
    }
}

private enum SSHTerminalSurfaceError: LocalizedError {
    case unavailable
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "终端视图当前不可用。"
        case .pasteboardWriteFailed:
            "无法将终端内容写入系统剪贴板。"
        }
    }
}

@MainActor
private struct SSHTerminalTranscriptView: NSViewRepresentable {
    let session: SSHSession
    let autoScrollToBottom: Bool
    let actions: SSHTerminalSurfaceActions

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.black.withAlphaComponent(0.85)

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        context.coordinator.attach(
            textView: textView,
            session: session,
            autoScrollToBottom: autoScrollToBottom
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.attach(
            textView: textView,
            session: session,
            autoScrollToBottom: autoScrollToBottom
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, SSHTerminalSurfaceCommandTarget {
        private static let truncationMarker = "[earlier terminal history truncated]\n"

        private let actions: SSHTerminalSurfaceActions
        private weak var textView: NSTextView?
        private weak var observedSession: SSHSession?
        private var outputObservation: AnyCancellable?
        private var historyIndex = SSHTerminalHistoryIndex()
        private var lastSequence: UInt64 = 0
        private var markerUTF16Length = 0
        private var autoScrollToBottom = true

        init(actions: SSHTerminalSurfaceActions) {
            self.actions = actions
        }

        func attach(
            textView: NSTextView,
            session: SSHSession,
            autoScrollToBottom: Bool
        ) {
            self.textView = textView
            self.autoScrollToBottom = autoScrollToBottom
            actions.attach(self)
            guard observedSession !== session else { return }

            outputObservation?.cancel()
            observedSession = session
            resetForNewSession()

            let replay = session.terminalPresentationReplay
            if replay.didTruncateEarlierOutput {
                installTruncationMarkerIfNeeded()
            }
            for batch in replay.batches {
                consume(batch)
            }
            outputObservation = session.$terminalPresentationBatch
                .compactMap { $0 }
                .sink { [weak self] batch in
                    MainActor.assumeIsolated {
                        self?.consume(batch)
                    }
                }
        }

        func detach() {
            outputObservation?.cancel()
            outputObservation = nil
            observedSession = nil
            textView = nil
            actions.detach(self)
        }

        func copyAll() throws {
            guard let textView else { throw SSHTerminalSurfaceError.unavailable }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(textView.string, forType: .string) else {
                throw SSHTerminalSurfaceError.pasteboardWriteFailed
            }
        }

        func clear() {
            guard let textStorage = textView?.textStorage else { return }
            textStorage.setAttributedString(NSAttributedString())
            historyIndex.reset()
            markerUTF16Length = 0
            // The canonical parser is owned by the session pipeline. Clearing presentation
            // history must not reset its live ANSI/control state. Clear the surface first so a
            // persistent desynchronization marker republished synchronously by the session remains
            // visible instead of being erased by this command.
            observedSession?.clearTerminalOutputHistory()
        }

        private func resetForNewSession() {
            historyIndex.reset()
            lastSequence = 0
            markerUTF16Length = 0
            textView?.textStorage?.setAttributedString(NSAttributedString())
        }

        private func consume(_ batch: SSHTerminalPresentationBatch) {
            guard batch.sequence > lastSequence else { return }
            lastSequence = batch.sequence
            guard !batch.operations.isEmpty,
                  let textStorage = textView?.textStorage else {
                return
            }

            var didTruncate = false
            textStorage.beginEditing()
            for operation in batch.operations {
                switch operation {
                case .append(let run):
                    textStorage.append(
                        NSAttributedString(
                            string: run.text,
                            attributes: attributes(for: run.style)
                        )
                    )
                    let mutation = historyIndex.append(run.text)
                    if mutation.prefixUTF16UnitsToRemove > 0 {
                        textStorage.deleteCharacters(
                            in: NSRange(
                                location: markerUTF16Length,
                                length: mutation.prefixUTF16UnitsToRemove
                            )
                        )
                    }
                    didTruncate = didTruncate || mutation.didTruncate

                case .erasePreviousCharacter:
                    erasePreviousCharacter(from: textStorage)
                }
            }
            textStorage.endEditing()
            if didTruncate {
                installTruncationMarkerIfNeeded()
            }
            if autoScrollToBottom {
                textView?.scrollToEndOfDocument(nil)
            }
        }

        private func erasePreviousCharacter(from textStorage: NSTextStorage) {
            let mutableString = textStorage.mutableString
            guard mutableString.length > markerUTF16Length else { return }
            let candidateIndex = mutableString.length - 1
            let range = mutableString.rangeOfComposedCharacterSequence(at: candidateIndex)
            guard range.location >= markerUTF16Length else { return }
            let removedText = mutableString.substring(with: range)
            // Backspace never crosses a completed transcript line boundary.
            guard removedText != "\n" else { return }
            textStorage.deleteCharacters(in: range)
            historyIndex.removeSuffix(removedText)
        }

        private func installTruncationMarkerIfNeeded() {
            guard markerUTF16Length == 0, let textStorage = textView?.textStorage else { return }
            let marker = NSAttributedString(
                string: Self.truncationMarker,
                attributes: attributes(
                    for: SSHTerminalTextStyle(
                        foregroundColor: .brightYellow,
                        isBold: false,
                        isUnderlined: false
                    )
                )
            )
            textStorage.insert(marker, at: 0)
            markerUTF16Length = (Self.truncationMarker as NSString).length
        }

        private func attributes(
            for style: SSHTerminalTextStyle
        ) -> [NSAttributedString.Key: Any] {
            let weight: NSFont.Weight = style.isBold ? .bold : .regular
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: weight),
                .foregroundColor: color(for: style.foregroundColor)
            ]
            if style.isUnderlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return attributes
        }

        private func color(for color: SSHTerminalANSIColor?) -> NSColor {
            switch color {
            case .black: .black
            case .red: .systemRed
            case .green: .systemGreen
            case .yellow: .systemYellow
            case .blue: .systemBlue
            case .magenta: .systemPurple
            case .cyan: .systemCyan
            case .white: .white
            case .brightBlack: .darkGray
            case .brightRed: .systemRed
            case .brightGreen: .systemGreen
            case .brightYellow: .systemYellow
            case .brightBlue: .systemBlue
            case .brightMagenta: .systemPurple
            case .brightCyan: .systemCyan
            case .brightWhite, .none: .white
            }
        }
    }
}
