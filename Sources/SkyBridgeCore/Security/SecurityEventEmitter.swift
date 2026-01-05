// MARK: - SecurityEventEmitter.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Unified security event emitter with backpressure handling.
///
/// Key features:
/// - Actor-isolated for thread safety
/// - Bounded queue with overflow handling
/// - Per-subscriber FIFO delivery via SubscriberActor
/// - Meta-event bypass path to prevent recursion
///
/// **Meta-event Recursion Prevention (Critical)**:
/// When the queue is full, a `.limitExceeded` meta-event is emitted.
/// This meta-event MUST bypass the normal queue to prevent infinite recursion:
/// 1. Meta-events are delivered directly to subscribers (not queued)
/// 2. Meta-events are rate-limited (max 1 per second)
/// 3. Meta-events are marked with `isMetaEvent = true`
public actor SecurityEventEmitter {
    
 // MARK: - Singleton
    
 /// Shared instance for global event emission
    public static let shared = SecurityEventEmitter()
    
 // MARK: - Configuration
    
 /// Maximum events in the main queue
    private let maxQueueSize: Int
    
 /// Maximum pending events per subscriber
    private let maxPendingPerSubscriber: Int
    
 /// Minimum interval between meta-events (rate limiting)
    private let metaEventMinInterval: Duration = .seconds(1)
    
 // MARK: - State
    
 /// Main event queue
    private var queuedEvents: [SecurityEvent] = []
    
 /// Last time a meta-event was emitted (for rate limiting)
    private var lastOverflowMetaEventTime: ContinuousClock.Instant?
    
 /// Registered subscribers
    private var subscribers: [UUID: SubscriberActor] = [:]
    
 /// Count of dropped events since last meta-event
    private var droppedSinceLastMetaEvent: Int = 0
    
 // MARK: - Initialization
    
 /// Initialize with custom limits (primarily for testing)
    public init(
        maxQueueSize: Int = SecurityLimits.default.maxEventQueueSize,
        maxPendingPerSubscriber: Int = SecurityLimits.default.maxPendingPerSubscriber
    ) {
        self.maxQueueSize = maxQueueSize
        self.maxPendingPerSubscriber = maxPendingPerSubscriber
    }
    
 // MARK: - Public API
    
 /// Emit a security event asynchronously (actor-isolated).
 ///
 /// Backpressure strategy:
 /// - When queue is full, new events are dropped (oldest preserved)
 /// - A meta-event (`.limitExceeded`) is triggered via bypass path
 /// - Meta-events are rate-limited: max 1 per second
 ///
 /// - Parameter event: The security event to emit
    public func emit(_ event: SecurityEvent) async {
 // Meta-events bypass the queue entirely
        if event.isMetaEvent {
            await deliverToAllSubscribersDirect(event)
            return
        }
        
 // Check queue capacity
        if queuedEvents.count >= maxQueueSize {
            droppedSinceLastMetaEvent += 1
            await emitOverflowMetaEventIfNeeded()
            return
        }
        
 // Add to queue
        queuedEvents.append(event)
        
 // Deliver to all subscribers
        await deliverToAllSubscribers(event)
    }
    
 /// Synchronous fire-and-forget interface for sync contexts.
 /// Spawns a detached to enter the actor.
 ///
 /// Use this when emitting from synchronous code (e.g., SignatureDBKeyManager.verify).
 ///
 /// - Parameter event: The security event to emit
    public nonisolated static func emitDetached(_ event: SecurityEvent) {
        Task.detached {
            await shared.emit(event)
        }
    }
    
 /// Subscribe to security events.
 ///
 /// Fan-out delivery strategy:
 /// - Each subscriber has its own SubscriberActor for serial FIFO delivery
 /// - Slow subscribers don't block others or the main queue
 /// - Per-subscriber queue overflow triggers meta-event (rate-limited)
 /// - UI subscribers should switch to @MainActor in their handler
 ///
 /// - Parameter handler: Async handler called for each event
 /// - Returns: Subscription ID for unsubscribing
    @discardableResult
    public func subscribe(
        _ handler: @escaping @Sendable (SecurityEvent) async -> Void
    ) -> UUID {
        let id = UUID()
        let subscriberActor = SubscriberActor(
            id: id,
            handler: handler,
            maxPending: maxPendingPerSubscriber,
            emitter: self
        )
        subscribers[id] = subscriberActor
        return id
    }
    
 /// Unsubscribe from security events.
 ///
 /// - Parameter id: The subscription ID returned from subscribe()
    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
    
 /// Get current queue size (for monitoring/testing)
    public var currentQueueSize: Int {
        queuedEvents.count
    }
    
 /// Get subscriber count (for monitoring/testing)
    public var subscriberCount: Int {
        subscribers.count
    }

    
 // MARK: - Internal Methods
    
 /// Called by SubscriberActor when its queue overflows
    internal func notifySubscriberOverflow(subscriberId: UUID, droppedCount: Int) async {
        await emitOverflowMetaEventIfNeeded(queueType: "subscriber_\(subscriberId.uuidString.prefix(8))")
    }
    
 // MARK: - Private Methods
    
 /// Deliver event to all subscribers (normal path - queued)
    private func deliverToAllSubscribers(_ event: SecurityEvent) async {
        for (_, subscriber) in subscribers {
            await subscriber.enqueue(event)
        }
    }
    
 /// Deliver event directly to all subscribers (bypass path for meta-events)
    private func deliverToAllSubscribersDirect(_ event: SecurityEvent) async {
        for (_, subscriber) in subscribers {
            await subscriber.deliverDirect(event)
        }
    }
    
 /// Emit overflow meta-event if rate limit allows
    private func emitOverflowMetaEventIfNeeded(queueType: String = "main") async {
        let now = ContinuousClock.now
        
 // Check rate limit
        if let lastTime = lastOverflowMetaEventTime {
            let elapsed = now - lastTime
            if elapsed < metaEventMinInterval {
 // Rate limited - don't emit
                return
            }
        }
        
 // Update timestamp
        lastOverflowMetaEventTime = now
        
 // Create and deliver meta-event directly (bypass queue)
        let metaEvent = SecurityEvent.queueOverflow(
            queueType: queueType,
            droppedCount: droppedSinceLastMetaEvent
        )
        
 // Reset counter
        droppedSinceLastMetaEvent = 0
        
 // Deliver directly to all subscribers
        await deliverToAllSubscribersDirect(metaEvent)
    }
    
 /// Clear all queued events (for testing)
    internal func clearQueue() {
        queuedEvents.removeAll()
        droppedSinceLastMetaEvent = 0
    }
    
 /// Clear all subscribers (for testing)
    internal func clearSubscribers() {
        subscribers.removeAll()
    }
}

// MARK: - SubscriberActor

/// Per-subscriber actor for serial FIFO event delivery.
///
/// Each subscriber gets its own actor to ensure:
/// - Serial delivery (events processed in order)
/// - Isolation (slow subscribers don't affect others)
/// - Bounded queue (overflow triggers meta-event)
internal actor SubscriberActor {
    
 // MARK: - Properties
    
 /// Unique identifier for this subscriber
    private let id: UUID
    
 /// The event handler
    private let handler: @Sendable (SecurityEvent) async -> Void
    
 /// Maximum pending events
    private let maxPending: Int
    
 /// Reference to emitter for overflow notification
    private weak var emitter: SecurityEventEmitter?
    
 /// Pending events queue
    private var pendingEvents: [SecurityEvent] = []
    
 /// Whether we're currently processing the queue
    private var isProcessing: Bool = false
    
 /// Count of dropped events (for overflow notification)
    private var droppedCount: Int = 0
    
 // MARK: - Initialization
    
    init(
        id: UUID,
        handler: @escaping @Sendable (SecurityEvent) async -> Void,
        maxPending: Int,
        emitter: SecurityEventEmitter
    ) {
        self.id = id
        self.handler = handler
        self.maxPending = maxPending
        self.emitter = emitter
    }
    
 // MARK: - Public Methods
    
 /// Enqueue an event for delivery.
 ///
 /// If the queue is full, the event is dropped and the emitter is notified.
 ///
 /// - Parameter event: The event to enqueue
 /// - Returns: true if enqueued, false if dropped
    @discardableResult
    func enqueue(_ event: SecurityEvent) async -> Bool {
 // Check capacity
        if pendingEvents.count >= maxPending {
            droppedCount += 1
 // Notify emitter about overflow (will trigger rate-limited meta-event)
            if let emitter = emitter {
                await emitter.notifySubscriberOverflow(subscriberId: id, droppedCount: droppedCount)
            }
            return false
        }
        
 // Add to queue
        pendingEvents.append(event)
        
 // Start processing if not already
        if !isProcessing {
            await processQueue()
        }
        
        return true
    }
    
 /// Deliver an event directly (bypass queue).
 ///
 /// Used for meta-events to prevent recursion.
 /// Does not enter the queue, calls handler immediately.
 ///
 /// - Parameter event: The event to deliver
    func deliverDirect(_ event: SecurityEvent) async {
        await handler(event)
    }
    
 /// Get current pending count (for monitoring/testing)
    var pendingCount: Int {
        pendingEvents.count
    }
    
 // MARK: - Private Methods
    
 /// Process the pending queue serially
    private func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true
        
        defer { isProcessing = false }
        
        while !pendingEvents.isEmpty {
            let event = pendingEvents.removeFirst()
            await handler(event)
        }
        
 // Reset dropped count after successful processing
        droppedCount = 0
    }
}

// MARK: - Sendable Conformance

// SecurityEventEmitter is an actor, so it's implicitly Sendable
// SubscriberActor is an actor, so it's implicitly Sendable

// MARK: - Testing Support

#if DEBUG
extension SecurityEventEmitter {
 /// Create a test instance with custom limits
    public static func createForTesting(
        maxQueueSize: Int = 100,
        maxPendingPerSubscriber: Int = 50
    ) -> SecurityEventEmitter {
        SecurityEventEmitter(
            maxQueueSize: maxQueueSize,
            maxPendingPerSubscriber: maxPendingPerSubscriber
        )
    }
    
 /// Reset the shared instance state (for testing)
    public func resetForTesting() async {
        clearQueue()
        clearSubscribers()
        lastOverflowMetaEventTime = nil
    }
}
#endif
