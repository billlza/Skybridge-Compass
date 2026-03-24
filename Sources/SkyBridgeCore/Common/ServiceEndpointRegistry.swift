import Foundation
import OSLog

public struct ServiceEndpointSnapshot: Sendable, Equatable {
    public var fileTransferPort: UInt16?
    public var remoteControlPort: UInt16?

    public init(
        fileTransferPort: UInt16? = nil,
        remoteControlPort: UInt16? = nil
    ) {
        self.fileTransferPort = fileTransferPort
        self.remoteControlPort = remoteControlPort
    }
}

/// Shared registry for the ports actually bound by the dedicated local services.
/// Discovery and heartbeat layers read from here so they stop advertising stale defaults.
public final class ServiceEndpointRegistry: @unchecked Sendable {
    public static let shared = ServiceEndpointRegistry()

    private let logger = Logger(
        subsystem: "com.skybridge.compass",
        category: "ServiceEndpointRegistry"
    )
    private let lock = NSLock()
    private var state = ServiceEndpointSnapshot()

    private init() {}

    public func snapshot() -> ServiceEndpointSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func setFileTransferPort(_ port: UInt16?) {
        lock.lock()
        state.fileTransferPort = port
        let snapshot = state
        lock.unlock()
        logSnapshot(snapshot)
    }

    public func setRemoteControlPort(_ port: UInt16?) {
        lock.lock()
        state.remoteControlPort = port
        let snapshot = state
        lock.unlock()
        logSnapshot(snapshot)
    }

    private func logSnapshot(_ snapshot: ServiceEndpointSnapshot) {
        logger.info(
            "📡 服务端点已更新: transfer=\(snapshot.fileTransferPort.map(String.init) ?? "-", privacy: .public) remote=\(snapshot.remoteControlPort.map(String.init) ?? "-", privacy: .public)"
        )
    }
}
