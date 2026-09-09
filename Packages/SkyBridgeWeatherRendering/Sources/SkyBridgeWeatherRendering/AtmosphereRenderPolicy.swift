import Foundation

enum AtmosphereRenderPolicy {
    /// Same pixel budget and quality tiers as the Android cloud volume.
    static func drawableSize(for size: CGSize, quality: Float) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return .zero
        }
        let qualityScale: CGFloat = quality > 0.65 ? 1 : 0.75
        let scale = min(1, 600 / min(size.width, size.height), 1300 / max(size.width, size.height)) * qualityScale
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }
}

struct AtmosphereAnimationClock {
    private(set) var elapsed: TimeInterval = 0
    private var previous: TimeInterval?

    mutating func sample(at timestamp: TimeInterval, animating: Bool) -> Float {
        if animating, let previous {
            elapsed += min(max(timestamp - previous, 0), 0.1)
        }
        previous = animating ? timestamp : nil
        return Float(elapsed)
    }

    mutating func pause() { previous = nil }
}
