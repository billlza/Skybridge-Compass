import Foundation
import BackgroundTasks
import os

@available(iOS 26.0, *)
@MainActor
final class IOSContinuedAudioTaskScheduler: IOSContinuedAudioScheduler {
    private var registered = false

    static func makeExecution() throws -> IOSAudioBackgroundExecution {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            throw IOSAudioBackgroundError.invalidIdentifier
        }
        return try IOSAudioBackgroundExecution(identifier: bundleID + ".audio-file." + UUID().uuidString,
            title: RuntimeLocalization.string("在电脑上播放音频"), scheduler: IOSContinuedAudioTaskScheduler())
    }

    func submit(identifier: String, title: String,
                launch: @escaping @MainActor (Result<any IOSContinuedAudioTask, any Error>) -> Void) async throws {
        guard !registered else { throw IOSAudioBackgroundError.alreadyStarted }
        registered = true
        // Continued tasks expressly permit registration after application launch.
        // Each job has a unique suffix: a late callback can never attach to a new
        // playback. The registered closure holds only the caller's weak job handle.
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            // This is the explicitly requested dispatch queue, not an inferred
            // actor hop. The runtime assertion preserves the SDK queue contract.
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    launch(.failure(IOSAudioBackgroundError.unexpectedTask)); return
                }
                guard continued.progress.completedUnitCount == 0 else {
                    continued.setTaskCompleted(success: false)
                    launch(.failure(IOSAudioBackgroundError.invalidProgress)); return
                }
                launch(.success(NativeTask(continued)))
            }
        }
        guard accepted else { throw IOSAudioBackgroundError.registrationRejected }
        let subtitle = RuntimeLocalization.string("正在准备音频")
        // iOS 27's submission completion may take an arbitrary delay and its SDK
        // forbids submission on a performance-critical/main thread. Construct and
        // retain the request inside this owned worker; do not send SDK objects
        // across actors or treat Swift cancellation as a completed system submit.
        try await Task.detached(priority: .userInitiated) {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            request.requiredResources = []
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
        }.value
    }

    func cancel(identifier: String) { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }

    private final class NativeTask: IOSContinuedAudioTask {
        let task: BGContinuedProcessingTask
        private var completed = false
        private let expired = OSAllocatedUnfairLock(initialState: false)
        private var expiration: (@MainActor () -> Void)?
        var identifier: String { task.identifier }
        var isExpired: Bool { expired.withLock { $0 } }
        init(_ task: BGContinuedProcessingTask) {
            self.task = task
            let expired = self.expired
            task.expirationHandler = { [weak self] in
                // Record revocation on the callback's actual queue before actor
                // scheduling. Completion cannot outrun an already observed expiry.
                expired.withLock { $0 = true }
                Task { @MainActor [weak self] in self?.expiration?() }
            }
        }
        func attachProgress(_ progress: Progress) {
            task.progress.totalUnitCount = 1
            task.progress.addChild(progress, withPendingUnitCount: 1)
        }
        func updateStatus(_ status: IOSAudioTaskStatus) {
            let text: String
            switch status {
            case .originalFile(let phase):
                switch phase {
                case .idle: text = "正在准备音频"
                case .authorizing: text = "正在验证账户设备授权"
                case .inspecting: text = "正在检查原文件"
                case .awaitingAcceptance: text = "等待电脑确认播放"
                case .transferringFile: text = "正在发送原文件"
                case .awaitingOutput: text = "等待电脑准备原格式输出"
                case .awaitingPlayback: text = "等待电脑确认播放完成"
                case .stopping: text = "正在停止并关闭资源"
                case .completed: text = "电脑已确认播放完成"
                case .failed: text = "播放未完成"
                }
            case .bluetoothFile(let phase):
                switch phase {
                case .idle: text = "正在准备音频"
                case .authorizing: text = "正在验证账户设备授权"
                case .inspecting: text = "正在检查原文件"
                case .awaitingRoute: text = "等待电脑确认播放"
                case .connectingBluetooth: text = "正在连接电脑蓝牙"
                case .awaitingAcceptance: text = "等待电脑准备接收音频"
                case .streaming: text = "正在通过蓝牙传送音频"
                case .awaitingContent: text = "等待电脑确认音频校验"
                case .awaitingPlayback: text = "等待电脑确认播放完成"
                case .stopping: text = "正在停止并关闭资源"
                case .completed: text = "电脑已确认播放完成"
                case .failed: text = "播放未完成"
                }
            }
            task.updateTitle(task.title, subtitle: RuntimeLocalization.string(text))
        }
        func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
            expiration = handler
            if isExpired { handler() }
        }
        @discardableResult func complete(success: Bool) -> Bool {
            guard !completed else { return false }
            completed = true
            task.expirationHandler = nil
            expiration = nil
            let accepted = success && !isExpired
            task.setTaskCompleted(success: accepted)
            return accepted
        }
    }
}
