import Foundation

enum SkyBridgeRuntimeEnvironment {
    static var isUITesting: Bool {
#if DEBUG || SKYBRIDGE_TESTING
        ProcessInfo.processInfo.arguments.contains("UITEST_MODE")
#else
        false
#endif
    }

    static var isRunningUnderXCTest: Bool {
#if DEBUG || SKYBRIDGE_TESTING
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
#else
        false
#endif
    }

    static var shouldSkipInteractiveStartup: Bool {
        isUITesting || isRunningUnderXCTest
    }

    static var shouldDisableAnimationsForUITests: Bool {
#if DEBUG || SKYBRIDGE_TESTING
        ProcessInfo.processInfo.arguments.contains("UITEST_DISABLE_ANIMATIONS")
#else
        false
#endif
    }
}
