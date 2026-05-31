import XCTest
@testable import SkyBridgeCore

@MainActor
final class USBInterfaceDescriptorTests: XCTestCase {
    func testParseInterfaceClassFromDescriptor() throws {
 // 中文注释：构造一个简单的配置描述符，包含一个接口描述符（bInterfaceClass = 1 音频）
 // 结构：length(9), type(4), ifaceNumber, altSetting, numEndpoints, class(1), subclass(1), protocol(0), iInterface
        let iface: [UInt8] = [9, 4, 0, 0, 0, 1, 1, 0, 0]
        let cfg = Data(iface)
        let cls = USBCConnectionManager.parseInterfaceClass(from: cfg)
        XCTAssertEqual(cls, 1)
    }

    func testExternalAccessoryGateIsClosedUnderUnitTests() {
        XCTAssertFalse(USBCConnectionManager.canUseExternalAccessory)
    }

    func testGenericDiscoveryDoesNotTriggerMFiScan() throws {
        let source = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift")
        XCTAssertFalse(source.contains("scanForMFiDevices()"))
    }

    func testUSBManagementRefreshDoesNotTriggerMFiScan() throws {
        let source = try readSource("Sources/SkyBridgeCompassApp/Views/USBDeviceManagementView.swift")
        XCTAssertFalse(source.contains("scanForMFiDevices()"))
    }

    func testExternalAccessoryManagerIsLazyOnly() throws {
        let source = try readSource("Sources/SkyBridgeCore/Connection/USBCConnectionManager.swift")
        let occurrences = source.components(separatedBy: "EAAccessoryManager.shared()").count - 1
        XCTAssertEqual(occurrences, 1)
        XCTAssertTrue(source.contains("private func ensureAccessoryManager() -> EAAccessoryManager?"))
    }

    func testUSBCManagerInitializerDoesNotImplicitlyScanUSB() throws {
        let source = try readSource("Sources/SkyBridgeCore/Connection/USBCConnectionManager.swift")
        let initializer = try extractBody(
            named: "public init()",
            from: source
        )
        XCTAssertFalse(
            initializer.contains("scanForUSBDevices"),
            "USBCConnectionManager construction must stay cheap; USB enumeration is only allowed from explicit scan call sites."
        )
        XCTAssertTrue(
            source.contains("connectionQueue.async {\n                let snapshot = Self.enumerateUSBDevicesSnapshot()"),
            "USB enumeration should run on the dedicated USB queue and publish results back to MainActor only after enumeration completes."
        )
    }

    func testUSBDiscoveryMonitoringOwnsExactlyOneInitialScan() throws {
        let usbSource = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/USBDeviceDiscoveryManager.swift")
        let startBody = try extractBody(named: "public func start() async", from: usbSource)
        let startMonitoringBody = try extractBody(named: "public func startMonitoring()", from: usbSource)

        XCTAssertFalse(
            startBody.contains("scanUSBDevices"),
            "USBDeviceDiscoveryManager.start() must not stack an explicit scan on top of startMonitoring()'s initial scan."
        )
        XCTAssertTrue(
            startMonitoringBody.contains("guard notificationPort == nil"),
            "USB monitoring should be idempotent so repeated discovery starts cannot install duplicate IOKit notifications."
        )
        XCTAssertEqual(
            startMonitoringBody.components(separatedBy: "scanUSBDevices()").count - 1,
            1,
            "startMonitoring() should own a single initial scan after notification registration."
        )

        let unifiedOnlineSource = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/UnifiedOnlineDeviceManager.swift")
        let unifiedStart = try extractBody(named: "public func startDiscovery()", from: unifiedOnlineSource)
        XCTAssertFalse(
            unifiedStart.contains("usbDiscovery.scanUSBDevices()"),
            "UnifiedOnlineDeviceManager.startDiscovery() should delegate the initial USB scan to startMonitoring()."
        )

        let unifiedDiscoverySource = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/UnifiedDeviceDiscoveryManager.swift")
        XCTAssertFalse(
            unifiedDiscoverySource.contains("self?.usbDiscovery.scanUSBDevices()"),
            "Legacy unified discovery integration should not double-trigger USB initial scans."
        )
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func extractBody(named signature: String, from source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw XCTSkip("Signature not found: \(signature)")
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...index])
                }
            }
            index = source.index(after: index)
        }

        throw XCTSkip("Unbalanced body for signature: \(signature)")
    }
}
