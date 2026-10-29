import SkyBridgeAppleTransport

/// Compatibility alias while Network.framework adapters migrate to the shared
/// Apple transport module. There is only one classifier implementation.
typealias NetworkFrameworkLocalNetworkPermissionClassifier =
    SkyBridgeAppleTransport.NetworkFrameworkLocalNetworkPermissionClassifier
