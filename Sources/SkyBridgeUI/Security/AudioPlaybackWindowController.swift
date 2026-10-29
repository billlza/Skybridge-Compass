import AppKit
import Combine
import SkyBridgeCore
import SkyBridgeProtocolCore
import SwiftUI

/// Owns both the receiver and its explicit, per-stream approval surface. Closing
/// this window rejects a pending request or stops its current playback.
@MainActor
public final class AudioPlaybackWindowController: NSObject, NSWindowDelegate {
    private var receiver: AudioPlaybackReceiverService?
    private var subscriptions: Set<AnyCancellable> = []
    private var window: NSWindow?
    private var dismissedOwner: UUID?
    private var closingForShutdown = false
    private var stopping = false
    private var startupFailed = false
    private let presentation = AudioPlaybackPanelPresentation()
    private let activate: @MainActor () -> Void
    private let enableBluetoothCompatibleAudio: Bool

    public override convenience init() {
        self.init(enableBluetoothCompatibleAudio: false)
    }

    public convenience init(enableBluetoothCompatibleAudio: Bool) {
        self.init(activate: { NSRunningApplication.current.activate(options: [.activateAllWindows]) },
            enableBluetoothCompatibleAudio: enableBluetoothCompatibleAudio)
    }

    init(activate: @escaping @MainActor () -> Void, enableBluetoothCompatibleAudio: Bool = false) {
        self.activate = activate
        self.enableBluetoothCompatibleAudio = enableBluetoothCompatibleAudio
        super.init()
    }

    public func start() {
        guard receiver == nil, !stopping else { return }
        do {
            let service = try AudioPlaybackReceiverService(enableBluetoothCompatibleAudio: enableBluetoothCompatibleAudio)
            startPresentation(receiver: service)
            // The presenter is ready before an incoming pairing can advertise capture.
            try service.start()
            startupFailed = false
        } catch {
            subscriptions.removeAll()
            receiver = nil
            startupFailed = true
            SkyBridgeLogger.ui.error("Audio receiver startup failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }
    }

    // Kept separate so presenter tests use a local service without starting the
    // real account/discovery singleton or opening an output device.
    func startPresentation(receiver: AudioPlaybackReceiverService) {
        precondition(self.receiver == nil)
        self.receiver = receiver
        receiver.approvals.$pendingRequest.sink { [weak self] published in
            Task { @MainActor [weak self] in
                guard let self, self.receiver?.approvals.pendingRequest?.id == published?.id else { return }
                if let published {
                    self.presentation.request = published
                    self.showAutomatically(owner: published.ownerID)
                }
            }
        }.store(in: &subscriptions)
        receiver.$phase.sink { [weak self] phase in
            Task { @MainActor [weak self] in
                guard let self, let service = self.receiver, service.phase == phase,
                      phase == .authorizing, let owner = service.currentPlaybackID else { return }
                self.presentation.request = nil
                self.showAutomatically(owner: owner)
            }
        }.store(in: &subscriptions)
    }

    public func show() {
        guard !stopping else { return }
        dismissedOwner = nil
        if receiver == nil, !startupFailed { start() }
        if window == nil {
            let content: AnyView
            if let receiver {
                content = AnyView(AudioPlaybackPanel(receiver: receiver, approvals: receiver.approvals,
                    presentation: presentation, retryCleanup: { [weak self] in self?.retryCleanupAndResume() }))
            } else {
                content = AnyView(VStack(alignment: .leading, spacing: 16) {
                    Label("音频接收暂不可用", systemImage: "exclamationmark.triangle")
                        .font(.title2)
                    Text("接收服务未能启动。请重新打开应用后重试。")
                        .foregroundStyle(.secondary)
                }.padding(24).frame(width: 460))
            }
            let created = NSWindow(contentViewController: NSHostingController(rootView: content))
            created.title = "SkyBridge · 音频接收"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.moveToActiveSpace]
            created.delegate = self
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        activate()
    }

    private func showAutomatically(owner: UUID) {
        guard !stopping, dismissedOwner != owner else { return }
        presentation.ownerID = owner
        show()
    }

    @discardableResult
    public func stop() async -> Bool {
        guard !stopping else { return false }
        stopping = true
        receiver?.approvals.dismiss()
        if let receiver, !(await receiver.stop()) {
            presentation.serviceUnavailable = true
            stopping = false
            show()
            return false
        }
        subscriptions.removeAll()
        closingForShutdown = true
        window?.close()
        window = nil
        closingForShutdown = false
        receiver = nil
        presentation.request = nil
        presentation.ownerID = nil
        stopping = false
        return true
    }

    /// Failed playback-resource cleanup cannot disappear into an unconditional app exit.
    /// The unresolved owner stays retained until cleanup succeeds or the user
    /// explicitly elects to let process termination release it.
    public func prepareForApplicationTermination() async -> Bool {
        if await stop() { return true }
        let alert = NSAlert()
        alert.messageText = "播放资源尚未完全释放"
        alert.informativeText = "部分清理尚未完成。可以取消退出并重试；仍然退出可能遗留临时音频副本、蓝牙会话或当前声音设置。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消退出")
        alert.addButton(withTitle: "重试清理并退出")
        alert.addButton(withTitle: "仍然退出")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            guard let receiver, await receiver.retryOutputCleanup() else { return false }
            return await stop()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func retryCleanupAndResume() {
        guard !stopping, !presentation.isRetrying, let receiver else { return }
        presentation.isRetrying = true
        Task { @MainActor [weak self] in
            let released = await receiver.retryOutputCleanup()
            guard let self, self.receiver === receiver else { return }
            self.presentation.isRetrying = false
            guard released, !self.stopping else { return }
            do {
                try receiver.start()
                self.presentation.serviceUnavailable = false
            } catch {
                self.presentation.serviceUnavailable = true
                SkyBridgeLogger.ui.error("Audio receiver restart failed: \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        window = nil
        guard !closingForShutdown, let receiver else { return }
        dismissedOwner = presentation.ownerID
        if let request = receiver.approvals.pendingRequest, request.ownerID == presentation.ownerID {
            receiver.approvals.resolve(request, allowOnce: false)
        }
        if let owner = presentation.ownerID { receiver.stopPlayback(ifOwnedBy: owner) }
    }

#if DEBUG || SKYBRIDGE_TESTING
    var isWindowVisibleForTesting: Bool { window?.isVisible == true }
    var displayedRequestForTesting: AudioPlaybackApprovalRequest? { presentation.request }
    func closeWindowForTesting() { window?.performClose(nil) }
#endif
}

@MainActor
private final class AudioPlaybackPanelPresentation: ObservableObject {
    @Published var request: AudioPlaybackApprovalRequest?
    @Published var ownerID: UUID?
    @Published var serviceUnavailable = false
    @Published var isRetrying = false
}

@MainActor
private struct AudioPlaybackPanel: View {
    @ObservedObject var receiver: AudioPlaybackReceiverService
    @ObservedObject var approvals: AudioPlaybackApprovalService
    @ObservedObject var presentation: AudioPlaybackPanelPresentation
    let retryCleanup: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(approvals.pendingRequest == nil ? phaseTitle : "允许在这台 Mac 播放？",
                  systemImage: "hifispeaker.fill")
                .font(.title2.weight(.semibold))

            if let sender = approvals.pendingRequest?.sender.deviceID ?? receiver.senderDeviceID {
                LabeledContent("已认证设备") {
                    Text(sender).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                }
            }
            if let transport = receiver.controlTransport {
                LabeledContent("本次设备连接", value: transport == .usb ? "USB 直连 · 已加密" : "网络连接 · 已加密")
            }
            if let output = receiver.selectedOutput {
                LabeledContent("本次输出", value: output.name)
            }
            if let request = presentation.request, case let .capturedPCM(format) = request.source {
                LabeledContent("来源", value: "手机应用声音 · 系统捕获")
                LabeledContent("捕获格式", value: formatDescription(format))
                LabeledContent("PCM 数据率", value: "\(UInt64(format.sampleRate) * UInt64(format.bytesPerFrame) * 8) bit/s")
                Text("保留系统交付的 PCM 样本。此格式不代表音乐文件的原始编码或精度。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let request = presentation.request, case let .originalFile(_, length, _) = request.source {
                LabeledContent("来源", value: "手机原始音乐文件")
                LabeledContent("文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(length), countStyle: .file))
                Text("仅接收用于本次播放的临时副本，核验文件内容后检查输出格式；结束后清理副本。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let source = displayedSource, case let .opus(kind, format) = source {
                LabeledContent("来源", value: kind == .originalFile ? "手机所选音乐文件" : "手机应用声音 · 系统捕获")
                LabeledContent("音频模式", value: "蓝牙兼容 · 有损压缩")
                LabeledContent("蓝牙编码", value: "Opus · \(format.bitrate / 1000) kbps")
                LabeledContent("解码输入", value: "48,000 Hz · \(format.channels) 声道 · 16-bit 整数")
                Text("采用有损压缩传输，并由 Mac 系统混音播放。解码输入格式不代表原音乐文件的精度。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let format = receiver.sourceFormat {
                LabeledContent(LocalizationManager.shared.localizedString("audio.output.source_format"), value: formatDescription(format))
            }
            if let expires = receiver.authorizationExpiresAt {
                LabeledContent("本地授权有效至", value: expires.formatted(date: .omitted, time: .standard))
                if receiver.isReceiving, let state = receiver.authorizationRenewalState {
                    Text(renewalDescription(state)).font(.footnote).foregroundStyle(.secondary)
                }
                Text("有效期内可使用已有授权；离线时无法获知服务器上的新撤销。退出账户或本次授权失效会停止播放。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Divider()
            if let pending = approvals.pendingRequest {
                Text(isBluetooth ? "仅允许这一次蓝牙播放。音频将经过有损压缩，并通过所选输出设备的系统混音播放。"
                    : "仅允许这一次播放。将尝试以相同格式独占所选输出；不支持时会明确停止。其他应用可能暂时无法使用该输出。")
                    .font(.callout)
                HStack {
                    Button("拒绝", role: .cancel) { approvals.resolve(pending, allowOnce: false) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("允许本次播放") { approvals.resolve(pending, allowOnce: true) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Text(statusDetail).font(.callout).foregroundStyle(.secondary)
                if receiver.requiresOutputRecovery {
                    Label("播放资源仍待清理，新的播放已暂停。", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                    Button(presentation.isRetrying ? "正在重试清理…" : "重试清理", action: retryCleanup)
                        .disabled(presentation.isRetrying)
                } else if receiver.outputCleanupPreservedExternalChanges {
                    Text("输出已释放；保留了其他应用更改的声音设置，没有强制恢复原设置。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !receiver.cleanupFailures.isEmpty {
                    Text("播放资源已释放，但本次停止曾出现错误；本次播放仍记为未完成。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if presentation.serviceUnavailable, !receiver.requiresOutputRecovery {
                    Text("接收服务暂不可用，请重新打开应用后重试。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let displayedOwner = receiver.currentPlaybackID {
                    HStack {
                        ProgressView().controlSize(.small)
                        Spacer()
                        Button("停止播放", role: .destructive) { receiver.stopPlayback(ifOwnedBy: displayedOwner) }
                    }
                }
            }
        }
        .padding(24).frame(width: 520)
    }

    private var phaseTitle: String {
        switch receiver.phase {
        case .idle: "在 Mac 上接收音频"
        case .authorizing: "正在核验设备授权"
        case .awaitingApproval: "等待本次播放确认"
        case .receivingFile: "正在接收并校验音乐文件"
        case .validatingFile: "正在校验无损音频"
        case .connectingBluetooth: "正在建立蓝牙音频连接"
        case .preparing: "正在准备音频输出"
        case .buffering: "正在缓冲"
        case .playing: "正在播放音频"
        case .finishing: "正在播放剩余声音"
        case .completed: "本次播放已结束"
        case .failed: receiver.failureReason == .userStopped ? "播放已停止" : "播放未能继续"
        }
    }

    private var statusDetail: String {
        switch receiver.phase {
        case .idle: "在已连接的手机设备页选择这台 Mac，再选择“在此设备播放”。可接收系统允许捕获的应用声音或所选 WAVE、FLAC、ALAC（M4A）原文件；输出必须支持来源格式。"
        case .authorizing: "核验双方账户设备授权；已有授权只能使用到原截止时间。"
        case .awaitingApproval: "每次新播放均需要在这台 Mac 上确认。"
        case .receivingFile: "正在接收本次批准的文件。完整性校验通过后，才会尝试打开严格音频输出。"
        case .validatingFile: "正在完整检查音乐数据。校验通过后，将按原始采样率、精度和声道准备播放。"
        case .connectingBluetooth: "正在与已认证设备建立加密蓝牙音频通道。"
        case .preparing: isBluetooth ? "正在准备蓝牙兼容音频输出。" : "正在检查输出是否支持相同的采样率、声道与 PCM 表示。"
        case .buffering: isBluetooth ? "兼容输出已就绪，正在缓冲压缩音频。" : "输出已按相同格式打开，正在等待足够的样本。"
        case .playing: isBluetooth ? "通过蓝牙接收压缩音频，并由系统混音播放。关闭此窗口也会停止播放。"
            : "按接收格式播放，未做重采样或有损压缩。关闭此窗口也会停止播放。"
        case .finishing: "音源已结束输入，正在确认最后的样本进度与完成回执。"
        case .completed:
            receiver.completedSourceFrames == 0 ? "未收到可播放的样本。" : "内容校验和设备报告的播放进度已完成。"
        case .failed: failureDescription
        }
    }

    private var failureDescription: String {
        if !isBluetooth, let issue = receiver.outputIssue,
           receiver.failureReason == .unsupportedOutput || receiver.failureReason == .outputLost {
            return LocalizationManager.shared.localizedString("audio." + issue.rawValue)
        }
        return switch receiver.failureReason {
        case .userStopped: "本次播放已停止。可从手机重新发起。"
        case .permissionRevoked: "系统采集权限已结束，请在手机重新授权。"
        case .sourceFailed: "手机未能继续提供音频，请检查音源和采集权限。"
        case .unsupportedOutput: isBluetooth ? "所选输出无法用于本次蓝牙播放，请检查声音设备后重试。"
            : "所选输出不支持本次格式或独占条件，请更换合适的输出设备后重试。"
        case .queueOverflow: "连接或处理速度无法维持当前音频，请检查链路后重试。"
        case .outputLost: "音频输出不可用或进度无法验证，请检查声音设备后重试。"
        case .protocolViolation, .contentMismatch: "接收数据未通过校验，本次播放已终止。"
        case .accountRevoked: "账户设备授权不可用或已失效，请联网核验双方账户和设备状态。"
        case .sessionReplaced: isBluetooth ? "蓝牙或设备连接已改变，请检查两端蓝牙状态并重新连接。" : "设备连接已改变，请重新连接后发起播放。"
        case .timedOut: "等待超时，请检查连接和手机状态后重试。"
        case .unsupportedSource: "此来源暂不支持播放。"
        case .receiverDeclined: "本次播放未获允许，或已有另一段播放正在进行。"
        case nil: "本次播放未完成。"
        }
    }

    private func renewalDescription(_ state: AudioMembershipRenewalState) -> String {
        let key: String
        switch state {
        case .waiting: key = "audio.authorization.renewal.waiting"
        case .checking: key = "audio.authorization.renewal.checking"
        case .retryPending: key = "audio.authorization.renewal.retry_pending"
        case .unavailable: key = "audio.authorization.renewal.unavailable"
        case .failed: key = "audio.authorization.renewal.failed"
        }
        return LocalizationManager.shared.localizedString(key)
    }

    private func formatDescription(_ format: AudioStreamingPCMFormat) -> String {
        let representation = format.encoding.isFloatingPoint ? "浮点" : "整数"
        return "\(format.sampleRate) Hz · \(format.channels) 声道 · \(format.encoding.containerBits)-bit \(representation)（声明 \(format.declaredValidBits) bit）"
    }

    private var displayedSource: AudioPlaybackSource? { presentation.request?.source ?? receiver.playbackSource }
    private var isBluetooth: Bool {
        if case .opus? = displayedSource { return true }
        return false
    }
}
