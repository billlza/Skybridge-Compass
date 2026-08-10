import Foundation
import Network
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCore

final class BonjourInteropContractTests: XCTestCase {
    func testProtocolCoreBonjourContractIsFoundationOnlyAndAppleAdapterOwnsNetworkTXT() throws {
        let coreSource = try repositorySource(
            "Sources/SkyBridgeProtocolCore/Discovery/BonjourInteropProtocolContract.swift"
        )
        let adapterSource = try repositorySource(
            "Sources/SkyBridgeCore/Discovery/BonjourInteropContract.swift"
        )

        XCTAssertTrue(coreSource.contains("import Foundation"))
        XCTAssertFalse(coreSource.contains("import Network"))
        XCTAssertFalse(coreSource.contains("NWTXTRecord"))
        XCTAssertFalse(coreSource.contains("WebRTCRemoteDesktopVideoFormatPolicy"))
        XCTAssertTrue(adapterSource.contains("typealias Core = BonjourInteropProtocolContract"))
        XCTAssertTrue(adapterSource.contains("makeCanonicalAdvertisementTXT("))
        XCTAssertFalse(adapterSource.contains("WebRTCRemoteDesktopVideoFormatPolicy"))
    }

    func testProtocolCoreBonjourContractMatchesAppleAdapterConstants() {
        XCTAssertEqual(BonjourInteropProtocolContract.controlServiceType, BonjourInteropContract.controlServiceType)
        XCTAssertEqual(BonjourInteropProtocolContract.fileTransferServiceType, BonjourInteropContract.fileTransferServiceType)
        XCTAssertEqual(BonjourInteropProtocolContract.remoteControlServiceType, BonjourInteropContract.remoteControlServiceType)
        XCTAssertEqual(BonjourInteropProtocolContract.defaultDiscoveryServiceTypes, BonjourInteropContract.defaultDiscoveryServiceTypes)
        XCTAssertEqual(BonjourInteropProtocolContract.fileTransferCapabilities, BonjourInteropContract.fileTransferCapabilities)
        XCTAssertEqual(BonjourInteropProtocolContract.remoteControlCapabilities, BonjourInteropContract.remoteControlCapabilities)
        XCTAssertEqual(BonjourInteropProtocolContract.remoteVideoFormatTXTKeys, BonjourInteropContract.remoteVideoFormatTXTKeys)
        XCTAssertEqual(BonjourInteropProtocolContract.fileTransferPortTXTKeys, BonjourInteropContract.fileTransferPortTXTKeys)
        XCTAssertEqual(BonjourInteropProtocolContract.remoteControlPortTXTKeys, BonjourInteropContract.remoteControlPortTXTKeys)
        XCTAssertEqual(BonjourInteropProtocolContract.pubKeyFingerprintTXTKeys, BonjourInteropContract.pubKeyFingerprintTXTKeys)
        XCTAssertEqual(BonjourInteropProtocolContract.deviceIdentityTXTKeys, BonjourInteropContract.deviceIdentityTXTKeys)
        XCTAssertEqual(
            BonjourInteropProtocolContract.windowsCompatibilityDiscoveryServiceTypes,
            BonjourInteropContract.windowsCompatibilityDiscoveryServiceTypes
        )
        XCTAssertEqual(
            BonjourInteropProtocolContract.canonicalAdvertisementTXTKeys,
            BonjourInteropContract.canonicalAdvertisementTXTKeys
        )
        XCTAssertEqual(
            BonjourInteropProtocolContract.maximumRecommendedTXTRecordWireBytes,
            BonjourInteropContract.maximumRecommendedTXTRecordWireBytes
        )
        XCTAssertEqual(
            BonjourInteropProtocolContract.normalizedPubKeyFingerprint(String(repeating: "a", count: 64)),
            BonjourInteropContract.normalizedPubKeyFingerprint(String(repeating: "a", count: 64))
        )
        XCTAssertEqual(
            BonjourInteropProtocolContract.normalizedRemoteVideoFormats(["hevc", "vp9", "jpeg"]),
            BonjourInteropContract.normalizedRemoteVideoFormats(["hevc", "vp9", "jpeg"])
        )
    }

    func testProtocolCoreBuildsCanonicalVersion2TXTWithinWireBudget() throws {
        let deviceId = "a35d39f7-c551-4857-9c55-77026e860f28"
        let fingerprint = String(repeating: "a", count: 64)
        let fields = try BonjourInteropProtocolContract.canonicalAdvertisementFields(
            deviceId: deviceId,
            pubKeyFingerprint: fingerprint,
            platform: .macOS,
            role: .control
        )

        XCTAssertEqual(fields, [
            "version": "2",
            "deviceId": deviceId,
            "pubKeyFP": fingerprint,
            "platform": "macos",
            "hs_soa": "1"
        ])
        XCTAssertEqual(try BonjourInteropProtocolContract.txtRecordWireSize(fields), 154)

        let networkRecord = try BonjourInteropContract.makeCanonicalAdvertisementTXT(
            deviceId: deviceId,
            pubKeyFingerprint: fingerprint,
            platform: .macOS,
            role: .control
        )
        XCTAssertEqual(networkRecord.data.count, 154)

        let coreWireData = try BonjourInteropProtocolContract.canonicalAdvertisementWireData(
            deviceId: deviceId,
            pubKeyFingerprint: fingerprint,
            platform: .macOS,
            role: .control
        )
        XCTAssertEqual(coreWireData.count, 154)

        XCTAssertEqual(networkRecord.data, coreWireData)
    }

    func testAppleWritersUseUnsignedRawKeyOrderDeterministically() throws {
        let deviceId = "a35d39f7-c551-4857-9c55-77026e860f28"
        let fingerprint = String(repeating: "a", count: 64)
        let cases: [(
            role: BonjourInteropContract.AdvertisementRole,
            entries: [(String, String)],
            expectedWireByteCount: Int
        )] = [
            (
                .control,
                [
                    ("deviceId", deviceId),
                    ("hs_soa", "1"),
                    ("platform", "macos"),
                    ("pubKeyFP", fingerprint),
                    ("version", "2")
                ],
                154
            ),
            (
                .dedicatedService,
                [
                    ("deviceId", deviceId),
                    ("platform", "macos"),
                    ("pubKeyFP", fingerprint),
                    ("version", "2")
                ],
                145
            )
        ]

        for testCase in cases {
            let expected = encodeTXT(testCase.entries)
            XCTAssertEqual(expected.count, testCase.expectedWireByteCount)
            XCTAssertLessThanOrEqual(
                expected.count,
                BonjourInteropContract.maximumRecommendedTXTRecordWireBytes
            )

            for _ in 0..<64 {
                let coreRecord = try BonjourInteropProtocolContract
                    .canonicalAdvertisementWireData(
                        deviceId: deviceId,
                        pubKeyFingerprint: fingerprint,
                        platform: .macOS,
                        role: testCase.role
                    )
                let networkRecord = try BonjourInteropContract.makeCanonicalAdvertisementTXT(
                    deviceId: deviceId,
                    pubKeyFingerprint: fingerprint,
                    platform: .macOS,
                    role: testCase.role
                )
                XCTAssertEqual(coreRecord, expected)
                XCTAssertEqual(networkRecord.data, expected)
            }
        }
    }

    func testLegacyDecodeRemainsIndependentOfCanonicalWriterOrder() throws {
        let fingerprint = String(repeating: "b", count: 64)
        let legacy = encodeTXT([
            ("pubKeyFP", fingerprint),
            ("platform", "ios"),
            ("deviceId", "legacy-device-id-0009"),
            ("version", "1.0.0")
        ])

        let decoded = try BonjourInteropProtocolContract.decodeAdvertisement(
            legacy,
            role: .control
        )

        guard case .legacy(let fields) = decoded else {
            return XCTFail("Expected shuffled legacy TXT input to remain compatible")
        }
        XCTAssertEqual(fields["deviceId"], "legacy-device-id-0009")
        XCTAssertEqual(fields["pubKeyFP"], fingerprint)
        XCTAssertEqual(
            decoded.discoveryProjection,
            BonjourInteropProtocolContract.DiscoveryProjection(
                generation: .legacy,
                deviceId: "legacy-device-id-0009",
                protocolPublicKeyFingerprint: fingerprint,
                platform: .iOS,
                advertisesStrongOwnerAuthentication: false
            )
        )
    }

    func testDedicatedServiceTXTUsesIdentityOnlyAndSRVOwnsPort() throws {
        let fields = try BonjourInteropProtocolContract.canonicalAdvertisementFields(
            deviceId: "a35d39f7-c551-4857-9c55-77026e860f28",
            pubKeyFingerprint: String(repeating: "b", count: 64),
            platform: .iPadOS,
            role: .dedicatedService
        )

        XCTAssertEqual(Set(fields.keys), ["version", "deviceId", "pubKeyFP", "platform"])
        XCTAssertNil(fields["hs_soa"])
        XCTAssertNil(fields["port"])
        XCTAssertNil(fields["capabilities"])
        XCTAssertNil(fields["remoteVideoFormats"])
    }

    func testCanonicalAdvertisementRejectsMalformedAndOversizedIdentity() throws {
        let fingerprint = String(repeating: "c", count: 64)
        XCTAssertNoThrow(try BonjourInteropProtocolContract.canonicalAdvertisementFields(
            deviceId: String(repeating: "d", count: 82),
            pubKeyFingerprint: fingerprint,
            platform: .macOS,
            role: .control
        ))
        XCTAssertThrowsError(try BonjourInteropProtocolContract.canonicalAdvertisementFields(
            deviceId: String(repeating: "d", count: 83),
            pubKeyFingerprint: fingerprint,
            platform: .macOS,
            role: .control
        )) { error in
            XCTAssertEqual(
                error as? BonjourInteropProtocolContract.AdvertisementError,
                .recordExceedsRecommendedSize(bytes: 201, maximum: 200)
            )
        }
        XCTAssertThrowsError(try BonjourInteropProtocolContract.canonicalAdvertisementFields(
            deviceId: "a35d39f7-c551-4857-9c55-77026e860f28",
            pubKeyFingerprint: String(repeating: "A", count: 64),
            platform: .macOS,
            role: .control
        ))
    }

    func testVersion2DecoderPreservesTypedAuthorityAndRole() throws {
        let fields = try BonjourInteropProtocolContract.canonicalAdvertisementFields(
            deviceId: "a35d39f7-c551-4857-9c55-77026e860f28",
            pubKeyFingerprint: String(repeating: "e", count: 64),
            platform: .iPadOS,
            role: .control
        )
        let decoded = try BonjourInteropProtocolContract.decodeAdvertisement(
            encodeTXT(fields.map { ($0.key, $0.value) }),
            role: .control
        )

        guard case .version2(let advertisement) = decoded else {
            return XCTFail("Expected a typed version-2 advertisement")
        }
        XCTAssertEqual(advertisement.deviceId, fields["deviceId"])
        XCTAssertEqual(advertisement.protocolPublicKeyFingerprint, fields["pubKeyFP"])
        XCTAssertEqual(advertisement.platform, .iPadOS)
        XCTAssertEqual(advertisement.role, .control)
        XCTAssertEqual(advertisement.canonicalFields, fields)
        XCTAssertEqual(
            decoded.discoveryProjection,
            BonjourInteropProtocolContract.DiscoveryProjection(
                generation: .version2,
                deviceId: fields["deviceId"],
                protocolPublicKeyFingerprint: fields["pubKeyFP"],
                platform: .iPadOS,
                advertisesStrongOwnerAuthentication: true
            )
        )
    }

    func testVersion2DecoderRejectsDuplicateCaseCollisionAndLegacyFields() throws {
        let baseEntries = [
            ("version", "2"),
            ("deviceId", "a35d39f7-c551-4857-9c55-77026e860f28"),
            ("pubKeyFP", String(repeating: "f", count: 64)),
            ("platform", "macos"),
            ("hs_soa", "1")
        ]

        XCTAssertThrowsError(try BonjourInteropProtocolContract.decodeAdvertisement(
            encodeTXT(baseEntries + [("DeviceId", "another-device-id-0001")]),
            role: .control
        )) { error in
            XCTAssertEqual(
                error as? BonjourInteropProtocolContract.AdvertisementError,
                .duplicateKey("DeviceId")
            )
        }
        XCTAssertThrowsError(try BonjourInteropProtocolContract.decodeAdvertisement(
            encodeTXT(baseEntries + [("controlPort", "9527")]),
            role: .control
        )) { error in
            XCTAssertEqual(
                error as? BonjourInteropProtocolContract.AdvertisementError,
                .invalidVersion2FieldSet
            )
        }
        XCTAssertThrowsError(try BonjourInteropProtocolContract.decodeAdvertisement(
            encodeTXT(baseEntries + [("kemPublicKey", String(repeating: "k", count: 96))]),
            role: .control
        )) { error in
            XCTAssertEqual(
                error as? BonjourInteropProtocolContract.AdvertisementError,
                .invalidVersion2FieldSet,
                "Prohibited v2 fields must be classified before the canonical-size budget"
            )
        }
        XCTAssertThrowsError(try BonjourInteropProtocolContract.decodeAdvertisement(
            encodeTXT([
                ("Version", "2"),
                ("deviceId", "a35d39f7-c551-4857-9c55-77026e860f28"),
                ("pubKeyFP", String(repeating: "f", count: 64)),
                ("platform", "macos"),
                ("hs_soa", "1")
            ]),
            role: .control
        )) { error in
            XCTAssertEqual(
                error as? BonjourInteropProtocolContract.AdvertisementError,
                .invalidVersion2FieldSet,
                "A case-variant v2 marker must never downgrade to legacy parsing"
            )
        }
    }

    func testVersion2DecoderSeparatesCanonicalBudgetFromParserSafetyLimit() throws {
        let oversizedCanonicalEntries = [
            ("version", "2"),
            ("deviceId", String(repeating: "d", count: 83)),
            ("pubKeyFP", String(repeating: "f", count: 64)),
            ("platform", "macos"),
            ("hs_soa", "1")
        ]
        XCTAssertThrowsError(try BonjourInteropProtocolContract.decodeAdvertisement(
            encodeTXT(oversizedCanonicalEntries),
            role: .control
        )) { error in
            XCTAssertEqual(
                error as? BonjourInteropProtocolContract.AdvertisementError,
                .recordExceedsRecommendedSize(bytes: 201, maximum: 200)
            )
        }

        let parserOversizedData = Data(
            repeating: 0,
            count: BonjourInteropProtocolContract.maximumAcceptedTXTRecordWireBytes + 1
        )
        XCTAssertThrowsError(try BonjourInteropProtocolContract.decodeAdvertisement(
            parserOversizedData,
            role: .control
        )) { error in
            XCTAssertEqual(
                error as? BonjourInteropProtocolContract.AdvertisementError,
                .recordExceedsParserSafetyLimit(bytes: 1_301, maximum: 1_300)
            )
        }
    }

    func testVersion2DecoderNeverDowngradesMalformedOrUnknownVersion() throws {
        let legacy = encodeTXT([
            ("version", "1.0.0"),
            ("uuid", "legacy-device-id-0001"),
            ("identityFingerprint", String(repeating: "a", count: 64))
        ])
        guard case .legacy(let fields) = try BonjourInteropProtocolContract.decodeAdvertisement(
            legacy,
            role: .control
        ) else {
            return XCTFail("Expected an explicit legacy decode")
        }
        XCTAssertEqual(fields["uuid"], "legacy-device-id-0001")
        XCTAssertEqual(
            try BonjourInteropProtocolContract.decodeAdvertisement(
                legacy,
                role: .control
            ).discoveryProjection,
            BonjourInteropProtocolContract.DiscoveryProjection(
                generation: .legacy,
                deviceId: "legacy-device-id-0001",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                platform: nil,
                advertisesStrongOwnerAuthentication: false
            )
        )

        XCTAssertThrowsError(try BonjourInteropProtocolContract.decodeAdvertisement(
            encodeTXT([("version", "3"), ("deviceId", "future-device-id-0001")]),
            role: .control
        )) { error in
            XCTAssertEqual(
                error as? BonjourInteropProtocolContract.AdvertisementError,
                .unsupportedVersion("3")
            )
        }
        XCTAssertThrowsError(try BonjourInteropProtocolContract.decodeAdvertisement(
            Data([12, 0x76, 0x65]),
            role: .control
        )) { error in
            XCTAssertEqual(
                error as? BonjourInteropProtocolContract.AdvertisementError,
                .truncatedField
            )
        }
    }

    func testLegacyRuntimeProjectionRejectsMutableTXTAuthority() throws {
        let decoded = try BonjourInteropProtocolContract.decodeAdvertisement(
            encodeTXT([
                ("version", "1"),
                ("deviceId", "legacy-device-id-0002"),
                ("pubKeyFP", String(repeating: "b", count: 64)),
                ("platform", "ios"),
                ("hs_soa", "1"),
                ("name", "spoofed-name"),
                ("capabilities", "file_transfer,remote_control,classic_resume"),
                ("port", "65535"),
                ("rssi", "0")
            ]),
            role: .control
        )

        XCTAssertEqual(
            decoded.discoveryProjection,
            BonjourInteropProtocolContract.DiscoveryProjection(
                generation: .legacy,
                deviceId: "legacy-device-id-0002",
                protocolPublicKeyFingerprint: String(repeating: "b", count: 64),
                platform: .iOS,
                advertisesStrongOwnerAuthentication: false
            )
        )
    }

    func testDefaultDiscoveryServiceTypesIncludeDedicatedTransferAndRemoteServices() {
        XCTAssertEqual(
            BonjourInteropContract.defaultDiscoveryServiceTypes,
            [
                BonjourInteropContract.controlServiceType,
                BonjourInteropContract.fileTransferServiceType,
                BonjourInteropContract.remoteControlServiceType
            ]
        )
    }

    func testSharedInteropValidatorsStayFailClosed() {
        XCTAssertEqual(
            BonjourInteropContract.normalizedPubKeyFingerprint(String(repeating: "a", count: 64)),
            String(repeating: "a", count: 64)
        )
        XCTAssertNil(BonjourInteropContract.normalizedPubKeyFingerprint(String(repeating: "a", count: 63)))
        XCTAssertNil(BonjourInteropContract.normalizedPubKeyFingerprint(String(repeating: "A", count: 64)))
        XCTAssertNil(BonjourInteropContract.normalizedPubKeyFingerprint("abc123"))

        XCTAssertEqual(
            BonjourInteropContract.normalizedRemoteVideoFormats(["HEVC", "vp9", "h264", "jpeg", "h264"]),
            ["hevc", "h264", "jpeg"]
        )
    }

    func testIOSBonjourWritersUseCanonicalVersion2Contract() throws {
        let fileTransferSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift"
        )
        let discoverySource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )
        let plistSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist"
        )

        XCTAssertTrue(fileTransferSource.contains("BonjourInteropProtocolContract.canonicalAdvertisementWireData("))
        XCTAssertFalse(fileTransferSource.contains("NetService.data(fromTXTRecord:"))
        XCTAssertFalse(fileTransferSource.contains("fields.mapValues"))
        XCTAssertFalse(fileTransferSource.contains("\"transferPort\": Data("))
        XCTAssertFalse(fileTransferSource.contains("\"fileTransferPort\": Data("))
        XCTAssertFalse(fileTransferSource.contains("\"capabilities\": Data("))
        XCTAssertTrue(discoverySource.contains("BonjourInteropProtocolContract.canonicalAdvertisementWireData("))
        XCTAssertTrue(discoverySource.contains("return NWTXTRecord(wireData)"))
        XCTAssertTrue(discoverySource.contains("let advertisedCaps: [String] = []"))
        XCTAssertFalse(discoverySource.contains("decodeAdvertisement(\n                    txtRecord.data,\n                    role: role\n                ).fields"))
        XCTAssertFalse(discoverySource.contains("parseCapabilities(from: txtRecord)"))
        XCTAssertFalse(discoverySource.contains("record[\"controlPort\"]"))
        XCTAssertFalse(discoverySource.contains("record[\"vendorDeviceId\"]"))
        XCTAssertTrue(
            discoverySource.contains(
                "return BonjourInteropProtocolContract.remoteControlServiceType"
            )
        )
        XCTAssertFalse(
            discoverySource.contains("case skybridgeRemote = \"_skybridge-rd._tcp\"")
        )
        XCTAssertTrue(discoverySource.contains("return [\"file\", \"file_transfer\"]"))
        XCTAssertTrue(
            discoverySource.contains("return [\"screen_sharing\", \"remote_desktop\", \"rdview\", \"remote_control\", \"rdcontrol\"]")
        )
        XCTAssertTrue(plistSource.contains("<string>_skybridge-xfer._tcp</string>"))
        XCTAssertTrue(plistSource.contains("<string>_skybridge-rd._tcp</string>"))
        XCTAssertFalse(plistSource.contains("<string>_skybridge-transfer._tcp</string>"))
        XCTAssertFalse(plistSource.contains("<string>_skybridge-remote._tcp</string>"))
    }

    func testMajorVersionRemovesParallelLegacyBonjourWriters() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let removedSources = [
            "Sources/SkyBridgeCore/Discovery/BonjourServiceEnhanced.swift",
            "Sources/SkyBridgeCore/P2P/P2PDeviceDiscovery.swift"
        ]
        for relativePath in removedSources {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(relativePath).path
                ),
                "Legacy Bonjour writer must remain removed: \(relativePath)"
            )
        }

        let addressProvider = try? String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/DeviceDiscovery/LocalNetworkAdvertisementAddressProvider.swift"
            ),
            encoding: .utf8
        )
        XCTAssertNotNil(addressProvider)
        XCTAssertFalse(addressProvider?.contains("attachAddressTXT") == true)
        XCTAssertTrue(addressProvider?.contains("routableLANAddresses()") == true)
    }

    func testVersion2ServiceTypesRespectDNSServiceLabelLimit() {
        for serviceType in BonjourInteropProtocolContract.defaultDiscoveryServiceTypes {
            XCTAssertTrue(
                BonjourInteropProtocolContract.isValidDNSServiceType(serviceType),
                "Invalid version-2 DNS-SD service type: \(serviceType)"
            )
        }
        XCTAssertFalse(
            BonjourInteropProtocolContract.isValidDNSServiceType(
                BonjourInteropProtocolContract.legacyFileTransferServiceType
            )
        )
        XCTAssertFalse(
            BonjourInteropProtocolContract.isValidDNSServiceType(
                BonjourInteropProtocolContract.legacyRemoteControlServiceType
            )
        )
        XCTAssertFalse(BonjourInteropProtocolContract.isValidDNSServiceType("_-bad._tcp"))
        XCTAssertFalse(BonjourInteropProtocolContract.isValidDNSServiceType("_bad-._tcp"))
        XCTAssertFalse(BonjourInteropProtocolContract.isValidDNSServiceType("_1234._tcp"))
    }

    func testDiscoverySourcesUseSharedStrictFingerprintValidator() throws {
        let sources = [
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift",
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift",
            "Sources/SkyBridgeCore/DeviceDiscovery/UnifiedOnlineDeviceManager.swift",
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
        ]

        for path in sources {
            let source = try repositorySource(path)
            XCTAssertFalse(source.contains("^[0-9a-f]{16,128}$"), "\(path) must not accept truncated TXT fingerprints.")
            if path.hasSuffix("DeviceDiscoveryManager.swift") {
                XCTAssertTrue(source.contains("BonjourInteropContract.decodeAdvertisement("))
                XCTAssertTrue(source.contains(".discoveryProjection"))
            } else {
                XCTAssertTrue(
                    source.contains("BonjourInteropContract.normalizedPubKeyFingerprint"),
                    "\(path) must use the shared strict TXT fingerprint validator."
                )
            }
        }
    }

    func testMachineReadableBonjourInteropContractMatchesProtocolCore() throws {
        let contract = try jsonObject("Docs/bonjour_interop_contract.json")
        XCTAssertEqual(contract["schemaVersion"] as? Int, 2)
        let serviceTypes = try dictionary(contract["serviceTypes"], "serviceTypes")
        XCTAssertEqual(serviceTypes["legacyQuicPrimary"] as? String, BonjourInteropProtocolContract.legacyQuicPrimaryServiceType)
        XCTAssertEqual(serviceTypes["control"] as? String, BonjourInteropProtocolContract.controlServiceType)
        XCTAssertEqual(serviceTypes["fileTransfer"] as? String, BonjourInteropProtocolContract.fileTransferServiceType)
        XCTAssertEqual(serviceTypes["remoteControl"] as? String, BonjourInteropProtocolContract.remoteControlServiceType)
        XCTAssertEqual(serviceTypes["companionLink"] as? String, BonjourInteropProtocolContract.companionLinkServiceType)

        let discovery = try dictionary(contract["discovery"], "discovery")
        XCTAssertEqual(
            try stringArray(discovery["appleDefaultServiceTypes"], "appleDefaultServiceTypes"),
            BonjourInteropProtocolContract.defaultDiscoveryServiceTypes
        )
        XCTAssertEqual(
            try stringArray(discovery["windowsCompatibilityQueryOrder"], "windowsCompatibilityQueryOrder"),
            BonjourInteropProtocolContract.windowsCompatibilityDiscoveryServiceTypes
        )

        let capabilities = try dictionary(contract["capabilities"], "capabilities")
        XCTAssertEqual(try stringArray(capabilities["base"], "base"), BonjourInteropProtocolContract.basePrimaryCapabilities)
        XCTAssertEqual(
            try stringArray(capabilities["fileTransfer"], "fileTransfer"),
            BonjourInteropProtocolContract.fileTransferCapabilities
        )
        XCTAssertEqual(
            try stringArray(capabilities["remoteControl"], "remoteControl"),
            BonjourInteropProtocolContract.remoteControlCapabilities
        )

        let txt = try dictionary(contract["txt"], "txt")
        XCTAssertEqual(txt["advertisementVersion"] as? String, BonjourInteropProtocolContract.advertisementVersion)
        XCTAssertEqual(
            txt["maximumWireBytes"] as? Int,
            BonjourInteropProtocolContract.maximumRecommendedTXTRecordWireBytes
        )
        XCTAssertEqual(
            try stringArray(txt["canonicalEmittedFields"], "canonicalEmittedFields"),
            Array(BonjourInteropProtocolContract.canonicalAdvertisementTXTKeys.dropLast())
        )
        XCTAssertEqual(
            try stringArray(txt["controlAdditionalEmittedFields"], "controlAdditionalEmittedFields"),
            ["hs_soa"]
        )
        XCTAssertEqual(
            try stringArray(txt["acceptedLegacyDeviceIdentityKeys"], "acceptedLegacyDeviceIdentityKeys"),
            BonjourInteropProtocolContract.deviceIdentityTXTKeys
        )
        XCTAssertEqual(
            try stringArray(txt["acceptedLegacyPubKeyFingerprintKeys"], "acceptedLegacyPubKeyFingerprintKeys"),
            BonjourInteropProtocolContract.pubKeyFingerprintTXTKeys
        )
        XCTAssertEqual(txt["pubKeyFingerprintPattern"] as? String, BonjourInteropProtocolContract.pubKeyFingerprintPattern)
        XCTAssertEqual(
            try stringArray(txt["acceptedLegacyFileTransferPortKeys"], "acceptedLegacyFileTransferPortKeys"),
            BonjourInteropProtocolContract.fileTransferPortTXTKeys
        )
        XCTAssertEqual(
            try stringArray(txt["acceptedLegacyRemoteControlPortKeys"], "acceptedLegacyRemoteControlPortKeys"),
            BonjourInteropProtocolContract.remoteControlPortTXTKeys
        )
        XCTAssertEqual(
            try stringArray(txt["acceptedLegacyRemoteVideoFormatKeys"], "acceptedLegacyRemoteVideoFormatKeys"),
            BonjourInteropProtocolContract.remoteVideoFormatTXTKeys
        )

        let remoteVideoFormats = try dictionary(contract["remoteVideoFormats"], "remoteVideoFormats")
        XCTAssertEqual(
            try stringArray(remoteVideoFormats["allowedTokens"], "allowedTokens"),
            BonjourInteropProtocolContract.supportedRemoteVideoFormatTokens
        )

        let routeProvenance = try dictionary(contract["routeProvenance"], "routeProvenance")
        XCTAssertEqual(routeProvenance["txtPortsAreDiagnosticOnly"] as? Bool, true)
        XCTAssertEqual(routeProvenance["actionableRoutesRequireResolvedDnsSdEndpoint"] as? Bool, true)
        XCTAssertEqual(routeProvenance["capabilitiesDoNotCreateRoutes"] as? Bool, true)
        XCTAssertEqual(routeProvenance["pubKeyFingerprintIsTrustHintOnly"] as? Bool, true)
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func jsonObject(_ relativePath: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ContractJSONError.invalidShape("Expected JSON object at \(relativePath).")
        }
        return dictionary
    }

    private func dictionary(_ value: Any?, _ name: String) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw ContractJSONError.invalidShape("Expected JSON dictionary for \(name).")
        }
        return dictionary
    }

    private func stringArray(_ value: Any?, _ name: String) throws -> [String] {
        guard let array = value as? [String] else {
            throw ContractJSONError.invalidShape("Expected JSON string array for \(name).")
        }
        return array
    }

    private enum ContractJSONError: Error {
        case invalidShape(String)
    }

    private func encodeTXT(_ entries: [(String, String)]) -> Data {
        var data = Data()
        for (key, value) in entries {
            let entry = Data("\(key)=\(value)".utf8)
            precondition(entry.count <= Int(UInt8.max))
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }

}
