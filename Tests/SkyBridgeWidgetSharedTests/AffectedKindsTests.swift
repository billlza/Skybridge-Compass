// MARK: - Affected Kinds Tests
// affectedKinds() 组合测试
// Requirements: 1.3

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Affected Kinds Tests")
struct AffectedKindsTests {
    
 // MARK: - Single Payload Tests
    
    @Test("Only devices changed → {deviceStatus}")
    func testOnlyDevicesChanged() {
        let result = affectedKinds(changedPayloads: [.devices])
        
        #expect(result == [.deviceStatus])
    }
    
    @Test("Only metrics changed → {systemMonitor}")
    func testOnlyMetricsChanged() {
        let result = affectedKinds(changedPayloads: [.metrics])
        
        #expect(result == [.systemMonitor])
    }
    
    @Test("Only transfers changed → {fileTransfer}")
    func testOnlyTransfersChanged() {
        let result = affectedKinds(changedPayloads: [.transfers])
        
        #expect(result == [.fileTransfer])
    }
    
 // MARK: - Multiple Payload Tests
    
    @Test("Devices + metrics changed → {deviceStatus, systemMonitor}")
    func testDevicesAndMetricsChanged() {
        let result = affectedKinds(changedPayloads: [.devices, .metrics])
        
        #expect(result == [.deviceStatus, .systemMonitor])
    }
    
    @Test("Devices + transfers changed → {deviceStatus, fileTransfer}")
    func testDevicesAndTransfersChanged() {
        let result = affectedKinds(changedPayloads: [.devices, .transfers])
        
        #expect(result == [.deviceStatus, .fileTransfer])
    }
    
    @Test("Metrics + transfers changed → {systemMonitor, fileTransfer}")
    func testMetricsAndTransfersChanged() {
        let result = affectedKinds(changedPayloads: [.metrics, .transfers])
        
        #expect(result == [.systemMonitor, .fileTransfer])
    }
    
    @Test("All payloads changed → ALL widgets")
    func testAllPayloadsChanged() {
        let result = affectedKinds(changedPayloads: Set(WidgetPayloadKind.allCases))
        
        #expect(result == Set(WidgetKind.allCases))
    }
    
 // MARK: - Schema Upgrade Tests
    
    @Test("Schema upgraded → ALL widgets regardless of payloads")
    func testSchemaUpgradedReloadsAll() {
 // Even with empty payloads, schema upgrade should reload all
        let result = affectedKinds(changedPayloads: [], schemaUpgraded: true)
        
        #expect(result == Set(WidgetKind.allCases))
    }
    
    @Test("Schema upgraded with single payload → ALL widgets")
    func testSchemaUpgradedWithSinglePayload() {
        let result = affectedKinds(changedPayloads: [.devices], schemaUpgraded: true)
        
        #expect(result == Set(WidgetKind.allCases))
    }
    
 // MARK: - Empty Set Tests
    
    @Test("Empty payloads → empty result")
    func testEmptyPayloads() {
        let result = affectedKinds(changedPayloads: [])
        
        #expect(result.isEmpty)
    }
    
 // MARK: - Mapping Consistency Tests
    
    @Test("Payload to widget mapping is complete")
    func testMappingIsComplete() {
 // Every payload kind should have a corresponding widget kind
        for payload in WidgetPayloadKind.allCases {
            #expect(payloadToWidgetMapping[payload] != nil, """
                Missing mapping for payload kind: \(payload)
                """)
        }
    }
    
    @Test("Mapping produces unique widgets")
    func testMappingProducesUniqueWidgets() {
        let widgets = payloadToWidgetMapping.values
        let uniqueWidgets = Set(widgets)
        
        #expect(widgets.count == uniqueWidgets.count, """
            Mapping should produce unique widgets for each payload
            """)
    }
    
 // MARK: - Property Tests
    
    @Test("affectedKinds is idempotent", arguments: 0..<20)
    func testIdempotent(iteration: Int) {
        let payloads = Set(WidgetPayloadKind.allCases.filter { _ in Bool.random() })
        let schemaUpgraded = Bool.random()
        
        let result1 = affectedKinds(changedPayloads: payloads, schemaUpgraded: schemaUpgraded)
        let result2 = affectedKinds(changedPayloads: payloads, schemaUpgraded: schemaUpgraded)
        
        #expect(result1 == result2)
    }
    
    @Test("Result size is bounded by input size", arguments: 0..<20)
    func testResultSizeBounded(iteration: Int) {
        let payloads = Set(WidgetPayloadKind.allCases.filter { _ in Bool.random() })
        
        let result = affectedKinds(changedPayloads: payloads, schemaUpgraded: false)
        
        #expect(result.count <= payloads.count, """
            Result size (\(result.count)) should not exceed input size (\(payloads.count))
            """)
    }
}
