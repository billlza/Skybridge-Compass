// MARK: - TokenBucketLimiter.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Token Bucket Rate Limiter using actor isolation for thread safety.
///
/// Implements the token bucket algorithm for rate limiting:
/// - Tokens are refilled at a constant rate up to a maximum burst capacity
/// - Each operation consumes one token
/// - Operations are rejected when no tokens are available
///
/// Uses ContinuousClock for monotonic time measurement (immune to system clock changes).
///
/// **Implementation constraints (per design doc):**
/// - Refill clamps tokens to burst capacity (no accumulation beyond burst)
/// - Consumption check uses >= 1.0 to avoid floating-point precision issues
///
/// **Validates: Requirements 4.1**
public actor TokenBucketLimiter {

    private static let maximumExactlyRepresentableTokenCount = 9_007_199_254_740_992
    
 // MARK: - Configuration
    
 /// Token refill rate (tokens per second)
    private let rate: Double
    
 /// Maximum token capacity (burst limit)
    private let burst: Int

 /// Monotonic time source. Production always uses `ContinuousClock`; the
 /// internal injection point keeps elapsed-time tests deterministic.
    private let now: @Sendable () -> ContinuousClock.Instant
    
 // MARK: - State
    
 /// Current available tokens (floating point for fractional refill)
    private var tokens: Double
    
 /// Last refill timestamp using monotonic clock
    private var lastRefill: ContinuousClock.Instant
    
 // MARK: - Initialization
    
 /// Initialize a token bucket rate limiter.
 ///
 /// - Parameters:
 /// - rate: Token refill rate in tokens per second
 /// - burst: Maximum token capacity (burst limit)
    public init(rate: Double, burst: Int) {
        self.init(rate: rate, burst: burst, now: { ContinuousClock.now })
    }

 /// Internal initializer for deterministic elapsed-time tests.
    internal init(
        rate: Double,
        burst: Int,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        precondition(rate.isFinite && rate > 0, "Rate must be finite and positive")
        precondition(burst > 0, "Burst must be positive")
        precondition(
            burst <= Self.maximumExactlyRepresentableTokenCount,
            "Burst exceeds exact token-count precision"
        )

        self.rate = rate
        self.burst = burst
        self.now = now
        self.tokens = Double(burst) // Start with full bucket
        self.lastRefill = now()
    }
    
 /// Initialize from SecurityLimits configuration.
 ///
 /// - Parameter limits: Security limits configuration
    public init(limits: SecurityLimits) {
        self.init(limits: limits, now: { ContinuousClock.now })
    }

 /// Internal configuration initializer for deterministic elapsed-time tests.
    internal init(
        limits: SecurityLimits,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.init(
            rate: limits.tokenBucketRate,
            burst: limits.tokenBucketBurst,
            now: now
        )
    }
    
 // MARK: - Public Interface
    
 /// Attempt to consume one token.
 ///
 /// - Returns: `true` if token was consumed (operation allowed),
 /// `false` if rate limited (no tokens available)
    public func tryConsume() -> Bool {
        refill()
        
 // Use >= 1.0 to avoid floating-point precision issues ("ghost tokens")
        if tokens >= 1.0 {
            tokens -= 1.0
            return true
        }
        return false
    }
    
 /// Attempt to consume multiple tokens.
 ///
 /// - Parameter count: Number of tokens to consume
 /// - Precondition: `count` must be non-negative
 /// - Returns: `true` if all tokens were consumed, `false` if rate limited
    public func tryConsume(count: Int) -> Bool {
        precondition(count >= 0, "Token count must not be negative")
        guard count > 0 else { return true }
        
        refill()

 // A bucket can never satisfy a request larger than its configured capacity.
        guard count <= burst else { return false }
        
        let required = Double(count)
        if tokens >= required {
            tokens -= required
            return true
        }
        return false
    }
    
 /// Get current available tokens (for monitoring/testing).
    public var availableTokens: Double {
        refill()
 // This is an up-to-date snapshot at the actor-isolated query instant.
        return tokens
    }
    
 /// Get current available tokens as integer (for monitoring).
    public var availableTokensInt: Int {
        refill()
        return Int(tokens)
    }
    
 /// Reset the bucket to full capacity.
    public func reset() {
        tokens = Double(burst)
        lastRefill = now()
    }
    
 // MARK: - Private Methods
    
 /// Refill tokens based on elapsed time since last refill.
 /// Clamps to burst capacity to prevent unbounded accumulation.
    private func refill() {
        let currentInstant = now()
        precondition(currentInstant >= lastRefill, "Monotonic clock moved backwards")
        let elapsed = currentInstant - lastRefill
        
 // Convert Duration to seconds
        let elapsedSeconds = Double(elapsed.components.seconds) +
                            Double(elapsed.components.attoseconds) / 1e18
        
 // Calculate new tokens to add
        let newTokens = elapsedSeconds * rate
        
 // Clamp to burst capacity (critical: prevents unbounded accumulation)
        tokens = min(Double(burst), tokens + newTokens)
        
        lastRefill = currentInstant
    }
}
