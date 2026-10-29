import Foundation

public enum USBLogicalStreamError: Error, Equatable, Sendable {
    case invalidConfiguration, invalidArgument, invalidHeader(String), invalidBody
    case protocolViolation(String), capacityExceeded, peerStoppedAccepting
    case ownerRetired, ownerNotAccepted, sendingFinished, writePending, wrongDispatch
    case cleanupUnconfirmed, resetByPeer, cancelled, pingPending, reusedPing
}

/// Published Yamux v0 framing. No identity, encryption or account authority is supplied here.
/// https://github.com/hashicorp/yamux/blob/v0.1.2/spec.md
public enum USBLogicalStreamWire {
    public static let headerBytes = 12
    public static let initialWindow = 256 * 1024
    public static let maximumNativeTransfer = 16 * 1024
    public static let outboundDataBytes = maximumNativeTransfer - headerBytes
    public static let syn: UInt16 = 1
    public static let ack: UInt16 = 2
    public static let fin: UInt16 = 4
    public static let rst: UInt16 = 8

    public enum FrameType: UInt8, Sendable { case data = 0, windowUpdate = 1, ping = 2, goAway = 3 }
    public struct Header: Equatable, Sendable {
        public let type: FrameType
        public let flags: UInt16
        public let streamID: UInt32
        public let value: UInt32
        public init(type: FrameType, flags: UInt16, streamID: UInt32, value: UInt32) {
            self.type = type; self.flags = flags; self.streamID = streamID; self.value = value
        }
        public func has(_ flag: UInt16) -> Bool { flags & flag != 0 }
    }
    public struct Frame: Sendable {
        public let header: Header
        public let body: Data
        public init(header: Header, body: Data = Data()) throws {
            try USBLogicalStreamWire.validate(header)
            guard body.count == (header.type == .data ? Int(header.value) : 0) else {
                throw USBLogicalStreamError.invalidBody
            }
            self.header = header; self.body = body
        }
        public func encoded() throws -> Data { try USBLogicalStreamWire.encodeHeader(header) + body }
    }

    public static func validate(_ header: Header) throws {
        guard header.flags <= 15 else { throw USBLogicalStreamError.invalidHeader("unknown flags") }
        switch header.type {
        case .data, .windowUpdate:
            guard header.streamID != 0, !(header.has(syn) && header.has(ack)),
                  !header.has(rst) || header.flags == rst else {
                throw USBLogicalStreamError.invalidHeader("stream lifecycle flags")
            }
            guard header.type != .data || header.value <= initialWindow else {
                throw USBLogicalStreamError.invalidHeader("data exceeds advertised receive window")
            }
        case .ping:
            guard header.streamID == 0, header.flags == syn || header.flags == ack else {
                throw USBLogicalStreamError.invalidHeader("session ping")
            }
        case .goAway:
            guard header.streamID == 0, header.flags == 0, header.value <= 2 else {
                throw USBLogicalStreamError.invalidHeader("session go-away")
            }
        }
    }

    /// The raw carrier must decode this before allocating an untrusted body, and retain one
    /// whole-frame deadline across its header/body reads. A partial frame or physical EOF fails.
    public static func decodeHeader(_ bytes: Data) throws -> Header {
        guard bytes.count == headerBytes else { throw USBLogicalStreamError.invalidHeader("header size") }
        let b = Array(bytes)
        guard b[0] == 0, let type = FrameType(rawValue: b[1]) else {
            throw USBLogicalStreamError.invalidHeader("version or type")
        }
        func word(_ offset: Int) -> UInt32 {
            (UInt32(b[offset]) << 24) | (UInt32(b[offset + 1]) << 16) |
                (UInt32(b[offset + 2]) << 8) | UInt32(b[offset + 3])
        }
        let header = Header(type: type, flags: (UInt16(b[2]) << 8) | UInt16(b[3]), streamID: word(4), value: word(8))
        try validate(header)
        return header
    }

    public static func encodeHeader(_ header: Header) throws -> Data {
        try validate(header)
        var result = Data([0, header.type.rawValue, UInt8(header.flags >> 8), UInt8(header.flags & 255)])
        for word in [header.streamID, header.value] {
            result.append(contentsOf: [UInt8(word >> 24), UInt8((word >> 16) & 255),
                                      UInt8((word >> 8) & 255), UInt8(word & 255)])
        }
        return result
    }
}
