import CryptoKit
import Network
import OSLog

/// 连接监听器 - 通过 NWListener 在本地端口接受入站 P2P 连接。
///
/// 说明：当前跨网连接主路径已迁移至 WebRTC DataChannel（不依赖端口监听），
/// 此监听器仅在局域网/直连回退场景下使用。
actor ConnectionListener {
    private let logger = Logger(subsystem: "com.skybridge.connection", category: "Listener")
    let sessionID: String
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    private var listener: NWListener?

    init(sessionID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.sessionID = sessionID
        self.privateKey = privateKey
    }

    func start(onConnection: @escaping @Sendable (RemoteConnection) async -> Void) async {
        do {
            let params = NWParameters.quic(alpn: ["skybridge-p2p"])
            let nwListener = try NWListener(using: params)
            self.listener = nwListener

            nwListener.newConnectionHandler = { [sessionID] conn in
                conn.start(queue: .global(qos: .userInitiated))
                let remote = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .nw(conn))
                Task { await onConnection(remote) }
            }
            nwListener.start(queue: .global(qos: .userInitiated))
            logger.info("✅ ConnectionListener started for session=\(self.sessionID, privacy: .public)")
        } catch {
            logger.error("❌ ConnectionListener failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
