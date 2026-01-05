// SPDX-License-Identifier: MIT
// SkyBridge Compass - SecurityEventCollector Tests
// Requirements: 1.2, 1.3, 1.4

import XCTest
import Foundation
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class SecurityEventCollectorTests: XCTestCase {
    
 // MARK: - Lifecycle Tests
    
 /// Test start/stop lifecycle
    func testStartStopLifecycle() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let collector = SecurityEventCollector(emitter: emitter)
        
 // Initially not collecting
        let initialCollecting = await collector.collecting
        XCTAssertFalse(initialCollecting)
        
 // Start collecting
        await collector.startCollecting()
        let afterStart = await collector.collecting
        XCTAssertTrue(afterStart)
        
 // Stop collecting
        await collector.stopCollecting()
        let afterStop = await collector.collecting
        XCTAssertFalse(afterStop)
    }
    
 /// Test double start is safe
    func testDoubleStartIsSafe() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let collector = SecurityEventCollector(emitter: emitter)
        
        await collector.startCollecting()
        await collector.startCollecting() // Should not crash
        
        let collecting = await collector.collecting
        XCTAssertTrue(collecting)
        
        await collector.stopCollecting()
    }
    
 /// Test stop without start is safe
    func testStopWithoutStartIsSafe() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let collector = SecurityEventCollector(emitter: emitter)
        
        await collector.stopCollecting() // Should not crash
        
        let collecting = await collector.collecting
        XCTAssertFalse(collecting)
    }
    
 // MARK: - Event Counting Tests
    
 /// Test event counting by type
    func testEventCountingByType() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let collector = SecurityEventCollector(emitter: emitter)
        
        await collector.startCollecting()
        
 // Emit some events
        await emitter.emit(SecurityEvent.create(type: .handshakeFailed, message: "Test 1"))
        await emitter.emit(SecurityEvent.create(type: .handshakeFailed, message: "Test 2"))
        await emitter.emit(SecurityEvent.create(type: .cryptoDowngrade, message: "Test 3"))
        
 // Wait for events to be processed
        try await Task.sleep(for: .milliseconds(50))
        
 // Verify counts
        let handshakeCount = await collector.handshakeFailedCount
        let downgradeCount = await collector.cryptoDowngradeCount
        
        XCTAssertEqual(handshakeCount, 2)
        XCTAssertEqual(downgradeCount, 1)
        
        await collector.stopCollecting()
    }
    
 /// Test count(of:) method
    func testCountOfMethod() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let collector = SecurityEventCollector(emitter: emitter)
        
        await collector.startCollecting()
        
 // Emit events of different types
        await emitter.emit(SecurityEvent.create(type: .limitExceeded, message: "Limit 1"))
        await emitter.emit(SecurityEvent.create(type: .limitExceeded, message: "Limit 2"))
        await emitter.emit(SecurityEvent.create(type: .rateLimitDisconnect, message: "Rate 1"))
        
        try await Task.sleep(for: .milliseconds(50))
        
        let limitCount = await collector.count(of: .limitExceeded)
        let rateCount = await collector.count(of: .rateLimitDisconnect)
        let handshakeCount = await collector.count(of: .handshakeFailed)
        
        XCTAssertEqual(limitCount, 2)
        XCTAssertEqual(rateCount, 1)
        XCTAssertEqual(handshakeCount, 0) // No handshake events emitted
        
        await collector.stopCollecting()
    }
    
 // MARK: - Reset Tests
    
 /// Test reset functionality
    func testResetFunctionality() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let collector = SecurityEventCollector(emitter: emitter)
        
        await collector.startCollecting()
        
 // Emit some events
        await emitter.emit(SecurityEvent.create(type: .handshakeFailed, message: "Test"))
        await emitter.emit(SecurityEvent.create(type: .cryptoDowngrade, message: "Test"))
        
        try await Task.sleep(for: .milliseconds(50))
        
 // Verify events were collected
        var handshakeCount = await collector.handshakeFailedCount
        XCTAssertEqual(handshakeCount, 1)
        
 // Reset
        await collector.reset()
        
 // Verify counts are zero
        handshakeCount = await collector.handshakeFailedCount
        let downgradeCount = await collector.cryptoDowngradeCount
        
        XCTAssertEqual(handshakeCount, 0)
        XCTAssertEqual(downgradeCount, 0)
        
        await collector.stopCollecting()
    }
    
 /// Test reset between iterations
    func testResetBetweenIterations() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let collector = SecurityEventCollector(emitter: emitter)
        
        await collector.startCollecting()
        
 // Iteration 1
        await emitter.emit(SecurityEvent.create(type: .handshakeFailed, message: "Iter 1"))
        try await Task.sleep(for: .milliseconds(30))
        
        var count = await collector.handshakeFailedCount
        XCTAssertEqual(count, 1)
        
        await collector.reset()
        
 // Iteration 2
        await emitter.emit(SecurityEvent.create(type: .handshakeFailed, message: "Iter 2"))
        await emitter.emit(SecurityEvent.create(type: .handshakeFailed, message: "Iter 2"))
        try await Task.sleep(for: .milliseconds(30))
        
        count = await collector.handshakeFailedCount
        XCTAssertEqual(count, 2)
        
        await collector.stopCollecting()
    }
    
 // MARK: - All Events Tests
    
 /// Test allEvents() method
    func testAllEventsMethod() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let collector = SecurityEventCollector(emitter: emitter)
        
        await collector.startCollecting()
        
        await emitter.emit(SecurityEvent.create(type: .handshakeFailed, message: "A"))
        await emitter.emit(SecurityEvent.create(type: .cryptoDowngrade, message: "B"))
        await emitter.emit(SecurityEvent.create(type: .limitExceeded, message: "C"))
        
        try await Task.sleep(for: .milliseconds(50))
        
        let allEvents = await collector.allEvents()
        XCTAssertEqual(allEvents.count, 3)
        
        await collector.stopCollecting()
    }
    
 /// Test events(of:) method
    func testEventsOfTypeMethod() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let collector = SecurityEventCollector(emitter: emitter)
        
        await collector.startCollecting()
        
        await emitter.emit(SecurityEvent.create(type: .handshakeFailed, message: "Fail 1"))
        await emitter.emit(SecurityEvent.create(type: .handshakeFailed, message: "Fail 2"))
        
        try await Task.sleep(for: .milliseconds(50))
        
        let events = await collector.events(of: .handshakeFailed)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].message, "Fail 1")
        XCTAssertEqual(events[1].message, "Fail 2")
        
        await collector.stopCollecting()
    }
    
 // MARK: - Property Tests
    
 /// Property 1: Event Capture Completeness
 /// For any SecurityEvent emitted while collector is active, it SHALL be captured
    func testProperty_EventCaptureCompleteness() async throws {
 // Run 50 iterations (reduced for test speed)
        for iteration in 0..<50 {
 // Create fresh emitter and collector for each iteration
            let emitter = SecurityEventEmitter.createForTesting()
            let collector = SecurityEventCollector(emitter: emitter)
            
            await collector.startCollecting()
            
 // Generate random number of events (1-10)
            let eventCount = Int.random(in: 1...10)
            
 // Emit events
            for _ in 0..<eventCount {
                let eventType: SecurityEventType = Bool.random() ? .handshakeFailed : .cryptoDowngrade
                await emitter.emit(SecurityEvent.create(type: eventType, message: "Test"))
            }
            
 // Wait for processing
            try await Task.sleep(for: .milliseconds(50))
            
 // Verify all events were captured
            let capturedCount = await collector.allEvents().count
            XCTAssertEqual(
                capturedCount, eventCount,
                "Iteration \(iteration): Expected \(eventCount) events, got \(capturedCount)"
            )
            
            await collector.stopCollecting()
        }
    }
    
 /// Property 3: Event Count Accuracy
 /// For any sequence of events, count(of:) SHALL return exact count
    func testProperty_EventCountAccuracy() async throws {
 // Run 50 iterations (reduced for test speed)
        for iteration in 0..<50 {
 // Create fresh emitter and collector for each iteration
            let emitter = SecurityEventEmitter.createForTesting()
            let collector = SecurityEventCollector(emitter: emitter)
            
            await collector.startCollecting()
            
 // Generate known distribution
            let handshakeCount = Int.random(in: 0...5)
            let downgradeCount = Int.random(in: 0...5)
            
 // Emit events
            for _ in 0..<handshakeCount {
                await emitter.emit(SecurityEvent.create(type: .handshakeFailed, message: "H"))
            }
            for _ in 0..<downgradeCount {
                await emitter.emit(SecurityEvent.create(type: .cryptoDowngrade, message: "D"))
            }
            
            try await Task.sleep(for: .milliseconds(50))
            
 // Verify counts match
            let actualHandshake = await collector.handshakeFailedCount
            let actualDowngrade = await collector.cryptoDowngradeCount
            
            XCTAssertEqual(
                actualHandshake, handshakeCount,
                "Iteration \(iteration): handshakeFailed mismatch"
            )
            XCTAssertEqual(
                actualDowngrade, downgradeCount,
                "Iteration \(iteration): cryptoDowngrade mismatch"
            )
            
            await collector.stopCollecting()
        }
    }
}
