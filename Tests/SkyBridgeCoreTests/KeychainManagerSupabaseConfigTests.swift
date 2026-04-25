import Foundation
import Testing
@testable import SkyBridgeCore

@Suite("KeychainManager Supabase Config Tests", .serialized)
struct KeychainManagerSupabaseConfigTests {
    @Test("Supabase client config strips legacy service-role storage on write")
    func testStoreSupabaseConfigPurgesLegacyServiceRoleKey() throws {
        guard #available(macOS 14.0, *) else { return }

        let keychain = KeychainManager.shared
        try clearSupabaseEntries(using: keychain)

        #expect(
            keychain.importKey(
                data: Data("legacy-service-role".utf8),
                service: "SkyBridge.Supabase",
                account: "ServiceRoleKey"
            )
        )

        try keychain.storeSupabaseConfig(
            url: " https://example.supabase.co ",
            anonKey: " anon-key "
        )

        let config = try keychain.retrieveSupabaseConfig()
        #expect(config.url == "https://example.supabase.co")
        #expect(config.anonKey == "anon-key")
        #expect(keychain.exportKey(service: "SkyBridge.Supabase", account: "ServiceRoleKey") == nil)

        try clearSupabaseEntries(using: keychain)
    }

    @Test("Supabase client config strips legacy service-role storage on read")
    func testRetrieveSupabaseConfigPurgesLegacyServiceRoleKey() throws {
        guard #available(macOS 14.0, *) else { return }

        let keychain = KeychainManager.shared
        try clearSupabaseEntries(using: keychain)

        #expect(
            keychain.importKey(
                data: Data("https://example.supabase.co".utf8),
                service: "SkyBridge.Supabase",
                account: "URL"
            )
        )
        #expect(
            keychain.importKey(
                data: Data("anon-key".utf8),
                service: "SkyBridge.Supabase",
                account: "AnonKey"
            )
        )
        #expect(
            keychain.importKey(
                data: Data("legacy-service-role".utf8),
                service: "SkyBridge.Supabase",
                account: "ServiceRoleKey"
            )
        )

        _ = try keychain.retrieveSupabaseConfig()

        #expect(keychain.exportKey(service: "SkyBridge.Supabase", account: "ServiceRoleKey") == nil)

        try clearSupabaseEntries(using: keychain)
    }

    @Test("Supabase fromEnvironment does not synchronously read Keychain")
    func testSupabaseConfigurationFromEnvironmentDoesNotReadKeychain() throws {
        guard #available(macOS 14.0, *) else { return }

        let keychain = KeychainManager.shared
        try clearSupabaseEntries(using: keychain)

        let keychainURL = "https://keychain-only-startup-blocker.supabase.co"
        try keychain.storeSupabaseConfig(url: keychainURL, anonKey: "anon-key")

        #expect(SupabaseService.Configuration.fromKeychain()?.url.absoluteString == keychainURL)
        #expect(SupabaseService.Configuration.fromEnvironment()?.url.absoluteString != keychainURL)

        try clearSupabaseEntries(using: keychain)
    }

    private func clearSupabaseEntries(using keychain: KeychainManager) throws {
        try keychain.deleteAPIKey(service: "SkyBridge.Supabase", account: "URL")
        try keychain.deleteAPIKey(service: "SkyBridge.Supabase", account: "AnonKey")
        try keychain.deleteAPIKey(service: "SkyBridge.Supabase", account: "ServiceRoleKey")
    }
}
