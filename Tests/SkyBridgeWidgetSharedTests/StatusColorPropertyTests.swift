// MARK: - Status Color Property Tests
// **Feature: macos-widgets, Property 6: Status Color Mapping**
// **Validates: Requirements 7.5**

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Status Color Property Tests")
struct StatusColorPropertyTests {
    
 // MARK: - Property 6: Status Color Mapping
    
    @Test("Online status maps to green", arguments: 0..<50)
    func testOnlineStatusMapsToGreen(iteration: Int) {
        let device = WidgetDeviceInfo(
            id: WidgetTestGenerators.deviceId(),
            name: WidgetTestGenerators.deviceName(),
            deviceType: WidgetTestGenerators.deviceType(),
            isOnline: true,
            lastSeen: Date(),
            ipAddress: WidgetTestGenerators.ipAddress()
        )
        
        let color = StatusColorMapper.colorForDevice(device)
        
        #expect(color == .green, """
            Online device should map to green
            Device: \(device.name)
            isOnline: \(device.isOnline)
            Color: \(color)
            """)
    }
    
    @Test("Offline status maps to red", arguments: 0..<50)
    func testOfflineStatusMapsToRed(iteration: Int) {
        let device = WidgetDeviceInfo(
            id: WidgetTestGenerators.deviceId(),
            name: WidgetTestGenerators.deviceName(),
            deviceType: WidgetTestGenerators.deviceType(),
            isOnline: false,
            lastSeen: Date(),
            ipAddress: WidgetTestGenerators.ipAddress()
        )
        
        let color = StatusColorMapper.colorForDevice(device)
        
        #expect(color == .red, """
            Offline device should map to red
            Device: \(device.name)
            isOnline: \(device.isOnline)
            Color: \(color)
            """)
    }
    
    @Test("colorForOnlineStatus is consistent with colorForDevice", arguments: 0..<100)
    func testColorConsistency(iteration: Int) {
        let isOnline = Bool.random()
        let device = WidgetDeviceInfo(
            id: "test",
            name: "Test",
            deviceType: .mac,
            isOnline: isOnline,
            lastSeen: Date(),
            ipAddress: nil
        )
        
        let colorFromStatus = StatusColorMapper.colorForOnlineStatus(isOnline)
        let colorFromDevice = StatusColorMapper.colorForDevice(device)
        
        #expect(colorFromStatus == colorFromDevice)
    }
    
    @Test("Stale data maps to yellow")
    func testStaleDataMapsToYellow() {
        let color = StatusColorMapper.colorForStaleness(true)
        #expect(color == .yellow)
    }
    
    @Test("Fresh data maps to green")
    func testFreshDataMapsToGreen() {
        let color = StatusColorMapper.colorForStaleness(false)
        #expect(color == .green)
    }
    
 // MARK: - Exhaustive Tests
    
    @Test("All boolean combinations produce valid colors")
    func testAllBooleanCombinations() {
        let onlineColors = [true, false].map { StatusColorMapper.colorForOnlineStatus($0) }
        let staleColors = [true, false].map { StatusColorMapper.colorForStaleness($0) }
        
 // All colors should be valid enum cases
        for color in onlineColors + staleColors {
            #expect([StatusColor.green, .red, .yellow, .gray].contains(color))
        }
    }
}
