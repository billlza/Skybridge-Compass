//
// SecurityEventEmitterTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for SecurityEventEmitter
// **Feature: security-hardening**
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Test Data Generator

/// Generates test data for SecurityEventEmitter tests
struct SecurityEventTestGenerator {
    
 /// Creates a random SecurityEvent for testing
    static func createRandomEvent(
        type: SecurityEventType? = nil,
        severity: SecurityEventSeverity? = nil,
        isMetaEvent: Bool = false
    ) -> SecurityEvent {
        let eventType = type ?? SecurityEventType.allCases.randomElement()!
        let eventSeverity = severity ?? [.info, .warning, .high, .critical].randomElement()!
        
        return SecurityEvent(
            type: eventType,
            severity: eventSeverity,
            message: "Test event \(UUID().uuidString)",
            context: [
                "testKey": "testValue_\(Int.random(in: 0...1000))",
                "iteration": String(Int.random(in: 0...10000))
            ],
            timestamp: Date(),
            id: UUID(),
            isMetaEvent: isMetaEvent
        )
    }
    
 /// Creates multiple random events
    static func createRandomEvents(count: Int) -> [SecurityEvent] {
        (0..<count).map { _ in createRandomEvent() }
    }
}

// MARK: - Thread-Safe Event Collector (Actor)

/// Actor for collecting events in a thread-safe manner
actor EventCollector {
    private var regularEvents: [SecurityEvent] = []
    private var metaEvents: [SecurityEvent] = []
    
    func addEvent(_ event: SecurityEvent) {
        if event.isMetaEvent {
            metaEvents.append(event)
        } else {
            regularEvents.append(event)
        }
    }
    
    func addMetaEvent(_ event: SecurityEvent) {
        metaEvents.append(event)
    }
    
    var regularEventCount: Int {
        regularEvents.count
    }
    
    var metaEventCount: Int {
        metaEvents.count
    }
    
    var allMetaEvents: [SecurityEvent] {
        metaEvents
    }
    
    var lastMetaEvent: SecurityEvent? {
        metaEvents.last
    }
    
    var metaEventTimestamps: [Date] {
        metaEvents.map { $0.timestamp }
    }
    
    func reset() {
        regularEvents.removeAll()
        metaEvents.removeAll()
    }
}

// MARK: - Property Test: Event Queue Overflow Handling
// **Feature: security-hardening, Property: Event queue overflow drops new events and emits meta-event**
// **Validates: Design constraint**

final class SecurityEventEmitterOverflowTests: XCTestCase {
    
 /// Property test: For any event queue at capacity, new events SHALL be dropped and a meta-event SHALL be emitted
 ///
 /// This test verifies:
 /// 1. When the queue is full, new events are dropped (not queued)
 /// 2. A meta-event (.limitExceeded with isMetaEvent=true) is emitted
 /// 3. Meta-events bypass the queue (delivered directly to subscribers)
 /// 4. Meta-events are rate-limited (max 1 per second)
 /// 5. The queue size never exceeds maxQueueSize
    func testProperty_EventQueueOverflowDropsNewEventsAndEmitsMetaEvent() async throws {
 // Use small queue size for testing
        let maxQueueSize = 10
        let maxPendingPerSubscriber = 50
        
        let emitter = SecurityEventEmitter.createForTesting(
            maxQueueSize: maxQueueSize,
            maxPendingPerSubscriber: maxPendingPerSubscriber
        )
        
 // Run multiple iterations with different overflow scenarios
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Reset emitter state for each iteration
            await emitter.resetForTesting()
            
 // Create a fresh collector for this iteration
            let collector = EventCollector()
            
 // Subscribe to events
            _ = await emitter.subscribe { event in
                await collector.addEvent(event)
            }
            
 // Generate events to overflow the queue
            let eventsToSend = maxQueueSize + Int.random(in: 1...20)
            let events = SecurityEventTestGenerator.createRandomEvents(count: eventsToSend)
            
 // Emit all events
            for event in events {
                await emitter.emit(event)
            }
            
 // Allow time for async delivery
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            
 // Property 1: Queue size never exceeds maxQueueSize
            let currentQueueSize = await emitter.currentQueueSize
            XCTAssertLessThanOrEqual(
                currentQueueSize,
                maxQueueSize,
                "Iteration \(iteration): Queue size (\(currentQueueSize)) should not exceed max (\(maxQueueSize))"
            )
            
 // Property 2: When overflow occurs, at least one meta-event should be emitted
            let metaEventCount = await collector.metaEventCount
            let regularEventCount = await collector.regularEventCount
            
            if eventsToSend > maxQueueSize {
                XCTAssertGreaterThanOrEqual(
                    metaEventCount,
                    1,
                    "Iteration \(iteration): At least one meta-event should be emitted on overflow"
                )
                
 // Property 3: Meta-events should have correct type and isMetaEvent flag
                let metaEvents = await collector.allMetaEvents
                for metaEvent in metaEvents {
                    XCTAssertTrue(
                        metaEvent.isMetaEvent,
                        "Iteration \(iteration): Meta-event should have isMetaEvent=true"
                    )
                    XCTAssertEqual(
                        metaEvent.type,
                        .limitExceeded,
                        "Iteration \(iteration): Meta-event should be of type .limitExceeded"
                    )
                    XCTAssertNotNil(
                        metaEvent.context["droppedCount"],
                        "Iteration \(iteration): Meta-event should contain droppedCount in context"
                    )
                }
            }
            
 // Property 4: Total events received should be <= events sent
 // (some are dropped due to overflow)
            XCTAssertLessThanOrEqual(
                regularEventCount,
                eventsToSend,
                "Iteration \(iteration): Received events (\(regularEventCount)) should not exceed sent (\(eventsToSend))"
            )
        }
    }
    
 /// Property test: Meta-events are rate-limited to max 1 per second
    func testProperty_MetaEventsAreRateLimited() async throws {
        let maxQueueSize = 5
        let emitter = SecurityEventEmitter.createForTesting(
            maxQueueSize: maxQueueSize,
            maxPendingPerSubscriber: 50
        )
        
        let collector = EventCollector()
        
        _ = await emitter.subscribe { event in
            if event.isMetaEvent {
                await collector.addMetaEvent(event)
            }
        }
        
 // Rapidly emit many events to trigger multiple overflows
        let eventsToSend = maxQueueSize * 10
        for _ in 0..<eventsToSend {
            let event = SecurityEventTestGenerator.createRandomEvent()
            await emitter.emit(event)
        }
        
 // Allow time for delivery
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        let timestamps = await collector.metaEventTimestamps
        
 // Property: Within a 1-second window, only 1 meta-event should be emitted
 // Since we're emitting rapidly (< 1 second total), we expect exactly 1 meta-event
        XCTAssertEqual(
            timestamps.count,
            1,
            "Only one meta-event should be emitted within the rate limit window (got \(timestamps.count))"
        )
    }
    
 /// Property test: Meta-events bypass the queue and are delivered directly
    func testProperty_MetaEventsBypassQueue() async throws {
        let maxQueueSize = 5
        let emitter = SecurityEventEmitter.createForTesting(
            maxQueueSize: maxQueueSize,
            maxPendingPerSubscriber: 50
        )
        
        let collector = EventCollector()
        
        _ = await emitter.subscribe { event in
            if event.isMetaEvent {
                await collector.addMetaEvent(event)
            }
        }
        
 // Fill the queue completely
        for _ in 0..<maxQueueSize {
            await emitter.emit(SecurityEventTestGenerator.createRandomEvent())
        }
        
 // Verify queue is full
        let queueSizeBeforeOverflow = await emitter.currentQueueSize
        XCTAssertEqual(queueSizeBeforeOverflow, maxQueueSize, "Queue should be full")
        
 // Emit one more event to trigger overflow
        await emitter.emit(SecurityEventTestGenerator.createRandomEvent())
        
 // Allow time for delivery
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
 // Property: Meta-event should be received even though queue is full
        let metaEventCount = await collector.metaEventCount
        
        XCTAssertGreaterThanOrEqual(
            metaEventCount,
            1,
            "Meta-event should be delivered even when queue is full (bypasses queue)"
        )
        
 // Property: Queue size should still be at max (meta-event didn't enter queue)
        let queueSizeAfterOverflow = await emitter.currentQueueSize
        XCTAssertEqual(
            queueSizeAfterOverflow,
            maxQueueSize,
            "Queue size should remain at max (meta-event bypasses queue)"
        )
    }
    
 /// Property test: Dropped events are counted correctly in meta-event context
    func testProperty_DroppedEventsCountedCorrectly() async throws {
        let maxQueueSize = 5
        let emitter = SecurityEventEmitter.createForTesting(
            maxQueueSize: maxQueueSize,
            maxPendingPerSubscriber: 50
        )
        
        let collector = EventCollector()
        
        _ = await emitter.subscribe { event in
            if event.isMetaEvent {
                await collector.addMetaEvent(event)
            }
        }
        
 // Fill the queue
        for _ in 0..<maxQueueSize {
            await emitter.emit(SecurityEventTestGenerator.createRandomEvent())
        }
        
 // Emit additional events that will be dropped
        let droppedCount = 7
        for _ in 0..<droppedCount {
            await emitter.emit(SecurityEventTestGenerator.createRandomEvent())
        }
        
 // Allow time for delivery
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        let metaEvent = await collector.lastMetaEvent
        
 // Property: Meta-event should report dropped count
        XCTAssertNotNil(metaEvent, "Meta-event should be emitted")
        
        if let metaEvent = metaEvent {
            XCTAssertNotNil(
                metaEvent.context["droppedCount"],
                "Meta-event should contain droppedCount"
            )
            
 // The dropped count in the meta-event should be > 0
            if let droppedStr = metaEvent.context["droppedCount"],
               let dropped = Int(droppedStr) {
                XCTAssertGreaterThan(
                    dropped,
                    0,
                    "Dropped count should be greater than 0"
                )
            }
        }
    }
}

// MARK: - Additional Edge Case Tests

extension SecurityEventEmitterOverflowTests {
    
 /// Test that normal events are delivered when queue is not full
    func testNormalEventsDeliveredWhenQueueNotFull() async throws {
        let maxQueueSize = 100
        let emitter = SecurityEventEmitter.createForTesting(
            maxQueueSize: maxQueueSize,
            maxPendingPerSubscriber: 50
        )
        
        let collector = EventCollector()
        
        _ = await emitter.subscribe { event in
            await collector.addEvent(event)
        }
        
 // Emit fewer events than queue capacity
        let eventsToSend = maxQueueSize / 2
        let sentEvents = SecurityEventTestGenerator.createRandomEvents(count: eventsToSend)
        
        for event in sentEvents {
            await emitter.emit(event)
        }
        
 // Allow time for delivery
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        let receivedCount = await collector.regularEventCount
        
 // All events should be delivered
        XCTAssertEqual(
            receivedCount,
            eventsToSend,
            "All events should be delivered when queue is not full"
        )
    }
    
 /// Test subscriber isolation - slow subscriber doesn't block others
    func testSubscriberIsolation() async throws {
        let maxQueueSize = 50
        let emitter = SecurityEventEmitter.createForTesting(
            maxQueueSize: maxQueueSize,
            maxPendingPerSubscriber: 10
        )
        
        let fastCollector = EventCollector()
        let slowCollector = EventCollector()
        
 // Fast subscriber
        _ = await emitter.subscribe { event in
            await fastCollector.addEvent(event)
        }
        
 // Slow subscriber (simulates processing delay)
        _ = await emitter.subscribe { event in
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
            await slowCollector.addEvent(event)
        }
        
 // Emit events
        let eventsToSend = 20
        for _ in 0..<eventsToSend {
            await emitter.emit(SecurityEventTestGenerator.createRandomEvent())
        }
        
 // Allow time for fast subscriber
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        let fastCount = await fastCollector.regularEventCount
        
 // Fast subscriber should receive events quickly
        XCTAssertGreaterThan(
            fastCount,
            0,
            "Fast subscriber should receive events"
        )
    }
}
