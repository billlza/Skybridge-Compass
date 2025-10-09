import Foundation
import os.log
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

public final class BackgroundTaskCoordinator {
    public static let shared = BackgroundTaskCoordinator()

    public typealias WorkHandler = (@escaping () -> Void) -> Void

    private let log = Logger(subsystem: "com.skybridge.compass", category: "BackgroundTask")
    private let schedulerIdentifier = "com.skybridge.compass.transfer.processing"
    private let activityScheduler = NSBackgroundActivityScheduler(identifier: "com.skybridge.compass.transfer.activity")
    private var registeredHandlers: [WorkHandler] = []
    private let queue = DispatchQueue(label: "com.skybridge.compass.background", qos: .utility)

    private init() {
        activityScheduler.repeats = true
        activityScheduler.interval = 600
        activityScheduler.tolerance = 120
    }

    public func registerSystemTasks() {
        queue.async {
            self.configureBackgroundTasks()
        }
    }

    public func register(handler: @escaping WorkHandler) {
        queue.async {
            self.registeredHandlers.append(handler)
        }
    }

    public func schedule() {
        queue.async {
            self.scheduleBackgroundActivity()
        }
    }

    private func configureBackgroundTasks() {
#if canImport(BackgroundTasks)
        if #available(macOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: schedulerIdentifier, using: nil) { [weak self] task in
                guard let processingTask = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.log.info("Executing BGProcessingTask for pending transfers")
                self?.executeHandlers {
                    processingTask.setTaskCompleted(success: true)
                }
            }
        }
#endif
        scheduleBackgroundActivity()
    }

    private func scheduleBackgroundActivity() {
        activityScheduler.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }
            self.log.debug("Running NSBackgroundActivityScheduler task")
            self.executeHandlers {
                completion(.finished)
            }
        }

#if canImport(BackgroundTasks)
        if #available(macOS 13.0, *) {
            let request = BGProcessingTaskRequest(identifier: schedulerIdentifier)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            do {
                try BGTaskScheduler.shared.submit(request)
                log.debug("BGProcessingTaskRequest submitted")
            } catch {
                log.error("Failed to submit BGProcessingTaskRequest: %{public}@", error.localizedDescription)
            }
        }
#endif
    }

    private func executeHandlers(completion: @escaping () -> Void) {
        let handlers = registeredHandlers
        guard !handlers.isEmpty else {
            completion()
            return
        }

        let group = DispatchGroup()
        for handler in handlers {
            group.enter()
            handler {
                group.leave()
            }
        }

        group.notify(queue: queue) {
            completion()
        }
    }
}
