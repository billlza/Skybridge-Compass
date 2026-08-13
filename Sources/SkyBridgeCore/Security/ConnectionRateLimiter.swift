// MARK: - ConnectionRateLimiter.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Rate limit decision for message processing.
public enum RateLimitDecision: Sendable, Equatable {
 /// Message should be processed normally
    case allow
 /// Message should be dropped (rate limited)
    case drop
 /// Connection should be disconnected due to excessive drops
    case disconnect(reason: String)
}

/// Dropped message record for sliding window tracking.
private struct DroppedMessageRecord: Sendable {
    let timestamp: ContinuousClock.Instant
    let count: Int
}

/// Connection-level rate limiter combining token bucket with disconnect threshold.
///
/// Tracks dropped messages in a sliding window and triggers disconnect
/// when the threshold is exceeded.
///
/// **Implementation per design doc:**
/// - Uses TokenBucketLimiter for per-message rate limiting
/// - Tracks dropped messages in sliding window using monotonic clock
/// - Disconnects when droppedMessagesThreshold exceeded in droppedMessagesWindow
///
/// **Validates: Requirements 4.2, 4.6, 4.7**
public actor ConnectionRateLimiter {
    
 // MARK: - Configuration
    
    private let limits: SecurityLimits
    
 // MARK: - State
    
 /// Token bucket for rate limiting
    private let tokenBucket: TokenBucketLimiter

 /// Monotonic time source shared with the bucket in deterministic tests.
    private let now: @Sendable () -> ContinuousClock.Instant
    
 /// Sliding window of dropped message records
    private var droppedMessages: [DroppedMessageRecord] = []
    
 /// Total dropped message count (for monitoring)
    private var totalDroppedCount: Int = 0
    
 /// Connection identifier (for logging/events)
 /// Nonisolated since it's immutable after initialization
    public nonisolated let connectionId: String
    
 // MARK: - Initialization
    
 /// Initialize a connection rate limiter.
 ///
 /// - Parameters:
 /// - limits: Security limits configuration
 /// - connectionId: Unique identifier for this connection
    public init(limits: SecurityLimits, connectionId: String) {
        self.init(
            limits: limits,
            connectionId: connectionId,
            now: { ContinuousClock.now }
        )
    }
    
 /// Initialize with a custom monotonic time source for deterministic tests.
 ///
 /// - Parameters:
 /// - limits: Security limits configuration
 /// - connectionId: Unique identifier for this connection
 /// - now: Monotonic time source shared by token refill and drop-window tracking
    internal init(
        limits: SecurityLimits,
        connectionId: String,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        precondition(
            limits.droppedMessagesThreshold > 0,
            "Dropped-message threshold must be positive"
        )
        precondition(
            limits.droppedMessagesWindow.isFinite && limits.droppedMessagesWindow > 0,
            "Dropped-message window must be finite and positive"
        )
        self.limits = limits
        self.connectionId = connectionId
        self.tokenBucket = TokenBucketLimiter(limits: limits, now: now)
        self.now = now
    }
    
 // MARK: - Public Interface
    
 /// Check if a message should be processed.
 ///
 /// - Returns: Decision on how to handle the message
    public func shouldProcess() async -> RateLimitDecision {
 // First check token bucket
        let allowed = await tokenBucket.tryConsume()
        
        if allowed {
            return .allow
        }
        
 // Message will be dropped - record it
        return recordDropped()
    }
    
 /// Record an externally rejected message and return the resulting policy decision.
 ///
 /// Callers must apply `.disconnect` immediately so malformed messages cannot
 /// bypass the sliding-window threshold while remaining below the token rate.
    public func recordDropped() -> RateLimitDecision {
        let currentInstant = now()
        droppedMessages.append(DroppedMessageRecord(timestamp: currentInstant, count: 1))
        totalDroppedCount += 1
        
 // Prune old records outside the window
        pruneOldRecords(now: currentInstant)

        if shouldDisconnect() {
            return .disconnect(reason: disconnectReason)
        }
        return .drop
    }
    
 /// Get total dropped message count (for monitoring).
    public var droppedMessageCount: Int {
        return totalDroppedCount
    }
    
 /// Get dropped messages in current window (for monitoring).
    public var droppedInWindow: Int {
        pruneOldRecords(now: now())
        return droppedMessages.reduce(0) { $0 + $1.count }
    }
    
 /// Get available tokens (for monitoring).
    public var availableTokens: Double {
        get async {
            return await tokenBucket.availableTokens
        }
    }
    
 /// Reset the rate limiter state.
    public func reset() async {
        await tokenBucket.reset()
        droppedMessages.removeAll()
        totalDroppedCount = 0
    }
    
 // MARK: - Private Methods
    
 /// Check if connection should be disconnected based on dropped message threshold.
    private func shouldDisconnect() -> Bool {
        let droppedInCurrentWindow = droppedMessages.reduce(0) { $0 + $1.count }
        return droppedInCurrentWindow >= limits.droppedMessagesThreshold
    }

    private var disconnectReason: String {
        "Exceeded \(limits.droppedMessagesThreshold) dropped messages in " +
        "\(limits.droppedMessagesWindow)s window"
    }
    
 /// Remove records outside the sliding window.
    private func pruneOldRecords(now: ContinuousClock.Instant) {
        let windowDuration = Duration.seconds(limits.droppedMessagesWindow)
        let cutoff = now - windowDuration
        
        droppedMessages.removeAll { record in
            record.timestamp < cutoff
        }
    }
}

// MARK: - ConnectionRateLimiterFactory

/// Factory for creating connection rate limiters.
public struct ConnectionRateLimiterFactory: Sendable {
    
    private let limits: SecurityLimits
    
 /// Initialize factory with security limits.
 ///
 /// - Parameter limits: Security limits configuration
    public init(limits: SecurityLimits = .default) {
        self.limits = limits
    }
    
 /// Create a new rate limiter for a connection.
 ///
 /// - Parameter connectionId: Unique identifier for the connection
 /// - Returns: New ConnectionRateLimiter instance
    public func create(connectionId: String) -> ConnectionRateLimiter {
        return ConnectionRateLimiter(limits: limits, connectionId: connectionId)
    }
    
 /// Create a new rate limiter with auto-generated connection ID.
 ///
 /// - Returns: New ConnectionRateLimiter instance with UUID-based connection ID
    public func create() -> ConnectionRateLimiter {
        return ConnectionRateLimiter(limits: limits, connectionId: UUID().uuidString)
    }
}
