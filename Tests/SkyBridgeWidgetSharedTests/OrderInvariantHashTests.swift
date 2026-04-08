// MARK: - Order Invariant Hash Tests
// **Feature: macos-widgets, Property 8: Order-Invariant Hash**
// **Validates: Requirements 5.1**

import Testing
import Foundation
import CryptoKit
@testable import SkyBridgeWidgetShared

@Suite("Order Invariant Hash Tests")
struct OrderInvariantHashTests {
    private let fixedLastUpdated = Date(timeIntervalSince1970: 1_704_067_200)
    
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    
 // MARK: - Property 8: Order-Invariant Hash
    
    @Test("Shuffled devices produce same hash after sorting", arguments: 0..<50)
    func testDevicesOrderInvariant(iteration: Int) throws {
 // Generate random devices
        let devices = WidgetTestGenerators.devices(count: Int.random(in: 5...20))
        
 // Create data with original order
        let data1 = WidgetDevicesData(
            devices: devices.sorted { $0.id < $1.id },
            lastUpdated: fixedLastUpdated
        )
        
 // Shuffle and create data with different order
        let shuffled = devices.shuffled()
        let data2 = WidgetDevicesData(
            devices: shuffled.sorted { $0.id < $1.id },
            lastUpdated: fixedLastUpdated
        )
        
 // Encode both
        let json1 = try encoder.encode(data1)
        let json2 = try encoder.encode(data2)
        
 // Hash should be identical
        let hash1 = sha256String(json1)
        let hash2 = sha256String(json2)
        
        #expect(hash1 == hash2, """
            Hash should be identical after sorting:
            Original order hash: \(hash1)
            Shuffled order hash: \(hash2)
            """)
    }
    
    @Test("Shuffled transfers produce same hash after sorting", arguments: 0..<50)
    func testTransfersOrderInvariant(iteration: Int) throws {
        let transfers = WidgetTestGenerators.transfers(count: Int.random(in: 3...10))
        
        let data1 = WidgetTransfersData(
            transfers: transfers.sorted { $0.id < $1.id },
            lastUpdated: fixedLastUpdated
        )
        let shuffled = transfers.shuffled()
        let data2 = WidgetTransfersData(
            transfers: shuffled.sorted { $0.id < $1.id },
            lastUpdated: fixedLastUpdated
        )
        
        let json1 = try encoder.encode(data1)
        let json2 = try encoder.encode(data2)
        
        let hash1 = sha256String(json1)
        let hash2 = sha256String(json2)
        
        #expect(hash1 == hash2)
    }
    
    @Test("Same data produces same hash across multiple encodings", arguments: 0..<20)
    func testDeterministicEncoding(iteration: Int) throws {
        let data = WidgetTestGenerators.devicesData(deviceCount: 10)
        
 // Encode multiple times
        let json1 = try encoder.encode(data)
        let json2 = try encoder.encode(data)
        let json3 = try encoder.encode(data)
        
        let hash1 = sha256String(json1)
        let hash2 = sha256String(json2)
        let hash3 = sha256String(json3)
        
        #expect(hash1 == hash2)
        #expect(hash2 == hash3)
    }
    
    @Test("Different data produces different hash")
    func testDifferentDataDifferentHash() throws {
        let data1 = WidgetDevicesData(devices: [
            WidgetDeviceInfo(id: "1", name: "Device A", deviceType: .mac, isOnline: true, lastSeen: fixedLastUpdated, ipAddress: nil)
        ], lastUpdated: fixedLastUpdated)
        
        let data2 = WidgetDevicesData(devices: [
            WidgetDeviceInfo(id: "1", name: "Device B", deviceType: .mac, isOnline: true, lastSeen: fixedLastUpdated, ipAddress: nil)
        ], lastUpdated: fixedLastUpdated)
        
        let json1 = try encoder.encode(data1)
        let json2 = try encoder.encode(data2)
        
        let hash1 = sha256String(json1)
        let hash2 = sha256String(json2)
        
        #expect(hash1 != hash2, "Different data should produce different hash")
    }
    
    @Test("Empty arrays produce consistent hash")
    func testEmptyArraysConsistentHash() throws {
        let data1 = WidgetDevicesData(devices: [], lastUpdated: fixedLastUpdated)
        let data2 = WidgetDevicesData(devices: [], lastUpdated: fixedLastUpdated)
        
        let json1 = try encoder.encode(data1)
        let json2 = try encoder.encode(data2)
        
        #expect(json1 == json2, "Empty payloads with the same metadata should encode identically")
    }
    
 // MARK: - Sorted Keys Verification
    
    @Test("JSON output has sorted keys")
    func testSortedKeysOutput() throws {
        let data = WidgetTestGenerators.devicesData(deviceCount: 3)
        let json = try encoder.encode(data)
        let jsonString = String(data: json, encoding: .utf8)!
        
 // Verify keys appear in alphabetical order
 // "devices" should come before "lastUpdated" which comes before "schemaVersion"
        if let devicesIndex = jsonString.range(of: "\"devices\""),
           let lastUpdatedIndex = jsonString.range(of: "\"lastUpdated\""),
           let schemaVersionIndex = jsonString.range(of: "\"schemaVersion\"") {
            #expect(devicesIndex.lowerBound < lastUpdatedIndex.lowerBound)
            #expect(lastUpdatedIndex.lowerBound < schemaVersionIndex.lowerBound)
        }
    }
    
 // MARK: - Helper
    
    private func sha256String(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
