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
            source.range(of: "snapshotEnsuringProtocolDeviceId(allowCreate: true)")
        )
        let listenerStart = try XCTUnwrap(source.range(of: "makeStartedListener(parameters:"))

        XCTAssertLessThan(authority.lowerBound, listenerStart.lowerBound)
        XCTAssertTrue(source.contains("configureBonjour(on: boundListener, port: boundPort, identity: identity)"))
        XCTAssertTrue(source.contains("txt[\"deviceId\"] = identity.deviceId"))
        XCTAssertTrue(source.contains("txt[\"pubKeyFP\"] = identity.pubKeyFP"))
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
        XCTAssertTrue(manager.contains("sessionBoundSignalingDeviceId("))
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

    func testPAKEAndSelfIdentityAPIsCannotSynthesizeOrExposeEmptySecurityIdentity() throws {
        let pake = try repositorySource("Sources/SkyBridgeCore/P2P/PAKEService.swift")
        XCTAssertTrue(
            pake.contains(
                "public init(localDeviceId: String, limits: SecurityLimits = .default) throws"
            )
        )
        XCTAssertTrue(pake.contains("throw PAKEError.invalidLocalDeviceId"))
        XCTAssertFalse(pake.contains("localDeviceId: String? = nil"))
        XCTAssertFalse(pake.contains("localDeviceId ?? UUID().uuidString"))

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
        XCTAssertFalse(probe.contains("try? removeUniqueProbe"))
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
