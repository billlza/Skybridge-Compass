//
// SignedKEMRefreshRequestAdmissionGate.swift
// SkyBridgeCompassiOS
//
// Replay and per-requester admission control for signed KEM refresh requests.
//

import Foundation

@available(iOS 17.0, *)
enum SignedKEMRefreshRequestAdmission: Equatable {
    case allowed
    case replay
    case rateLimited
}

@available(iOS 17.0, *)
actor SignedKEMRefreshRequestAdmissionGate {
    static let shared = SignedKEMRefreshRequestAdmissionGate()

    private struct CachedResponse: Sendable {
        let payload: AppMessage.SignedKEMRefreshPayload
        let completedAt: TimeInterval
    }

    private let ttl: TimeInterval
    private let rateLimitWindow: TimeInterval
    private let maxRequestsPerWindow: Int
    private let maxEntries: Int
    private var seenRequestHashes: [String: TimeInterval] = [:]
    private var completedResponses: [String: CachedResponse] = [:]
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

        let replayKey = replayKey(
            requestHashHex: requestHashHex,
            requesterDeviceId: requesterDeviceId,
            requesterFingerprint: requesterFingerprint
        )
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

    func cachedCompletedResponse(
        requestHashHex: String,
        requesterDeviceId: String,
        requesterFingerprint: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> AppMessage.SignedKEMRefreshPayload? {
        prune(now: now)
        let key = replayKey(
            requestHashHex: requestHashHex,
            requesterDeviceId: requesterDeviceId,
            requesterFingerprint: requesterFingerprint
        )
        guard seenRequestHashes[key] != nil else {
            completedResponses.removeValue(forKey: key)
            return nil
        }
        return completedResponses[key]?.payload
    }

    func recordCompletedResponse(
        _ payload: AppMessage.SignedKEMRefreshPayload,
        requestHashHex: String,
        requesterDeviceId: String,
        requesterFingerprint: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard !Task.isCancelled else { return }
        prune(now: now)
        let key = replayKey(
            requestHashHex: requestHashHex,
            requesterDeviceId: requesterDeviceId,
            requesterFingerprint: requesterFingerprint
        )
        guard seenRequestHashes[key] != nil else { return }
        completedResponses[key] = CachedResponse(payload: payload, completedAt: now)
        trimIfNeeded()
    }

#if DEBUG || SKYBRIDGE_TESTING
    func clearForTesting() {
        seenRequestHashes.removeAll()
        completedResponses.removeAll()
        requesterWindows.removeAll()
    }
#endif

    private func prune(now: TimeInterval) {
        let replayCutoff = now - ttl
        seenRequestHashes = seenRequestHashes.filter { $0.value >= replayCutoff }
        completedResponses = completedResponses.filter { $0.value.completedAt >= replayCutoff }

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
            completedResponses.removeValue(forKey: key)
        }
    }

    private func replayKey(
        requestHashHex: String,
        requesterDeviceId: String,
        requesterFingerprint: String
    ) -> String {
        [
            requesterDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            requesterFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            requestHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "|")
    }
}
