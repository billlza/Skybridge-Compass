import Foundation

/// XPC 客户端（连接提权的 PowerMetrics Helper）。
/// 如果服务不存在/不可达，所有API立即返回 nil，不阻塞主线程。
@available(macOS 14.0, *)
final class PowerMetricsServiceClient: @unchecked Sendable {
 // nonisolated 对于 Sendable 类型是安全的，不需要 unsafe
    nonisolated static let shared = PowerMetricsServiceClient()
    private nonisolated init() {}

 // 服务名需与后续Helper保持一致
    private let serviceName = "com.skybridge.PowerMetricsHelper"
    private var connection: NSXPCConnection?
    private var lastSnapshot: PowerMetricsSnapshot?
    private var lastFetchTime: Date = .distantPast
    private let minFetchInterval: TimeInterval = 10.0
    private var serviceAvailable: Bool? = nil
    private var nextRetryAt: Date = .distantPast

    func fetchLatestSnapshot() async -> PowerMetricsSnapshot? {
        let now = Date()
        if now.timeIntervalSince(lastFetchTime) < minFetchInterval {
            return lastSnapshot
        }
        lastFetchTime = now

        // If we've already detected the helper is unavailable, skip repeated connection attempts.
        if serviceAvailable == false || now < nextRetryAt {
            return lastSnapshot
        }

 // 若系统无服务则直接返回nil
        guard let conn = ensureConnection() else { return lastSnapshot }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            // Helper missing / connection invalidated → back off to avoid system log spam.
            self?.serviceAvailable = false
            self?.nextRetryAt = Date().addingTimeInterval(60)
            self?.connection?.invalidate()
            self?.connection = nil
        }) as? PowerMetricsXPCProtocol else {
            serviceAvailable = false
            nextRetryAt = Date().addingTimeInterval(60)
            return lastSnapshot
        }

        let snapshot = await fetchSnapshotWithTimeout(proxy: proxy, timeout: 0.2)
        if let snapshot {
            lastSnapshot = snapshot
            serviceAvailable = true
            nextRetryAt = .distantPast
        }
        return lastSnapshot
    }

    private struct SendableProxy: @unchecked Sendable {
        let value: PowerMetricsXPCProtocol
    }

    private func fetchSnapshotWithTimeout(
        proxy: PowerMetricsXPCProtocol,
        timeout: TimeInterval
    ) async -> PowerMetricsSnapshot? {
        enum SnapshotResult: Sendable {
            case snapshot(PowerMetricsSnapshot?)
            case timeout
        }

        let sendableProxy = SendableProxy(value: proxy)

        // 取消安全的 continuation 盒子：避免 timeout 赢了后 task 被 cancel，但 continuation 永远不 resume 的问题
        final class ContinuationBox<T: Sendable>: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<T, Never>?
            private var pendingValue: T?
            private var hasResumed: Bool = false

            func setContinuation(_ cont: CheckedContinuation<T, Never>) {
                lock.lock()
                defer { lock.unlock() }
                if let pending = pendingValue, !hasResumed {
                    hasResumed = true
                    pendingValue = nil
                    cont.resume(returning: pending)
                    return
                }
                continuation = cont
            }

            func resumeOnce(_ value: T) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                if let cont = continuation {
                    continuation = nil
                    cont.resume(returning: value)
                } else {
                    pendingValue = value
                }
            }
        }
        let result = await withTaskGroup(of: SnapshotResult.self) { group in
            group.addTask {
                let box = ContinuationBox<Data?>()
                let data: Data? = await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                        box.setContinuation(continuation)
                        sendableProxy.value.fetchSnapshot { data in
                            box.resumeOnce(data)
                        }
                    }
                } onCancel: {
                    // timeout 赢了会 cancel 这个 task：这里必须 resume，让 continuation 结束
                    box.resumeOnce(nil)
                }
                let snapshot = data.flatMap { try? JSONDecoder().decode(PowerMetricsSnapshot.self, from: $0) }
                return .snapshot(snapshot)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        switch result {
        case .snapshot(let snapshot):
            return snapshot
        case .timeout:
            return nil
        }
    }

    private func ensureConnection() -> NSXPCConnection? {
        if serviceAvailable == false || Date() < nextRetryAt {
            return nil
        }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: PowerMetricsXPCProtocol.self)
        c.invalidationHandler = { [weak self] in
            self?.connection = nil
            self?.serviceAvailable = false
            self?.nextRetryAt = Date().addingTimeInterval(60)
        }
        c.resume()
        connection = c
        serviceAvailable = true
        return c
    }
}

// XPC 协议（由Helper实现）
@objc protocol PowerMetricsXPCProtocol {
    func fetchSnapshot(completion: @escaping (Data?) -> Void)
}
