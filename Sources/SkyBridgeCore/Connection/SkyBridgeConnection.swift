import Foundation
import Network
import OSLog

/// 对 NWConnection 做一层安全包装
/// - 跟踪当前状态
/// - 仅在 .ready 时允许访问 endpoint / metadata
/// - 统一管理 start / cancel / 发送 / 接收
public final class SkyBridgeConnection: @unchecked Sendable {
    public enum LifecycleState {
        case idle
        case connecting
        case ready
        case failed(Error)
        case cancelled
    }

    public let id: UUID = UUID()
    private let logger = Logger(subsystem: "com.skybridge.Compass", category: "SkyBridgeConnection")
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var externalStateHandler: (@Sendable (NWConnection.State) -> Void)?
    private var lifecycleState: LifecycleState = .idle
    private let stateLock = NSLock()

    public init(
        connection: NWConnection,
        queue: DispatchQueue = .global(qos: .userInitiated),
        stateHandler: (@Sendable (NWConnection.State) -> Void)? = nil
    ) {
        self.connection = connection
        self.queue = queue
        self.externalStateHandler = stateHandler
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            self.handleStateUpdate(newState)
            self.externalStateHandler?(newState)
        }
    }

 /// 设置外部状态回调（可在初始化后调用）
    public func onStateUpdate(_ handler: @Sendable @escaping (NWConnection.State) -> Void) {
        self.externalStateHandler = handler
    }

 /// 当前安全状态（线程安全）
    public var state: LifecycleState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lifecycleState
    }

    private func setState(_ newState: LifecycleState) {
        stateLock.lock()
        lifecycleState = newState
        stateLock.unlock()
    }

 /// 启动连接
    public func start() {
        setState(.connecting)
        connection.start(queue: queue)
    }

 /// 取消连接
    public func cancel() {
        connection.cancel()
 // 具体状态会在回调中置为 .cancelled
    }

 /// 仅在 .ready 时返回远端 Endpoint，否则为 nil
    public var remoteEndpoint: NWEndpoint? {
        guard case .ready = state else { return nil }
        return connection.currentPath?.remoteEndpoint
    }

 /// 仅在 .ready 时返回本地 Endpoint，否则为 nil
    public var localEndpoint: NWEndpoint? {
        guard case .ready = state else { return nil }
        return connection.currentPath?.localEndpoint
    }

 /// 发送数据（透传）
    public func send(_ data: Data, completion: @Sendable @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error)
        })
    }

 /// 接收数据（透传）
    public func receive(min: Int = 1,
                        max: Int = 64 * 1024,
                        handler: @Sendable @escaping (Data?, NWConnection.ContentContext?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: min,
                           maximumLength: max,
                           completion: handler)
    }

 /// 内部状态处理
    private func handleStateUpdate(_ newState: NWConnection.State) {
        switch newState {
        case .setup:
            break
        case .waiting(let error):
            logger.debug("🔁 连接等待: \(error.localizedDescription, privacy: .public)")
            setState(.connecting)
        case .preparing:
            setState(.connecting)
        case .ready:
            let remoteDesc = connection.currentPath?.remoteEndpoint?.debugDescription ?? "(unknown)"
            logger.info("✅ 连接就绪: \(remoteDesc, privacy: .public)")
            setState(.ready)
        case .failed(let error):
            logger.error("❌ 连接失败: \(error.localizedDescription, privacy: .public)")
            setState(.failed(error))
        case .cancelled:
            logger.info("🛑 连接已取消")
            setState(.cancelled)
        @unknown default:
            logger.error("⚠️ 未知连接状态")
        }
    }
}