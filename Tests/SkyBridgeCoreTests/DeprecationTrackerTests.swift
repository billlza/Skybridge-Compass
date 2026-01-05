//
// DeprecationTrackerTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for DeprecationTracker and Deprecated API Forwarding
// **Feature: tech-debt-cleanup, Property 9: Deprecated API Forwarding**
// **Validates: Requirements 10.1, 10.2**
//

import XCTest
@testable import SkyBridgeCore

// MARK: - DeprecationTracker Unit Tests

@available(macOS 14.0, iOS 17.0, *)
final class DeprecationTrackerTests: XCTestCase {
    
    var tracker: DeprecationTracker!
    
    override func setUp() {
        super.setUp()
        #if DEBUG
        tracker = DeprecationTracker.createForTesting()
        #endif
    }
    
    override func tearDown() {
        #if DEBUG
        tracker?.reset()
        #endif
        tracker = nil
        super.tearDown()
    }
    
 // MARK: - Basic Recording Tests
    
 /// Test that recordUsage tracks API calls
    func testRecordUsageTracksAPICalls() {
        #if DEBUG
        tracker.recordUsage(
            api: "TestAPI.method()",
            replacement: "NewAPI.method()"
        )
        
        XCTAssertTrue(tracker.hasRecordedUsage(for: "TestAPI.method()"))
        XCTAssertEqual(tracker.usageCount(for: "TestAPI.method()"), 1)
        XCTAssertEqual(tracker.uniqueAPICount, 1)
        XCTAssertEqual(tracker.totalUsageCount, 1)
        #endif
    }
    
 /// Test that multiple calls to same API increment count
    func testMultipleCallsIncrementCount() {
        #if DEBUG
        let api = "TestAPI.repeatedMethod()"
        let replacement = "NewAPI.repeatedMethod()"
        
        for _ in 0..<5 {
            tracker.recordUsage(api: api, replacement: replacement)
        }
        
        XCTAssertEqual(tracker.usageCount(for: api), 5)
        XCTAssertEqual(tracker.uniqueAPICount, 1)
        XCTAssertEqual(tracker.totalUsageCount, 5)
        #endif
    }
    
 /// Test that different APIs are tracked separately
    func testDifferentAPIsTrackedSeparately() {
        #if DEBUG
        tracker.recordUsage(api: "API1.method()", replacement: "New1.method()")
        tracker.recordUsage(api: "API2.method()", replacement: "New2.method()")
        tracker.recordUsage(api: "API1.method()", replacement: "New1.method()")
        
        XCTAssertEqual(tracker.usageCount(for: "API1.method()"), 2)
        XCTAssertEqual(tracker.usageCount(for: "API2.method()"), 1)
        XCTAssertEqual(tracker.uniqueAPICount, 2)
        XCTAssertEqual(tracker.totalUsageCount, 3)
        #endif
    }
    
 /// Test that call sites are tracked
    func testCallSitesAreTracked() {
        #if DEBUG
        tracker.recordUsage(
            api: "TestAPI.method()",
            replacement: "NewAPI.method()",
            file: "/path/to/File1.swift",
            line: 42
        )
        tracker.recordUsage(
            api: "TestAPI.method()",
            replacement: "NewAPI.method()",
            file: "/path/to/File2.swift",
            line: 100
        )
        
        let records = tracker.getUsageRecords()
        XCTAssertEqual(records.count, 1)
        
        let record = records[0]
        XCTAssertEqual(record.callSites.count, 2)
        XCTAssertTrue(record.callSites.contains("File1.swift:42"))
        XCTAssertTrue(record.callSites.contains("File2.swift:100"))
        #endif
    }
    
 /// Test that reset clears all data
    func testResetClearsAllData() {
        #if DEBUG
        tracker.recordUsage(api: "API1.method()", replacement: "New1.method()")
        tracker.recordUsage(api: "API2.method()", replacement: "New2.method()")
        
        XCTAssertEqual(tracker.uniqueAPICount, 2)
        
        tracker.reset()
        
        XCTAssertEqual(tracker.uniqueAPICount, 0)
        XCTAssertEqual(tracker.totalUsageCount, 0)
        XCTAssertFalse(tracker.hasRecordedUsage(for: "API1.method()"))
        #endif
    }
    
 /// Test report generation
    func testReportGeneration() {
        #if DEBUG
        tracker.recordUsage(api: "OldAPI.method()", replacement: "NewAPI.method()")
        
        let report = tracker.generateReport()
        
        XCTAssertTrue(report.contains("OldAPI.method()"))
        XCTAssertTrue(report.contains("NewAPI.method()"))
        XCTAssertTrue(report.contains("Call count: 1"))
        #endif
    }
    
 /// Test empty report
    func testEmptyReport() {
        #if DEBUG
        let report = tracker.generateReport()
        XCTAssertTrue(report.contains("No deprecated API usage detected"))
        #endif
    }
    
 // MARK: - Thread Safety Tests
    
 /// Test concurrent access is thread-safe
    func testConcurrentAccessIsThreadSafe() {
        #if DEBUG
        let expectation = XCTestExpectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = 100
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<100 {
            queue.async {
                self.tracker.recordUsage(
                    api: "ConcurrentAPI.method\(i % 10)()",
                    replacement: "NewAPI.method\(i % 10)()"
                )
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 5.0)
        
 // Should have recorded all calls without crashing
        XCTAssertEqual(tracker.totalUsageCount, 100)
        XCTAssertEqual(tracker.uniqueAPICount, 10)
        #endif
    }
}

// MARK: - Property 9: Deprecated API Forwarding Tests

/// **Property 9: Deprecated API Forwarding**
/// *For any* deprecated API call, the compatibility bridge SHALL:
/// 1. Forward the call to the new implementation (Requirement 10.1)
/// 2. Record the usage via DeprecationTracker (Requirement 10.2)
/// **Validates: Requirements 10.1, 10.2**
@available(macOS 14.0, iOS 17.0, *)
final class DeprecatedAPIForwardingTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
 // Reset the shared tracker before each test
        DeprecationTracker.shared.reset()
    }
    
    override func tearDown() {
        DeprecationTracker.shared.reset()
        super.tearDown()
    }
    
 // MARK: - EnhancedDeviceDiscovery Forwarding Tests
    
 /// Test EnhancedDeviceDiscovery.init() records deprecation
    @MainActor
    func testProperty9_EnhancedDeviceDiscoveryInitRecordsDeprecation() {
        #if DEBUG
 // Create deprecated instance
        let _ = EnhancedDeviceDiscovery()
        
 // Verify deprecation was recorded
        XCTAssertTrue(
            DeprecationTracker.shared.hasRecordedUsage(for: "EnhancedDeviceDiscovery.init()"),
            "EnhancedDeviceDiscovery.init() should record deprecation usage"
        )
        #endif
    }
    
 /// Test EnhancedDeviceDiscovery.startScanning() records deprecation
    @MainActor
    func testProperty9_EnhancedDeviceDiscoveryStartScanningRecordsDeprecation() {
        #if DEBUG
        let discovery = EnhancedDeviceDiscovery()
        DeprecationTracker.shared.reset()  // Reset after init
        
        discovery.startScanning()
        
        XCTAssertTrue(
            DeprecationTracker.shared.hasRecordedUsage(for: "EnhancedDeviceDiscovery.startScanning()"),
            "EnhancedDeviceDiscovery.startScanning() should record deprecation usage"
        )
        
 // Verify it updates state (forwarding works)
        XCTAssertTrue(discovery.isScanning, "startScanning should set isScanning to true")
        #endif
    }
    
 /// Test EnhancedDeviceDiscovery.stopScanning() records deprecation
    @MainActor
    func testProperty9_EnhancedDeviceDiscoveryStopScanningRecordsDeprecation() {
        #if DEBUG
        let discovery = EnhancedDeviceDiscovery()
        discovery.startScanning()
        DeprecationTracker.shared.reset()  // Reset after previous calls
        
        discovery.stopScanning()
        
        XCTAssertTrue(
            DeprecationTracker.shared.hasRecordedUsage(for: "EnhancedDeviceDiscovery.stopScanning()"),
            "EnhancedDeviceDiscovery.stopScanning() should record deprecation usage"
        )
        
 // Verify it updates state (forwarding works)
        XCTAssertFalse(discovery.isScanning, "stopScanning should set isScanning to false")
        #endif
    }
    
 // MARK: - DeviceTypesHardwareRemoteController Forwarding Tests
    
 /// Test DeviceTypesHardwareRemoteController.init() records deprecation
    @MainActor
    func testProperty9_DeviceTypesHardwareRemoteControllerInitRecordsDeprecation() {
        #if DEBUG
        let _ = DeviceTypesHardwareRemoteController()
        
        XCTAssertTrue(
            DeprecationTracker.shared.hasRecordedUsage(for: "DeviceTypesHardwareRemoteController.init()"),
            "DeviceTypesHardwareRemoteController.init() should record deprecation usage"
        )
        #endif
    }
    
 /// Test DeviceTypesHardwareRemoteController.disconnect() records deprecation
    @MainActor
    func testProperty9_DeviceTypesHardwareRemoteControllerDisconnectRecordsDeprecation() {
        #if DEBUG
        let controller = DeviceTypesHardwareRemoteController()
        DeprecationTracker.shared.reset()  // Reset after init
        
        controller.disconnect()
        
        XCTAssertTrue(
            DeprecationTracker.shared.hasRecordedUsage(for: "DeviceTypesHardwareRemoteController.disconnect()"),
            "DeviceTypesHardwareRemoteController.disconnect() should record deprecation usage"
        )
        
 // Verify state is updated (forwarding works)
        XCTAssertFalse(controller.isConnected, "disconnect should set isConnected to false")
        XCTAssertEqual(controller.connectionStatus, "未连接", "disconnect should update connectionStatus")
        #endif
    }
    
 // MARK: - DeviceTypesSecurityManager Forwarding Tests
    
 /// Test DeviceTypesSecurityManager.init() records deprecation
    @MainActor
    func testProperty9_DeviceTypesSecurityManagerInitRecordsDeprecation() {
        #if DEBUG
        let _ = DeviceTypesSecurityManager()
        
        XCTAssertTrue(
            DeprecationTracker.shared.hasRecordedUsage(for: "DeviceTypesSecurityManager.init()"),
            "DeviceTypesSecurityManager.init() should record deprecation usage"
        )
        #endif
    }
    
 /// Test DeviceTypesSecurityManager.cleanup() records deprecation
    @MainActor
    func testProperty9_DeviceTypesSecurityManagerCleanupRecordsDeprecation() async {
        #if DEBUG
        let manager = DeviceTypesSecurityManager()
        DeprecationTracker.shared.reset()  // Reset after init
        
        await manager.cleanup()
        
        XCTAssertTrue(
            DeprecationTracker.shared.hasRecordedUsage(for: "DeviceTypesSecurityManager.cleanup()"),
            "DeviceTypesSecurityManager.cleanup() should record deprecation usage"
        )
        
 // Verify state is updated (forwarding works)
        XCTAssertFalse(manager.isStarted, "cleanup should set isStarted to false")
        XCTAssertTrue(manager.trustedDevices.isEmpty, "cleanup should clear trustedDevices")
        #endif
    }
    
 // MARK: - Property: All Deprecated APIs Record Usage
    
 /// **Property 9 Comprehensive Test**
 /// For any deprecated API in the compatibility bridges, calling it SHALL record usage
    @MainActor
    func testProperty9_AllDeprecatedAPIsRecordUsage() {
        #if DEBUG
 // Test EnhancedDeviceDiscovery
        let discovery = EnhancedDeviceDiscovery()
        discovery.startScanning()
        discovery.stopScanning()
        
 // Test DeviceTypesHardwareRemoteController
        let controller = DeviceTypesHardwareRemoteController()
        controller.disconnect()
        
 // Test DeviceTypesSecurityManager
        let manager = DeviceTypesSecurityManager()
        
 // Verify all APIs were recorded
        let records = DeprecationTracker.shared.getUsageRecords()
        let recordedAPIs = Set(records.map { $0.api })
        
        let expectedAPIs: Set<String> = [
            "EnhancedDeviceDiscovery.init()",
            "EnhancedDeviceDiscovery.startScanning()",
            "EnhancedDeviceDiscovery.stopScanning()",
            "DeviceTypesHardwareRemoteController.init()",
            "DeviceTypesHardwareRemoteController.disconnect()",
            "DeviceTypesSecurityManager.init()"
        ]
        
        for api in expectedAPIs {
            XCTAssertTrue(
                recordedAPIs.contains(api),
                "Expected deprecated API '\(api)' to be recorded"
            )
        }
        
 // Verify total count is at least the number of expected APIs
        XCTAssertGreaterThanOrEqual(
            DeprecationTracker.shared.uniqueAPICount,
            expectedAPIs.count,
            "Should have recorded at least \(expectedAPIs.count) unique deprecated APIs"
        )
        #endif
    }
    
 // MARK: - Property: Replacement Information is Correct
    
 /// Test that replacement information is correctly recorded
    @MainActor
    func testProperty9_ReplacementInformationIsCorrect() {
        #if DEBUG
        let _ = EnhancedDeviceDiscovery()
        
        let records = DeprecationTracker.shared.getUsageRecords()
        let initRecord = records.first { $0.api == "EnhancedDeviceDiscovery.init()" }
        
        XCTAssertNotNil(initRecord, "Should have recorded EnhancedDeviceDiscovery.init()")
        XCTAssertEqual(
            initRecord?.replacement,
            "DeviceDiscoveryService.shared",
            "Replacement should point to DeviceDiscoveryService.shared"
        )
        #endif
    }
}
