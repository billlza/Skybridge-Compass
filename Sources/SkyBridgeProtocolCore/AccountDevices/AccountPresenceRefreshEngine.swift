import Foundation
import OSLog

/// 账号在线状态刷新引擎（macOS `PresenceService` 与 iOS `AccountPresenceService` 共用的唯一实现）。
///
/// 每个 tick：先心跳（注册本设备在线 + 上报元数据），再拉取账号设备列表并发布快照；
/// 从列表派生受信设备的在线子集。失败按 `AccountPresenceFailure` 分类并暴露，退避由 `AccountPresenceRefreshPolicy` 决定。
///
/// 并发/生命周期不变量（有测试锁定）：
/// - 单飞：同一时刻只有一个刷新任务；`triggerRefresh()` 在刷新进行中是幂等的。
/// - 世代：`stop()`/重启后，旧世代的在途结果永远不会覆盖新世代的状态。
/// - fail closed：列表超过 TTL 未成功刷新时清空在线集合，并把快照里每台设备置为离线；时钟回拨同样视为失效。
///   到期由轮询循环准时触发，不受刷新退避（最长 5 分钟）影响。
/// - 列表失败保留上一次成功快照（设备名/地址仍有价值），但把失败类型发布出来，UI 必须显示"可能已过期"。
/// - 退避：一次 tick 里心跳或列表任一失败都计入 `consecutiveFailures`；两者都成功才清零。
///   （只数列表失败会让"心跳一直失败、列表一直成功"以 30s 固定间隔无限重试。）
@MainActor
public final class AccountPresenceRefreshEngine {
    public struct State: Sendable, Equatable {
        public var onlinePeerDeviceIds: Set<String> = []
        public var accountDevices: AccountDeviceListSnapshot?
        public var lastSuccessfulListAt: Date?
        public var lastListFailure: AccountPresenceFailure?
        public var lastHeartbeatFailure: AccountPresenceFailure?

        public init() {}
    }

    public typealias RegistrationOperation = @MainActor () async throws -> Void
    public typealias AccountDeviceListOperation = @MainActor () async throws -> AccountDeviceListSnapshot
    public typealias TrustedDeviceIDsProvider = @MainActor () -> Set<String>
    public typealias NowProvider = @MainActor () -> Date
    public typealias FailureClassifier = @Sendable (Error) -> AccountPresenceFailure
    public typealias StateObserver = @MainActor (State) -> Void
    /// 轮询循环的等待原语。默认是 `Task.sleep`；测试注入后可在不真实等待的情况下驱动退避节奏。
    public typealias SleepOperation = @Sendable (TimeInterval) async throws -> Void

    public private(set) var state = State() {
        didSet {
            if state != oldValue { onStateChange(state) }
        }
    }

    private var loopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshToken: UUID?
    private var started = false
    private var lifecycleGeneration: UInt64 = 0
    private var consecutiveFailures = 0
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "AccountPresence")
    private let refreshInterval: TimeInterval
    private let onlineStateTTL: TimeInterval
    private let now: NowProvider
    private let registerPresence: RegistrationOperation
    private let listAccountDevices: AccountDeviceListOperation
    private let trustedDeviceIDs: TrustedDeviceIDsProvider
    private let classifyFailure: FailureClassifier
    private let onStateChange: StateObserver
    private let sleepOperation: SleepOperation

    public init(
        refreshInterval: TimeInterval = AccountPresenceRefreshPolicy.heartbeatInterval,
        onlineStateTTL: TimeInterval = AccountPresenceRefreshPolicy.snapshotTTL,
        now: @escaping NowProvider = Date.init,
        registerPresence: @escaping RegistrationOperation,
        listAccountDevices: @escaping AccountDeviceListOperation,
        trustedDeviceIDs: @escaping TrustedDeviceIDsProvider,
        classifyFailure: @escaping FailureClassifier,
        onStateChange: @escaping StateObserver,
        sleepOperation: @escaping SleepOperation = { try await Task.sleep(for: .seconds($0)) }
    ) {
        precondition(onlineStateTTL > 0, "Presence online-state TTL must be positive")
        precondition(refreshInterval > 0, "Presence refresh interval must be positive")
        self.refreshInterval = refreshInterval
        self.onlineStateTTL = onlineStateTTL
        self.now = now
        self.registerPresence = registerPresence
        self.listAccountDevices = listAccountDevices
        self.trustedDeviceIDs = trustedDeviceIDs
        self.classifyFailure = classifyFailure
        self.onStateChange = onStateChange
        self.sleepOperation = sleepOperation
    }

    public var isStarted: Bool { started }

    /// 启动心跳 + 列表轮询（幂等）。
    public func start() {
        guard !started else { return }
        started = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        // 从后台恢复时先让过期的在线状态失效，再发起刷新：UI 不会短暂展示陈旧的"在线"。
        expireOnlineStateIfStale(at: now())
        scheduleRefresh(for: generation)
        loopTask = Task { @MainActor [weak self] in
            var nextRefreshAt: Date
            // 等待原语单独捕获：睡眠期间不需要（也不应该）持有引擎本身。
            let sleep: SleepOperation
            do {
                guard let self, self.isCurrentRefresh(generation) else { return }
                sleep = self.sleepOperation
                nextRefreshAt = self.now().addingTimeInterval(self.nextRefreshDelay())
            }
            while true {
                let sleepInterval: TimeInterval
                do {
                    // 只在同步段持有 self：睡眠期间不延长引擎的生命周期。
                    guard let self, self.isCurrentRefresh(generation) else { return }
                    let current = self.now()
                    sleepInterval = AccountPresenceRefreshPolicy.loopSleepInterval(
                        untilRefresh: nextRefreshAt.timeIntervalSince(current),
                        untilOnlineStateExpires: self.timeUntilOnlineStateExpires(at: current)
                    )
                }
                do {
                    try await sleep(sleepInterval)
                } catch {
                    return
                }
                guard let self, self.isCurrentRefresh(generation) else { return }
                let current = self.now()
                self.expireOnlineStateIfStale(at: current)
                if current >= nextRefreshAt {
                    self.scheduleRefresh(for: generation)
                    nextRefreshAt = current.addingTimeInterval(self.nextRefreshDelay())
                }
            }
        }
    }

    /// 停止并清空全部状态（登出/账号切换/后台）。
    public func stop() {
        lifecycleGeneration &+= 1
        loopTask?.cancel()
        loopTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshToken = nil
        started = false
        consecutiveFailures = 0
        state = State()
    }

    /// 挂起计时与在途刷新但保留快照（进入后台）。恢复用 `start()`。
    public func suspend() {
        lifecycleGeneration &+= 1
        loopTask?.cancel()
        loopTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshToken = nil
        started = false
    }

    /// 立即触发一次（前台恢复、用户点刷新）。刷新进行中时不会并发第二次。
    public func triggerRefresh() {
        guard started else { return }
        expireOnlineStateIfStale(at: now())
        scheduleRefresh(for: lifecycleGeneration)
    }

    public func waitForCurrentRefresh() async {
        let task = refreshTask
        await task?.value
    }

    public func isOnline(deviceId: String) -> Bool {
        !deviceId.isEmpty && state.onlinePeerDeviceIds.contains(deviceId)
    }

    public func isSnapshotStale(at currentTime: Date? = nil) -> Bool {
        AccountPresenceRefreshPolicy.isSnapshotStale(
            lastSuccessAt: state.lastSuccessfulListAt,
            now: currentTime ?? now(),
            ttl: onlineStateTTL
        )
    }

    /// 下一次刷新前的等待时间（秒）：常规节奏，或最近一次失败对应的退避。
    /// UI 可用它显示"将在 N 秒后重试"，测试用它锁定退避阶梯。
    public var nextRefreshDelaySeconds: TimeInterval { nextRefreshDelay() }

    private func nextRefreshDelay() -> TimeInterval {
        guard let failure = state.lastListFailure ?? state.lastHeartbeatFailure else {
            return refreshInterval
        }
        let delay = AccountPresenceRefreshPolicy.retryDelay(after: failure, consecutiveFailures: consecutiveFailures)
        return max(delay, refreshInterval)
    }

    private func scheduleRefresh(for generation: UInt64) {
        guard isCurrentGeneration(generation), refreshTask == nil else { return }
        let token = UUID()
        refreshToken = token
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.tick(generation: generation)
            self.finishRefresh(token: token, generation: generation)
        }
    }

    private func finishRefresh(token: UUID, generation: UInt64) {
        guard lifecycleGeneration == generation, refreshToken == token else { return }
        refreshTask = nil
        refreshToken = nil
    }

    private func tick(generation: UInt64) async {
        var tickFailed = false
        do {
            try await registerPresence()
            guard isCurrentRefresh(generation) else { return }
            if state.lastHeartbeatFailure != nil { state.lastHeartbeatFailure = nil }
        } catch {
            guard isCurrentRefresh(generation) else { return }
            tickFailed = true
            let failure = classifyFailure(error)
            state.lastHeartbeatFailure = failure
            logger.warning(
                "Presence registration failed: failure=\(String(describing: failure), privacy: .public) errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
            )
        }
        guard isCurrentRefresh(generation) else { return }

        do {
            let snapshot = try await listAccountDevices()
            guard isCurrentRefresh(generation) else { return }
            var next = state
            next.lastListFailure = nil
            next.lastSuccessfulListAt = now()
            next.accountDevices = snapshot
            // 信任记录可能在请求期间被撤销：用 await 之后的当前信任集合求交。
            next.onlinePeerDeviceIds = snapshot.onlineDeviceIds.intersection(trustedDeviceIDs())
            state = next
        } catch {
            guard isCurrentRefresh(generation) else { return }
            tickFailed = true
            let failure = classifyFailure(error)
            state.lastListFailure = failure
            logger.warning(
                "Account device list failed: failure=\(String(describing: failure), privacy: .public) errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
            )
            expireOnlineStateIfStale(at: now())
        }
        // 心跳与列表任一失败都要拉长退避；只有两者都成功才回到常规节奏。
        consecutiveFailures = tickFailed ? consecutiveFailures + 1 : 0
    }

    private var hasOnlineState: Bool {
        !state.onlinePeerDeviceIds.isEmpty || (state.accountDevices?.hasOnlineDevices ?? false)
    }

    /// 距离在线状态到期还有多久；没有在线状态时为 nil（循环无需为此唤醒）。
    private func timeUntilOnlineStateExpires(at currentTime: Date) -> TimeInterval? {
        guard hasOnlineState else { return nil }
        guard let lastSuccessfulListAt = state.lastSuccessfulListAt else { return 0 }
        let age = currentTime.timeIntervalSince(lastSuccessfulListAt)
        guard age >= 0 else { return 0 }
        return max(0, onlineStateTTL - age)
    }

    private func expireOnlineStateIfStale(at currentTime: Date) {
        guard hasOnlineState else { return }
        guard let lastSuccessfulListAt = state.lastSuccessfulListAt else {
            markOnlineStateExpired()
            return
        }
        let age = currentTime.timeIntervalSince(lastSuccessfulListAt)
        guard age >= 0, age < onlineStateTTL else {
            // Wall-clock rollback is not proof that a peer remains online; fail closed.
            markOnlineStateExpired()
            return
        }
    }

    /// 在线集合清空 + 快照里每台设备置为离线；静态信息（名称/地址/能力）保留给 UI 展示。
    private func markOnlineStateExpired() {
        var next = state
        next.onlinePeerDeviceIds = []
        next.accountDevices = next.accountDevices?.markingAllOffline()
        state = next
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        started && lifecycleGeneration == generation
    }

    private func isCurrentRefresh(_ generation: UInt64) -> Bool {
        isCurrentGeneration(generation) && !Task.isCancelled
    }
}
