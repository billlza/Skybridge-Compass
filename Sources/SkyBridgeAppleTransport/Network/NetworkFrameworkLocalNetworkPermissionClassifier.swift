import Foundation
import Network
import SkyBridgeProtocolCore
import dnssd

/// Converts Network.framework's Local Network privacy signals into one stable
/// product-level decision. Callers remain responsible for choosing their own
/// domain error and user-facing recovery action.
public enum NetworkFrameworkLocalNetworkPermissionClassifier {
    public nonisolated static func isDenied(error: NWError, path: NWPath?) -> Bool {
        if isDenied(path: path) {
            return true
        }
        if case .dns(let code) = error,
           code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            return true
        }
        return isDenied(
            errorDescriptions: [
                String(describing: error),
                (error as NSError).localizedDescription
            ]
        )
    }

    public nonisolated static func isDenied(path: NWPath?) -> Bool {
        if #available(macOS 11.0, iOS 14.0, *) {
            return ApplePeerConnectivityPolicy.isLocalNetworkPermissionDenied(
                pathReason: sharedPathReason(path?.unsatisfiedReason),
                errorDescriptions: []
            )
        }
        return false
    }

    @available(macOS 11.0, iOS 14.0, *)
    public nonisolated static func isDenied(
        unsatisfiedReason: NWPath.UnsatisfiedReason?
    ) -> Bool {
        ApplePeerConnectivityPolicy.isLocalNetworkPermissionDenied(
            pathReason: sharedPathReason(unsatisfiedReason),
            errorDescriptions: []
        )
    }

    public nonisolated static func isDenied(errorDescriptions: [String]) -> Bool {
        ApplePeerConnectivityPolicy.isLocalNetworkPermissionDenied(
            pathReason: nil,
            errorDescriptions: errorDescriptions
        )
    }

    @available(macOS 11.0, iOS 14.0, *)
    public nonisolated static func sharedPathReason(
        _ reason: NWPath.UnsatisfiedReason?
    ) -> ApplePeerConnectivityPolicy.PathUnsatisfiedReason? {
        guard let reason else { return nil }
        switch reason {
        case .notAvailable:
            return .notAvailable
        case .cellularDenied:
            return .cellularDenied
        case .wifiDenied:
            return .wifiDenied
        case .localNetworkDenied:
            return .localNetworkDenied
        case .vpnInactive:
            return .vpnInactive
        @unknown default:
            return .unknown
        }
    }
}
