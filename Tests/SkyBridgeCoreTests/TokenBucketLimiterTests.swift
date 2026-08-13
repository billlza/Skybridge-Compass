//
// TokenBucketLimiterTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for TokenBucketLimiter and ConnectionRateLimiter
// **Feature: security-hardening**
//

import XCTest
@testable import SkyBridgeCore

private final class ManualRateLimiterClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant

    init(instant: ContinuousClock.Instant = ContinuousClock.now) {
        self.instant = instant
    }

    func currentInstant() -> ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero, "Manual clock must remain monotonic")
        lock.withLock {
            instant = instant.advanced(by: duration)
        }
    }
}

// MARK: - Property Test: Token Bucket Rate Limiting Per Connection
// **Feature: security-hardening, Property 10: Token bucket rate limiting per connection**
// **Validates: Requirements 4.1, 4.8**

final class TokenBucketLimiterTests: XCTestCase {
    
 /// **Feature: security-hardening, Property 10: Token bucket rate limiting per connection**
 /// **Validates: Requirements 4.1, 4.8**
 ///
 /// Property: For any WebSocket connection, the rate limiter SHALL enforce
 /// token bucket limits independently per connection.
 ///
 /// This test verifies:
 /// 1. Tokens are consumed correctly (one per tryConsume)
 /// 2. Burst capacity is respected (can't exceed burst)
 /// 3. Rate limiting kicks in when tokens exhausted
 /// 4. Tokens refill over time at the configured rate
 /// 5. Multiple connections have independent token buckets
    func testProperty_TokenBucketRateLimitingPerConnection() async throws {
 // Run 100 iterations with different random configurations
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate random configuration within valid bounds
            let rate = Double.random(in: 10.0...1000.0)
            let burst = Int.random(in: 10...500)

            let clock = ManualRateLimiterClock()
            let limiter = TokenBucketLimiter(
                rate: rate,
                burst: burst,
                now: { clock.currentInstant() }
            )
            
 // Property 1: Initial tokens should equal burst capacity
            let initialTokens = await limiter.availableTokens
            XCTAssertEqual(
                initialTokens, Double(burst),
                "Iteration \(iteration): Initial tokens (\(initialTokens)) should equal burst (\(burst))"
            )
            
 // Property 2: Can consume up to burst tokens immediately
            var consumedCount = 0
            for _ in 0..<burst {
                let consumed = await limiter.tryConsume()
                if consumed {
                    consumedCount += 1
                }
            }
            XCTAssertEqual(
                consumedCount, burst,
                "Iteration \(iteration): Should consume exactly \(burst) tokens, consumed \(consumedCount)"
            )
            
 // Property 3: After exhausting burst, next consume should fail
            let afterBurstConsume = await limiter.tryConsume()
            XCTAssertFalse(
                afterBurstConsume,
                "Iteration \(iteration): Should not consume after burst exhausted"
            )
            
 // Property 4: Tokens should be near zero after exhausting burst
            let tokensAfterExhaust = await limiter.availableTokens
            XCTAssertLessThan(
                tokensAfterExhaust, 1.0,
                "Iteration \(iteration): Tokens after exhaust (\(tokensAfterExhaust)) should be < 1.0"
            )
        }
    }
    
 /// Test that tokens refill over time at the configured rate
    func testTokenRefillOverTime() async throws {
        let rate = 100.0 // 100 tokens per second
        let burst = 100

        let clock = ManualRateLimiterClock()
        let limiter = TokenBucketLimiter(
            rate: rate,
            burst: burst,
            now: { clock.currentInstant() }
        )
        
 // Consume all tokens
        for _ in 0..<burst {
            _ = await limiter.tryConsume()
        }
        
 // Verify tokens exhausted (tryConsume triggers refill internally)
        let exhausted = await limiter.tryConsume()
        XCTAssertFalse(exhausted, "Tokens should be exhausted")
        
 // Advance exactly 100ms: 10 tokens at 100 tokens per second.
        clock.advance(by: .milliseconds(100))

        let consumedTen = await limiter.tryConsume(count: 10)
        let consumedEleventh = await limiter.tryConsume()
        let remaining = await limiter.availableTokens
        XCTAssertTrue(consumedTen, "Exactly 10 tokens should refill")
        XCTAssertFalse(consumedEleventh, "An eleventh token must not be available")
        XCTAssertEqual(remaining, 0, accuracy: 0.000_001)
    }

 /// Test that fractional refill accumulates without creating a ghost token.
    func testFractionalRefillAccumulatesToWholeToken() async throws {
        let clock = ManualRateLimiterClock()
        let limiter = TokenBucketLimiter(
            rate: 4.0,
            burst: 1,
            now: { clock.currentInstant() }
        )

        let initialConsume = await limiter.tryConsume()
        XCTAssertTrue(initialConsume)

        clock.advance(by: .milliseconds(125))
        let halfTokenConsume = await limiter.tryConsume()
        let halfTokenBalance = await limiter.availableTokens
        XCTAssertFalse(halfTokenConsume, "Half a token must not be consumable")
        XCTAssertEqual(halfTokenBalance, 0.5, accuracy: 0.000_001)

        clock.advance(by: .milliseconds(125))
        let accumulatedConsume = await limiter.tryConsume()
        let consumeAfterAccumulated = await limiter.tryConsume()
        XCTAssertTrue(accumulatedConsume, "Two half-token intervals should accumulate")
        XCTAssertFalse(consumeAfterAccumulated, "The accumulated token must be consumed once")
    }

 /// Test that tokens are clamped to burst capacity on refill
    func testTokensClampedToBurstOnRefill() async throws {
        let rate = 1000.0 // High rate
        let burst = 50

        let clock = ManualRateLimiterClock()
        let limiter = TokenBucketLimiter(
            rate: rate,
            burst: burst,
            now: { clock.currentInstant() }
        )
        
 // Consume some tokens
        for _ in 0..<10 {
            _ = await limiter.tryConsume()
        }
        
 // Advance enough to refill more than the bucket can hold.
        clock.advance(by: .milliseconds(100)) // 100 tokens at 1000/s

 // Consuming exactly the burst must succeed, but one more token must fail.
        let consumedBurst = await limiter.tryConsume(count: burst)
        let consumedBeyondBurst = await limiter.tryConsume()
        XCTAssertTrue(consumedBurst)
        XCTAssertFalse(consumedBeyondBurst, "Refill must clamp at burst capacity")
    }

 /// Monitoring snapshots should account for elapsed time without consuming.
    func testAvailableTokenSnapshotsRefillAtQueryTime() async throws {
        let clock = ManualRateLimiterClock()
        let limiter = TokenBucketLimiter(
            rate: 4.0,
            burst: 4,
            now: { clock.currentInstant() }
        )

        let consumedInitialBurst = await limiter.tryConsume(count: 4)
        XCTAssertTrue(consumedInitialBurst)

        clock.advance(by: .milliseconds(625)) // 2.5 tokens
        let preciseSnapshot = await limiter.availableTokens
        let integerSnapshot = await limiter.availableTokensInt
        XCTAssertEqual(preciseSnapshot, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(integerSnapshot, 2)
    }
    
 /// Test that multiple connections have independent token buckets
    func testIndependentTokenBucketsPerConnection() async throws {
        let rate = 100.0
        let burst = 50

        let clock = ManualRateLimiterClock()
 // Create two independent limiters (simulating two connections)
        let limiter1 = TokenBucketLimiter(
            rate: rate,
            burst: burst,
            now: { clock.currentInstant() }
        )
        let limiter2 = TokenBucketLimiter(
            rate: rate,
            burst: burst,
            now: { clock.currentInstant() }
        )
        
 // Exhaust limiter1
        for _ in 0..<burst {
            _ = await limiter1.tryConsume()
        }
        
 // limiter1 should be exhausted
        let limiter1CanConsume = await limiter1.tryConsume()
        XCTAssertFalse(limiter1CanConsume, "Limiter1 should be exhausted")
        
 // limiter2 should still have full capacity
        let limiter2Tokens = await limiter2.availableTokens
        XCTAssertEqual(limiter2Tokens, Double(burst), "Limiter2 should have full capacity")
        
 // limiter2 should be able to consume
        let limiter2CanConsume = await limiter2.tryConsume()
        XCTAssertTrue(limiter2CanConsume, "Limiter2 should be able to consume")
    }
    
 /// Test tryConsume with count parameter
    func testTryConsumeMultiple() async throws {
        let burst = 100
        let clock = ManualRateLimiterClock()
        let limiter = TokenBucketLimiter(
            rate: 100.0,
            burst: burst,
            now: { clock.currentInstant() }
        )
        
 // Consume 50 tokens at once
        let consumed50 = await limiter.tryConsume(count: 50)
        XCTAssertTrue(consumed50, "Should consume 50 tokens")
        
 // Should have ~50 tokens left
        let remaining = await limiter.availableTokens
        XCTAssertEqual(remaining, 50.0, accuracy: 1.0, "Should have ~50 tokens remaining")
        
 // Try to consume 60 (more than remaining) - should fail
        let consumed60 = await limiter.tryConsume(count: 60)
        XCTAssertFalse(consumed60, "Should not consume 60 tokens when only ~50 remain")
        
 // Tokens should be unchanged after failed consume
        let afterFailed = await limiter.availableTokens
        XCTAssertEqual(afterFailed, remaining, accuracy: 1.0, "Tokens should be unchanged after failed consume")

        let consumedBeyondCapacity = await limiter.tryConsume(count: Int.max)
        let afterBeyondCapacity = await limiter.availableTokens
        XCTAssertFalse(consumedBeyondCapacity, "A request larger than burst must fail")
        XCTAssertEqual(afterBeyondCapacity, remaining, accuracy: 0.000_001)
    }
    
 /// Test reset functionality
    func testReset() async throws {
        let burst = 100
        let clock = ManualRateLimiterClock()
        let limiter = TokenBucketLimiter(
            rate: 100.0,
            burst: burst,
            now: { clock.currentInstant() }
        )
        
 // Exhaust tokens
        for _ in 0..<burst {
            _ = await limiter.tryConsume()
        }
        
 // Verify exhausted
        let afterExhaust = await limiter.availableTokens
        XCTAssertLessThan(afterExhaust, 1.0, "Should be exhausted")
        
 // Elapsed time before reset must not be counted after the reset baseline moves.
        clock.advance(by: .seconds(10))
        await limiter.reset()

 // The reset bucket has exactly one burst, not a second refill from old elapsed time.
        let consumedResetBurst = await limiter.tryConsume(count: burst)
        let consumedBeyondResetBurst = await limiter.tryConsume()
        XCTAssertTrue(consumedResetBurst)
        XCTAssertFalse(consumedBeyondResetBurst)
    }
    
 /// Test initialization from SecurityLimits
    func testInitFromSecurityLimits() async throws {
        let limits = SecurityLimits.default
        let clock = ManualRateLimiterClock()
        let limiter = TokenBucketLimiter(
            limits: limits,
            now: { clock.currentInstant() }
        )
        
        let tokens = await limiter.availableTokens
        XCTAssertEqual(tokens, Double(limits.tokenBucketBurst), "Should initialize with burst from limits")
    }
    
 /// Test edge case: consume with count 0
    func testConsumeZero() async throws {
        let clock = ManualRateLimiterClock()
        let limiter = TokenBucketLimiter(
            rate: 100.0,
            burst: 100,
            now: { clock.currentInstant() }
        )
        
        let consumed = await limiter.tryConsume(count: 0)
        XCTAssertTrue(consumed, "Consuming 0 tokens should always succeed")
        
        let tokens = await limiter.availableTokens
        XCTAssertEqual(tokens, 100.0, "Tokens should be unchanged after consuming 0")
    }
    
 /// Test floating-point precision: >= 1.0 check prevents ghost tokens
    func testFloatingPointPrecision() async throws {
        let clock = ManualRateLimiterClock()
        let limiter = TokenBucketLimiter(
            rate: 100.0,
            burst: 1,
            now: { clock.currentInstant() }
        )
        
 // Consume the single token
        let consumed = await limiter.tryConsume()
        XCTAssertTrue(consumed, "Should consume the single token")
        
 // Immediately try again - should fail (no ghost tokens from floating point)
        let ghostConsume = await limiter.tryConsume()
        XCTAssertFalse(ghostConsume, "Should not have ghost tokens from floating point precision")
    }

 /// Actor isolation must prevent concurrent consumers from overspending a fixed bucket.
    func testConcurrentConsumptionDoesNotExceedBurst() async throws {
        let burst = 100
        let clock = ManualRateLimiterClock()
        let limiter = TokenBucketLimiter(
            rate: 100.0,
            burst: burst,
            now: { clock.currentInstant() }
        )

        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<(burst * 2) {
                group.addTask {
                    await limiter.tryConsume()
                }
            }

            var count = 0
            for await result in group where result {
                count += 1
            }
            return count
        }

        XCTAssertEqual(accepted, burst)
        let remaining = await limiter.availableTokens
        XCTAssertEqual(remaining, 0, accuracy: 0.000_001)
    }
}


// MARK: - Property Test: Rate Limit Disconnect Threshold
// **Feature: security-hardening, Property 12: Rate limit disconnect threshold**
// **Validates: Requirements 4.6, 4.7**

final class ConnectionRateLimiterTests: XCTestCase {
    
 /// **Feature: security-hardening, Property 12: Rate limit disconnect threshold**
 /// **Validates: Requirements 4.6, 4.7**
 ///
 /// Property: For any connection dropping more than droppedMessagesThreshold messages
 /// in droppedMessagesWindow, the service SHALL close connection and emit
 /// SecurityEvent.rateLimitDisconnect.
 ///
 /// This test verifies:
 /// 1. Dropped messages are tracked in sliding window
 /// 2. Disconnect is triggered when threshold exceeded
 /// 3. Old dropped messages outside window don't count
 /// 4. Each connection tracks drops independently
    func testProperty_RateLimitDisconnectThreshold() async throws {
 // Run 100 iterations with different random configurations
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate random configuration
            let threshold = Int.random(in: 10...100)
            let windowSeconds = Double.random(in: 1.0...10.0)
            let rate = Double.random(in: 1.0...10.0) // Low rate to trigger drops
            let burst = Int.random(in: 1...5) // Low burst to trigger drops quickly
            
            let limits = createTestLimits(
                rate: rate,
                burst: burst,
                threshold: threshold,
                window: windowSeconds
            )
            let clock = ManualRateLimiterClock()
            let limiter = ConnectionRateLimiter(
                limits: limits,
                connectionId: "test-\(iteration)",
                now: { clock.currentInstant() }
            )
            
 // Property 1: Initial state should allow processing
            let initialDecision = await limiter.shouldProcess()
            XCTAssertEqual(
                initialDecision, .allow,
                "Iteration \(iteration): Initial decision should be allow"
            )
            
 // Property 2: Exhaust the remaining burst without recording a drop.
            for _ in 1..<burst {
                let decision = await limiter.shouldProcess()
                XCTAssertEqual(decision, .allow, "Iteration \(iteration): Burst token should be allowed")
            }
            
 // Next requests should be dropped (until threshold)
            var dropCount = 0
            for _ in 0..<(threshold - 1) {
                let decision = await limiter.shouldProcess()
                XCTAssertEqual(decision, .drop, "Iteration \(iteration): Expected a drop before threshold")
                dropCount += 1
            }
            
 // Property 3: Should have dropped messages but not disconnected yet
            XCTAssertGreaterThan(
                dropCount, 0,
                "Iteration \(iteration): Should have some dropped messages"
            )
            
 // Property 4: One more drop should trigger disconnect
            let finalDecision = await limiter.shouldProcess()
            if case .disconnect(let reason) = finalDecision {
                XCTAssertTrue(
                    reason.contains("\(threshold)"),
                    "Iteration \(iteration): Disconnect reason should mention threshold"
                )
            } else {
                XCTFail("Iteration \(iteration): Expected disconnect at threshold, got \(finalDecision)")
            }
        }
    }
    
 /// Test that dropped messages are tracked correctly
    func testDroppedMessagesTracking() async throws {
        let limits = createTestLimits(
            rate: 1.0, // Very low rate
            burst: 1,
            threshold: 100,
            window: 10.0
        )
        
        let limiter = makeLimiter(limits: limits, connectionId: "test")
        
 // Consume the single token
        let first = await limiter.shouldProcess()
        XCTAssertEqual(first, .allow, "First request should be allowed")
        
 // Next request should be dropped
        let second = await limiter.shouldProcess()
        XCTAssertEqual(second, .drop, "Second request should be dropped")
        
 // Check dropped count
        let droppedCount = await limiter.droppedMessageCount
        XCTAssertEqual(droppedCount, 1, "Should have 1 dropped message")
        
 // Drop more messages
        for _ in 0..<5 {
            _ = await limiter.shouldProcess()
        }
        
        let totalDropped = await limiter.droppedMessageCount
        XCTAssertEqual(totalDropped, 6, "Should have 6 dropped messages total")
    }
    
 /// Test that disconnect is triggered at exact threshold
    func testDisconnectAtExactThreshold() async throws {
        let threshold = 10
        let limits = createTestLimits(
            rate: 0.001, // Essentially no refill
            burst: 1,
            threshold: threshold,
            window: 60.0 // Long window to ensure all drops count
        )
        
        let limiter = makeLimiter(limits: limits, connectionId: "test")
        
 // Consume the single token
        _ = await limiter.shouldProcess()
        
 // Drop exactly threshold - 1 messages
        for i in 0..<(threshold - 1) {
            let decision = await limiter.shouldProcess()
            XCTAssertEqual(decision, .drop, "Request \(i + 1) should be dropped")
        }
        
 // The threshold-th drop should trigger disconnect
        let finalDecision = await limiter.shouldProcess()
        if case .disconnect = finalDecision {
 // Expected
        } else {
            XCTFail("Expected disconnect at threshold, got \(finalDecision)")
        }
    }
    
 /// Test that old drops outside window don't count toward threshold
    func testSlidingWindowExpiration() async throws {
        let threshold = 5
        let windowSeconds = 0.1 // 100ms window
        
        let limits = createTestLimits(
            rate: 0.001,
            burst: 1,
            threshold: threshold,
            window: windowSeconds
        )
        
        let clock = ManualRateLimiterClock()
        let limiter = makeLimiter(limits: limits, connectionId: "test", clock: clock)
        
 // Consume token
        _ = await limiter.shouldProcess()
        
 // Drop some messages (less than threshold)
        for _ in 0..<3 {
            _ = await limiter.shouldProcess()
        }
        
 // Advance past the exact monotonic-window boundary without wall-clock sleep.
        clock.advance(by: .milliseconds(101))
        
 // Drops in window should be 0 now
        let dropsInWindow = await limiter.droppedInWindow
        XCTAssertEqual(dropsInWindow, 0, "Drops should have expired from window")
        
 // Total dropped count should still reflect all drops
        let totalDropped = await limiter.droppedMessageCount
        XCTAssertEqual(totalDropped, 3, "Total dropped should still be 3")
    }

 /// The drop window is inclusive at the exact cutoff and expires immediately after it.
    func testSlidingWindowExactCutoff() async throws {
        let limits = createTestLimits(
            rate: 1.0,
            burst: 1,
            threshold: 5,
            window: 0.1
        )
        let clock = ManualRateLimiterClock()
        let limiter = makeLimiter(limits: limits, connectionId: "cutoff", clock: clock)

        _ = await limiter.recordDropped()
        clock.advance(by: .milliseconds(100))
        let atCutoff = await limiter.droppedInWindow
        XCTAssertEqual(atCutoff, 1, "A drop exactly at the cutoff remains in the window")

        clock.advance(by: .nanoseconds(1))
        let afterCutoff = await limiter.droppedInWindow
        XCTAssertEqual(afterCutoff, 0, "A drop expires immediately after the cutoff")
    }
    
 /// Test that multiple connections have independent drop tracking
    func testIndependentDropTracking() async throws {
        let limits = createTestLimits(
            rate: 0.001,
            burst: 1,
            threshold: 100,
            window: 10.0
        )
        
        let clock = ManualRateLimiterClock()
        let limiter1 = makeLimiter(limits: limits, connectionId: "conn1", clock: clock)
        let limiter2 = makeLimiter(limits: limits, connectionId: "conn2", clock: clock)
        
 // Exhaust and drop on limiter1
        _ = await limiter1.shouldProcess()
        for _ in 0..<5 {
            _ = await limiter1.shouldProcess()
        }
        
 // limiter1 should have drops
        let limiter1Drops = await limiter1.droppedMessageCount
        XCTAssertEqual(limiter1Drops, 5, "Limiter1 should have 5 drops")
        
 // limiter2 should have no drops
        let limiter2Drops = await limiter2.droppedMessageCount
        XCTAssertEqual(limiter2Drops, 0, "Limiter2 should have 0 drops")
        
 // limiter2 should still allow (has full token bucket)
        let limiter2Decision = await limiter2.shouldProcess()
        XCTAssertEqual(limiter2Decision, .allow, "Limiter2 should allow")
    }
    
 /// Test reset functionality
    func testReset() async throws {
        let limits = createTestLimits(
            rate: 0.001,
            burst: 1,
            threshold: 100,
            window: 10.0
        )
        
        let limiter = makeLimiter(limits: limits, connectionId: "test")
        
 // Exhaust and drop
        _ = await limiter.shouldProcess()
        for _ in 0..<5 {
            _ = await limiter.shouldProcess()
        }
        
 // Verify drops
        let beforeReset = await limiter.droppedMessageCount
        XCTAssertEqual(beforeReset, 5, "Should have 5 drops before reset")
        
 // Reset
        await limiter.reset()
        
 // Drops should be cleared
        let afterReset = await limiter.droppedMessageCount
        XCTAssertEqual(afterReset, 0, "Drops should be 0 after reset")
        
 // Should be able to process again
        let decision = await limiter.shouldProcess()
        XCTAssertEqual(decision, .allow, "Should allow after reset")
    }
    
 /// Test recordDropped for external drops (e.g., oversized messages)
    func testRecordDroppedExternal() async throws {
        let limits = createTestLimits(
            rate: 100.0,
            burst: 100,
            threshold: 5,
            window: 10.0
        )
        
        let limiter = makeLimiter(limits: limits, connectionId: "test")
        
 // External drops must return `.drop` until the exact disconnect threshold.
        for _ in 0..<4 {
            let decision = await limiter.recordDropped()
            XCTAssertEqual(decision, .drop)
        }
        
        let drops = await limiter.droppedMessageCount
        XCTAssertEqual(drops, 4, "Should have 4 external drops recorded")
        
 // The threshold-th external drop must itself request immediate disconnect.
        let thresholdDecision = await limiter.recordDropped()
        if case .disconnect(let reason) = thresholdDecision {
            XCTAssertTrue(reason.contains("5"))
        } else {
            XCTFail("Expected external drop at threshold to disconnect, got \(thresholdDecision)")
        }
    }
    
 /// Test factory creates independent limiters
    func testFactory() async throws {
        let factory = ConnectionRateLimiterFactory(limits: .default)
        
        let limiter1 = factory.create(connectionId: "conn1")
        let limiter2 = factory.create(connectionId: "conn2")
        let limiter3 = factory.create() // Auto-generated ID
        
 // All should be independent
        XCTAssertEqual(limiter1.connectionId, "conn1")
        XCTAssertEqual(limiter2.connectionId, "conn2")
        XCTAssertNotEqual(limiter3.connectionId, "conn1")
        XCTAssertNotEqual(limiter3.connectionId, "conn2")
    }
    
 // MARK: - Helper Methods

    private func makeLimiter(
        limits: SecurityLimits,
        connectionId: String,
        clock: ManualRateLimiterClock = ManualRateLimiterClock()
    ) -> ConnectionRateLimiter {
        return ConnectionRateLimiter(
            limits: limits,
            connectionId: connectionId,
            now: { clock.currentInstant() }
        )
    }
    
    private func createTestLimits(
        rate: Double,
        burst: Int,
        threshold: Int,
        window: Double
    ) -> SecurityLimits {
        return SecurityLimits(
            maxTotalFiles: 10_000,
            maxTotalBytes: 50 * 1024 * 1024 * 1024,
            globalTimeout: 300.0,
            maxRegexPatternLength: 1000,
            maxRegexPatternCount: 100,
            maxRegexGroups: 10,
            maxRegexQuantifiers: 20,
            maxRegexAlternations: 10,
            maxRegexLookaheads: 3,
            perPatternTimeout: 0.05,
            perPatternInputLimit: 1024 * 1024,
            maxTotalHistoryBytes: 10 * 1024 * 1024,
            tokenBucketRate: rate,
            tokenBucketBurst: burst,
            maxMessageBytes: 64 * 1024,
            decodeDepthLimit: 10,
            decodeArrayLengthLimit: 1000,
            decodeStringLengthLimit: 64 * 1024,
            droppedMessagesThreshold: threshold,
            droppedMessagesWindow: window,
            pakeRecordTTL: 600.0,
            pakeMaxRecords: 10_000,
            pakeCleanupInterval: 128,
            maxSymlinkDepth: 10,
            maxRetryCount: 20,
            maxRetryDelay: 300.0,
            maxExtractedFiles: 1000,
            maxTotalExtractedBytes: 500 * 1024 * 1024,
            maxNestingDepth: 3,
            maxCompressionRatio: 100.0,
            maxExtractionTime: 10.0,
            maxBytesPerFile: 100 * 1024 * 1024,
            largeFileThreshold: 500 * 1024 * 1024,
            hashTimeoutQuick: 2.0,
            hashTimeoutStandard: 5.0,
            hashTimeoutDeep: 10.0,
            maxEventQueueSize: 10_000,
            maxPendingPerSubscriber: 1_000
        )
    }
}
