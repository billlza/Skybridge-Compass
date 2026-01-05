// MARK: - Pretty Printer Property Tests
// **Feature: macos-widgets, Property 7: Pretty Printer Output**
// **Validates: Requirements 5.6**

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Pretty Printer Property Tests")
struct PrettyPrinterPropertyTests {
    
 // MARK: - Property 7: Pretty Printer Output
    
    @Test("WidgetDevicesData prettyDescription contains all device names", arguments: 0..<50)
    func testDevicesDataPrettyPrinter(iteration: Int) throws {
        let deviceCount = Int.random(in: 1...10)
        let data = WidgetTestGenerators.devicesData(deviceCount: deviceCount)
        
        let output = data.prettyDescription
        
 // Verify all device names are present
        for device in data.devices {
            #expect(output.contains(device.name), """
                Pretty printer output missing device name '\(device.name)'
                Output: \(output)
                """)
        }
        
 // Verify device count is present
        #expect(output.contains("\(data.devices.count)"))
        
 // Verify online count is present
        #expect(output.contains("\(data.onlineCount)"))
    }
    
    @Test("WidgetMetricsData prettyDescription contains metric values", arguments: 0..<50)
    func testMetricsDataPrettyPrinter(iteration: Int) throws {
        let data = WidgetTestGenerators.metricsData()
        
        let output = data.prettyDescription
        
 // Verify CPU percentage is present (formatted to 1 decimal)
        let cpuFormatted = String(format: "%.1f", data.metrics.cpuUsage)
        #expect(output.contains(cpuFormatted), """
            Pretty printer output missing CPU value '\(cpuFormatted)'
            Output: \(output)
            """)
        
 // Verify Memory percentage is present
        let memFormatted = String(format: "%.1f", data.metrics.memoryUsage)
        #expect(output.contains(memFormatted), """
            Pretty printer output missing Memory value '\(memFormatted)'
            Output: \(output)
            """)
    }
    
    @Test("WidgetTransfersData prettyDescription contains all file names", arguments: 0..<50)
    func testTransfersDataPrettyPrinter(iteration: Int) throws {
        let transferCount = Int.random(in: 1...5)
        let data = WidgetTestGenerators.transfersData(transferCount: transferCount)
        
        let output = data.prettyDescription
        
 // Verify all file names are present
        for transfer in data.transfers {
            #expect(output.contains(transfer.fileName), """
                Pretty printer output missing file name '\(transfer.fileName)'
                Output: \(output)
                """)
        }
        
 // Verify transfer count is present
        #expect(output.contains("\(data.transfers.count)"))
        
 // Verify active count is present
        #expect(output.contains("\(data.activeCount)"))
    }
    
 // MARK: - Empty State Tests
    
    @Test("Empty devices data prettyDescription handles gracefully")
    func testEmptyDevicesPrettyPrinter() {
        let data = WidgetDevicesData.empty
        let output = data.prettyDescription
        
        #expect(output.contains("0") || output.contains("none"))
        #expect(!output.isEmpty)
    }
    
    @Test("Empty transfers data prettyDescription handles gracefully")
    func testEmptyTransfersPrettyPrinter() {
        let data = WidgetTransfersData.empty
        let output = data.prettyDescription
        
        #expect(output.contains("0") || output.contains("none"))
        #expect(!output.isEmpty)
    }
    
 // MARK: - Truncation Info Tests
    
    @Test("Truncation info appears in prettyDescription")
    func testTruncationInfoInPrettyPrinter() {
        let data = WidgetDevicesData(
            devices: WidgetTestGenerators.devices(count: 3),
            truncationInfo: TruncationInfo(devicesOmitted: 47, transfersOmitted: 0)
        )
        
        let output = data.prettyDescription
        
        #expect(output.contains("47") || output.contains("omitted"), """
            Pretty printer should indicate truncation
            Output: \(output)
            """)
    }
    
 // MARK: - Sanitized Description Tests
    
    @Test("Sanitized description is shorter than pretty description")
    func testSanitizedDescriptionIsShorter() {
        let data = WidgetTestGenerators.devicesData(deviceCount: 10)
        
        let pretty = data.prettyDescription
        let sanitized = data.sanitizedDescription
        
        #expect(sanitized.count < pretty.count, """
            Sanitized description should be shorter
            Pretty: \(pretty.count) chars
            Sanitized: \(sanitized.count) chars
            """)
    }
    
    @Test("Sanitized description does not contain IP addresses")
    func testSanitizedDescriptionNoIP() {
 // Create device with known IP
        let device = WidgetDeviceInfo(
            id: "test",
            name: "Test Device",
            deviceType: .mac,
            isOnline: true,
            lastSeen: Date(),
            ipAddress: "192.168.1.100"
        )
        let data = WidgetDevicesData(devices: [device])
        
        let sanitized = data.sanitizedDescription
        
        #expect(!sanitized.contains("192.168"), """
            Sanitized description should not contain IP address
            Output: \(sanitized)
            """)
    }
}
