// MARK: - Widget Shared Models Tests
// Property-based tests for widget data models
// Requirements: 5.1, 5.2, 5.5

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Widget Shared Models Tests")
struct WidgetSharedModelsTests {
    
 // MARK: - Basic Encoding/Decoding Tests
    
    @Test("WidgetDeviceType decodes known values")
    func testDeviceTypeKnownValues() throws {
        for type in WidgetDeviceType.allCases {
            let json = "\"\(type.rawValue)\""
            let data = Data(json.utf8)
            let decoded = try JSONDecoder().decode(WidgetDeviceType.self, from: data)
            #expect(decoded == type)
        }
    }
    
    @Test("WidgetDeviceType decodes unknown value to .unknown")
    func testDeviceTypeUnknownValue() throws {
        let json = "\"some_future_device_type\""
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WidgetDeviceType.self, from: data)
        #expect(decoded == .unknown)
    }
    
    @Test("WidgetDeviceInfo round-trip encoding")
    func testDeviceInfoRoundTrip() throws {
        let device = WidgetDeviceInfo(
            id: "test-id",
            name: "Test Device",
            deviceType: .mac,
            isOnline: true,
            lastSeen: Date(),
            ipAddress: "192.168.1.100"
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let data = try encoder.encode(device)
        let decoded = try decoder.decode(WidgetDeviceInfo.self, from: data)
        
        #expect(decoded.id == device.id)
        #expect(decoded.name == device.name)
        #expect(decoded.deviceType == device.deviceType)
        #expect(decoded.isOnline == device.isOnline)
        #expect(decoded.ipAddress == device.ipAddress)
    }
    
    @Test("WidgetSystemMetrics clamps values")
    func testMetricsClamping() {
        let metrics = WidgetSystemMetrics(
            cpuUsage: 150,  // Should clamp to 100
            memoryUsage: -10,  // Should clamp to 0
            networkUpload: -100,  // Should clamp to 0
            networkDownload: 1000
        )
        
        #expect(metrics.cpuUsage == 100)
        #expect(metrics.memoryUsage == 0)
        #expect(metrics.networkUpload == 0)
        #expect(metrics.networkDownload == 1000)
    }
    
    @Test("WidgetTransferInfo clamps progress")
    func testTransferProgressClamping() {
        let transfer = WidgetTransferInfo(
            id: "t1",
            fileName: "test.txt",
            progress: 1.5,  // Should clamp to 1.0
            totalBytes: 1000,
            transferredBytes: 500,
            isUpload: true,
            deviceName: "Device"
        )
        
        #expect(transfer.progress == 1.0)
    }
    
    @Test("WidgetTransferInfo isActive property")
    func testTransferIsActive() {
        let active = WidgetTransferInfo(
            id: "t1", fileName: "a.txt", progress: 0.5,
            totalBytes: 100, transferredBytes: 50, isUpload: true, deviceName: "D"
        )
        let completed = WidgetTransferInfo(
            id: "t2", fileName: "b.txt", progress: 1.0,
            totalBytes: 100, transferredBytes: 100, isUpload: false, deviceName: "D"
        )
        
        #expect(active.isActive == true)
        #expect(completed.isActive == false)
    }
}
