import Foundation
import Network
import OSLog

/// Shared STUN helper for current cross-network connectivity flows.
public actor STUNService {
    public static let shared = STUNService()

    private let logger = Logger(subsystem: "com.skybridge.signal", category: "STUN")
    private let stunServers: [(host: String, port: UInt16)] = [
        ("54.92.79.99", 3478),
        ("stun.l.google.com", 19302),
        ("stun1.l.google.com", 19302),
        ("stun.cloudflare.com", 3478)
    ]
    private var cachedAddress: (address: String, port: UInt16)?
    private var cacheTime: Date?
    private let cacheValidDuration: TimeInterval = 60

    private init() {}

    public func getPublicAddress() async -> (address: String, port: UInt16)? {
        if let cachedAddress,
           let cacheTime,
           Date().timeIntervalSince(cacheTime) < cacheValidDuration {
            return cachedAddress
        }

        for (host, port) in stunServers {
            if let result = await querySTUNServer(host: host, port: port) {
                cachedAddress = result
                cacheTime = Date()
                logger.info("✅ STUN 查询成功: \(result.address, privacy: .public):\(result.port, privacy: .public)")
                return result
            }
        }

        logger.warning("⚠️ 所有 STUN 服务器查询失败")
        return nil
    }

    private func querySTUNServer(host: String, port: UInt16) async -> (address: String, port: UInt16)? {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: port)
            )
            let connection = NWConnection(to: endpoint, using: .udp)

            let resumedFlag = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable ((address: String, port: UInt16)?) -> Void = { value in
                resumedFlag.withLock { done in
                    if !done {
                        done = true
                        continuation.resume(returning: value)
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = Self.createSTUNBindingRequest()
                    connection.send(content: request, completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, error in
                        defer { connection.cancel() }

                        if let data, error == nil, let result = Self.parseSTUNResponse(data) {
                            resumeOnce(result)
                            return
                        }
                        resumeOnce(nil)
                    }
                case .failed, .cancelled:
                    resumeOnce(nil)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))

            Task {
                try? await Task.sleep(for: .seconds(3))
                connection.cancel()
            }
        }
    }

    private static func createSTUNBindingRequest() -> Data {
        var data = Data()
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])

        var transactionID = [UInt8](repeating: 0, count: 12)
        for index in 0..<transactionID.count {
            transactionID[index] = UInt8.random(in: 0...255)
        }
        data.append(contentsOf: transactionID)
        return data
    }

    private static func parseSTUNResponse(_ data: Data) -> (address: String, port: UInt16)? {
        guard data.count >= 20 else { return nil }
        guard data[0] == 0x01 && data[1] == 0x01 else { return nil }

        var offset = 20
        while offset + 4 <= data.count {
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            offset += 4

            guard offset + attrLength <= data.count else { break }
            if attrType == 0x0020 || attrType == 0x0001 {
                guard attrLength >= 8 else {
                    offset += (attrLength + 3) & ~3
                    continue
                }

                let family = data[offset + 1]
                if family == 0x01 {
                    var port = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])
                    var ip = [UInt8](data[offset + 4..<offset + 8])

                    if attrType == 0x0020 {
                        port ^= 0x2112
                        ip[0] ^= 0x21
                        ip[1] ^= 0x12
                        ip[2] ^= 0xA4
                        ip[3] ^= 0x42
                    }

                    return ("\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])", port)
                }
            }

            offset += (attrLength + 3) & ~3
        }

        return nil
    }
}
