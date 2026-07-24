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
    @Published public private(set) var isReady = false
    
    private init() {}
    
    public func startIfNeeded() async throws {
        if started, await networkService.isHealthy() {
            isReady = true
            return
        }

        await networkService.setOnFileReceiveRequest { metadata, connection, peerName in
            let manager = await MainActor.run { FileTransferManager.instance }
            do {
                _ = try await manager.receiveFile(metadata: metadata, from: connection, peerContext: peerName)
            } catch {
                SkyBridgeLogger.shared.error("❌ 文件接收失败: \(error.localizedDescription)")
            }
        }

        do {
            try await networkService.ensureHealthy()
            started = await networkService.isHealthy()
            guard started else {
                throw FileTransferError.networkError("文件传输监听未进入健康状态")
            }
            isReady = true
            SkyBridgeLogger.shared.info("✅ iOS 文件传输监听已启动 (port=\(FileTransferConstants.defaultPort))")
        } catch {
            started = false
            isReady = false
            SkyBridgeLogger.shared.error("❌ iOS 文件传输监听启动失败: \(error.localizedDescription)")
            throw error
        }
    }

    public func ensureHealthy() async throws {
        do {
            try await networkService.ensureHealthy()
            started = await networkService.isHealthy()
            guard started else {
                throw FileTransferError.networkError("文件传输监听未进入健康状态")
            }
            isReady = true
        } catch {
            started = false
            isReady = false
            throw error
        }
    }
    
    public func stop() async {
        await networkService.stopListening()
        started = false
        isReady = false
    }
}
