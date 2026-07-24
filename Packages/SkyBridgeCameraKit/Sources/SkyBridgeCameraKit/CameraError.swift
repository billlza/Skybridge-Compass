import Foundation

public enum SkyBridgeCameraError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint(String)
    case unsupportedScheme(String)
    case credentialsInURLForbidden
    case endpointNotLocal
    case basicAuthenticationRequiresTLS
    case responseHeaderTooLarge(limit: Int)
    case responseBodyTooLarge(limit: Int)
    case sdpTooLarge(limit: Int)
    case malformedResponse(String)
    case malformedSDP(String)
    case unsupportedMedia(String)
    case unsupportedAuthentication(String)
    case credentialsMissing
    case authenticationRejected
    case malformedRTP(String)
    case rtpSequenceDiscontinuity(expected: UInt16, actual: UInt16)
    case accessUnitTooLarge(limit: Int)
    case transportFailed(String)
    case timedOut(String)
    case unexpectedStatus(code: Int, reason: String)
    case missingSession
    case streamEnded
    case cancelled
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpoint(reason):
            "Invalid camera endpoint: \(reason)"
        case let .unsupportedScheme(scheme):
            "Unsupported camera endpoint scheme: \(scheme)"
        case .credentialsInURLForbidden:
            "Credentials must not be embedded in a camera URL."
        case .endpointNotLocal:
            "Camera endpoint is not an allowed private IP literal."
        case .basicAuthenticationRequiresTLS:
            "Basic authentication is only allowed over RTSPS."
        case let .responseHeaderTooLarge(limit):
            "RTSP response headers exceed the \(limit)-byte limit."
        case let .responseBodyTooLarge(limit):
            "RTSP response body exceeds the \(limit)-byte limit."
        case let .sdpTooLarge(limit):
            "SDP exceeds the \(limit)-byte limit."
        case let .malformedResponse(reason):
            "Malformed RTSP response: \(reason)"
        case let .malformedSDP(reason):
            "Malformed SDP: \(reason)"
        case let .unsupportedMedia(reason):
            "Unsupported camera media: \(reason)"
        case let .unsupportedAuthentication(reason):
            "Unsupported RTSP authentication: \(reason)"
        case .credentialsMissing:
            "The camera requires credentials."
        case .authenticationRejected:
            "The camera rejected the supplied credentials."
        case let .malformedRTP(reason):
            "Malformed RTP/H.264 data: \(reason)"
        case let .rtpSequenceDiscontinuity(expected, actual):
            "RTP sequence discontinuity: expected \(expected), received \(actual)."
        case let .accessUnitTooLarge(limit):
            "H.264 access unit exceeds the \(limit)-byte limit."
        case let .transportFailed(reason):
            "RTSP transport failed: \(reason)"
        case let .timedOut(stage):
            "RTSP operation timed out while \(stage)."
        case let .unexpectedStatus(code, reason):
            "Unexpected RTSP status \(code): \(reason)"
        case .missingSession:
            "RTSP SETUP response did not contain a valid Session header."
        case .streamEnded:
            "The RTSP connection ended unexpectedly."
        case .cancelled:
            "The RTSP operation was cancelled."
        case let .invalidState(reason):
            "Invalid RTSP client state: \(reason)"
        }
    }
}
