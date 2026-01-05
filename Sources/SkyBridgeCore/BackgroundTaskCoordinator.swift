import Foundation
import os.log

/// 后台任务协调器 - 使用 macOS 原生的 NSBackgroundActivityScheduler
/// 遵循苹果社区规范，专为 macOS 平台优化
@MainActor
public final class BackgroundTaskCoordinator: Sendable {
    public static let shared = BackgroundTaskCoordinator()

    public typealias WorkHandler = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let log = Logger(subsystem: "com.skybridge.compass", category: "BackgroundTask")
    private let activityScheduler = NSBackgroundActivityScheduler(identifier: "com.skybridge.compass.transfer.activity")
    private var registeredHandlers: [WorkHandler] = []
    private let queue = DispatchQueue(label: "com.skybridge.compass.background", qos: .utility)

    private init() {
 // 配置 NSBackgroundActivityScheduler 以符合 macOS 最佳实践
        activityScheduler.repeats = true
        activityScheduler.interval = 600 // 10分钟间隔
        activityScheduler.tolerance = 120 // 2分钟容差
        activityScheduler.qualityOfService = .utility
    }

 /// 注册系统任务 - 使用 macOS 原生后台活动调度器
    public func registerSystemTasks() {
        Task { @MainActor in
            await configureBackgroundTasks()
        }
    }

 /// 注册工作处理器
    public func register(handler: @escaping WorkHandler) {
        registeredHandlers.append(handler)
    }

 /// 调度后台活动
    public func schedule() {
        Task { @MainActor in
            await scheduleBackgroundActivity()
        }
    }

 /// 配置后台任务 - 仅使用 macOS 支持的 API
    private func configureBackgroundTasks() async {
        log.info("配置 macOS 后台任务调度器")
        await scheduleBackgroundActivity()
    }

 /// 调度后台活动 - 使用 NSBackgroundActivityScheduler
    private func scheduleBackgroundActivity() async {
        activityScheduler.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }
            Task { @MainActor in
                self.log.debug("执行 NSBackgroundActivityScheduler 任务")
                await self.executeHandlers {
                    completion(.finished)
                }
            }
        }
        log.debug("NSBackgroundActivityScheduler 任务已调度")
    }

 /// 执行处理器 - 使用 DispatchGroup 确保线程安全
    private func executeHandlers(completion: @escaping @Sendable () -> Void) async {
        let handlers = registeredHandlers
        guard !handlers.isEmpty else {
            completion()
            return
        }

 // 使用 DispatchGroup 顺序执行处理器，避免并发问题
        let group = DispatchGroup()
        for handler in handlers {
            group.enter()
            handler {
                group.leave()
            }
        }

 // 等待所有处理器完成
        group.notify(queue: .main) {
            completion()
        }
    }
}
