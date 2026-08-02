//
// PairingIdentityExchangeReplyThrottle.swift
// Skybridge-Compass
//
// Reply throttle helpers for pairing identity exchange messages.
//

import CryptoKit
import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct PairingIdentityExchangeReplyThrottleState: Equatable, Sendable {
    let requestKey: String
    let repliedAt: Date
}

@available(macOS 14.0, iOS 17.0, *)
extension P2PDiscoveryService {
    nonisolated static func shouldSendPairingIdentityExchangeReply(
        lastSentAt: Date?,
        now: Date = Date(),
        minimumInterval: TimeInterval = 10
    ) -> Bool {
        guard let lastSentAt else { return true }
        return now.timeIntervalSince(lastSentAt) >= minimumInterval
    }

    nonisolated static func shouldSendPairingIdentityExchangeReply(
        lastReply: PairingIdentityExchangeReplyThrottleState?,
        requestKey: String,
        now: Date = Date(),
        minimumInterval: TimeInterval = 10
    ) -> Bool {
        guard let lastReply else { return true }
        if lastReply.requestKey != requestKey { return true }
        return now.timeIntervalSince(lastReply.repliedAt) >= minimumInterval
    }

    nonisolated static func pairingIdentityExchangeRequestKey(
        _ payload: AppMessage.PairingIdentityExchangePayload
    ) -> String {
        var material = Data("SkyBridge-PIE-ReplyThrottle-v1\n".utf8)

        func append(_ string: String) {
            let data = Data(string.utf8)
            var length = UInt32(data.count).littleEndian
            material.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
            material.append(data)
        }

        func append(_ data: Data) {
            var length = UInt32(data.count).littleEndian
            material.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
            material.append(data)
        }

        append(payload.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())

        for key in payload.kemPublicKeys.sorted(by: { $0.suiteWireId < $1.suiteWireId }) {
            var wireId = key.suiteWireId.littleEndian
            material.append(Data(bytes: &wireId, count: MemoryLayout<UInt16>.size))
            append(Data(SHA256.hash(data: key.publicKey)))
        }

        for key in AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(payload.protocolIdentityPublicKeys) ?? [] {
            append(key.protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            append(key.authoritativeFingerprint?.lowercased() ?? "")
        }

        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}
