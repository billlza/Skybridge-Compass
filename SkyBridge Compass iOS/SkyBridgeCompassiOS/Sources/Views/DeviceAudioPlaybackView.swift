import SwiftUI
import UniformTypeIdentifiers
import SkyBridgeProtocolCore

@available(iOS 17.0, *)
struct DeviceAudioPlaybackView: View {
    // Resolve file tags through the OS; importedAs is for types declared in the app's Info.plist.
    static let bluetoothFileTypes: [UTType] = [UTType.wav,
        UTType(filenameExtension: "flac", conformingTo: .audio)].compactMap { $0 }
    static let originalFileTypes: [UTType] = bluetoothFileTypes + [.mpeg4Audio]
    let target: IOSAudioPlaybackTarget
    @ObservedObject var service: IOSDeviceAudioPlaybackService
    let openChannel: @MainActor () throws -> IOSAudioChannel
    var captureAvailability: IOSSystemAudioCaptureAvailability?
    private var currentCaptureAvailability: IOSSystemAudioCaptureAvailability {
        captureAvailability ?? service.systemCaptureAvailability
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectingFile = false
    @State private var bluetoothFile = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(target.name, systemImage: "hifispeaker")
                    Text(RuntimeLocalization.string("选择音源和传输方式，电脑确认后开始播放。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let operation = service.operation {
                    Section(RuntimeLocalization.string("当前播放")) {
                        if let active = service.target { LabeledContent(RuntimeLocalization.string("设备"), value: active.name) }
                        if let file = service.fileName { Text(file).lineLimit(2) }
                        AudioFilePlaybackStatus(operation: operation)
                        if service.backgroundState != .finished && (operation.phase != .completed || service.backgroundFailure != nil) {
                            Text(RuntimeLocalization.string(fileBackgroundStatus))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let operation = service.captureOperation {
                    Section(RuntimeLocalization.string("当前播放")) {
                        if let active = service.target { LabeledContent(RuntimeLocalization.string("设备"), value: active.name) }
                        AudioCapturePlaybackStatus(operation: operation)
                    }
                }
                if let operation = service.bluetoothOperation {
                    Section(RuntimeLocalization.string("当前播放")) {
                        if let active = service.target { LabeledContent(RuntimeLocalization.string("设备"), value: active.name) }
                        if let file = service.fileName { Text(file).lineLimit(2) }
                        BluetoothFilePlaybackStatus(operation: operation)
                        if service.backgroundState != .finished && (operation.phase != .completed || service.backgroundFailure != nil) {
                            Text(RuntimeLocalization.string(fileBackgroundStatus))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if !service.isPresentationLocked {
                    Section {
                        Button {
                            bluetoothFile = false
                            selectingFile = true
                        } label: { Label(RuntimeLocalization.string("选择音频文件"), systemImage: "music.note") }
                            .disabled(service.isPresentationLocked || !target.sources.contains(.originalFile))
                        if !target.sources.contains(.originalFile) {
                            Text(RuntimeLocalization.string("这台电脑尚未提供原文件播放能力。"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(RuntimeLocalization.string("原文件"))
                    } footer: {
                        Text(RuntimeLocalization.string("支持 WAVE，以及接收端已启用的 FLAC 和 ALAC（M4A）原文件；M4A 目前仅支持 ALAC 编码。文件原样发送，在电脑端无损解码；输出需保持原始采样率、精度和声道。开始后请查看后台播放状态。"))
                    }
                    if target.sources.contains(.bluetoothFile) {
                        Section {
                            Button {
                                bluetoothFile = true; selectingFile = true
                            } label: { Label(RuntimeLocalization.string("通过蓝牙播放文件"), systemImage: "wave.3.right") }
                        } header: {
                            Text(RuntimeLocalization.string("蓝牙"))
                        } footer: {
                            Text(RuntimeLocalization.string("支持 WAVE 和 FLAC。蓝牙会有损压缩并转换音频格式，实际格式会显示在播放状态中。请保持当前设备连接，开始后查看后台播放状态。"))
                        }
                    }
                    Section {
                        Button {
                            do { try service.startSystemCapture(target: target, openChannel: openChannel) }
                            catch IOSAudioCaptureError.unavailable {
                                errorText = RuntimeLocalization.string("当前设备暂时无法使用系统音频采集。可继续使用原文件播放。")
                            }
                            catch { errorText = RuntimeLocalization.string("无法开始系统音频传送。请确认设备仍已连接、账户有效，且系统支持音频采集。") }
                        } label: { Label(RuntimeLocalization.string("传送系统音频"), systemImage: "waveform") }
                            .disabled(service.isPresentationLocked || currentCaptureAvailability != .available || !target.sources.contains(.systemCapture))
                        if !target.sources.contains(.systemCapture) {
                            Text(RuntimeLocalization.string("这台电脑尚未提供系统音频接收能力。"))
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if currentCaptureAvailability == .requiresNewerSystem {
                            Text(RuntimeLocalization.string("系统音频采集需要支持此功能的 iOS 27 或更新版本设备。"))
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if currentCaptureAvailability == .systemUnavailable {
                            Text(RuntimeLocalization.string("当前设备暂时无法使用系统音频采集。可继续使用原文件播放。"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(RuntimeLocalization.string("保留系统实际交付的采样，不代表音乐文件的原始格式。部分应用或受保护内容可能无法采集。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    } header: {
                        Text(RuntimeLocalization.string("系统音频"))
                    } footer: {
                        Text(RuntimeLocalization.string("请求 48 kHz 双声道，实际格式在采集后显示。电脑准备好前的声音不会发送。系统采集期间可切换应用，仅传送音频。"))
                    }
                }
                if service.isRunning || service.cleanupPending {
                    Section {
                        if service.captureOperation?.phase == .streaming {
                            Button(RuntimeLocalization.string("结束采集并完成播放")) { service.finishCapture() }
                        }
                        if service.isRunning {
                            Button(RuntimeLocalization.string(service.captureOperation == nil ? "停止播放" : "立即停止"), role: .destructive) { service.stop() }
                        }
                        if service.cleanupPending {
                            Text(RuntimeLocalization.string("资源尚未确认关闭，暂时不能开始新的播放。"))
                                .font(.footnote).foregroundStyle(.secondary)
                            Button(RuntimeLocalization.string("重试关闭")) {
                                Task {
                                    do { try await service.retryCleanup() }
                                    catch { errorText = RuntimeLocalization.string("关闭尚未完成，请稍后重试。") }
                                }
                            }
                            .disabled(service.isClosing)
                        }
                    }
                }
            }
            .navigationTitle(RuntimeLocalization.string("在电脑上播放音频"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(RuntimeLocalization.string("关闭")) { dismiss() }
                        .disabled(service.isPresentationLocked)
                }
            }
            .fileImporter(isPresented: $selectingFile, allowedContentTypes: bluetoothFile ? Self.bluetoothFileTypes : Self.originalFileTypes, allowsMultipleSelection: false) { result in
                do {
                    let urls = try result.get()
                    guard urls.count == 1, let url = urls.first else { throw IOSPreparedAudioFileError.invalidSource }
                    if bluetoothFile { try service.startBluetoothFile(url: url, target: target, openChannel: openChannel) }
                    else { try service.start(url: url, target: target, openChannel: openChannel) }
                } catch { errorText = RuntimeLocalization.string("无法开始播放。请确认设备仍已连接、账户有效，并选择当前播放方式支持的音频文件。") }
            }
            .alert(RuntimeLocalization.string("音频播放"), isPresented: Binding(
                get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                    Button(RuntimeLocalization.string("好的")) { errorText = nil }
                } message: { Text(errorText ?? "") }
            .interactiveDismissDisabled(service.isPresentationLocked)
            .onChange(of: scenePhase) { _, phase in if phase == .background { service.didEnterBackground() } }
            // App switching passes through inactive before background. It must
            // not be mistaken for an explicit foreground dismissal.
            .onDisappear { service.presentationDidDisappear(isBackground: scenePhase != .active) }
        }
    }

    private var fileBackgroundStatus: String {
        if service.backgroundFailure as? IOSAudioBackgroundError == .expired {
            return service.isRunning ? "系统已结束后台播放，正在停止。" : "系统已结束后台播放，请重新开始。"
        }
        if service.backgroundFailure != nil, service.backgroundFailure as? IOSAudioBackgroundError != .cancelled {
            return service.isRunning ? "后台播放未能继续，正在结束任务。" : "后台播放未能完成，请重新开始。"
        }
        switch service.backgroundState {
        case .foregroundOnly: return "当前播放需保持 SkyBridge 在前台。"
        case .requesting: return "正在申请后台播放，请稍候。"
        case .active: return "后台播放已就绪，可以切换应用；系统取消任务时会停止播放。"
        case .stopping: return "正在结束后台播放任务。"
        case .finished: return "后台播放任务已结束。"
        case .failed: return "后台播放任务已结束，请查看播放结果。"
        }
    }
}

@available(iOS 17.0, *)
private struct BluetoothFilePlaybackStatus: View {
    @ObservedObject var operation: IOSOpusFileSendSession
    var body: some View {
        Text(RuntimeLocalization.string(status))
        if operation.phase != .completed, operation.phase != .failed, operation.phase != .stopping {
            AudioAuthorizationStatus(expiry: operation.authorizationExpiresAt, state: operation.authorizationRenewalState)
        }
        LabeledContent(RuntimeLocalization.string("传输方式"), value: RuntimeLocalization.string("蓝牙"))
        if let plan = operation.plan {
            LabeledContent(RuntimeLocalization.string("原文件格式"), value: pcmFormatDescription(plan.originalFormat)).font(.footnote)
            LabeledContent(RuntimeLocalization.string("传送格式"), value: "Opus · 48 kHz · \(plan.opus.bitrate / 1_000) kbps · \(plan.opus.channels) ch").font(.footnote)
        }
        if operation.sentBytes > 0 {
            Text(RuntimeLocalization.string("已发送数据") + ": " + ByteCountFormatter.string(fromByteCount: Int64(clamping: operation.sentBytes), countStyle: .file))
                .font(.footnote).foregroundStyle(.secondary)
        }
        if operation.receipt != nil {
            Text(RuntimeLocalization.string("电脑已确认压缩音频接收和播放完成。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var status: String {
        switch operation.phase {
        case .idle: return "等待选择音频"
        case .authorizing: return "正在验证账户设备授权"
        case .inspecting: return "正在检查原文件"
        case .awaitingRoute: return "等待电脑确认播放"
        case .connectingBluetooth: return "正在连接电脑蓝牙"
        case .awaitingAcceptance: return "等待电脑准备接收音频"
        case .streaming: return "正在通过蓝牙传送音频"
        case .awaitingContent: return "等待电脑确认音频校验"
        case .awaitingPlayback: return "等待电脑确认播放完成"
        case .stopping: return "正在停止并关闭资源"
        case .completed: return "电脑已确认播放完成"
        case .failed:
            switch operation.failure?.reason {
            case .userStopped: return "播放已停止"
            case .receiverDeclined: return "电脑未同意本次播放"
            case .accountRevoked, .permissionRevoked: return "账户或播放授权已失效"
            case .sessionReplaced: return "连接已变化，请重新开始"
            case .unsupportedOutput, .outputLost: return "电脑输出中断"
            case .timedOut: return "等待超时，播放已停止"
            case .contentMismatch: return "音频校验未通过"
            case .unsupportedSource: return "音频文件格式暂不支持"
            default: return "播放未完成"
            }
        }
    }
}

@available(iOS 17.0, *)
private struct AudioFilePlaybackStatus: View {
    @ObservedObject var operation: IOSOriginalFileSendSession

    var body: some View {
        Text(RuntimeLocalization.string(status))
        if operation.phase != .completed, operation.phase != .failed, operation.phase != .stopping {
            AudioAuthorizationStatus(expiry: operation.authorizationExpiresAt, state: operation.authorizationRenewalState)
        }
        if let route = operation.fileRoute {
            LabeledContent(RuntimeLocalization.string("传输方式"), value: RuntimeLocalization.string(
                route == .usbReturn ? "USB" : "局域网"))
                .font(.footnote)
        }
        if let format = operation.sourceFormat {
            LabeledContent(RuntimeLocalization.string("原文件格式"), value: pcmFormatDescription(format))
                .font(.footnote)
        }
        if operation.phase == .transferringFile, operation.totalBytes > 0 {
            ProgressView(value: Double(operation.transferredBytes), total: Double(operation.totalBytes))
        }
        if operation.phase == .awaitingPlayback, let frames = operation.outputSourceFrames,
           let total = operation.workProgress.sourceFrames, total > 0 {
            ProgressView(RuntimeLocalization.string("电脑播放进度"), value: Double(frames), total: Double(total))
        }
        if operation.receipt != nil {
            Text(RuntimeLocalization.string("电脑已确认原文件接收和播放完成；此回执不等同于独立的数字音频输出测量。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch operation.phase {
        case .idle: return "等待选择音频"
        case .authorizing: return "正在验证账户设备授权"
        case .inspecting: return "正在检查原文件"
        case .awaitingAcceptance: return "等待电脑确认播放"
        case .transferringFile: return "正在发送原文件"
        case .awaitingOutput: return "等待电脑准备原格式输出"
        case .awaitingPlayback: return "等待电脑确认播放完成"
        case .stopping: return "正在停止并关闭资源"
        case .completed: return "电脑已确认播放完成"
        case .failed:
            switch operation.failure?.reason {
            case .userStopped: return "播放已停止"
            case .receiverDeclined: return "电脑未同意本次播放"
            case .accountRevoked, .permissionRevoked: return "账户或播放授权已失效"
            case .unsupportedOutput: return "电脑输出设备不支持原格式"
            case .outputLost: return "电脑输出中断"
            case .sessionReplaced: return "连接已变化，请重新开始"
            case .timedOut: return "等待超时，播放已停止"
            case .contentMismatch: return "文件校验未通过"
            case .unsupportedSource: return "音频文件格式暂不支持"
            default: return "播放未完成"
            }
        }
    }
}

@available(iOS 17.0, *)
private struct AudioCapturePlaybackStatus: View {
    @ObservedObject var operation: IOSCaptureSendSession

    var body: some View {
        Text(RuntimeLocalization.string(status))
        if operation.phase != .completed, operation.phase != .failed, operation.phase != .stopping {
            AudioAuthorizationStatus(expiry: operation.authorizationExpiresAt, state: operation.authorizationRenewalState)
        }
        if let format = operation.format {
            LabeledContent(RuntimeLocalization.string("系统交付格式"), value: pcmFormatDescription(format))
                .font(.footnote)
        }
        if operation.sentBytes > 0 {
            Text(RuntimeLocalization.string("已发送数据") + ": " +
                 ByteCountFormatter.string(fromByteCount: Int64(clamping: operation.sentBytes), countStyle: .file))
                .font(.footnote).foregroundStyle(.secondary)
        }
        if operation.receipt != nil {
            Text(RuntimeLocalization.string("电脑已确认采集音频接收和播放完成；此回执不等同于独立的数字音频输出测量。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch operation.phase {
        case .idle: return "等待开始系统音频采集"
        case .authorizing: return "正在验证账户设备授权"
        case .selecting: return "等待系统采集授权"
        case .probing: return "正在识别系统交付格式"
        case .awaitingAcceptance: return "等待电脑准备接收音频"
        case .streaming: return "正在传送系统音频"
        case .draining: return "正在结束采集并发送剩余音频"
        case .awaitingContent: return "等待电脑确认音频校验"
        case .awaitingPlayback: return "等待电脑确认播放完成"
        case .stopping: return "正在停止并关闭资源"
        case .completed: return "电脑已确认播放完成"
        case .failed:
            switch operation.failure?.reason {
            case .userStopped: return "播放已停止"
            case .receiverDeclined: return "电脑未同意本次播放"
            case .accountRevoked, .permissionRevoked: return "账户或播放授权已失效"
            case .unsupportedOutput: return "电脑输出设备不支持原格式"
            case .outputLost: return "电脑输出中断"
            case .sessionReplaced: return "连接已变化，请重新开始"
            case .timedOut: return "等待超时，播放已停止"
            case .contentMismatch: return "音频校验未通过"
            case .queueOverflow: return "音频缓冲已满，传送已停止"
            case .unsupportedSource: return "系统交付格式暂不支持"
            case .sourceFailed: return "系统音频采集已中断"
            default: return "播放未完成"
            }
        }
    }
}

@available(iOS 17.0, *)
private struct AudioAuthorizationStatus: View {
    let expiry: Date?
    let state: AudioMembershipRenewalState?

    var body: some View {
        if let expiry {
            LabeledContent(RuntimeLocalization.string("audio.authorization.expiry")) {
                Text(expiry, format: .dateTime.hour().minute().second())
            }
            .font(.footnote)
        }
        if let state {
            Text(RuntimeLocalization.string(key(for: state)))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func key(for state: AudioMembershipRenewalState) -> String {
        switch state {
        case .waiting: return "audio.authorization.renewal.waiting"
        case .checking: return "audio.authorization.renewal.checking"
        case .retryPending: return "audio.authorization.renewal.retry_pending"
        case .unavailable: return "audio.authorization.renewal.unavailable"
        case .failed: return "audio.authorization.renewal.failed"
        }
    }
}

private func pcmFormatDescription(_ format: AudioStreamingPCMFormat) -> String {
    "\(format.sampleRate) Hz · \(format.channels) ch · \(format.declaredValidBits)/\(format.encoding.containerBits) bit · \(format.encoding.isFloatingPoint ? "Float" : "PCM")"
}
