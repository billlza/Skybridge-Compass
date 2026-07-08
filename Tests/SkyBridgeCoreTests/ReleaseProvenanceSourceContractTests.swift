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

        let readiness = try repositorySource("Scripts/check_macos_release_readiness.sh")
        XCTAssertTrue(readiness.contains("validate_release_binary_provenance_strings"))
        XCTAssertTrue(readiness.contains("validate_release_app_binary_provenance_strings"))
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
