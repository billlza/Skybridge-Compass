// MARK: - Round Trip Property Tests
// **Feature: macos-widgets, Property 1: Serialization Round Trip (语义等价)**
// **Validates: Requirements 5.1, 5.2, 5.5**

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Round Trip Property Tests")
struct RoundTripPropertyTests {
    
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    
 // MARK: - Property 1: Serialization Round Trip
    
    @Test("WidgetDevicesData round-trip preserves semantic equality", arguments: 0..<100)
    func testDevicesDataRoundTrip(iteration: Int) throws {
 // Generate random data
        let original = WidgetTestGenerators.devicesData(deviceCount: Int.random(in: 0...20))
        
 // Encode to JSON
        let jsonData = try encoder.encode(original)
        
 // Decode back
        let decoded = try decoder.decode(WidgetDevicesData.self, from: jsonData)
        
 // Verify semantic equality
        #expect(decoded.semanticEquals(original), """
            Round-trip failed for WidgetDevicesData:
            Original: \(original.prettyDescription)
            Decoded: \(decoded.prettyDescription)
            """)
    }
    
    @Test("WidgetMetricsData round-trip preserves semantic equality", arguments: 0..<100)
    func testMetricsDataRoundTrip(iteration: Int) throws {
        let original = WidgetTestGenerators.metricsData()
        
        let jsonData = try encoder.encode(original)
        let decoded = try decoder.decode(WidgetMetricsData.self, from: jsonData)
        
        #expect(decoded.semanticEquals(original), """
            Round-trip failed for WidgetMetricsData:
            Original: \(original.prettyDescription)
            Decoded: \(decoded.prettyDescription)
            """)
    }
    
    @Test("WidgetTransfersData round-trip preserves semantic equality", arguments: 0..<100)
    func testTransfersDataRoundTrip(iteration: Int) throws {
        let original = WidgetTestGenerators.transfersData(transferCount: Int.random(in: 0...10))
        
        let jsonData = try encoder.encode(original)
        let decoded = try decoder.decode(WidgetTransfersData.self, from: jsonData)
        
        #expect(decoded.semanticEquals(original), """
            Round-trip failed for WidgetTransfersData:
            Original: \(original.prettyDescription)
            Decoded: \(decoded.prettyDescription)
            """)
    }
    
    @Test("WidgetDeviceInfo round-trip preserves semantic equality", arguments: 0..<100)
    func testDeviceInfoRoundTrip(iteration: Int) throws {
        let original = WidgetTestGenerators.deviceInfo()
        
        let jsonData = try encoder.encode(original)
        let decoded = try decoder.decode(WidgetDeviceInfo.self, from: jsonData)
        
        #expect(decoded.semanticEquals(original))
    }
    
    @Test("WidgetSystemMetrics round-trip preserves semantic equality", arguments: 0..<100)
    func testSystemMetricsRoundTrip(iteration: Int) throws {
        let original = WidgetTestGenerators.systemMetrics()
        
        let jsonData = try encoder.encode(original)
        let decoded = try decoder.decode(WidgetSystemMetrics.self, from: jsonData)
        
        #expect(decoded.semanticEquals(original))
    }
    
    @Test("WidgetTransferInfo round-trip preserves semantic equality", arguments: 0..<100)
    func testTransferInfoRoundTrip(iteration: Int) throws {
        let original = WidgetTestGenerators.transferInfo()
        
        let jsonData = try encoder.encode(original)
        let decoded = try decoder.decode(WidgetTransferInfo.self, from: jsonData)
        
        #expect(decoded.semanticEquals(original))
    }
    
 // MARK: - Edge Cases
    
    @Test("Empty devices data round-trip")
    func testEmptyDevicesDataRoundTrip() throws {
        let original = WidgetDevicesData.empty
        
        let jsonData = try encoder.encode(original)
        let decoded = try decoder.decode(WidgetDevicesData.self, from: jsonData)
        
        #expect(decoded.semanticEquals(original))
    }
    
    @Test("Empty transfers data round-trip")
    func testEmptyTransfersDataRoundTrip() throws {
        let original = WidgetTransfersData.empty
        
        let jsonData = try encoder.encode(original)
        let decoded = try decoder.decode(WidgetTransfersData.self, from: jsonData)
        
        #expect(decoded.semanticEquals(original))
    }
    
    @Test("Data with truncation info round-trip")
    func testTruncationInfoRoundTrip() throws {
        let original = WidgetDevicesData(
            devices: WidgetTestGenerators.devices(count: 5),
            truncationInfo: TruncationInfo(devicesOmitted: 10, transfersOmitted: 0)
        )
        
        let jsonData = try encoder.encode(original)
        let decoded = try decoder.decode(WidgetDevicesData.self, from: jsonData)
        
        #expect(decoded.semanticEquals(original))
        #expect(decoded.truncationInfo?.devicesOmitted == 10)
    }
}
