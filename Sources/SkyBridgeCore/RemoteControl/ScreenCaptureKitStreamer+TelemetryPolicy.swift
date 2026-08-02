// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import Foundation

extension ScreenCaptureKitStreamer {
    static func encodeLatencyPercentiles(_ values: [Double]) -> (
        p50: Double?,
        p95: Double?,
        max: Double?
    ) {
        guard !values.isEmpty else {
            return (nil, nil, nil)
        }
        let sorted = values.sorted()
        func value(at percentile: Double) -> Double {
            let clamped = min(max(percentile, 0), 1)
            let rawIndex = (Double(sorted.count - 1) * clamped).rounded(.up)
            let index = min(sorted.count - 1, max(0, Int(rawIndex)))
            return sorted[index]
        }
        return (value(at: 0.50), value(at: 0.95), sorted[sorted.count - 1])
    }
}
#endif
