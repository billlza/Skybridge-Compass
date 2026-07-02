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

        let readiness = try repositorySource("Scripts/check_macos_release_readiness.sh")
        XCTAssertTrue(readiness.contains("validate_release_binary_provenance_strings"))
        XCTAssertTrue(readiness.contains("validate_release_app_binary_provenance_strings"))
        XCTAssertTrue(readiness.contains("release_app_binary_candidates"))
        XCTAssertTrue(readiness.contains("release app binary"))
        XCTAssertTrue(readiness.contains("validate_release_app_binary_provenance_strings \"${APP_PATH}\""))
    }

    func testQPeriaptVendorPolicyRejectsLocalPathArtifacts() throws {
        let builder = try repositorySource("Scripts/build_qperiapt_xcframework.sh")
        XCTAssertTrue(builder.contains("CARGO_ENCODED_RUSTFLAGS"))
        XCTAssertTrue(builder.contains("--remap-path-prefix=${QPERIAPT_REPO}=qperiapt-src"))
        XCTAssertTrue(builder.contains("--remap-path-prefix=${HOME}/.cargo/registry/src=cargo-registry"))
        XCTAssertTrue(builder.contains("--remap-path-prefix=${HOME}/.rustup/toolchains=rust-toolchain"))

        let vendorPolicy = try repositorySource("Scripts/test_vendor_artifact_policy.sh")
        XCTAssertTrue(vendorPolicy.contains("assert_no_user_home_paths_in_static_library"))
        XCTAssertTrue(vendorPolicy.contains("leaks a non-toolchain local user path into the vendored binary"))
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
