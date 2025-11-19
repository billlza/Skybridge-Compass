import Foundation

public enum PerformanceMode: String, CaseIterable, Sendable, Identifiable {
    case powerSave = "省电"
    case balanced = "平衡"
    case extreme = "极致"

    public var id: String { rawValue }
}

public struct PerformanceSettings: Sendable {
    public var mode: PerformanceMode
    public var renderScale: Double
    public var maxResolution: Int
    public var targetFPS: Int
    public var enableIPv6: Bool
    public var enableNewDiscovery: Bool
    public var enableP2P: Bool
    public var maxConcurrentLinks: Int
    public var smoothing: Double

    public init(
        mode: PerformanceMode,
        renderScale: Double,
        maxResolution: Int,
        targetFPS: Int,
        enableIPv6: Bool,
        enableNewDiscovery: Bool,
        enableP2P: Bool,
        maxConcurrentLinks: Int,
        smoothing: Double
    ) {
        self.mode = mode
        self.renderScale = renderScale
        self.maxResolution = maxResolution
        self.targetFPS = targetFPS
        self.enableIPv6 = enableIPv6
        self.enableNewDiscovery = enableNewDiscovery
        self.enableP2P = enableP2P
        self.maxConcurrentLinks = maxConcurrentLinks
        self.smoothing = smoothing
    }
}

public extension PerformanceSettings {
    static let `default` = PerformanceSettings(
        mode: .balanced,
        renderScale: 0.8,
        maxResolution: 6144,
        targetFPS: 60,
        enableIPv6: true,
        enableNewDiscovery: false,
        enableP2P: true,
        maxConcurrentLinks: 4,
        smoothing: 0.45
    )
}
