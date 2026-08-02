import CryptoKit
import XCTest
@testable import SkyBridgeCore

final class AppUpdateManifestTests: XCTestCase {
    func testManifestWithNewerVersionIsUpdateAvailable() throws {
        let manifest = try decodeManifest(version: "1.2.0", build: "20260524")
        let decision = try SkyBridgeAppUpdateEvaluator.evaluate(
            manifest: manifest,
            context: context(currentVersion: "1.1.9", currentBuild: "20260523"),
            trustedSigningKeys: trustedSigningKeys()
        )

        XCTAssertEqual(decision.state, .updateAvailable)
    }

    func testManifestWithSameVersionAndBuildIsUpToDate() throws {
        let manifest = try decodeManifest(version: "1.2.0", build: "20260524")
        let decision = try SkyBridgeAppUpdateEvaluator.evaluate(
            manifest: manifest,
            context: context(currentVersion: "1.2.0", currentBuild: "20260524"),
            trustedSigningKeys: trustedSigningKeys()
        )

        XCTAssertEqual(decision.state, .upToDate)
    }

    func testManifestRejectsBundleMismatch() throws {
        let manifest = try decodeManifest(bundleId: "com.example.other")

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(manifest: manifest, context: context())
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .bundleIdentifierMismatch(
                    expected: "com.skybridge.compass.pro",
                    actual: "com.example.other"
                )
            )
        }
    }

    func testManifestRejectsInsecureDownloadURL() throws {
        let manifest = try decodeManifest(downloadURL: "http://example.com/SkyBridgeCompassPro.dmg")

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(manifest: manifest, context: context())
        ) { error in
            XCTAssertEqual(error as? SkyBridgeAppUpdateValidationError, .invalidDownloadURL)
        }
    }

    func testManifestRejectsPackagesNotMarkedNotarized() throws {
        let manifest = try decodeManifest(notarized: false)

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(manifest: manifest, context: context())
        ) { error in
            XCTAssertEqual(error as? SkyBridgeAppUpdateValidationError, .packageNotNotarized)
        }
    }

    func testManifestRejectsMissingApplePQCSDKBuildAttestation() throws {
        let manifest = try decodeManifest(includeApplePQCSDKBuild: false)

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(error as? SkyBridgeAppUpdateValidationError, .missingApplePQCSDKBuildAttestation)
        }
    }

    func testManifestRejectsApplePQCSDKBuildNotCompiledWithHASFlag() throws {
        let manifest = try decodeManifest(applePQCSDKCompiled: false)

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(error as? SkyBridgeAppUpdateValidationError, .applePQCSDKBuildNotCompiled)
        }
    }

    func testManifestRejectsUnsupportedApplePQCSDKBuildProbeMode() throws {
        let manifest = try decodeManifest(applePQCSDKBuildProbeMode: "sdk_version_fallback")

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .unsupportedApplePQCSDKBuildProbeMode("sdk_version_fallback")
            )
        }
    }

    func testManifestRejectsUnsupportedApplePQCSDKBuildSDKName() throws {
        let manifest = try decodeManifest(applePQCSDKBuildSDKName: "iphoneos")

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .unsupportedApplePQCSDKBuildSDKName("iphoneos")
            )
        }
    }

    func testManifestRejectsUnsupportedApplePQCSDKBuildSDKVersion() throws {
        let manifest = try decodeManifest(applePQCSDKBuildSDKVersion: "27.0")

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .unsupportedApplePQCSDKBuildSDKVersion("27.0")
            )
        }
    }

    func testManifestRejectsUnsupportedApplePQCSDKBuildSwiftTarget() throws {
        let manifest = try decodeManifest(applePQCSDKBuildSwiftTarget: "arm64-apple-macosx27.0")

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .unsupportedApplePQCSDKBuildSwiftTarget("arm64-apple-macosx27.0")
            )
        }
    }

    func testManifestRejectsMissingApplePQCSDKBuildSecureEnclaveSymbols() throws {
        let manifest = try decodeManifest(applePQCSDKBuildSecureEnclaveSymbolsIncluded: false)

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .missingApplePQCSDKBuildSecureEnclaveSymbols
            )
        }
    }

    func testManifestRejectsUnsupportedApplePQCSDKBuildSymbolSet() throws {
        let manifest = try decodeManifest(applePQCSDKBuildSymbolSet: "cryptokit-pqc-version-fallback")

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .unsupportedApplePQCSDKBuildSymbolSet("cryptokit-pqc-version-fallback")
            )
        }
    }

    func testManifestRejectsTamperedApplePQCSDKBuildSignature() throws {
        let manifest = try decodeManifest(
            applePQCSDKBuildSignatureOverride: Data(repeating: 1, count: 64).base64EncodedString()
        )

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .applePQCSDKBuildSignatureVerificationFailed
            )
        }
    }

    func testManifestRejectsMissingSignature() throws {
        let manifest = try decodeManifest(signed: false)

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(error as? SkyBridgeAppUpdateValidationError, .missingManifestSignature)
        }
    }

    func testManifestRejectsTamperedSignature() throws {
        let manifest = try decodeManifest(
            signatureOverride: Data(repeating: 0, count: 64).base64EncodedString()
        )

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .manifestSignatureVerificationFailed
            )
        }
    }

    func testManifestRejectsUntrustedSigningKey() throws {
        let manifest = try decodeManifest()

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(),
                trustedSigningKeys: [
                    SkyBridgeAppUpdateTrustedSigningKey(
                        keyId: "other-key",
                        publicKeyBase64: testPublicKeyBase64
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .manifestSignatureKeyNotTrusted(testKeyId)
            )
        }
    }

    func testAppUpdateCheckerUsesTrustedSignedGitHubManifestContract() throws {
        let source = try repositorySource("Sources/SkyBridgeCompassApp/Services/AppUpdateChecker.swift")
        let appSource = try repositorySource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let appInfo = try repositorySource("Sources/SkyBridgeCompassApp/Info.plist")
        let xcodeProjectSource = try repositorySource("SkyBridgeWidgets.xcodeproj/project.pbxproj")
        let manifestEvaluator = try repositorySource("Sources/SkyBridgeCore/Updates/AppUpdateManifest.swift")
        let generator = try repositorySource("Scripts/generate_macos_update_manifest.swift")
        let manifestValidator = try repositorySource("Scripts/validate_macos_update_manifest.sh")
        let publisher = try repositorySource("Scripts/publish_macos_update_release.sh")
        let releaseReadiness = try repositorySource("Scripts/check_macos_release_readiness.sh")
        let workflow = try repositorySource(".github/workflows/macos-release-readiness.yml")
        let cliWorkflow = try repositorySource(".github/workflows/skybridge-cli-release.yml")
        let cliPublisher = try repositorySource("rust/scripts/publish_cli_github_release.sh")
        let fastfile = try repositorySource("fastlane/Fastfile")
        let xcodeVerifier = try repositorySource("Scripts/verify_xcode_toolchain.sh")

        XCTAssertTrue(source.contains("trustedSigningKeys: [SkyBridgeAppUpdateTrustedSigningKey]"))
        XCTAssertTrue(source.contains("trustedSigningKeys: trustedSigningKeys"))
        XCTAssertTrue(source.contains("SkyBridgeAppUpdateSequenceStoring"))
        XCTAssertTrue(source.contains("highestAcceptedSequence()"))
        XCTAssertTrue(source.contains("minimumAcceptedManifestSequence: minimumSequence"))
        XCTAssertTrue(source.contains("recordAcceptedSequence(decision.manifest.sequence)"))
        XCTAssertTrue(source.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(source.contains("SkyBridgeAppUpdateAutomaticCheckPolicy"))
        XCTAssertTrue(source.contains("presentAutomaticUpdateIfNeeded"))
        XCTAssertTrue(source.contains("claimPresentation(for: decision.manifest.sequence)"))
        XCTAssertTrue(appSource.contains("SkyBridgeAppUpdateController.scheduleAutomaticCheckAfterLaunch()"))
        XCTAssertTrue(source.contains("https://github.com/billlza/Skybridge-Compass/releases/latest/download/macos-stable.json"))
        XCTAssertTrue(appInfo.contains("SKYBRIDGE_UPDATE_MANIFEST_ED25519_PUBLIC_KEYS"))
        XCTAssertTrue(
            xcodeProjectSource.contains("AppUpdateChecker.swift in Sources"),
            "The packaged Mac app target must compile the real update checker used by the menu and UI entry points."
        )
        XCTAssertTrue(generator.contains("SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64"))
        XCTAssertTrue(generator.contains("appendSignedField(\"published_at\""))
        XCTAssertTrue(generator.contains("appendSignedField(\"expires_at\""))
        XCTAssertTrue(generator.contains("appendSignedField(\"sequence\""))
        XCTAssertTrue(generator.contains("manifest generation requires --notarized"))
        XCTAssertTrue(generator.contains("apple_pqc_sdk_build"))
        XCTAssertTrue(generator.contains("compiled_with_has_apple_pqc_sdk"))
        XCTAssertTrue(generator.contains("appBundleContainsApplePQCCompileMarker"))
        XCTAssertTrue(generator.contains("sdk_name must be"))
        XCTAssertTrue(generator.contains("sdk_version must be"))
        XCTAssertTrue(generator.contains("swift_target must be"))
        XCTAssertTrue(generator.contains("secure_enclave_symbols_included must be true"))
        XCTAssertTrue(manifestEvaluator.contains("missingApplePQCSDKBuildAttestation"))
        XCTAssertTrue(manifestEvaluator.contains("expectedApplePQCSDKBuildSDKName"))
        XCTAssertTrue(manifestEvaluator.contains("expectedApplePQCSDKBuildSDKVersion"))
        XCTAssertTrue(manifestEvaluator.contains("expectedApplePQCSDKBuildSwiftTarget"))
        XCTAssertTrue(manifestEvaluator.contains("missingApplePQCSDKBuildSecureEnclaveSymbols"))
        XCTAssertTrue(manifestEvaluator.contains("applePQCSDKBuildSigningPayload"))
        XCTAssertFalse(
            generator.contains("--private-key-base64"),
            "The update manifest generator must not accept private key material as a command-line argument."
        )
        XCTAssertTrue(publisher.contains("Scripts/generate_macos_update_manifest.swift"))
        XCTAssertTrue(publisher.contains("validate_macos_update_manifest.sh"))
        XCTAssertTrue(publisher.contains("--require-apple-pqc-sdk-build"))
        XCTAssertTrue(publisher.contains("macos-update-release-publish-proof"))
        XCTAssertTrue(publisher.contains(#""release_proof": release_proof == "true"#))
        XCTAssertTrue(publisher.contains(#""app_bundle_name": app_bundle_name"#))
        XCTAssertFalse(publisher.contains(#""app_path": app_path"#))
        XCTAssertFalse(publisher.contains(#""dmg_path": dmg_path"#))
        XCTAssertFalse(publisher.contains(#""manifest_path": manifest_path"#))
        XCTAssertTrue(publisher.contains("local manifest only:"))
        XCTAssertTrue(publisher.contains("uploaded=false remote_verified=false release_proof=false"))
        XCTAssertTrue(publisher.contains("published-immutable-and-verified"))
        XCTAssertTrue(publisher.contains("macos-stable.json"))
        XCTAssertTrue(publisher.contains("gh release create"))
        XCTAssertTrue(publisher.contains("gh release edit"))
        XCTAssertTrue(publisher.contains("gh release download"))
        XCTAssertTrue(publisher.contains("gh release verify \"$TAG_NAME\""))
        XCTAssertTrue(publisher.contains("gh release verify-asset"))
        XCTAssertTrue(publisher.contains("--expected-source-sha"))
        XCTAssertTrue(publisher.contains("--evidence-provenance-path"))
        XCTAssertTrue(publisher.contains("--evidence-asset"))
        XCTAssertTrue(publisher.contains("--verify-tag"))
        XCTAssertTrue(publisher.contains("--draft"))
        XCTAssertTrue(publisher.contains("isImmutable"))
        XCTAssertTrue(publisher.contains("repos/${REPOSITORY}/immutable-releases"))
        XCTAssertTrue(publisher.contains("X-GitHub-Api-Version: 2026-03-10"))
        XCTAssertTrue(publisher.contains("validate_local_source_checkout"))
        XCTAssertTrue(publisher.contains("remote_tag_commit_sha"))
        XCTAssertFalse(publisher.contains("gh release upload"))
        XCTAssertTrue(publisher.contains("xcrun stapler validate"))
        XCTAssertTrue(
            publisher.contains("DMG_DIR=\"$(cd \"$(dirname \"$DMG_PATH\")\" && pwd)\""),
            "The publisher should canonicalize DMG paths before notarization and upload tools inspect them."
        )
        XCTAssertFalse(
            publisher.contains("xcrun stapler validate \"$dmg_path\" >/dev/null"),
            "stapler validate returns failure on notarized DMGs on some macOS versions when stdout is redirected; keep the output visible so the publish gate observes the real notarization result."
        )
        XCTAssertFalse(publisher.contains("--clobber"))
        XCTAssertTrue(publisher.contains("\"sdk_name\": \"macosx\""))
        XCTAssertTrue(publisher.contains("\"sdk_version\": \"26.5\""))
        XCTAssertTrue(publisher.contains("\"swift_target\": \"arm64-apple-macosx26.0\""))
        XCTAssertTrue(publisher.contains("\"secure_enclave_symbols_included\": True"))
        XCTAssertTrue(publisher.contains("resolve_default_sequence"))
        XCTAssertTrue(publisher.contains("CFBundleVersion must be a positive integer for immutable release sequencing"))
        XCTAssertFalse(publisher.contains("date -u '+%Y%m%d%H%M%S'"))
        XCTAssertTrue(publisher.contains("https://github.com/${REPOSITORY}/releases/download/${TAG_NAME}"))
        XCTAssertTrue(manifestValidator.contains("bundle_id"))
        XCTAssertTrue(manifestValidator.contains("does not match app CFBundleIdentifier"))
        XCTAssertTrue(manifestValidator.contains("expires_at"))
        XCTAssertTrue(manifestValidator.contains("does not match DMG sha256"))
        XCTAssertTrue(manifestValidator.contains("apple_pqc_sdk_build must be present and signed"))
        XCTAssertTrue(manifestValidator.contains("expected_basename=expected_dmg_name"))
        XCTAssertTrue(manifestValidator.contains(#"validate_https_url(download_url, "download_url", require_github=True"#))
        XCTAssertTrue(releaseReadiness.contains("generate_macos_update_manifest.swift"))
        XCTAssertTrue(releaseReadiness.contains("publish_macos_update_release.sh"))
        XCTAssertTrue(releaseReadiness.contains("validate_macos_update_manifest.sh"))
        XCTAssertTrue(releaseReadiness.contains("Package integrity-only validation complete; full_release_readiness=false release_proof=false"))
        XCTAssertTrue(releaseReadiness.contains("macOS release readiness completed with explicit skips; full_release_readiness=false release_proof=false"))
        XCTAssertTrue(releaseReadiness.contains("full macOS release readiness checks passed"))
        XCTAssertTrue(releaseReadiness.contains("redact_release_log_excerpt"))
        XCTAssertTrue(releaseReadiness.contains("Authorization: Bearer <redacted>"))
        XCTAssertTrue(releaseReadiness.contains("<redacted-path>"))
        XCTAssertTrue(releaseReadiness.contains("skybridge_assert_bundle_has_apple_pqc_compile_marker"))
        XCTAssertTrue(releaseReadiness.contains("verify_xcode_toolchain.sh"))
        XCTAssertTrue(releaseReadiness.contains("Scripts/check_macos_deps.sh"))
        XCTAssertTrue(releaseReadiness.contains("env -u SKYBRIDGE_FILE_TOOL -u SKYBRIDGE_OTOOL_TOOL"))
        XCTAssertTrue(releaseReadiness.contains("--strict \"${app_path}\" \"14.0\""))
        XCTAssertTrue(releaseReadiness.contains("DMG embedded app contains Mach-O binaries that cannot prove macOS 14.0 compatibility"))
        XCTAssertTrue(
            releaseReadiness.contains("stapled_notarization_ticket_is_valid \"${target_path}\""),
            "Release readiness must accept stapled notarization evidence for the exact App or DMG target when spctl omits notarized source context."
        )
        XCTAssertFalse(
            releaseReadiness.contains("[[ \"${target_path}\" == *.dmg ]] && xcrun stapler validate"),
            "The notarization confirmation path must not be limited to DMGs; stapled App bundles are release evidence too."
        )
        XCTAssertTrue(workflow.contains("DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer"))
        XCTAssertTrue(workflow.contains("SKYBRIDGE_REQUIRED_APPLE_SWIFT_VERSION: \"6.3.3\""))
        XCTAssertFalse(
            workflow.contains("swift-actions/setup-swift"),
            "Apple-platform release builds must use the Xcode 26.6 Apple toolchain, not a separate Swift.org toolchain."
        )
        XCTAssertTrue(workflow.contains("contents: write"))
        XCTAssertTrue(
            workflow.contains("actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4.3.0")
        )
        XCTAssertFalse(
            workflow.contains("actions/download-artifact@v4"),
            "Release workflows must pin the reviewed download-artifact commit instead of a mutable major tag."
        )
        XCTAssertTrue(workflow.contains("cancel-in-progress: false"))
        XCTAssertTrue(workflow.contains("release_artifact_run_attempt:"))
        XCTAssertFalse(workflow.contains("release_artifact_workflow_path:"))
        XCTAssertFalse(workflow.contains("release_artifact_event:"))
        XCTAssertTrue(workflow.contains("Validate Release Artifact Run Provenance"))
        XCTAssertTrue(workflow.contains("Scripts/validate_macos_release_artifact_run.sh"))
        XCTAssertTrue(workflow.contains("GH_TOKEN: ${{ github.token }}"))
        XCTAssertTrue(workflow.contains("RELEASE_ARTIFACT_RUN_ATTEMPT: ${{ inputs.release_artifact_run_attempt }}"))
        XCTAssertTrue(workflow.contains("RELEASE_ARTIFACT_WORKFLOW_PATH: .github/workflows/real-device-release-gate.yml"))
        XCTAssertTrue(workflow.contains("RELEASE_ARTIFACT_EVENT: workflow_dispatch"))
        XCTAssertTrue(workflow.contains(#"--repository "${GITHUB_REPOSITORY}""#))
        XCTAssertTrue(workflow.contains(#"--expected-run-attempt "${RELEASE_ARTIFACT_RUN_ATTEMPT}""#))
        XCTAssertTrue(workflow.contains(#"--expected-workflow-path "${RELEASE_ARTIFACT_WORKFLOW_PATH}""#))
        XCTAssertTrue(workflow.contains(#"--expected-head-sha "${GITHUB_SHA}""#))
        XCTAssertTrue(workflow.contains(#"--expected-head-branch "${GITHUB_REF_NAME}""#))
        XCTAssertTrue(workflow.contains(#"--artifact "${CONNECTIVITY_ARTIFACT_NAME}""#))
        XCTAssertTrue(workflow.contains(#"--artifact "${P2P_REMOTE_ARTIFACT_NAME}""#))
        XCTAssertTrue(workflow.contains(#"--artifact "${WEBRTC_REMOTE_ARTIFACT_NAME}""#))
        XCTAssertTrue(workflow.contains(#"--artifact "${FILE_TRANSFER_ARTIFACT_NAME}""#))
        XCTAssertTrue(workflow.contains(#"--artifact "${P2P_NOTICE_ARTIFACT_NAME}""#))
        XCTAssertTrue(workflow.contains(#"--artifact "${WEBRTC_NOTICE_ARTIFACT_NAME}""#))
        XCTAssertTrue(workflow.contains(#"--artifact "${NOTICE_PANEL_ARTIFACT_NAME}""#))
        XCTAssertTrue(workflow.contains("release-artifact-run-provenance.json"))
        if
            let provenanceRange = workflow.range(of: "Validate Release Artifact Run Provenance"),
            let firstDownloadRange = workflow.range(of: "Download Connectivity Matrix Artifact"),
            let signingSecretsRange = workflow.range(of: "Validate Release Signing Secrets")
        {
            XCTAssertLessThan(
                provenanceRange.lowerBound,
                firstDownloadRange.lowerBound,
                "The release workflow must verify source-run provenance before downloading release-gate artifacts."
            )
            XCTAssertLessThan(
                provenanceRange.lowerBound,
                signingSecretsRange.lowerBound,
                "The release workflow must reject untrusted release-gate artifacts before signing secrets are exposed."
            )
        } else {
            XCTFail("Release workflow must keep provenance validation, artifact download, and signing-secret validation steps visible.")
        }
        XCTAssertTrue(workflow.contains("Scripts/publish_macos_update_release.sh"))
        XCTAssertTrue(workflow.contains("Scripts/validate_macos_release_public_artifacts.sh"))
        XCTAssertTrue(workflow.contains("--require-public-redacted-artifacts"))
        XCTAssertTrue(workflow.contains("SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64"))
        XCTAssertTrue(workflow.contains("publish_release_tag:"))
        XCTAssertTrue(workflow.contains("macos-release-evidence.tar.gz"))
        XCTAssertTrue(workflow.contains("Upload Immutable Release Publish Proof"))
        XCTAssertTrue(workflow.contains(#"--expected-source-sha "$GITHUB_SHA""#))
        XCTAssertTrue(workflow.contains(#"--evidence-provenance-path "$MACOS_PUBLISH_HANDOFF_ROOT/release-artifact-run-provenance.json""#))
        XCTAssertTrue(workflow.contains(#"--evidence-asset "$MACOS_PUBLISH_HANDOFF_ROOT/macos-release-evidence.tar.gz""#))
        XCTAssertTrue(workflow.contains("Artifacts/release-gate-raw/connectivity"))
        XCTAssertTrue(workflow.contains("--connectivity-artifact-dir \"Artifacts/release-gate-public/connectivity\""))
        XCTAssertTrue(workflow.contains("--p2p-remote-artifact-dir \"Artifacts/release-gate-public/p2p-remote\""))
        XCTAssertTrue(workflow.contains("--file-transfer-artifact-dir \"Artifacts/release-gate-public/file-transfer\""))
        XCTAssertFalse(
            workflow.contains("find dist -maxdepth 1 -type f -name 'SkyBridgeCompassPro-*.dmg'"),
            "Release publishing must select the versioned DMG from the packaged app metadata, not the lexicographically last DMG under dist."
        )
        XCTAssertTrue(workflow.contains("CFBundleShortVersionString"))
        XCTAssertTrue(workflow.contains("dmg_path=\"dist/SkyBridgeCompassPro-${app_version}.dmg\""))
        XCTAssertTrue(workflow.contains("macos-signed-release-gate:"))
        XCTAssertTrue(workflow.contains("macos-immutable-release-publish:"))
        XCTAssertTrue(workflow.contains("environment: macos-production-release"))
        XCTAssertTrue(workflow.contains("persist-credentials: false"))
        XCTAssertTrue(workflow.contains("Remove Temporary Signing Credentials"))
        XCTAssertTrue(fastfile.contains("SKYBRIDGE_RELEASE_GATE_CONNECTIVITY_ARTIFACT_DIR"))
        XCTAssertFalse(fastfile.contains("Scripts/publish_macos_update_release.sh"))
        XCTAssertTrue(fastfile.contains("远程发布只允许由受保护的 macos-release-readiness GitHub Actions workflow 执行"))
        XCTAssertTrue(cliWorkflow.contains("rust/scripts/publish_cli_github_release.sh"))
        XCTAssertEqual(
            cliPublisher.components(separatedBy: "--latest=false").count - 1,
            2,
            "Both draft creation and final publication must keep the CLI release out of the latest channel."
        )
        XCTAssertFalse(cliWorkflow.contains("make_latest: true"))
        XCTAssertTrue(xcodeVerifier.contains("TOOLCHAIN_POLICY=\"${SKYBRIDGE_XCODE_TOOLCHAIN_POLICY:-stable-release}\""))
        XCTAssertTrue(xcodeVerifier.contains("EXPECTED_XCODE_VERSION=\"26.6\""))
        XCTAssertTrue(xcodeVerifier.contains("EXPECTED_XCODE_BUILD=\"17F113\""))
        XCTAssertTrue(xcodeVerifier.contains("EXPECTED_SWIFT_VERSION=\"6.3.3\""))
        XCTAssertTrue(xcodeVerifier.contains("EXPECTED_MACOS_SDK_VERSION=\"26.5\""))
        XCTAssertTrue(xcodeVerifier.contains("stable release toolchain must not use beta Xcode developer directory"))
        XCTAssertTrue(xcodeVerifier.contains("custom-diagnostic"))
        XCTAssertFalse(
            appInfo.localizedCaseInsensitiveContains("private"),
            "Release update configuration must pin public keys only."
        )
    }

    func testReleaseManifestGeneratorProducesEvaluatorCompatibleSignedManifest() throws {
        let root = repositoryRoot()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-update-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let appURL = tempRoot.appendingPathComponent("SkyBridge Compass Pro.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.skybridge.compass.pro",
            "CFBundleShortVersionString": "1.2.0",
            "CFBundleVersion": "2026052401",
            "LSMinimumSystemVersion": "14.0.0",
            "SkyBridgePackagingApplePQCSDKCompiledWithHASApplePQCSDK": true,
            "SkyBridgePackagingApplePQCSDKCompileMarker": "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk",
            "SkyBridgePackagingApplePQCSDKProbeMode": "symbol_probe",
            "SkyBridgePackagingApplePQCSDKName": "macosx",
            "SkyBridgePackagingApplePQCSDKVersion": "26.5",
            "SkyBridgePackagingApplePQCSDKSwiftTarget": "arm64-apple-macosx26.0",
            "SkyBridgePackagingApplePQCSDKSecureEnclaveSymbolsIncluded": true,
            "SkyBridgePackagingApplePQCSDKSymbolSet": "cryptokit-pqc-v1"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        let executableURL = macOSURL.appendingPathComponent("SkyBridgeCompassApp")
        try "#!/bin/sh\n# skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk\nexit 0\n".write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let packageData = Data("fake notarized dmg payload".utf8)
        let packageURL = tempRoot.appendingPathComponent("SkyBridgeCompassPro-1.2.0.dmg")
        try packageData.write(to: packageURL)
        let privateKeyURL = tempRoot.appendingPathComponent("manifest-key.txt")
        try "hxcB2jeo7OVtr1HYrtdJ6xRxqN6voO498K8FtePGZQk=".write(
            to: privateKeyURL,
            atomically: true,
            encoding: .utf8
        )
        let outputURL = tempRoot.appendingPathComponent("macos-stable.json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.currentDirectoryURL = root
        process.arguments = [
            "Scripts/generate_macos_update_manifest.swift",
            "--app-path", appURL.path,
            "--package-path", packageURL.path,
            "--download-url", "https://github.com/billlza/Skybridge-Compass/releases/download/stable/SkyBridgeCompassPro-1.2.0.dmg",
            "--release-notes-url", "https://github.com/billlza/Skybridge-Compass/releases/tag/stable",
            "--key-id", testKeyId,
            "--private-key-file", privateKeyURL.path,
            "--sequence", "2026052401",
            "--published-at", "2026-05-24T00:00:00Z",
            "--expires-at", "2026-06-24T00:00:00Z",
            "--output", outputURL.path,
            "--notarized"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let processOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, processOutput)

        let manifestData = try Data(contentsOf: outputURL)
        let manifest = try SkyBridgeAppUpdateEvaluator.decodeManifest(from: manifestData)
        let decision = try SkyBridgeAppUpdateEvaluator.evaluate(
            manifest: manifest,
            context: context(currentVersion: "1.1.9", currentBuild: "2026052301"),
            trustedSigningKeys: trustedSigningKeys()
        )

        XCTAssertEqual(decision.state, .updateAvailable)
        XCTAssertEqual(manifest.sha256, SHA256.hash(data: packageData).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(manifest.sizeBytes, Int64(packageData.count))
        XCTAssertEqual(manifest.signature?.keyId, testKeyId)
        XCTAssertEqual(manifest.applePQCSDKBuild?.compiledWithHASApplePQCSDK, true)
        XCTAssertEqual(manifest.applePQCSDKBuild?.probeMode, "symbol_probe")
        XCTAssertEqual(manifest.applePQCSDKBuild?.sdkName, "macosx")
        XCTAssertEqual(manifest.applePQCSDKBuild?.sdkVersion, "26.5")
        XCTAssertEqual(manifest.applePQCSDKBuild?.swiftTarget, "arm64-apple-macosx26.0")
        XCTAssertEqual(manifest.applePQCSDKBuild?.secureEnclaveSymbolsIncluded, true)
        XCTAssertEqual(manifest.applePQCSDKBuild?.symbolSet, "cryptokit-pqc-v1")
        XCTAssertEqual(manifest.applePQCSDKBuild?.signature?.keyId, testKeyId)
    }

    func testManifestWithFutureMinimumSystemVersionIsUnsupported() throws {
        let manifest = try decodeManifest(minimumSystemVersion: "99.0.0")
        let decision = try SkyBridgeAppUpdateEvaluator.evaluate(
            manifest: manifest,
            context: context(currentSystemVersion: "14.0.0"),
            trustedSigningKeys: trustedSigningKeys()
        )

        XCTAssertEqual(decision.state, .unsupportedSystemVersion)
    }

    func testManifestRejectsExpiredMetadata() throws {
        let manifest = try decodeManifest(
            publishedAt: "2026-05-20T00:00:00Z",
            expiresAt: "2026-05-24T00:00:00Z"
        )

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(now: updateNow),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .manifestExpired("2026-05-24T00:00:00Z")
            )
        }
    }

    func testManifestRejectsFuturePublishedMetadata() throws {
        let manifest = try decodeManifest(publishedAt: "2026-05-26T00:00:00Z")

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(now: updateNow),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .manifestPublishedInFuture("2026-05-26T00:00:00Z")
            )
        }
    }

    func testManifestRejectsSequenceRollback() throws {
        let manifest = try decodeManifest(sequence: 7)

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: manifest,
                context: context(now: updateNow, minimumAcceptedManifestSequence: 8),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .manifestSequenceRollback(minimum: 8, actual: 7)
            )
        }
    }

    func testManifestSignatureBindsAntiReplayFields() throws {
        let original = try decodeManifest(sequence: 7)
        let signature = try XCTUnwrap(original.signature?.value)
        let tampered = try decodeManifest(
            sequence: 8,
            signatureOverride: signature
        )

        XCTAssertThrowsError(
            try SkyBridgeAppUpdateEvaluator.evaluate(
                manifest: tampered,
                context: context(now: updateNow),
                trustedSigningKeys: trustedSigningKeys()
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeAppUpdateValidationError,
                .manifestSignatureVerificationFailed
            )
        }
    }

    private var testKeyId: String { "skybridge-test-update-key" }

    private var updateNow: Date {
        Date(timeIntervalSince1970: 1_779_667_200)
    }

    private var testPublicKeyBase64: String {
        "/E0iFV7ENOwcBoI7fVsVI7KYwRPiyYwev5oNvEqZuqY="
    }

    private var testPrivateKey: Curve25519.Signing.PrivateKey {
        get throws {
            let data = try XCTUnwrap(
                Data(base64Encoded: "hxcB2jeo7OVtr1HYrtdJ6xRxqN6voO498K8FtePGZQk=")
            )
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
    }

    private func trustedSigningKeys() -> [SkyBridgeAppUpdateTrustedSigningKey] {
        [
            SkyBridgeAppUpdateTrustedSigningKey(
                keyId: testKeyId,
                publicKeyBase64: testPublicKeyBase64
            )
        ]
    }

    private func context(
        currentVersion: String = "1.0.0",
        currentBuild: String = "1",
        currentSystemVersion: String = "14.0.0",
        now: Date = Date(timeIntervalSince1970: 1_779_667_200),
        minimumAcceptedManifestSequence: Int64 = 0
    ) -> SkyBridgeAppUpdateContext {
        SkyBridgeAppUpdateContext(
            bundleIdentifier: "com.skybridge.compass.pro",
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            currentSystemVersion: currentSystemVersion,
            now: now,
            minimumAcceptedManifestSequence: minimumAcceptedManifestSequence
        )
    }

    private func decodeManifest(
        bundleId: String = "com.skybridge.compass.pro",
        version: String = "1.2.0",
        build: String = "20260524",
        sequence: Int64 = 2026052401,
        publishedAt: String = "2026-05-24T00:00:00Z",
        expiresAt: String = "2026-06-24T00:00:00Z",
        minimumSystemVersion: String = "14.0.0",
        downloadURL: String = "https://skybridge-compass.vercel.app/releases/SkyBridgeCompassPro.dmg",
        notarized: Bool = true,
        includeApplePQCSDKBuild: Bool = true,
        applePQCSDKCompiled: Bool = true,
        applePQCSDKBuildProbeMode: String = "symbol_probe",
        applePQCSDKBuildSDKName: String = "macosx",
        applePQCSDKBuildSDKVersion: String = "26.5",
        applePQCSDKBuildSwiftTarget: String = "arm64-apple-macosx26.0",
        applePQCSDKBuildSecureEnclaveSymbolsIncluded: Bool = true,
        applePQCSDKBuildSymbolSet: String = "cryptokit-pqc-v1",
        applePQCSDKBuildSignatureOverride: String? = nil,
        signed: Bool = true,
        signatureOverride: String? = nil
    ) throws -> SkyBridgeAppUpdateManifest {
        let unsignedManifest = try SkyBridgeAppUpdateEvaluator.decodeManifest(
            from: Data(
                manifestJSON(
                    bundleId: bundleId,
                    version: version,
                    build: build,
                    sequence: sequence,
                    publishedAt: publishedAt,
                    expiresAt: expiresAt,
                    minimumSystemVersion: minimumSystemVersion,
                    downloadURL: downloadURL,
                    notarized: notarized,
                    includeApplePQCSDKBuild: includeApplePQCSDKBuild,
                    applePQCSDKCompiled: applePQCSDKCompiled,
                    applePQCSDKBuildProbeMode: applePQCSDKBuildProbeMode,
                    applePQCSDKBuildSDKName: applePQCSDKBuildSDKName,
                    applePQCSDKBuildSDKVersion: applePQCSDKBuildSDKVersion,
                    applePQCSDKBuildSwiftTarget: applePQCSDKBuildSwiftTarget,
                    applePQCSDKBuildSecureEnclaveSymbolsIncluded: applePQCSDKBuildSecureEnclaveSymbolsIncluded,
                    applePQCSDKBuildSymbolSet: applePQCSDKBuildSymbolSet,
                    applePQCSDKBuildSignatureValue: nil,
                    signatureValue: nil
                ).utf8
            )
        )
        let applePQCSDKBuildSignatureValue: String?
        if let applePQCSDKBuildSignatureOverride {
            applePQCSDKBuildSignatureValue = applePQCSDKBuildSignatureOverride
        } else if let attestation = unsignedManifest.applePQCSDKBuild {
            let payload = SkyBridgeAppUpdateEvaluator.applePQCSDKBuildSigningPayload(
                for: unsignedManifest,
                attestation: attestation
            )
            applePQCSDKBuildSignatureValue = try testPrivateKey.signature(for: payload).base64EncodedString()
        } else {
            applePQCSDKBuildSignatureValue = nil
        }
        let signatureValue: String?
        if let signatureOverride {
            signatureValue = signatureOverride
        } else if signed {
            let payload = SkyBridgeAppUpdateEvaluator.signingPayload(for: unsignedManifest)
            signatureValue = try testPrivateKey.signature(for: payload).base64EncodedString()
        } else {
            signatureValue = nil
        }
        return try SkyBridgeAppUpdateEvaluator.decodeManifest(
            from: Data(
                manifestJSON(
                    bundleId: bundleId,
                    version: version,
                    build: build,
                    sequence: sequence,
                    publishedAt: publishedAt,
                    expiresAt: expiresAt,
                    minimumSystemVersion: minimumSystemVersion,
                    downloadURL: downloadURL,
                    notarized: notarized,
                    includeApplePQCSDKBuild: includeApplePQCSDKBuild,
                    applePQCSDKCompiled: applePQCSDKCompiled,
                    applePQCSDKBuildProbeMode: applePQCSDKBuildProbeMode,
                    applePQCSDKBuildSDKName: applePQCSDKBuildSDKName,
                    applePQCSDKBuildSDKVersion: applePQCSDKBuildSDKVersion,
                    applePQCSDKBuildSwiftTarget: applePQCSDKBuildSwiftTarget,
                    applePQCSDKBuildSecureEnclaveSymbolsIncluded: applePQCSDKBuildSecureEnclaveSymbolsIncluded,
                    applePQCSDKBuildSymbolSet: applePQCSDKBuildSymbolSet,
                    applePQCSDKBuildSignatureValue: applePQCSDKBuildSignatureValue,
                    signatureValue: signatureValue
                ).utf8
            )
        )
    }

    private func manifestJSON(
        bundleId: String,
        version: String,
        build: String,
        sequence: Int64,
        publishedAt: String,
        expiresAt: String,
        minimumSystemVersion: String,
        downloadURL: String,
        notarized: Bool,
        includeApplePQCSDKBuild: Bool,
        applePQCSDKCompiled: Bool,
        applePQCSDKBuildProbeMode: String,
        applePQCSDKBuildSDKName: String,
        applePQCSDKBuildSDKVersion: String,
        applePQCSDKBuildSwiftTarget: String,
        applePQCSDKBuildSecureEnclaveSymbolsIncluded: Bool,
        applePQCSDKBuildSymbolSet: String,
        applePQCSDKBuildSignatureValue: String?,
        signatureValue: String?
    ) -> String {
        let applePQCSDKBuildJSON: String
        if includeApplePQCSDKBuild {
            let applePQCSDKBuildSignatureJSON: String
            if let applePQCSDKBuildSignatureValue {
                applePQCSDKBuildSignatureJSON = """
                    ,
                    "signature": {
                      "algorithm": "ed25519",
                      "key_id": "\(testKeyId)",
                      "value": "\(applePQCSDKBuildSignatureValue)"
                    }
                """
            } else {
                applePQCSDKBuildSignatureJSON = ""
            }
            let compileMarker = applePQCSDKCompiled
                ? "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk"
                : "skybridge.apple-pqc-sdk.compile-fact.v1.missing-has-apple-pqc-sdk"
            applePQCSDKBuildJSON = """
              ,
                "apple_pqc_sdk_build": {
                "compiled_with_has_apple_pqc_sdk": \(applePQCSDKCompiled ? "true" : "false"),
                "compile_marker": "\(compileMarker)",
                "probe_mode": "\(applePQCSDKBuildProbeMode)",
                "sdk_name": "\(applePQCSDKBuildSDKName)",
                "sdk_version": "\(applePQCSDKBuildSDKVersion)",
                "swift_target": "\(applePQCSDKBuildSwiftTarget)",
                "secure_enclave_symbols_included": \(applePQCSDKBuildSecureEnclaveSymbolsIncluded ? "true" : "false"),
                "symbol_set": "\(applePQCSDKBuildSymbolSet)"
            \(applePQCSDKBuildSignatureJSON)
              }
            """
        } else {
            applePQCSDKBuildJSON = ""
        }
        let signatureJSON: String
        if let signatureValue {
            signatureJSON = """
              ,
              "signature": {
                "algorithm": "ed25519",
                "key_id": "\(testKeyId)",
                "value": "\(signatureValue)"
              }
            """
        } else {
            signatureJSON = ""
        }
        let json = """
        {
          "schema_version": 1,
          "bundle_id": "\(bundleId)",
          "platform": "macos",
          "channel": "stable",
          "version": "\(version)",
          "build": "\(build)",
          "sequence": \(sequence),
          "published_at": "\(publishedAt)",
          "expires_at": "\(expiresAt)",
          "minimum_system_version": "\(minimumSystemVersion)",
          "release_notes_url": "https://skybridge-compass.vercel.app/releases/notes",
          "download_url": "\(downloadURL)",
          "sha256": "\(String(repeating: "a", count: 64))",
          "package_format": "dmg",
          "distribution": "developer-id",
          "notarized": \(notarized ? "true" : "false"),
          "size_bytes": 1024
        \(applePQCSDKBuildJSON)
        \(signatureJSON)
        }
        """
        return json
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = repositoryRoot()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
