//
// AuditTrail.swift
// SkyBridgeCore
//
// Phase A (TDSC): Tamper-evident telemetry
// - Per-session hash-chain anchored to handshake transcriptHash (or an explicit anchor)
// - Deterministic encoding of event fields + sorted context
//

import Foundation
import CryptoKit

@available(macOS 14.0, iOS 17.0, *)
public actor AuditTrail {
    public static let shared = AuditTrail()

    public struct Entry: Sendable, Codable, Equatable {
        public let sessionId: String
        public let seq: UInt64
        public let timestampMs: UInt64
        public let eventType: String
        public let severity: String
        public let message: String
        public let context: [String: String]
        public let prevHashHex: String
        public let hashHex: String
    }

    public struct Snapshot: Sendable, Codable, Equatable {
        public let sessionId: String
        public let anchorHex: String
        public let headHashHex: String
        public let count: Int
        public let entries: [Entry]
    }

    public var isEnabled: Bool = true

    // Keep bounded history per session to avoid unbounded memory growth.
    public var maxEntriesPerSession: Int = 2048

    private struct SessionState {
        var anchor: Data
        var head: Data
        var seq: UInt64
        var entries: [Entry]
    }

    private var sessions: [String: SessionState] = [:]

    private init() {}
    
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Begin (or reset) a session audit chain anchored to `anchor` (typically handshake transcriptHash).
    public func beginSession(sessionId: String, anchor: Data) {
        guard isEnabled else { return }
        sessions[sessionId] = SessionState(anchor: anchor, head: anchor, seq: 0, entries: [])
    }

    /// Record a SecurityEvent into the audit chain.
    ///
    /// Session routing:
    /// - If `event.context["sessionId"]` exists, records under that session.
    /// - Otherwise records under a synthetic "global" session.
    public func record(_ event: SecurityEvent) {
        guard isEnabled else { return }

        let sessionId = event.context["sessionId"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "global"

        // If we haven't begun the session yet, anchor to a zero hash.
        let anchor = sessions[sessionId]?.anchor ?? Data(repeating: 0, count: 32)
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionState(anchor: anchor, head: anchor, seq: 0, entries: [])
        }

        guard var state = sessions[sessionId] else { return }

        let seq = state.seq &+ 1
        state.seq = seq

        let timestampMs = UInt64(max(0, Int64(event.timestamp.timeIntervalSince1970 * 1000.0)))

        // Deterministic payload for hashing (no randomness, sorted context).
        let payload = encodeDeterministicPayload(
            sessionId: sessionId,
            seq: seq,
            timestampMs: timestampMs,
            event: event
        )

        var toHash = Data()
        toHash.reserveCapacity(state.head.count + payload.count)
        toHash.append(state.head)
        toHash.append(payload)

        let digest = SHA256.hash(data: toHash)
        let newHead = Data(digest)
        let entry = Entry(
            sessionId: sessionId,
            seq: seq,
            timestampMs: timestampMs,
            eventType: event.type.rawValue,
            severity: event.severity.rawValue,
            message: event.message,
            context: event.context,
            prevHashHex: state.head.hexString,
            hashHex: newHead.hexString
        )

        state.head = newHead
        state.entries.append(entry)
        if state.entries.count > maxEntriesPerSession {
            state.entries.removeFirst(state.entries.count - maxEntriesPerSession)
        }

        sessions[sessionId] = state
    }

    public func snapshot(sessionId: String) -> Snapshot? {
        guard let state = sessions[sessionId] else { return nil }
        return Snapshot(
            sessionId: sessionId,
            anchorHex: state.anchor.hexString,
            headHashHex: state.head.hexString,
            count: state.entries.count,
            entries: state.entries
        )
    }

    public func reset(sessionId: String) {
        sessions.removeValue(forKey: sessionId)
    }

    public func resetAll() {
        sessions.removeAll()
    }

    // MARK: - Deterministic encoding (hash input)

    private func encodeDeterministicPayload(
        sessionId: String,
        seq: UInt64,
        timestampMs: UInt64,
        event: SecurityEvent
    ) -> Data {
        var data = Data()
        data.reserveCapacity(256)

        // version marker
        data.append(0xA1)

        data.appendUInt64LE(seq)
        data.appendUInt64LE(timestampMs)
        data.appendStringWithUInt32Len(sessionId)
        data.appendStringWithUInt32Len(event.type.rawValue)
        data.appendStringWithUInt32Len(event.severity.rawValue)
        data.appendStringWithUInt32Len(event.message)
        data.appendStringWithUInt32Len(event.id.uuidString)
        data.append(event.isMetaEvent ? 1 : 0)

        // Sorted context for deterministic ordering.
        let sorted = event.context.sorted(by: { $0.key < $1.key })
        data.appendUInt32LE(UInt32(sorted.count))
        for (k, v) in sorted {
            data.appendStringWithUInt32Len(k)
            data.appendStringWithUInt32Len(v)
        }

        return data
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<UInt32>.size))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<UInt64>.size))
    }

    mutating func appendStringWithUInt32Len(_ string: String) {
        let bytes = Data(string.utf8)
        appendUInt32LE(UInt32(bytes.count))
        append(bytes)
    }
}


