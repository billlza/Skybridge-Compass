#if os(macOS)
import Foundation
import Network

/// USB presence is routing evidence, never protocol identity or pairing consent.
public struct USBMultiplexDevice: Codable, Equatable, Sendable {
    public let deviceID: UInt32
    public let udid: String
    public let productID: UInt32
    public let connectionType: String
}

public enum USBMultiplexError: String, Error, LocalizedError, Sendable {
    case unavailable, malformedResponse, deviceUnavailable, ambiguousDevice
    case portUnavailable, timedOut, peerClosed

    public var errorDescription: String? { "USB transport: \(rawValue)" }
}

/// Speaks the plist usbmuxd protocol to the OS-owned local socket. Once Connect
/// succeeds, the SAME NWConnection carries the app's existing framed protocol.
/// No local TCP proxy, Xcode runner, Wi-Fi fallback or device credential is used.
public enum USBMultiplexTransport {
    public static let socketPath = "/var/run/usbmuxd"
    public static let controlPort: UInt16 = 9527
    static let maximumPacketBytes = 1_048_576

    public static func devices() async throws -> [USBMultiplexDevice] {
        try await withConnection { connection in
            defer { connection.cancel() }
            let response = try await exchange(
                message("ListDevices"), tag: 1, over: connection
            )
            return try decodeDevices(response)
        }
    }

    /// Re-enumerate immediately before each dial: daemon DeviceIDs are ephemeral,
    /// and a USB device must never silently resolve to its Network twin.
    public static func open(udid: String, port: UInt16 = controlPort) async throws -> NWConnection {
        guard port > 0, !udid.isEmpty else { throw USBMultiplexError.malformedResponse }
        let matches = try await devices().filter { $0.udid == udid }
        guard let device = matches.first else { throw USBMultiplexError.deviceUnavailable }
        guard matches.count == 1 else { throw USBMultiplexError.ambiguousDevice }
        return try await withConnection { connection in
            var request = message("Connect")
            request["DeviceID"] = device.deviceID
            request["PortNumber"] = port.bigEndian
            let response = try await exchange(request, tag: 2, over: connection)
            guard response["MessageType"] as? String == "Result",
                  let number = integer(response["Number"]) else {
                throw USBMultiplexError.malformedResponse
            }
            guard number == 0 else { throw USBMultiplexError.portUnavailable }
            try Task.checkCancellation()
            return connection
        }
    }

    static func decodeDevices(_ response: [String: Any]) throws -> [USBMultiplexDevice] {
        guard let rows = response["DeviceList"] as? [[String: Any]], rows.count <= 256 else {
            throw USBMultiplexError.malformedResponse
        }
        var devices: [USBMultiplexDevice] = []
        var identifiers = Set<UInt32>()
        var serials = Set<String>()
        for row in rows {
            guard let properties = row["Properties"] as? [String: Any],
                  let connectionType = properties["ConnectionType"] as? String else {
                throw USBMultiplexError.malformedResponse
            }
            // Network entries are explicitly not USB candidates.
            if connectionType == "Network" { continue }
            guard connectionType == "USB",
                  let deviceID = integer(properties["DeviceID"]), deviceID > 0,
                  integer(row["DeviceID"]) == deviceID,
                  let productID = integer(properties["ProductID"]),
                  let udid = properties["SerialNumber"] as? String,
                  (24...64).contains(udid.utf8.count),
                  udid.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0)
                      || (97...102).contains($0) || $0 == 45 }) else {
                throw USBMultiplexError.malformedResponse
            }
            guard identifiers.insert(deviceID).inserted, serials.insert(udid).inserted else {
                throw USBMultiplexError.ambiguousDevice
            }
            devices.append(.init(deviceID: deviceID, udid: udid, productID: productID,
                                 connectionType: connectionType))
        }
        return devices.sorted { $0.udid < $1.udid }
    }

    private static func integer(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0,
              number.doubleValue <= Double(UInt32.max),
              number.doubleValue == Double(number.uint32Value) else { return nil }
        return number.uint32Value
    }

    private static func message(_ type: String) -> [String: Any] {
        ["MessageType": type, "ClientVersionString": "SkyBridge",
         "ProgName": "SkyBridge", "kLibUSBMuxVersion": 3]
    }

    static func packet(_ payload: Data, tag: UInt32) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumPacketBytes - 16 else {
            throw USBMultiplexError.malformedResponse
        }
        var result = Data()
        for value in [UInt32(payload.count + 16), 1, 8, tag] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        result.append(payload)
        return result
    }

    static func payloadLength(header: Data, tag: UInt32) throws -> Int {
        guard header.count == 16 else { throw USBMultiplexError.malformedResponse }
        let words = stride(from: 0, to: 16, by: 4).map { offset in
            header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
        }
        guard (17...UInt32(maximumPacketBytes)).contains(words[0]),
              words[1] == 1, words[2] == 8, words[3] == tag else {
            throw USBMultiplexError.malformedResponse
        }
        return Int(words[0]) - 16
    }

    private static func exchange(
        _ request: [String: Any], tag: UInt32, over connection: NWConnection
    ) async throws -> [String: Any] {
        let payload = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        let bytes = try packet(payload, tag: tag)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
        let reader = FramedReader.nwConnection(connection)
        let header = try await reader.receiveExactly(16)
        let length = try payloadLength(header: header, tag: tag)
        let data = try await reader.receiveExactly(length)
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw USBMultiplexError.malformedResponse
        }
        return result
    }

    private static func withConnection<T: Sendable>(
        _ operation: @escaping @Sendable (NWConnection) async throws -> T
    ) async throws -> T {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask {
                        try await ready(connection)
                        try Task.checkCancellation()
                        return try await operation(connection)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(6))
                        connection.cancel() // Unblock an outstanding exact read before draining the group.
                        throw USBMultiplexError.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw USBMultiplexError.unavailable }
                    return result
                }
            } catch {
                connection.cancel()
                throw error
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func ready(_ connection: NWConnection) async throws {
        let states = AsyncStream<NWConnection.State>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            connection.stateUpdateHandler = { state in
                continuation.yield(state)
            }
            connection.start(queue: DispatchQueue(label: "com.skybridge.usb.multiplex"))
        }
        defer { connection.stateUpdateHandler = nil }
        for await state in states {
            switch state {
            case .ready: return
            case .failed(let error): throw error
            case .cancelled: throw CancellationError()
            default: continue
            }
        }
        throw CancellationError()
    }
}
#endif
