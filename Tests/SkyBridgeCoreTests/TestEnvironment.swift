import Foundation

// Ensure tests use the in-memory keychain to avoid system keychain access.
private let testEnvironmentBootstrap: Int = {
    setenv("SKYBRIDGE_KEYCHAIN_IN_MEMORY", "1", 1)
    return 0
}()
