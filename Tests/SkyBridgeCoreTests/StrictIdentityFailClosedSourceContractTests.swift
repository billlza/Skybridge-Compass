import Foundation
import XCTest

final class StrictIdentityFailClosedSourceContractTests: XCTestCase {
    func testRegistrationFingerprintIsAuthorityOnlyAndRegistrationMetadataCannotBeBlank() throws {
        let identitySource = try repositorySource(
            "Sources/SkyBridgeCore/Utilities/SelfIdentityProvider.swift"
        )
        let registrationSection = try XCTUnwrap(
            identitySource.range(of: "public func generateRegistrationFingerprint")
        )
        let registrationEnd = try XCTUnwrap(
            identitySource.range(
                of: "/// \u{83b7}\u{53d6}\u{8bbe}\u{5907}\u{6307}\u{7eb9}\u{4fe1}\u{606f}",
                range: registrationSection.lowerBound..<identitySource.endIndex
            )
        )
        let fingerprintSource = String(
            identitySource[registrationSection.lowerBound..<registrationEnd.lowerBound]
        )

        XCTAssertTrue(fingerprintSource.contains("loadAuthoritativeIdentity(allowCreate: allowCreate)"))
        XCTAssertTrue(fingerprintSource.contains("com.skybridge.registration-device-fingerprint.v1"))
        XCTAssertFalse(fingerprintSource.contains("Host.current"))
        XCTAssertFalse(fingerprintSource.contains("macSet"))
        XCTAssertFalse(fingerprintSource.contains("getHardware"))

        let authenticationSource = try repositorySource(
            "Sources/SkyBridgeCompassApp/AuthenticationViewModel.swift"
        )
        XCTAssertTrue(
            authenticationSource.contains(
                "\"device_fingerprint\": riskOutcome.deviceFingerprint"
            )
        )
        XCTAssertFalse(authenticationSource.contains("ensureDeviceFingerprint() ?? \"\""))
        XCTAssertTrue(authenticationSource.contains("private func ensureDeviceFingerprint() async throws -> String"))
    }

    func testFileTransferBonjourPublishesOnlyAfterAuthorityResolution() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/FileTransfer/FileTransferListenerService.swift"
        )
        let authority = try XCTUnwrap(
            source.range(of: "CanonicalBonjourAdvertisementIdentityProvider.current(")
        )
        let listenerStart = try XCTUnwrap(source.range(of: "let parameters = makeListenerParameters()"))

        XCTAssertLessThan(authority.lowerBound, listenerStart.lowerBound)
        XCTAssertTrue(source.contains("configureBonjour(on: listener, identity: identity)"))
        XCTAssertTrue(source.contains("BonjourInteropContract.makeCanonicalAdvertisementTXT("))
        XCTAssertTrue(source.contains("deviceId: identity.deviceId"))
        XCTAssertTrue(source.contains("pubKeyFingerprint: identity.protocolPublicKeyFingerprint"))
        XCTAssertFalse(source.contains("deviceId: nil"))
        XCTAssertFalse(source.contains("snap.deviceId.isEmpty ? serviceName"))
    }

    func testWebRTCAndICloudActiveNamespacesNeverUseHostDerivedIdentity() throws {
        let manager = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let fileTransfer = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCFileTransfer.swift"
        )

        XCTAssertFalse(manager.contains("CrossNetworkConnectionRuntimeSupport.deviceFingerprint()"))
        XCTAssertFalse(manager.contains("?? deviceFingerprint"))
        XCTAssertFalse(manager.contains("?? self.deviceFingerprint"))
        XCTAssertTrue(manager.contains("sessionBoundSignalingAuthority("))
        XCTAssertTrue(manager.contains("case .sent, .blocked:"))
        XCTAssertTrue(manager.contains("fromDevice: localAuthorityDeviceId"))
        XCTAssertTrue(manager.contains("skybridge.answer.\\(localAuthorityDeviceId)"))

        XCTAssertTrue(fileTransfer.contains("protocolIdentityDeviceId(allowCreate: false)"))
        XCTAssertTrue(fileTransfer.contains("senderDeviceId: senderDeviceId"))
        XCTAssertFalse(fileTransfer.contains("senderDeviceId: snap.deviceId.isEmpty"))
    }

    func testCloudKitAndCloudPresenceKeepAuthoritySeparateFromCompatibilityRoutes() throws {
        let cloudKit = try repositorySource(
            "Sources/SkyBridgeCore/Services/CloudKitService.swift"
        )
        XCTAssertFalse(cloudKit.contains("KeychainManager.shared.getOrGenerateDeviceId()"))
        XCTAssertTrue(cloudKit.contains("snapshotEnsuringProtocolDeviceId(allowCreate: allowCreate)"))
        XCTAssertTrue(cloudKit.contains("record[\"deviceId\"] = identity.deviceId"))
        XCTAssertTrue(cloudKit.contains("record[\"publicKeyFingerprint\"] = identity.pubKeyFP"))

        let unified = try repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/UnifiedOnlineDeviceManager.swift"
        )
        XCTAssertFalse(unified.contains("stableIdentityDeviceId ?? device.id"))
        XCTAssertFalse(unified.contains("[cloudDevice.stableIdentityDeviceId, cloudDevice.id]"))
        XCTAssertTrue(unified.contains("stableDeviceId: device.stableIdentityDeviceId"))
    }

    func testDisabledPAKEAndSelfIdentityAPIsCannotSynthesizeSecurityIdentity() throws {
        let pake = try repositorySource("Sources/SkyBridgeCore/P2P/PAKEService.swift")
        XCTAssertTrue(pake.contains("unavailable,"))
        XCTAssertTrue(pake.contains("public actor PAKEService {}"))
        XCTAssertFalse(pake.contains("public init("))

        let identity = try repositorySource(
            "Sources/SkyBridgeCore/Utilities/SelfIdentityProvider.swift"
        )
        XCTAssertTrue(identity.contains("func presentationSnapshot() -> SelfIdentitySnapshot"))
        XCTAssertFalse(identity.contains("public func presentationSnapshot()"))
        XCTAssertFalse(identity.contains("public func snapshot() -> SelfIdentitySnapshot"))

        let crossNetwork = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        XCTAssertFalse(crossNetwork.contains("SelfIdentityProvider.shared.snapshot()"))
        XCTAssertFalse(crossNetwork.contains("selfIdentity.deviceId.isEmpty"))
    }

    func testPublicIdentityAndKeychainMaintenanceCannotBypassAuthority() throws {
        let manager = try repositorySource(
            "Sources/SkyBridgeCore/P2P/DeviceIdentityKeyManager.swift"
        )
        let deleteStart = try XCTUnwrap(
            manager.range(of: "public func deleteIdentityKey() throws")
        )
        let deleteEnd = try XCTUnwrap(
            manager.range(
                of: "// MARK: - Private Methods",
                range: deleteStart.lowerBound..<manager.endIndex
            )
        )
        let deleteBody = manager[deleteStart.lowerBound..<deleteEnd.lowerBound]
        XCTAssertTrue(deleteBody.contains("keyRotationFailed"))
        XCTAssertFalse(deleteBody.contains("deleteExistingKey"))
        XCTAssertFalse(manager.contains("private func deleteExistingKey()"))

        let keychain = try repositorySource(
            "Sources/SkyBridgeCore/Security/KeychainManager.swift"
        )
        XCTAssertFalse(keychain.contains("func deduplicate(servicePrefix:"))
        XCTAssertFalse(keychain.contains("func getOrGenerateDeviceId"))

        let settings = try repositorySource("Sources/SkyBridgeCore/Views/SettingsView.swift")
        XCTAssertFalse(settings.contains("deduplicateKeychain"))
        XCTAssertFalse(settings.contains(".deduplicate(servicePrefix:"))
    }

    func testSignedPersistentReferenceProbeIsCrashRecoverableAndFailClosed() throws {
        let probe = try repositorySource(
            "Scripts/macos_keychain_persistent_ref_probe.swift"
        )

        XCTAssertTrue(
            probe.contains(
                "com.skybridge.release-probe.persistent-ref.v1"
            ),
            "A stable namespace is required so a later run can remove crash remnants"
        )
        XCTAssertFalse(probe.contains("UUID().uuidString"))
        XCTAssertTrue(probe.contains("O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC"))
        XCTAssertTrue(probe.contains("private func removeUniqueProbeItems(in domain: KeychainDomain) throws"))
        XCTAssertTrue(probe.contains("private func removeUniqueProbePrivateKey(in domain: KeychainDomain) throws"))
        XCTAssertTrue(probe.contains("private func withVerifiedCleanup("))
        XCTAssertTrue(probe.contains("try verifyAbsent()"))
        XCTAssertTrue(probe.contains("verifyAbsent: verifyGenericPasswordArtifactsAbsent"))
        XCTAssertTrue(probe.contains("try verifyPrivateKeyArtifactsAbsent(accessGroup: accessGroup)"))
        XCTAssertTrue(
            probe.contains("case (.secItemAdd, _), (.discovery, true):"),
            "Data Protection discovery references must use kSecValuePersistentRef"
        )
        XCTAssertTrue(probe.contains("origin: .discovery"))
        XCTAssertTrue(probe.contains(") == expectedValue else"))
        XCTAssertFalse(probe.contains("try? removeUniqueProbe"))
    }

    func testSignedIdentityAuditIsReadOnlyStableAndRedacted() throws {
        let manager = try repositorySource(
            "Sources/SkyBridgeCore/P2P/DeviceIdentityKeyManager.swift"
        )
        let auditStart = try XCTUnwrap(
            manager.range(of: "public func legacyIdentityAuditReport() throws")
        )
        let auditEnd = try XCTUnwrap(
            manager.range(
                of: "/// Loads the device ID from an existing identity authority",
                range: auditStart.lowerBound..<manager.endIndex
            )
        )
        let auditBody = manager[auditStart.lowerBound..<auditEnd.lowerBound]
        XCTAssertEqual(
            auditBody.components(
                separatedBy: "discoverStableLegacyIdentity(using: store)"
            ).count - 1,
            1
        )
        XCTAssertEqual(
            auditBody.components(
                separatedBy: "DeviceIdentityAuthorityTransaction.resolve"
            ).count - 1,
            3,
            "The incomplete path must revalidate the authority before emitting structured degraded evidence"
        )
        XCTAssertTrue(manager.contains("guard initial == verified"))
        XCTAssertTrue(auditBody.contains("legacyIdentityChangedDuringAudit"))
        XCTAssertTrue(auditBody.contains("state: .inspectionUnavailable"))
        XCTAssertTrue(auditBody.contains("inspectionStatus: .unavailable"))
        for mutation in [
            "cleanupLegacyIdentity",
            "migrateLegacyIdentity",
            "claimCandidate",
            "insertAuthorityIfAbsent",
            "deleteLegacyPrivateKey",
            "deleteLegacyGenericPasswordCandidate",
            "createNewIdentityKey"
        ] {
            XCTAssertFalse(auditBody.contains(mutation))
        }

        let host = try repositorySource("Sources/LocalLanInteropHost/main.swift")
        XCTAssertTrue(
            host.contains("@_spi(SkyBridgeSmokeDiagnostics) import SkyBridgeCore")
        )
        XCTAssertTrue(host.contains("SKYBRIDGE_SMOKE_IDENTITY_AUDIT_ONLY"))
        XCTAssertTrue(host.contains("encoder.outputFormatting = [.sortedKeys]"))
        XCTAssertTrue(host.contains("read-only-audit-error"))
        XCTAssertFalse(
            host.contains(#"identity audit failed: \(error.localizedDescription)"#)
        )
        XCTAssertTrue(host.contains(#"failed stage=identity code=\(code)"#))
        XCTAssertFalse(
            host.contains(
                #"failed stage=identity error=\(sanitize(error.localizedDescription))"#
            )
        )
    }

    func testLegacyMigrationPromotesOnlyTheCommittedTupleAndRetainsResidue() throws {
        let manager = try repositorySource(
            "Sources/SkyBridgeCore/P2P/DeviceIdentityKeyManager.swift"
        )
        XCTAssertFalse(manager.contains("cleanupLegacyIdentity"))
        XCTAssertFalse(manager.contains("deleteLegacyPrivateKey"))
        XCTAssertTrue(manager.contains("committedMigrationKeyInfo(from: legacy.state)"))
        XCTAssertTrue(manager.contains("uniqueCommittedMigrationPrivateKey("))
        XCTAssertTrue(manager.contains("resolveValidatedAuthority("))
        XCTAssertTrue(
            manager.contains(
                "Legacy identity residue retained beside the validated shared authority"
            )
        )

        let authority = try repositorySource(
            "Sources/SkyBridgeCore/P2P/DeviceIdentityAuthority.swift"
        )
        XCTAssertFalse(authority.contains("func deleteLegacyPrivateKey("))
        XCTAssertTrue(authority.contains("keyInfo last"))
        XCTAssertTrue(authority.contains("standalone deviceId"))
        XCTAssertTrue(authority.contains("matches.count == 1"))
    }

    func testValidatedAuthoritySeparatesTypedResidueHealthFromAuthorityUse() throws {
        let manager = try repositorySource(
            "Sources/SkyBridgeCore/P2P/DeviceIdentityKeyManager.swift"
        )
        XCTAssertTrue(manager.contains("private struct LegacyResidueInspectionError"))
        XCTAssertTrue(manager.contains("discoverStableLegacyIdentity(using: store)"))
        XCTAssertTrue(
            manager.contains(
                "catch let inspectionError as LegacyResidueInspectionError"
            )
        )
        XCTAssertTrue(manager.contains("return .unavailable(inspectionError.reason)"))
        XCTAssertTrue(
            manager.contains(
                "legacyMigrationPolicy: .rejectMutation"
            ),
            "The read-only existing-authority API must not migrate legacy data"
        )
        XCTAssertTrue(
            manager.contains("legacyIdentityRequiresExplicitMigration")
        )
        XCTAssertFalse(
            manager.contains("localizedDescription, privacy: .public"),
            "Identity storage metadata must not cross a public log boundary"
        )

        let host = try repositorySource("Sources/LocalLanInteropHost/main.swift")
        XCTAssertTrue(host.contains("lastLegacyResidueInspectionStatus()"))
        XCTAssertTrue(host.contains("guard residueStatus.inspectionComplete"))
        XCTAssertTrue(host.contains("legacyResidueInspectionComplete="))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
