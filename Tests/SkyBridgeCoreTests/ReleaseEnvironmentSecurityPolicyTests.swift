import Foundation
import XCTest
@testable import SkyBridgeCore

final class ReleaseEnvironmentSecurityPolicyTests: XCTestCase {
    func testRemoteControlLegacyOverrideRequiresAnExplicitTestBuildValue() {
        #if DEBUG || SKYBRIDGE_TESTING
        for acceptedValue in ["1", "true", "TRUE", " yes "] {
            XCTAssertTrue(
                RemoteControlSOABindingPolicy.allowsInsecureLegacyRemoteControl(
                    environment: ["SKYBRIDGE_ALLOW_INSECURE_REMOTE_CONTROL": acceptedValue]
                )
            )
        }

        for rejectedValue in ["", "0", "false", "on", "unexpected"] {
            XCTAssertFalse(
                RemoteControlSOABindingPolicy.allowsInsecureLegacyRemoteControl(
                    environment: ["SKYBRIDGE_ALLOW_INSECURE_REMOTE_CONTROL": rejectedValue]
                )
            )
        }
        #else
        XCTAssertFalse(
            RemoteControlSOABindingPolicy.allowsInsecureLegacyRemoteControl(
                environment: ["SKYBRIDGE_ALLOW_INSECURE_REMOTE_CONTROL": "1"]
            ),
            "A production build must ignore the insecure remote-control launch override."
        )
        #endif
    }

    func testSecuritySensitiveEnvironmentBranchesHaveProductionCompileTimeFallbacks() throws {
        let remoteControl = try repositorySource(
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlSOABindingPolicy.swift"
        )
        let remoteControlPolicy = try sourceSlice(
            from: "static func allowsInsecureLegacyRemoteControl(environment:",
            to: "@available(macOS 14.0, iOS 17.0, *)",
            in: remoteControl
        )
        XCTAssertTrue(remoteControlPolicy.contains("#if DEBUG || SKYBRIDGE_TESTING"))
        XCTAssertTrue(remoteControlPolicy.contains("#else\n        // A launch environment"))
        XCTAssertTrue(remoteControlPolicy.contains("return false\n        #endif"))

        let handshake = try repositorySource("Sources/SkyBridgeCore/P2P/HandshakeContext.swift")
        let noncePolicy = try sourceSlice(
            from: "private static func fillRandomBytes",
            to: "// MARK: - Key Derivation",
            in: handshake
        )
        XCTAssertTrue(noncePolicy.contains("#if DEBUG || SKYBRIDGE_BENCHMARKING"))
        XCTAssertTrue(noncePolicy.contains("SKYBRIDGE_BENCH_DETERMINISTIC_NONCE"))
        XCTAssertTrue(noncePolicy.contains("SecRandomCopyBytes"))

        let keychain = try repositorySource("Sources/SkyBridgeCore/Security/KeychainManager.swift")
        try assertTestOnlyInMemoryPolicy(
            in: keychain,
            start: "private nonisolated static var useInMemoryKeychain",
            end: "private nonisolated(unsafe) static var inMemoryStore"
        )

        let identity = try repositorySource("Sources/SkyBridgeCore/P2P/DeviceIdentityKeyManager.swift")
        try assertTestOnlyInMemoryPolicy(
            in: identity,
            start: "private nonisolated static var useInMemoryKeychain",
            end: "private nonisolated(unsafe) static var inMemoryStore"
        )

        let secureEnclave = try repositorySource(
            "Sources/SkyBridgeCore/P2P/SecureEnclaveSigningCallback.swift"
        )
        try assertTestOnlyInMemoryPolicy(
            in: secureEnclave,
            start: "private static var useInMemoryKeychain",
            end: "/// 检查 Secure Enclave 是否可用"
        )

        let supabase = try repositorySource("Sources/SkyBridgeCore/Services/SupabaseService.swift")
        let supabasePolicy = try sourceSlice(
            from: "private static var usesTestOnlyInMemoryKeychain",
            to: "private func resolvedConfiguration",
            in: supabase
        )
        XCTAssertTrue(supabasePolicy.contains("#if DEBUG || SKYBRIDGE_TESTING"))
        XCTAssertTrue(supabasePolicy.contains("SKYBRIDGE_KEYCHAIN_IN_MEMORY"))
        XCTAssertTrue(supabasePolicy.contains("XCTestConfigurationFilePath"))
        XCTAssertTrue(supabasePolicy.contains("#else\n        return false\n        #endif"))

        let replayCache = try repositorySource("Sources/SkyBridgeCore/P2P/HandshakeReplayCache.swift")
        let replayPolicy = try sourceSlice(
            from: "private nonisolated static let disablePrune",
            to: "private var lastPrune",
            in: replayCache
        )
        XCTAssertTrue(
            replayPolicy.contains("#if DEBUG || SKYBRIDGE_TESTING || SKYBRIDGE_BENCHMARKING")
        )
        XCTAssertTrue(replayPolicy.contains("#else\n        // Product builds always retain"))
        XCTAssertTrue(replayPolicy.contains("return false\n        #endif"))
    }

    func testAppOnlySecurityOverridesAreCompileTimeGated() throws {
        let updateChecker = try repositorySource(
            "Sources/SkyBridgeCompassApp/Services/AppUpdateChecker.swift"
        )
        let productionInitializer = try sourceSlice(
            from: "init(\n        manifestURL:",
            to: "#if DEBUG || SKYBRIDGE_TESTING",
            in: updateChecker
        )
        XCTAssertFalse(productionInitializer.contains("trustedSigningKeys:"))
        XCTAssertTrue(productionInitializer.contains("Self.defaultTrustedSigningKeys()"))

        let manifestURLPolicy = try sourceSlice(
            from: "static func defaultManifestURL",
            to: "static func defaultTrustedSigningKeys",
            in: updateChecker
        )
        XCTAssertTrue(manifestURLPolicy.contains("#if DEBUG || SKYBRIDGE_TESTING"))
        XCTAssertTrue(manifestURLPolicy.contains("SKYBRIDGE_UPDATE_MANIFEST_URL"))
        XCTAssertTrue(manifestURLPolicy.contains("bundle.object(forInfoDictionaryKey:"))

        let trustPolicy = try sourceSlice(
            from: "static func defaultTrustedSigningKeys",
            to: "private static func parseTrustedSigningKeys",
            in: updateChecker
        )
        XCTAssertTrue(trustPolicy.contains("bundle.object(forInfoDictionaryKey:"))
        XCTAssertTrue(trustPolicy.contains("#if DEBUG || SKYBRIDGE_TESTING"))
        XCTAssertTrue(trustPolicy.contains("SKYBRIDGE_ALLOW_UPDATE_TRUST_OVERRIDE"))
        XCTAssertTrue(trustPolicy.contains("#else\n        return []\n        #endif"))

        let authentication = try repositorySource(
            "Sources/SkyBridgeCompassApp/AuthenticationViewModel.swift"
        )
        let authenticationPolicy = try sourceSlice(
            from: "private static var allowsRemoteRiskDegrade",
            to: "private func enforceLocalLoginThrottle",
            in: authentication
        )
        XCTAssertTrue(authenticationPolicy.contains("#if DEBUG || SKYBRIDGE_TESTING"))
        XCTAssertTrue(authenticationPolicy.contains("SKYBRIDGE_ALLOW_AUTH_RISK_DEGRADE"))
        XCTAssertTrue(authenticationPolicy.contains("#else\n        return false\n        #endif"))

        let registration = try repositorySource(
            "Sources/SkyBridgeCore/Services/RegistrationSecurityService.swift"
        )
        let persistencePolicy = try sourceSlice(
            from: "private static func makePersistenceURL",
            to: "private static func loadPersistedState",
            in: registration
        )
        XCTAssertTrue(persistencePolicy.contains("#if DEBUG || SKYBRIDGE_TESTING"))
        XCTAssertTrue(persistencePolicy.contains("SKYBRIDGE_REGISTRATION_SECURITY_STATE_PATH"))
        XCTAssertTrue(persistencePolicy.contains(".applicationSupportDirectory"))

        let paperEvaluation = try repositorySource("Scripts/run_paper_eval.sh")
        XCTAssertTrue(
            paperEvaluation.contains(
                "swift build -c release -Xswiftc -DSKYBRIDGE_BENCHMARKING --product HandshakeBenchRunner"
            )
        )
    }

    private func assertTestOnlyInMemoryPolicy(
        in source: String,
        start: String,
        end: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let policy = try sourceSlice(from: start, to: end, in: source)
        XCTAssertTrue(policy.contains("#if DEBUG || SKYBRIDGE_TESTING"), file: file, line: line)
        XCTAssertTrue(policy.contains("SKYBRIDGE_KEYCHAIN_IN_MEMORY"), file: file, line: line)
        XCTAssertTrue(policy.contains("XCTestConfigurationFilePath"), file: file, line: line)
        XCTAssertTrue(
            policy.contains("#else\n        return false\n        #endif"),
            file: file,
            line: line
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSlice(from start: String, to end: String, in source: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
