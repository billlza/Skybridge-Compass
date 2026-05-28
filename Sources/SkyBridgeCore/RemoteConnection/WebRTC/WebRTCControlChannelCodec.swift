import CryptoKit
import Foundation
import SkyBridgeProtocolCore

enum WebRTCAppSecurePacketType: UInt8, Sendable, Hashable, CaseIterable {
    case appControl = 1
    case fileTransfer = 2
    case remoteControl = 3
    case remoteDesktop = 4
    case remoteDesktopAudio = 5
}

struct WebRTCAppSecureOpenedPayload: Sendable {
    let packetType: WebRTCAppSecurePacketType
    let direction: UInt8
    let sessionHash: UInt64
    let transcriptPrefix: UInt64
    let epoch: UInt32
    let counter: UInt64
    let payload: Data
}

enum WebRTCAppSecureReplayRejectionReason: String, Sendable {
    case duplicateCounter = "duplicate-counter"
    case counterOutsideWindow = "counter-outside-window"
}

enum WebRTCAppSecureEnvelopeError: Error, LocalizedError, Equatable {
    case malformed
    case unsupportedMagic(UInt32)
    case unsupportedVersion(UInt8)
    case unsupportedPacketType(UInt8)
    case packetTypeMismatch(expected: [WebRTCAppSecurePacketType], actual: WebRTCAppSecurePacketType)
    case directionMismatch(expected: UInt8, actual: UInt8)
    case sessionMismatch(expected: UInt64, actual: UInt64)
    case transcriptMismatch(expected: UInt64, actual: UInt64)
    case epochMismatch(expected: UInt32, actual: UInt32)
    case authenticationFailed(packetType: WebRTCAppSecurePacketType, counter: UInt64)
    case invalidCounter(UInt64)
    case counterExhausted
    case replayDetected(
        packetType: WebRTCAppSecurePacketType,
        counter: UInt64,
        highestCounter: UInt64,
        reason: WebRTCAppSecureReplayRejectionReason
    )

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "malformed WebRTC secure envelope"
        case .unsupportedMagic(let magic):
            return "unsupported WebRTC secure envelope magic=\(magic)"
        case .unsupportedVersion(let version):
            return "unsupported WebRTC secure envelope version=\(version)"
        case .unsupportedPacketType(let raw):
            return "unsupported WebRTC secure envelope packetType=\(raw)"
        case .packetTypeMismatch(let expected, let actual):
            let expectedRaw = expected.map { String($0.rawValue) }.joined(separator: ",")
            return "WebRTC secure envelope packetType mismatch expected=\(expectedRaw) actual=\(actual.rawValue)"
        case .directionMismatch(let expected, let actual):
            return "WebRTC secure envelope direction mismatch expected=\(expected) actual=\(actual)"
        case .sessionMismatch(let expected, let actual):
            return "WebRTC secure envelope session mismatch expected=\(expected) actual=\(actual)"
        case .transcriptMismatch(let expected, let actual):
            return "WebRTC secure envelope transcript mismatch expected=\(expected) actual=\(actual)"
        case .epochMismatch(let expected, let actual):
            return "WebRTC secure envelope epoch mismatch expected=\(expected) actual=\(actual)"
        case .authenticationFailed(let packetType, let counter):
            return "WebRTC secure envelope authentication failed packetType=\(packetType.rawValue) counter=\(counter)"
        case .invalidCounter(let counter):
            return "WebRTC secure envelope invalid counter=\(counter)"
        case .counterExhausted:
            return "WebRTC secure envelope counter exhausted"
        case .replayDetected(let packetType, let counter, let highestCounter, let reason):
            return "WebRTC secure envelope replay detected packetType=\(packetType.rawValue) counter=\(counter) highestCounter=\(highestCounter) reason=\(reason.rawValue)"
        }
    }
}

struct WebRTCAppSecureReplayWindow: Sendable {
    private struct ReplayScope: Hashable, Sendable {
        let packetType: WebRTCAppSecurePacketType
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

    mutating func validateAndRecord(_ openedPayload: WebRTCAppSecureOpenedPayload) throws {
        guard openedPayload.counter > 0 else {
            throw WebRTCAppSecureEnvelopeError.invalidCounter(openedPayload.counter)
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
            throw WebRTCAppSecureEnvelopeError.replayDetected(
                packetType: openedPayload.packetType,
                counter: openedPayload.counter,
                highestCounter: highestCounter,
                reason: .counterOutsideWindow
            )
        }
        guard !lane.recordedCounters.contains(openedPayload.counter) else {
            throw WebRTCAppSecureEnvelopeError.replayDetected(
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

enum WebRTCAppSecureEnvelope {
    static let overheadBytes = headerLength + tagLength

    private static let magic: UInt32 = 0x5342_5743 // "SBWC"
    private static let version: UInt8 = 1
    private static let headerLength = 52
    private static let tagLength = 16
    private static let epoch: UInt32 = 0
    private static let directionInitiatorToResponder: UInt8 = 1
    private static let directionResponderToInitiator: UInt8 = 2

    static func seal(
        _ plaintext: Data,
        keys: SessionKeys,
        packetType: WebRTCAppSecurePacketType,
        counter: UInt64
    ) throws -> Data {
        guard counter > 0 else {
            throw WebRTCAppSecureEnvelopeError.invalidCounter(counter)
        }
        guard plaintext.count <= Int(UInt32.max) else {
            throw WebRTCAppSecureEnvelopeError.malformed
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
        allowedPacketTypes: Set<WebRTCAppSecurePacketType>
    ) throws -> WebRTCAppSecureOpenedPayload {
        let parsed = try parseHeader(packet)
        guard allowedPacketTypes.contains(parsed.packetType) else {
            throw WebRTCAppSecureEnvelopeError.packetTypeMismatch(
                expected: Array(allowedPacketTypes).sorted { $0.rawValue < $1.rawValue },
                actual: parsed.packetType
            )
        }
        let expectedDirection = receiveDirection(for: keys)
        guard parsed.direction == expectedDirection else {
            throw WebRTCAppSecureEnvelopeError.directionMismatch(expected: expectedDirection, actual: parsed.direction)
        }
        let expectedSessionHash = sessionIdHash(keys.sessionId)
        guard parsed.sessionHash == expectedSessionHash else {
            throw WebRTCAppSecureEnvelopeError.sessionMismatch(expected: expectedSessionHash, actual: parsed.sessionHash)
        }
        let expectedTranscriptPrefix = transcriptPrefix(keys.transcriptHash)
        guard parsed.transcriptPrefix == expectedTranscriptPrefix else {
            throw WebRTCAppSecureEnvelopeError.transcriptMismatch(
                expected: expectedTranscriptPrefix,
                actual: parsed.transcriptPrefix
            )
        }
        guard parsed.epoch == epoch else {
            throw WebRTCAppSecureEnvelopeError.epochMismatch(expected: epoch, actual: parsed.epoch)
        }
        guard parsed.counter > 0 else {
            throw WebRTCAppSecureEnvelopeError.invalidCounter(parsed.counter)
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
            return WebRTCAppSecureOpenedPayload(
                packetType: parsed.packetType,
                direction: parsed.direction,
                sessionHash: parsed.sessionHash,
                transcriptPrefix: parsed.transcriptPrefix,
                epoch: parsed.epoch,
                counter: parsed.counter,
                payload: payload
            )
        } catch {
            throw WebRTCAppSecureEnvelopeError.authenticationFailed(
                packetType: parsed.packetType,
                counter: parsed.counter
            )
        }
    }

    private struct ParsedHeader {
        let packetType: WebRTCAppSecurePacketType
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
            throw WebRTCAppSecureEnvelopeError.malformed
        }
        let magic = readUInt32(packet, at: 0)
        guard magic == self.magic else {
            throw WebRTCAppSecureEnvelopeError.unsupportedMagic(magic)
        }
        let version = packet[packet.startIndex + 4]
        guard version == self.version else {
            throw WebRTCAppSecureEnvelopeError.unsupportedVersion(version)
        }
        let encodedHeaderLength = Int(packet[packet.startIndex + 5])
        guard encodedHeaderLength == headerLength else {
            throw WebRTCAppSecureEnvelopeError.malformed
        }
        let packetTypeRaw = packet[packet.startIndex + 6]
        guard let packetType = WebRTCAppSecurePacketType(rawValue: packetTypeRaw) else {
            throw WebRTCAppSecureEnvelopeError.unsupportedPacketType(packetTypeRaw)
        }
        let payloadLength = Int(readUInt32(packet, at: 36))
        guard packet.count == headerLength + payloadLength + tagLength else {
            throw WebRTCAppSecureEnvelopeError.malformed
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
        var input = Data("SkyBridge-WebRTC-App-Session-v1|".utf8)
        input.append(Data(sessionId.utf8))
        return firstUInt64(of: SHA256.hash(data: input))
    }

    private static func transcriptPrefix(_ transcriptHash: Data) -> UInt64 {
        var input = Data("SkyBridge-WebRTC-App-Transcript-v1|".utf8)
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

enum WebRTCControlChannelCodec {
    static func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
        let frame = HandshakePadding.unwrapIfNeeded(data, label: "rx/webrtc")
        if frame.count == 38, (try? HandshakeFinished.decode(from: frame)) != nil { return true }
        guard frame.count >= 5 else { return false }
        guard frame.first == HandshakeConstants.protocolVersion else { return false }
        if (try? HandshakeMessageA.decode(from: frame)) != nil { return true }
        if (try? HandshakeMessageB.decode(from: frame)) != nil { return true }
        return false
    }

    static func isActiveHandshakeDriverFrame(_ data: Data) -> Bool {
        let frame = HandshakePadding.unwrapIfNeeded(data, label: "rx/webrtc")
        if isLikelyHandshakeControlPacket(frame) { return true }
        return false
    }

    static func encryptAppPayload(
        _ plaintext: Data,
        with keys: SessionKeys,
        packetType: WebRTCAppSecurePacketType = .appControl,
        counter: UInt64
    ) throws -> Data {
        try WebRTCAppSecureEnvelope.seal(
            plaintext,
            keys: keys,
            packetType: packetType,
            counter: counter
        )
    }

    static func decryptAppPayload(
        _ ciphertext: Data,
        with keys: SessionKeys,
        allowedPacketTypes: Set<WebRTCAppSecurePacketType> = Set(WebRTCAppSecurePacketType.allCases)
    ) throws -> WebRTCAppSecureOpenedPayload {
        try WebRTCAppSecureEnvelope.open(
            ciphertext,
            keys: keys,
            allowedPacketTypes: allowedPacketTypes
        )
    }

    static func decodeCompatibilityAppMessage(_ plaintext: Data) -> AppMessage? {
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(AppMessage.self, from: plaintext) {
            return direct
        }

        guard let fallback = try? decoder.decode(PlainEnvelope.self, from: plaintext) else {
            return nil
        }
        if let payload = fallback.clipboard {
            return .clipboard(payload)
        }
        if let payload = fallback.pairingIdentityExchange {
            return .pairingIdentityExchange(payload)
        }
        if let payload = fallback.heartbeat {
            return .heartbeat(payload)
        }
        if let payload = fallback.ping {
            return .ping(payload)
        }
        if let payload = fallback.pong {
            return .pong(payload)
        }
        return nil
    }

    static func bootstrapAppMessageKind(_ message: AppMessage) -> String {
        switch message {
        case .clipboard:
            return "clipboard"
        case .pairingIdentityExchange:
            return "pairingIdentityExchange"
        case .kemRefreshRequest:
            return "kemRefreshRequest"
        case .signedKEMRefresh:
            return "signedKEMRefresh"
        case .kemRefreshFailure:
            return "kemRefreshFailure"
        case .protocolIdentityBindingRequest:
            return "protocolIdentityBindingRequest"
        case .signedProtocolIdentityBinding:
            return "signedProtocolIdentityBinding"
        case .heartbeat:
            return "heartbeat"
        case .peerDisconnecting:
            return "peerDisconnecting"
        case .ping:
            return "ping"
        case .pong:
            return "pong"
        }
    }

    static func orderedUniqueCandidateIds(_ rawValues: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in rawValues {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }
        return ordered
    }

    static func pairingExchangeFingerprint(_ payload: AppMessage.PairingIdentityExchangePayload) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(payload.deviceId.utf8))
        for key in payload.kemPublicKeys.sorted(by: { $0.suiteWireId < $1.suiteWireId }) {
            hasher.update(data: Data("\(key.suiteWireId)".utf8))
            hasher.update(data: key.publicKey)
        }
        for key in (AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(payload.protocolIdentityPublicKeys) ?? []) {
            hasher.update(data: Data(key.protocolSigningAlgorithm.utf8))
            hasher.update(data: key.publicKey)
        }
        for format in (payload.remoteVideoFormats ?? []).map({ $0.lowercased() }).sorted() {
            hasher.update(data: Data(format.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct PlainEnvelope: Decodable {
        let clipboard: AppMessage.ClipboardPayload?
        let pairingIdentityExchange: AppMessage.PairingIdentityExchangePayload?
        let heartbeat: AppMessage.HeartbeatPayload?
        let ping: AppMessage.PingPayload?
        let pong: AppMessage.PongPayload?
    }
}
