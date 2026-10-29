import Foundation

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
        guard let openedPayload = try? openScreenChannelPayload(payload, keys: keys) else {
            return nil
        }
        return decodeScreenChannelPayload(openedPayload)
    }

    nonisolated static func decodeEncryptedScreenChannelPayload(
        _ payload: Data,
        keys: SessionKeys
    ) throws -> ScreenData? {
        let openedPayload = try openScreenChannelPayload(payload, keys: keys)
        return decodeScreenChannelPayload(openedPayload)
    }

    nonisolated static func openScreenChannelPayload(
        _ payload: Data,
        with keys: SessionKeys
    ) throws -> WebRTCAppSecureOpenedPayload {
        try openScreenChannelPayload(payload, keys: keys)
    }

    nonisolated static func openScreenChannelPayload(
        _ payload: Data,
        keys: SessionKeys
    ) throws -> WebRTCAppSecureOpenedPayload {
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc-screen")
        return try WebRTCAppSecureEnvelope.open(
            trafficUnwrapped,
            keys: keys,
            allowedPacketTypes: [.remoteDesktop]
        )
    }

    nonisolated static func decodeScreenChannelPayload(
        _ openedPayload: WebRTCAppSecureOpenedPayload
    ) -> ScreenData? {
        guard openedPayload.packetType == .remoteDesktop else {
            return nil
        }
        return decodeScreenDataPayload(openedPayload.payload)
    }

    nonisolated static func openDirectControlProbePayload(
        _ payload: Data,
        keys: SessionKeys
    ) -> WebRTCAppSecureOpenedPayload? {
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc")
        return try? WebRTCAppSecureEnvelope.open(
            trafficUnwrapped,
            keys: keys,
            allowedPacketTypes: [.appControl, .remoteDesktop, .remoteDesktopAudio]
        )
    }
}
