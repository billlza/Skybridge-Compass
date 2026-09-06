import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class LocalDevicePresenceReportBuilderTests: XCTestCase {
    private func presentation(name: String?, model: String? = "Mac") -> LocalDevicePresentation.Snapshot {
        LocalDevicePresentation.Snapshot(deviceName: name, modelName: model, platformName: "macOS", osVersion: "Version 26.6")
    }

    func testBuildsAMacReportFromTheSharedLocalSources() throws {
        let report = try LocalDevicePresenceReportBuilder.makeReport(
            presentation: presentation(name: "  Studio Mac  "),
            hardwareModel: "Mac16,7",
            lanAddresses: ["fd12::1", "169.254.1.1", "10.0.0.5", "127.0.0.1", "10.0.0.5"],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 1)
        )
        XCTAssertEqual(report.deviceName, "Studio Mac")
        XCTAssertEqual(report.platform, .macOS)
        XCTAssertEqual(report.deviceModel, "Mac16,7")
        XCTAssertEqual(report.osVersion, "26.6.1")
        XCTAssertEqual(report.lanAddresses, ["fd12::1", "10.0.0.5"], "provider order is the interface preference and must survive")
        XCTAssertEqual(report.capabilities, ["clipboard", "file_transfer", "remote_desktop"])
    }

    func testFallsBackToHardwareModelThenPlatformModelWhenTheHostHasNoName() throws {
        let fromHardware = try LocalDevicePresenceReportBuilder.makeReport(
            presentation: presentation(name: nil),
            hardwareModel: "Mac16,7",
            lanAddresses: [],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertEqual(fromHardware.deviceName, "Mac16,7")

        let fromPresentation = try LocalDevicePresenceReportBuilder.makeReport(
            presentation: presentation(name: " ", model: "Mac"),
            hardwareModel: nil,
            lanAddresses: [],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertEqual(fromPresentation.deviceName, "Mac")
        XCTAssertEqual(fromPresentation.deviceModel, "Mac")
        XCTAssertEqual(fromPresentation.lanAddresses, [])
    }

    func testCapsLANAddressesAtTheContractLimit() throws {
        let addresses = (1...12).map { "10.0.0.\($0)" }
        let report = try LocalDevicePresenceReportBuilder.makeReport(
            presentation: presentation(name: "Mac"),
            hardwareModel: nil,
            lanAddresses: addresses,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertEqual(report.lanAddresses.count, AccountDevicePresenceReport.maximumLANAddresses)
    }

    func testBuilderReusesExistingHelpersInsteadOfNewSystemCalls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/LocalDevicePresenceReportBuilder.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("getifaddrs"))
        XCTAssertFalse(source.contains("sysctlbyname"))
        XCTAssertTrue(source.contains("LocalNetworkAdvertisementAddressProvider.routableLANAddresses()"))
        XCTAssertTrue(source.contains("HardwareModelIdentifier.current()"))
        XCTAssertTrue(source.contains("LocalDevicePresentation.current()"))

        for path in [
            "Sources/SkyBridgeCore/Utilities/SelfIdentityProvider.swift",
            "Sources/SkyBridgeCore/iCloud/iCloudDeviceDiscoveryManager.swift",
            "Sources/SkyBridgeCore/Services/CloudKitService.swift"
        ] {
            let dedupedSource = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(dedupedSource.contains("sysctlbyname(\"hw.model\""), "\(path) must use HardwareModelIdentifier")
            XCTAssertTrue(dedupedSource.contains("HardwareModelIdentifier.current()"), "\(path) must use HardwareModelIdentifier")
        }

        let lanProvider = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/DeviceDiscovery/LocalNetworkAdvertisementAddressProvider.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(lanProvider.contains("LANAddressRoutabilityPolicy.isAdvertisableRoutableLANAddress(raw)"))
        XCTAssertFalse(lanProvider.contains("hasPrefix(\"fe80:\")"), "the literal rule lives in the shared policy only")
    }

    func testHardwareModelIdentifierReturnsARealModelOnThisHost() {
        let model = HardwareModelIdentifier.current()
        XCTAssertNotNil(model)
        XCTAssertTrue(model?.contains(",") == true || model?.lowercased().contains("mac") == true)
    }
}
