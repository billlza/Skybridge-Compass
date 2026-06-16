import Foundation

enum SkyBridgeRuntimeEnvironment {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_MODE")
    }

    static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    static var shouldSkipInteractiveStartup: Bool {
        isUITesting || isRunningUnderXCTest
    }

    static var shouldDisableAnimationsForUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_DISABLE_ANIMATIONS")
    }
}
