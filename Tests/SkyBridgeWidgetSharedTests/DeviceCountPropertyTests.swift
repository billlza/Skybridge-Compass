// MARK: - Device Count Property Tests
// **Feature: macos-widgets, Property 2: Device Count Accuracy**
// **Validates: Requirements 1.2**

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Device Count Property Tests")
struct DeviceCountPropertyTests {
    
 // MARK: - Property 2: Device Count Accuracy
    
    @Test("onlineCount equals count of devices where isOnline == true", arguments: 0..<100)
    func testOnlineCountAccuracy(iteration: Int) {
        let deviceCount = Int.random(in: 0...50)
        let devices = (0..<deviceCount).map { _ in WidgetTestGenerators.deviceInfo() }
        let data = WidgetDevicesData(devices: devices)
        
        let expectedOnlineCount = devices.filter { $0.isOnline }.count
        
        #expect(data.onlineCount == expectedOnlineCount, """
            Online count mismatch:
            Expected: \(expectedOnlineCount)
            Actual: \(data.onlineCount)
            Total devices: \(deviceCount)
            """)
    }
    
    @Test("onlineCount is zero for empty device list")
    func testOnlineCountEmpty() {
        let data = WidgetDevicesData.empty
        #expect(data.onlineCount == 0)
    }
    
    @Test("onlineCount equals total when all devices online")
    func testOnlineCountAllOnline() {
        let devices = (0..<10).map { i in
            WidgetDeviceInfo(
                id: "device-\(i)",
                name: "Device \(i)",
                deviceType: .mac,
                isOnline: true,
                lastSeen: Date(),
                ipAddress: nil
            )
        }
        let data = WidgetDevicesData(devices: devices)
        
        #expect(data.onlineCount == 10)
    }
    
    @Test("onlineCount is zero when all devices offline")
    func testOnlineCountAllOffline() {
        let devices = (0..<10).map { i in
            WidgetDeviceInfo(
                id: "device-\(i)",
                name: "Device \(i)",
                deviceType: .mac,
                isOnline: false,
                lastSeen: Date(),
                ipAddress: nil
            )
        }
        let data = WidgetDevicesData(devices: devices)
        
        #expect(data.onlineCount == 0)
    }
}
