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

    private init() {
        self.fileTransferListener = FileTransferListenerService(manager: fileTransferManager)
        self.remoteControlManager = RemoteControlManager()
        self.remoteControlServer = RemoteControlServer(manager: remoteControlManager)
    }

    func startIfNeeded() async throws {
        try await ensureHealthy()
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
