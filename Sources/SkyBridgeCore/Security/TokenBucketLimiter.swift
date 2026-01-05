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
    
 // MARK: - Configuration
    
 /// Token refill rate (tokens per second)
    private let rate: Double
    
 /// Maximum token capacity (burst limit)
    private let burst: Int
    
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
        precondition(rate > 0, "Rate must be positive")
        precondition(burst > 0, "Burst must be positive")
        
        self.rate = rate
        self.burst = burst
        self.tokens = Double(burst) // Start with full bucket
        self.lastRefill = ContinuousClock.now
    }
    
 /// Initialize from SecurityLimits configuration.
 ///
 /// - Parameter limits: Security limits configuration
    public init(limits: SecurityLimits) {
        self.rate = limits.tokenBucketRate
        self.burst = limits.tokenBucketBurst
        self.tokens = Double(limits.tokenBucketBurst)
        self.lastRefill = ContinuousClock.now
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
 /// - Returns: `true` if all tokens were consumed, `false` if rate limited
    public func tryConsume(count: Int) -> Bool {
        guard count > 0 else { return true }
        
        refill()
        
        let required = Double(count)
        if tokens >= required {
            tokens -= required
            return true
        }
        return false
    }
    
 /// Get current available tokens (for monitoring/testing).
    public var availableTokens: Double {
 // Note: This is a snapshot, may be stale immediately after return
        return tokens
    }
    
 /// Get current available tokens as integer (for monitoring).
    public var availableTokensInt: Int {
        return Int(tokens)
    }
    
 /// Reset the bucket to full capacity.
    public func reset() {
        tokens = Double(burst)
        lastRefill = ContinuousClock.now
    }
    
 // MARK: - Private Methods
    
 /// Refill tokens based on elapsed time since last refill.
 /// Clamps to burst capacity to prevent unbounded accumulation.
    private func refill() {
        let now = ContinuousClock.now
        let elapsed = now - lastRefill
        
 // Convert Duration to seconds
        let elapsedSeconds = Double(elapsed.components.seconds) +
                            Double(elapsed.components.attoseconds) / 1e18
        
 // Calculate new tokens to add
        let newTokens = elapsedSeconds * rate
        
 // Clamp to burst capacity (critical: prevents unbounded accumulation)
        tokens = min(Double(burst), tokens + newTokens)
        
        lastRefill = now
    }
}
