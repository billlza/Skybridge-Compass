import Foundation
import XCTest

final class ReleaseProvenanceSourceContractTests: XCTestCase {
    func testHelperInstallerDoesNotEmbedSourceCheckoutPaths() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/Performance/HelperInstaller.swift")

        XCTAssertFalse(
            source.contains("#filePath"),
            "HelperInstaller runtime fallback paths must not embed the developer checkout path into release binaries."
        )
        XCTAssertTrue(
            source.contains("Bundle.main.path(forResource: helperServiceName, ofType: \"plist\")"),
            "Packaged helper plist lookup should use app bundle resources first."
        )
        XCTAssertTrue(
            source.contains("ProcessInfo.processInfo.environment[\"BUILT_PRODUCTS_DIR\"]"),
            "Development helper executable lookup should stay explicit through Xcode's build-products directory."
        )
    }

    func testReleaseBuildsUseScratchPathAndGateUserPathLeakage() throws {
        let buildPolicy = try repositorySource("Scripts/package_build_policy.sh")
        XCTAssertTrue(buildPolicy.contains("SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH"))
        XCTAssertTrue(buildPolicy.contains("--scratch-path"))
        XCTAssertTrue(buildPolicy.contains("配置的 scratch path"))

        let buildDMG = try repositorySource("Scripts/build_dmg.sh")
        XCTAssertTrue(buildDMG.contains("/tmp/skybridge-swiftpm-release-${BUILD_ARCH}"))
        XCTAssertTrue(buildDMG.contains("SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH"))

        let packageApp = try repositorySource("Scripts/package_app.sh")
        XCTAssertTrue(packageApp.contains("/tmp/skybridge-swiftpm-release-${BUILD_ARCH}"))
        XCTAssertTrue(packageApp.contains("SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH"))
        XCTAssertTrue(packageApp.contains("stamp_release_git_provenance \"${INFO_PLIST_DST}\""))
        XCTAssertTrue(packageApp.contains("SkyBridgePackagingGitCommit"))
        XCTAssertTrue(packageApp.contains("SkyBridgePackagingGitBranch"))
        XCTAssertTrue(packageApp.contains("SkyBridgePackagingGitDirtyState"))
        XCTAssertTrue(packageApp.contains("git -C \"${git_dir}\" status --porcelain --untracked-files=all"))
        XCTAssertTrue(packageApp.contains("require_release_git_provenance \"${git_commit}\" \"${git_branch}\" \"${git_dirty}\""))
        XCTAssertTrue(packageApp.contains("release_dmg 打包要求 Git worktree 为 clean"))

        let liboqsProvenanceGate = try XCTUnwrap(
            packageApp.range(of: "\"${ROOT_DIR}/Sources/Vendor/liboqs.provenance.json\"")
        )
        let freeRDPProvenanceGate = try XCTUnwrap(
            packageApp.range(of: "\"${ROOT_DIR}/Sources/Vendor/FreeRDPRuntime.provenance.json\"")
        )
        let releaseBuild = try XCTUnwrap(packageApp.range(of: "swift build \\\n"))
        let freeRDPCopy = try XCTUnwrap(
            packageApp.range(of: "cp -f \"${dylib}\" \"${FW_DIR}/\"")
        )
        XCTAssertLessThan(liboqsProvenanceGate.lowerBound, releaseBuild.lowerBound)
        XCTAssertLessThan(freeRDPProvenanceGate.lowerBound, releaseBuild.lowerBound)
        XCTAssertLessThan(freeRDPProvenanceGate.lowerBound, freeRDPCopy.lowerBound)
        XCTAssertTrue(packageApp.contains("native_vendor_provenance.py\" verify"))
        XCTAssertTrue(packageApp.contains("artifact bytes 不一致"))
        for requiredRuntime in [
            "libfreerdp3.dylib",
            "libwinpr3.dylib",
            "libssl.4.dylib",
            "libcrypto.4.dylib",
            "libjansson.4.dylib",
            "liburiparser.1.dylib",
        ] {
            XCTAssertTrue(packageApp.contains(requiredRuntime))
        }
        XCTAssertFalse(packageApp.contains("libssl.3.dylib"))
        XCTAssertFalse(packageApp.contains("libcrypto.3.dylib"))

        let nativeLock = try repositorySource("Config/native-dependencies.lock.json")
        let freeRDPRecipe = try repositorySource("Scripts/build_freerdp_dylibs.sh")
        XCTAssertTrue(nativeLock.contains("\"version\": \"4.0.1\""))
        XCTAssertTrue(nativeLock.contains("\"ref\": \"openssl-4.0.1\""))
        XCTAssertTrue(nativeLock.contains("1e963a8680ec78ad2072792c7a1a71f3c530bd2e"))
        XCTAssertTrue(nativeLock.contains("libssl.4.dylib;libcrypto.4.dylib"))
        XCTAssertTrue(nativeLock.contains("\"build_jobs\": \"8\""))
        XCTAssertTrue(freeRDPRecipe.contains("openssl-4.0.1-mkinstallvars-defaults.patch"))
        XCTAssertTrue(freeRDPRecipe.contains("libssl.4.dylib"))
        XCTAssertTrue(freeRDPRecipe.contains("libcrypto.4.dylib"))
        XCTAssertTrue(freeRDPRecipe.contains("--build-input \"build_jobs=$BUILD_JOBS\""))

        let readiness = try repositorySource("Scripts/check_macos_release_readiness.sh")
        XCTAssertTrue(readiness.contains("validate_release_binary_provenance_strings"))
        XCTAssertTrue(readiness.contains("validate_release_app_binary_provenance_strings"))
        XCTAssertTrue(readiness.contains("validate_release_binary_test_surface_strings"))
        XCTAssertTrue(readiness.contains("SKYBRIDGE_SMOKE_"))
        XCTAssertTrue(readiness.contains("SkyBridgeTestingBuild"))
        XCTAssertTrue(readiness.contains("release_app_binary_candidates"))
        XCTAssertTrue(readiness.contains("release app binary"))
        XCTAssertTrue(readiness.contains("validate_release_app_binary_provenance_strings \"${APP_PATH}\""))
        XCTAssertTrue(readiness.contains("DMG app Git commit"))
        XCTAssertTrue(readiness.contains("--manifest-path"))
        XCTAssertTrue(readiness.contains("MANIFEST_PATH=\"${PROJECT_ROOT}/dist/macos-stable.json\""))
        XCTAssertTrue(readiness.contains("MANIFEST_PATH_EXPLICIT=0"))
        XCTAssertTrue(readiness.contains("MANIFEST_PATH_EXPLICIT=1"))
        XCTAssertTrue(readiness.contains("if [[ \"${MANIFEST_PATH_EXPLICIT}\" == \"1\" ]]; then"))
        XCTAssertTrue(readiness.contains("elif [[ -f \"${MANIFEST_PATH}\" ]]; then"))
        XCTAssertTrue(readiness.contains("validate_local_update_manifest \"${MANIFEST_PATH}\" \"${APP_PATH}\" \"${DMG_PATH}\""))
        XCTAssertTrue(readiness.contains("deferring exact manifest validation to Scripts/publish_macos_update_release.sh"))
        XCTAssertTrue(readiness.contains("--require-apple-pqc-sdk-build"))
        XCTAssertTrue(readiness.contains("stable update manifest does not advertise the exact release app and DMG"))
        XCTAssertTrue(readiness.contains("APP_GIT_DIRTY_STATE"))
        XCTAssertTrue(readiness.contains("validate_release_git_provenance \"${APP_GIT_COMMIT}\" \"${APP_GIT_BRANCH}\" \"${APP_GIT_DIRTY_STATE}\" \"app bundle\""))
        XCTAssertTrue(readiness.contains("validate_release_git_provenance \"${dmg_git_commit}\" \"${dmg_git_branch}\" \"${dmg_git_dirty_state}\" \"DMG app\""))
        XCTAssertTrue(readiness.contains("[[ \"${git_dirty_state}\" == \"clean\" ]]"))
        XCTAssertFalse(readiness.contains("clean|dirty|unknown"))

        XCTAssertTrue(buildDMG.contains("SkyBridgePackagingGitCommit"))
        XCTAssertTrue(buildDMG.contains("SkyBridgePackagingGitBranch"))
        XCTAssertTrue(buildDMG.contains("SkyBridgePackagingGitDirtyState"))
        XCTAssertTrue(buildDMG.contains("\"$git_dirty_state\" == \"clean\""))
    }

    func testReleaseBinarySurfaceGateRecursesAndInspectsDemangledSymbols() throws {
        let readiness = try repositorySource("Scripts/check_macos_release_readiness.sh")

        XCTAssertTrue(readiness.contains("--scan-release-binaries-only"))
        XCTAssertTrue(readiness.contains("find \"${app_path}\" -type f -print0"))
        XCTAssertTrue(readiness.contains("while IFS= read -r -d '' binary_path"))
        XCTAssertTrue(readiness.contains("validate_release_binary_test_surface_symbols"))
        XCTAssertTrue(readiness.contains("validate_release_binary_test_surface \"${binary_path}\""))
        XCTAssertTrue(readiness.contains("xcrun --find nm"))
        XCTAssertTrue(readiness.contains("xcrun --find swift-demangle"))
        XCTAssertTrue(readiness.contains("\"${RELEASE_SWIFT_DEMANGLE_TOOL}\" --compact"))

        for marker in [
            "SKYBRIDGE_TESTING",
            "SKYBRIDGE_SMOKE_",
            "SKYBRIDGE_KEYCHAIN_IN_MEMORY",
            "UITEST_",
            "XCTestSessionIdentifier",
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCInjectBundleInto",
            "RemoteControlSmokeStatusWriter",
            "SmokeHarness",
            "SmokeStatusWriter",
            "SmokeStatusReporter",
            "SmokeStreamOverrides",
            "SmokeTraceWriter",
            "SmokeStatusFileAppender",
            "MacSmokeStatusFailClosedWriter",
            "RemoteControlNoticePanelProbeHarness"
        ] {
            XCTAssertTrue(
                readiness.contains(marker),
                "release readiness must reject compiled test surface marker \(marker)"
            )
        }

        let behaviorTest = try repositorySource("Scripts/test_macos_release_binary_surface_gate.sh")
        XCTAssertTrue(behaviorTest.contains("Contents/Resources/Embedded/Nested/Helpers"))
        XCTAssertTrue(behaviorTest.contains("NOT_SKYBRIDGE_TESTING"))
        XCTAssertTrue(behaviorTest.contains("RemoteControlSmokeStatusWriterFactory"))
        XCTAssertTrue(behaviorTest.contains("LocalCameraSmokeHarness"))
        XCTAssertTrue(behaviorTest.contains("in its symbol table"))
        XCTAssertTrue(behaviorTest.contains("after Swift symbol demangling"))
        XCTAssertTrue(behaviorTest.contains("--scan-release-binaries-only"))
    }

    func testQPeriaptVendorPolicyInstallsOnlyTheAuthenticatedABI2Release() throws {
        let builder = try repositorySource("Scripts/build_qperiapt_xcframework.sh")
        XCTAssertTrue(builder.contains("QPERIAPT_RELEASE_TAG=\"v0.1.0-alpha.2-r1\""))
        XCTAssertTrue(builder.contains("releases/download/${QPERIAPT_RELEASE_TAG}"))
        XCTAssertTrue(builder.contains("require_sha256 \"$DOWNLOAD_DIR/CQPeriapt.xcframework.zip\""))
        XCTAssertTrue(builder.contains("validate_archive_shape"))
        XCTAssertTrue(builder.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(builder.contains("assert_exact_symbols \"$header\" \"$library\""))
        XCTAssertTrue(builder.contains("PROVENANCE_SOURCE=\"$ROOT_DIR/VendorProvenance/QPeriapt/abi2-v0.1.0-alpha.2-r1.json\""))
        XCTAssertFalse(builder.contains("QPERIAPT_REPO"))
        XCTAssertFalse(builder.contains("CARGO_ENCODED_RUSTFLAGS"))
        XCTAssertFalse(builder.contains("IOS_VENDOR_OUT"))
        XCTAssertFalse(builder.contains("INSTALL_IOS_MIRROR"))

        let vendorPolicy = try repositorySource("Scripts/test_vendor_artifact_policy.sh")
        XCTAssertTrue(vendorPolicy.contains("assert_no_user_home_paths_in_static_library"))
        XCTAssertTrue(vendorPolicy.contains("leaks a non-toolchain local user path into the vendored binary"))
        XCTAssertTrue(vendorPolicy.contains("git -C \"${ROOT_DIR}\" ls-files --error-unmatch"))
        XCTAssertTrue(vendorPolicy.contains("git -C \"${ROOT_DIR}\" cat-file -e \"HEAD:${path}\""))
        XCTAssertTrue(vendorPolicy.contains("required vendor artifact differs across HEAD, index, and worktree"))
        XCTAssertTrue(vendorPolicy.contains("assert_exact_head_bound_qperiapt_tree"))
        XCTAssertFalse(vendorPolicy.contains("SkyBridge Compass iOS/Vendor/qperiapt.xcframework"))
    }

    func testLoopbackBenchmarkIdentityIsHeadBoundInMemoryAndCertificatePinned() throws {
        let fixturePolicy = try repositorySource("Scripts/test_loopback_benchmark_fixture_policy.sh")
        XCTAssertTrue(fixturePolicy.contains("git -C \"${ROOT_DIR}\" ls-files --error-unmatch"))
        XCTAssertTrue(fixturePolicy.contains("git -C \"${ROOT_DIR}\" cat-file -e \"HEAD:${path}\""))
        XCTAssertTrue(fixturePolicy.contains("required fixture differs across HEAD, index, and worktree"))
        XCTAssertTrue(fixturePolicy.contains("CA:FALSE"))
        XCTAssertTrue(fixturePolicy.contains("TLS Web Server Authentication"))
        XCTAssertTrue(fixturePolicy.contains("CERTIFICATE_SHA256="))
        XCTAssertTrue(fixturePolicy.contains("PRIVATE_KEY_SHA256="))

        for sourcePath in [
            "Sources/BaselineBenchRunner/main.swift",
            "Tests/SkyBridgeBenchTests/BaselineLoopbackBenchTests.swift"
        ] {
            let source = try repositorySource(sourcePath)
            XCTAssertTrue(source.contains("SecIdentityCreate(nil, certificate, privateKey)"))
            XCTAssertTrue(source.contains("complete(actualCertificateDER == expectedCertificateDER)"))
            XCTAssertTrue(source.contains("startListenerAndWaitUntilReady"))
            XCTAssertTrue(source.contains("AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1))"))
            XCTAssertFalse(source.contains("SecPKCS12Import"))
            XCTAssertFalse(source.contains("SecItemAdd"))
            XCTAssertFalse(source.contains("complete(true)"))
        }

        let sensitiveArtifacts = try repositorySource("Scripts/check_sensitive_artifacts.sh")
        XCTAssertTrue(sensitiveArtifacts.contains("certificate\\.der|private_key\\.x963"))
        XCTAssertTrue(sensitiveArtifacts.contains("\".der\""))
        XCTAssertTrue(sensitiveArtifacts.contains("\".x963\""))

        let sourceQualityGate = try repositorySource("Scripts/gates/source_quality_gate.sh")
        XCTAssertTrue(sourceQualityGate.contains("test_loopback_benchmark_fixture_policy.sh"))
        XCTAssertTrue(sourceQualityGate.contains("check_sensitive_artifacts.sh"))
    }

    func testXPCHelpersBindMessagesToSignedApplicationIdentityWithoutPIDLookup() throws {
        let helperPaths = [
            "Sources/PowerMetricsHelper/main.swift",
            "Sources/RegexMatchingHelper/RegexMatchingService.swift"
        ]

        for helperPath in helperPaths {
            let source = try repositorySource(helperPath)
            let requirementRange = try XCTUnwrap(
                source.range(of: "setCodeSigningRequirement(requirement)"),
                "\(helperPath) must bind NSXPC messages to a code-signing requirement"
            )
            let interfaceRange = try XCTUnwrap(
                source.range(of: "newConnection.exportedInterface"),
                "\(helperPath) must configure an explicit exported interface"
            )
            let activationRange = try XCTUnwrap(
                source.range(of: "newConnection.activate()"),
                "\(helperPath) must explicitly activate accepted connections"
            )

            XCTAssertLessThan(requirementRange.lowerBound, interfaceRange.lowerBound)
            XCTAssertLessThan(requirementRange.lowerBound, activationRange.lowerBound)
            XCTAssertTrue(source.contains("anchor apple generic"))
            XCTAssertTrue(source.contains("certificate leaf[subject.OU]"))
            XCTAssertFalse(source.contains("kSecGuestAttributePid"))
            XCTAssertFalse(source.contains("SecCodeCopyGuestWithAttributes"))
            XCTAssertFalse(source.contains("connection.processIdentifier"))
            XCTAssertFalse(source.contains("newConnection.resume()"))
        }

        let powerMetrics = try repositorySource("Sources/PowerMetricsHelper/main.swift")
        XCTAssertTrue(powerMetrics.contains("guard let team = currentTeamIdentifier(), isValidTeamIdentifier(team)"))
        XCTAssertTrue(powerMetrics.contains("SKYBRIDGE_HELPER_VERSION=2.5.0"))

        let regex = try repositorySource("Sources/RegexMatchingHelper/RegexMatchingService.swift")
        XCTAssertTrue(regex.contains("guard let team = regexHelperTeamIdentifier(), isValidRegexHelperTeamIdentifier(team)"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
