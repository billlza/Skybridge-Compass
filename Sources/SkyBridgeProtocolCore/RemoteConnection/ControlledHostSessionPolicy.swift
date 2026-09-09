import Foundation

/// 一台控制端同时连接多台主机时的准入、焦点与流量分级规则。
/// 各端运行时必须显式接入此策略；定义本身不代表某条传输已支持多主机。
///
/// 后台主机降帧并关闭音频，减少后台资源消耗。各主机仍持有独立连接和解码器，
/// 因此总资源消耗仍随主机数增长。切换会保留认证连接，但流配置可能重启采集。
///
/// 单一音频焦点避免混音与播放端所有权冲突；不同远端的采集设备彼此独立。
public enum ControlledHostSessionPolicy {
    /// 同时控制的主机数上限。超出时明确拒绝，不排队、不静默顶替。
    public static let defaultConcurrentHostLimit = 2

    /// 后台保留低帧率画面；实际首帧/切换延迟还取决于采集重配和关键帧到达。
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

    /// 所有存活主机的流预算。总请求帧率随后台主机数按低帧率增量增长。
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
