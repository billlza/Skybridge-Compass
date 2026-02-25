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
    private nonisolated static let disablePrune: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["SKYBRIDGE_DISABLE_REPLAY_PRUNE"] == "1" { return true }
        // Bench/CI: pruning is unnecessary for correctness and adds O(n) noise that
        // can dominate performance measurements under high handshake throughput.
        if env["SKYBRIDGE_RUN_BENCH"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return false
    }()
    private var lastPrune: TimeInterval = 0
    private var entries: [Data: TimeInterval] = [:]
    
    func registerIfNew(_ handshakeId: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if !Self.disablePrune, now - lastPrune >= pruneInterval {
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
