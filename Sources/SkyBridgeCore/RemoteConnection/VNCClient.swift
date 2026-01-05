import Foundation
import Network
import os.log

// MARK: - VNC 客户端探测器

/// VNC(RFB) 客户端探测器
///
/// 中文说明：此类提供轻量级的 VNC 服务探测功能。
/// 对于完整的 VNC 功能（认证、帧缓冲、输入事件），请使用 `VNCClientImpl`。
///
/// Swift 6.2.1 最佳实践：
/// - 使用 `Sendable` 确保跨并发域安全
/// - 完整实现请参考 `VNCClientImpl`
public final class VNCClient: RemoteProtocolClient, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "VNCClient")
    private let queue = DispatchQueue(label: "com.skybridge.vnc.probe")

    public init() {}

 /// 探测 VNC 服务是否可用
 /// - Parameters:
 /// - host: 主机地址
 /// - port: 端口号（默认 5900）
    public func probe(host: String, port: UInt16) async throws {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)
        connection.start(queue: queue)

 // 使用 Continuation 等待连接就绪或失败
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.logger.info("VNC 探测连接就绪: \(host):\(port)")
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

 // 读取服务器版本字符串（RFB x.y\n）
        let versionInfo = try await readServerVersion(connection: connection)
        if let version = versionInfo {
            logger.info("VNC 版本: \(version.version), 协议: \(version.protocolVersion)")
        }

        connection.cancel()
    }
    
 /// 读取 VNC 服务器版本
    private func readServerVersion(connection: NWConnection) async throws -> VNCVersionInfo? {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VNCVersionInfo?, Error>) in
            connection.receive(minimumIncompleteLength: 12, maximumLength: 64) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let data = data, !data.isEmpty,
                      let versionString = String(data: data, encoding: .ascii) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let trimmed = versionString.trimmingCharacters(in: .whitespacesAndNewlines)
                let info = VNCVersionInfo(
                    version: trimmed,
                    protocolVersion: self.parseProtocolVersion(trimmed)
                )
                continuation.resume(returning: info)
            }
        }
    }
    
 /// 解析 RFB 协议版本
    private func parseProtocolVersion(_ version: String) -> String {
        if version.contains("003.008") {
            return "RFB 3.8"
        } else if version.contains("003.007") {
            return "RFB 3.7"
        } else if version.contains("003.003") {
            return "RFB 3.3"
        }
        return "Unknown"
    }
    
 /// 检查 VNC 服务版本
 /// - Returns: VNC 版本信息
    public func checkVersion(host: String, port: UInt16 = 5900) async throws -> VNCVersionInfo? {
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
        
        let info = try await readServerVersion(connection: connection)
        connection.cancel()
        return info
    }
}

// MARK: - VNC 版本信息

/// VNC 版本信息
public struct VNCVersionInfo: Sendable {
 /// 原始版本字符串
    public let version: String
 /// 解析后的协议版本
    public let protocolVersion: String
}