import Foundation
import Network
import os.log

// MARK: - SSH 客户端探测器

/// SSH 客户端探测器
///
/// 中文说明：此类提供轻量级的 SSH 服务探测功能。
/// 对于完整的 SSH 功能（认证、命令执行、Shell 会话），请使用 `SSHClientImpl`。
///
/// Swift 6.2.1 最佳实践：
/// - 使用 `Sendable` 确保跨并发域安全
/// - 完整实现请参考 `SSHClientImpl`
public final class SSHClient: RemoteProtocolClient, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SSHClient")
    private let queue = DispatchQueue(label: "com.skybridge.ssh.probe")

    public init() {}

 /// 探测 SSH 服务是否可用
 /// - Parameters:
 /// - host: 主机地址
 /// - port: 端口号（默认 22）
    public func probe(host: String, port: UInt16) async throws {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)
        connection.start(queue: queue)
        
 // 使用 Continuation 等待连接就绪或失败，避免并发数据竞争
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.logger.info("SSH 探测连接就绪: \(host):\(port)")
                    continuation.resume()
                case .failed(let err):
                    continuation.resume(throwing: err)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
        }
        
 // 读取服务器 Banner（SSH-2.0-OpenSSH_x.x）
        let banner = try await readServerBanner(connection: connection)
        if let banner = banner {
            logger.info("SSH 服务器 Banner: \(banner)")
        }
        
        connection.cancel()
    }
    
 /// 读取 SSH 服务器 Banner
    private func readServerBanner(connection: NWConnection) async throws -> String? {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                if let data = data, let banner = String(data: data, encoding: .utf8) {
                    let trimmed = banner.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: trimmed)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
 /// 检查 SSH 服务版本
 /// - Returns: SSH 版本信息（如 "SSH-2.0-OpenSSH_8.6"）
    public func checkVersion(host: String, port: UInt16 = 22) async throws -> String? {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)
        connection.start(queue: queue)
        
 // 等待连接
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let err):
                    continuation.resume(throwing: err)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
        }
        
        let banner = try await readServerBanner(connection: connection)
        connection.cancel()
        return banner
    }
}

// MARK: - 便捷类型别名

/// 完整 SSH 客户端类型别名
/// 中文说明：推荐使用此类型进行完整的 SSH 操作
@available(macOS 14.0, *)
public typealias FullSSHClient = SSHClientImpl