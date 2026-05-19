import Foundation
import CryptoKit

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    enum RemoteDesktopControlPayloadDecodeResult: Sendable {
        case screen(ScreenData)
        case audio(RemoteDesktopAudioChunkPayload)
    }

    nonisolated static func decodeScreenDataPayload(_ plaintext: Data) -> ScreenData? {
        if let screenData = RemoteDesktopScreenFrameWire.decodeIfPresent(plaintext) {
            return screenData
        }

        if let msg = try? JSONDecoder().decode(RemoteMessage.self, from: plaintext),
           msg.type == .screenData {
            return try? JSONDecoder().decode(ScreenData.self, from: msg.payload)
        }

        return nil
    }

    nonisolated static func decodeRemoteDesktopHighThroughputPayload(
        _ plaintext: Data
    ) -> RemoteDesktopControlPayloadDecodeResult? {
        if let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(plaintext) {
            return .audio(audioChunk)
        }

        if let screenData = decodeScreenDataPayload(plaintext) {
            return .screen(screenData)
        }

        return nil
    }

    nonisolated static func decodeDirectScreenChannelPayload(
        _ payload: Data,
        keys: SessionKeys
    ) -> ScreenData? {
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc-screen")
        guard let plaintext = try? decryptScreenPayload(ciphertext: trafficUnwrapped, with: keys) else {
            return nil
        }
        return decodeScreenDataPayload(plaintext)
    }

    nonisolated static func decodeEncryptedScreenChannelPayload(
        _ payload: Data,
        keys: SessionKeys
    ) throws -> ScreenData? {
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc-screen")
        let plaintext = try decryptScreenPayload(ciphertext: trafficUnwrapped, with: keys)
        return decodeScreenDataPayload(plaintext)
    }

    nonisolated private static func decryptScreenPayload(
        ciphertext: Data,
        with keys: SessionKeys
    ) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    nonisolated static func decryptDirectControlProbePayload(
        _ payload: Data,
        keys: SessionKeys
    ) -> Data? {
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc")
        let key = SymmetricKey(data: keys.receiveKey)
        guard let box = try? AES.GCM.SealedBox(combined: trafficUnwrapped) else {
            return nil
        }
        return try? AES.GCM.open(box, using: key)
    }
}
