import CryptoKit
import Foundation
import SkyBridgeProtocolCore

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

    static func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined ?? Data()
    }

    static func decryptAppPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
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
