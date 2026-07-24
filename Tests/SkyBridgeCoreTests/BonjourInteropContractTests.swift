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
        XCTAssertTrue(adapterSource.contains("private typealias Core = BonjourInteropProtocolContract"))
        XCTAssertTrue(adapterSource.contains("WebRTCRemoteDesktopVideoFormatPolicy.supportedRemoteVideoFormats()"))
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
            BonjourInteropProtocolContract.primaryCapabilitiesTXTValue(transferPort: 9443, remoteControlPort: 5901),
            BonjourInteropContract.primaryCapabilitiesTXTValue(transferPort: 9443, remoteControlPort: 5901)
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

    func testProtocolCoreBuildsPureTXTFieldsForAppleAdapter() {
        XCTAssertEqual(
            BonjourInteropProtocolContract.primaryAdvertisementFields(
                transferPort: 9443,
                remoteControlPort: 5901,
                remoteVideoFormats: ["HEVC", "vp9", "jpeg", "h264", "jpeg"]
            ),
            [
                "capabilities": "clipboard,clipboard_sync,file,file_transfer,classic_resume,screen_sharing,remote_desktop,rdview,remote_control,rdcontrol",
                "transferPort": "9443",
                "fileTransferPort": "9443",
                "file_transfer_port": "9443",
                "remotePort": "5901",
                "remoteControlPort": "5901",
                "remote_port": "5901",
                "remoteVideoFormats": "hevc,jpeg,h264",
                "remote_video_formats": "hevc,jpeg,h264",
                "remoteformats": "hevc,jpeg,h264",
                "remotevideoformats": "hevc,jpeg,h264",
                "remotevideformats": "hevc,jpeg,h264"
            ]
        )
        XCTAssertEqual(
            BonjourInteropProtocolContract.primaryAdvertisementFields(
                transferPort: nil,
                remoteControlPort: nil,
                remoteVideoFormats: ["hevc"]
            ),
            ["capabilities": "clipboard,clipboard_sync"]
        )
        XCTAssertEqual(
            BonjourInteropProtocolContract.fileTransferAdvertisementFields(port: 9443),
            [
                "capabilities": "file,file_transfer,classic_resume",
                "transferPort": "9443",
                "fileTransferPort": "9443",
                "file_transfer_port": "9443",
                "port": "9443"
            ]
        )
        XCTAssertEqual(
            BonjourInteropProtocolContract.remoteControlAdvertisementFields(
                port: 5901,
                remoteVideoFormats: ["vp9", "jpeg"]
            ),
            [
                "capabilities": "screen_sharing,remote_desktop,rdview,remote_control,rdcontrol",
                "remotePort": "5901",
                "remoteControlPort": "5901",
                "remote_port": "5901",
                "port": "5901",
                "remoteVideoFormats": "jpeg",
                "remote_video_formats": "jpeg",
                "remoteformats": "jpeg",
                "remotevideoformats": "jpeg",
                "remotevideformats": "jpeg"
            ]
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

    func testPrimaryAdvertisementCarriesCrossPlatformCapabilityAliasesAndPorts() throws {
        var record = NWTXTRecord()
        BonjourInteropContract.attachPrimaryAdvertisementTXT(
            to: &record,
            transferPort: 9443,
            remoteControlPort: 5901
        )

        let capabilities = Set((record["capabilities"] ?? "").split(separator: ",").map(String.init))
        XCTAssertTrue(capabilities.isSuperset(of: Set([
            "file",
            "file_transfer",
            "classic_resume",
            "screen_sharing",
            "rdview",
            "rdcontrol",
            "remote_control",
            "remote_desktop",
            "clipboard",
            "clipboard_sync"
        ])))
        XCTAssertEqual(record["transferPort"], "9443")
        XCTAssertEqual(record["fileTransferPort"], "9443")
        XCTAssertEqual(record["file_transfer_port"], "9443")
        XCTAssertEqual(record["remotePort"], "5901")
        XCTAssertEqual(record["remoteControlPort"], "5901")
        XCTAssertEqual(record["remote_port"], "5901")

        let remoteFormats = try XCTUnwrap(record["remoteVideoFormats"])
        XCTAssertTrue(remoteFormats.contains("jpeg"))
        XCTAssertTrue(remoteFormats.contains("h264"))
        for key in BonjourInteropContract.remoteVideoFormatTXTKeys {
            XCTAssertEqual(record[key], remoteFormats)
        }
    }

    func testPrimaryAdvertisementDoesNotInventEndpointPortsWhenServicesAreNotRegistered() {
        var record = NWTXTRecord()
        BonjourInteropContract.attachPrimaryAdvertisementTXT(
            to: &record,
            transferPort: nil,
            remoteControlPort: nil
        )

        XCTAssertEqual(record["capabilities"], BonjourInteropContract.basePrimaryCapabilitiesTXTValue)
        XCTAssertFalse(record["capabilities"]?.contains("file_transfer") ?? true)
        XCTAssertFalse(record["capabilities"]?.contains("remote_desktop") ?? true)
        XCTAssertNil(record["transferPort"])
        XCTAssertNil(record["fileTransferPort"])
        XCTAssertNil(record["file_transfer_port"])
        XCTAssertNil(record["remotePort"])
        XCTAssertNil(record["remoteControlPort"])
        XCTAssertNil(record["remote_port"])
        XCTAssertNil(record["remoteVideoFormats"])
    }

    func testPrimaryAdvertisementGatesCapabilityAliasesOnEndpointPorts() {
        var transferOnly = NWTXTRecord()
        BonjourInteropContract.attachPrimaryAdvertisementTXT(
            to: &transferOnly,
            transferPort: 9443,
            remoteControlPort: nil
        )
        XCTAssertTrue(transferOnly["capabilities"]?.contains("file_transfer") ?? false)
        XCTAssertTrue(transferOnly["capabilities"]?.contains("classic_resume") ?? false)
        XCTAssertFalse(transferOnly["capabilities"]?.contains("remote_desktop") ?? true)
        XCTAssertNil(transferOnly["remoteVideoFormats"])

        var remoteOnly = NWTXTRecord()
        BonjourInteropContract.attachPrimaryAdvertisementTXT(
            to: &remoteOnly,
            transferPort: nil,
            remoteControlPort: 5901
        )
        XCTAssertFalse(remoteOnly["capabilities"]?.contains("file_transfer") ?? true)
        XCTAssertTrue(remoteOnly["capabilities"]?.contains("remote_desktop") ?? false)
        XCTAssertNotNil(remoteOnly["remoteVideoFormats"])
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

    func testDedicatedServiceAdvertisementsUseNarrowCapabilities() {
        var transferRecord = NWTXTRecord()
        BonjourInteropContract.attachFileTransferAdvertisementTXT(to: &transferRecord, port: 9443)
        XCTAssertEqual(transferRecord["capabilities"], "file,file_transfer,classic_resume")
        XCTAssertEqual(transferRecord["transferPort"], "9443")
        XCTAssertEqual(transferRecord["fileTransferPort"], "9443")
        XCTAssertEqual(transferRecord["file_transfer_port"], "9443")
        XCTAssertEqual(transferRecord["port"], "9443")

        var remoteRecord = NWTXTRecord()
        BonjourInteropContract.attachRemoteControlAdvertisementTXT(to: &remoteRecord, port: 5901)
        XCTAssertEqual(
            remoteRecord["capabilities"],
            "screen_sharing,remote_desktop,rdview,remote_control,rdcontrol"
        )
        XCTAssertEqual(remoteRecord["remotePort"], "5901")
        XCTAssertEqual(remoteRecord["remoteControlPort"], "5901")
        XCTAssertEqual(remoteRecord["remote_port"], "5901")
        XCTAssertEqual(remoteRecord["port"], "5901")
        XCTAssertNil(remoteRecord["fileTransferPort"])
    }

    func testLegacyMacFileTransferNetworkServiceUsesInteropTXTBuilder() {
        let record = FileTransferNetworkService.makeBonjourTXTRecord(
            deviceName: "Mac Studio",
            port: 9443
        )

        XCTAssertEqual(txtString(record, "platform"), "macos")
        XCTAssertEqual(txtString(record, "device"), "Mac Studio")
        XCTAssertEqual(txtString(record, "name"), "Mac Studio")
        XCTAssertEqual(txtString(record, "capabilities"), "file,file_transfer,classic_resume")
        XCTAssertEqual(txtString(record, "transferPort"), "9443")
        XCTAssertEqual(txtString(record, "fileTransferPort"), "9443")
        XCTAssertEqual(txtString(record, "port"), "9443")
    }

    func testIOSBonjourSourcesStayAlignedWithInteropCapabilityAliases() throws {
        let fileTransferSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift"
        )
        let discoverySource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )
        let plistSource = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist"
        )

        XCTAssertTrue(
            fileTransferSource.contains("\"capabilities\": Data(\"file,file_transfer\".utf8)")
        )
        XCTAssertFalse(fileTransferSource.contains("ClassicTransferCapability.classicResume"))
        XCTAssertTrue(fileTransferSource.contains("\"transferPort\": Data(portString.utf8)"))
        XCTAssertTrue(fileTransferSource.contains("\"fileTransferPort\": Data(portString.utf8)"))
        XCTAssertTrue(fileTransferSource.contains("\"file_transfer_port\": Data(portString.utf8)"))
        XCTAssertTrue(
            discoverySource.contains("case skybridgeRemote = \"_skybridge-remote._tcp\"")
        )
        XCTAssertTrue(discoverySource.contains("return [\"file\", \"file_transfer\"]"))
        XCTAssertTrue(
            discoverySource.contains("return [\"screen_sharing\", \"remote_desktop\", \"rdview\", \"remote_control\", \"rdcontrol\"]")
        )
        XCTAssertTrue(plistSource.contains("<string>_skybridge-transfer._tcp</string>"))
        XCTAssertTrue(plistSource.contains("<string>_skybridge-remote._tcp</string>"))
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
            XCTAssertTrue(
                source.contains("BonjourInteropContract.normalizedPubKeyFingerprint"),
            "\(path) must use the shared strict TXT fingerprint validator."
            )
        }
    }

    func testMachineReadableBonjourInteropContractMatchesProtocolCore() throws {
        let contract = try jsonObject("Docs/bonjour_interop_contract.json")
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
        XCTAssertEqual(try stringArray(txt["deviceIdentityKeys"], "deviceIdentityKeys"), BonjourInteropProtocolContract.deviceIdentityTXTKeys)
        XCTAssertEqual(
            try stringArray(txt["pubKeyFingerprintKeys"], "pubKeyFingerprintKeys"),
            BonjourInteropProtocolContract.pubKeyFingerprintTXTKeys
        )
        XCTAssertEqual(txt["pubKeyFingerprintPattern"] as? String, BonjourInteropProtocolContract.pubKeyFingerprintPattern)
        XCTAssertEqual(
            try stringArray(txt["fileTransferPortKeys"], "fileTransferPortKeys"),
            BonjourInteropProtocolContract.fileTransferPortTXTKeys
        )
        XCTAssertEqual(
            try stringArray(txt["remoteControlPortKeys"], "remoteControlPortKeys"),
            BonjourInteropProtocolContract.remoteControlPortTXTKeys
        )
        XCTAssertEqual(
            try stringArray(txt["remoteVideoFormatKeys"], "remoteVideoFormatKeys"),
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

    private func txtString(_ record: [String: Data], _ key: String) -> String? {
        record[key].flatMap { String(data: $0, encoding: .utf8) }
    }
}
