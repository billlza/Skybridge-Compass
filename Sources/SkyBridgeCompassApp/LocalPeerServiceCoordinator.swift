import Foundation
import SkyBridgeCore

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

    func startIfNeeded() async {
        do {
            try await ensureHealthy()
        } catch {
            SkyBridgeLogger.ui.error("❌ 常驻本地服务健康检查失败: \(error.localizedDescription, privacy: .public)")
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

        let endpointsBeforeRemote = ServiceEndpointRegistry.shared.snapshot()
        let remoteNeedsRestart = remoteControlServer.activePort == nil
            || endpointsBeforeRemote.remoteControlPort == nil
            || endpointsBeforeRemote.remoteControlPort != remoteControlServer.activePort
            || !remoteControlServer.isBonjourPublished
        if remoteNeedsRestart {
            if remoteControlServer.activePort != nil {
                remoteControlServer.stop()
            }
            do {
                try await remoteControlServer.start()
            } catch {
                SkyBridgeLogger.ui.error("❌ 启动常驻远程控制监听失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        remoteControlReady = remoteControlServer.activePort != nil

        if !p2pDiscoveryService.isAdvertising {
            p2pDiscoveryService.startAdvertising()
        }

        let endpoints = ServiceEndpointRegistry.shared.snapshot()
        hasStarted = fileTransferReady && remoteControlReady
        if hasStarted {
            SkyBridgeLogger.ui.info(
                """
                ✅ 常驻本地服务已就绪: transfer=\(endpoints.fileTransferPort.map(String.init) ?? "-", privacy: .public) \
                remote=\(endpoints.remoteControlPort.map(String.init) ?? "-", privacy: .public)
                """
            )
        } else {
            SkyBridgeLogger.ui.warning("⚠️ 常驻本地服务未全部就绪，将在下次调用时重试启动")
        }
    }
}
