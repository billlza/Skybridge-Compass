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
        let appInfo = try repositorySource("Sources/SkyBridgeCompassApp/Info.plist")
        let xcodeProjectSource = try repositorySource("SkyBridgeWidgets.xcodeproj/project.pbxproj")
        let generator = try repositorySource("Scripts/generate_macos_update_manifest.swift")
        let publisher = try repositorySource("Scripts/publish_macos_update_release.sh")
        let releaseReadiness = try repositorySource("Scripts/check_macos_release_readiness.sh")
        let workflow = try repositorySource(".github/workflows/macos-release-readiness.yml")
        let fastfile = try repositorySource("fastlane/Fastfile")
        let xcodeVerifier = try repositorySource("Scripts/verify_xcode_toolchain.sh")

        XCTAssertTrue(source.contains("trustedSigningKeys: [SkyBridgeAppUpdateTrustedSigningKey]"))
        XCTAssertTrue(source.contains("trustedSigningKeys: trustedSigningKeys"))
        XCTAssertTrue(source.contains("SkyBridgeAppUpdateSequenceStoring"))
        XCTAssertTrue(source.contains("highestAcceptedSequence()"))
        XCTAssertTrue(source.contains("minimumAcceptedManifestSequence: minimumSequence"))
        XCTAssertTrue(source.contains("recordAcceptedSequence(decision.manifest.sequence)"))
        XCTAssertTrue(source.contains("https://github.com/billlza/Skybridge-Compass/releases/download/stable/macos-stable.json"))
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
        XCTAssertFalse(
            generator.contains("--private-key-base64"),
            "The update manifest generator must not accept private key material as a command-line argument."
        )
        XCTAssertTrue(publisher.contains("Scripts/generate_macos_update_manifest.swift"))
        XCTAssertTrue(publisher.contains("macos-stable.json"))
        XCTAssertTrue(publisher.contains("gh release upload"))
        XCTAssertTrue(publisher.contains("gh release download"))
        XCTAssertTrue(publisher.contains("xcrun stapler validate"))
        XCTAssertTrue(publisher.contains("--clobber"))
        XCTAssertTrue(publisher.contains("resolve_default_sequence"))
        XCTAssertTrue(publisher.contains("date -u '+%Y%m%d%H%M%S'"))
        XCTAssertTrue(publisher.contains("https://github.com/${REPOSITORY}/releases/download/${TAG_NAME}"))
        XCTAssertTrue(releaseReadiness.contains("generate_macos_update_manifest.swift"))
        XCTAssertTrue(releaseReadiness.contains("publish_macos_update_release.sh"))
        XCTAssertTrue(releaseReadiness.contains("verify_xcode_toolchain.sh"))
        XCTAssertTrue(workflow.contains("DEVELOPER_DIR: /Applications/Xcode_26.5.app/Contents/Developer"))
        XCTAssertTrue(workflow.contains("SKYBRIDGE_REQUIRED_APPLE_SWIFT_VERSION: \"6.3.2\""))
        XCTAssertFalse(
            workflow.contains("swift-actions/setup-swift"),
            "Apple-platform release builds must use the Xcode 26.5 Apple toolchain, not a separate Swift.org toolchain."
        )
        XCTAssertTrue(workflow.contains("contents: write"))
        XCTAssertTrue(workflow.contains("actions/download-artifact@v4"))
        XCTAssertTrue(workflow.contains("Scripts/publish_macos_update_release.sh"))
        XCTAssertTrue(workflow.contains("SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64"))
        XCTAssertTrue(workflow.contains("--connectivity-artifact-dir \"Artifacts/release-gate/connectivity\""))
        XCTAssertTrue(workflow.contains("--p2p-remote-artifact-dir \"Artifacts/release-gate/p2p-remote\""))
        XCTAssertTrue(workflow.contains("--file-transfer-artifact-dir \"Artifacts/release-gate/file-transfer\""))
        XCTAssertTrue(fastfile.contains("SKYBRIDGE_RELEASE_GATE_CONNECTIVITY_ARTIFACT_DIR"))
        XCTAssertTrue(fastfile.contains("Scripts/publish_macos_update_release.sh"))
        XCTAssertTrue(xcodeVerifier.contains("EXPECTED_XCODE_VERSION=\"${SKYBRIDGE_REQUIRED_XCODE_VERSION:-26.5}\""))
        XCTAssertTrue(xcodeVerifier.contains("EXPECTED_SWIFT_VERSION=\"${SKYBRIDGE_REQUIRED_APPLE_SWIFT_VERSION:-6.3.2}\""))
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
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.skybridge.compass.pro",
            "CFBundleShortVersionString": "1.2.0",
            "CFBundleVersion": "2026052401",
            "LSMinimumSystemVersion": "14.0.0"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

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
                    signatureValue: nil
                ).utf8
            )
        )
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
        signatureValue: String?
    ) -> String {
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
