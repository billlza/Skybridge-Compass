import Foundation
import XCTest

final class AppleAIAdvisorySourceContractTests: XCTestCase {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func productionSwiftSources() throws -> [(relativePath: String, source: String)] {
        let roots = [
            "Sources",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources",
            "SkyBridge Compass iOS/Widgets",
            "SkyBridge Compass iOS/LocalPackages",
            "Scripts"
        ]
        var sources: [(relativePath: String, source: String)] = []
        for relativeRoot in roots {
            let sourceRoot = repositoryRoot().appendingPathComponent(relativeRoot)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw NSError(
                    domain: "AppleAIAdvisorySourceContractTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing production source root: \(relativeRoot)"]
                )
            }
            guard let enumerator = FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw NSError(
                    domain: "AppleAIAdvisorySourceContractTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to enumerate production source root: \(relativeRoot)"]
                )
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relativePath = url.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "")
                let source = try String(contentsOf: url, encoding: .utf8)
                sources.append((relativePath, source))
            }
        }
        XCTAssertFalse(sources.isEmpty, "AI advisory source-contract scan must not pass with an empty source set.")
        return sources.sorted { $0.relativePath < $1.relativePath }
    }

    private func nonCommentMatches(
        in source: String,
        relativePath: String,
        tokens: [String]
    ) -> [String] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else {
                    return nil
                }
                guard let token = tokens.first(where: { trimmed.contains($0) }) else {
                    return nil
                }
                return "\(relativePath):\(index + 1):\(token):\(trimmed)"
            }
    }

    func testFoundationModelsAndCoreAIHaveNoProductionEntrypointWithoutSanitizedAdvisoryAdapter() throws {
        let appleAIFrameworkTokens = [
            "import FoundationModels",
            "import CoreAI",
            "canImport(FoundationModels)",
            "canImport(CoreAI)",
            "SystemLanguageModel",
            "LanguageModelSession",
            "GeneratedContent",
            "PrivateCloudCompute",
            "HAS_APPLE_AI_ADVISORY_SDK"
        ]
        let productionReferences = try productionSwiftSources().flatMap { relativePath, source in
            nonCommentMatches(in: source, relativePath: relativePath, tokens: appleAIFrameworkTokens)
        }
        let integrationFiles = [
            "Package.swift",
            "project.yml",
            "SkyBridge Compass iOS/Package.swift",
            "SkyBridge Compass iOS/project.yml",
            "SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj/project.pbxproj"
        ]
        let integrationReferences = try integrationFiles.flatMap { relativePath -> [String] in
            let source = try readSource(relativePath)
            return appleAIFrameworkTokens.compactMap { token in
                source.contains(token) ? "\(relativePath):\(token)" : nil
            }
        }

        XCTAssertTrue(
            productionReferences.isEmpty && integrationReferences.isEmpty,
            "FoundationModels/CoreAI/PCC entrypoints require a redacted advisory adapter, availability guard, privacy tests, and this source-contract allowlist update first: \((productionReferences + integrationReferences).joined(separator: ", "))"
        )
    }

    func testAIAdvisoryBoundaryCannotReferenceAuthorityMutationAPIs() throws {
        let forbiddenAuthorityTokens = [
            "autoBlockCritical",
            "onCriticalAnomaly",
            "trustDevice(",
            "TrustSyncService",
            "addTrustRecord",
            "recordAuthenticatedRemoteAuthority",
            "revokeTrustRecord",
            "PairingTrustApprovalService",
            "ConnectionApprovalService",
            "approveRequest(",
            "StrictPQCAdmissionGate",
            "SignedKEMRefreshRequestAdmissionGate",
            "CryptoProviderFactory",
            "PolicyDecisionContract.evaluate",
            "KeychainManager",
            "KEMTrustStore",
            "PeerKEMBootstrapStore",
            "HandshakeKEMIdentityStore",
            "HAS_APPLE_PQC_SDK",
            "SkyBridgePackagingBuildSource",
            "release_eligible",
            "macos-stable.json"
        ]
        let aiBoundaryReferences = try productionSwiftSources().flatMap { relativePath, source -> [String] in
            guard relativePath.contains("/AI/") else {
                return []
            }
            return nonCommentMatches(in: source, relativePath: relativePath, tokens: forbiddenAuthorityTokens)
        }

        XCTAssertTrue(
            aiBoundaryReferences.isEmpty,
            "AI/advisory sources must stay DTO-only and must not call trust, admission, PQC provider, key, or release authority paths: \(aiBoundaryReferences.joined(separator: ", "))"
        )
    }

    func testSecurityAuthorityPathsDoNotConsumeAIAdvisoryOutput() throws {
        let authorityPaths = [
            "Sources/SkyBridgeCore/Security/AnomalyDetectionService.swift",
            "Sources/SkyBridgeCore/Security/ConnectionApprovalService.swift",
            "Sources/SkyBridgeCore/Security/PairingTrustApprovalService.swift",
            "Sources/SkyBridgeCore/P2P/TrustSyncService.swift",
            "Sources/SkyBridgeCore/P2P/StrictPQCAdmissionGate.swift",
            "Sources/SkyBridgeCore/P2P/SignedKEMRefreshRequestAdmissionGate.swift",
            "Sources/SkyBridgeCore/P2P/CryptoProviderFactory.swift",
            "Sources/SkyBridgeCore/P2P/PolicyDecisionSnapshot.swift",
            "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCPQCHandshakePolicy.swift"
        ]
        let aiOutputTokens = [
            "AIAdvisoryEngine",
            "AIAdvisoryInputDTO",
            "AIAdvisoryOutputDTO",
            "AIAdvisoryRedactor",
            "AIAdvisoryFactDTO"
        ]
        let authorityReferences = try authorityPaths.flatMap { relativePath -> [String] in
            let source = try readSource(relativePath)
            return nonCommentMatches(in: source, relativePath: relativePath, tokens: aiOutputTokens)
        }

        XCTAssertTrue(
            authorityReferences.isEmpty,
            "Security, trust, PQC, admission, and WebRTC authority paths must not consume AI advisory DTOs: \(authorityReferences.joined(separator: ", "))"
        )
    }

    func testAnomalyDetectionLogsDoNotInterpolateRawIdentifiers() throws {
        let source = try readSource("Sources/SkyBridgeCore/Security/AnomalyDetectionService.swift")
        let sensitiveLogTokens = [
            "sourceDeviceID",
            "deviceID",
            "deviceId",
            "deviceName",
            "knownDeviceIDs",
            "context",
            "fileType",
            "fingerprint",
            "sessionId",
            "token"
        ]
        let rawIdentifierLogLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("logger.") else {
                    return nil
                }
                guard let token = sensitiveLogTokens.first(where: { trimmed.contains($0) }) else {
                    return nil
                }
                return "Sources/SkyBridgeCore/Security/AnomalyDetectionService.swift:\(index + 1):\(token):\(trimmed)"
            }

        XCTAssertTrue(
            rawIdentifierLogLines.isEmpty,
            "AnomalyDetectionService logs must not interpolate raw device, session, file, fingerprint, or token identifiers: \(rawIdentifierLogLines.joined(separator: ", "))"
        )
    }

    func testAnomalyDetectionPersistenceFailuresAreObservable() throws {
        let source = try readSource("Sources/SkyBridgeCore/Security/AnomalyDetectionService.swift")
        let forbiddenSilentWrites = [
            "try? Self.configurationStore.save",
            "try? Self.baselineStore.save",
            "try? Self.historyStore.save"
        ]

        for forbiddenSilentWrite in forbiddenSilentWrites {
            XCTAssertFalse(
                source.contains(forbiddenSilentWrite),
                "AnomalyDetectionService must not silently swallow persistence failures: \(forbiddenSilentWrite)"
            )
        }

        XCTAssertTrue(source.contains("AnomalyDetectionPersistenceFailure"))
        XCTAssertTrue(source.contains("@Published public private(set) var lastPersistenceFailure"))
        XCTAssertTrue(source.contains("recordPersistenceFailure"))
        XCTAssertTrue(source.contains("logger.error("))
        XCTAssertTrue(source.contains("String(reflecting: type(of: error))"))
    }

    func testAIAdvisorySourceContractsRunInOS27CompatibilityLane() throws {
        let script = try readSource("Scripts/run_os27_beta_compatibility.sh")

        XCTAssertTrue(script.contains("AppleAIAdvisorySourceContractTests"))
        XCTAssertTrue(
            script.contains("source_contract_filter='SkyBridgeCoreTests.(ApplePQCSDKGateSourceContractTests|AppleDesignAPISourceContractTests|AppleAIAdvisorySourceContractTests|AppleAppIntentAuthoritySourceContractTests|AIAdvisoryBoundaryTests|MetalShaderSourceCompileContractTests|AppUpdateManifestTests|QuantumCryptoManagerStrictPQCPolicyTests|P2PRedactionSourceContractTests)'"),
            "OS27 source-contract mode must run AI advisory guardrails before reporting source_contracts=verified."
        )
        XCTAssertTrue(
            script.contains("ApplePQCSDKGateSourceContractTests|AppleDesignAPISourceContractTests|AppleAIAdvisorySourceContractTests|AppleAppIntentAuthoritySourceContractTests|AIAdvisoryBoundaryTests|MetalShaderSourceCompileContractTests"),
            "OS27 full validation must keep the AI advisory source contract in its filtered SwiftPM clean-log tests."
        )
    }
}
