import Foundation
import Network
import SkyBridgeProtocolCore
import SkyBridgeAppleTransport

/// Framing effects for the existing session state machine. Network.framework
/// retains its synchronous native enqueue; USB owns a bounded deferred writer.
/// Route discovery, identity and account authorization do not live here.
enum P2PControlFrameCarrier: Sendable {
    case network(NWConnection)
    #if os(macOS)
    case usb(USBHostControlFrameTransport)
    #endif

    typealias Authorization = @Sendable () throws -> Void
    var networkConnection: NWConnection? {
        switch self {
        case .network(let connection): return connection
        #if os(macOS)
        case .usb: return nil
        #endif
        }
    }
    var isReady: Bool {
        switch self {
        case .network(let connection): if case .ready = connection.state { return true }; return false
        #if os(macOS)
        case .usb(let transport): return transport.isReady
        #endif
        }
    }
    func close() {
        switch self {
        case .network(let connection): connection.cancel()
        #if os(macOS)
        case .usb(let transport): transport.close()
        #endif
        }
    }
    func receiveFrame() async throws -> Data {
        switch self {
        case .network(let connection): return try await FramedReader.nwConnection(connection).receiveFrame()
        #if os(macOS)
        case .usb(let transport): return try await transport.receiveFrame()
        #endif
        }
    }
    func sendFrame(_ payload: Data, authorization: @escaping Authorization) async throws {
        try authorization()
        switch self {
        case .network(let connection):
            let frame = try P2PControlFramePolicy.frame(body: payload)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        #if os(macOS)
        case .usb(let transport): try await transport.sendFrame(payload, requireEffectAuthorization: authorization)
        #endif
        }
    }

    /// Called while the builder still owns its preparation/epoch lock. The
    /// network enqueue occurs in that turn. USB repeats the captured check on
    /// its native writer, after that lock has been released; never inline here.
    func enqueuePreparedFrame(_ frame: Data, authorization: @escaping Authorization,
                              completion: @escaping @Sendable (Result<Void, any Error>) -> Void) throws {
        switch self {
        case .network(let connection):
            connection.send(content: frame, completion: .contentProcessed { error in
                completion(error.map { .failure($0) } ?? .success(()))
            })
        #if os(macOS)
        case .usb(let transport):
            try transport.enqueueFramedBytes(frame, requireEffectAuthorization: authorization, completion: completion)
        #endif
        }
    }
}
