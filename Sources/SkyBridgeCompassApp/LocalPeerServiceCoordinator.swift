import AppKit
import Foundation
import SkyBridgeCore

private enum LocalPeerServiceCoordinatorError: LocalizedError {
    case fileTransferListenerUnavailable
    case remoteControlServerUnavailable

    var errorDescription: String? {
        switch self {
        case .fileTransferListenerUnavailable:
            return "文件传输监听器启动后没有可用端口"
        case .remoteControlServerUnavailable:
            return "远程控制监听器启动后没有可用端口"
        }
    }
}

@available(macOS 14.0, *)
@MainActor
final class LocalPeerServiceCoordinator: ObservableObject {
    static let shared = LocalPeerServiceCoordinator()

    private let fileTransferManager = FileTransferManager.shared
    private let fileTransferListener: FileTransferListenerService
    private let remoteControlManager: RemoteControlManager
    private let remoteControlServer: RemoteControlServer
    private let p2pDiscoveryService = P2PDiscoveryService.shared

    @Published private(set) var hasStarted = false

    /// Grace period after wake before reconciling. Interfaces come back asynchronously; probing a
    /// listener immediately would report a failure that resolves itself a second later.
    private static let postWakeReconcileDelay: Duration = .seconds(3)

    private var wakeObserverToken: NSObjectProtocol?
    private var postWakeReconcileTask: Task<Void, Never>?

    private init() {
        self.fileTransferListener = FileTransferListenerService(manager: fileTransferManager)
        self.remoteControlManager = RemoteControlManager()
        self.remoteControlServer = RemoteControlServer(manager: remoteControlManager)
    }

    func startIfNeeded() async throws {
        installWakeObserverIfNeeded()
        try await ensureHealthy()
    }

    /// Reconciles the local listeners after the machine wakes.
    ///
    /// The Bonjour advertisement is deliberately *not* withdrawn at sleep, because Wake on Demand
    /// requires a live registration for the Sleep Proxy Server to take over. The listener socket,
    /// however, can be left stale by the interface teardown/rebuild across a sleep cycle, and
    /// nothing else re-drives it — so without this the Mac can come back advertising a service
    /// that no longer accepts connections.
    private func installWakeObserverIfNeeded() {
        guard wakeObserverToken == nil else { return }

        wakeObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: OperationQueue.main
        ) { _ in
            Task { @MainActor in
                LocalPeerServiceCoordinator.shared.schedulePostWakeReconcile()
            }
        }
    }

    private func schedulePostWakeReconcile() {
        postWakeReconcileTask?.cancel()
        postWakeReconcileTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.postWakeReconcileDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.hasStarted else { return }

            do {
                try await self.ensureHealthy()
                SkyBridgeLogger.ui.info("🌅 系统唤醒后常驻本地服务已复核")
            } catch {
                // Surfaced, not swallowed: an unreachable listener behind a live Bonjour record is
                // exactly the state that makes a peer look online but refuse connections.
                SkyBridgeLogger.ui.error(
                    "❌ 系统唤醒后常驻本地服务复核失败: \(error.localizedDescription, privacy: .public)"
                )
            }
            self.postWakeReconcileTask = nil
        }
    }

    func ensureHealthy() async throws {
        fileTransferManager.localServiceHealthCheck = { @MainActor in
            try await LocalPeerServiceCoordinator.shared.ensureHealthy()
        }

        var fileTransferReady = false
        var remoteControlReady = false

        try await fileTransferListener.ensureHealthy()
        fileTransferReady = fileTransferListener.activePort != nil
        guard fileTransferReady else {
            throw LocalPeerServiceCoordinatorError.fileTransferListenerUnavailable
        }

        try await remoteControlServer.ensureHealthy()
        remoteControlReady = remoteControlServer.activePort != nil
        guard remoteControlReady else {
            throw LocalPeerServiceCoordinatorError.remoteControlServerUnavailable
        }

        try await p2pDiscoveryService.ensureAdvertisingHealthy()

        let endpoints = ServiceEndpointRegistry.shared.snapshot()
        hasStarted = true
        SkyBridgeLogger.ui.info(
            """
            ✅ 常驻本地服务已就绪: transfer=\(endpoints.fileTransferPort.map(String.init) ?? "-", privacy: .public) \
            remote=\(endpoints.remoteControlPort.map(String.init) ?? "-", privacy: .public)
            """
        )
    }
}
