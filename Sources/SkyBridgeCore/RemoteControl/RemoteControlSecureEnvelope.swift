import CryptoKit
import Foundation

enum RemoteControlSecurePacketType: UInt8, Sendable, Hashable {
    case control = 1
    case screen = 2
    case audio = 3
}

struct RemoteControlSecureOpenedPayload: Sendable {
    let packetType: RemoteControlSecurePacketType
    let direction: UInt8
    let sessionHash: UInt64
    let transcriptPrefix: UInt64
    let epoch: UInt32
    let counter: UInt64
    let payload: Data
}

enum RemoteControlSecureReplayRejectionReason: String, Sendable {
    case duplicateCounter = "duplicate-counter"
    case counterOutsideWindow = "counter-outside-window"
}

enum RemoteControlSecureEnvelopeError: Error, LocalizedError, Equatable {
    case malformed
    case unsupportedMagic(UInt32)
    case unsupportedVersion(UInt8)
    case unsupportedPacketType(UInt8)
    case packetTypeMismatch(expected: [RemoteControlSecurePacketType], actual: RemoteControlSecurePacketType)
    case directionMismatch(expected: UInt8, actual: UInt8)
    case sessionMismatch(expected: UInt64, actual: UInt64)
    case transcriptMismatch(expected: UInt64, actual: UInt64)
    case epochMismatch(expected: UInt32, actual: UInt32)
    case authenticationFailed(packetType: RemoteControlSecurePacketType, counter: UInt64)
    case invalidCounter(UInt64)
    case replayDetected(
        packetType: RemoteControlSecurePacketType,
        counter: UInt64,
        highestCounter: UInt64,
        reason: RemoteControlSecureReplayRejectionReason
    )

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "malformed secure envelope"
        case .unsupportedMagic(let magic):
            return "unsupported secure envelope magic=\(magic)"
        case .unsupportedVersion(let version):
            return "unsupported secure envelope version=\(version)"
        case .unsupportedPacketType(let raw):
            return "unsupported secure envelope packetType=\(raw)"
        case .packetTypeMismatch(let expected, let actual):
            let expectedRaw = expected.map { String($0.rawValue) }.joined(separator: ",")
            return "secure envelope packetType mismatch expected=\(expectedRaw) actual=\(actual.rawValue)"
        case .directionMismatch(let expected, let actual):
            return "secure envelope direction mismatch expected=\(expected) actual=\(actual)"
        case .sessionMismatch(let expected, let actual):
            return "secure envelope session mismatch expected=\(expected) actual=\(actual)"
        case .transcriptMismatch(let expected, let actual):
            return "secure envelope transcript mismatch expected=\(expected) actual=\(actual)"
        case .epochMismatch(let expected, let actual):
            return "secure envelope epoch mismatch expected=\(expected) actual=\(actual)"
        case .authenticationFailed(let packetType, let counter):
            return "secure envelope authentication failed packetType=\(packetType.rawValue) counter=\(counter)"
        case .invalidCounter(let counter):
            return "secure envelope invalid counter=\(counter)"
        case .replayDetected(let packetType, let counter, let highestCounter, let reason):
            return "secure envelope replay detected packetType=\(packetType.rawValue) counter=\(counter) highestCounter=\(highestCounter) reason=\(reason.rawValue)"
        }
    }
}

struct RemoteControlSecureReplayWindow: Sendable {
    private struct ReplayScope: Hashable, Sendable {
        let packetType: RemoteControlSecurePacketType
        let direction: UInt8
        let sessionHash: UInt64
        let transcriptPrefix: UInt64
        let epoch: UInt32
    }

    private struct ReplayLane: Sendable {
        var highestCounter: UInt64 = 0
        var recordedCounters: Set<UInt64> = []
    }

    private static let windowSize: UInt64 = 1024
    private var lanes: [ReplayScope: ReplayLane] = [:]

    mutating func validateAndRecord(_ openedPayload: RemoteControlSecureOpenedPayload) throws {
        guard openedPayload.counter > 0 else {
            throw RemoteControlSecureEnvelopeError.invalidCounter(openedPayload.counter)
        }

        let scope = ReplayScope(
            packetType: openedPayload.packetType,
            direction: openedPayload.direction,
            sessionHash: openedPayload.sessionHash,
            transcriptPrefix: openedPayload.transcriptPrefix,
            epoch: openedPayload.epoch
        )
        var lane = lanes[scope] ?? ReplayLane()
        let highestCounter = lane.highestCounter

        if openedPayload.counter > highestCounter {
            lane.highestCounter = openedPayload.counter
            lane.recordedCounters.insert(openedPayload.counter)
            pruneRecordedCounters(in: &lane)
            lanes[scope] = lane
            return
        }

        let counterDistance = highestCounter - openedPayload.counter
        guard counterDistance < Self.windowSize else {
            throw RemoteControlSecureEnvelopeError.replayDetected(
                packetType: openedPayload.packetType,
                counter: openedPayload.counter,
                highestCounter: highestCounter,
                reason: .counterOutsideWindow
            )
        }
        guard !lane.recordedCounters.contains(openedPayload.counter) else {
            throw RemoteControlSecureEnvelopeError.replayDetected(
                packetType: openedPayload.packetType,
                counter: openedPayload.counter,
                highestCounter: highestCounter,
                reason: .duplicateCounter
            )
        }

        lane.recordedCounters.insert(openedPayload.counter)
        lanes[scope] = lane
    }

    private func pruneRecordedCounters(in lane: inout ReplayLane) {
        let minimumCounterToKeep: UInt64
        if lane.highestCounter > Self.windowSize {
            minimumCounterToKeep = lane.highestCounter - Self.windowSize + 1
        } else {
            minimumCounterToKeep = 1
        }
        lane.recordedCounters = lane.recordedCounters.filter { $0 >= minimumCounterToKeep }
    }
}

enum RemoteControlSecureEnvelope {
    static let overheadBytes = headerLength + tagLength

    private static let magic: UInt32 = 0x5342_5243 // "SBRC"
    private static let version: UInt8 = 1
    private static let headerLength = 52
    private static let tagLength = 16
    private static let epoch: UInt32 = 0
    private static let directionInitiatorToResponder: UInt8 = 1
    private static let directionResponderToInitiator: UInt8 = 2

    static func seal(
        _ plaintext: Data,
        keys: SessionKeys,
        packetType: RemoteControlSecurePacketType,
        counter: UInt64
    ) throws -> Data {
        guard counter > 0 else {
            throw RemoteControlSecureEnvelopeError.invalidCounter(counter)
        }
        let nonce = AES.GCM.Nonce()
        let nonceData = nonce.withUnsafeBytes { Data($0) }
        var header = Data()
        header.reserveCapacity(headerLength)
        appendUInt32(magic, to: &header)
        header.append(version)
        header.append(UInt8(headerLength))
        header.append(packetType.rawValue)
        header.append(sendDirection(for: keys))
        appendUInt64(sessionIdHash(keys.sessionId), to: &header)
        appendUInt64(transcriptPrefix(keys.transcriptHash), to: &header)
        appendUInt32(epoch, to: &header)
        appendUInt64(counter, to: &header)
        appendUInt32(UInt32(plaintext.count), to: &header)
        header.append(nonceData)
        precondition(header.count == headerLength)

        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keys.sendKey),
            nonce: nonce,
            authenticating: header
        )
        var output = header
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }

    static func open(
        _ packet: Data,
        keys: SessionKeys,
        allowedPacketTypes: Set<RemoteControlSecurePacketType>
    ) throws -> RemoteControlSecureOpenedPayload {
        let parsed = try parseHeader(packet)
        guard allowedPacketTypes.contains(parsed.packetType) else {
            throw RemoteControlSecureEnvelopeError.packetTypeMismatch(
                expected: Array(allowedPacketTypes).sorted { $0.rawValue < $1.rawValue },
                actual: parsed.packetType
            )
        }
        let expectedDirection = receiveDirection(for: keys)
        guard parsed.direction == expectedDirection else {
            throw RemoteControlSecureEnvelopeError.directionMismatch(expected: expectedDirection, actual: parsed.direction)
        }
        let expectedSessionHash = sessionIdHash(keys.sessionId)
        guard parsed.sessionHash == expectedSessionHash else {
            throw RemoteControlSecureEnvelopeError.sessionMismatch(expected: expectedSessionHash, actual: parsed.sessionHash)
        }
        let expectedTranscriptPrefix = transcriptPrefix(keys.transcriptHash)
        guard parsed.transcriptPrefix == expectedTranscriptPrefix else {
            throw RemoteControlSecureEnvelopeError.transcriptMismatch(
                expected: expectedTranscriptPrefix,
                actual: parsed.transcriptPrefix
            )
        }
        guard parsed.epoch == epoch else {
            throw RemoteControlSecureEnvelopeError.epochMismatch(expected: epoch, actual: parsed.epoch)
        }
        guard parsed.counter > 0 else {
            throw RemoteControlSecureEnvelopeError.invalidCounter(parsed.counter)
        }

        let ciphertextStart = packet.startIndex + headerLength
        let ciphertextEnd = ciphertextStart + parsed.payloadLength
        let ciphertext = packet[ciphertextStart..<ciphertextEnd]
        let tag = packet[packet.index(packet.endIndex, offsetBy: -tagLength)..<packet.endIndex]
        let nonce = try AES.GCM.Nonce(data: parsed.nonce)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        do {
            let payload = try AES.GCM.open(
                box,
                using: SymmetricKey(data: keys.receiveKey),
                authenticating: packet.prefix(headerLength)
            )
            return RemoteControlSecureOpenedPayload(
                packetType: parsed.packetType,
                direction: parsed.direction,
                sessionHash: parsed.sessionHash,
                transcriptPrefix: parsed.transcriptPrefix,
                epoch: parsed.epoch,
                counter: parsed.counter,
                payload: payload
            )
        } catch {
            throw RemoteControlSecureEnvelopeError.authenticationFailed(
                packetType: parsed.packetType,
                counter: parsed.counter
            )
        }
    }

    private struct ParsedHeader {
        let packetType: RemoteControlSecurePacketType
        let direction: UInt8
        let sessionHash: UInt64
        let transcriptPrefix: UInt64
        let epoch: UInt32
        let counter: UInt64
        let payloadLength: Int
        let nonce: Data
    }

    private static func parseHeader(_ packet: Data) throws -> ParsedHeader {
        guard packet.count >= headerLength + tagLength else {
            throw RemoteControlSecureEnvelopeError.malformed
        }
        let magic = readUInt32(packet, at: 0)
        guard magic == self.magic else {
            throw RemoteControlSecureEnvelopeError.unsupportedMagic(magic)
        }
        let version = packet[packet.startIndex + 4]
        guard version == self.version else {
            throw RemoteControlSecureEnvelopeError.unsupportedVersion(version)
        }
        let encodedHeaderLength = Int(packet[packet.startIndex + 5])
        guard encodedHeaderLength == headerLength else {
            throw RemoteControlSecureEnvelopeError.malformed
        }
        let packetTypeRaw = packet[packet.startIndex + 6]
        guard let packetType = RemoteControlSecurePacketType(rawValue: packetTypeRaw) else {
            throw RemoteControlSecureEnvelopeError.unsupportedPacketType(packetTypeRaw)
        }
        let payloadLength = Int(readUInt32(packet, at: 36))
        guard packet.count == headerLength + payloadLength + tagLength else {
            throw RemoteControlSecureEnvelopeError.malformed
        }
        return ParsedHeader(
            packetType: packetType,
            direction: packet[packet.startIndex + 7],
            sessionHash: readUInt64(packet, at: 8),
            transcriptPrefix: readUInt64(packet, at: 16),
            epoch: readUInt32(packet, at: 24),
            counter: readUInt64(packet, at: 28),
            payloadLength: payloadLength,
            nonce: Data(packet[(packet.startIndex + 40)..<(packet.startIndex + 52)])
        )
    }

    private static func sendDirection(for keys: SessionKeys) -> UInt8 {
        keys.role == .initiator ? directionInitiatorToResponder : directionResponderToInitiator
    }

    private static func receiveDirection(for keys: SessionKeys) -> UInt8 {
        keys.role == .initiator ? directionResponderToInitiator : directionInitiatorToResponder
    }

    private static func sessionIdHash(_ sessionId: String) -> UInt64 {
        var input = Data("SkyBridge-RemoteControl-Session-v1|".utf8)
        input.append(Data(sessionId.utf8))
        return firstUInt64(of: SHA256.hash(data: input))
    }

    private static func transcriptPrefix(_ transcriptHash: Data) -> UInt64 {
        var input = Data("SkyBridge-RemoteControl-Transcript-v1|".utf8)
        input.append(transcriptHash)
        return firstUInt64(of: SHA256.hash(data: input))
    }

    private static func firstUInt64<D: Sequence>(of digest: D) -> UInt64 where D.Element == UInt8 {
        digest.prefix(8).reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
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
