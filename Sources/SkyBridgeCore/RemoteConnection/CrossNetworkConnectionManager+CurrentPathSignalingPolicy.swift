import Foundation
import SkyBridgeProtocolCore

extension CrossNetworkConnectionManager {
    nonisolated static func validatedSignalingWebSocketPath(_ rawPath: String?) throws -> String {
        try CurrentPathSignalingWebSocketPolicy.validatedWebSocketPath(rawPath)
    }

    nonisolated public static func currentPathSignalingWebSocketURL(
        signalingServerOrigin: String,
        wsPath: String?,
        sessionID: String,
        sessionToken: String,
        clientVersion: String,
        protocolVersion: String
    ) -> URL? {
        CurrentPathSignalingWebSocketPolicy.webSocketURL(
            signalingServerOrigin: signalingServerOrigin,
            wsPath: wsPath,
            sessionID: sessionID,
            sessionToken: sessionToken,
            clientVersion: clientVersion,
            protocolVersion: protocolVersion,
            credentialTransport: .headers
        )
    }

    nonisolated public static func currentPathSignalingWebSocketHeaders(
        sessionID: String,
        sessionToken: String,
        clientVersion: String,
        protocolVersion: String
    ) -> [String: String]? {
        CurrentPathSignalingWebSocketPolicy.webSocketHeaders(
            sessionID: sessionID,
            sessionToken: sessionToken,
            clientVersion: clientVersion,
            protocolVersion: protocolVersion,
            credentialTransport: .headers
        )
    }
}
