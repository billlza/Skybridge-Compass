import Foundation
import SkyBridgeProtocolCore

enum StrictPQCAdmissionRejection: Equatable, Sendable {
    case peerOfferedClassicOnly
    case localPQCUnavailable

    var diagnosticMessage: String {
        switch self {
        case .peerOfferedClassicOnly:
            return "strictPQC rejected classic-only bootstrap path"
        case .localPQCUnavailable:
            return "strictPQC requires a local PQC responder; classic bootstrap fallback is not allowed"
        }
    }
}

enum StrictPQCAdmissionGate {
    static func inboundRejection(
        policy: HandshakePolicy,
        peerSupportedSuites: [CryptoSuite],
        localPQCSuitesAvailable: Bool
    ) -> StrictPQCAdmissionRejection? {
        guard policy.requirePQC else { return nil }
        guard peerSupportedSuites.contains(where: { $0.isPQCGroup && $0.isNegotiable }) else {
            return .peerOfferedClassicOnly
        }
        guard localPQCSuitesAvailable else {
            return .localPQCUnavailable
        }
        return nil
    }
}
