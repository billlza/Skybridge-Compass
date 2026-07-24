//
// SignedKEMRefreshRequestAdmissionGate.swift
// Skybridge-Compass
//
// Replay and per-requester admission control for signed KEM refresh requests.
//

import Foundation

@available(macOS 14.0, iOS 17.0, *)
enum SignedKEMRefreshRequestAdmission: Equatable {
    case allowed
    case replay
    case rateLimited
}

@available(macOS 14.0, iOS 17.0, *)
actor SignedKEMRefreshRequestAdmissionGate {
    static let shared = SignedKEMRefreshRequestAdmissionGate()

    private let ttl: TimeInterval
    private let rateLimitWindow: TimeInterval
    private let maxRequestsPerWindow: Int
    private let maxEntries: Int
    private var seenRequestHashes: [String: TimeInterval] = [:]
    private var requesterWindows: [String: [TimeInterval]] = [:]

    init(
        ttl: TimeInterval = 300,
        rateLimitWindow: TimeInterval = 60,
        maxRequestsPerWindow: Int = 10,
        maxEntries: Int = 10_000
    ) {
        self.ttl = ttl
        self.rateLimitWindow = rateLimitWindow
        self.maxRequestsPerWindow = max(1, maxRequestsPerWindow)
        self.maxEntries = max(16, maxEntries)
    }

    func admit(
        requestHashHex: String,
        requesterDeviceId: String,
        requesterFingerprint: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> SignedKEMRefreshRequestAdmission {
        prune(now: now)

        let replayKey = [
            requesterDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            requesterFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            requestHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "|")
        if let firstSeen = seenRequestHashes[replayKey], now - firstSeen <= ttl {
            return .replay
        }

        let requesterKey = [
            requesterDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            requesterFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "|")
        let cutoff = now - rateLimitWindow
        var window = requesterWindows[requesterKey, default: []].filter { $0 >= cutoff }
        guard window.count < maxRequestsPerWindow else {
            requesterWindows[requesterKey] = window
            return .rateLimited
        }

        window.append(now)
        requesterWindows[requesterKey] = window
        seenRequestHashes[replayKey] = now
        trimIfNeeded()
        return .allowed
    }

#if DEBUG || SKYBRIDGE_TESTING
    func clearForTesting() {
        seenRequestHashes.removeAll()
        requesterWindows.removeAll()
    }
#endif

    private func prune(now: TimeInterval) {
        let replayCutoff = now - ttl
        seenRequestHashes = seenRequestHashes.filter { $0.value >= replayCutoff }

        let rateCutoff = now - rateLimitWindow
        requesterWindows = requesterWindows.compactMapValues { samples in
            let retained = samples.filter { $0 >= rateCutoff }
            return retained.isEmpty ? nil : retained
        }
    }

    private func trimIfNeeded() {
        guard seenRequestHashes.count > maxEntries else { return }
        let overflow = seenRequestHashes.count - maxEntries
        for key in seenRequestHashes.sorted(by: { $0.value < $1.value }).prefix(overflow).map(\.key) {
            seenRequestHashes.removeValue(forKey: key)
        }
    }
}
