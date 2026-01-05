// MARK: - Backward Compatibility Tests
// 宽容解码测试 - 确保旧版本 JSON 能正确解码
// Requirements: 5.3

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Backward Compatibility Tests")
struct BackwardCompatibilityTests {
    
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    
 // MARK: - Missing schemaVersion (v0 files)
    
    @Test("WidgetDevicesData decodes without schemaVersion field")
    func testDevicesDataMissingSchemaVersion() throws {
 // JSON without schemaVersion (simulating v0 file)
        let json = """
        {
            "devices": [
                {
                    "id": "device-1",
                    "name": "Old Device",
                    "deviceType": "mac",
                    "isOnline": true,
                    "lastSeen": "2024-01-01T00:00:00Z",
                    "ipAddress": "192.168.1.1"
                }
            ],
            "lastUpdated": "2024-01-01T00:00:00Z"
        }
        """
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetDevicesData.self, from: data)
        
        #expect(decoded.schemaVersion == 1, "Missing schemaVersion should default to 1")
        #expect(decoded.devices.count == 1)
        #expect(decoded.devices[0].name == "Old Device")
    }
    
    @Test("WidgetMetricsData decodes without schemaVersion field")
    func testMetricsDataMissingSchemaVersion() throws {
        let json = """
        {
            "metrics": {
                "cpuUsage": 50.0,
                "memoryUsage": 60.0,
                "networkUpload": 1000,
                "networkDownload": 2000,
                "timestamp": "2024-01-01T00:00:00Z"
            },
            "lastUpdated": "2024-01-01T00:00:00Z"
        }
        """
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetMetricsData.self, from: data)
        
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.metrics.cpuUsage == 50.0)
    }
    
    @Test("WidgetTransfersData decodes without schemaVersion field")
    func testTransfersDataMissingSchemaVersion() throws {
        let json = """
        {
            "transfers": [],
            "lastUpdated": "2024-01-01T00:00:00Z"
        }
        """
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetTransfersData.self, from: data)
        
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.transfers.isEmpty)
    }
    
 // MARK: - Missing Optional Fields
    
    @Test("WidgetDevicesData decodes with missing devices array")
    func testDevicesDataMissingDevices() throws {
        let json = """
        {
            "schemaVersion": 1,
            "lastUpdated": "2024-01-01T00:00:00Z"
        }
        """
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetDevicesData.self, from: data)
        
        #expect(decoded.devices.isEmpty, "Missing devices should default to empty array")
    }
    
    @Test("WidgetMetricsData decodes with missing metrics")
    func testMetricsDataMissingMetrics() throws {
        let json = """
        {
            "schemaVersion": 1,
            "lastUpdated": "2024-01-01T00:00:00Z"
        }
        """
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetMetricsData.self, from: data)
        
        #expect(decoded.metrics.cpuUsage == 0, "Missing metrics should default to empty")
        #expect(decoded.metrics.memoryUsage == 0)
    }
    
    @Test("WidgetDevicesData decodes with missing lastUpdated")
    func testDevicesDataMissingLastUpdated() throws {
        let json = """
        {
            "schemaVersion": 1,
            "devices": []
        }
        """
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetDevicesData.self, from: data)
        
        #expect(decoded.lastUpdated == Date.distantPast, "Missing lastUpdated should default to distantPast")
    }
    
 // MARK: - Unknown Device Type Fallback
    
    @Test("Unknown deviceType falls back to .unknown")
    func testUnknownDeviceTypeFallback() throws {
        let json = """
        {
            "schemaVersion": 1,
            "devices": [
                {
                    "id": "device-1",
                    "name": "Future Device",
                    "deviceType": "quantum_computer",
                    "isOnline": true,
                    "lastSeen": "2024-01-01T00:00:00Z",
                    "ipAddress": null
                }
            ],
            "lastUpdated": "2024-01-01T00:00:00Z"
        }
        """
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetDevicesData.self, from: data)
        
        #expect(decoded.devices[0].deviceType == .unknown, """
            Unknown device type 'quantum_computer' should fall back to .unknown
            """)
    }
    
    @Test("All known device types decode correctly")
    func testAllKnownDeviceTypes() throws {
        for type in WidgetDeviceType.allCases {
            let json = """
            {
                "id": "test",
                "name": "Test",
                "deviceType": "\(type.rawValue)",
                "isOnline": true,
                "lastSeen": "2024-01-01T00:00:00Z",
                "ipAddress": null
            }
            """
            
            let data = Data(json.utf8)
            let decoded = try decoder.decode(WidgetDeviceInfo.self, from: data)
            
            #expect(decoded.deviceType == type)
        }
    }
    
 // MARK: - Minimal JSON (Worst Case)
    
    @Test("WidgetDevicesData decodes from minimal JSON")
    func testMinimalDevicesDataJSON() throws {
        let json = "{}"
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetDevicesData.self, from: data)
        
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.devices.isEmpty)
        #expect(decoded.truncationInfo == nil)
        #expect(decoded.lastUpdated == Date.distantPast)
    }
    
    @Test("WidgetMetricsData decodes from minimal JSON")
    func testMinimalMetricsDataJSON() throws {
        let json = "{}"
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetMetricsData.self, from: data)
        
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.metrics.cpuUsage == 0)
    }
    
    @Test("WidgetTransfersData decodes from minimal JSON")
    func testMinimalTransfersDataJSON() throws {
        let json = "{}"
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetTransfersData.self, from: data)
        
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.transfers.isEmpty)
    }
    
 // MARK: - Future Schema Version
    
    @Test("Future schemaVersion is preserved")
    func testFutureSchemaVersion() throws {
        let json = """
        {
            "schemaVersion": 99,
            "devices": [],
            "lastUpdated": "2024-01-01T00:00:00Z"
        }
        """
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetDevicesData.self, from: data)
        
        #expect(decoded.schemaVersion == 99, "Future schema version should be preserved")
    }
    
 // MARK: - Extra Fields (Forward Compatibility)
    
    @Test("Extra unknown fields are ignored")
    func testExtraFieldsIgnored() throws {
        let json = """
        {
            "schemaVersion": 1,
            "devices": [],
            "lastUpdated": "2024-01-01T00:00:00Z",
            "futureField": "some value",
            "anotherFutureField": 12345
        }
        """
        
        let data = Data(json.utf8)
        let decoded = try decoder.decode(WidgetDevicesData.self, from: data)
        
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.devices.isEmpty)
    }
}
