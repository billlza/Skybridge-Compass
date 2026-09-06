import Foundation

/// 一台控制端同时控制多台主机（一控多）时的准入、焦点与流量分级规则。纯函数，macOS 局域网与 iOS 跨网共用一份。
///
/// 核心取舍：观看管线的代价（解码、渲染、音频）应当按「正在看几台」计，而不是按「连了几台」计。
/// 后台主机被显式降流到保活帧率并关闭音频，因此并发上限可以定得保守，而切换焦点时对端仍是热的、不必重新协商整条流。
///
/// 音频只给焦点主机，这不是偏好而是硬约束：系统音频采集设备是进程内单例，
/// 第二个占用者会被明确拒绝（见 `SBWebRTCSystemAudioDevice`），所以同时向两台主机要音频必然有一台拿不到。
public enum ControlledHostSessionPolicy {
    /// 同时控制的主机数上限。超出时明确拒绝，不排队、不静默顶替。
    public static let defaultConcurrentHostLimit = 2

    /// 后台主机的保活帧率。不设为 0：保持解码器温热，切换焦点时不必等一个完整的关键帧周期。
    public static let backgroundKeepAliveFrameRate = 2

    // MARK: - 准入

    public enum Admission: Sendable, Equatable {
        /// 可以开始控制这台主机。
        case admitted
        /// 已经在控制它了，调用方应当把焦点切过去而不是新建一路。
        case alreadyControlled
        /// 达到并发上限。调用方必须把这个结果暴露给用户，不得静默顶替已有主机。
        case refusedAtCapacity(limit: Int, activeHostCount: Int)
    }

    /// 判定能否再控制一台主机。`activeHostKeys` 是当前已在控制的主机键集合。
    public static func admit(
        hostKey: String,
        activeHostKeys: Set<String>,
        limit: Int = defaultConcurrentHostLimit
    ) -> Admission {
        let boundedLimit = max(1, limit)
        if activeHostKeys.contains(hostKey) {
            return .alreadyControlled
        }
        guard activeHostKeys.count < boundedLimit else {
            return .refusedAtCapacity(limit: boundedLimit, activeHostCount: activeHostKeys.count)
        }
        return .admitted
    }

    // MARK: - 焦点

    /// 一台主机退出后，焦点应当落在哪台。`ordered` 是按最近使用排序的存活主机（最近的在前）。
    /// 返回 nil 表示没有可聚焦的主机了。
    public static func focusedHost(
        afterRemoving removedHostKey: String,
        remaining ordered: [String],
        currentFocus: String?
    ) -> String? {
        let survivors = ordered.filter { $0 != removedHostKey }
        if let currentFocus, currentFocus != removedHostKey, survivors.contains(currentFocus) {
            // 退出的不是焦点主机：焦点不动，避免用户正在操作的画面被别的主机顶掉。
            return currentFocus
        }
        return survivors.first
    }

    // MARK: - 流量分级

    public enum StreamTier: Sendable, Equatable {
        /// 用户正在看的那一台：按用户设置的完整质量。
        case focused
        /// 已连接但不在前台：降到保活帧率、不要音频。
        case background
    }

    public static func tier(for hostKey: String, focusedHostKey: String?) -> StreamTier {
        hostKey == focusedHostKey ? .focused : .background
    }

    /// 一台主机该向对端请求的流预算。
    public struct StreamBudget: Sendable, Equatable {
        public let targetFrameRate: Int
        public let audioEnabled: Bool
        /// 后台主机允许对端自行降分辨率以省带宽；焦点主机沿用调用方的设置。
        public let allowsAdaptiveResolution: Bool

        public init(targetFrameRate: Int, audioEnabled: Bool, allowsAdaptiveResolution: Bool) {
            self.targetFrameRate = targetFrameRate
            self.audioEnabled = audioEnabled
            self.allowsAdaptiveResolution = allowsAdaptiveResolution
        }
    }

    /// 由分级推出流预算。`requestedFrameRate` / `requestedAudio` 是用户设置里的值。
    public static func budget(
        for tier: StreamTier,
        requestedFrameRate: Int,
        requestedAudio: Bool,
        requestedAdaptiveResolution: Bool = false
    ) -> StreamBudget {
        let sanitizedFrameRate = max(1, requestedFrameRate)
        switch tier {
        case .focused:
            return StreamBudget(
                targetFrameRate: sanitizedFrameRate,
                audioEnabled: requestedAudio,
                allowsAdaptiveResolution: requestedAdaptiveResolution
            )
        case .background:
            return StreamBudget(
                // 后台永远不会比焦点更费：用户把帧率本来就设得很低时取较小值。
                targetFrameRate: min(sanitizedFrameRate, backgroundKeepAliveFrameRate),
                audioEnabled: false,
                allowsAdaptiveResolution: true
            )
        }
    }

    /// 所有存活主机的流预算。焦点主机之外一律降级，因此总代价与主机数近似无关。
    public static func budgets(
        hostKeys: [String],
        focusedHostKey: String?,
        requestedFrameRate: Int,
        requestedAudio: Bool,
        requestedAdaptiveResolution: Bool = false
    ) -> [String: StreamBudget] {
        var result: [String: StreamBudget] = [:]
        for hostKey in hostKeys {
            result[hostKey] = budget(
                for: tier(for: hostKey, focusedHostKey: focusedHostKey),
                requestedFrameRate: requestedFrameRate,
                requestedAudio: requestedAudio,
                requestedAdaptiveResolution: requestedAdaptiveResolution
            )
        }
        return result
    }
}
