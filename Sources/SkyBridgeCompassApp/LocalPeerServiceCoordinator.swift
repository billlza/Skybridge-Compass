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
        guard !hasStarted else { return }

        do {
            try await fileTransferListener.start()
        } catch {
            SkyBridgeLogger.ui.error("❌ 启动常驻文件传输监听失败: \(error.localizedDescription, privacy: .public)")
        }

        do {
            try await remoteControlServer.start()
        } catch {
            SkyBridgeLogger.ui.error("❌ 启动常驻远程控制监听失败: \(error.localizedDescription, privacy: .public)")
        }

        if !p2pDiscoveryService.isAdvertising {
            p2pDiscoveryService.startAdvertising()
        }

        let endpoints = ServiceEndpointRegistry.shared.snapshot()
        SkyBridgeLogger.ui.info(
            """
            ✅ 常驻本地服务已就绪: transfer=\(endpoints.fileTransferPort.map(String.init) ?? "-", privacy: .public) \
            remote=\(endpoints.remoteControlPort.map(String.init) ?? "-", privacy: .public)
            """
        )
        hasStarted = true
    }
}
