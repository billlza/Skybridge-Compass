import Foundation
import Network

/// iOS 文件传输运行时协调器：
/// - 启动监听（8080）
/// - 将入站 metadata/connection 路由给 `FileTransferManager` 落盘
@available(iOS 17.0, *)
@MainActor
public final class FileTransferRuntime: ObservableObject {
    public static let shared = FileTransferRuntime()
    
    private let networkService = FileTransferNetworkService(port: FileTransferConstants.defaultPort)
    private var started = false
    
    private init() {}
    
    public func startIfNeeded() async {
        guard !started else { return }
        started = true
        
        await networkService.setOnFileReceiveRequest { metadata, connection, peerName in
            let manager = await MainActor.run { FileTransferManager.instance }
            do {
                _ = try await manager.receiveFile(metadata: metadata, from: connection, peer: peerName)
            } catch {
                SkyBridgeLogger.shared.error("❌ 文件接收失败: \(error.localizedDescription)")
            }
        }
        
        do {
            try await networkService.startListening()
            SkyBridgeLogger.shared.info("✅ iOS 文件传输监听已启动 (port=\(FileTransferConstants.defaultPort))")
        } catch {
            SkyBridgeLogger.shared.error("❌ iOS 文件传输监听启动失败: \(error.localizedDescription)")
        }
    }
    
    public func stop() async {
        await networkService.stopListening()
        started = false
    }
}


