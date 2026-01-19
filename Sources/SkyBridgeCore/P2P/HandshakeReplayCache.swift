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
    private let pruneInterval: TimeInterval = 1
    private var lastPrune: TimeInterval = 0
    private var entries: [Data: TimeInterval] = [:]
    
    func registerIfNew(_ handshakeId: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if now - lastPrune >= pruneInterval {
            prune(now: now)
            lastPrune = now
        }
        if let existing = entries[handshakeId], now - existing <= ttl {
            return false
        }
        entries[handshakeId] = now
        return true
    }
    
    func prune(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let cutoff = now - ttl
        entries = entries.filter { $0.value >= cutoff }
    }
    
    func clearForTesting() {
        entries.removeAll()
        lastPrune = 0
    }
}
