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
    private struct StartAttempt {
        let id: UUID
        let task: Task<Void, Error>
    }
    private var startAttempt: StartAttempt?
    @Published public private(set) var isReady = false
    
    private init() {}
    
    public func startIfNeeded() async throws {
        if let startAttempt {
            return try await startAttempt.task.value
        }
        if started, await networkService.isHealthy() {
            isReady = true
            return
        }

        let attemptID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performStart()
        }
        startAttempt = StartAttempt(id: attemptID, task: task)
        defer {
            if startAttempt?.id == attemptID {
                startAttempt = nil
            }
        }
        try await task.value
    }

    private func performStart() async throws {
        try Task.checkCancellation()

        await networkService.setOnFileReceiveRequest { metadata, connection, peerName in
            let manager = await MainActor.run { FileTransferManager.instance }
            do {
                _ = try await manager.receiveFile(metadata: metadata, from: connection, peerContext: peerName)
            } catch {
                let nsError = error as NSError
                SignedKEMRefreshSmokeStatusWriter.append(
                    "file-transfer inbound-handler-failed domain=\(nsError.domain) code=\(nsError.code)"
                )
                SkyBridgeLogger.shared.error(
                    "❌ 文件接收失败: domain=\(nsError.domain) code=\(nsError.code)"
                )
                throw error
            }
        }

        do {
            try await networkService.ensureHealthy()
            try Task.checkCancellation()
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
        try await startIfNeeded()
    }

    func refreshAdvertisingAuthorityIfActive(
        _ authority: ProtocolIdentitySnapshot
    ) async throws {
        try await startIfNeeded()
        do {
            try await networkService.refreshAdvertisingAuthority(authority)
            started = await networkService.isHealthy()
            isReady = started
            guard started else {
                throw FileTransferError.networkError(
                    "文件传输 Bonjour 身份刷新后未进入健康状态"
                )
            }
        } catch {
            started = false
            isReady = false
            throw error
        }
    }
    
    public func stop() async {
        let inFlightStart = startAttempt?.task
        startAttempt = nil
        inFlightStart?.cancel()
        // Stop the actor-owned listener first. Cancelling this wrapper task does
        // not by itself cancel FileTransferNetworkService's shared unstructured
        // startup task, so waiting first could stall until its full deadline.
        await networkService.stopListening()
        if let inFlightStart {
            _ = try? await inFlightStart.value
        }
        started = false
        isReady = false
    }
}
