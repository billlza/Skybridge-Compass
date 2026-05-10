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

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
