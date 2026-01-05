//
// HandshakeReplayCache.swift
// SkyBridgeCore
//
// Short-window replay cache for handshakeId.
//

import Foundation

@available(macOS 14.0, iOS 17.0, *)
actor HandshakeReplayCache {
    static let shared = HandshakeReplayCache()
    
    private let ttl: TimeInterval = 5 * 60
    private var entries: [String: Date] = [:]
    
    func registerIfNew(_ handshakeId: String, now: Date = Date()) -> Bool {
        prune(now: now)
        if let existing = entries[handshakeId], now.timeIntervalSince(existing) <= ttl {
            return false
        }
        entries[handshakeId] = now
        return true
    }
    
    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-ttl)
        entries = entries.filter { $0.value >= cutoff }
    }
    
    func clearForTesting() {
        entries.removeAll()
    }
}
