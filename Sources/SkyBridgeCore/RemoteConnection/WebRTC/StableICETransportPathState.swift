@available(macOS 14.0, iOS 17.0, *)
struct StableICETransportPathState: Sendable, Equatable {
    private(set) var effectivePath: WebRTCSession.ICETransportPath = .unknown
    private(set) var lastNonUnknownPath: WebRTCSession.ICETransportPath?
    private(set) var consecutiveUnknownProbes: Int = 0

    @discardableResult
    mutating func recordProbe(
        _ probedPath: WebRTCSession.ICETransportPath,
        unknownProbeThreshold: Int = 10
    ) -> Bool {
        if probedPath == .unknown {
            consecutiveUnknownProbes += 1
            if let lastNonUnknownPath,
               consecutiveUnknownProbes < max(1, unknownProbeThreshold) {
                effectivePath = lastNonUnknownPath
                return true
            }
            effectivePath = .unknown
            return false
        }

        consecutiveUnknownProbes = 0
        lastNonUnknownPath = probedPath
        effectivePath = probedPath
        return false
    }
}
