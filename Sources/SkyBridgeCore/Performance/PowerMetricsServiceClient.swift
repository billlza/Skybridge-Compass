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

    func fetchLatestSnapshot() async -> PowerMetricsSnapshot? {
        let now = Date()
        if now.timeIntervalSince(lastFetchTime) < minFetchInterval {
            return lastSnapshot
        }
        lastFetchTime = now

 // 若系统无服务则直接返回nil
        guard let conn = ensureConnection() else { return lastSnapshot }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in }) as? PowerMetricsXPCProtocol else {
            return lastSnapshot
        }

        let snapshot = await fetchSnapshotWithTimeout(proxy: proxy, timeout: 0.2)
        if let snapshot {
            lastSnapshot = snapshot
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
        let result = await withTaskGroup(of: SnapshotResult.self) { group in
            group.addTask {
                let data = await withCheckedContinuation { continuation in
                    sendableProxy.value.fetchSnapshot { data in
                        continuation.resume(returning: data)
                    }
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
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: PowerMetricsXPCProtocol.self)
        c.invalidationHandler = { [weak self] in self?.connection = nil }
        c.resume()
        connection = c
        return c
    }
}

// XPC 协议（由Helper实现）
@objc protocol PowerMetricsXPCProtocol {
    func fetchSnapshot(completion: @escaping (Data?) -> Void)
}
