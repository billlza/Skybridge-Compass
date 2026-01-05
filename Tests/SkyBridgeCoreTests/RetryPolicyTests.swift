//
// RetryPolicyTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for RetryPolicy security hardening
// **Feature: security-hardening**
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Property Test: Retry Delay Bounds
// **Feature: security-hardening, Property 19: Retry delay bounds**
// **Validates: Requirements 10.1, 10.2, 10.3, 10.4, 10.5**

final class RetryPolicyTests: XCTestCase {
    
 /// **Feature: security-hardening, Property 19: Retry delay bounds**
 /// **Validates: Requirements 10.1, 10.2, 10.3, 10.4, 10.5**
 ///
 /// Property: *For any* retryCount (including negative, large, or overflow-inducing values),
 /// the calculated delay SHALL be in range [0, maxDelay].
 ///
 /// This test verifies:
 /// 1. Requirement 10.1: retryCount is clamped to maxRetryCount
 /// 2. Requirement 10.2: Calculated delay never exceeds maxDelay
 /// 3. Requirement 10.3: pow() overflow returns maxDelay
 /// 4. Requirement 10.4: Negative retryCount is treated as 0
 /// 5. Requirement 10.5: Jitter does not cause delay to exceed maxDelay
    func testProperty_RetryDelayBounds() {
 // Run 100 iterations with different random configurations
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate random policy configuration within valid bounds
            let initialDelay = TimeInterval.random(in: 0.1...10.0)
            let maxDelay = TimeInterval.random(in: initialDelay...300.0)
            let backoffMultiplier = Double.random(in: 1.5...3.0)
            let maxRetryCount = Int.random(in: 5...30)
            let jitterFactor = Double.random(in: 0.0...0.5)
            let jitterEnabled = Bool.random()
            
            let policy = RetryPolicy(
                maxAttempts: maxRetryCount,
                initialDelay: initialDelay,
                maxDelay: maxDelay,
                backoffMultiplier: backoffMultiplier,
                jitterEnabled: jitterEnabled,
                maxRetryCount: maxRetryCount,
                jitterFactor: jitterFactor
            )
            
 // Test with various retryCount values including edge cases
            let testCounts: [Int] = [
                -1000,           // Large negative
                -1,              // Small negative
                0,               // Zero
                1,               // Small positive
                maxRetryCount / 2,  // Mid-range
                maxRetryCount,   // At limit
                maxRetryCount + 1,  // Just over limit
                maxRetryCount * 2,  // Well over limit
                Int.max / 2,     // Large positive (potential overflow)
                Int.max          // Maximum int (definite overflow)
            ]
            
            for retryCount in testCounts {
                let delay = policy.delay(for: retryCount)
                
 // Property: delay must be in [0, maxDelay]
                XCTAssertGreaterThanOrEqual(
                    delay, 0,
                    "Iteration \(iteration), retryCount \(retryCount): delay (\(delay)) must be >= 0"
                )
                XCTAssertLessThanOrEqual(
                    delay, maxDelay,
                    "Iteration \(iteration), retryCount \(retryCount): delay (\(delay)) must be <= maxDelay (\(maxDelay))"
                )
                
 // Property: delay must be finite
                XCTAssertTrue(
                    delay.isFinite,
                    "Iteration \(iteration), retryCount \(retryCount): delay must be finite"
                )
            }
        }
    }
    
 /// Test that negative retryCount is treated as 0 (Requirement 10.4)
    func testNegativeRetryCountTreatedAsZero() {
        let policy = RetryPolicy(
            maxAttempts: 10,
            initialDelay: 1.0,
            maxDelay: 300.0,
            backoffMultiplier: 2.0,
            jitterEnabled: false,
            maxRetryCount: 20,
            jitterFactor: 0.0
        )
        
 // With jitter disabled and factor 0, delay for count 0 should be initialDelay
        let delayForZero = policy.delay(for: 0)
        let delayForNegative = policy.delay(for: -1)
        let delayForLargeNegative = policy.delay(for: -1000)
        
 // All negative values should produce the same delay as 0
        XCTAssertEqual(delayForZero, delayForNegative, "Negative retryCount should be treated as 0")
        XCTAssertEqual(delayForZero, delayForLargeNegative, "Large negative retryCount should be treated as 0")
        XCTAssertEqual(delayForZero, 1.0, "Delay for count 0 should be initialDelay (1.0)")
    }
    
 /// Test that retryCount is clamped to maxRetryCount (Requirement 10.1)
    func testRetryCountClampedToMax() {
        let maxRetryCount = 5
        let policy = RetryPolicy(
            maxAttempts: 10,
            initialDelay: 1.0,
            maxDelay: 1000.0, // High maxDelay to not interfere
            backoffMultiplier: 2.0,
            jitterEnabled: false,
            maxRetryCount: maxRetryCount,
            jitterFactor: 0.0
        )
        
 // Delay at maxRetryCount
        let delayAtMax = policy.delay(for: maxRetryCount)
        
 // Delay beyond maxRetryCount should be same as at maxRetryCount
        let delayBeyondMax = policy.delay(for: maxRetryCount + 1)
        let delayWayBeyondMax = policy.delay(for: maxRetryCount * 10)
        
        XCTAssertEqual(delayAtMax, delayBeyondMax, "Delay beyond maxRetryCount should equal delay at maxRetryCount")
        XCTAssertEqual(delayAtMax, delayWayBeyondMax, "Delay way beyond maxRetryCount should equal delay at maxRetryCount")
    }
    
 /// Test overflow protection (Requirements 10.2, 10.3)
    func testOverflowProtection() {
 // Test with a policy that allows overflow by having very high maxRetryCount
 // With multiplier 2.0 and count 1100, pow(2.0, 1100) will overflow to infinity
        let overflowPolicy = RetryPolicy(
            maxAttempts: 2000,
            initialDelay: 1.0,
            maxDelay: 300.0,
            backoffMultiplier: 2.0,
            jitterEnabled: false,
            maxRetryCount: 2000, // Very high to allow overflow
            jitterFactor: 0.0
        )
        
 // pow(2.0, 1100) will overflow to infinity
        let delayForOverflow = overflowPolicy.delay(for: 1100)
        
 // Should return maxDelay on overflow
        XCTAssertEqual(delayForOverflow, 300.0, "Overflow should return maxDelay")
        XCTAssertTrue(delayForOverflow.isFinite, "Delay must be finite even on overflow")
    }
    
 /// Test that jitter never causes delay to exceed maxDelay (Requirement 10.5)
    func testJitterNeverExceedsMaxDelay() {
        let maxDelay = 10.0
        let policy = RetryPolicy(
            maxAttempts: 10,
            initialDelay: 9.0, // Close to maxDelay
            maxDelay: maxDelay,
            backoffMultiplier: 1.1, // Small multiplier
            jitterEnabled: true,
            maxRetryCount: 20,
            jitterFactor: 0.5 // Large jitter factor
        )
        
 // Run many iterations to test jitter randomness
        for _ in 0..<1000 {
            for retryCount in 0...10 {
                let delay = policy.delay(for: retryCount)
                XCTAssertLessThanOrEqual(
                    delay, maxDelay,
                    "Jitter must not cause delay to exceed maxDelay"
                )
                XCTAssertGreaterThanOrEqual(
                    delay, 0,
                    "Jitter must not cause delay to go negative"
                )
            }
        }
    }
    
 /// Test exponential backoff calculation correctness
    func testExponentialBackoffCalculation() {
        let policy = RetryPolicy(
            maxAttempts: 10,
            initialDelay: 1.0,
            maxDelay: 1000.0,
            backoffMultiplier: 2.0,
            jitterEnabled: false,
            maxRetryCount: 20,
            jitterFactor: 0.0
        )
        
 // Without jitter, delays should follow exponential pattern
 // delay(0) = 1.0 * 2^0 = 1.0
 // delay(1) = 1.0 * 2^1 = 2.0
 // delay(2) = 1.0 * 2^2 = 4.0
 // delay(3) = 1.0 * 2^3 = 8.0
        
        XCTAssertEqual(policy.delay(for: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 1), 2.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 2), 4.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 3), 8.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 4), 16.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 5), 32.0, accuracy: 0.001)
    }
    
 /// Test that delay is capped at maxDelay
    func testDelayCapAtMaxDelay() {
        let maxDelay = 30.0
        let policy = RetryPolicy(
            maxAttempts: 10,
            initialDelay: 1.0,
            maxDelay: maxDelay,
            backoffMultiplier: 2.0,
            jitterEnabled: false,
            maxRetryCount: 20,
            jitterFactor: 0.0
        )
        
 // delay(5) = 32.0 which exceeds maxDelay of 30.0
        let delay5 = policy.delay(for: 5)
        XCTAssertEqual(delay5, maxDelay, "Delay should be capped at maxDelay")
        
 // Higher counts should also be capped
        let delay10 = policy.delay(for: 10)
        XCTAssertEqual(delay10, maxDelay, "Higher retry counts should also be capped at maxDelay")
    }
    
 /// Property test with random inputs to ensure bounds are always respected
    func testProperty_RandomInputsBoundsRespected() {
 // Run 100 iterations
        for _ in 0..<100 {
 // Random policy parameters
            let initialDelay = TimeInterval.random(in: 0.001...100.0)
            let maxDelay = TimeInterval.random(in: initialDelay...1000.0)
            let backoffMultiplier = Double.random(in: 1.0...10.0)
            let maxRetryCount = Int.random(in: 1...100)
            let jitterFactor = Double.random(in: 0.0...1.0)
            
            let policy = RetryPolicy(
                maxAttempts: maxRetryCount,
                initialDelay: initialDelay,
                maxDelay: maxDelay,
                backoffMultiplier: backoffMultiplier,
                jitterEnabled: true,
                maxRetryCount: maxRetryCount,
                jitterFactor: jitterFactor
            )
            
 // Random retry count (including edge cases)
            let retryCount = Int.random(in: Int.min...Int.max)
            let delay = policy.delay(for: retryCount)
            
 // Invariant: delay must always be in [0, maxDelay] and finite
            XCTAssertGreaterThanOrEqual(delay, 0, "Delay must be >= 0")
            XCTAssertLessThanOrEqual(delay, maxDelay, "Delay must be <= maxDelay")
            XCTAssertTrue(delay.isFinite, "Delay must be finite")
        }
    }
}
