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
}