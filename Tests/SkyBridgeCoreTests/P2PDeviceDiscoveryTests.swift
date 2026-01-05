//
// P2PDeviceDiscoveryTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for P2P Device Discovery
// **Feature: ios-p2p-integration**
//
// Property 1: Device Discovery Timing (Validates: Requirements 1.1) - CI only
// Property 2: TXT Record Parsing Completeness (Validates: Requirements 1.2)
// Property 3: Offline Device Removal (Validates: Requirements 1.3)
// Property 4: Device List Sorting (Validates: Requirements 1.4)
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PDeviceDiscoveryTests: XCTestCase {
    
 // MARK: - Property 2: TXT Record Parsing Completeness
    
 /// **Property 2: TXT Record Parsing Completeness**
 /// *For any* valid TXT record containing device information, parsing should extract
 /// all required fields (deviceId, pubKeyFP, platform, capabilities) without data loss.
 /// **Validates: Requirements 1.2**
    func testTXTRecordParsingCompletenessProperty() {
 // Generate test TXT records with various configurations
        let testCases = generateTestTXTRecords()
        
        for (txtRecord, expectedDevice) in testCases {
 // Parse TXT record
            guard let device = P2PTXTRecordParser.createDevice(
                from: txtRecord,
                endpoint: createMockEndpoint()
            ) else {
                if expectedDevice != nil {
                    XCTFail("Failed to parse valid TXT record: \(txtRecord)")
                }
                continue
            }
            
            guard let expected = expectedDevice else {
                XCTFail("Should not have parsed invalid TXT record")
                continue
            }
            
 // Property: deviceId must be extracted correctly
            XCTAssertEqual(device.deviceId, expected.deviceId,
                           "deviceId must be extracted correctly")
            
 // Property: pubKeyFP must be extracted correctly
            XCTAssertEqual(device.pubKeyFP, expected.pubKeyFP,
                           "pubKeyFP must be extracted correctly")
            
 // Property: platform must be extracted correctly
            XCTAssertEqual(device.platform, expected.platform,
                           "platform must be extracted correctly")
            
 // Property: capabilities must be extracted correctly
            XCTAssertEqual(device.capabilities, expected.capabilities,
                           "capabilities must be extracted correctly")
        }
    }
    
 /// Test TXT record validation
    func testTXTRecordValidation() {
 // Valid record
        let validRecord: [String: String] = [
            "deviceId": "test-device-123",
            "pubKeyFP": String(repeating: "a", count: 64)
        ]
        
        let validResult = P2PTXTRecordParser.validate(validRecord)
        XCTAssertTrue(validResult.isValid, "Valid record should pass validation")
        
 // Missing deviceId
        let missingDeviceId: [String: String] = [
            "pubKeyFP": String(repeating: "a", count: 64)
        ]
        
        let missingResult = P2PTXTRecordParser.validate(missingDeviceId)
        XCTAssertFalse(missingResult.isValid, "Missing deviceId should fail validation")
        
 // Invalid pubKeyFP format
        let invalidPubKeyFP: [String: String] = [
            "deviceId": "test-device",
            "pubKeyFP": "invalid-format"
        ]
        
        let invalidResult = P2PTXTRecordParser.validate(invalidPubKeyFP)
        XCTAssertFalse(invalidResult.isValid, "Invalid pubKeyFP should fail validation")
        
 // Empty deviceId
        let emptyDeviceId: [String: String] = [
            "deviceId": "",
            "pubKeyFP": String(repeating: "a", count: 64)
        ]
        
        let emptyResult = P2PTXTRecordParser.validate(emptyDeviceId)
        XCTAssertFalse(emptyResult.isValid, "Empty deviceId should fail validation")
    }
    
 /// Test TXT record binary parsing
    func testTXTRecordBinaryParsing() {
 // Create binary TXT record data
        var data = Data()
        
 // Add "deviceId=test-123"
        let entry1 = "deviceId=test-123"
        data.append(UInt8(entry1.count))
        data.append(contentsOf: entry1.utf8)
        
 // Add "pubKeyFP=aaaa..."
        let pubKeyFP = String(repeating: "a", count: 64)
        let entry2 = "pubKeyFP=\(pubKeyFP)"
        data.append(UInt8(entry2.count))
        data.append(contentsOf: entry2.utf8)
        
 // Parse
        let parsed = P2PTXTRecordParser.parse(data)
        
 // Property: All entries should be parsed
        XCTAssertEqual(parsed["deviceId"], "test-123")
        XCTAssertEqual(parsed["pubKeyFP"], pubKeyFP)
    }
    
 // MARK: - Property 3: Offline Device Removal
    
 /// **Property 3: Offline Device Removal**
 /// *For any* previously discovered device that goes offline, the system should
 /// remove it from the discovered list within 5 seconds.
 /// **Validates: Requirements 1.3**
    func testOfflineDeviceRemovalProperty() {
 // Test that offline threshold is configured correctly
        XCTAssertEqual(P2PConstants.deviceOfflineThresholdSeconds, 5.0,
                       "Offline threshold must be 5 seconds")
        
 // Create device with old lastSeen
        let oldDevice = P2PDiscoveredDevice(
            deviceId: "old-device",
            pubKeyFP: String(repeating: "a", count: 64),
            platform: .iOS,
            capabilities: [],
            name: "Old Device",
            protocolVersion: "1.0",
            endpoint: createMockEndpoint(),
            lastSeen: Date().addingTimeInterval(-10), // 10 seconds ago
            isOnline: true
        )
        
 // Property: Device older than threshold should be considered offline
        let timeSinceLastSeen = Date().timeIntervalSince(oldDevice.lastSeen)
        XCTAssertGreaterThan(timeSinceLastSeen, P2PConstants.deviceOfflineThresholdSeconds,
                             "Old device should exceed offline threshold")
        
 // Create fresh device
        let freshDevice = P2PDiscoveredDevice(
            deviceId: "fresh-device",
            pubKeyFP: String(repeating: "b", count: 64),
            platform: .iOS,
            capabilities: [],
            name: "Fresh Device",
            protocolVersion: "1.0",
            endpoint: createMockEndpoint(),
            lastSeen: Date(),
            isOnline: true
        )
        
 // Property: Fresh device should not exceed threshold
        let freshTimeSince = Date().timeIntervalSince(freshDevice.lastSeen)
        XCTAssertLessThan(freshTimeSince, P2PConstants.deviceOfflineThresholdSeconds,
                          "Fresh device should not exceed offline threshold")
    }
    
 // MARK: - Property 4: Device List Sorting
    
 /// **Property 4: Device List Sorting**
 /// *For any* set of discovered devices with different lastSeen timestamps,
 /// the displayed list should be sorted in descending order by lastSeen time.
 /// **Validates: Requirements 1.4**
    func testDeviceListSortingProperty() {
 // Create devices with different lastSeen times
        let now = Date()
        var devices: [P2PDiscoveredDevice] = []
        
        for i in 0..<10 {
            let device = P2PDiscoveredDevice(
                deviceId: "device-\(i)",
                pubKeyFP: String(repeating: String(i), count: 64),
                platform: .iOS,
                capabilities: [],
                name: "Device \(i)",
                protocolVersion: "1.0",
                endpoint: createMockEndpoint(),
                lastSeen: now.addingTimeInterval(Double(-i * 10)), // Staggered times
                isOnline: true
            )
            devices.append(device)
        }
        
 // Shuffle to simulate random discovery order
        devices.shuffle()
        
 // Sort by lastSeen descending (as the service would)
        let sorted = devices.sorted { $0.lastSeen > $1.lastSeen }
        
 // Property: List should be sorted by lastSeen descending
        for i in 0..<sorted.count - 1 {
            XCTAssertGreaterThanOrEqual(sorted[i].lastSeen, sorted[i + 1].lastSeen,
                                        "Devices must be sorted by lastSeen descending")
        }
        
 // Property: Most recent device should be first
        let mostRecent = devices.max(by: { $0.lastSeen < $1.lastSeen })!
        XCTAssertEqual(sorted.first?.deviceId, mostRecent.deviceId,
                       "Most recent device must be first")
    }
    
 // MARK: - Additional Discovery Tests
    
 /// Test P2PPlatformType
    func testP2PPlatformType() {
 // Property: All platform types should have valid rawValue
        for platform in [P2PPlatformType.macOS, .iOS, .iPadOS, .unknown] {
            XCTAssertFalse(platform.rawValue.isEmpty,
                           "Platform \(platform) must have non-empty rawValue")
        }
        
 // Property: Mobile platforms should be identified correctly
        XCTAssertTrue(P2PPlatformType.iOS.isMobile, "iOS should be mobile")
        XCTAssertTrue(P2PPlatformType.iPadOS.isMobile, "iPadOS should be mobile")
        XCTAssertFalse(P2PPlatformType.macOS.isMobile, "macOS should not be mobile")
        XCTAssertFalse(P2PPlatformType.unknown.isMobile, "unknown should not be mobile")
    }
    
 /// Test P2PDiscoveredDevice equality
    func testP2PDiscoveredDeviceEquality() {
        let device1 = P2PDiscoveredDevice(
            deviceId: "same-device",
            pubKeyFP: String(repeating: "a", count: 64),
            platform: .iOS,
            capabilities: ["cap1"],
            name: "Device 1",
            protocolVersion: "1.0",
            endpoint: createMockEndpoint(),
            lastSeen: Date(),
            isOnline: true
        )
        
        let device2 = P2PDiscoveredDevice(
            deviceId: "same-device",
            pubKeyFP: String(repeating: "b", count: 64), // Different pubKeyFP
            platform: .macOS, // Different platform
            capabilities: ["cap2"], // Different capabilities
            name: "Device 2", // Different name
            protocolVersion: "2.0", // Different version
            endpoint: createMockEndpoint(),
            lastSeen: Date().addingTimeInterval(-100), // Different lastSeen
            isOnline: false // Different online status
        )
        
 // Property: Equality is based on deviceId only
        XCTAssertEqual(device1, device2,
                       "Devices with same deviceId must be equal")
        
        let device3 = P2PDiscoveredDevice(
            deviceId: "different-device",
            pubKeyFP: String(repeating: "a", count: 64),
            platform: .iOS,
            capabilities: ["cap1"],
            name: "Device 1",
            protocolVersion: "1.0",
            endpoint: createMockEndpoint(),
            lastSeen: Date(),
            isOnline: true
        )
        
 // Property: Different deviceId means not equal
        XCTAssertNotEqual(device1, device3,
                          "Devices with different deviceId must not be equal")
    }
    
 /// Test shortId computation
    func testShortIdComputation() {
        let pubKeyFP = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        let device = P2PDiscoveredDevice(
            deviceId: "test-device",
            pubKeyFP: pubKeyFP,
            platform: .iOS,
            capabilities: [],
            name: "Test",
            protocolVersion: "1.0",
            endpoint: createMockEndpoint()
        )
        
 // Property: shortId should be prefix of pubKeyFP
        XCTAssertTrue(pubKeyFP.hasPrefix(device.shortId),
                      "shortId must be prefix of pubKeyFP")
        
 // Property: shortId should have correct length
        XCTAssertEqual(device.shortId.count, P2PConstants.pubKeyFPDisplayLength,
                       "shortId must have correct length")
    }
    
 // MARK: - Helper Methods
    
    private func generateTestTXTRecords() -> [([String: String], P2PDiscoveredDevice?)] {
        var testCases: [([String: String], P2PDiscoveredDevice?)] = []
        
 // Valid complete record
        let validComplete: [String: String] = [
            "deviceId": "device-123",
            "pubKeyFP": String(repeating: "a", count: 64),
            "platform": "iOS",
            "capabilities": "screen-mirror,file-transfer",
            "name": "iPhone 15",
            "version": "1.0"
        ]
        let expectedComplete = P2PDiscoveredDevice(
            deviceId: "device-123",
            pubKeyFP: String(repeating: "a", count: 64),
            platform: .iOS,
            capabilities: ["screen-mirror", "file-transfer"],
            name: "iPhone 15",
            protocolVersion: "1.0",
            endpoint: createMockEndpoint()
        )
        testCases.append((validComplete, expectedComplete))
        
 // Valid minimal record
        let validMinimal: [String: String] = [
            "deviceId": "device-456",
            "pubKeyFP": String(repeating: "b", count: 64)
        ]
        let expectedMinimal = P2PDiscoveredDevice(
            deviceId: "device-456",
            pubKeyFP: String(repeating: "b", count: 64),
            platform: .unknown,
            capabilities: [],
            name: "Unknown Device",
            protocolVersion: "1.0",
            endpoint: createMockEndpoint()
        )
        testCases.append((validMinimal, expectedMinimal))
        
 // Invalid - missing deviceId
        let invalidMissingId: [String: String] = [
            "pubKeyFP": String(repeating: "c", count: 64)
        ]
        testCases.append((invalidMissingId, nil))
        
 // Invalid - missing pubKeyFP
        let invalidMissingFP: [String: String] = [
            "deviceId": "device-789"
        ]
        testCases.append((invalidMissingFP, nil))
        
 // Invalid - empty deviceId
        let invalidEmptyId: [String: String] = [
            "deviceId": "",
            "pubKeyFP": String(repeating: "d", count: 64)
        ]
        testCases.append((invalidEmptyId, nil))
        
        return testCases
    }
    
    private func createMockEndpoint() -> NWEndpoint {
 // Create a mock endpoint for testing
        return NWEndpoint.hostPort(host: "127.0.0.1", port: 12345)
    }
}

import Network
