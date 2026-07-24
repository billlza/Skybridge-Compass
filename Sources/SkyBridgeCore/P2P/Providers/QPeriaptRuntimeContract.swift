import SkyBridgeProtocolCore
import SkyBridgeQPeriaptRuntime

/// Compatibility facade preserving SkyBridgeCore's historical error surface.
enum QPeriaptRuntimeContract {
    static let expectedABIVersion =
        SkyBridgeQPeriaptRuntime.QPeriaptRuntimeContract.expectedABIVersion
    static let expectedRuntimeVersion =
        SkyBridgeQPeriaptRuntime.QPeriaptRuntimeContract.expectedRuntimeVersion
    static let expectedSuiteID =
        SkyBridgeQPeriaptRuntime.QPeriaptRuntimeContract.expectedSuiteID

    static var isCompatible: Bool {
        SkyBridgeQPeriaptRuntime.QPeriaptRuntimeContract.isCompatible
    }

    static func requireCompatible() throws {
        do {
            try SkyBridgeQPeriaptRuntime.QPeriaptRuntimeContract.requireCompatible()
        } catch let error as QPeriaptRuntimeContractError {
            throw CryptoProviderError.operationFailed(error.localizedDescription)
        }
    }

    static func statusDescription(_ status: Int32) -> String {
        SkyBridgeQPeriaptRuntime.QPeriaptRuntimeContract.statusDescription(status)
    }
}
