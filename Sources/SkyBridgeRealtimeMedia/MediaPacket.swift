import CryptoKit
import Foundation

public enum SkyBridgeMediaPacketError: Error, Equatable, Sendable, LocalizedError {
    case payloadTooLarge(Int)
    case malformedPacket
    case unsupportedMagic(UInt32)
    case unsupportedVersion(UInt8)
    case epochMismatch(expected: UInt32, actual: UInt32)
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge(let bytes):
            return "payloadTooLarge(\(bytes))"
        case .malformedPacket:
            return "malformedPacket"
        case .unsupportedMagic(let magic):
            return "unsupportedMagic(\(magic))"
        case .unsupportedVersion(let version):
            return "unsupportedVersion(\(version))"
        case .epochMismatch(let expected, let actual):
            return "epochMismatch(expected:\(expected), actual:\(actual))"
        case .authenticationFailed:
            return "authenticationFailed"
        }
    }
}

public struct SkyBridgeMediaPacketHeader: Equatable, Sendable {
    public let sessionIdHash: UInt64
    public let streamId: UInt32
    public let sequence: UInt64
    public let timestampSamples: UInt64
    public let flags: UInt16
    public let keyEpoch: UInt32
    public let nonceCounter: UInt64

    public init(
        sessionIdHash: UInt64,
        streamId: UInt32 = SkyBridgeRealtimeMediaConstants.defaultStreamId,
        sequence: UInt64,
        timestampSamples: UInt64,
        flags: UInt16 = 0,
        keyEpoch: UInt32,
        nonceCounter: UInt64
    ) {
        self.sessionIdHash = sessionIdHash
        self.streamId = streamId
        self.sequence = sequence
        self.timestampSamples = timestampSamples
        self.flags = flags
        self.keyEpoch = keyEpoch
        self.nonceCounter = nonceCounter
    }
}

public struct SkyBridgeMediaOpenedPacket: Equatable, Sendable {
    public let header: SkyBridgeMediaPacketHeader
    public let payload: Data

    public init(header: SkyBridgeMediaPacketHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

public enum SkyBridgeMediaPacketCodec {
    public static let maxPayloadBytes = 1_100

    private static let magic: UInt32 = 0x53424D41 // "SBMA"
    private static let version: UInt8 = 1
    private static let headerLength = 52
    private static let tagLength = 16

    public static func seal(
        payload: Data,
        header: SkyBridgeMediaPacketHeader,
        keys: SkyBridgeMediaDirectionKeys
    ) throws -> Data {
        guard payload.count <= maxPayloadBytes else {
            throw SkyBridgeMediaPacketError.payloadTooLarge(payload.count)
        }
        guard header.keyEpoch == keys.epoch else {
            throw SkyBridgeMediaPacketError.epochMismatch(expected: keys.epoch, actual: header.keyEpoch)
        }
        var headerData = Data()
        headerData.reserveCapacity(headerLength)
        appendUInt32(magic, to: &headerData)
        headerData.append(version)
        headerData.append(UInt8(headerLength))
        appendUInt16(header.flags, to: &headerData)
        appendUInt64(header.sessionIdHash, to: &headerData)
        appendUInt32(header.streamId, to: &headerData)
        appendUInt64(header.sequence, to: &headerData)
        appendUInt64(header.timestampSamples, to: &headerData)
        appendUInt32(header.keyEpoch, to: &headerData)
        appendUInt64(header.nonceCounter, to: &headerData)
        appendUInt32(UInt32(payload.count), to: &headerData)
        precondition(headerData.count == headerLength)

        let sealed = try AES.GCM.seal(
            payload,
            using: keys.key,
            nonce: try nonce(salt: keys.nonceSalt, counter: header.nonceCounter),
            authenticating: headerData
        )
        var packet = headerData
        packet.append(sealed.ciphertext)
        packet.append(sealed.tag)
        return packet
    }

    public static func open(
        packet: Data,
        keys: SkyBridgeMediaDirectionKeys
    ) throws -> SkyBridgeMediaOpenedPacket {
        guard packet.count >= headerLength + tagLength else {
            throw SkyBridgeMediaPacketError.malformedPacket
        }
        let magic = readUInt32(packet, at: 0)
        guard magic == self.magic else {
            throw SkyBridgeMediaPacketError.unsupportedMagic(magic)
        }
        let version = packet[packet.startIndex + 4]
        guard version == self.version else {
            throw SkyBridgeMediaPacketError.unsupportedVersion(version)
        }
        let encodedHeaderLength = Int(packet[packet.startIndex + 5])
        guard encodedHeaderLength == headerLength, packet.count >= encodedHeaderLength + tagLength else {
            throw SkyBridgeMediaPacketError.malformedPacket
        }
        let flags = readUInt16(packet, at: 6)
        let sessionIdHash = readUInt64(packet, at: 8)
        let streamId = readUInt32(packet, at: 16)
        let sequence = readUInt64(packet, at: 20)
        let timestampSamples = readUInt64(packet, at: 28)
        let keyEpoch = readUInt32(packet, at: 36)
        let nonceCounter = readUInt64(packet, at: 40)
        let payloadLength = Int(readUInt32(packet, at: 48))
        guard keyEpoch == keys.epoch else {
            throw SkyBridgeMediaPacketError.epochMismatch(expected: keys.epoch, actual: keyEpoch)
        }
        guard payloadLength <= maxPayloadBytes,
              packet.count == headerLength + payloadLength + tagLength else {
            throw SkyBridgeMediaPacketError.malformedPacket
        }
        let headerData = packet.prefix(headerLength)
        let ciphertext = packet.dropFirst(headerLength).prefix(payloadLength)
        let tag = packet.suffix(tagLength)
        let box = try AES.GCM.SealedBox(
            nonce: try nonce(salt: keys.nonceSalt, counter: nonceCounter),
            ciphertext: ciphertext,
            tag: tag
        )
        do {
            let payload = try AES.GCM.open(box, using: keys.key, authenticating: headerData)
            return SkyBridgeMediaOpenedPacket(
                header: SkyBridgeMediaPacketHeader(
                    sessionIdHash: sessionIdHash,
                    streamId: streamId,
                    sequence: sequence,
                    timestampSamples: timestampSamples,
                    flags: flags,
                    keyEpoch: keyEpoch,
                    nonceCounter: nonceCounter
                ),
                payload: payload
            )
        } catch {
            throw SkyBridgeMediaPacketError.authenticationFailed
        }
    }

    public static func sessionIdHash(_ sessionId: String) -> UInt64 {
        let digest = SHA256.hash(data: Data(sessionId.utf8))
        return digest.prefix(8).reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }

    private static func nonce(salt: Data, counter: UInt64) throws -> AES.GCM.Nonce {
        var data = Data()
        data.reserveCapacity(12)
        data.append(salt.prefix(4))
        appendUInt64(counter, to: &data)
        return try AES.GCM.Nonce(data: data)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[data.startIndex + offset]) << 8)
            | UInt16(data[data.startIndex + offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[data.startIndex + offset]) << 24)
            | (UInt32(data[data.startIndex + offset + 1]) << 16)
            | (UInt32(data[data.startIndex + offset + 2]) << 8)
            | UInt32(data[data.startIndex + offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[data.startIndex + offset + index])
        }
        return value
    }
}
