import Foundation
import XCTest

final class ApplePQCSDKGateSourceContractTests: XCTestCase {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func productionPQCClaimSources() throws -> [(relativePath: String, source: String)] {
        let roots = [
            "Sources",
            "SkyBridge Compass iOS",
            "Docs"
        ]
        let scannedExtensions: Set<String> = ["m", "mm", "h", "c", "cpp", "md", "strings"]
        var sources: [(relativePath: String, source: String)] = []

        for relativeRoot in roots {
            let rootURL = repositoryRoot().appendingPathComponent(relativeRoot)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw NSError(
                    domain: "ApplePQCSDKGateSourceContractTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing PQC claim source root: \(relativeRoot)"]
                )
            }
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw NSError(
                    domain: "ApplePQCSDKGateSourceContractTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to enumerate PQC claim source root: \(relativeRoot)"]
                )
            }
            for case let url as URL in enumerator {
                let relativePath = url.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "")
                guard scannedExtensions.contains(url.pathExtension),
                      !relativePath.contains("/Vendor/"),
                      !relativePath.contains(".xcframework") else {
                    continue
                }
                let source = try String(contentsOf: url, encoding: .utf8)
                sources.append((relativePath, source))
            }
        }

        let readme = try readSource("README.md")
        sources.append(("README.md", readme))
        XCTAssertFalse(sources.isEmpty, "PQC claim source-contract scan must not pass with an empty source set.")
        return sources.sorted { $0.relativePath < $1.relativePath }
    }

    private func packageManifestTargetBody(_ targetName: String, in manifest: String) throws -> String {
        let targetStartMarkers = [
            "\n        .binaryTarget(\n            name: \"\(targetName)\"",
            "\n        .target(\n            name: \"\(targetName)\"",
            "\n        .testTarget(\n            name: \"\(targetName)\"",
            "\n        .executableTarget(\n            name: \"\(targetName)\""
        ]
        guard let startRange = targetStartMarkers
            .compactMap({ manifest.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else {
            throw XCTSkip("Package.swift target not found: \(targetName)")
        }
        let nextTargetMarkers = [
            "\n        .binaryTarget(",
            "\n        .target(",
            "\n        .testTarget(",
            "\n        .executableTarget("
        ]
        let searchRange = startRange.upperBound..<manifest.endIndex
        let endIndex = nextTargetMarkers
            .compactMap { manifest.range(of: $0, range: searchRange)?.lowerBound }
            .min() ?? manifest.endIndex
        return String(manifest[startRange.lowerBound..<endIndex])
    }

    func testApplePQCSDKProbeDoesNotPromoteVersionFallbackToAvailable() throws {
        let source = try readSource("Scripts/apple_pqc_sdk_probe.sh")

        XCTAssertTrue(
            source.contains("sdk_name=\"${1:-macosx}\""),
            "Apple PQC SDK probe must preserve the macOS default while allowing explicit SDK targets."
        )
        XCTAssertTrue(source.contains("iphoneos)"))
        XCTAssertTrue(source.contains("iphonesimulator)"))
        XCTAssertTrue(source.contains("arm64-apple-ios26.0"))
        XCTAssertTrue(source.contains("apple-ios26.0-simulator"))
        XCTAssertTrue(
            source.contains("SKYBRIDGE_PQC_PROBE_SECURE_ENCLAVE"),
            "Secure Enclave PQC symbols should be an explicit macOS probe layer, not an accidental cross-platform requirement."
        )
        XCTAssertFalse(
            source.contains("version_fallback"),
            "Apple PQC SDK availability must be proven by CryptoKit symbol typecheck, not SDK major-version fallback."
        )
        XCTAssertFalse(
            source.contains("[ \"$sdk_major\" -ge 26 ]"),
            "SDK major version is not proof that the required CryptoKit PQC symbols are typecheckable."
        )
        XCTAssertTrue(source.contains("SKYBRIDGE_PQC_PROBE_MODE=\"symbol_probe_failed\""))
        XCTAssertTrue(source.contains("SKYBRIDGE_PQC_SDK_AVAILABLE=0"))
        XCTAssertTrue(source.contains("skybridge_apple_pqc_sdk_probe_succeeded()"))
        XCTAssertTrue(source.contains("skybridge_require_apple_pqc_sdk_symbol_probe()"))
    }

    func testQPeriaptBootstrapExportRequiresRuntimeProbeAndPlatformMetadata() throws {
        let policy = try readSource("Sources/SkyBridgeCore/P2P/QPeriaptPlatformPolicy.swift")
        XCTAssertTrue(policy.contains("#available(macOS 26.0, iOS 26.0, *)"))
        XCTAssertTrue(policy.contains("QPeriaptCryptoProvider.quickRuntimeProbe(session: session)"))
        XCTAssertTrue(policy.contains("runtimeSessionRegistry.install(session)"))
        XCTAssertTrue(policy.contains("prepareLocalRuntimeSupport() async"))
        XCTAssertTrue(policy.contains("only `activateRuntimeSession` can install an authenticated session"))
        XCTAssertTrue(policy.contains("currentRuntimeSession()"))
        XCTAssertTrue(policy.contains("makeCryptoProvider()"))
        XCTAssertTrue(policy.contains("SB_ENABLE_QPERIAPT"))
        XCTAssertTrue(policy.contains("SKYBRIDGE_PQC_PREFERRED_SUITE"))

        let runtime = try readSource("Sources/SkyBridgeQPeriaptRuntime/QPeriaptPolicyRuntime.swift")
        XCTAssertTrue(runtime.contains("verificationKeySHA256Pin"))
        XCTAssertTrue(runtime.contains("public let trustRootFingerprint: Data"))
        XCTAssertTrue(runtime.contains("trustRootIdentifierSHA256"))
        XCTAssertTrue(runtime.contains("case missingTrustedState"))
        XCTAssertTrue(runtime.contains("compareAndSwapTrustedState"))
        XCTAssertTrue(runtime.contains("case trustedStateChangedConcurrently"))
        XCTAssertTrue(runtime.contains("known commit would hide a monotonic-state transition"))

        let registry = try readSource(
            "Sources/SkyBridgeQPeriaptRuntime/QPeriaptRuntimeSessionRegistry.swift"
        )
        XCTAssertTrue(registry.contains("QPeriaptRuntimeSessionRegistry"))
        XCTAssertTrue(registry.contains("trustRootFingerprint != session.trustRootFingerprint"))
        XCTAssertTrue(registry.contains("policyRollbackRejected"))
        XCTAssertTrue(registry.contains("policyVersionDigestConflict"))

        let deviceIdentity = try readSource("Sources/SkyBridgeCore/P2P/DeviceIdentityKeyManager.swift")
        XCTAssertTrue(deviceIdentity.contains("QPeriaptPlatformPolicy.isEnabledForLocalRuntime()"))
        XCTAssertTrue(deviceIdentity.contains("QPeriaptPlatformPolicy.makeCryptoProvider()"))
        XCTAssertTrue(deviceIdentity.contains("suite == .qperiaptABI2PolicyBound"))
        XCTAssertFalse(deviceIdentity.contains("QPeriaptCryptoProvider()"))
        XCTAssertTrue(deviceIdentity.contains("requiredWireIds.insert(CryptoSuite.qperiaptABI2PolicyBound.wireId)"))
        XCTAssertTrue(deviceIdentity.contains("KEMIdentityKeyLengthContract.resolve("))
        XCTAssertFalse(deviceIdentity.contains("case (0x0012, .qperiaptPQC)"))

        let keyInfo = try readSource("Sources/SkyBridgeCore/P2P/KEMIdentityModels.swift")
        XCTAssertTrue(keyInfo.contains("let canonicalSuite = suite.canonicalKEMSuite"))
        XCTAssertTrue(keyInfo.contains("case (0x0012, .qperiaptPQC):"))
        XCTAssertTrue(keyInfo.contains("QPeriaptPlatformPolicy.publicKeyLength"))
        XCTAssertTrue(keyInfo.contains("QPeriaptPlatformPolicy.privateKeyLength"))

        let signaling = try readSource("Sources/SkyBridgeProtocolCore/RemoteConnection/WebRTC/WebRTCSignalingEnvelope.swift")
        XCTAssertTrue(signaling.contains("public var platform: String?"))
        XCTAssertTrue(signaling.contains("public var osVersion: String?"))

        let crossNetwork = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        XCTAssertTrue(crossNetwork.contains("platform: QPeriaptPlatformPolicy.localPlatformName()"))
        XCTAssertTrue(crossNetwork.contains("osVersion: QPeriaptPlatformPolicy.localOSVersionString()"))
    }

    func testQPeriaptABI2NegotiationBoundaryIsConsistentAcrossAppleMirrorsAndRust() throws {
        let macSuite = try readSource("Sources/SkyBridgeProtocolCore/P2P/CryptoSuite.swift")
        XCTAssertTrue(macSuite.contains("wireId: 0x0011"))
        XCTAssertTrue(macSuite.contains("wireId: 0x0012"))
        XCTAssertTrue(macSuite.contains("wireId == Self.qperiaptContextBound.wireId"))

        let macContext = try readSource("Sources/SkyBridgeCore/P2P/HandshakeContext.swift")
        XCTAssertTrue(macContext.contains("guard suite.isNegotiable else { return nil }"))
        XCTAssertTrue(macContext.contains("offeredSuites.allSatisfy(\\.isNegotiable)"))

        let iosSuite = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/CoreTypes.swift")
        XCTAssertTrue(iosSuite.contains("case qperiaptABI2PolicyBound"))
        XCTAssertTrue(iosSuite.contains("case .qperiaptContextBound: return 0x0011"))
        XCTAssertTrue(iosSuite.contains("case .qperiaptABI2PolicyBound: return 0x0012"))
        XCTAssertTrue(iosSuite.contains("self == .qperiaptContextBound"))
        XCTAssertTrue(
            iosSuite.contains(
                "self == .xwing || self == .qperiaptContextBound || self == .qperiaptABI2PolicyBound"
            ),
            "ABI2 is a hybrid suite even though admission remains provider/session-bound."
        )
        XCTAssertTrue(iosSuite.contains("isKnown && !isDecodeOnly"))
        XCTAssertTrue(
            iosSuite.contains("public static var explicitBetaPQCSuites: [CryptoSuite]") &&
                iosSuite.contains("return []")
        )
        XCTAssertFalse(
            iosSuite.contains("return [.qperiaptABI2PolicyBound]"),
            "ABI2 must be exposed only by a dynamically admitted provider, never a static global offer."
        )

        let iosManifest = try readSource("SkyBridge Compass iOS/Package.swift")
        XCTAssertTrue(iosManifest.contains(".package(name: \"SkyBridgeRoot\", path: \"..\")"))
        XCTAssertTrue(
            iosManifest.contains(
                ".product(name: \"SkyBridgeQPeriaptRuntime\", package: \"SkyBridgeRoot\")"
            )
        )

        let iosKEMInfo = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Trust/KEMPublicKeyInfo.swift")
        XCTAssertTrue(iosKEMInfo.contains("guard suite.isNegotiable, suite.isPQCGroup"))
        XCTAssertTrue(iosKEMInfo.contains("CryptoSuite.qperiaptABI2PolicyBound.wireId"))

        let rustCore = try readSource("rust/crates/skybridge-core/src/lib.rs")
        XCTAssertTrue(rustCore.contains("#[cfg(feature = \"q-periapt\")]"))
        XCTAssertTrue(rustCore.contains("compile_error!"))
        XCTAssertTrue(rustCore.contains("legacy ABI1 (wire 0x0011)"))
    }

    func testQPeriaptIOSProductionAdmissionIsProvisioningBoundAndFailClosed() throws {
        let iosRuntime = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Providers/QPeriaptIOSRuntime.swift"
        )
        XCTAssertTrue(
            iosRuntime.contains(
                "material: QPeriaptProductionTrustRootMaterial.makeSignedPolicyMaterial()"
            ),
            "The production registry must be built from the ceremony-generated shared material, never an inline fixture."
        )
        XCTAssertFalse(
            iosRuntime.contains("makeFixtureSignedPolicyMaterial"),
            "Production must ship without a fixture or placeholder trust root."
        )
        XCTAssertTrue(
            iosRuntime.contains("guard !entries.isEmpty else { return .unprovisioned }"),
            "Missing production policy material must remain an explicit non-advertising state."
        )
        XCTAssertTrue(iosRuntime.contains("private struct IOSQPeriaptTrustedStateStore"))
        XCTAssertTrue(iosRuntime.contains(": QPeriaptTrustedStateStore"))
        XCTAssertTrue(iosRuntime.contains("#if DEBUG || SKYBRIDGE_TESTING"))
        XCTAssertTrue(iosRuntime.contains("static func activateSignedPolicyForTesting("))
        XCTAssertFalse(iosRuntime.contains("Bundle.main"))
        XCTAssertFalse(iosRuntime.contains("signed-policy-vectors.json"))
        XCTAssertTrue(iosRuntime.contains("requiredConfiguration(defaults: userDefaults)"))
        XCTAssertFalse(iosRuntime.contains("requestedPQCAlgorithm(defaults: userDefaults)"))

        let keychain = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Security/KeychainManager.swift"
        )
        XCTAssertTrue(keychain.contains("qPeriaptMaximumTrustedStateTransitions = 64"))
        XCTAssertTrue(keychain.contains("kSecAttrSynchronizable as String: false"))
        XCTAssertTrue(
            keychain.contains(
                "kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"
            )
        )
        XCTAssertTrue(keychain.contains("switch SecItemAdd(query as CFDictionary, nil)"))
        XCTAssertTrue(keychain.contains("snapshot.transitionCount < Self.qPeriaptMaximumTrustedStateTransitions"))
        XCTAssertTrue(keychain.contains("snapshot.visitedStateDigests.contains(newStateDigest)"))
        XCTAssertTrue(keychain.contains("throw KeychainError.immutableStateCycleRejected"))
        XCTAssertTrue(keychain.contains("expectedDigest = Data(SHA256.hash(data: expectedState ?? Data()))"))

        let driver = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeDriver.swift"
        )
        XCTAssertTrue(driver.contains("qPeriaptAdmissionSnapshot.bind(provider: cryptoProvider)"))
        XCTAssertTrue(driver.contains("qPeriaptAdmissionSnapshot.isPeerEligible(capabilities)"))
        XCTAssertFalse(driver.contains("QPeriaptIOSRuntime.currentSession"))
        XCTAssertFalse(driver.contains("QPeriaptIOSRuntime.isEnabledForLocalRuntime"))

        let settings = try readSource("Sources/SkyBridgeCore/Settings/SettingsManager.swift")
        XCTAssertTrue(settings.contains("@Published public var preferQPeriaptBeta: Bool = false"))

        let policy = try readSource("Sources/SkyBridgeCore/P2P/QPeriaptPlatformPolicy.swift")
        XCTAssertTrue(policy.contains("isRequested(environment: environment, userDefaults: userDefaults) && isLocalRuntimeSupported"))
        XCTAssertTrue(policy.contains("q-periapt-abi2-policy-unprovisioned"))
        XCTAssertFalse(policy.contains("@unchecked Sendable"))

        let adapter = try readSource("Sources/SkyBridgeQPeriaptRuntime/QPeriaptNativeRuntime.swift")
        XCTAssertTrue(adapter.contains("maximumWaiters: Int = 8"))
        XCTAssertTrue(adapter.contains("maximumWaitDuration: Duration = .seconds(30)"))
        XCTAssertTrue(adapter.contains("case waitDeadlineExceeded"))
        XCTAssertTrue(adapter.contains("DispatchQueue("))
        XCTAssertTrue(adapter.contains("withCheckedThrowingContinuation"))
        XCTAssertTrue(adapter.contains("OSAllocatedUnfairLock"))
        XCTAssertFalse(adapter.contains("DispatchSemaphore"))
        XCTAssertFalse(adapter.contains("@unchecked Sendable"))

        let coreBridge = try readSource(
            "Sources/SkyBridgeCore/P2P/Providers/QPeriaptNativeAdapter.swift"
        )
        let secretBuffer = try readSource(
            "Sources/SkyBridgeQPeriaptRuntime/QPeriaptSecretBuffer.swift"
        )
        XCTAssertTrue(secretBuffer.contains("extension SecureBytes: QPeriaptSecretBuffer"))
        XCTAssertTrue(secretBuffer.contains("typealias QPeriaptSecretBytes = SecureBytes"))
        XCTAssertFalse(coreBridge.contains("extension SecureBytes: QPeriaptSecretBuffer"))
        XCTAssertTrue(coreBridge.contains("translateNativeErrors"))
        XCTAssertFalse(coreBridge.contains("q_periapt_"))
    }

    func testQPeriaptAppleBindingFailsClosedOnABIAndSuiteDrift() throws {
        let contract = try readSource(
            "Sources/SkyBridgeQPeriaptRuntime/QPeriaptRuntimeContract.swift"
        )
        XCTAssertTrue(contract.contains("q_periapt_abi_version()"))
        XCTAssertTrue(contract.contains("q_periapt_fixed_suite_id_len()"))
        XCTAssertTrue(contract.contains("q_periapt_fixed_suite_id()"))
        XCTAssertTrue(contract.contains("Q-Periapt C ABI mismatch"))
        XCTAssertTrue(contract.contains("Q-Periapt header changed the frozen SkyBridge ABI2 PolicyBound contract"))
        XCTAssertTrue(contract.contains("expectedRuntimeVersion = \"0.1.0-alpha.2\""))

        let provider = try readSource("Sources/SkyBridgeCore/P2P/Providers/QPeriaptCryptoProvider.swift")
        XCTAssertTrue(provider.contains("QPeriaptNativeAdapter(session: session)"))
        XCTAssertTrue(provider.contains("ApplicationContextBoundCryptoProvider"))
        XCTAssertTrue(provider.contains("Q-Periapt ABI2 requires the protocol-derived application context"))
        XCTAssertFalse(
            provider.contains("q_periapt_hybrid_encapsulate") ||
                provider.contains("q_periapt_hybrid_decapsulate"),
            "ABI2 provider must not retain ABI1 entry points."
        )

        let kemProvider = try readSource("Sources/SkyBridgeCore/P2P/Providers/QPeriaptKEMProvider.swift")
        XCTAssertTrue(kemProvider.contains("QPeriaptNativeAdapter(session: session)"))
        XCTAssertTrue(kemProvider.contains("requires a non-empty application context"))

        let adapter = try readSource(
            "Sources/SkyBridgeQPeriaptRuntime/QPeriaptNativeRuntime.swift"
        )
        XCTAssertTrue(adapter.contains("try QPeriaptRuntimeContract.requireCompatible()"))
        XCTAssertTrue(adapter.contains("q_periapt_generate_keypair("))
        XCTAssertTrue(adapter.contains("q_periapt_encapsulate("))
        XCTAssertTrue(adapter.contains("q_periapt_decapsulate("))
        XCTAssertTrue(adapter.contains("session.decision.encoded.withUnsafeBytes"))
        XCTAssertTrue(adapter.contains("privateKey.withUnsafeBytes"))
        XCTAssertTrue(adapter.contains("privateKey: Secret"))
        XCTAssertTrue(adapter.contains("let privateKey = try Secret(count: Self.privateKeyLength)"))
        XCTAssertTrue(adapter.contains("Secret: QPeriaptSecretBuffer"))
        XCTAssertFalse(adapter.contains("var privateKey = Data(capacity: Self.privateKeyLength)"))
        XCTAssertFalse(adapter.contains("privateKey.copyData()"))
        XCTAssertTrue(provider.contains("bytes: keys.privateKey.copyData()"))
        XCTAssertTrue(kemProvider.contains("privateKey: keys.privateKey.copyData()"))

        let buildScript = try readSource("Scripts/build_qperiapt_xcframework.sh")
        XCTAssertTrue(buildScript.contains("assert_header_contract"))
        XCTAssertTrue(buildScript.contains("assert_exact_symbols"))
        XCTAssertTrue(buildScript.contains("assert_original_release"))
        XCTAssertTrue(buildScript.contains("assert_derivative"))
        XCTAssertTrue(buildScript.contains("validate_archive_shape"))
        XCTAssertTrue(buildScript.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(buildScript.contains("q_periapt_abi_version"))
        XCTAssertTrue(buildScript.contains("q_periapt_fixed_suite_id"))
        XCTAssertTrue(buildScript.contains("Q_PERIAPT_POLICY_DECISION_LEN 40"))
        XCTAssertTrue(buildScript.contains("QPERIAPT_RELEASE_TAG=\"v0.1.0-alpha.2-r1\""))
        XCTAssertTrue(buildScript.contains("QPERIAPT_SOURCE_COMMIT=\"5664fd86a617f92b620ea37e7692d3417d0e307d\""))
        XCTAssertTrue(buildScript.contains("QPERIAPT_ZIP_SHA256="))
        XCTAssertTrue(buildScript.contains("declared_qperiapt_symbols"))
        XCTAssertTrue(buildScript.contains("frozen ABI2 exact-nine symbol set"))
        XCTAssertTrue(buildScript.contains("module.modulemap"))
        XCTAssertTrue(buildScript.contains("linked .a bytes remain exact"))
        XCTAssertTrue(
            buildScript.contains("q_periapt_hybrid_encapsulate_with_decision")
                && buildScript.contains("! grep -Fq \"$forbidden\" \"$header\""),
            "The installer must name and reject guessed pre-ABI2 entry points, not treat their mention in the denylist as an export."
        )
    }

    func testOSVersionOrHardwareChecksDoNotAdvertisePQCWithoutCryptoEvidence() throws {
        let forbiddenClaims = [
            "启用后量子加密",
            "已自动启用 `HAS_APPLE_PQC_SDK`",
            "自动启用 HAS_APPLE_PQC_SDK",
            "iOS 26 SDK 构建下，Xcode 工程已自动启用"
        ]
        let matches = try productionPQCClaimSources().flatMap { relativePath, source -> [String] in
            source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, line -> String? in
                    guard let claim = forbiddenClaims.first(where: { line.contains($0) }) else {
                        return nil
                    }
                    return "\(relativePath):\(index + 1):\(claim):\(line.trimmingCharacters(in: .whitespaces))"
                }
        }

        XCTAssertTrue(
            matches.isEmpty,
            "OS version, SDK version, or hardware checks must not advertise PQC without symbol probe, runtime proof, and negotiated session evidence: \(matches.joined(separator: ", "))"
        )
    }

    func testUserVisiblePQCClaimsRequireNegotiatedRuntimeProofLanguage() throws {
        let userVisibleSources = [
            "Docs/CrossPlatformDiscoveryDesign.md",
            "SkyBridge Compass iOS/README.md",
            "Sources/SkyBridgeCompassApp/PreferencesView.swift",
            "Sources/SkyBridgeCore/Settings/SettingsManager.swift",
            "Sources/SkyBridgeCore/QuantumSecure/QuantumSecureP2PNetwork.swift",
            "Sources/SkyBridgeCore/Resources/en.lproj/Localizable.strings",
            "Sources/SkyBridgeCore/Resources/zh-Hans.lproj/Localizable.strings",
            "Sources/SkyBridgeCore/Resources/ja.lproj/Localizable.strings"
        ]
        let forbiddenBroadClaims = [
            "后量子密码学 (PQC) 加密握手和通信",
            "TLS 1.3 + PQC 层",
            "端到端 PQC 加密",
            "protected by quantum-safe/PQC encryption",
            "受量子安全/PQC 加密保护",
            "量子安全/PQC 暗号で保護されています",
            "End-to-end PQC encryption where supported",
            "默认启用PQC，提供量子安全保护",
            "启动量子安全网络",
            "量子安全网络已启动",
            "停止量子安全网络",
            "Quantum-Safe\", description: \"量子安全算法"
        ]

        let matches = try userVisibleSources.flatMap { relativePath -> [String] in
            let source = try readSource(relativePath)
            return source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, line -> String? in
                    guard let claim = forbiddenBroadClaims.first(where: { line.contains($0) }) else {
                        return nil
                    }
                    return "\(relativePath):\(index + 1):\(claim):\(line.trimmingCharacters(in: .whitespaces))"
                }
        }

        XCTAssertTrue(
            matches.isEmpty,
            "User-visible PQC wording must name negotiated/runtime proof boundaries instead of advertising unconditional quantum-safe transport: \(matches.joined(separator: ", "))"
        )

        let iOSReadme = try readSource("SkyBridge Compass iOS/README.md")
        XCTAssertTrue(iOSReadme.contains("runtime self-test"))
        XCTAssertTrue(iOSReadme.contains("信任材料与协商 suite"))
        XCTAssertTrue(iOSReadme.contains("runtime-negotiated suite 与信任/KEM 材料证明后声明"))
        XCTAssertTrue(iOSReadme.contains("PQC 只在 runtime-negotiated suite 已证明时声明"))
        XCTAssertTrue(try readSource("Docs/CrossPlatformDiscoveryDesign.md").contains("PQC only when the negotiated suite and runtime proof support it"))
        XCTAssertTrue(try readSource("Sources/SkyBridgeCompassApp/PreferencesView.swift").contains("Negotiated PQC"))
        XCTAssertTrue(try readSource("Sources/SkyBridgeCore/Settings/SettingsManager.swift").contains("不得把开关本身当成量子安全证明"))
        XCTAssertTrue(try readSource("Sources/SkyBridgeCore/QuantumSecure/QuantumSecureP2PNetwork.swift").contains("PQC 状态等待协商证明"))

        let englishStrings = try readSource("Sources/SkyBridgeCore/Resources/en.lproj/Localizable.strings")
        let simplifiedChineseStrings = try readSource("Sources/SkyBridgeCore/Resources/zh-Hans.lproj/Localizable.strings")
        let japaneseStrings = try readSource("Sources/SkyBridgeCore/Resources/ja.lproj/Localizable.strings")
        XCTAssertTrue(englishStrings.contains("PQC is shown only when the negotiated suite proves it."))
        XCTAssertTrue(simplifiedChineseStrings.contains("仅在协商套件证明后显示 PQC。"))
        XCTAssertTrue(japaneseStrings.contains("PQC はネゴシエート済みスイートで証明された場合のみ表示されます。"))
    }

    func testAppleTLSPQCDocumentationStaysServerNegotiatedAndTransportOnly() throws {
        let os27Plan = try readSource("Docs/os27-adaptation-plan-2026-06.md")

        XCTAssertTrue(os27Plan.contains("Apple Support TLS quantum-secure readiness"))
        XCTAssertTrue(os27Plan.contains("Apple Platform Security quantum-secure cryptography"))
        XCTAssertTrue(os27Plan.contains("URLSession"))
        XCTAssertTrue(os27Plan.contains("Network"))
        XCTAssertTrue(os27Plan.contains("ClientHello"))
        XCTAssertTrue(os27Plan.contains("X25519MLKEM768"))
        XCTAssertTrue(os27Plan.contains("transport capability advertisement"))
        XCTAssertTrue(os27Plan.contains("服务器在 TLS 握手中选择该 group"))
        XCTAssertTrue(os27Plan.contains("nscurl --tls-diagnostics"))
        XCTAssertTrue(os27Plan.contains("Negotiated TLS key exchange group (name): X25519MLKEM768"))
        XCTAssertTrue(os27Plan.contains("server_support_required=true"))
        XCTAssertTrue(os27Plan.contains("session_negotiated=false"))
        XCTAssertTrue(os27Plan.contains("affects_crypto_suite_selection=false"))
        XCTAssertTrue(os27Plan.contains("release_eligible=false"))
        XCTAssertTrue(os27Plan.contains("TLS hybrid KEX 不得进入 `CryptoSuite`"))
        XCTAssertTrue(os27Plan.contains("不接受 OS 版本、SDK 版本、硬件型号、TLS advertisement 或 Xcode GUI 状态作为应用层 PQC 会话证明"))
        XCTAssertTrue(os27Plan.contains("symbol_probe"))
        XCTAssertTrue(os27Plan.contains("ApplePQC/AppleXWing runtime self-test"))
        XCTAssertTrue(os27Plan.contains("negotiated suite/trust material proof"))
    }

    func testOS27BetaLaneRequiresAllApplePQCSymbolProbesBeforeEnablingCompileGate() throws {
        let source = try readSource("Scripts/run_os27_beta_compatibility.sh")

        XCTAssertTrue(source.contains("run_full_validation_lane()"))
        XCTAssertTrue(source.contains("for pqc_sdk in macosx iphoneos iphonesimulator; do"))
        XCTAssertTrue(source.contains("skybridge_require_apple_pqc_sdk_symbol_probe \"${pqc_sdk}\""))
        XCTAssertFalse(
            source.contains("skybridge_detect_apple_pqc_sdk \"${pqc_sdk}\""),
            "OS27 critical lanes must use the strict Apple PQC probe helper, not the diagnostic detector return code."
        )
        XCTAssertTrue(source.contains("Apple PQC SDK symbol probe failed for ${pqc_sdk}"))
        XCTAssertTrue(source.contains("Apple PQC symbols verified"))
        XCTAssertTrue(source.contains("record_pqc_symbol_probe_result()"))
        XCTAssertTrue(source.contains("pqc_symbol_probe_details"))
        XCTAssertTrue(source.contains("cryptokit-pqc-os27-v1"))
        XCTAssertTrue(source.contains("cryptokit_compile_time_symbol_surface_only"))
        XCTAssertTrue(source.contains("\"affects_session_status\": False"))
        XCTAssertTrue(source.contains("\"affects_network_tls_pqc\": False"))
        XCTAssertTrue(source.contains("OS27_COMPAT_REPORT_SCHEMA_VERSION=2"))
        XCTAssertTrue(source.contains("OS27_APPLE_PQC_SYMBOL_SET"))
        XCTAssertTrue(source.contains("validate_os27_apple_pqc_symbol_set_override()"))
        XCTAssertTrue(source.contains("OS27 compatibility reports must use ${OS27_APPLE_PQC_SYMBOL_SET}"))
        XCTAssertFalse(
            source.contains(#"OS27_APPLE_PQC_SYMBOL_SET="${SKYBRIDGE_OS27_APPLE_PQC_SYMBOL_SET:-cryptokit-pqc-os27-v1}""#),
            "OS27 beta reports must not allow overriding their symbol-set down to stable-release cryptokit-pqc-v1."
        )
        XCTAssertTrue(source.contains("secure_enclave_symbols_included"))
        XCTAssertTrue(
            source.contains(#"if [[ "${sdk_name}" == "macosx" || "${sdk_name}" == "iphoneos" ]]; then"#),
            "OS27 pending/not-run metadata must match the physical Apple SDKs whose symbol probes include Secure Enclave ML-DSA."
        )
        XCTAssertTrue(source.contains("error_summary"))
        XCTAssertTrue(source.contains("sanitize_report_error_summary()"))
        XCTAssertTrue(
            source.contains(#"s#<tmp>/[^[:space:]]+#<tmp>#g"#) && source.contains(#"s#/var/folders/[^[:space:]]+#<tmp>#g"#),
            "OS27 reports should preserve compiler error meaning without leaking local temporary paths."
        )
        XCTAssertTrue(source.contains("apple_quantum_secure_runtime_proof"))
        XCTAssertTrue(source.contains("ApplePQC ML-KEM/ML-DSA runtime"))
        XCTAssertTrue(source.contains("AppleXWing HPKE runtime"))
        XCTAssertTrue(source.contains("apple_cryptokit_runtime_self_test_only"))
        XCTAssertTrue(source.contains("\"session_negotiated\": False"))
        XCTAssertTrue(source.contains("OS27_REQUIRED_IOS_DEVICE_PQC_RUNTIME_TEST"))
        XCTAssertTrue(source.contains("run_reported_gate()"))

        let probeLoopRange = source.range(of: "for pqc_sdk in macosx iphoneos iphonesimulator; do")
        let enableCompileGateRange = source.range(of: "export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1")
        XCTAssertNotNil(probeLoopRange)
        XCTAssertNotNil(enableCompileGateRange)
        if let probeLoopRange, let enableCompileGateRange {
            XCTAssertLessThan(
                probeLoopRange.lowerBound,
                enableCompileGateRange.lowerBound,
                "OS27 lane must enable HAS_APPLE_PQC_SDK only after macOS, iPhoneOS, and iPhoneSimulator symbol probes succeed."
            )
        }

        XCTAssertTrue(source.contains("ApplePQCSDKGateSourceContractTests"))
        XCTAssertTrue(source.contains("MetalShaderSourceCompileContractTests"))
        XCTAssertTrue(source.contains("PQCSignatureProviderAutoFallbackSemanticsTests"))
        XCTAssertTrue(source.contains("QuantumCryptoManagerStrictPQCPolicyTests"))
        XCTAssertTrue(source.contains("generic/platform=iOS Simulator"))
        XCTAssertTrue(source.contains("configure_ios_xcodebuild_apple_pqc_gate_after_probe()"))
        XCTAssertTrue(source.contains("SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK"))
        XCTAssertTrue(source.contains("run_swiftpm_clean_log_test()"))
        XCTAssertTrue(source.contains("run_xcodebuild_clean_log()"))
        XCTAssertTrue(
            source.contains("clean_log_diagnostic_pattern()"),
            "SwiftPM and xcodebuild clean-log gates should share one warning/error detector."
        )
        XCTAssertTrue(
            source.contains("([Ww][Aa][Rr][Nn][Ii][Nn][Gg]|[Ee][Rr][Rr][Oo][Rr]):"),
            "Clean-log gates must catch uppercase diagnostics such as xcodebuild's WARNING: output."
        )
        XCTAssertTrue(
            source.contains(#"grep -E "$(clean_log_diagnostic_pattern)" "${log_file}""#),
            "SwiftPM and xcodebuild clean-log gates should call the shared diagnostic detector."
        )
        XCTAssertFalse(
            source.contains(#"'(^|[^[:alnum:]_])(warning|error):'"#),
            "Lowercase-only clean-log matching would miss xcodebuild-style uppercase diagnostics."
        )
        XCTAssertTrue(source.contains("ensure_swiftpm_scratch_path()"))
        XCTAssertTrue(source.contains("swiftpm_scratch_path()"))
        XCTAssertTrue(source.contains("prime_swiftpm_scratch_path()"))
        XCTAssertTrue(source.contains("for cache_name in repositories checkouts artifacts; do"))
        XCTAssertFalse(
            source.contains("SKYBRIDGE_OS27_SWIFTPM_COPY_METAL_RESOURCES"),
            "Metal resource handling must not fork between production and OS27 validation. SwiftPM should copy shader sources by default."
        )
        XCTAssertTrue(source.contains(#"run_swiftpm_clean_log "SwiftPM OS27 app build" swift build --scratch-path "${OS27_SWIFTPM_SCRATCH_PATH}" --disable-automatic-resolution --disable-prefetching --product SkyBridgeCompassApp"#))
        XCTAssertTrue(source.contains("source \"${ROOT_DIR}/Scripts/package_build_policy.sh\""))
        XCTAssertTrue(source.contains("assert_os27_swiftpm_app_has_apple_pqc_compile_marker()"))
        XCTAssertTrue(source.contains(#"assert_os27_swiftpm_app_has_apple_pqc_compile_marker "${OS27_SWIFTPM_SCRATCH_PATH}""#))
        XCTAssertTrue(source.contains(#"scratch_path="${OS27_SWIFTPM_SCRATCH_PATH}""#))
        XCTAssertFalse(
            source.contains(#"--scratch-path "$(swiftpm_scratch_path)""#),
            "Command substitution runs the scratch-path helper in a subshell, so the EXIT trap cannot see and clean the generated SwiftPM scratch directory."
        )
        let swiftPMAppBuild = source.range(of: #"run_swiftpm_clean_log "SwiftPM OS27 app build" swift build --scratch-path "${OS27_SWIFTPM_SCRATCH_PATH}" --disable-automatic-resolution --disable-prefetching --product SkyBridgeCompassApp"#)
        let swiftPMMarkerAssertion = source.range(of: #"assert_os27_swiftpm_app_has_apple_pqc_compile_marker "${OS27_SWIFTPM_SCRATCH_PATH}""#)
        let swiftPMPQCTest = source.range(of: #"run_swiftpm_clean_log_test "${swiftpm_pqc_filter}""#)
        XCTAssertNotNil(swiftPMAppBuild)
        XCTAssertNotNil(swiftPMMarkerAssertion)
        XCTAssertNotNil(swiftPMPQCTest)
        if let swiftPMAppBuild, let swiftPMMarkerAssertion, let swiftPMPQCTest {
            XCTAssertLessThan(
                swiftPMAppBuild.lowerBound,
                swiftPMMarkerAssertion.lowerBound,
                "OS27 full lane must build the SwiftPM app before checking its Apple PQC compile marker."
            )
            XCTAssertLessThan(
                swiftPMMarkerAssertion.lowerBound,
                swiftPMPQCTest.lowerBound,
                "OS27 full lane must prove the built app binary contains the HAS_APPLE_PQC_SDK marker before running later PQC tests."
            )
        }
        XCTAssertTrue(source.contains("prepare_swiftpm_webrtc_runtime_framework()"))
        XCTAssertTrue(source.contains("-path '*/out/Products/Debug/WebRTC.framework'"))
        XCTAssertTrue(source.contains(#"[[ -e "${source_framework}/WebRTC" ]] || fail "SwiftPM WebRTC.framework runtime binary was not found: ${source_framework}/WebRTC""#))
        XCTAssertFalse(
            source.contains("-path '*/out/Products/Debug/WebRTC.framework/WebRTC'"),
            "macOS framework binaries can be symlinks; the runtime-prep step should locate the framework root and then validate the entry path."
        )
        XCTAssertTrue(source.contains(#"prime_swiftpm_scratch_path "${scratch_path}""#))
        XCTAssertTrue(source.contains(#"run_swiftpm_clean_log "SwiftPM OS27 PQC test build" swift build --scratch-path "${scratch_path}" --disable-automatic-resolution --disable-prefetching --build-tests"#))
        XCTAssertTrue(source.contains(#"prepare_swiftpm_webrtc_runtime_framework "${scratch_path}""#))
        XCTAssertTrue(source.contains(#"run_swiftpm_clean_log "SwiftPM OS27 PQC test" swift test --scratch-path "${scratch_path}" --disable-automatic-resolution --disable-prefetching --skip-build --filter "${filter}""#))
        XCTAssertTrue(source.contains("SwiftPM OS27 PQC test"))
        XCTAssertTrue(source.contains("emitted warnings/errors under clean-log gate"))
        XCTAssertTrue(source.contains(#"run_xcodebuild_clean_log "generic iOS build""#))
        XCTAssertTrue(source.contains(#"run_xcodebuild_clean_log "iOS Simulator build""#))
        XCTAssertTrue(
            source.contains(#"run_reported_gate OS27_REPORT_SWIFTPM_APP_BUILD_STATUS "SwiftPM OS27 app build failed clean-log gate""#),
            "SwiftPM app build warnings must fail closed and update the machine-readable gate status."
        )
        XCTAssertTrue(
            source.contains(#"run_reported_gate OS27_REPORT_IOS_SIMULATOR_BUILD_STATUS "iOS Simulator build failed clean-log gate""#),
            "Xcodebuild warning output must fail closed and update the machine-readable gate status."
        )
        XCTAssertTrue(
            source.contains(#""${OS27_IOS_XCODEBUILD_APPLE_PQC_SETTINGS[@]}""#),
            "OS27 Xcode builds must receive the probe-verified Apple PQC compile condition explicitly."
        )

        guard let fullValidationRange = source.range(of: "run_full_validation_lane()") else {
            return XCTFail("OS27 script must define a full validation lane.")
        }
        let fullValidationSource = source[fullValidationRange.lowerBound...]
        XCTAssertTrue(fullValidationSource.contains("run_swiftpm_clean_log_test \"${swiftpm_pqc_filter}\""))
        XCTAssertTrue(
            fullValidationSource.contains("OS27_REPORT_SOURCE_CONTRACTS_STATUS=\"running\""),
            "Full validation should expose source-contract progress in the machine-readable report."
        )
        XCTAssertTrue(
            fullValidationSource.contains("OS27_REPORT_SOURCE_CONTRACTS_STATUS=\"passed\""),
            "Full validation should mark source-contract tests passed after the filtered clean-log test gate succeeds."
        )
        XCTAssertTrue(
            fullValidationSource.contains("OS27_REPORT_SOURCE_CONTRACTS_STATUS=\"failed\""),
            "Full validation should mark source-contract tests failed when the filtered clean-log test gate fails."
        )
        XCTAssertTrue(
            fullValidationSource.contains("OS27_REPORT_FULL_VALIDATION_ATTEMPTED=\"1\""),
            "Full validation reports must distinguish attempted validation from completed validation."
        )
        XCTAssertTrue(
            fullValidationSource.contains("OS27_REPORT_FULL_VALIDATION=\"1\"")
                && fullValidationSource.contains("OS27_REPORT_FULL_VALIDATION_PASSED=\"1\""),
            "The legacy full_validation field may only become true after all required OS27 gates, including the iOS device runtime proof, have passed."
        )
        XCTAssertFalse(
            fullValidationSource.contains(#"run_reported_gate OS27_REPORT_SWIFTPM_FILTERED_TEST_STATUS "SwiftPM OS27 filtered test failed clean-log gate" run_swiftpm_clean_log_test"#),
            "The filtered SwiftPM gate also owns source-contract report status, so it should not be hidden behind a single-status wrapper."
        )
        XCTAssertFalse(
            fullValidationSource.contains("swift test -Xswiftc -warnings-as-errors --filter \"${swiftpm_pqc_filter}\""),
            "Xcode 27 beta's SwiftPM build can pass -suppress-warnings for package dependencies; full validation should use a clean-log warning gate instead of conflicting compiler flags."
        )
    }

    func testNetworkTLSPQCProbeIsDiagnosticOnlyAndDoesNotChangeWireSuites() throws {
        let probeSource = try readSource("Scripts/apple_pqc_sdk_probe.sh")
        let os27Source = try readSource("Scripts/run_os27_beta_compatibility.sh")
        let cryptoSuiteSource = try readSource("Sources/SkyBridgeProtocolCore/P2P/CryptoSuite.swift")
        let tlsSource = try readSource("Sources/SkyBridgeCore/Security/TLSSecurityManager.swift")

        XCTAssertTrue(probeSource.contains("skybridge_detect_network_tls_pqc_sdk()"))
        XCTAssertTrue(probeSource.contains("skybridge_network_tls_pqc_sdk_probe_succeeded()"))
        XCTAssertTrue(probeSource.contains("SKYBRIDGE_NETWORK_TLS_PQC_SYMBOL_SET=\"network-tls-pqc-v1\""))
        XCTAssertTrue(probeSource.contains("import Network"))
        XCTAssertTrue(probeSource.contains("SwiftTLSOptions()"))
        XCTAssertTrue(probeSource.contains(".x25519MLKEM768"))
        XCTAssertFalse(
            probeSource.contains("SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1") &&
                probeSource.contains("skybridge_detect_network_tls_pqc_sdk \"${_skybridge_pqc_optional_sdk_name}\""),
            "Network TLS PQC public API probing must not enable the CryptoKit HAS_APPLE_PQC_SDK compile gate."
        )

        XCTAssertTrue(os27Source.contains("network_tls_pqc_symbol_probes"))
        XCTAssertTrue(os27Source.contains("network_tls_pqc_symbol_probe_details"))
        XCTAssertTrue(os27Source.contains("network-tls-pqc-v1"))
        XCTAssertTrue(os27Source.contains("status}\" == \"failed\" || \"${status}\" == \"unavailable\""))
        XCTAssertTrue(os27Source.contains(#""proof_scope": "transport_sdk_public_api_surface_only""#))
        XCTAssertTrue(os27Source.contains(#""server_support_required": True"#))
        XCTAssertTrue(os27Source.contains(#""session_negotiated": False"#))
        XCTAssertTrue(os27Source.contains(#""affects_session_status": False"#))
        XCTAssertTrue(os27Source.contains(#""affects_crypto_suite_selection": False"#))
        XCTAssertTrue(os27Source.contains(#""release_eligible": False"#))
        XCTAssertTrue(os27Source.contains("Network TLS PQC public API probe"))
        XCTAssertTrue(os27Source.contains("proofScope=transport_sdk_public_api_surface_only releaseEligible=false affectsCryptoSuiteSelection=false"))
        XCTAssertTrue(os27Source.contains("releaseEligible=false affectsCryptoSuiteSelection=false proofScope=transport_sdk_public_api_surface_only"))
        XCTAssertFalse(
            os27Source.contains("Network TLS PQC public API probe failed"),
            "Network TLS PQC public API status is diagnostic while the API is beta/unstable; failure must not block OS27 compatibility proof for app-layer CryptoKit PQC."
        )

        XCTAssertFalse(
            cryptoSuiteSource.contains("network-tls-pqc-v1") || cryptoSuiteSource.contains("x25519MLKEM768") || cryptoSuiteSource.contains("SwiftTLSOptions"),
            "Transport-layer TLS hybrid KEX must not create an OS27-only SkyBridge wire suite."
        )
        let releaseConsumerSources = try [
            "Scripts/generate_macos_update_manifest.swift",
            "Scripts/package_build_policy.sh",
            "Scripts/publish_macos_update_release.sh",
            "Scripts/verify_xcode_toolchain.sh"
        ].map { relativePath in
            (relativePath: relativePath, source: try readSource(relativePath))
        }
        let releaseConsumerLeakage = releaseConsumerSources.flatMap { relativePath, source in
            ["network-tls-pqc-v1", "SwiftTLSOptions", "x25519MLKEM768"].compactMap { token in
                source.contains(token) ? "\(relativePath):\(token)" : nil
            }
        }
        XCTAssertTrue(
            releaseConsumerLeakage.isEmpty,
            "Release consumers must not treat Network TLS PQC SDK probes as release or manifest evidence: \(releaseConsumerLeakage.joined(separator: ", "))"
        )
        XCTAssertTrue(
            tlsSource.contains("传输层 PQC 协商未由本模块证明"),
            "TLS diagnostics must not label a connection as PQC unless a negotiated TLS group is actually proven."
        )
    }

    func testBenchmarkEntrypointsUseCanonicalApplePQCSymbolProbe() throws {
        let probeSource = try readSource("Scripts/apple_pqc_sdk_probe.sh")
        let benchmarkEntrypoints = [
            "Scripts/run_paper_eval.sh": try readSource("Scripts/run_paper_eval.sh"),
            "Scripts/run_baseline_bench.sh": try readSource("Scripts/run_baseline_bench.sh")
        ]

        XCTAssertTrue(probeSource.contains("skybridge_configure_optional_apple_pqc_sdk_compile_gate()"))
        XCTAssertTrue(probeSource.contains("skybridge_detect_apple_pqc_sdk \"${_skybridge_pqc_optional_sdk_name}\""))
        XCTAssertTrue(probeSource.contains("export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1"))
        XCTAssertTrue(probeSource.contains("export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=0"))

        for (relativePath, source) in benchmarkEntrypoints {
            XCTAssertTrue(
                source.contains("source \"${root_dir}/Scripts/apple_pqc_sdk_probe.sh\""),
                "\(relativePath) must source the canonical Apple PQC SDK probe before enabling HAS_APPLE_PQC_SDK."
            )
            XCTAssertTrue(
                source.contains("skybridge_configure_optional_apple_pqc_sdk_compile_gate macosx"),
                "\(relativePath) must configure Apple PQC through the canonical optional compile-gate helper."
            )
            XCTAssertFalse(
                source.contains("CryptoKit.swiftmodule"),
                "\(relativePath) must not grep SDK module internals as proof of Apple PQC support."
            )
            XCTAssertFalse(
                source.contains("MLKEM768"),
                "\(relativePath) must not use a single symbol string as a substitute for the full CryptoKit typecheck probe."
            )
            XCTAssertFalse(
                source.contains("-DHAS_APPLE_PQC_SDK"),
                "\(relativePath) must not bypass Package.swift by passing HAS_APPLE_PQC_SDK directly to SwiftPM."
            )
            XCTAssertFalse(
                source.contains("export HAS_APPLE_PQC_SDK=1"),
                "\(relativePath) must not publish a legacy environment value that can be mistaken for compile proof."
            )
        }

        let baselineSource = benchmarkEntrypoints["Scripts/run_baseline_bench.sh"] ?? ""
        XCTAssertTrue(
            baselineSource.contains("BASELINE_FORCE_APPLE_PQC is deprecated")
                && baselineSource.contains("exit 2"),
            "The old baseline force flag may only remain as a fail-fast deprecation guard."
        )
        XCTAssertFalse(
            baselineSource.contains(#"BASELINE_FORCE_APPLE_PQC:-}" == "1""#),
            "The old baseline force flag must not enable Apple PQC."
        )
    }

    func testSwiftPMApplePQCSDKCompileGateRequiresExplicitProbeOverride() throws {
        let manifestPaths = [
            "Package.swift",
            "SkyBridge Compass iOS/Package.swift"
        ]

        for manifestPath in manifestPaths {
            let manifest = try readSource(manifestPath)
            XCTAssertTrue(
                manifest.contains("SKYBRIDGE_ENABLE_APPLE_PQC_SDK"),
                "\(manifestPath) must use the explicit probe-controlled Apple PQC compile gate."
            )
            XCTAssertTrue(
                manifest.contains("fatalError(\"Invalid SKYBRIDGE_ENABLE_APPLE_PQC_SDK value:"),
                "\(manifestPath) must fail fast on malformed Apple PQC compile-gate overrides."
            )
            XCTAssertFalse(
                manifest.contains("#if swift(>="),
                "\(manifestPath) must not infer Apple PQC SDK availability from the Swift language/toolchain version."
            )
            XCTAssertFalse(
                manifest.contains("SKYBRIDGE_FORCE_DISABLE_APPLE_PQC_SDK"),
                "\(manifestPath) must not use force-disable compatibility switches now that the default is fail-closed."
            )
            XCTAssertFalse(
                manifest.contains("gate PQC compilation on the toolchain Swift version"),
                "\(manifestPath) comments must not describe Swift-version inference as the compile-gate policy."
            )
        }
    }

    func testIOSXcodeApplePQCCompileGateRequiresExplicitProbeSetting() throws {
        let projectYAML = try readSource("SkyBridge Compass iOS/project.yml")
        let pbxproj = try readSource("SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj/project.pbxproj")
        let deviceLane = try readSource("SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh")

        let forbiddenPattern = try NSRegularExpression(
            pattern: #"SWIFT_ACTIVE_COMPILATION_CONDITIONS\[sdk=(iphoneos|iphonesimulator)[0-9]+\*\].*HAS_APPLE_PQC_SDK"#
        )
        XCTAssertNil(
            forbiddenPattern.firstMatch(in: projectYAML, range: NSRange(projectYAML.startIndex..., in: projectYAML)),
            "project.yml must not infer Apple PQC SDK availability from SDK selectors."
        )
        XCTAssertNil(
            forbiddenPattern.firstMatch(in: pbxproj, range: NSRange(pbxproj.startIndex..., in: pbxproj)),
            "project.pbxproj must not infer Apple PQC SDK availability from SDK selectors."
        )
        XCTAssertGreaterThanOrEqual(projectYAML.components(separatedBy: #"SKYBRIDGE_APPLE_PQC_SDK_CONDITION: """#).count - 1, 2)
        XCTAssertGreaterThanOrEqual(
            projectYAML.components(separatedBy: #"SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) $(SKYBRIDGE_APPLE_PQC_SDK_CONDITION)""#).count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(pbxproj.components(separatedBy: #"SKYBRIDGE_APPLE_PQC_SDK_CONDITION = "";"#).count - 1, 4)
        XCTAssertGreaterThanOrEqual(
            pbxproj.components(separatedBy: #"SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) $(SKYBRIDGE_APPLE_PQC_SDK_CONDITION)";"#).count - 1,
            4
        )
        XCTAssertTrue(deviceLane.contains("validate_apple_pqc_sdk_condition_env()"))
        XCTAssertTrue(deviceLane.contains(#"build_args+=("SKYBRIDGE_APPLE_PQC_SDK_CONDITION=${SKYBRIDGE_APPLE_PQC_SDK_CONDITION}")"#))
    }

    func testMacOSSwiftPMScopesWebRTCAudioHeaderOverlayAndTestRPath() throws {
        let manifest = try readSource("Package.swift")
        let targetsUsingFrameworkHeadersDirectly = [
            "SkyBridgeCore",
            "SkyBridgeUI",
            "SkyBridgeCoreTests",
            "SkyBridgeBenchTests",
            "SkyBridgeCompassApp",
            "LocalLanInteropHost",
            "LocalWebRTCSmokeHost",
            "CurrentPathProbe",
            "BaselineBenchRunner",
            "HandshakeBenchRunner",
            "MessageSizeBenchRunner"
        ]

        let audioBridgeBody = try packageManifestTargetBody("WebRTCAudioDeviceBridge", in: manifest)
        XCTAssertTrue(
            audioBridgeBody.contains(#"["-I", webRTCAudioDeviceHeaderOverlayPath]"#)
                && audioBridgeBody.contains(#".when(platforms: [.macOS])"#),
            "Only the Objective-C audio-device bridge should receive the reviewed M150 RTCAudioDevice header overlay."
        )
        XCTAssertTrue(
            manifest.contains(#"let webRTCAudioDeviceHeaderOverlayPath = "\(packageRootPath)/Sources/Vendor/WebRTCM150AudioDeviceHeader""#)
        )
        XCTAssertFalse(
            manifest.contains("webRTCHeadersIncludePath"),
            "The removed general WebRTC header mirror must not remain as a second framework-header authority."
        )

        for targetName in targetsUsingFrameworkHeadersDirectly {
            let body = try packageManifestTargetBody(targetName, in: manifest)
            XCTAssertFalse(
                body.contains("webRTCAudioDeviceHeaderOverlayPath"),
                "\(targetName) must consume the M150 framework headers directly instead of inheriting the audio-device-only overlay."
            )
        }

        let productRootRPath = #"let swiftPMProductRootRPath = "@loader_path/../../..""#
        let testLinkerSettingsHelper = "func webRTCTestLinkerSettings() -> [LinkerSetting]"
        XCTAssertTrue(
            manifest.contains(productRootRPath),
            "SwiftPM test targets should share one canonical product-root rpath instead of spelling equivalent paths differently."
        )
        XCTAssertTrue(
            manifest.contains(testLinkerSettingsHelper),
            "SwiftPM test targets should share a named linker-settings helper so future targets do not duplicate rpath strings."
        )
        XCTAssertFalse(
            manifest.contains("@loader_path/../.././.."),
            "Do not hide duplicate rpath warnings by spelling the same path differently; fix rpath ownership instead."
        )

        let coreTestsBody = try packageManifestTargetBody("SkyBridgeCoreTests", in: manifest)
        XCTAssertTrue(
            coreTestsBody.contains("linkerSettings: webRTCTestLinkerSettings()"),
            "SkyBridgeCoreTests must search the SwiftPM product root for WebRTC.framework when Xcode 27 SwiftBuild places binary-target frameworks beside the test bundle."
        )
        let benchTestsBody = try packageManifestTargetBody("SkyBridgeBenchTests", in: manifest)
        XCTAssertFalse(
            benchTestsBody.contains("linkerSettings: webRTCTestLinkerSettings()"),
            "SwiftPM links package tests into one runner; adding the same WebRTC rpath from SkyBridgeBenchTests duplicates the runner LC_RPATH. OS27 lane prepares WebRTC.framework in PackageFrameworks before --skip-build test instead."
        )
        XCTAssertEqual(
            manifest.components(separatedBy: productRootRPath).count - 1,
            1,
            "The package should define the WebRTC SwiftPM product-root rpath once and reuse it through the named helper."
        )
        XCTAssertEqual(
            manifest.components(separatedBy: "linkerSettings: webRTCTestLinkerSettings()").count - 1,
            1,
            "The SwiftPM package test runner should receive the WebRTC product-root rpath exactly once."
        )
    }

    func testSwiftPMMetalResourcesDoNotCheckInCompilerIntermediates() throws {
        let manifest = try readSource("Package.swift")
        let sourceRoot = repositoryRoot().appendingPathComponent("Sources")
        let resourceIntermediates = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )?
            .compactMap { $0 as? URL }
            .filter { ["air", "metallib"].contains($0.pathExtension) }
            .map { $0.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "") }
            .sorted() ?? []

        XCTAssertTrue(
            resourceIntermediates.isEmpty,
            "SwiftPM resources must not include checked-in Metal compiler outputs: \(resourceIntermediates.joined(separator: ", "))"
        )
        XCTAssertFalse(
            manifest.contains(#".air""#),
            "Package.swift must not process Metal .air intermediates. Keep .metal sources as the resource contract and let the active toolchain produce the library."
        )
        XCTAssertTrue(
            manifest.contains("func metalResource(_ path: String) -> Resource"),
            "Package.swift should keep Metal shader resource policy centralized."
        )
        XCTAssertTrue(
            manifest.contains(".copy(path)"),
            "SwiftPM should copy .metal shader sources by default; SkyBridgeMetalShaderLibrary compiles copied sources at runtime and contract tests validate required functions."
        )
        XCTAssertFalse(
            manifest.contains("useCopiedMetalResourcesForOS27SwiftPMValidation"),
            "Metal resource handling must not depend on a validation-only environment override."
        )
        XCTAssertFalse(
            manifest.contains("SKYBRIDGE_OS27_SWIFTPM_COPY_METAL_RESOURCES"),
            "Metal resource handling must be the same in default SwiftPM builds and OS27 validation builds."
        )
        XCTAssertTrue(manifest.contains(#"metalResource("Rendering/WeatherShaders.metal")"#))
        XCTAssertTrue(manifest.contains(#"metalResource("Rendering/Metal4Shaders.metal")"#))
        XCTAssertTrue(manifest.contains(#"metalResource("GlobalHazeShaders.metal")"#))
    }

    func testReleasePackagingGatesMatchCopiedCoreMetalResourcePolicy() throws {
        let packageScript = try readSource("Scripts/package_app.sh")
        let readinessScript = try readSource("Scripts/check_macos_release_readiness.sh")
        let expectedCoreShaders = [
            "RemoteDesktopShaders",
            "RemoteDesktopPassthrough",
            "RemoteDesktopHDR",
            "Metal4Shaders",
            "AuroraShaders",
            "WeatherParticleShaders",
            "WeatherShaders",
            "RainShaders",
            "HazeShaders",
            "HazeParticleShaders"
        ]

        XCTAssertTrue(packageScript.contains("validate_core_metal_shader_sources"))
        XCTAssertTrue(readinessScript.contains("validate_core_metal_shader_sources"))
        XCTAssertFalse(
            packageScript.contains("缺少编译后的 SkyBridgeCore default.metallib"),
            "SkyBridgeCore Metal resources are copied source shaders and loaded through SkyBridgeMetalShaderLibrary."
        )
        XCTAssertFalse(
            readinessScript.contains("missing compiled SkyBridgeCore default.metallib"),
            "Release readiness must match the copied-source SkyBridgeCore Metal resource contract."
        )

        for shaderName in expectedCoreShaders {
            XCTAssertTrue(
                packageScript.contains("\(shaderName).metal"),
                "package_app.sh must validate \(shaderName).metal before release packaging succeeds."
            )
            XCTAssertTrue(
                readinessScript.contains("\(shaderName).metal"),
                "check_macos_release_readiness.sh must validate \(shaderName).metal after packaging."
            )
        }
    }

    func testOS27DiagnosisModeIsReadOnlyAndNotValidationProof() throws {
        let source = try readSource("Scripts/run_os27_beta_compatibility.sh")

        XCTAssertTrue(source.contains("--diagnose-environment"))
        XCTAssertTrue(source.contains("run_diagnose_environment()"))
        XCTAssertTrue(source.contains("full_validation=false"))
        XCTAssertTrue(source.contains("compatibility=not_validated"))
        XCTAssertTrue(source.contains("coverage=toolchain_sdk_device_readiness_only"))
        XCTAssertTrue(source.contains("SKYBRIDGE_OS27_COMPAT_REPORT_PATH"))
        XCTAssertTrue(source.contains("write_os27_compatibility_report()"))
        XCTAssertTrue(source.contains("Artifacts/os27/compatibility-report.json"))
        XCTAssertTrue(source.contains("\"release_eligible\": bool_value(\"OS27_REPORT_RELEASE_ELIGIBLE\")"))
        XCTAssertTrue(source.contains("xcrun devicectl list devices --json-output"))
        XCTAssertTrue(source.contains("print_xcode27_selected_bundle_diagnostics()"))
        XCTAssertTrue(source.contains("xcode27_bundle_diagnostic ready="))
        XCTAssertTrue(source.contains("record_xcode27_build_consistency()"))
        XCTAssertTrue(source.contains("xcode27_build_consistency status="))
        XCTAssertTrue(source.contains("metadata_mismatch"))
        XCTAssertTrue(source.contains("release_eligible=false evidence=environment_metadata_only"))
        XCTAssertTrue(source.contains("codesign -dv --verbose=4"))
        XCTAssertTrue(source.contains("codesign --verify --strict --verbose=2"))
        XCTAssertTrue(source.contains("spctl --status"))
        XCTAssertTrue(source.contains("xattr -p com.apple.quarantine"))
        XCTAssertFalse(
            source.contains("xattr -d com.apple.quarantine") || source.contains("xattr -dr com.apple.quarantine"),
            "OS27 diagnosis must not mutate Xcode beta quarantine metadata."
        )
        XCTAssertTrue(source.contains("matching_ipados27_beta_ipad_count"))
        XCTAssertTrue(source.contains("candidate_ipados27_ipad_count"))
        XCTAssertTrue(source.contains("developer_mode_unknown"))
        XCTAssertTrue(source.contains(#"tunnel_state == "connected""#))
        XCTAssertTrue(source.contains("tunnel_connected"))
        XCTAssertTrue(source.contains("ready_ipados27_beta_ipad_count"))
        XCTAssertTrue(source.contains("ready_ipados27_ipad_candidate_count"))
        XCTAssertTrue(source.contains("SKYBRIDGE_OS27_DIAGNOSTIC_TOOL_TIMEOUT_SECONDS"))
        XCTAssertTrue(source.contains("toolchain_invocation_timeout"))
        XCTAssertTrue(source.contains("return 2"))
        XCTAssertFalse(
            source.contains("serialNumber"),
            "OS27 diagnosis must publish sanitized device readiness summaries, not hardware identifiers."
        )

        guard
            let diagnoseRange = source.range(of: "run_diagnose_environment()"),
            let fullRange = source.range(of: "run_full_validation_lane()")
        else {
            return XCTFail("OS27 script must keep diagnosis and full validation in separate functions.")
        }

        let diagnosisSource = source[diagnoseRange.lowerBound..<fullRange.lowerBound]
        XCTAssertFalse(diagnosisSource.contains("apple_pqc_sdk_probe.sh"))
        XCTAssertFalse(diagnosisSource.contains("SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1"))
        XCTAssertFalse(diagnosisSource.contains("swift test"))
        XCTAssertFalse(diagnosisSource.contains("xcodebuild \\"))
        XCTAssertFalse(diagnosisSource.contains("test_lane_ios_device.sh"))
    }

    func testOS27SourceContractsModeDoesNotClaimCompatibilityValidation() throws {
        let source = try readSource("Scripts/run_os27_beta_compatibility.sh")

        XCTAssertTrue(source.contains("--verify-source-contracts"))
        XCTAssertTrue(source.contains("run_source_contracts()"))
        XCTAssertTrue(source.contains("mode=source-contracts full_validation=false compatibility=not_validated release_eligible=false coverage=source_contracts_only"))
        XCTAssertTrue(source.contains("Scripts/test_apple_pqc_sdk_probe_api.sh"))
        XCTAssertTrue(source.contains("Scripts/test_run_os27_beta_compatibility_diagnose.sh"))
        XCTAssertTrue(source.contains("Scripts/test_check_os27_compatibility_report.sh"))
        XCTAssertTrue(source.contains("Scripts/test_lane_ios_device_privacy.sh"))
        XCTAssertTrue(source.contains("Scripts/test_check_macos_deps.sh"))
        XCTAssertTrue(source.contains("Scripts/test_build_freerdp_dylibs_policy.sh"))
        XCTAssertTrue(source.contains("Scripts/test_check_ios_test_configuration.sh"))
        XCTAssertTrue(source.contains("Scripts/test_verify_xcode_toolchain.sh"))
        XCTAssertTrue(source.contains("Scripts/test_package_build_policy.sh"))
        XCTAssertTrue(source.contains("Scripts/test_validate_macos_release_artifact_run.sh"))
        XCTAssertTrue(source.contains("SKYBRIDGE_OS27_BUILD_GATE_TIMEOUT_SECONDS"))
        XCTAssertTrue(source.contains("run_command_with_timeout"))
        XCTAssertTrue(source.contains("ApplePQCSDKGateSourceContractTests"))
        XCTAssertTrue(source.contains("AppUpdateManifestTests"))
        XCTAssertTrue(source.contains("P2PRedactionSourceContractTests"))
        XCTAssertTrue(source.contains("export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1"))
        XCTAssertTrue(source.contains("source_contract_filter='SkyBridgeCoreTests.(ApplePQCSDKGateSourceContractTests|AppleDesignAPISourceContractTests|AppleAIAdvisorySourceContractTests|AppleAppIntentAuthoritySourceContractTests|AIAdvisoryBoundaryTests|MetalShaderSourceCompileContractTests|AppUpdateManifestTests|QuantumCryptoManagerStrictPQCPolicyTests|P2PRedactionSourceContractTests)'"))
        XCTAssertTrue(
            source.contains(#"run_swiftpm_clean_log_test "${source_contract_filter}""#),
            "Source-contract mode must reuse the build-tests -> prepare WebRTC.framework -> --skip-build test path. SwiftPM test discovery loads all bundles before applying --filter."
        )
        XCTAssertFalse(
            source.contains(#"swift test --scratch-path "$(swiftpm_scratch_path)" -Xswiftc -warnings-as-errors"#),
            "Xcode 27 SwiftPM can combine package-dependency -suppress-warnings with explicit -warnings-as-errors. Source-contract tests must use clean-log gating instead."
        )
        XCTAssertFalse(
            source.contains(#"swift test --scratch-path "$(swiftpm_scratch_path)" --filter "SkyBridgeCoreTests.ApplePQCSDKGateSourceContractTests""#),
            "Direct swift test --filter still triggers test bundle discovery for SkyBridgeBenchTests before the filter runs."
        )
        XCTAssertTrue(source.contains("source_contracts=verified full_validation=false compatibility=not_validated release_eligible=false"))
        XCTAssertTrue(source.contains("OS27_REPORT_SOURCE_CONTRACTS_STATUS=\"passed\""))
        XCTAssertTrue(source.contains("OS27_REPORT_STATUS=\"source_contracts_verified\""))

        guard
            let guardrailRange = source.range(of: "run_source_contract_guardrail_scripts()"),
            let packagePolicySourceRange = source.range(of: "# shellcheck source=Scripts/package_build_policy.sh")
        else {
            return XCTFail("OS27 script must keep the source-contract guardrail list explicit and source package policy after it.")
        }

        let guardrailBody = source[guardrailRange.lowerBound..<packagePolicySourceRange.lowerBound]
        let bareGuardrailCommands = guardrailBody
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("bash Scripts/") && !$0.contains("|| return 1") }
        XCTAssertTrue(
            bareGuardrailCommands.isEmpty,
            "Source-contract guardrails must explicitly return failure per child command; outer if/errexit must not be trusted: \(bareGuardrailCommands.joined(separator: ", "))"
        )

        guard
            let sourceContractsRange = source.range(of: "run_source_contracts()"),
            let nextFunctionRange = source.range(of: "\nrun_swiftpm_clean_log()")
        else {
            return XCTFail("OS27 script must keep source-contract, diagnosis, and full validation in separate functions.")
        }

        let sourceContractsBody = source[sourceContractsRange.lowerBound..<nextFunctionRange.lowerBound]
        XCTAssertFalse(sourceContractsBody.contains("[os27-beta-compat] passed"))
        XCTAssertFalse(sourceContractsBody.contains("OS27_REPORT_COMPATIBILITY=\"validated\""))
        XCTAssertFalse(sourceContractsBody.contains("OS27_REPORT_RELEASE_ELIGIBLE=\"1\""))
        XCTAssertFalse(sourceContractsBody.contains("OS27_REPORT_FULL_VALIDATION=\"1\""))
        XCTAssertFalse(sourceContractsBody.contains("OS27_REPORT_FULL_VALIDATION_PASSED=\"1\""))
        XCTAssertFalse(sourceContractsBody.contains("xcodebuild \\"))
        XCTAssertFalse(sourceContractsBody.contains("test_lane_ios_device.sh"))
        XCTAssertFalse(sourceContractsBody.contains("publish_macos_update_release.sh"))
    }

    func testOS27CompatibilityReportCheckerRejectsStaleOrReleaseEligibleEvidence() throws {
        let checker = try readSource("Scripts/check_os27_compatibility_report.py")
        let checkerTests = try readSource("Scripts/test_check_os27_compatibility_report.sh")
        let os27Lane = try readSource("Scripts/run_os27_beta_compatibility.sh")

        XCTAssertTrue(checker.contains("EXPECTED_SCHEMA_VERSION = 2"))
        XCTAssertTrue(checker.contains("EXPECTED_OS27_SYMBOL_SET = \"cryptokit-pqc-os27-v1\""))
        XCTAssertTrue(checker.contains("EXPECTED_PQC_SYMBOL_PROOF_SCOPE = \"cryptokit_compile_time_symbol_surface_only\""))
        XCTAssertTrue(checker.contains("EXPECTED_APPLE_RUNTIME_PROOF_SCOPE = \"apple_cryptokit_runtime_self_test_only\""))
        XCTAssertTrue(checker.contains("--require-full-validation"))
        XCTAssertTrue(checker.contains("--require-source-contracts"))
        XCTAssertTrue(checker.contains("release_eligible must be false"))
        XCTAssertTrue(checker.contains("affects_session_status must be false"))
        XCTAssertTrue(checker.contains("server_support_required must be true"))
        XCTAssertTrue(checker.contains("session_negotiated must be false"))
        XCTAssertTrue(checker.contains("affects_crypto_suite_selection"))
        XCTAssertTrue(checker.contains("REQUIRED_IOS_DEVICE_TEST"))
        XCTAssertTrue(checker.contains("\"gates.required_ios_device_test\": \"passed\""))
        XCTAssertTrue(checker.contains("\"apple_quantum_secure_runtime_proof.status\": \"passed\""))

        XCTAssertTrue(checkerTests.contains("stale-v1"))
        XCTAssertTrue(checkerTests.contains("wrong-symbol"))
        XCTAssertTrue(checkerTests.contains("release-eligible"))
        XCTAssertTrue(checkerTests.contains("network-affects-suite"))
        XCTAssertTrue(checkerTests.contains("network-server-support-not-required"))
        XCTAssertTrue(checkerTests.contains("network-session-negotiated"))
        XCTAssertTrue(checkerTests.contains("network-affects-session"))
        XCTAssertTrue(checkerTests.contains("network-release-eligible"))
        XCTAssertTrue(checkerTests.contains("pqc-symbol-affects-session"))
        XCTAssertTrue(checkerTests.contains("runtime-session-negotiated"))
        XCTAssertTrue(checkerTests.contains("--require-full-validation"))
        XCTAssertTrue(checkerTests.contains("--require-source-contracts"))

        XCTAssertTrue(os27Lane.contains("OS27_COMPAT_REPORT_SCHEMA_VERSION=2"))
        XCTAssertTrue(os27Lane.contains("bash Scripts/test_check_os27_compatibility_report.sh"))
    }

    func testPQCStatusSurfacesKeepCapabilitySeparateFromSessionProof() throws {
        let presentation = try readSource("Sources/SkyBridgeCore/P2P/ConnectionCryptoPresentation.swift")
        let macDashboard = try readSource("Sources/SkyBridgeCompassApp/DashboardViewModel.swift")
        let iosPresentation = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/ConnectionPresentationContract.swift")
        let iosDeviceRow = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/Dashboard/Components/DeviceRowView.swift")
        let iosErrorFormatter = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/P2PHandshakeErrorFormatter.swift")
        let securitySettings = try readSource("Sources/SkyBridgeCore/UI/SecuritySettingsView.swift")
        let systemRequirements = try readSource("Sources/SkyBridgeCore/QuantumSecure/PQCProvider.swift")

        XCTAssertTrue(presentation.contains("suiteToken.contains(\"mlkem\") || suiteToken.contains(\"mldsa\") || suiteToken.contains(\"xwing\")"))
        XCTAssertTrue(presentation.contains("inferredModeLabelForCurrentPolicy"))
        XCTAssertTrue(presentation.contains(") -> String? {\n        nil\n    }"))
        XCTAssertFalse(macDashboard.contains("defaultPQCModeLabel: ConnectionCryptoPresentation.inferredModeLabelForCurrentPolicy"))
        XCTAssertTrue(macDashboard.contains("defaultPQCModeLabel: nil"))

        XCTAssertTrue(iosPresentation.contains("suiteToken.contains(\"mlkem\") || suiteToken.contains(\"mldsa\") || suiteToken.contains(\"xwing\")"))
        XCTAssertTrue(iosDeviceRow.contains("PQCCapabilityBadge"))
        XCTAssertTrue(iosDeviceRow.contains("PQC 候选能力；不是当前连接证明"))
        XCTAssertTrue(iosErrorFormatter.contains("当前构建、运行时或协商证据不足"))
        XCTAssertFalse(iosErrorFormatter.contains("需要 macOS 26/iOS 26 或更高版本"))

        XCTAssertTrue(securitySettings.contains("候选就绪"))
        XCTAssertTrue(securitySettings.contains("等待协商证明"))
        XCTAssertTrue(systemRequirements.contains("不代表当前连接已使用 PQC"))
        XCTAssertTrue(systemRequirements.contains("不要仅凭系统版本或 SDK 符号显示"))
    }

    func testOS27AdaptationPlanDocumentsWWDC26AdoptionBoundaries() throws {
        let plan = try readSource("Docs/os27-adaptation-plan-2026-06.md")
        let sourceRoots = [
            "Sources",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources"
        ]
        let sourceImports = sourceRoots.flatMap { relativeRoot -> [String] in
            let sourceRoot = repositoryRoot().appendingPathComponent(relativeRoot)
            return FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .flatMap { url -> [String] in
                    let relativePath = url.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "")
                    let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    return source
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .enumerated()
                        .compactMap { index, line in
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            if trimmed == "import FoundationModels" || trimmed == "import CoreAI" {
                                return "\(relativePath):\(index + 1):\(trimmed)"
                            }
                            return nil
                        }
                } ?? []
        }
        let integrationFiles = [
            "Package.swift",
            "project.yml",
            "SkyBridge Compass iOS/Package.swift",
            "SkyBridge Compass iOS/project.yml",
            "SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj/project.pbxproj"
        ]
        let prematureAIFrameworkReferences = try integrationFiles.flatMap { relativePath -> [String] in
            let source = try readSource(relativePath)
            return ["FoundationModels", "CoreAI"].compactMap { token in
                source.contains(token) ? "\(relativePath):\(token)" : nil
            }
        }

        XCTAssertTrue(plan.contains("WWDC26 技术采用矩阵"))
        XCTAssertTrue(plan.contains("PQC adoption matrix"))
        XCTAssertTrue(plan.contains("release_eligible=false"))
        XCTAssertTrue(plan.contains("symbol_probe"))
        XCTAssertTrue(plan.contains("cryptokit-pqc-os27-v1"))
        XCTAssertTrue(plan.contains("source_contracts=verified full_validation=false compatibility=not_validated release_eligible=false"))
        XCTAssertTrue(plan.contains("status=source_contracts_verified"))
        XCTAssertTrue(plan.contains("coverage=source_contracts_only"))
        XCTAssertTrue(plan.contains("gates.source_contracts=passed"))
        XCTAssertTrue(plan.contains("schema_version=2"))
        XCTAssertTrue(plan.contains("Scripts/check_os27_compatibility_report.py --require-full-validation"))
        XCTAssertTrue(plan.contains("旧 `/tmp` full-validation JSON"))
        XCTAssertTrue(plan.contains("默认路径 `Artifacts/os27/compatibility-report.json` 是最新一次 lane 的可变产物"))
        XCTAssertTrue(plan.contains("必须直接读取 JSON 字段"))
        XCTAssertFalse(plan.contains("当前仓库默认 `Artifacts/os27/compatibility-report.json` 仍记录最近一次无真机 partial 结果"))
        XCTAssertTrue(plan.contains("稳定 release manifest"))
        XCTAssertTrue(plan.contains("runtime proof"))
        XCTAssertTrue(plan.contains("Xcode 27 beta lane `release_eligible=false`"))
        XCTAssertTrue(plan.contains("OS27 source-contract 本身 `release_eligible=false`"))
        XCTAssertTrue(plan.contains("Network.framework TLS hybrid KEX"))
        XCTAssertTrue(plan.contains("network-tls-pqc-v1"))
        XCTAssertTrue(plan.contains("proof_scope=transport_sdk_public_api_surface_only"))
        XCTAssertTrue(plan.contains("server_support_required=true"))
        XCTAssertTrue(plan.contains("session_negotiated=false"))
        XCTAssertTrue(plan.contains("affects_session_status=false"))
        XCTAssertTrue(plan.contains("affects_crypto_suite_selection=false"))
        XCTAssertTrue(plan.contains("本仓库显式 `SwiftTLSOptions.KeyExchangeGroup.x25519MLKEM768` 配置探针当前不能作为 source-level proof"))
        XCTAssertTrue(plan.contains("不能进入 `CryptoSuite`"))
        XCTAssertTrue(plan.contains("WWDC26 官方资料中没有可直接用于本项目的量子通信、QKD 或量子网络 app API"))
        XCTAssertTrue(plan.contains("任何“量子通信”产品文案都不得替代 PQC 证明链"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/news/releases/"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/documentation/cryptokit/enhancing-your-app-s-privacy-and-security-with-quantum-secure-workflows"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/documentation/foundationmodels"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/documentation/coreai"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/documentation/cryptokit/hpke/ciphersuite/xwingmlkem768x25519_sha256_aes_gcm_256"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/videos/play/wwdc2026/258/"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/videos/play/wwdc2026/260/"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/videos/play/wwdc2026/379/"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/videos/play/wwdc2026/201/"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/videos/play/wwdc2026/347/"))
        XCTAssertTrue(plan.contains("https://developer.apple.com/documentation/technologyoverviews/liquid-glass"))
        XCTAssertTrue(plan.contains("Foundation Models framework"))
        XCTAssertTrue(plan.contains("Private Cloud Compute"))
        XCTAssertTrue(plan.contains("Core AI framework"))
        XCTAssertTrue(plan.contains("AppIntentsTesting"))
        XCTAssertTrue(plan.contains("Device Hub"))
        XCTAssertTrue(plan.contains("模型输出只能 advisory"))
        XCTAssertTrue(plan.contains("AIAdvisoryInputDTO"))
        XCTAssertTrue(plan.contains("AIAdvisoryOutputDTO"))
        XCTAssertTrue(plan.contains("脱敏 DTO"))
        XCTAssertTrue(plan.contains("禁止日志原文"))
        XCTAssertTrue(plan.contains("不得读取密钥、连接码、raw logs、网络拓扑、文件名或 handshake transcript"))
        XCTAssertTrue(plan.contains("不得直接触发连接、文件传输、远程桌面、信任变更、密钥迁移或 release eligibility"))
        XCTAssertTrue(plan.contains("禁止进入握手/加密/媒体热路径"))
        XCTAssertTrue(plan.contains("不把 GUI 连接状态、`devicectl` 可见状态或 Simulator 状态当 runtime proof"))
        XCTAssertTrue(plan.contains("不创建 OS27-only suite"))
        XCTAssertTrue(plan.contains("不能把模型输出当安全事实"))
        XCTAssertTrue(plan.contains("Release baseline 切换到 Xcode 27 正式版前"))
        XCTAssertTrue(plan.contains("macOS 14+ / iOS 17+"))
        XCTAssertTrue(plan.contains("pre-2020 A12/A12X 设备只允许在具体能力层标记 legacy-limited"))
        XCTAssertTrue(plan.contains("不得用 deployment target 提升来“获得”API"))
        XCTAssertTrue(
            sourceImports.isEmpty,
            "FoundationModels/CoreAI imports must not enter production sources before an explicit adapter, availability guard, and tests exist: \(sourceImports.joined(separator: ", "))"
        )
        XCTAssertTrue(
            prematureAIFrameworkReferences.isEmpty,
            "FoundationModels/CoreAI framework references must not enter package or Xcode integration before an explicit adapter, availability guard, and tests exist: \(prematureAIFrameworkReferences.joined(separator: ", "))"
        )
    }

    func testApplePlatformFeatureRegistryDocumentsOS27AdoptionBoundaries() throws {
        let registrySource = try readSource("Sources/SkyBridgeCore/Diagnostics/ApplePlatformFeatureRegistry.swift")
        let provenanceSource = try readSource("Sources/SkyBridgeCore/Diagnostics/ApplePQCSDKBuildProvenance.swift")
        let plan = try readSource("Docs/os27-adaptation-plan-2026-06.md")

        let expectedIDs = [
            "cryptokit-pqc-v1",
            "cryptokit-pqc-os27-v1",
            "network-tls-pqc-v1",
            "device-hub-diagnostics",
            "liquid-glass-wrapper",
            "foundation-models-advisory",
            "core-ai-advisory",
            "app-intents-pending-confirmation"
        ]

        for id in expectedIDs {
            XCTAssertTrue(registrySource.contains(#"= "\#(id)""#), "Registry must define feature ID \(id).")
            XCTAssertTrue(plan.contains(id), "OS27 adaptation plan must mention registry feature ID \(id).")
        }

        XCTAssertEqual(
            expectedIDs.count,
            Set(expectedIDs).count,
            "Apple platform feature IDs must be unique."
        )
        XCTAssertTrue(provenanceSource.contains(#"stableReleaseSymbolSet = "cryptokit-pqc-v1""#))
        XCTAssertTrue(provenanceSource.contains(#"os27BetaSymbolSet = "cryptokit-pqc-os27-v1""#))
        XCTAssertTrue(provenanceSource.contains(#"networkTLSPQCSymbolSet = "network-tls-pqc-v1""#))
        XCTAssertTrue(provenanceSource.contains("requiredSymbolSet = stableReleaseSymbolSet"))

        let forbiddenReleaseEligibleRecords = [
            ".cryptokitPQCOS27Beta",
            ".networkTLSPQCProbe",
            ".deviceHubDiagnostics",
            ".foundationModelsAdvisory",
            ".coreAIAdvisory",
            ".appIntentsPendingConfirmation"
        ]
        for marker in forbiddenReleaseEligibleRecords {
            guard let recordStart = registrySource.range(of: "id: \(marker)") else {
                return XCTFail("Missing registry record: \(marker)")
            }
            let suffix = registrySource[recordStart.lowerBound...]
            let recordEnd = suffix.range(of: "SkyBridgeApplePlatformFeatureRecord(", options: [], range: suffix.index(after: recordStart.lowerBound)..<suffix.endIndex)?.lowerBound ?? suffix.endIndex
            let record = String(suffix[..<recordEnd])
            XCTAssertTrue(record.contains("releaseEligible: false"), "\(marker) must not be release eligible.")
        }

        XCTAssertTrue(registrySource.contains("id: .cryptokitPQCStable"))
        XCTAssertTrue(registrySource.contains("releaseEligible: true"))
        XCTAssertTrue(registrySource.contains("siri_pending_request_and_widget_navigation_only"))
        XCTAssertTrue(registrySource.contains("manual_device_diagnostics_only"))
        XCTAssertTrue(registrySource.contains("requires server support"))
        XCTAssertTrue(registrySource.contains("redacted_advisory_dto_only"))
        XCTAssertTrue(registrySource.contains("transport_sdk_public_api_surface_only"))
        XCTAssertTrue(registrySource.contains("compatibility_wrapper_with_old_os_fallback"))
    }

    func testIOSStartupLogsDoNotExposeSupabaseHost() throws {
        let supabaseService = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Auth/SupabaseService.swift")
        let appSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift")

        let forbiddenFragments = [
            "Supabase 配置来源=Keychain host=",
            "Supabase 配置来源=Info.plist host=",
            "Supabase 配置来源=SupabaseConfig.plist(host=",
            "Supabase 配置来源=Bundle.module(host=",
            "Supabase resolved host=",
            #"print("🔐 Supabase resolved host="#
        ]

        for fragment in forbiddenFragments {
            XCTAssertFalse(
                supabaseService.contains(fragment) || appSource.contains(fragment),
                "iOS startup/config logs must not expose concrete Supabase hosts: \(fragment)"
            )
        }

        XCTAssertTrue(supabaseService.contains("logResolvedConfiguration(source: \"Keychain\")"))
        XCTAssertTrue(supabaseService.contains("logResolvedConfiguration(source: \"Info.plist\")"))
        XCTAssertTrue(supabaseService.contains("logResolvedConfiguration(source: \"SupabaseConfig.plist\")"))
        XCTAssertTrue(supabaseService.contains("logResolvedConfiguration(source: \"Bundle.module\")"))
        XCTAssertTrue(appSource.contains("Supabase 配置状态=present"))
    }

    func testRemoteDesktopStreamRefreshTokensAreNotLoggedRaw() throws {
        let sourcePaths = [
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        ]
        let forbiddenFragments = [
            "streamRefreshToken.map(String.init)",
            "token=\\(refreshToken",
            "token=\\(token",
            "token=\\(ack.streamRefreshToken",
            "previous=\\(previousConfig?.streamRefreshToken"
        ]

        for sourcePath in sourcePaths {
            let source = try readSource(sourcePath)
            XCTAssertTrue(
                source.contains("streamRefreshTokenLogState"),
                "\(sourcePath) must keep an explicit stream-refresh-token log redaction helper."
            )
            for fragment in forbiddenFragments {
                XCTAssertFalse(
                    source.contains(fragment),
                    "\(sourcePath) must not expose raw stream refresh tokens in logs or smoke diagnostics: \(fragment)"
                )
            }
        }
    }

    func testProductionSourcesDoNotIntroduceOS27OnlyAvailabilityBranches() throws {
        let sourceRoots = [
            "Sources",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources"
        ]
        let os27AvailabilityReferences = sourceRoots.flatMap { relativeRoot -> [String] in
            let sourceRoot = repositoryRoot().appendingPathComponent(relativeRoot)
            return FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .flatMap { url -> [String] in
                    let relativePath = url.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "")
                    let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    return source
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .enumerated()
                        .compactMap { index, line in
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.hasPrefix("//") else { return nil }
                            let introducesAvailabilityBranch = trimmed.contains("#available(")
                                || trimmed.contains("@available(")
                            guard introducesAvailabilityBranch, trimmed.contains("27") else {
                                return nil
                            }
                            return "\(relativePath):\(index + 1):\(trimmed)"
                        }
                } ?? []
        }

        XCTAssertTrue(
            os27AvailabilityReferences.isEmpty,
            "OS27 beta work must not create production OS27-only branches. Keep new APIs behind SDK symbol probes, compile gates, and runtime proof instead: \(os27AvailabilityReferences.joined(separator: ", "))"
        )
    }

    func testMacOSReleaseWorkflowRunsOS27SourceContractsWithoutSwitchingToBetaToolchain() throws {
        let workflow = try readSource(".github/workflows/macos-release-readiness.yml")

        XCTAssertTrue(workflow.contains("os27-source-contracts:"))
        XCTAssertTrue(workflow.contains("bash Scripts/run_os27_beta_compatibility.sh --verify-source-contracts"))
        XCTAssertTrue(workflow.contains("needs: [macos-preflight, os27-source-contracts]"))

        guard
            let sourceContractsRange = workflow.range(of: "  os27-source-contracts:"),
            let signedReleaseRange = workflow.range(of: "  macos-signed-release-gate:")
        else {
            return XCTFail("Release workflow must keep os27-source-contracts as a separate job before signed release evaluation.")
        }

        let sourceContractsJob = workflow[sourceContractsRange.lowerBound..<signedReleaseRange.lowerBound]
        XCTAssertTrue(sourceContractsJob.contains("DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer"))
        XCTAssertTrue(sourceContractsJob.contains("bash Scripts/verify_xcode_toolchain.sh"))
        XCTAssertFalse(
            sourceContractsJob.contains("sudo xcode-select"),
            "OS27 source-contract CI must not globally switch the runner into a beta toolchain."
        )
        XCTAssertFalse(
            sourceContractsJob.contains("Xcode-beta"),
            "OS27 source-contract CI should remain stable-toolchain static coverage, not a beta runtime validation lane."
        )
    }

    func testReleaseScriptsDoNotConsumeOS27BetaCompatibilityReport() throws {
        let releaseSources = try [
            "Scripts/generate_macos_update_manifest.swift",
            "Scripts/publish_macos_update_release.sh",
            "Scripts/check_macos_release_readiness.sh",
            "Scripts/package_app.sh",
            "Scripts/build_dmg.sh",
            "Scripts/package_build_policy.sh"
        ].map(readSource).joined(separator: "\n")
        let os27Lane = try readSource("Scripts/run_os27_beta_compatibility.sh")

        XCTAssertTrue(os27Lane.contains("SKYBRIDGE_OS27_COMPAT_REPORT_PATH"))
        XCTAssertTrue(os27Lane.contains("Artifacts/os27/compatibility-report.json"))

        [
            "SKYBRIDGE_OS27_COMPAT_REPORT_PATH",
            "Artifacts/os27/compatibility-report.json",
            "compatibility-report.json",
            "OS27_REPORT_RELEASE_ELIGIBLE",
            "source_contracts=verified",
            "partial_not_validated"
        ].forEach { forbidden in
            XCTAssertFalse(
                releaseSources.contains(forbidden),
                "Stable release scripts must not consume OS27 beta compatibility report output as release proof: \(forbidden)"
            )
        }
    }

    func testApplePQCSDKTypesStayBehindCompileGate() throws {
        let sources = [
            "Sources/SkyBridgeCore/Security/P2PSecurityManager.swift",
            "Sources/SkyBridgeCore/QuantumSecure/PQCKeyMigrationTool.swift"
        ]
        let sensitiveTokens = [
            "XWingMLKEM768X25519.",
            "HPKE.Ciphersuite.XWingMLKEM768X25519",
            "SecureEnclave.MLKEM",
            "MLKEM768.PublicKey",
            "MLDSA65.",
            "MLDSA87."
        ]

        for sourcePath in sources {
            let source = try readSource(sourcePath)
            var conditionalStack: [Bool] = []
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if") {
                    conditionalStack.append(trimmed.contains("HAS_APPLE_PQC_SDK"))
                } else if trimmed.hasPrefix("#endif") {
                    _ = conditionalStack.popLast()
                }

                guard !trimmed.hasPrefix("//") else { continue }
                let containsApplePQCSDKType = sensitiveTokens.contains { line.contains($0) }
                if containsApplePQCSDKType {
                    XCTAssertTrue(
                        conditionalStack.contains(true),
                        "\(sourcePath):\(index + 1) references Apple PQC SDK types outside #if HAS_APPLE_PQC_SDK: \(line)"
                    )
                }
            }
        }
    }

    func testOS27DeviceLaneValidatesExplicitDeviceIdentifiers() throws {
        let deviceLane = try readSource("SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh")
        let os27Lane = try readSource("Scripts/run_os27_beta_compatibility.sh")

        XCTAssertFalse(
            deviceLane.contains(#"DEVICE_ID="${SKYBRIDGE_IOS_DEVICE_ID:-$(pick_device_id)}""#),
            "Explicit SKYBRIDGE_IOS_DEVICE_ID must not bypass OS/release/device-type constraints."
        )
        XCTAssertTrue(deviceLane.contains("requested_identifier = os.environ.get(\"SKYBRIDGE_IOS_DEVICE_ID\")"))
        XCTAssertTrue(deviceLane.contains("SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD"))
        XCTAssertTrue(deviceLane.contains("does not satisfy required constraints"))
        XCTAssertTrue(deviceLane.contains("developerModeStatus\") != \"enabled\""))
        XCTAssertTrue(deviceLane.contains("unsupported environment variable: ${name}"))
        XCTAssertTrue(deviceLane.contains("validate_major_env SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR"))
        XCTAssertTrue(deviceLane.contains("validate_boolean_env SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD"))
        XCTAssertTrue(deviceLane.contains("SKYBRIDGE_IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS"))
        XCTAssertTrue(deviceLane.contains("validate_positive_integer_env SKYBRIDGE_IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS"))
        XCTAssertTrue(deviceLane.contains("-destination-timeout \"${IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS}\""))
        XCTAssertTrue(deviceLane.contains("DEVICE_REDACTION_TOKENS_FILE"))
        XCTAssertTrue(deviceLane.contains("redact_ios_device_log"))
        XCTAssertTrue(deviceLane.contains("3<&0"))
        XCTAssertTrue(deviceLane.contains("-destination \"platform=iOS,id=${DEVICE_ID}\""))
        XCTAssertFalse(deviceLane.contains("device=${DEVICE_ID}"))
        XCTAssertFalse(deviceLane.contains("cat \"${log_path}\""))

        XCTAssertTrue(os27Lane.contains("SKYBRIDGE_OS27_RUN_IOS_DEVICE_TESTS"))
        XCTAssertTrue(os27Lane.contains("reject_conflicting_os27_device_gate_env SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR \"${expected_os_major}\""))
        XCTAssertTrue(
            os27Lane.contains("reject_conflicting_os27_device_gate_env SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE \"${expected_release_type}\""),
            "The OS27 beta full lane must reject external environment that weakens the iPadOS 27 Beta runtime gate."
        )
        XCTAssertTrue(os27Lane.contains("reject_conflicting_os27_device_gate_env SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD \"${expected_ipad_required}\""))
        XCTAssertTrue(os27Lane.contains("SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=\"${expected_os_major}\""))
        XCTAssertTrue(os27Lane.contains("SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=\"${expected_release_type}\""))
        XCTAssertTrue(os27Lane.contains("SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=\"${expected_ipad_required}\""))
        XCTAssertFalse(
            os27Lane.contains("SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=\"${SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE:-Beta}\""),
            "The OS27 beta full lane must not allow external releaseType env to override the required Beta gate."
        )
        XCTAssertFalse(
            os27Lane.contains("SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=\"${SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD:-1}\""),
            "The OS27 beta full lane must not allow external iPad env to override the required iPad gate."
        )
        XCTAssertFalse(
            os27Lane.contains("SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=\"${SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE:-}\""),
            "The OS27 beta full lane must not allow a missing releaseType constraint to satisfy the required runtime proof."
        )
        XCTAssertTrue(os27Lane.contains("SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS=1"))
        XCTAssertTrue(os27Lane.contains("SKYBRIDGE_OS27_ALLOW_PARTIAL_WITHOUT_DEVICE"))
        XCTAssertTrue(os27Lane.contains("iOS 27 beta physical-device PQC runtime tests were not run"))
        XCTAssertTrue(os27Lane.contains("SKYBRIDGE_OS27_ALLOW_ALTERNATE_DEVICE_TEST"))
        XCTAssertTrue(os27Lane.contains("run_ios27_device_pqc_runtime_test()"))
        XCTAssertTrue(os27Lane.contains(#"OS27_REQUIRED_IOS_DEVICE_PQC_RUNTIME_TEST='SkyBridgeCompassiOSTests/ApplePQCProviderRuntimeSelfTestTests/testApplePQCAndXWingProbesGenerateKeysOnAvailableRuntime'"#))
        XCTAssertTrue(os27Lane.contains(#"required_ios_device_test="${OS27_REQUIRED_IOS_DEVICE_PQC_RUNTIME_TEST}""#))
        XCTAssertTrue(os27Lane.contains(#"run_ios27_device_pqc_runtime_test "${required_ios_device_test}""#))
        XCTAssertTrue(os27Lane.contains(#"run_ios27_device_pqc_runtime_test "${requested_ios_device_test}""#))
        XCTAssertFalse(
            os27Lane.contains(#"ios_device_test="${SKYBRIDGE_OS27_IOS_DEVICE_TEST:-${required_ios_device_test}}""#),
            "SKYBRIDGE_OS27_IOS_DEVICE_TEST must not replace the required ApplePQC/X-Wing runtime self-test; alternates can only run as additional diagnostics."
        )
        if
            let requiredRun = os27Lane.range(of: #"run_ios27_device_pqc_runtime_test "${required_ios_device_test}""#),
            let alternateRun = os27Lane.range(of: #"run_ios27_device_pqc_runtime_test "${requested_ios_device_test}""#)
        {
            XCTAssertLessThan(
                requiredRun.lowerBound,
                alternateRun.lowerBound,
                "The required ApplePQC/X-Wing runtime self-test must run before any alternate device diagnostic test."
            )
        } else {
            XCTFail("OS27 device lane must run the required PQC runtime gate and then any alternate diagnostic.")
        }
        XCTAssertTrue(os27Lane.contains("compatibility=partial_not_validated"))
        XCTAssertTrue(os27Lane.contains("OS27_REPORT_STATUS=\"partial\""))
        XCTAssertTrue(os27Lane.contains("OS27_REPORT_COMPATIBILITY=\"partial_not_validated\""))
        XCTAssertTrue(os27Lane.contains("OS27_REPORT_RELEASE_ELIGIBLE=\"0\""))
        XCTAssertTrue(os27Lane.contains("OS27_REPORT_REQUIRED_IOS_DEVICE_TEST_STATUS=\"skipped\""))
        XCTAssertTrue(os27Lane.contains("skipped_iOS_build_gates"))
        XCTAssertTrue(os27Lane.contains("SKYBRIDGE_OS27_SKIP_IOS_GENERIC_BUILD"))
        XCTAssertTrue(os27Lane.contains("SKYBRIDGE_OS27_SKIP_IOS_SIMULATOR_BUILD"))
        XCTAssertTrue(
            os27Lane.contains("*/out/Products/Debug/WebRTC.framework")
                && os27Lane.contains("*/debug/WebRTC.framework"),
            "OS27 source-contract lane must support both Xcode beta and stable SwiftPM scratch WebRTC framework layouts."
        )
        XCTAssertFalse(
            os27Lane.contains("device runtime gate skipped by explicit diagnostic override.\"\n      exit 0"),
            "Partial OS27 diagnostics must not exit 0 in a way that can be mistaken for full compatibility validation."
        )
    }

    func testReleasePackagingCannotBypassApplePQCSDKProbeWithDiagnosticOverride() throws {
        let policy = try readSource("Scripts/package_build_policy.sh")
        let buildDMG = try readSource("Scripts/build_dmg.sh")
        let packageApp = try readSource("Scripts/package_app.sh")
        let releaseReadiness = try readSource("Scripts/check_macos_release_readiness.sh")
        let publisher = try readSource("Scripts/publish_macos_update_release.sh")
        let manifestGenerator = try readSource("Scripts/generate_macos_update_manifest.swift")
        let manifestEvaluator = try readSource("Sources/SkyBridgeCore/Updates/AppUpdateManifest.swift")
        let provenance = try readSource("Sources/SkyBridgeCore/Diagnostics/ApplePQCSDKBuildProvenance.swift")
        let appSource = try readSource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")

        XCTAssertTrue(policy.contains("skybridge_configure_apple_pqc_sdk_for_package_context"))
        XCTAssertTrue(policy.contains("skybridge_require_apple_pqc_sdk_symbol_probe macosx"))
        XCTAssertTrue(policy.contains("skybridge_apple_pqc_sdk_probe_succeeded"))
        XCTAssertTrue(policy.contains("symbol_probe"))
        XCTAssertTrue(policy.contains("app|release_dmg"))
        XCTAssertTrue(policy.contains("禁止使用 SKYBRIDGE_ALLOW_RELEASE_WITHOUT_APPLE_PQC_SDK"))
        XCTAssertTrue(policy.contains("skybridge_assert_bundle_has_apple_pqc_compile_marker"))
        XCTAssertTrue(policy.contains("skybridge_assert_release_stable_toolchain"))
        XCTAssertTrue(policy.contains("skybridge_assert_release_app_stable_platform_metadata"))
        XCTAssertTrue(policy.contains("SkyBridgePackagingApplePQCSDKCompiledWithHASApplePQCSDK"))
        XCTAssertTrue(policy.contains("SkyBridgePackagingApplePQCSDKSymbolSet"))

        XCTAssertTrue(provenance.contains("#if HAS_APPLE_PQC_SDK"))
        XCTAssertTrue(provenance.contains("skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk"))
        XCTAssertTrue(appSource.contains("SkyBridgeApplePQCSDKBuildProvenance.compileMarker"))

        XCTAssertFalse(
            buildDMG.contains("SKYBRIDGE_ALLOW_RELEASE_WITHOUT_APPLE_PQC_SDK"),
            "Release DMG entrypoint must not allow diagnostic Apple PQC bypasses."
        )
        XCTAssertFalse(
            packageApp.contains("SKYBRIDGE_ALLOW_RELEASE_WITHOUT_APPLE_PQC_SDK"),
            "Release package entrypoint must not allow diagnostic Apple PQC bypasses."
        )
        XCTAssertTrue(packageApp.contains("skybridge_stamp_apple_pqc_sdk_packaging_metadata"))
        XCTAssertTrue(buildDMG.contains("skybridge_assert_bundle_has_apple_pqc_compile_marker"))
        XCTAssertTrue(
            buildDMG.contains("SwiftPM 主构建模式：Xcode app target 仅提供 Widget/资源，中间 app runtime marker 校验推迟到 package_app.sh 产物")
        )
        XCTAssertTrue(
            buildDMG.contains("verify_app_runtime_layout \"$APP_BUNDLE\""),
            "Release DMG must still validate the final packaged app bundle after package_app.sh copies the SwiftPM release executable."
        )
        XCTAssertTrue(buildDMG.contains("skybridge_assert_release_app_stable_platform_metadata"))
        XCTAssertTrue(releaseReadiness.contains("skybridge_assert_bundle_has_apple_pqc_compile_marker"))
        XCTAssertTrue(releaseReadiness.contains("skybridge_assert_release_app_stable_platform_metadata"))
        XCTAssertTrue(publisher.contains("skybridge_assert_bundle_has_apple_pqc_compile_marker"))
        XCTAssertTrue(buildDMG.contains("skybridge_assert_release_stable_toolchain \"release_dmg\""))
        XCTAssertTrue(packageApp.contains("skybridge_assert_release_stable_toolchain \"${PACKAGE_CONTEXT}\""))
        XCTAssertTrue(packageApp.contains("skybridge_assert_release_app_stable_platform_metadata \"${INFO_PLIST_DST}\""))
        XCTAssertTrue(releaseReadiness.contains("skybridge_assert_release_stable_toolchain \"release_dmg\""))
        XCTAssertTrue(releaseReadiness.contains("Scripts/check_macos_deps.sh"))
        XCTAssertTrue(releaseReadiness.contains("env -u SKYBRIDGE_FILE_TOOL -u SKYBRIDGE_OTOOL_TOOL"))
        XCTAssertTrue(releaseReadiness.contains("--strict \"${app_path}\" \"14.0\""))
        XCTAssertTrue(releaseReadiness.contains("DMG embedded app contains Mach-O binaries that cannot prove macOS 14.0 compatibility"))
        XCTAssertTrue(publisher.contains("skybridge_assert_release_stable_toolchain \"release_dmg\""))
        XCTAssertTrue(manifestGenerator.contains("apple_pqc_sdk_build"))
        XCTAssertTrue(manifestGenerator.contains("appBundleContainsApplePQCCompileMarker"))
        XCTAssertTrue(manifestGenerator.contains("applePQCSDKName = \"macosx\""))
        XCTAssertTrue(manifestGenerator.contains("applePQCSDKVersion = \"26.5\""))
        XCTAssertTrue(manifestGenerator.contains("applePQCSwiftTarget = \"arm64-apple-macosx26.0\""))
        XCTAssertTrue(manifestGenerator.contains("applePQCSymbolSet = \"cryptokit-pqc-v1\""))
        XCTAssertFalse(
            manifestGenerator.contains("cryptokit-pqc-os27-v1"),
            "Stable update manifest generation must not accept OS27 beta-only symbol-set proof before the release baseline intentionally migrates."
        )
        XCTAssertTrue(manifestGenerator.contains("secure_enclave_symbols_included must be true"))
        XCTAssertTrue(manifestEvaluator.contains("missingApplePQCSDKBuildAttestation"))
        XCTAssertTrue(manifestEvaluator.contains("expectedApplePQCSDKBuildSDKName = \"macosx\""))
        XCTAssertTrue(manifestEvaluator.contains("expectedApplePQCSDKBuildSDKVersion = \"26.5\""))
        XCTAssertTrue(
            manifestEvaluator.contains(
                "expectedApplePQCSDKBuildSwiftTarget = \"arm64-apple-macosx26.0\""
            )
        )
        XCTAssertTrue(manifestEvaluator.contains("missingApplePQCSDKBuildSecureEnclaveSymbols"))
        XCTAssertTrue(manifestEvaluator.contains("applePQCSDKBuildSignatureVerificationFailed"))
        XCTAssertTrue(publisher.contains("\"secure_enclave_symbols_included\": True"))

        let buildGateRange = buildDMG.range(of: "skybridge_configure_apple_pqc_sdk_for_package_context \"release_dmg\" \"Release DMG\"")
        let buildSkipRange = buildDMG.range(of: "if [[ \"$SKIP_BUILD\" == false ]]")
        XCTAssertNotNil(buildGateRange)
        XCTAssertNotNil(buildSkipRange)
        if let buildGateRange, let buildSkipRange {
            XCTAssertLessThan(
                buildGateRange.lowerBound,
                buildSkipRange.lowerBound,
                "Release DMG Apple PQC gate must run before SKIP_BUILD can bypass the build step."
            )
        }

        let existingAppMetadataGateRange = buildDMG.range(
            of: "skybridge_assert_release_app_stable_platform_metadata \"$info_plist\" \"Release DMG App Bundle\""
        )
        let existingAppReuseRange = buildDMG.range(of: "log_info \"复用已存在 App Bundle")
        XCTAssertNotNil(existingAppMetadataGateRange)
        XCTAssertNotNil(existingAppReuseRange)
        if let existingAppMetadataGateRange, let existingAppReuseRange {
            XCTAssertLessThan(
                existingAppMetadataGateRange.lowerBound,
                existingAppReuseRange.lowerBound,
                "Release DMG --use-existing-app must prove the app was stamped with stable Xcode/SDK metadata before reuse."
            )
        }

        let machoGateRange = releaseReadiness.range(of: "validate_macho_minimum_macos_version_floor \"${APP_PATH}\"")
        let packageIntegrityExitRange = releaseReadiness.range(of: "if [[ \"${PACKAGE_INTEGRITY_ONLY}\" == \"1\" ]]")
        XCTAssertNotNil(machoGateRange)
        XCTAssertNotNil(packageIntegrityExitRange)
        if let machoGateRange, let packageIntegrityExitRange {
            XCTAssertLessThan(
                machoGateRange.lowerBound,
                packageIntegrityExitRange.lowerBound,
                "Release package-integrity validation must prove bundle Mach-O minos before it can exit successfully."
            )
        }

        let packageGateRange = packageApp.range(of: "skybridge_configure_apple_pqc_sdk_for_package_context \"${PACKAGE_CONTEXT}\" \"Release package\"")
        let packageSkipRange = packageApp.range(of: "if [[ \"${SKIP_BUILD}\" != \"1\" ]]")
        XCTAssertNotNil(packageGateRange)
        XCTAssertNotNil(packageSkipRange)
        if let packageGateRange, let packageSkipRange {
            XCTAssertLessThan(
                packageGateRange.lowerBound,
                packageSkipRange.lowerBound,
                "Release package Apple PQC gate must run before SKIP_BUILD can reuse an existing product."
            )
        }

        let packageMetadataStampRange = packageApp.range(of: "stamp_macos_platform_metadata \"${INFO_PLIST_DST}\"")
        let packageMetadataGateRange = packageApp.range(
            of: "skybridge_assert_release_app_stable_platform_metadata \"${INFO_PLIST_DST}\" \"release_dmg packaged app\""
        )
        let packageBuildSourceRange = packageApp.range(of: "plutil -replace SkyBridgePackagingBuildSource")
        XCTAssertFalse(
            packageApp.contains("SkyBridgePackagingBuildProductPath -string \"${BUILD_DIR}/${EXECUTABLE}\""),
            "Release package provenance must not write local build product paths into Info.plist."
        )
        XCTAssertTrue(
            packageApp.contains("SkyBridgePackagingBuildProductPath -string \"<redacted:${BUILD_SOURCE}>/${EXECUTABLE}\""),
            "Release package provenance should keep a stable build-source label without leaking local paths."
        )
        XCTAssertNotNil(packageMetadataStampRange)
        XCTAssertNotNil(packageMetadataGateRange)
        XCTAssertNotNil(packageBuildSourceRange)
        if let packageMetadataStampRange, let packageMetadataGateRange, let packageBuildSourceRange {
            XCTAssertLessThan(packageMetadataStampRange.lowerBound, packageMetadataGateRange.lowerBound)
            XCTAssertLessThan(
                packageMetadataGateRange.lowerBound,
                packageBuildSourceRange.lowerBound,
                "Release package must prove stable Xcode/SDK metadata immediately after stamping and before recording reusable package provenance."
            )
        }
    }

    func testStrictPQCAdmissionGateUsesLocalCapabilityEvidence() throws {
        let sources = [
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift",
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift"
        ]

        for sourcePath in sources {
            let source = try readSource(sourcePath)
            XCTAssertFalse(
                source.contains("localPQCSuitesAvailable: hasPQCGroup"),
                "\(sourcePath) must not pass peer-advertised PQC suites as local PQC capability."
            )
            XCTAssertFalse(
                source.contains("localPQCSuitesAvailable: peerHasPQCGroup"),
                "\(sourcePath) must not pass peer-advertised PQC suites as local PQC capability."
            )
            XCTAssertTrue(
                source.contains("Local PQC capability is"),
                "\(sourcePath) should document that local PQC capability comes from provider selection, not MessageA peer suites."
            )
        }
    }

    func testUnavailablePQCProvidersDoNotAdvertiseClassicSuites() throws {
        let sources = [
            "Sources/SkyBridgeCore/P2P/CryptoProviderFactory.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/CryptoProviderFactory.swift"
        ]

        for sourcePath in sources {
            let source = try readSource(sourcePath)
            guard let unavailableProviderRange = source.range(of: "internal struct UnavailablePQCProvider") else {
                XCTFail("\(sourcePath) must define UnavailablePQCProvider.")
                continue
            }
            let body = source[unavailableProviderRange.lowerBound...]
            XCTAssertTrue(
                body.contains("let activeSuite: CryptoSuite = .unknown(0xFFFF)"),
                "\(sourcePath) unavailable provider must not present X25519 as the active suite."
            )
            XCTAssertTrue(
                body.contains("let supportedSuites: [CryptoSuite] = []"),
                "\(sourcePath) unavailable provider must not advertise negotiable suites."
            )
            XCTAssertTrue(
                body.contains("func supportsSuite(_ suite: CryptoSuite) -> Bool"),
                "\(sourcePath) unavailable provider must override supportsSuite."
            )
            XCTAssertTrue(
                body.range(
                    of: #"func supportsSuite\(_ suite: CryptoSuite\) -> Bool\s*\{\s*false\s*\}"#,
                    options: .regularExpression
                ) != nil,
                "\(sourcePath) unavailable provider supportsSuite override must fail closed."
            )
        }
    }
}
