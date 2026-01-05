import Foundation
import Network

/// 统一的远程协议客户端接口
/// 中文说明：用于抽象不同远程协议（RDP/VNC/SSH）的连接过程，便于在UI层按协议类型调用。
public protocol RemoteProtocolClient: Sendable {
 /// 探测与初始连接，确保远端服务可达；协议细节与会话渲染由具体实现负责。
 /// - Parameters:
 /// - host: 远端主机或IP
 /// - port: 远端端口
    func probe(host: String, port: UInt16) async throws
}