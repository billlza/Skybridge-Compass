//
// DeviceDiscoveryManager.swift
// Skybridge-Compass
//
// macOS 26.x / Swift 6.2.1
// 基于 Network.framework + Bonjour 的本地设备发现与 TCP 连接管理
//

import Foundation
import Network
import OSLog
import CryptoKit
import Combine
import Security

/// 设备发现管理器 - 基于 2025 年 Apple 推荐栈
/// 使用 Network.framework 的 Bonjour 能力 + TCP 连接
///
/// 继承 BaseManager，统一管理器模式和生命周期管理
@MainActor
public class P2PDiscoveryService: BaseManager {
    public static let shared = P2PDiscoveryService()

 // MARK: - 发布的属性（给 SwiftUI / 视图层用）

 /// 发现的设备列表（Bonjour + 自定义逻辑融合）
    @Published public private(set) var discoveredDevices: [DiscoveredDevice] = []
 /// P2P设备列表（供上层统一使用）
    @Published public var p2pDevices: [P2PDevice] = []

 /// 当前连接状态（只是对 connections 字典的一个抽象）
    @Published public var connectionStatus: P2PDiscoveryConnectionStatus = .disconnected

    /// 当前已建立的入站会话数量（用于 UI 显示“被连接/已连接”）
    @Published public private(set) var activeInboundSessions: Int = 0

 /// 是否正在扫描（有无浏览器在跑）
    @Published public var isScanning: Bool = false
 /// P2P发现是否运行中
    @Published public var isDiscovering: Bool = false
 /// 是否正在广播服务
    @Published public var isAdvertising: Bool = false

 // MARK: - 私有属性

 /// Bonjour 浏览器（一个 serviceType 对应一个 NWBrowser）
    private var browsers: [NWBrowser] = []

 /// Bonjour 监听器（本机作为服务端被发现）
    private var listener: NWListener?
    private var acceptingInboundControlConnections = false

    /// 当前活跃连接（按 DiscoveredDevice.id.uuidString 存）
    private var connections: [String: NWConnection] = [:]
    /// Per-device generation for outbound connect orchestration. It prevents an
    /// older fallback attempt from removing/cancelling a newer connection that
    /// reused the same stable device key.
    private var outboundConnectionAttemptIds: [String: UUID] = [:]
    /// 已完成应用层握手认证的连接（用于保持 P2PConnection 生命周期）
    private var authenticatedConnections: [String: P2PConnection] = [:]
    private struct InboundControlSession {
        let connection: NWConnection
        var task: Task<Void, Never>?
        var aliases: Set<String>
    }
    private static let maximumProvisionalInboundConnections = 32
    private static let provisionalInboundTimeoutSeconds: TimeInterval = 12
    nonisolated static let maximumDiscoveredDevices = 128
    nonisolated static let maximumHydrationTaskOwners = 128
    nonisolated static let maximumRouteIdentifiersPerDevice = 32
    nonisolated private static let maximumNetServiceResolveWaiters = maximumHydrationTaskOwners - 4
    private static let staleDiscoveryEvictionAge: TimeInterval = 30
    private static let discoveryCapacityLogInterval: TimeInterval = 5
    private static let unprotectedAdmissionBackoffSeconds: TimeInterval = 1
    private var inboundControlSessions: [UUID: InboundControlSession] = [:]
    private var provisionalInboundConnections: [ObjectIdentifier: NWConnection] = [:]
    private var provisionalInboundTimeoutTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    struct DiscoveryHydrationRoute: Hashable, Sendable {
        let serviceName: String
        let serviceType: String
        let domain: String

        init(serviceName: String, serviceType: String, domain: String) {
            self.serviceName = serviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.serviceType = serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.domain = normalizedDomain.isEmpty ? "local." : normalizedDomain
        }
    }

    struct DiscoveryHydrationTicket: Equatable, Sendable {
        let route: DiscoveryHydrationRoute
        let stableDeviceIdentity: String
        let serviceType: String
        let generation: UInt64
        let lifecycleToken: UUID
    }

    struct DiscoveryHydrationGenerationState: Sendable {
        private var lifecycleToken = UUID()
        private var nextGeneration: UInt64 = 0
        private var generationByRoute: [DiscoveryHydrationRoute: UInt64] = [:]

        mutating func issue(
            route: DiscoveryHydrationRoute,
            stableDeviceIdentity: String,
            serviceType: String
        ) -> DiscoveryHydrationTicket {
            let generation = advance(route: route)
            return DiscoveryHydrationTicket(
                route: route,
                stableDeviceIdentity: stableDeviceIdentity,
                serviceType: serviceType,
                generation: generation,
                lifecycleToken: lifecycleToken
            )
        }

        mutating func invalidate(route: DiscoveryHydrationRoute) {
            generationByRoute.removeValue(forKey: route)
        }

        mutating func invalidateAll() {
            lifecycleToken = UUID()
            nextGeneration = 0
            generationByRoute.removeAll(keepingCapacity: false)
        }

        mutating func retire(_ ticket: DiscoveryHydrationTicket) {
            guard ticket.lifecycleToken == lifecycleToken,
                  generationByRoute[ticket.route] == ticket.generation else {
                return
            }
            generationByRoute.removeValue(forKey: ticket.route)
        }

        func accepts(
            _ ticket: DiscoveryHydrationTicket,
            currentStableDeviceIdentity: String,
            hasService: Bool
        ) -> Bool {
            hasService
                && ticket.lifecycleToken == lifecycleToken
                && ticket.stableDeviceIdentity == currentStableDeviceIdentity
                && generationByRoute[ticket.route] == ticket.generation
        }

        private mutating func advance(route: DiscoveryHydrationRoute) -> UInt64 {
            if nextGeneration == UInt64.max {
                // A lifecycle token prevents a theoretical generation wrap
                // from making an ancient resolver result current again.
                lifecycleToken = UUID()
                nextGeneration = 0
                generationByRoute.removeAll(keepingCapacity: false)
            }
            nextGeneration += 1
            generationByRoute[route] = nextGeneration
            return nextGeneration
        }
    }

    enum DiscoveryCapacityPriority: Int, Comparable, Sendable {
        case compatibility = 0
        case skyBridge = 1
        case protected = 2

        static func < (lhs: DiscoveryCapacityPriority, rhs: DiscoveryCapacityPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct DiscoveryCapacityRecord: Equatable, Sendable {
        let id: UUID
        let priority: DiscoveryCapacityPriority
        let isProtected: Bool
    }

    enum DiscoveryCapacityDecision: Equatable, Sendable {
        case admit
        case evict(UUID)
        case reject
    }

    struct DiscoveryCapacityState: Sendable {
        private(set) var lastActivityByDeviceID: [UUID: Date] = [:]

        var trackedDeviceCount: Int {
            lastActivityByDeviceID.count
        }

        func isTracking(deviceID: UUID) -> Bool {
            lastActivityByDeviceID[deviceID] != nil
        }

        mutating func recordActivity(for deviceID: UUID, at date: Date) {
            lastActivityByDeviceID[deviceID] = date
        }

        mutating func remove(deviceID: UUID) {
            lastActivityByDeviceID.removeValue(forKey: deviceID)
        }

        mutating func retainOnly(deviceIDs: Set<UUID>) {
            lastActivityByDeviceID = lastActivityByDeviceID.filter { deviceIDs.contains($0.key) }
        }

        mutating func removeAll() {
            lastActivityByDeviceID.removeAll(keepingCapacity: false)
        }

        func admissionDecision(
            existing: [DiscoveryCapacityRecord],
            incomingPriority: DiscoveryCapacityPriority,
            incomingIsProtected: Bool,
            limit: Int,
            staleAfter: TimeInterval,
            now: Date
        ) -> DiscoveryCapacityDecision {
            guard existing.count >= max(1, limit) else { return .admit }

            let unprotected = existing.filter { !$0.isProtected }
            guard !unprotected.isEmpty else { return .reject }

            let eligible: [DiscoveryCapacityRecord]
            if incomingIsProtected {
                eligible = unprotected
            } else {
                let lowerPriority = unprotected.filter { $0.priority < incomingPriority }
                if !lowerPriority.isEmpty {
                    eligible = lowerPriority
                } else {
                    eligible = unprotected.filter { record in
                        guard let lastActivity = lastActivityByDeviceID[record.id] else { return false }
                        return now.timeIntervalSince(lastActivity) >= staleAfter
                    }
                }
            }

            guard let candidate = eligible.min(by: evictionOrder) else { return .reject }
            return .evict(candidate.id)
        }

        private func evictionOrder(
            _ lhs: DiscoveryCapacityRecord,
            _ rhs: DiscoveryCapacityRecord
        ) -> Bool {
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            let lhsActivity = lastActivityByDeviceID[lhs.id] ?? .distantPast
            let rhsActivity = lastActivityByDeviceID[rhs.id] ?? .distantPast
            if lhsActivity != rhsActivity {
                return lhsActivity < rhsActivity
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    struct BoundedRouteMergeResult: Equatable, Sendable {
        let identifiers: [String]
        let accepted: Bool
    }

    private struct NetServiceResolveTaskOwner {
        let token: UUID
        let ticket: DiscoveryHydrationTicket
        let task: Task<Void, Never>
    }
    private static let maximumTXTResolveCooldownEntries = 256
    private static let txtResolveCooldownRetentionSeconds: TimeInterval = 30
    private var txtResolveCooldown: [DiscoveryHydrationRoute: Date] = [:]
    private var netServiceResolveTasks: [DiscoveryHydrationRoute: NetServiceResolveTaskOwner] = [:]
    private var discoveryHydrationGenerationState = DiscoveryHydrationGenerationState()
    private var discoveryCapacityState = DiscoveryCapacityState()
    private var lastDiscoveryCapacityLogAt: Date?
    private var lastHydrationCapacityLogAt: Date?
    private var lastRouteCapacityLogAt: Date?
    private var unprotectedAdmissionBackoffUntil: Date?
    private var advertisingLifecycleGeneration: UInt64 = 0
    private var advertisingLifecycleTask: Task<Void, Error>?
    private let outboundConnectionQueue = DispatchQueue(
        label: "com.skybridge.p2p.discovery.outbound-connection",
        qos: .utility
    )

 /// 服务类型瘦身策略 - 默认仅SkyBridge；兼容/调试模式可扩展
    private let allServiceTypes = [
        BonjourInteropContract.controlServiceType,
        BonjourInteropContract.fileTransferServiceType,
        BonjourInteropContract.remoteControlServiceType,
        "_companion-link._tcp",
        "_airplay._tcp",
        "_rdlink._tcp",
        "_sftp-ssh._tcp"
    ]
 /// 兼容模式与 companion-link 开关（默认关闭，正常用户场景仅SkyBridge）
    public var enableCompatibilityMode: Bool = false
    public var enableCompanionLink: Bool = false
    private var activeBrowserServiceTypes: Set<String> = []
    private func effectiveServiceTypes() -> [String] {
        var base = BonjourInteropContract.defaultDiscoveryServiceTypes
        if enableCompanionLink { base.append("_companion-link._tcp") }
        if enableCompatibilityMode {
            base.append(contentsOf: allServiceTypes.filter { !$0.hasPrefix("_skybridge") && !$0.hasPrefix("_companion-link") })
        }
        return base
    }

    private let serviceDomain = "local."

    private enum ConnectionSecurityPlan: String {
        case encryptedTLS = "tls"
        case plainTCP = "tcp"
    }

    public enum ConnectionRoutePreference: Sendable {
        case automatic
        case preferUSB
        case managedRelayOnly
    }

    #if DEBUG || SKYBRIDGE_TESTING
    func testingReplaceAuthenticatedConnections(_ connections: [String: P2PConnection]) {
        authenticatedConnections = connections
    }
    #endif

    private static let controlServiceType = BonjourInteropContract.controlServiceType
    private static let controlAdvertisementOwner = "P2PDiscoveryService"

    public func activeAuthenticatedConnectionsForClassicTransfer() -> [P2PConnection] {
        authenticatedConnections.values.filter { $0.status == .authenticated }
    }

    private static func normalizedInboundControlAliases(_ aliases: [String?]) -> Set<String> {
        aliases.reduce(into: Set<String>()) { result, raw in
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return }
            for candidate in PeerTrustLookup.lookupCandidates(for: raw) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                result.insert(normalized)
            }
        }
    }

    private func upsertInboundControlSession(
        id: UUID,
        connection: NWConnection,
        aliases rawAliases: [String?]
    ) {
        let aliases = Self.normalizedInboundControlAliases(rawAliases)
        guard !aliases.isEmpty else { return }

        guard var session = inboundControlSessions[id] else { return }
        session.aliases.formUnion(aliases)
        inboundControlSessions[id] = session
    }

    private func registerInboundControlSession(
        id: UUID,
        connection: NWConnection
    ) {
        inboundControlSessions[id] = InboundControlSession(
            connection: connection,
            task: nil,
            aliases: []
        )
    }

    private func attachInboundControlSessionTask(
        _ task: Task<Void, Never>,
        id: UUID
    ) {
        guard var session = inboundControlSessions[id] else {
            task.cancel()
            return
        }
        session.task = task
        inboundControlSessions[id] = session
    }

    private func removeInboundControlSession(id: UUID) {
        inboundControlSessions.removeValue(forKey: id)
    }

    private func cancelInboundControlSessions(
        matching sessionIDs: Set<UUID>? = nil
    ) async {
        let selected = inboundControlSessions.filter { id, _ in
            sessionIDs?.contains(id) ?? true
        }
        guard !selected.isEmpty else { return }

        // Remove ownership before cancellation so repeated stop/disconnect calls
        // are idempotent and a session defer cannot race a second cancellation.
        for id in selected.keys {
            inboundControlSessions.removeValue(forKey: id)
        }
        for session in selected.values {
            session.task?.cancel()
            session.connection.cancel()
        }
        for session in selected.values {
            await session.task?.value
        }
    }

    private func cancelInboundControlSessionsWithoutWaiting() {
        let sessions = Array(inboundControlSessions.values)
        inboundControlSessions.removeAll(keepingCapacity: false)
        for session in sessions {
            session.task?.cancel()
            session.connection.cancel()
        }
    }

    private func registerProvisionalInboundConnection(_ connection: NWConnection) -> Bool {
        let identifier = ObjectIdentifier(connection)
        if provisionalInboundConnections[identifier] != nil {
            return true
        }
        guard provisionalInboundConnections.count < Self.maximumProvisionalInboundConnections else {
            logger.error(
                "❌ 拒绝过量入站 P2P 控制连接: limit=\(Self.maximumProvisionalInboundConnections, privacy: .public)"
            )
            connection.cancel()
            return false
        }

        let timeoutTask = Task { @MainActor [weak self, weak connection] in
            do {
                try await Task.sleep(for: .seconds(Self.provisionalInboundTimeoutSeconds))
            } catch {
                return
            }
            guard let self,
                  let connection,
                  self.provisionalInboundConnections.removeValue(forKey: identifier) != nil else {
                return
            }
            self.provisionalInboundTimeoutTasks.removeValue(forKey: identifier)
            self.logger.error(
                "❌ 入站 P2P 控制连接首个有效协议帧超时: seconds=\(Int(Self.provisionalInboundTimeoutSeconds), privacy: .public)"
            )
            connection.cancel()
        }
        provisionalInboundConnections[identifier] = connection
        provisionalInboundTimeoutTasks[identifier] = timeoutTask
        return true
    }

    private func finishProvisionalInboundConnection(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        provisionalInboundConnections.removeValue(forKey: identifier)
        provisionalInboundTimeoutTasks.removeValue(forKey: identifier)?.cancel()
    }

    private func cancelAllProvisionalInboundConnections() {
        let connections = Array(provisionalInboundConnections.values)
        let tasks = Array(provisionalInboundTimeoutTasks.values)
        provisionalInboundConnections.removeAll(keepingCapacity: false)
        provisionalInboundTimeoutTasks.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }
        connections.forEach { $0.cancel() }
    }

    private enum InterfacePreference: String {
        case automatic
        case wiredEthernetOnly
    }

    struct SmokeConnectionPathClassification: Equatable, Sendable {
        let routeClass: String
        let attached: Bool
        let linkLocal: Bool
    }

    final class NetServiceResolvePermitWaiter: @unchecked Sendable {
        private enum Completion {
            case succeeded
            case cancelled
        }

        private struct State {
            var continuation: CheckedContinuation<Void, Error>?
            var completion: Completion?
        }

        let id: UUID
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(id: UUID = UUID()) {
            self.id = id
        }

        /// Installs the continuation exactly once. Cancellation may race ahead
        /// of installation, so a completed waiter resumes the newly installed
        /// continuation immediately instead of entering the actor queue.
        @discardableResult
        func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
            let completion = state.withLock { state -> Completion? in
                guard let completion = state.completion else {
                    state.continuation = continuation
                    return nil
                }
                return completion
            }

            switch completion {
            case nil:
                return true
            case .succeeded:
                continuation.resume()
                return false
            case .cancelled:
                continuation.resume(throwing: CancellationError())
                return false
            }
        }

        /// Returns true only when this call won the single-completion race.
        @discardableResult
        func resumeSuccess() -> Bool {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
                guard state.completion == nil else { return nil }
                state.completion = .succeeded
                defer { state.continuation = nil }
                return state.continuation
            }
            guard let continuation else { return false }
            continuation.resume()
            return true
        }

        /// Cancellation is synchronous so process/lifecycle teardown cannot
        /// deallocate a queued checked continuation before an actor cleanup
        /// task gets scheduled.
        @discardableResult
        func cancel() -> Bool {
            let transition = state.withLock { state -> (Bool, CheckedContinuation<Void, Error>?) in
                guard state.completion == nil else { return (false, nil) }
                state.completion = .cancelled
                defer { state.continuation = nil }
                return (true, state.continuation)
            }
            transition.1?.resume(throwing: CancellationError())
            return transition.0
        }
    }

    actor NetServiceResolveLimiter {
        enum PermitError: Error {
            case queueFull
        }

        struct Snapshot: Equatable, Sendable {
            let inFlight: Int
            let waiting: Int
        }

        private let limit: Int
        private let maximumWaiters: Int
        private var inFlight = 0
        private var waiters: [NetServiceResolvePermitWaiter] = []

        init(limit: Int, maximumWaiters: Int = 64) {
            self.limit = max(1, limit)
            self.maximumWaiters = max(1, maximumWaiters)
        }

        func withPermit<T: Sendable>(
            _ operation: @Sendable () async throws -> T
        ) async throws -> T {
            try await acquire()
            defer { release() }
            try Task.checkCancellation()
            return try await operation()
        }

        func snapshot() -> Snapshot {
            Snapshot(inFlight: inFlight, waiting: waiters.count)
        }

        private func acquire() async throws {
            try Task.checkCancellation()
            if inFlight < limit {
                inFlight += 1
                return
            }

            guard waiters.count < maximumWaiters else {
                throw PermitError.queueFull
            }
            let waiter = NetServiceResolvePermitWaiter()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if waiter.install(continuation) {
                        waiters.append(waiter)
                    }
                }
            } onCancel: {
                waiter.cancel()
                Task { await self.removeWaiter(id: waiter.id) }
            }
        }

        private func release() {
            while !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                if waiter.resumeSuccess() {
                    // Direct permit handoff: the resumed waiter already owns
                    // this in-flight slot and must not increment the counter.
                    return
                }
            }
            inFlight = max(0, inFlight - 1)
        }

        private func removeWaiter(id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index)
        }
    }

    private struct NetServiceResolvedEndpoint: Sendable {
        let port: Int
        let ipv4: String?
        let ipv6: String?
    }

    private struct LocalInterfaceCacheEntry: Sendable {
        let addresses: Set<String>
        let normalizedHostName: String
        let updatedAt: Date
    }

    private enum NetServiceResolveError: LocalizedError {
        case resolveFailed([String: NSNumber])

        var errorDescription: String? {
            switch self {
            case .resolveFailed(let info):
                return "NetService 解析失败: \(info)"
            }
        }
    }

    private final class NetServiceResolveContext: NSObject, NetServiceDelegate, @unchecked Sendable {
        private let resumed = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<NetServiceResolvedEndpoint, Error>
        private let service: NetService
        private let timeoutSeconds: TimeInterval
        private var timeoutTask: Task<Void, Never>?
        private var selfRetain: NetServiceResolveContext?

        init(
            service: NetService,
            timeoutSeconds: TimeInterval,
            continuation: CheckedContinuation<NetServiceResolvedEndpoint, Error>
        ) {
            self.service = service
            self.timeoutSeconds = timeoutSeconds
            self.continuation = continuation
            super.init()
            self.selfRetain = self
        }

        func start() {
            service.delegate = self
            service.schedule(in: .main, forMode: .common)
            service.resolve(withTimeout: timeoutSeconds)

            timeoutTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.finish(.failure(P2PDiscoveryError.timeout))
            }
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            let port = max(0, sender.port)
            var foundIPv4: String?
            var foundIPv6: String?

            if let addresses = sender.addresses {
                for data in addresses {
                    let address = P2P_ExtractIPAddress(from: data)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard !address.isEmpty, address != "未知地址" else { continue }
                    if address.contains("."), !address.hasPrefix("169.254"), !address.hasPrefix("127."), foundIPv4 == nil {
                        foundIPv4 = address
                    } else if address.contains(":"), !address.hasPrefix("fe80:"), foundIPv6 == nil {
                        foundIPv6 = address
                    }
                }
            }

            finish(.success(NetServiceResolvedEndpoint(port: port, ipv4: foundIPv4, ipv6: foundIPv6)))
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
            finish(.failure(NetServiceResolveError.resolveFailed(errorDict)))
        }

        func cancel() {
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<NetServiceResolvedEndpoint, Error>) {
            let shouldResume = resumed.withLock { state -> Bool in
                guard !state else { return false }
                state = true
                return true
            }
            guard shouldResume else { return }

            // Resume synchronously. In particular, task cancellation must not
            // depend on a subsequently scheduled MainActor cleanup task: the
            // process may already be terminating and checked continuations
            // must retain single, deterministic ownership at that boundary.
            switch result {
            case .success(let resolved):
                continuation.resume(returning: resolved)
            case .failure(let error):
                continuation.resume(throwing: error)
            }

            Task { @MainActor [self] in
                timeoutTask?.cancel()
                timeoutTask = nil
                service.stop()
                service.delegate = nil
                service.remove(from: .main, forMode: .common)
                selfRetain = nil
            }
        }
    }

    private final class NetServiceResolveCancellationHandle: @unchecked Sendable {
        private struct State {
            var context: NetServiceResolveContext?
            var cancelled = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        @discardableResult
        func install(_ context: NetServiceResolveContext) -> Bool {
            let wasCancelled = state.withLock { state -> Bool in
                state.context = context
                return state.cancelled
            }
            if wasCancelled {
                context.cancel()
                return false
            }
            return true
        }

        func cancel() {
            let context = state.withLock { state -> NetServiceResolveContext? in
                state.cancelled = true
                return state.context
            }
            context?.cancel()
        }
    }

    private final class WaitForConnectionContext: @unchecked Sendable {
        private let resumed = OSAllocatedUnfairLock(initialState: false)
        private let waitingReported = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<Void, Error>
        var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func complete(
            _ result: Result<Void, Error>,
            beforeResume: () -> Void = {}
        ) {
            let shouldResume = resumed.withLock { isResumed -> Bool in
                guard !isResumed else { return false }
                isResumed = true
                return true
            }
            guard shouldResume else { return }
            timeoutTask?.cancel()
            timeoutTask = nil
            beforeResume()
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }

        func shouldReportWaiting() -> Bool {
            waitingReported.withLock { didReport -> Bool in
                guard !didReport else { return false }
                didReport = true
                return true
            }
        }
    }

    private final class ConnectionWaitCancellationHandle: @unchecked Sendable {
        private struct State {
            var context: WaitForConnectionContext?
            var cancelled = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func install(_ context: WaitForConnectionContext, connection: NWConnection) {
            let wasCancelled = state.withLock { state -> Bool in
                state.context = context
                return state.cancelled
            }
            if wasCancelled {
                connection.stateUpdateHandler = nil
                connection.cancel()
                context.complete(.failure(CancellationError()))
            }
        }

        func cancel(connection: NWConnection) {
            let context = state.withLock { state -> WaitForConnectionContext? in
                state.cancelled = true
                return state.context
            }
            connection.stateUpdateHandler = nil
            connection.cancel()
            context?.complete(.failure(CancellationError()))
        }
    }

    private final class SendContentContext: @unchecked Sendable {
        private let resumed = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<Void, Error>
        private let connection: NWConnection
        var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<Void, Error>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        func cancelConnection() {
            connection.cancel()
        }

        func complete(_ result: Result<Void, Error>) {
            let shouldResume = resumed.withLock { isResumed -> Bool in
                guard !isResumed else { return false }
                isResumed = true
                return true
            }
            guard shouldResume else { return }
            timeoutTask?.cancel()
            timeoutTask = nil
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private final class SendContentCancellationHandle: @unchecked Sendable {
        private struct State {
            var context: SendContentContext?
            var cancelled = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func install(_ context: SendContentContext) {
            let wasCancelled = state.withLock { state -> Bool in
                state.context = context
                return state.cancelled
            }
            if wasCancelled {
                context.cancelConnection()
                context.complete(.failure(CancellationError()))
            }
        }

        func cancel(connection: NWConnection) {
            let context = state.withLock { state -> SendContentContext? in
                state.cancelled = true
                return state.context
            }
            connection.cancel()
            context?.complete(.failure(CancellationError()))
        }
    }

    private let netServiceResolveLimiter = NetServiceResolveLimiter(
        limit: 4,
        maximumWaiters: maximumNetServiceResolveWaiters
    )
    private var localInterfaceCacheEntry: LocalInterfaceCacheEntry?
    private let localInterfaceCacheTTL: TimeInterval = 8

 // MARK: - 初始化

    public init() {
        super.init(category: "DeviceDiscoveryManager")
        $discoveredDevices
            .map { $0.map { Self.mapToP2PDevice($0) } }
            .assign(to: &self.$p2pDevices)
    }

 // MARK: - BaseManager 重写

 /// 执行设备发现管理器的初始化逻辑
    public override func performInitialization() async {
        await super.performInitialization()
        logger.info("✅ 设备发现管理器初始化完成")
    }

 /// 启动设备发现管理器
    public override func performStart() async throws {
        logger.info("🚀 启动设备发现服务")
        startScanning()
    }

 /// 停止设备发现管理器
    public override func performStop() async {
        logger.info("🛑 停止设备发现服务")
        acceptingInboundControlConnections = false
        outboundConnectionAttemptIds.removeAll(keepingCapacity: false)
        connections.values.forEach { connection in
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll(keepingCapacity: false)
        authenticatedConnections.values.forEach { $0.disconnect() }
        authenticatedConnections.removeAll(keepingCapacity: false)
        stopScanning()
        if let advertisingLifecycleTask {
            do {
                try await advertisingLifecycleTask.value
            } catch is CancellationError {
                logger.debug("ℹ️ P2P 广播停止任务被后继生命周期取代")
            } catch {
                logger.error("❌ 等待 P2P 广播停止失败: \(error.localizedDescription)")
            }
        }
        await cancelInboundControlSessions()
    }

 /// 清理资源
    public override func cleanup() {
        super.cleanup()

 // 清理发现的设备
        discoveredDevices.removeAll()
        resetDiscoveryCapacityState()
        connectionStatus = .disconnected
        activeInboundSessions = 0
        isScanning = false
        acceptingInboundControlConnections = false

 // 清理网络连接
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        outboundConnectionAttemptIds.removeAll(keepingCapacity: false)
        authenticatedConnections.values.forEach { $0.disconnect() }
        authenticatedConnections.removeAll()
        cancelInboundControlSessionsWithoutWaiting()
        cancelAllProvisionalInboundConnections()
        cancelNetServiceResolveTasks()

 // 停止 Bonjour 浏览 / 广播
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        activeBrowserServiceTypes.removeAll()
        listener?.cancel()
        listener = nil
        stopAdvertising()
    }

 // MARK: - 公共方法（扫描 / 连接）

    /// 开始扫描设备 - 2025 增强版：多服务类型扫描（全基于 Network.framework）
    public func startScanning() {
        guard isInitialized else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.waitUntilInitialized() {
                    self.startScanning()
                } else {
                    await self.handleError(.notInitialized)
                }
            }
            return
        }
        guard !isScanning else {
            logger.debug("startScanning() 忽略：已经在扫描中")
            return
        }

        let selected = effectiveServiceTypes()
        logger.info("🔍 开始扫描设备（Bonjour，服务类型：\(selected)）")
        isScanning = true
        isDiscovering = true
        acceptingInboundControlConnections = true

        startBrowsers(for: selected)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startAdvertising()
            } catch is CancellationError {
                self.logger.debug("ℹ️ P2P 广播启动已被生命周期变更取消")
            } catch {
                self.logger.error("❌ P2P 广播启动失败: \(error.localizedDescription)")
            }
        }
    }

    private func startBrowsers(for selected: [String]) {
        activeBrowserServiceTypes = Set(selected)

	 // 为每种服务类型创建独立的浏览器
        for serviceType in selected {
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: serviceDomain)
            let parameters = NWParameters()
            parameters.includePeerToPeer = true  // 支持点对点（AWDL / 直连）

            let browser = NWBrowser(for: descriptor, using: parameters)

 // 设置状态更新处理器
            browser.stateUpdateHandler = { [weak self, serviceType] state in
                Task { @MainActor in
                    self?.handleBrowserStateUpdate(state, for: serviceType)
                }
            }

 // 设置结果变化处理器
            browser.browseResultsChangedHandler = { [weak self, serviceType] results, changes in
                Task { @MainActor in
                    self?.handleBrowseResultsChanged(results: results,
                                                     changes: changes,
                                                     serviceType: serviceType)
                }
            }

 // 启动浏览器
            browser.start(queue: .global(qos: .utility))
            browsers.append(browser)

            logger.debug("  ✅ 启动浏览器: \(serviceType)")
        }
    }

 /// 启动发现（与 startScanning 同义，供上层统一调用）
    public func startDiscovery() {
        startScanning()
    }

 /// 停止发现（与 stopScanning 同义，供上层统一调用）
    public func stopDiscovery() {
        stopScanning()
    }

    public func applyDiscoverySettings(
        compatibilityMode: Bool,
        companionLink: Bool
    ) {
        let previousDesired = Set(effectiveServiceTypes())
        enableCompatibilityMode = compatibilityMode
        enableCompanionLink = companionLink
        let desired = Set(effectiveServiceTypes())
        guard desired != previousDesired || desired != activeBrowserServiceTypes else {
            return
        }

        logger.info("🔄 P2P 发现设置已实时应用: compatibility=\(compatibilityMode) companionLink=\(companionLink) serviceTypes=\(desired.sorted())")
        guard isScanning else { return }

        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        startBrowsers(for: desired.sorted())
    }

 /// 刷新设备列表（重启扫描）
    public func refreshDevices() async {
        // UX fix:
        // A hard stop/start here interrupts ongoing handshakes/transfers and creates reconnect loops.
        // For "refresh", we keep browsers/listener running and simply clear transient caches.
        logger.info("🔄 刷新设备列表（软刷新：不停止扫描/不重启广播）")
        discoveredDevices.removeAll()
        resetDiscoveryCapacityState()
        txtResolveCooldown.removeAll()
        cancelNetServiceResolveTasks()
        if connections.isEmpty && authenticatedConnections.isEmpty {
            connectionStatus = .disconnected
        }
        // Ensure advertising is on while scanning.
        if isScanning, !isAdvertising {
            do {
                try await startAdvertising()
            } catch {
                isAdvertising = false
                logger.error("❌ P2P 广播健康恢复失败: \(error.localizedDescription)")
            }
        }
    }

    /// 停止扫描设备
    public func stopScanning() {
        acceptingInboundControlConnections = false
        cancelNetServiceResolveTasks()
        txtResolveCooldown.removeAll(keepingCapacity: false)
        discoveredDevices.removeAll(keepingCapacity: false)
        resetDiscoveryCapacityState()
        if isScanning {
            logger.info("⏹️ 停止扫描设备")
            isScanning = false
            isDiscovering = false

            // 取消所有浏览器
            for browser in browsers {
                browser.cancel()
            }
            browsers.removeAll()
            activeBrowserServiceTypes.removeAll()
        }

        if connections.isEmpty && authenticatedConnections.isEmpty {
            connectionStatus = .disconnected
        }

        stopAdvertising()
    }

    /// 连接到指定设备（优先 Bonjour 服务名，失败时自动回退到 host:port）
    public func connectToDevice(_ device: DiscoveredDevice) async throws {
        let preferredRoute: ConnectionRoutePreference = SettingsManager.shared.enableP2PDirectConnection
            ? .automatic
            : .managedRelayOnly
        try await connectToDevice(device, routePreference: preferredRoute)
    }

    /// 连接到指定设备（可指定路由偏好，例如 USB 优先）。
    public func connectToDevice(
        _ device: DiscoveredDevice,
        routePreference: ConnectionRoutePreference
    ) async throws {
        let device = resolveLatestConnectableDevice(from: device)
        let deviceDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(
            device.deviceId ?? device.uniqueIdentifier ?? device.name
        )
        logger.info("尝试连接到设备: \(deviceDiagnosticLabel, privacy: .public)")
        NetworkActivityLogStore.shared.record(
            category: "p2p",
            message: "connect start device=\(deviceDiagnosticLabel) route=\(String(describing: routePreference))"
        )
        let deviceKey = stableConnectionKey(for: device)
        let attemptId = UUID()
        outboundConnectionAttemptIds[deviceKey] = attemptId
        defer {
            if outboundConnectionAttemptIds[deviceKey] == attemptId {
                outboundConnectionAttemptIds.removeValue(forKey: deviceKey)
            }
        }
        func requireCurrentAttempt() throws {
            try Task.checkCancellation()
            guard outboundConnectionAttemptIds[deviceKey] == attemptId else {
                throw CancellationError()
            }
        }

        connections[deviceKey]?.stateUpdateHandler = nil
        connections[deviceKey]?.cancel()
        connections.removeValue(forKey: deviceKey)
        if let existingAuthenticated = authenticatedConnections.removeValue(forKey: deviceKey) {
            existingAuthenticated.disconnect()
        }

        await repairPeerKEMBootstrapAliasesIfNeeded(for: device)
        try requireCurrentAttempt()

        let preferUSBRoute = routePreference == .preferUSB
        let disableDirectRoute = routePreference == .managedRelayOnly
        let primaryServiceType = BonjourInteropContract.controlServiceType
        let connectableServiceTypes = P2PDiscoveryBonjourPolicy.normalizedConnectableServiceTypes(from: device.services)
        let preferredServiceType = connectableServiceTypes.contains(primaryServiceType) ? primaryServiceType : connectableServiceTypes.first
        let hasStrongRouteIdentity =
            device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || device.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || P2PDiscoveryBonjourPolicy.isStrongUniqueIdentifier(device.uniqueIdentifier)
        let serviceNameCandidates = P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: device)
        let serviceName = serviceNameCandidates.first ?? ""
        logger.info(
            "🧭 连接目标解析: displayName=\(deviceDiagnosticLabel, privacy: .public) bonjourInstance=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(serviceName), privacy: .public) identifier=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(device.uniqueIdentifier), privacy: .public)"
        )
        let hasBonjourIdentifier = P2PDiscoveryBonjourPolicy.isBonjourIdentifier(device.uniqueIdentifier)
        let portValue = resolvedPort(
            for: device,
            preferredServiceType: preferredServiceType,
            primaryServiceType: primaryServiceType,
            connectableServiceTypes: connectableServiceTypes
        )
        let hasSkyBridgeControlHint =
            connectableServiceTypes.contains(primaryServiceType)
            || connectableServiceTypes.contains("_skybridge._udp")
            || device.source == .skybridgeBonjour
            || device.source == .skybridgeP2P
        let hasLinkLocalAddress = {
            if let ipv6 = device.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               ipv6.hasPrefix("fe80:") {
                return true
            }
            if let ipv4 = device.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines),
               ipv4.hasPrefix("169.254.") {
                return true
            }
            return false
        }()
        let shouldAttemptBonjourService = !serviceNameCandidates.isEmpty
            && serviceNameCandidates.contains(where: { !P2PDiscoveryBonjourPolicy.isLikelyIPAddress($0) })
            && (hasBonjourIdentifier || hasSkyBridgeControlHint || hasLinkLocalAddress || (device.ipv4 == nil && device.ipv6 == nil))

        var serviceTypesToTry: [String] = []
        if let preferredServiceType {
            serviceTypesToTry.append(preferredServiceType)
        }
        if !serviceTypesToTry.contains(primaryServiceType) {
            serviceTypesToTry.append(primaryServiceType)
        }
        if serviceTypesToTry.isEmpty {
            serviceTypesToTry = [primaryServiceType]
        }

        var bonjourEndpointAttempts: [NWEndpoint] = []
        if shouldAttemptBonjourService {
            for candidateServiceName in serviceNameCandidates where !candidateServiceName.isEmpty && !P2PDiscoveryBonjourPolicy.isLikelyIPAddress(candidateServiceName) {
                for serviceType in serviceTypesToTry {
                    bonjourEndpointAttempts.append(
                        .service(
                            name: candidateServiceName,
                            type: serviceType,
                            domain: serviceDomain,
                            interface: nil
                        )
                    )
                }
            }
        }
        let freshBonjourHostFallbackEndpoints = await makeFreshBonjourHostFallbackEndpoints(
            serviceNameCandidates: shouldAttemptBonjourService ? serviceNameCandidates : [],
            serviceTypes: serviceTypesToTry,
            domain: serviceDomain
        )
        try requireCurrentAttempt()
        let hostFallbackEndpoints = makeHostFallbackEndpoints(device: device, portValue: portValue)

        var endpointAttempts: [NWEndpoint] = []
        if disableDirectRoute {
            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)
        } else if preferUSBRoute {
            endpointAttempts.append(contentsOf: hostFallbackEndpoints)
            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)
        } else if !bonjourEndpointAttempts.isEmpty {
            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)
            endpointAttempts.append(contentsOf: freshBonjourHostFallbackEndpoints)
            endpointAttempts.append(contentsOf: hostFallbackEndpoints)
        } else if hasStrongRouteIdentity, !hostFallbackEndpoints.isEmpty {
            endpointAttempts.append(contentsOf: hostFallbackEndpoints)
        } else {
            endpointAttempts.append(contentsOf: hostFallbackEndpoints)
        }

        if !endpointAttempts.isEmpty {
            var seenEndpointKeys = Set<String>()
            endpointAttempts = endpointAttempts.filter { endpoint in
                let key = endpoint.debugDescription
                if seenEndpointKeys.contains(key) { return false }
                seenEndpointKeys.insert(key)
                return true
            }
        }

        RemoteControlSmokeStatusWriter.append(
            "p2p-connect-plan serviceCandidates=\(serviceNameCandidates.count) serviceEndpoints=\(bonjourEndpointAttempts.count) freshHostEndpoints=\(freshBonjourHostFallbackEndpoints.count) hostFallbackEndpoints=\(hostFallbackEndpoints.count) endpointOrder=\(Self.smokeEndpointPlanSummary(endpointAttempts))"
        )

        // If type metadata is missing but we still have Bonjour identity, probe SkyBridge default service.
        if endpointAttempts.isEmpty, shouldAttemptBonjourService {
            for candidateServiceName in serviceNameCandidates where !candidateServiceName.isEmpty && !P2PDiscoveryBonjourPolicy.isLikelyIPAddress(candidateServiceName) {
                endpointAttempts.append(
                    .service(
                        name: candidateServiceName,
                        type: primaryServiceType,
                        domain: serviceDomain,
                        interface: nil
                    )
                )
            }
        }

        guard !endpointAttempts.isEmpty else {
            NetworkActivityLogStore.shared.record(
                category: "p2p",
                message: "connect failed device=\(deviceDiagnosticLabel) reason=no_connectable_endpoint",
                level: "WARN"
            )
            throw P2PDiscoveryError.noConnectableEndpoint
        }

        try await ensureStrictPQCOutboundPreflightReady(
            for: device,
            endpointAttempts: endpointAttempts,
            preferredServiceType: preferredServiceType
        )
        try requireCurrentAttempt()

        var lastError: Error?
        for endpoint in endpointAttempts {
            try requireCurrentAttempt()
            let securityPlans = preferredConnectionSecurityPlans(
                for: endpoint,
                device: device,
                preferredServiceType: preferredServiceType
            )
            let interfacePreferences = interfacePreferences(for: endpoint, preferUSBRoute: preferUSBRoute)
            for interfacePreference in interfacePreferences {
                for plan in securityPlans {
                    try requireCurrentAttempt()
                    let connection = makeConnection(
                        to: endpoint,
                        securityPlan: plan,
                        interfacePreference: interfacePreference
                    )
                    do {
                        let endpointDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(endpoint.debugDescription)
                        if case .service(let name, let type, _, _) = endpoint {
                            logger.info("📡 尝试 Bonjour 连接: \(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(name), privacy: .public) [\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(type), privacy: .public)] security=\(plan.rawValue, privacy: .public) route=\(interfacePreference.rawValue, privacy: .public)")
                        } else {
                            logger.info("📡 尝试地址连接: \(endpointDiagnosticLabel, privacy: .public) security=\(plan.rawValue, privacy: .public) route=\(interfacePreference.rawValue, privacy: .public)")
                        }

                        connections[deviceKey] = connection
                        connectionStatus = .connecting
                        try await waitForConnection(
                            connection,
                            deviceId: deviceKey,
                            endpoint: endpoint
                        )
                        try requireCurrentAttempt()
                        guard connections[deviceKey] === connection else {
                            throw CancellationError()
                        }

                        if shouldAuthenticateAsSkyBridgeControl(
                            endpoint: endpoint,
                            device: device,
                            preferredServiceType: preferredServiceType
                        ) {
                            logger.info("🔐 传输层已就绪，开始应用层握手认证")
                            let authenticated = try await authenticateConnection(
                                connection,
                                for: device,
                                endpoint: endpoint,
                                fallbackPort: portValue
                            )
                            try requireCurrentAttempt()
                            guard connections[deviceKey] === connection else {
                                authenticated.disconnect()
                                throw CancellationError()
                            }
                            if let replaced = authenticatedConnections.updateValue(authenticated, forKey: deviceKey),
                               replaced.id != authenticated.id {
                                replaced.disconnect()
                            }
                        } else {
                            if let replaced = authenticatedConnections.removeValue(forKey: deviceKey) {
                                replaced.disconnect()
                            }
                        }

                        logger.info("✅ 成功连接到设备: \(deviceDiagnosticLabel, privacy: .public)")
                        NetworkActivityLogStore.shared.record(
                            category: "p2p",
                            message: "connect success device=\(deviceDiagnosticLabel) endpoint=\(endpointDiagnosticLabel)"
                        )
                        connectionStatus = .connected
                        return
                    } catch {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        if let authenticated = authenticatedConnections[deviceKey],
                           authenticated.connection === connection {
                            authenticatedConnections.removeValue(forKey: deviceKey)
                            authenticated.disconnect()
                        }
                        if connections[deviceKey] === connection {
                            connections.removeValue(forKey: deviceKey)
                        }
                        if error is CancellationError || Task.isCancelled
                            || outboundConnectionAttemptIds[deviceKey] != attemptId {
                            throw CancellationError()
                        }
                        lastError = error
                        logger.warning("⚠️ 连接尝试失败，将回退到下一方案: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
                    }
                }
            }
        }

        try requireCurrentAttempt()
        connectionStatus = .failed
        NetworkActivityLogStore.shared.record(
            category: "p2p",
            message: "connect failed device=\(deviceDiagnosticLabel) reason=\(lastError.map(SkyBridgeDiagnosticRedaction.errorSummary) ?? "cancelled")",
            level: "WARN"
        )
        throw lastError ?? P2PDiscoveryError.connectionCancelled
    }

    private func shouldAuthenticateAsSkyBridgeControl(
        endpoint: NWEndpoint,
        device: DiscoveredDevice,
        preferredServiceType: String?
    ) -> Bool {
        isSkyBridgeControlEndpoint(endpoint, device: device, preferredServiceType: preferredServiceType)
    }

    private func authenticateConnection(
        _ connection: NWConnection,
        for device: DiscoveredDevice,
        endpoint: NWEndpoint,
        fallbackPort: Int,
        timeoutSeconds: TimeInterval = 12
    ) async throws -> P2PConnection {
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let requestedPolicy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        let requestedSelection: CryptoProviderFactory.SelectionPolicy = requestedPolicy.requirePQC ? .requirePQC : .preferPQC
        let prefersPQC = await Self.cryptoProviderSupportedSuites(policy: requestedSelection)
            .contains(where: { $0.isPQCGroup })
        let effectiveTimeoutSeconds: TimeInterval
        if requestedPolicy.requirePQC {
            effectiveTimeoutSeconds = max(timeoutSeconds, 90)
        } else if prefersPQC {
            // Compatibility/default mode may still need a classic bootstrap plus a PQC retry.
            effectiveTimeoutSeconds = max(timeoutSeconds, 45)
        } else {
            effectiveTimeoutSeconds = timeoutSeconds
        }

        let p2pDevice = makeP2PDeviceForConnection(
            from: device,
            endpoint: endpoint,
            fallbackPort: fallbackPort
        )
        let authenticatedConnection = P2PConnection(device: p2pDevice, connection: connection)
        authenticatedConnection.startReceivingForHandshake()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await authenticatedConnection.authenticate()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(effectiveTimeoutSeconds))
                    throw P2PDiscoveryError.timeout
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            return authenticatedConnection
        } catch {
            authenticatedConnection.disconnect()
            throw error
        }
    }

    private func makeP2PDeviceForConnection(
        from device: DiscoveredDevice,
        endpoint: NWEndpoint,
        fallbackPort: Int
    ) -> P2PDevice {
        let address: String = {
            switch endpoint {
            case .hostPort(let host, _):
                return String(describing: host)
            case .service(let name, _, let domain, _):
                return domain.isEmpty ? "\(name).local." : "\(name).\(domain)"
            default:
                return device.ipv4 ?? device.ipv6 ?? ""
            }
        }()

        let port: UInt16 = {
            switch endpoint {
            case .hostPort(_, let hostPort):
                return hostPort.rawValue
            case .service(_, _, let servicePort, _):
                if let parsed = UInt16(servicePort) { return parsed }
            default:
                break
            }
            if let parsedFallback = UInt16(exactly: fallbackPort), parsedFallback > 0 {
                return parsedFallback
            }
            return 0
        }()

        let persistentDeviceId = device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesBonjourServiceEndpoint: Bool = {
            if case .service = endpoint { return true }
            return false
        }()
        let resolvedId: String = {
            if let connectionPeerId = P2PDiscoveryBonjourPolicy.connectionPeerIdentifier(
                for: device,
                usesBonjourServiceEndpoint: usesBonjourServiceEndpoint
            ) {
                return connectionPeerId
            }
            return device.id.uuidString
        }()

        let capabilities = Array(Set(device.services)).sorted()
        let endpoints = [endpoint.debugDescription]

        return P2PDevice(
            id: resolvedId,
            name: P2PDiscoveryBonjourPolicy.resolvedBonjourServiceName(for: device),
            type: .macOS,
            address: address,
            port: port,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capabilities: capabilities,
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: endpoints,
            lastMessageTimestamp: nil,
            isVerified: false,
            verificationFailedReason: device.pubKeyFP == nil ? "等待公钥交换" : nil,
            persistentDeviceId: persistentDeviceId,
            pubKeyFingerprint: device.pubKeyFP,
            macAddresses: device.macSet.isEmpty ? nil : device.macSet
        )
    }

    private func preferredConnectionSecurityPlans(
        for endpoint: NWEndpoint,
        device: DiscoveredDevice,
        preferredServiceType: String?
    ) -> [ConnectionSecurityPlan] {
        // SkyBridge 近距通道使用应用层握手加密（HandshakeDriver + SessionKeys）。
        // 为避免与 iOS 端 length-framed 明文控制通道发生 TLS 记录头错配，这里固定使用 plain TCP。
        if isSkyBridgeControlEndpoint(endpoint, device: device, preferredServiceType: preferredServiceType) {
            return [.plainTCP]
        }

        let net = RemoteDesktopSettingsManager.shared.settings.networkSettings
        guard net.enableEncryption, TLSConfigurator.options(for: net.encryptionAlgorithm) != nil else {
            return [.plainTCP]
        }
        return [.encryptedTLS, .plainTCP]
    }

    private func isSkyBridgeControlEndpoint(
        _ endpoint: NWEndpoint,
        device: DiscoveredDevice,
        preferredServiceType: String?
    ) -> Bool {
        let skybridgeServices = Set(["_skybridge._tcp", "_skybridge._udp"])

        if case .service(_, let type, _, _) = endpoint, skybridgeServices.contains(type) {
            return true
        }
        if let preferredServiceType, skybridgeServices.contains(preferredServiceType) {
            return true
        }
        if device.services.contains(where: { skybridgeServices.contains($0) }) {
            return true
        }
        if device.portMap["_skybridge._tcp"] != nil || device.portMap["_skybridge._udp"] != nil {
            return true
        }
        return false
    }

    private func makeConnection(
        to endpoint: NWEndpoint,
        securityPlan: ConnectionSecurityPlan,
        interfacePreference: InterfacePreference
    ) -> NWConnection {
        let net = RemoteDesktopSettingsManager.shared.settings.networkSettings
        if securityPlan == .encryptedTLS, let tls = TLSConfigurator.options(for: net.encryptionAlgorithm) {
            let tcp = NWProtocolTCP.Options()
            let params = NWParameters(tls: tls, tcp: tcp)
            params.includePeerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)
            params.allowLocalEndpointReuse = true
            applyInterfacePreference(interfacePreference, to: params)
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 30
                tcpOptions.keepaliveInterval = 15
                tcpOptions.keepaliveCount = 4
                tcpOptions.noDelay = true
            }
            return NWConnection(to: endpoint, using: params)
        }

        if securityPlan == .encryptedTLS {
            logger.warning("⚠️ TLS 配置不可用，降级为纯 TCP")
        }

        let params = NWParameters.tcp
        params.includePeerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)
        params.allowLocalEndpointReuse = true
        applyInterfacePreference(interfacePreference, to: params)
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 30
            tcpOptions.keepaliveInterval = 15
            tcpOptions.keepaliveCount = 4
            tcpOptions.noDelay = true
        }
        return NWConnection(to: endpoint, using: params)
    }

    private static func shouldIncludePeerToPeer(for endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return true }
        var value = String(describing: host)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let scope = value.firstIndex(of: "%") {
            value = String(value[..<scope])
        }
        if IPv4Address(value) != nil {
            return value.hasPrefix("169.254.")
        }
        if IPv6Address(value) != nil {
            return value.hasPrefix("fe80:")
        }
        return false
    }

    private func applyInterfacePreference(_ preference: InterfacePreference, to params: NWParameters) {
        guard preference == .wiredEthernetOnly else { return }
        params.requiredInterfaceType = .wiredEthernet
    }

    private func resolvedPort(
        for device: DiscoveredDevice,
        preferredServiceType: String?,
        primaryServiceType: String,
        connectableServiceTypes: [String]
    ) -> Int {
        if let preferredServiceType, let preferredPort = device.portMap[preferredServiceType], preferredPort > 0 {
            return preferredPort
        }
        if let primaryPort = device.portMap[primaryServiceType], primaryPort > 0 {
            return primaryPort
        }
        for serviceType in connectableServiceTypes {
            if let port = device.portMap[serviceType], port > 0 {
                return port
            }
        }
        return 0
    }

    private func makeHostFallbackEndpoints(device: DiscoveredDevice, portValue: Int) -> [NWEndpoint] {
        guard portValue > 0, let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            return []
        }

        var endpoints: [NWEndpoint] = []

        if let ipv4 = device.ipv4, !ipv4.isEmpty {
            let trimmedIPv4 = ipv4.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLocalIPAddress(trimmedIPv4) {
                logger.debug("忽略本机地址，跳过连接尝试: \(trimmedIPv4)")
            } else if Self.isNonRoutableIPv4Endpoint(trimmedIPv4) {
                logger.debug("忽略不可路由 IPv4，跳过连接尝试: \(trimmedIPv4)")
            } else {
                endpoints.append(.hostPort(host: NWEndpoint.Host(trimmedIPv4), port: port))
            }
        }

        if let ipv6 = device.ipv6, !ipv6.isEmpty {
            let trimmedIPv6 = ipv6.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLocalIPAddress(trimmedIPv6) {
                logger.debug("忽略本机地址，跳过连接尝试: \(trimmedIPv6)")
            } else if trimmedIPv6.lowercased().hasPrefix("fe80:") {
                // IPv6 链路本地地址必须保留 scope id（例如 %en0），否则连接不可达。
                endpoints.append(.hostPort(host: NWEndpoint.Host(trimmedIPv6), port: port))
            } else {
                let normalizedIPv6 = trimmedIPv6.split(separator: "%", maxSplits: 1).first.map(String.init) ?? trimmedIPv6
                endpoints.append(.hostPort(host: NWEndpoint.Host(normalizedIPv6), port: port))
            }
        }

        return endpoints
    }

    private func makeFreshBonjourHostFallbackEndpoints(
        serviceNameCandidates: [String],
        serviceTypes: [String],
        domain: String
    ) async -> [NWEndpoint] {
        let normalizedServiceTypes = P2PDiscoveryBonjourPolicy.normalizedConnectableServiceTypes(
            from: serviceTypes.isEmpty ? [BonjourInteropContract.controlServiceType] : serviceTypes
        )
        guard !serviceNameCandidates.isEmpty, !normalizedServiceTypes.isEmpty else {
            return []
        }

        var endpoints: [NWEndpoint] = []
        var seenEndpointKeys = Set<String>()
        for serviceName in serviceNameCandidates {
            let trimmedName = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  !P2PDiscoveryBonjourPolicy.isLikelyIPAddress(trimmedName) else {
                continue
            }

            for serviceType in normalizedServiceTypes {
                guard let resolved = await resolveNetServiceEndpoint(
                    domain: domain,
                    type: serviceType,
                    name: trimmedName,
                    timeoutSeconds: 3.0
                ), resolved.port > 0,
                   let port = NWEndpoint.Port(rawValue: UInt16(resolved.port)) else {
                    RemoteControlSmokeStatusWriter.append(
                        "p2p-bonjour-resolve result=failure service=\(serviceType) name=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(trimmedName))"
                    )
                    continue
                }

                let beforeCount = endpoints.count
                for host in [resolved.ipv4, resolved.ipv6].compactMap({ $0 }) {
                    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedHost.isEmpty,
                          !isLocalIPAddress(trimmedHost),
                          !Self.isNonRoutableIPv4Endpoint(trimmedHost) else {
                        continue
                    }

                    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(trimmedHost), port: port)
                    let key = endpoint.debugDescription
                    if seenEndpointKeys.insert(key).inserted {
                        endpoints.append(endpoint)
                    }
                }
                RemoteControlSmokeStatusWriter.append(
                    "p2p-bonjour-resolve result=success service=\(serviceType) name=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(trimmedName)) port=\(resolved.port) directEndpoints=\(endpoints.count - beforeCount)"
                )
            }
        }
        return endpoints
    }

    private nonisolated static func smokeEndpointPlanSummary(_ endpoints: [NWEndpoint]) -> String {
        endpoints.enumerated().map { index, endpoint in
            "\(index):\(smokeEndpointClass(endpoint)):\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(endpoint.debugDescription))"
        }.joined(separator: ",")
    }

    private nonisolated static func smokeEndpointClass(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service:
            return "service"
        case .hostPort:
            return "direct-host"
        default:
            return "other"
        }
    }

    private nonisolated static func isLocalNetworkPermissionDenied(_ error: NWError, path: NWPath?) -> Bool {
        if #available(macOS 11.0, iOS 14.0, *),
           path?.unsatisfiedReason == .localNetworkDenied {
            return true
        }
        let details = [
            String(describing: error),
            (error as NSError).localizedDescription
        ]
        .joined(separator: " ")
        .lowercased()
        return details.contains("local network prohibited")
            || details.contains("local network denied")
            || details.contains("localnetworkdenied")
    }

    private nonisolated static func bootstrapConnectionWaitingSummary(_ error: NWError, path: NWPath?) -> String {
        let nsError = error as NSError
        var fields = [
            "error_domain=\(nsError.domain)",
            "code=\(nsError.code)"
        ]
        if Self.isLocalNetworkPermissionDenied(error, path: path) {
            fields.append("reason=local-network-permission-denied")
        }
        if #available(macOS 11.0, iOS 14.0, *),
           let unsatisfiedReason = path?.unsatisfiedReason {
            fields.append("unsatisfiedReason=\(Self.unsatisfiedReasonDiagnosticCode(unsatisfiedReason))")
        }
        return fields.joined(separator: " ")
    }

    @available(macOS 11.0, iOS 14.0, *)
    private nonisolated static func unsatisfiedReasonDiagnosticCode(_ reason: NWPath.UnsatisfiedReason) -> String {
        switch reason {
        case .notAvailable:
            return "notAvailable"
        case .cellularDenied:
            return "cellularDenied"
        case .wifiDenied:
            return "wifiDenied"
        case .localNetworkDenied:
            return "localNetworkDenied"
        case .vpnInactive:
            return "vpnInactive"
        @unknown default:
            return "unknown"
        }
    }

    private enum StrictPQCOutboundPreflightAction: Equatable {
        case proceed
        case attemptSignedLANRefresh
        case attemptOOBProtocolIdentityBindingThenRefresh
    }

    private struct BootstrapControlExchangeResult {
        let response: AppMessage
        let endpoint: NWEndpoint
        let connectLatencyMs: Double
        let attemptCount: Int
        let failedAttemptCount: Int
    }

    private struct LocalProtocolIdentityProof: Sendable {
        let algorithm: ProtocolSigningAlgorithm
        let publicKey: Data
        let keyHandle: SigningKeyHandle
        let fingerprint: String
    }

    private func ensureStrictPQCOutboundPreflightReady(
        for device: DiscoveredDevice,
        endpointAttempts: [NWEndpoint],
        preferredServiceType: String?
    ) async throws {
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let policy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        guard policy.requirePQC else { return }
        guard endpointAttempts.contains(where: {
            isSkyBridgeControlEndpoint($0, device: device, preferredServiceType: preferredServiceType)
        }) else {
            return
        }

        let stableTargetCandidates = Self.stableProtocolIdentityCandidates(for: device)
	        guard let targetDeviceId = Self.uniqueStableProtocolIdentityCandidate(from: stableTargetCandidates) else {
	            let reason = "missing stable protocol identity target; refusing endpoint alias target"
	            logger.warning(
	                "⛔️ PIB-1 protocol identity binding failed: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) stage=preflight-identity-binding reason=\(reason, privacy: .public) lifecycle=identity-oob>failed"
	            )
	            throw P2PDiscoveryError.strictPQCTrustPreflightFailed(reason)
	        }

        let candidates = Self.outboundStrictPQCTrustCandidates(for: device, stableTarget: targetDeviceId)
        let preferredTargetSuite = await Self.preferredStrictPQCOutboundTargetSuite()
        let trustProvider = DefaultHandshakeTrustProvider()
        let trustedKEMSuites = await Self.trustedKEMSuites(
            provider: trustProvider,
            candidates: candidates
        )
        var pinnedFingerprints = await Self.trustedProtocolFingerprints(
            provider: trustProvider,
            candidates: candidates
        )
        let signedRefreshEvidence = await PeerKEMBootstrapStore.shared
            .signedRefreshEvidence(forCandidates: candidates)
        let preflightAction = Self.strictPQCOutboundPreflightAction(
            trustedPeerKEMSuites: trustedKEMSuites,
            signedRefreshEvidence: signedRefreshEvidence,
            pinnedProtocolFingerprints: pinnedFingerprints,
            preferredTargetSuite: preferredTargetSuite
        )
        guard preflightAction != .proceed else { return }

        let bootstrapEndpoints = Self.strictPQCBootstrapEndpointCandidates(from: endpointAttempts)
        guard !bootstrapEndpoints.isEmpty else {
            throw P2PDiscoveryError.strictPQCTrustPreflightFailed("missing direct LAN bootstrap endpoint")
        }

        var refreshFailure: Error?
        if preflightAction == .attemptSignedLANRefresh {
            do {
                try await attemptOutboundSignedLANKEMRefresh(
                    for: device,
                    targetDeviceId: targetDeviceId,
                    candidates: candidates,
                    endpoints: bootstrapEndpoints,
                    pinnedProtocolFingerprints: pinnedFingerprints,
                    preferredTargetSuite: preferredTargetSuite
                )
                return
            } catch {
                refreshFailure = error
                guard Self.shouldAttemptOOBProtocolIdentityBinding(afterSKRFailure: error) else {
                    throw error
                }
                let line = "⛔️ SKR-1 signed LAN KEM refresh failed: peer=\(Self.protocolIdentityLogRedaction) stage=preflight-kem-refresh reason=\(Self.protocolIdentityLogRedaction) pinnedProtocolIdentity=1 lifecycle=missing-kem>failed"
                logger.warning("\(line, privacy: .public)")
                RemoteControlSmokeStatusWriter.append(line)
            }
        }

        do {
            let reboundFingerprint = try await attemptOutboundOOBProtocolIdentityBinding(
                for: device,
                targetDeviceId: targetDeviceId,
                candidates: candidates,
                endpoints: bootstrapEndpoints
            )
            pinnedFingerprints = [reboundFingerprint]
            try await attemptOutboundSignedLANKEMRefresh(
                for: device,
                targetDeviceId: targetDeviceId,
                candidates: candidates,
                endpoints: bootstrapEndpoints,
                pinnedProtocolFingerprints: pinnedFingerprints,
                preferredTargetSuite: preferredTargetSuite
            )
        } catch {
            let baseReason = refreshFailure.map { "after SKR failure \($0.localizedDescription); " } ?? ""
            throw P2PDiscoveryError.strictPQCTrustPreflightFailed(baseReason + error.localizedDescription)
        }
    }

    private func attemptOutboundOOBProtocolIdentityBinding(
        for device: DiscoveredDevice,
        targetDeviceId: String,
        candidates: [String],
        endpoints: [NWEndpoint]
    ) async throws -> String {
        let requesterIdentity = try await localProtocolIdentityProofForOutboundPIB()
        let requesterDeviceId = try await localOutboundProtocolIdentityDeviceId()
        let nonce = Self.secureRandomNonce()
        let endpointDigest = Self.bootstrapEndpointDigest(for: device)
        let unsignedRequest = AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: requesterDeviceId,
            targetDeviceId: targetDeviceId,
            requestedProtocolSigningAlgorithms: try await CommittedLocalProtocolIdentitySnapshot
                .loadActiveAndCompatibility()
                .map { $0.algorithm.rawValue },
            requesterProtocolSigningAlgorithm: requesterIdentity.algorithm.rawValue,
            requesterProtocolIdentityPublicKey: requesterIdentity.publicKey,
            requesterProtocolIdentityFingerprint: requesterIdentity.fingerprint,
            requesterSignature: Data(),
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: endpointDigest,
            nonce: nonce
        )
        let requesterSignatureProvider = ProtocolSignatureProviderSelector.select(for: requesterIdentity.algorithm)
        let requesterSignature = try await requesterSignatureProvider.sign(
            unsignedRequest.canonicalPreimage,
            key: requesterIdentity.keyHandle
        )
        let request = AppMessage.ProtocolIdentityBindingRequestPayload(
            transactionId: unsignedRequest.transactionId,
            requesterDeviceId: unsignedRequest.requesterDeviceId,
            targetDeviceId: unsignedRequest.targetDeviceId,
            requestedProtocolSigningAlgorithms: unsignedRequest.requestedProtocolSigningAlgorithms,
            requesterProtocolSigningAlgorithm: requesterIdentity.algorithm.rawValue,
            requesterProtocolIdentityPublicKey: requesterIdentity.publicKey,
            requesterProtocolIdentityFingerprint: requesterIdentity.fingerprint,
            requesterSignature: requesterSignature,
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: unsignedRequest.routeScope,
            bonjourEndpointDigest: unsignedRequest.bonjourEndpointDigest,
            nonce: unsignedRequest.nonce,
            sentAt: unsignedRequest.sentAt
        )

        let connectStartLine = "🔐 PIB-1 protocol identity binding connect-start: peer=\(Self.protocolIdentityLogRedaction) endpoints=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>connect"
        logger.info("\(connectStartLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(connectStartLine)

        let responseTimeoutSeconds = Self.protocolIdentityBindingResponseTimeoutSeconds()
        let exchange = try await exchangeBootstrapControlMessage(
            .protocolIdentityBindingRequest(request),
            endpoints: endpoints,
            timeoutSeconds: responseTimeoutSeconds
        )
        let requestLine = "🔐 PIB-1 protocol identity binding request: peer=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) algorithms=\(request.requestedProtocolSigningAlgorithms.joined(separator: ",")) responseTimeoutSeconds=\(Int(responseTimeoutSeconds)) lifecycle=identity-oob>request"
        logger.info("\(requestLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(requestLine)

        if case .kemRefreshFailure(let failure) = exchange.response {
            throw Self.protocolIdentityBindingFailure("remote rejected PIB-1 stage=\(failure.stage) reasonCode=\(failure.reasonCode) reason=\(failure.reason)")
        }
        guard case .signedProtocolIdentityBinding(let payload) = exchange.response else {
            throw Self.protocolIdentityBindingFailure("unexpected PIB-1 response type")
        }

        let validated = try payload.validatedForOOBBinding(request: request)
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: validated.protocolSigningAlgorithm) else {
            throw Self.protocolIdentityBindingFailure("invalid signature algorithm")
        }
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: algorithm)
        let verified = try await signatureProvider.verify(
            validated.signaturePreimage,
            signature: validated.signature,
            publicKey: validated.protocolIdentityPublicKey
        )
        guard verified else {
            throw Self.protocolIdentityBindingFailure("signature verification failed")
        }

        let verifiedLine = "🔐 PIB-1 protocol identity binding signature verified: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>verified"
        logger.info("\(verifiedLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(verifiedLine)

        let approvalRequest = PairingTrustApprovalService.Request(
            peerEndpoint: exchange.endpoint.debugDescription,
            declaredDeviceId: validated.deviceId,
            policyBindingKey: "PIB-1-peer|\(validated.deviceId)|\(validated.protocolSigningAlgorithm)|\(validated.protocolIdentityFingerprint.lowercased())",
            displayName: validated.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? validated.deviceName!
                : device.name,
            model: device.modelName,
            platform: device.platformName,
            osVersion: device.osVersion,
            protocolIdentityAlgorithm: validated.protocolSigningAlgorithm,
            protocolIdentityFingerprint: validated.protocolIdentityFingerprint.lowercased(),
            protocolIdentityTransactionId: request.transactionId,
            protocolIdentityRequestHashHex: request.canonicalRequestHashHex,
            protocolIdentityCandidateHashHex: validated.canonicalCandidateHashHex,
            protocolIdentitySASTranscriptHashHex: validated.sasTranscriptHashHex(request: request),
            kemKeyCount: 0
        )
        let approval = await PairingTrustApprovalService.shared.decideProtocolIdentityBindingCandidate(
            for: approvalRequest,
            verificationCode: validated.shortAuthenticationCode(request: request)
        )
        guard approval != .reject else {
            throw Self.protocolIdentityBindingFailure("operator rejected PIB-1 verification code")
        }

        // The SAS prompt is intentionally long-lived. Refuse to confirm a
        // candidate that expired while the operator was comparing devices.
        _ = try validated.validatedForOOBBinding(request: request, now: Date())

        let confirmNow = Date()
        let unsignedConfirm = AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: request.transactionId,
            requesterDeviceId: request.requesterDeviceId,
            responderDeviceId: validated.deviceId,
            requesterProtocolIdentityFingerprint: requesterIdentity.fingerprint,
            responderProtocolIdentityFingerprint: validated.protocolIdentityFingerprint,
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            candidateHashHex: validated.canonicalCandidateHashHex,
            sasTranscriptHashHex: validated.sasTranscriptHashHex(request: request),
            confirmationNonce: Self.secureRandomNonce(),
            sentAt: confirmNow,
            expiresAt: confirmNow.addingTimeInterval(300),
            requesterSignature: Data()
        )
        let confirmSignature = try await requesterSignatureProvider.sign(
            unsignedConfirm.signaturePreimage,
            key: requesterIdentity.keyHandle
        )
        let confirm = AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: unsignedConfirm.transactionId,
            requesterDeviceId: unsignedConfirm.requesterDeviceId,
            responderDeviceId: unsignedConfirm.responderDeviceId,
            requesterProtocolIdentityFingerprint: unsignedConfirm.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint: unsignedConfirm.responderProtocolIdentityFingerprint,
            requestNonce: unsignedConfirm.requestNonce,
            requestHashHex: unsignedConfirm.requestHashHex,
            candidateHashHex: unsignedConfirm.candidateHashHex,
            sasTranscriptHashHex: unsignedConfirm.sasTranscriptHashHex,
            confirmationNonce: unsignedConfirm.confirmationNonce,
            sentAt: unsignedConfirm.sentAt,
            expiresAt: unsignedConfirm.expiresAt,
            requesterSignature: confirmSignature
        )
        let confirmationExchange = try await exchangeBootstrapControlMessage(
            .protocolIdentityBindingConfirm(confirm),
            endpoints: endpoints,
            timeoutSeconds: responseTimeoutSeconds
        )
        if case .kemRefreshFailure(let failure) = confirmationExchange.response {
            throw Self.protocolIdentityBindingFailure(
                "remote rejected PIB-1 confirmation stage=\(failure.stage) reasonCode=\(failure.reasonCode) reason=\(failure.reason)"
            )
        }
        guard case .signedProtocolIdentityBindingFinalAck(let ack) = confirmationExchange.response else {
            throw Self.protocolIdentityBindingFailure("unexpected PIB-1 final acknowledgement type")
        }
        let validatedAck = try ack.validatedForFinalization(
            request: request,
            candidate: validated,
            confirm: confirm
        )
        guard try await signatureProvider.verify(
            validatedAck.signaturePreimage,
            signature: validatedAck.responderSignature,
            publicKey: validated.protocolIdentityPublicKey
        ) else {
            throw Self.protocolIdentityBindingFailure("PIB-1 final acknowledgement signature invalid")
        }

        let promoted = try await TrustSyncService.shared.recordAuthenticatedRemoteAuthority(
            deviceId: validated.deviceId,
            displayName: validated.deviceName ?? device.name,
            preferredCurrentDeviceId: targetDeviceId,
            knownDeviceIds: candidates + [validated.deviceId] + validated.aliases,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyFingerprint: validated.protocolIdentityFingerprint,
            authenticatedProtocolPublicKey: validated.protocolIdentityPublicKey,
            pinSource: .pib1OperatorApproval
        )
        guard promoted else {
            throw Self.protocolIdentityBindingFailure("authority pin promotion failed")
        }
        let bootstrapCachePersisted = await PeerProtocolIdentityBootstrapStore.shared.upsert(
            deviceIds: candidates + [validated.deviceId] + validated.aliases,
            fingerprints: [validated.protocolIdentityFingerprint]
        )
        if !bootstrapCachePersisted {
            let cacheLine = "⚠️ PIB-1 requester derived bootstrap cache persistence failed after authoritative TrustSync commit; future bootstrap will fail closed until rebuilt lifecycle=identity-oob>cache-persist-failed"
            logger.error("\(cacheLine, privacy: .public)")
            RemoteControlSmokeStatusWriter.append(cacheLine)
        }

        let pinnedLine = "🔐 PIB-1 protocol identity binding pinned: peer=\(Self.protocolIdentityLogRedaction) deviceId=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) operator=\(approval.rawValue) lifecycle=identity-oob>pinned"
        logger.info("\(pinnedLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(pinnedLine)
        return validated.protocolIdentityFingerprint.lowercased()
    }

    private func attemptOutboundSignedLANKEMRefresh(
        for device: DiscoveredDevice,
        targetDeviceId: String,
        candidates: [String],
        endpoints: [NWEndpoint],
        pinnedProtocolFingerprints: Set<String>,
        preferredTargetSuite: CryptoSuite?
    ) async throws {
        let requestedSuites = await Self.signedLANRefreshRequestedSuites(preferredTargetSuite: preferredTargetSuite)
        let requesterDeviceId = try await localOutboundProtocolIdentityDeviceId()
        let requesterProof = try await localProtocolIdentityProofForOutboundPIB()
        let requesterFingerprint = requesterProof.fingerprint
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: requesterDeviceId,
            targetDeviceId: targetDeviceId,
            requesterProtocolIdentityFingerprint: requesterFingerprint,
            targetProtocolIdentityFingerprint: pinnedProtocolFingerprints.count == 1 ? pinnedProtocolFingerprints.sorted().first : nil,
            requestedSuiteWireIds: requestedSuites.map(\.wireId),
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: Self.bootstrapEndpointDigest(for: device),
            nonce: Self.secureRandomNonce()
        )

        let connectStartLine = "🔐 SKR-1 signed LAN KEM refresh connect-start: peer=\(Self.protocolIdentityLogRedaction) endpointCount=\(endpoints.count) pinnedProtocolIdentity=\(pinnedProtocolFingerprints.isEmpty ? 0 : 1) missingPeerKEM=1 lifecycle=missing-kem>connect"
        logger.info("\(connectStartLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(connectStartLine)
        let startedAt = Date()
        let exchange = try await exchangeBootstrapControlMessage(
            .kemRefreshRequest(request),
            endpoints: endpoints,
            timeoutSeconds: 8.0
        )
        let requestLine = "🔐 SKR-1 signed LAN KEM refresh request: peer=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) requesterProtocolIdentity=\(Self.protocolIdentityLogRedaction) suites=\(requestedSuites.map(\.rawValue).joined(separator: ",")) suiteWireIds=\(requestedSuites.map { String(format: "0x%04X", $0.wireId) }.joined(separator: ",")) pinnedProtocolIdentity=\(pinnedProtocolFingerprints.isEmpty ? 0 : 1) missingPeerKEM=1 lifecycle=missing-kem>request"
        logger.info("\(requestLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(requestLine)

        if case .kemRefreshFailure(let failure) = exchange.response {
            throw Self.signedLANRefreshFailure("remote rejected SKR-1 stage=\(failure.stage) reasonCode=\(failure.reasonCode)")
        }
        guard case .signedKEMRefresh(let payload) = exchange.response else {
            throw Self.signedLANRefreshFailure("unexpected SKR-1 response type")
        }

        let minimumGeneration = await PeerKEMBootstrapStore.shared.maximumKEMGeneration(forCandidates: candidates)
        let validated = try payload.validatedForStrictPQCImport(
            request: request,
            pinnedProtocolFingerprints: pinnedProtocolFingerprints,
            minimumGeneration: minimumGeneration
        )
        try await PeerKEMBootstrapStore.shared.upsertSignedKEMRefresh(
            deviceIds: candidates + [targetDeviceId, validated.deviceId] + validated.aliases,
            payload: validated,
            request: request,
            pinnedProtocolFingerprints: pinnedProtocolFingerprints,
            minimumGeneration: minimumGeneration
        )
        await PeerProtocolIdentityBootstrapStore.shared.upsert(
            deviceIds: candidates + [targetDeviceId, validated.deviceId] + validated.aliases,
            fingerprints: [validated.protocolIdentityFingerprint]
        )
        let importedSuites = validated.kemPublicKeys
            .map { CryptoSuite(wireId: $0.suiteWireId).rawValue }
            .sorted()
            .joined(separator: ",")
        let totalLatencyMs = Date().timeIntervalSince(startedAt) * 1_000.0
	        let verifiedLine = String(
	            format: "🔐 SKR-1 signed LAN KEM refresh verified and imported: peer=%@ suites=%@ wireId=%@ pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=%.1f connectLatencyMs=%.1f retryCount=%d lifecycle=served>verified metricScope=application-control-channel",
	            Self.protocolIdentityLogRedaction,
	            importedSuites,
	            validated.kemPublicKeys.map { String(format: "0x%04X", $0.suiteWireId) }.sorted().joined(separator: ","),
            totalLatencyMs,
            exchange.connectLatencyMs,
            max(0, exchange.attemptCount - 1)
        )
        logger.info("\(verifiedLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(verifiedLine)

        let evidence = await PeerKEMBootstrapStore.shared.signedRefreshEvidence(forCandidates: candidates)
        guard Self.signedRefreshEvidenceSatisfiesStrictPQC(evidence, preferredTargetSuite: preferredTargetSuite) else {
            throw Self.signedLANRefreshFailure("SKR-1 completed but strict suite still unsatisfied")
        }
    }

    private func exchangeBootstrapControlMessage(
        _ message: AppMessage,
        endpoints: [NWEndpoint],
        timeoutSeconds: TimeInterval
    ) async throws -> BootstrapControlExchangeResult {
        var lastError: Error?
        var failedAttemptCount = 0
        for (index, endpoint) in endpoints.enumerated() {
            try Task.checkCancellation()
            let connection = makeConnection(to: endpoint, securityPlan: .plainTCP, interfacePreference: .automatic)
            let connectStartedAt = Date()
            RemoteControlSmokeStatusWriter.append(
                "bootstrap-control-attempt index=\(index) endpointClass=\(Self.smokeEndpointClass(endpoint)) peerToPeer=\(Self.shouldIncludePeerToPeer(for: endpoint) ? 1 : 0) endpoint=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(endpoint.debugDescription))"
            )
            do {
                try await waitForBootstrapControlConnection(
                    connection,
                    endpoint: endpoint,
                    attemptIndex: index,
                    timeoutSeconds: min(10, max(3, timeoutSeconds))
                )
                let connectLatencyMs = Date().timeIntervalSince(connectStartedAt) * 1_000.0
                RemoteControlSmokeStatusWriter.append(
                    String(
                        format: "bootstrap-control-ready index=%d endpointClass=%@ connectLatencyMs=%.1f",
                        index,
                        Self.smokeEndpointClass(endpoint),
                        connectLatencyMs
                    )
                )
                try await sendBootstrapFrame(try JSONEncoder().encode(message), over: connection)
                let responseFrame = try await Self.receiveBootstrapFrame(
                    over: connection,
                    timeoutSeconds: timeoutSeconds
                )
                connection.cancel()
                let decoded = try JSONDecoder().decode(
                    AppMessage.self,
                    from: Self.normalizeInboundControlFrame(responseFrame)
                )
                return BootstrapControlExchangeResult(
                    response: decoded,
                    endpoint: endpoint,
                    connectLatencyMs: connectLatencyMs,
                    attemptCount: index + 1,
                    failedAttemptCount: failedAttemptCount
                )
	            } catch {
	                if error is CancellationError || Task.isCancelled {
	                    connection.stateUpdateHandler = nil
	                    connection.cancel()
	                    throw CancellationError()
	                }
	                failedAttemptCount += 1
	                lastError = error
	                connection.cancel()
	                logger.warning(
	                    "⚠️ bootstrap control exchange failed endpoint=\(Self.protocolIdentityLogRedaction, privacy: .public) error=\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
	                )
                RemoteControlSmokeStatusWriter.append(
                    "bootstrap-control-failed index=\(index) endpointClass=\(Self.smokeEndpointClass(endpoint)) error=\(SkyBridgeDiagnosticRedaction.errorSummary(error))"
                )
	            }
        }
        throw lastError ?? P2PDiscoveryError.connectionCancelled
    }

    private func waitForBootstrapControlConnection(
        _ connection: NWConnection,
        endpoint: NWEndpoint,
        attemptIndex: Int,
        timeoutSeconds: TimeInterval
    ) async throws {
        let cancellationHandle = ConnectionWaitCancellationHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let context = WaitForConnectionContext(continuation: continuation)
                cancellationHandle.install(context, connection: connection)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        context.complete(.success(())) {
                            connection.stateUpdateHandler = nil
                        }
                    case .waiting(let error):
                        let path = connection.currentPath
                        if context.shouldReportWaiting() {
                            RemoteControlSmokeStatusWriter.append(
                                "bootstrap-control-waiting index=\(attemptIndex) endpointClass=\(Self.smokeEndpointClass(endpoint)) \(Self.bootstrapConnectionWaitingSummary(error, path: path))"
                            )
                        }
                        if Self.isLocalNetworkPermissionDenied(error, path: path) {
                            context.complete(.failure(P2PDiscoveryError.localNetworkPermissionDenied)) {
                                connection.stateUpdateHandler = nil
                            }
                        }
                    case .failed(let error):
                        context.complete(.failure(error)) {
                            connection.stateUpdateHandler = nil
                        }
                    case .cancelled:
                        context.complete(.failure(P2PDiscoveryError.connectionCancelled)) {
                            connection.stateUpdateHandler = nil
                        }
                    default:
                        break
                    }
                }
                guard !Task.isCancelled else {
                    cancellationHandle.cancel(connection: connection)
                    return
                }
                connection.start(queue: outboundConnectionQueue)
                context.timeoutTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    context.complete(.failure(P2PDiscoveryError.timeout))
                }
            }
        } onCancel: {
            cancellationHandle.cancel(connection: connection)
        }
    }

    private func sendBootstrapFrame(_ data: Data, over connection: NWConnection) async throws {
        var framed = Data()
        var length = UInt32(data.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(data)
        try await Self.sendContent(framed, over: connection, timeoutSeconds: 5.0)
    }

    /// Races a bootstrap frame against a deadline without leaving an
    /// uncancellable `NWConnection.receive` continuation behind. Cancelling
    /// the connection is the only reliable way to unblock Network.framework's
    /// receive callback, so every unsuccessful exit closes the connection
    /// before the task group waits for its children.
    nonisolated static func receiveBootstrapFrame(
        over connection: NWConnection,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        let reader = FramedReader.nwConnection(connection)
        return try await raceBootstrapReceive(
            timeoutSeconds: timeoutSeconds,
            cancelReceive: { connection.cancel() },
            receive: { try await reader.receiveFrame(maxFrameLength: 1_048_576) }
        )
    }

    nonisolated static func raceBootstrapReceive(
        timeoutSeconds: TimeInterval,
        cancelReceive: @escaping @Sendable () -> Void,
        receive: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await receive()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw P2PDiscoveryError.timeout
                }

                do {
                    guard let result = try await group.next() else {
                        throw P2PDiscoveryError.connectionCancelled
                    }
                    group.cancelAll()
                    return result
                } catch {
                    // `group.cancelAll()` does not cancel an outstanding
                    // Network.framework receive callback. Close first so
                    // task-group teardown cannot wait forever.
                    cancelReceive()
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            cancelReceive()
        }
    }

    private func localProtocolIdentityProofForOutboundPIB(
        targetFingerprint: String? = nil
    ) async throws -> LocalProtocolIdentityProof {
        let normalizedTargetFingerprint = Self.normalizedFingerprint(targetFingerprint)
        let identities = try await CommittedLocalProtocolIdentitySnapshot
            .loadActiveAndCompatibility()
        if let identity = identities.first(where: {
            normalizedTargetFingerprint == nil
                || normalizedTargetFingerprint == $0.authoritativeFingerprint
        }) {
            return LocalProtocolIdentityProof(
                algorithm: identity.algorithm,
                publicKey: identity.publicKey,
                keyHandle: identity.keyHandle,
                fingerprint: identity.authoritativeFingerprint
            )
        }
        throw Self.protocolIdentityBindingFailure("missing local protocol identity proof")
    }

    private func localOutboundProtocolIdentityDeviceId() async throws -> String {
        let raw = try await SelfIdentityProvider.shared
            .protocolIdentityDeviceId(allowCreate: true)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Self.protocolIdentityBindingFailure("local device id unavailable")
        }
        return trimmed
    }

    private nonisolated static func cryptoProviderSupportedSuites(
        policy: CryptoProviderFactory.SelectionPolicy
    ) async -> [CryptoSuite] {
        await Task.detached(priority: .utility) {
            CryptoProviderFactory.make(policy: policy).supportedSuites
        }.value
    }

    private static func preferredStrictPQCOutboundTargetSuite() async -> CryptoSuite? {
        await cryptoProviderSupportedSuites(policy: .requirePQC)
            .first(where: { $0.isPQCGroup && $0.isNegotiable })?
            .canonicalKEMSuite
    }

    private static func signedLANRefreshRequestedSuites(preferredTargetSuite: CryptoSuite?) async -> [CryptoSuite] {
        let providerSuites = await cryptoProviderSupportedSuites(policy: .requirePQC)
            .filter { $0.isPQCGroup && $0.isNegotiable }
            .map(\.canonicalKEMSuite)
        var suites = providerSuites
        if let preferred = preferredTargetSuite?.canonicalKEMSuite, preferred.isNegotiable, preferred.isPQCGroup {
            suites.insert(preferred, at: 0)
        }
        var seen = Set<UInt16>()
        let unique = suites.filter { suite in
            guard suite.isNegotiable, suite.isPQCGroup else { return false }
            return seen.insert(suite.wireId).inserted
        }
        return unique.isEmpty ? [.mlkem768MLDSA65] : unique
    }

    private static func strictPQCOutboundPreflightAction(
        trustedPeerKEMSuites: Set<CryptoSuite>,
        signedRefreshEvidence: PeerKEMBootstrapStore.SignedRefreshEvidence?,
        pinnedProtocolFingerprints: Set<String>,
        preferredTargetSuite: CryptoSuite?
    ) -> StrictPQCOutboundPreflightAction {
        let normalizedPins = Set(pinnedProtocolFingerprints.compactMap(normalizedFingerprint))
        guard !normalizedPins.isEmpty else {
            return .attemptOOBProtocolIdentityBindingThenRefresh
        }
        if signedRefreshEvidenceSatisfiesStrictPQC(
            signedRefreshEvidence,
            preferredTargetSuite: preferredTargetSuite
        ) {
            return .proceed
        }
        if signedRefreshEvidence == nil {
            return .attemptOOBProtocolIdentityBindingThenRefresh
        }
        if canSatisfyStrictPQCWithTrustedKEM(
            trustedPeerKEMSuites: trustedPeerKEMSuites,
            preferredTargetSuite: preferredTargetSuite
        ) {
            return .attemptSignedLANRefresh
        }
        return .attemptSignedLANRefresh
    }

    private static func canSatisfyStrictPQCWithTrustedKEM(
        trustedPeerKEMSuites: Set<CryptoSuite>,
        preferredTargetSuite: CryptoSuite?
    ) -> Bool {
        if let preferredTargetSuite {
            return trustedPeerKEMSuites.contains {
                suiteSupportsTargetKEM($0, target: preferredTargetSuite)
            }
        }
        return trustedPeerKEMSuites.contains(where: { $0.isPQCGroup })
    }

    private static func suiteSupportsTargetKEM(_ availableSuite: CryptoSuite, target: CryptoSuite) -> Bool {
        if availableSuite == target { return true }
        if availableSuite.canonicalKEMSuite == target.canonicalKEMSuite { return true }
        if target.isHybrid { return availableSuite.isHybrid }
        if availableSuite.isHybrid { return target.isHybrid }
        return false
    }

    private static func signedRefreshEvidenceSatisfiesStrictPQC(
        _ evidence: PeerKEMBootstrapStore.SignedRefreshEvidence?,
        preferredTargetSuite: CryptoSuite?
    ) -> Bool {
        guard let evidence else { return false }
        let suites = Set(evidence.suiteWireIds.map(CryptoSuite.init(wireId:)))
        return canSatisfyStrictPQCWithTrustedKEM(
            trustedPeerKEMSuites: suites,
            preferredTargetSuite: preferredTargetSuite
        )
    }

    private static func shouldAttemptOOBProtocolIdentityBinding(afterSKRFailure error: Error) -> Bool {
        let reason = error.localizedDescription.lowercased()
        return reason.contains("requester protocol identity fingerprint not pinned")
            || reason.contains("requester_protocol_identity_not_pinned")
            || reason.contains("missing requester protocol identity")
            || reason.contains("pinned protocol identity mismatch")
            || reason.contains("pinned_protocol_identity_mismatch")
            || reason.contains("missing pinned protocol identity")
            || reason.contains("missing_pinned")
    }

    private static func trustedKEMSuites(
        provider: DefaultHandshakeTrustProvider,
        candidates: [String]
    ) async -> Set<CryptoSuite> {
        var suites = Set<CryptoSuite>()
        for candidate in candidates {
            suites.formUnion(await provider.trustedKEMPublicKeys(for: candidate).keys)
        }
        return suites
    }

    private static func trustedProtocolFingerprints(
        provider: DefaultHandshakeTrustProvider,
        candidates: [String]
    ) async -> Set<String> {
        var fingerprints = Set<String>()
        for candidate in candidates {
            fingerprints.formUnion(await provider.trustedFingerprints(for: candidate))
        }
        return Set(fingerprints.compactMap(normalizedFingerprint))
    }

    private static func strictPQCBootstrapEndpointCandidates(from endpointAttempts: [NWEndpoint]) -> [NWEndpoint] {
        let service = endpointAttempts.filter { endpoint in
            if case .service = endpoint { return true }
            return false
        }
        let directRoutable = endpointAttempts.filter { endpoint in
            guard case .hostPort(let host, _) = endpoint else { return false }
            return isRoutableBootstrapHost(String(describing: host))
        }
        let directAny = endpointAttempts.filter { endpoint in
            if case .hostPort = endpoint { return true }
            return false
        }
        var seen = Set<String>()
        return (directRoutable + directAny + service).filter { endpoint in
            let key = endpoint.debugDescription
            return seen.insert(key).inserted
        }
    }

    private static func isRoutableBootstrapHost(_ raw: String) -> Bool {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let scope = value.firstIndex(of: "%") {
            value = String(value[..<scope])
        }
        if IPv4Address(value) != nil {
            return !isNonRoutableIPv4Endpoint(value)
        }
        if IPv6Address(value) != nil {
            return value != "::" && value != "::1" && !value.hasPrefix("fe80:") && !value.hasPrefix("ff")
        }
        return true
    }

    private static func outboundStrictPQCTrustCandidates(
        for device: DiscoveredDevice,
        stableTarget: String
    ) -> [String] {
        var ordered = [String]()
        var seen = Set<String>()
        func append(_ raw: String?) {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  seen.insert(trimmed).inserted else {
                return
            }
            ordered.append(trimmed)
        }
        append(stableTarget)
        for candidate in stableProtocolIdentityCandidates(for: device) {
            append(candidate)
        }
        for candidate in P2PDiscoveryKEMAliasRepairPolicy.aliasRepairCandidates(for: device) {
            append(candidate)
        }
        return ordered
    }

    private static func stableProtocolIdentityCandidates(for device: DiscoveredDevice) -> [String] {
        var ordered = [String]()
        var seen = Set<String>()
        func appendStable(_ raw: String?) {
            guard let stable = PeerTrustLookup.persistentDeviceId(from: raw),
                  seen.insert(stable).inserted else {
                return
            }
            ordered.append(stable)
        }
        appendStable(device.deviceId)
        appendStable(device.uniqueIdentifier)
        for routeIdentifier in device.routeIdentifiers {
            appendStable(routeIdentifier)
        }
        return ordered
    }

    private static func uniqueStableProtocolIdentityCandidate(from candidates: [String]) -> String? {
        var stableCandidates = [String]()
        var seen = Set<String>()
        for candidate in candidates {
            guard let stable = PeerTrustLookup.persistentDeviceId(from: candidate),
                  seen.insert(stable).inserted else {
                continue
            }
            stableCandidates.append(stable)
        }
        return stableCandidates.count == 1 ? stableCandidates[0] : nil
    }

    private static func bootstrapEndpointDigest(for device: DiscoveredDevice) -> String? {
        let material = [
            device.uniqueIdentifier,
            device.ipv4,
            device.ipv6,
            device.services.sorted().joined(separator: ","),
            device.portMap.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
        guard !material.isEmpty else { return nil }
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func secureRandomNonce(count: Int = 24) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return Data(bytes)
    }

    private static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    nonisolated private static func signedLANRefreshFailure(_ reason: String) -> NSError {
        NSError(
            domain: "SkyBridge.SignedLANRefresh",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    nonisolated private static func protocolIdentityBindingFailure(_ reason: String) -> NSError {
        NSError(
            domain: "SkyBridge.ProtocolIdentityBinding",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    private static func protocolIdentityBindingResponseTimeoutSeconds() -> Double {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_PIB_APPROVAL_TIMEOUT_SECONDS"],
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 195
        }
        return Double(min(max(value + 15, 45), 315))
    }

    private nonisolated static func isNonRoutableIPv4Endpoint(_ value: String) -> Bool {
        guard IPv4Address(value) != nil else { return false }
        return value.hasPrefix("169.254.")
            || value.hasPrefix("127.")
            || value.hasPrefix("0.")
            || value == "255.255.255.255"
    }

    private func interfacePreferences(
        for endpoint: NWEndpoint,
        preferUSBRoute: Bool
    ) -> [InterfacePreference] {
        guard preferUSBRoute else { return [.automatic] }
        if case .hostPort = endpoint {
            return [.wiredEthernetOnly, .automatic]
        }
        return [.automatic]
    }

    private func stableConnectionKey(for device: DiscoveredDevice) -> String {
        Self.handshakeDeviceIdentifier(for: device)
    }

    static func handshakeDeviceIdentifier(for device: DiscoveredDevice) -> String {
        P2PDiscoveryKEMAliasRepairPolicy.handshakeDeviceIdentifier(for: device)
    }

    private func repairPeerKEMBootstrapAliasesIfNeeded(for device: DiscoveredDevice) async {
        let handshakeId = Self.handshakeDeviceIdentifier(for: device)
        let aliases = Self.kemBootstrapAliasRepairCandidates(for: device)
        guard !handshakeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !aliases.isEmpty else {
            return
        }

        let provider = DefaultHandshakeTrustProvider()
        let directKeys = await provider.trustedKEMPublicKeys(for: handshakeId)
        guard directKeys.isEmpty else { return }

        for alias in aliases where alias != handshakeId {
            let aliasKeys = await provider.trustedKEMPublicKeys(for: alias)
            guard !aliasKeys.isEmpty else { continue }
            let kemKeys = P2PDiscoveryKEMAliasRepairPolicy.kemPublicKeys(from: aliasKeys)
            await PeerKEMBootstrapStore.shared.upsert(
                deviceIds: aliases,
                kemPublicKeys: kemKeys
	            )
	            logger.info(
	                "🔧 已修复 P2P KEM bootstrap 缓存别名: selected=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(handshakeId), privacy: .public) alias=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(alias), privacy: .public) keys=\(kemKeys.count)"
	            )
	            return
	        }

        guard let record = Self.uniqueKEMTrustRecordForAliasRepair(
            device: device,
            records: TrustSyncService.shared.activeTrustRecords
        ) else {
            return
        }
        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(record.kemPublicKeys ?? [])
        guard !kemKeys.isEmpty else { return }

        await PeerKEMBootstrapStore.shared.upsert(
            deviceIds: aliases + PeerTrustLookup.recordLookupCandidates(record),
            kemPublicKeys: kemKeys
	        )
	        logger.info(
	            "🔧 已修复 P2P KEM 信任记录别名: selected=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(handshakeId), privacy: .public) trust=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(record.deviceId), privacy: .public) keys=\(kemKeys.count)"
	        )
	    }

    static func kemBootstrapAliasRepairCandidates(for device: DiscoveredDevice) -> [String] {
        P2PDiscoveryKEMAliasRepairPolicy.aliasRepairCandidates(for: device)
    }

    static func uniqueKEMTrustRecordForAliasRepair(
        device: DiscoveredDevice,
        records: [TrustRecord]
    ) -> TrustRecord? {
        P2PDiscoveryKEMAliasRepairPolicy.uniqueTrustRecord(
            for: device,
            records: records
        )
    }

    private func resolveLatestConnectableDevice(from device: DiscoveredDevice) -> DiscoveredDevice {
        let strongIdentity = (deviceId: device.deviceId, pubKeyFP: device.pubKeyFP)
        let routeBoundBonjourIdentifier = P2PDiscoveryBonjourPolicy.preferredRoutableBonjourIdentifier(for: device)
            ?? device.uniqueIdentifier
        guard let matchIndex = findDiscoveredDeviceIndex(
            name: device.name,
            ipv4: device.ipv4,
            ipv6: device.ipv6,
            bonjourIdentifier: routeBoundBonjourIdentifier,
            strongIdentity: strongIdentity
        ) else {
            return device
        }

        var refreshed = discoveredDevices[matchIndex]
        if refreshed.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let suppliedDeviceId = device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suppliedDeviceId.isEmpty {
            refreshed.deviceId = suppliedDeviceId
        }
        if refreshed.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let suppliedFingerprint = device.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suppliedFingerprint.isEmpty {
            refreshed.pubKeyFP = suppliedFingerprint
        }
        preserveSuppliedConnectableRouteContext(from: device, into: &refreshed)
        if refreshed.id != device.id {
            logger.info(
                "ℹ️ 连接目标已刷新为最新发现快照: \(device.name, privacy: .public) \(device.id.uuidString, privacy: .public) -> \(refreshed.id.uuidString, privacy: .public)"
            )
        }
        return refreshed
    }

    private func preserveSuppliedConnectableRouteContext(
        from supplied: DiscoveredDevice,
        into refreshed: inout DiscoveredDevice
    ) {
        guard Self.hasCompleteProtocolIdentity(
            deviceId: refreshed.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? supplied.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
            pubKeyFP: refreshed.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? supplied.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) else {
            return
        }

        let refreshedRoute = P2PDiscoveryBonjourPolicy.preferredRoutableBonjourIdentifier(for: refreshed)
        let suppliedRoute = P2PDiscoveryBonjourPolicy.preferredRoutableBonjourIdentifier(for: supplied)
        if let refreshedRoute,
           let suppliedRoute,
           P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(refreshedRoute)
                != P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(suppliedRoute) {
            return
        }

        let suppliedIPv4 = refreshed.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            ? supplied.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let suppliedIPv6 = refreshed.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            ? supplied.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        refreshed._updateTransient(
            ipv4: suppliedIPv4?.isEmpty == false ? suppliedIPv4 : nil,
            ipv6: suppliedIPv6?.isEmpty == false ? suppliedIPv6 : nil
        )
        for service in supplied.services {
            let normalized = service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == BonjourInteropContract.controlServiceType || normalized == "_skybridge._udp" else {
                continue
            }
            if !refreshed.services.contains(normalized) {
                refreshed.services.append(normalized)
            }
        }
        for (service, port) in supplied.portMap where port > 0 {
            let normalized = service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == BonjourInteropContract.controlServiceType || normalized == "_skybridge._udp" else {
                continue
            }
            if (refreshed.portMap[normalized] ?? 0) <= 0 {
                refreshed.portMap[normalized] = port
            }
        }
        refreshed.routeIdentifiers = DiscoveredDevice.mergedRouteIdentifiers(
            refreshed.routeIdentifiers,
            supplied.routeIdentifiers
        )
    }

    private func bonjourIdentifier(from endpoint: NWEndpoint) -> String? {
        guard case .service(let name, _, let domain, _) = endpoint else { return nil }
        let normalizedDomain = domain.isEmpty ? serviceDomain : domain.lowercased()
        return "bonjour:\(name)@\(normalizedDomain)"
    }

    private nonisolated static func numericNetworkAddresses(
        from endpoint: NWEndpoint
    ) -> (ipv4: String?, ipv6: String?) {
        guard case .hostPort(let host, _) = endpoint else { return (nil, nil) }
        switch host {
        case .ipv4(let address):
            return ("\(address)", nil)
        case .ipv6(let address):
            return (nil, "\(address)")
        case .name(let name, _):
            let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if IPv4Address(candidate) != nil {
                return (candidate, nil)
            }
            let unscoped = candidate.split(separator: "%", maxSplits: 1).first.map(String.init) ?? candidate
            if IPv6Address(unscoped) != nil {
                return (nil, candidate)
            }
            return (nil, nil)
        @unknown default:
            return (nil, nil)
        }
    }

    private nonisolated static func stableDiscoveryHydrationIdentity(
        for device: DiscoveredDevice,
        bonjourIdentifier: String?
    ) -> String? {
        if let deviceId = device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !deviceId.isEmpty {
            return "id:\(deviceId.lowercased())"
        }
        if let fingerprint = device.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !fingerprint.isEmpty {
            return "fp:\(fingerprint)"
        }
        return P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(bonjourIdentifier)
    }

    private nonisolated static func bonjourIdentifier(
        for route: DiscoveryHydrationRoute
    ) -> String {
        "bonjour:\(route.serviceName)@\(route.domain)"
    }

    private func currentHydrationDeviceIndex(
        for ticket: DiscoveryHydrationTicket
    ) -> Int? {
        let routeIdentifier = Self.bonjourIdentifier(for: ticket.route)
        return discoveredDevices.firstIndex { device in
            Self.stableDiscoveryHydrationIdentity(
                for: device,
                bonjourIdentifier: routeIdentifier
            ) == ticket.stableDeviceIdentity
                && Self.discoveredDevice(
                    device,
                    hasNormalizedBonjourIdentifier: routeIdentifier
                )
                && device.services.contains(ticket.serviceType)
        }
    }

    /// 断开与指定设备的连接
    @discardableResult
    public func disconnectFromDevice(_ deviceId: String) async -> Bool {
        logger.info("🔌 断开设备连接: \(deviceId)")

        let targetAliases = Set(PeerTrustLookup.lookupCandidates(for: deviceId))
        let activeKeys = Set(connections.keys)
            .union(authenticatedConnections.keys)
            .union(outboundConnectionAttemptIds.keys)
        let directMatches = activeKeys.contains(deviceId) ? [deviceId] : []
        let aliasedMatches = activeKeys.filter { candidate in
            let candidateAliases = Set(PeerTrustLookup.lookupCandidates(for: candidate))
            return !candidateAliases.isDisjoint(with: targetAliases)
        }
        let keysToDisconnect = Array(Set(directMatches).union(aliasedMatches))
        let normalizedTargetAliases = Set(targetAliases.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        let inboundSessionsToDisconnect = inboundControlSessions.filter { _, session in
            !session.aliases.isDisjoint(with: normalizedTargetAliases)
        }

        guard !keysToDisconnect.isEmpty || !inboundSessionsToDisconnect.isEmpty else {
            logger.info("ℹ️ 未找到匹配的活跃连接: \(deviceId)")
            return false
        }

        for key in keysToDisconnect {
            outboundConnectionAttemptIds.removeValue(forKey: key)
            if let authenticated = authenticatedConnections.removeValue(forKey: key) {
                authenticated.disconnect()
            }
            connections[key]?.stateUpdateHandler = nil
            connections[key]?.cancel()
            connections.removeValue(forKey: key)
        }
        await cancelInboundControlSessions(
            matching: Set(inboundSessionsToDisconnect.keys)
        )

        if connections.isEmpty && authenticatedConnections.isEmpty && inboundControlSessions.isEmpty && activeInboundSessions == 0 {
            connectionStatus = .disconnected
        }
        return true
    }

 /// 发送数据到指定设备
    public func sendData(_ data: Data, to deviceId: String) async throws {
        guard let connection = connections[deviceId] else {
            throw P2PDiscoveryError.deviceNotConnected
        }

        try await Self.sendContent(data, over: connection, timeoutSeconds: 5.0)
    }

    private nonisolated static func sendContent(
        _ data: Data,
        over connection: NWConnection,
        timeoutSeconds: TimeInterval
    ) async throws {
        let cancellationHandle = SendContentCancellationHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let context = SendContentContext(continuation: continuation, connection: connection)
                cancellationHandle.install(context)
                guard !Task.isCancelled else {
                    cancellationHandle.cancel(connection: connection)
                    return
                }
                context.timeoutTask = Task { [context] in
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    context.cancelConnection()
                    context.complete(.failure(P2PDiscoveryError.timeout))
                }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        context.complete(.failure(error))
                    } else {
                        context.complete(.success(()))
                    }
                })
            }
        } onCancel: {
            cancellationHandle.cancel(connection: connection)
        }
    }

 // MARK: - Bonjour 广播（本机作为服务端）

 /// 启动广播服务（Bonjour）
    @MainActor public func startAdvertising(forceRebind: Bool = false) async throws {
        advertisingLifecycleGeneration &+= 1
        let generation = advertisingLifecycleGeneration
        let previousTask = advertisingLifecycleTask
        previousTask?.cancel()

        let task: Task<Void, Error> = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            if let previousTask {
                do {
                    try await previousTask.value
                } catch is CancellationError {
                    self.logger.debug("ℹ️ 前一广播生命周期任务已取消")
                } catch {
                    self.logger.debug("ℹ️ 前一广播生命周期任务失败，继续当前请求")
                }
            }
            try Task.checkCancellation()
            guard self.isScanning,
                  self.advertisingLifecycleGeneration == generation else {
                throw CancellationError()
            }
            try await self.performStartAdvertising(forceRebind: forceRebind)
            try Task.checkCancellation()
            guard self.isScanning,
                  self.advertisingLifecycleGeneration == generation else {
                throw CancellationError()
            }
        }
        advertisingLifecycleTask = task
        try await task.value
    }

    @MainActor
    private func performStartAdvertising(forceRebind: Bool) async throws {
        logger.info("📡 开始广播服务")

        let centerSnapshot = await ServiceAdvertiserCenter.shared.advertisementSnapshot(for: Self.controlServiceType)
            let centerHealthyForP2P = centerSnapshot.isOwned(by: Self.controlAdvertisementOwner)
                && centerSnapshot.isConnectable
            if !forceRebind, centerHealthyForP2P {
                isAdvertising = true
                logger.debug("📡 广播已在运行，忽略重复启动")
                return
            }
            if !forceRebind,
               centerSnapshot.isOwned(by: Self.controlAdvertisementOwner),
               centerSnapshot.isStarting {
                do {
                    let port = try await ServiceAdvertiserCenter.shared.waitUntilReady(Self.controlServiceType)
                    isAdvertising = true
                    logger.info("📡 并发启动的广播已就绪，端口: \(port)")
                    return
                } catch {
                    logger.error("❌ 等待正在启动的广播失败: \(error.localizedDescription)")
                }
            }

            if centerSnapshot.isAdvertising {
                if forceRebind {
                    logger.info("🔁 强制重绑 _skybridge._tcp 广播监听")
                } else if !centerSnapshot.isOwned(by: Self.controlAdvertisementOwner) {
                    logger.warning(
                        "⚠️ 检测到 _skybridge._tcp 被外部组件占用，切换到 P2PDiscoveryService 独占监听: owner=\(centerSnapshot.owner ?? "-", privacy: .public)"
                    )
                } else {
                    logger.warning("⚠️ _skybridge._tcp 广播监听状态不可连接，执行自愈重绑")
                }
                await ServiceAdvertiserCenter.shared.stopAdvertising(Self.controlServiceType)
            } else if isAdvertising {
                logger.warning("⚠️ _skybridge._tcp 广播状态失配：内部标记为运行中，但中央监听器已丢失，执行自愈重绑")
            }

            if let existing = listener {
                existing.cancel()
                listener = nil
            }
            isAdvertising = false

            do {
                let port = try await ServiceAdvertiserCenter.shared.startAdvertising(
                    serviceName: getDeviceName(),
                    serviceType: Self.controlServiceType,
                    owner: Self.controlAdvertisementOwner,
                    includePeerToPeer: false,
                    connectionHandler: { [weak self] connection in
                        Task { @MainActor in self?.handleNewConnection(connection) }
                    },
                    stateHandler: { [weak self] state in
                        Task { @MainActor in self?.handleListenerStateUpdate(state) }
                    }
                )
                isAdvertising = true
                if port > 0 {
                    logger.info("📡 广播服务已启动，端口: \(port)")
                } else {
                    logger.info("📡 广播服务已启动（系统分配端口）")
                }
            } catch {
                isAdvertising = false
                logger.error("❌ 启动广播服务失败: \(error.localizedDescription)")
                throw error
            }
    }

    @MainActor public func ensureAdvertisingHealthy() async throws {
        let snapshot = await ServiceAdvertiserCenter.shared.advertisementSnapshot(for: Self.controlServiceType)
        let healthyForP2P = snapshot.isOwned(by: Self.controlAdvertisementOwner)
            && snapshot.isConnectable
        if healthyForP2P {
            isAdvertising = true
            return
        }
        if snapshot.isOwned(by: Self.controlAdvertisementOwner), snapshot.isStarting {
            do {
                _ = try await ServiceAdvertiserCenter.shared.waitUntilReady(Self.controlServiceType)
                isAdvertising = true
                return
            } catch {
                logger.error("❌ P2P 广播启动健康检查失败: \(error.localizedDescription)")
            }
        }

        logger.warning(
            "⚠️ P2P 广播健康检查失败，准备重绑: state=\(snapshot.state.rawValue, privacy: .public) owner=\(snapshot.owner ?? "-", privacy: .public) port=\(snapshot.port.map(String.init) ?? "-", privacy: .public) internal=\(self.isAdvertising, privacy: .public)"
        )
        try await startAdvertising(forceRebind: snapshot.isAdvertising || self.isAdvertising)
    }

 /// 停止广播服务
    private func stopAdvertising() {
        advertisingLifecycleGeneration &+= 1
        let generation = advertisingLifecycleGeneration
        let previousTask = advertisingLifecycleTask
        previousTask?.cancel()
        let task: Task<Void, Error> = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previousTask {
                do {
                    try await previousTask.value
                } catch is CancellationError {
                    self.logger.debug("ℹ️ 广播启动已取消，继续停止")
                } catch {
                    self.logger.debug("ℹ️ 广播启动失败后继续停止")
                }
            }
            guard self.advertisingLifecycleGeneration == generation else { return }
            await self.performStopAdvertising()
        }
        advertisingLifecycleTask = task
    }

    private func performStopAdvertising() async {
        logger.info("📡 停止广播服务")
        cancelAllProvisionalInboundConnections()
        listener?.cancel()
        listener = nil
        isAdvertising = false
        await ServiceAdvertiserCenter.shared.stopAdvertising(
            Self.controlServiceType,
            owner: Self.controlAdvertisementOwner
        )
    }

 // MARK: - Bonjour 浏览结果处理

 /// 处理浏览器状态更新
    private func handleBrowserStateUpdate(_ state: NWBrowser.State, for serviceType: String) {
        switch state {
        case .ready:
            logger.info("🔍 浏览器就绪: \(serviceType)")
        case .failed(let error):
            logger.error("❌ 浏览器失败 [\(serviceType)]: \(error.localizedDescription)")
        case .cancelled:
            logger.info("⏹️ 浏览器已取消: \(serviceType)")
        default:
            break
        }
    }

 /// 处理浏览结果变化 - 增强版：支持多服务类型
    private func handleBrowseResultsChanged(
        results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>,
        serviceType: String
    ) {
        for change in changes {
            switch change {
            case .added(let result):
                upsertDiscoveredDevice(
                    from: result,
                    serviceType: serviceType,
                    replaceExistingHydration: false
                )
            case .removed(let result):
                removeDiscoveredDevice(from: result, serviceType: serviceType)
            case .changed(old: let old, new: let new, flags: _):
                invalidateDiscoveryHydration(for: old.endpoint)
                upsertDiscoveredDevice(
                    from: new,
                    serviceType: serviceType,
                    replaceExistingHydration: true
                )
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    /// 从 Bonjour TXT 提取强身份（稳定 deviceId / pubKeyFP）
    private func extractStrongIdentity(from result: NWBrowser.Result) -> (deviceId: String?, pubKeyFP: String?) {
        guard case .bonjour(let txtRecord) = result.metadata else {
            return (nil, nil)
        }
        let dict = BonjourTXTParser.parse(txtRecord)
        let deviceId = sanitizeStableIdentity(
            dict["deviceId"]
                ?? dict["id"]
                ?? dict["deviceID"]
                ?? dict["device_id"]
                ?? dict["uuid"]
                ?? dict["uniqueId"]
                ?? dict["unique_id"]
        )
        let pubKeyFP = sanitizePubKeyFingerprint(
            dict["pubKeyFP"]
                ?? dict["pubkeyfp"]
                ?? dict["pubkeyFP"]
                ?? dict["pub_key_fp"]
                ?? dict["identityFingerprint"]
                ?? dict["fp"]
        )
        return (deviceId, pubKeyFP)
    }

    private func sanitizeStableIdentity(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        guard value.count >= 8 else { return nil }
        return value
    }

    private func sanitizePubKeyFingerprint(_ raw: String?) -> String? {
        BonjourInteropContract.normalizedPubKeyFingerprint(raw)
    }

    private func extractSOAFlag(from result: NWBrowser.Result) -> Bool {
        guard case .bonjour(let txtRecord) = result.metadata else {
            return false
        }
        let dict = BonjourTXTParser.parse(txtRecord)
        return P2PDiscoveryBonjourPolicy.normalizeSOAFlag(dict["hs_soa"] ?? dict["HS_SOA"])
    }

    private func extractNetworkLinkStatus(from result: NWBrowser.Result) -> DeviceNetworkLinkStatus? {
        guard case .bonjour(let txtRecord) = result.metadata else { return nil }
        return BonjourTXTParser.extractNetworkLinkStatus(txtRecord)
    }

    private nonisolated static func connectionTypes(
        from status: DeviceNetworkLinkStatus?,
        defaultTypes: Set<DeviceConnectionType>
    ) -> Set<DeviceConnectionType> {
        guard let status else { return defaultTypes }
        var updated = defaultTypes
        updated.remove(.unknown)
        updated.insert(status.connectionType)
        return updated
    }

    private nonisolated static func signalPercentage(from status: DeviceNetworkLinkStatus?) -> Double? {
        status?.normalizedSignalStrength.map { $0 * 100.0 }
    }

    private func extractAdvertisedServicePort(from result: NWBrowser.Result, serviceType: String) -> Int? {
        guard case .bonjour(let txtRecord) = result.metadata else { return nil }
        let dict = BonjourTXTParser.parse(txtRecord)
        return P2PDiscoveryBonjourPolicy.advertisedServicePort(from: dict, serviceType: serviceType)
    }

    private func findDiscoveredDeviceIndex(
        name: String,
        ipv4: String?,
        ipv6: String?,
        bonjourIdentifier: String?,
        strongIdentity: (deviceId: String?, pubKeyFP: String?)
    ) -> Int? {
        let normalizedDeviceId = strongIdentity.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFingerprint = strongIdentity.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasStrongIdentity = normalizedDeviceId?.isEmpty == false || normalizedFingerprint?.isEmpty == false
        let normalizedBonjourIdentifier = P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(bonjourIdentifier)
        let normalizedIPv4 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(ipv4)
        let normalizedIPv6 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(ipv6)

        if let strongIndex = discoveredDevices.firstIndex(where: { existing in
            if let normalizedDeviceId,
               !normalizedDeviceId.isEmpty,
               let existingId = existing.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
               existingId == normalizedDeviceId {
                return true
            }

            if let normalizedFingerprint,
               !normalizedFingerprint.isEmpty,
               let existingFP = existing.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               existingFP == normalizedFingerprint {
                return true
            }
            return false
        }) {
            return strongIndex
        }

        if hasStrongIdentity,
           let normalizedBonjourIdentifier,
           P2PDiscoveryBonjourPolicy.isRoutableBonjourIdentifier(bonjourIdentifier),
           Self.hasCompleteProtocolIdentity(
               deviceId: normalizedDeviceId,
               pubKeyFP: normalizedFingerprint
           ),
           let routedIndex = discoveredDevices.firstIndex(where: { existing in
               Self.discoveredDevice(existing, hasNormalizedBonjourIdentifier: normalizedBonjourIdentifier)
           }) {
            return routedIndex
        }

        guard !hasStrongIdentity else {
            return nil
        }

        if let normalizedBonjourIdentifier,
           P2PDiscoveryBonjourPolicy.isRoutableBonjourIdentifier(bonjourIdentifier) {
            let routeMatchedIndexes = discoveredDevices.indices.filter {
                Self.discoveredDevice(
                    discoveredDevices[$0],
                    hasNormalizedBonjourIdentifier: normalizedBonjourIdentifier
                )
            }
            if let identityBackedIndex = routeMatchedIndexes.first(where: {
                Self.hasCompleteProtocolIdentity(
                    deviceId: discoveredDevices[$0].deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
                    pubKeyFP: discoveredDevices[$0].pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            }) {
                return identityBackedIndex
            }
            if let routedIndex = routeMatchedIndexes.first {
                return routedIndex
            }
        }

        return discoveredDevices.firstIndex(where: { existing in
            if let normalizedBonjourIdentifier,
               let existingIdentifier = P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(existing.uniqueIdentifier),
               existingIdentifier == normalizedBonjourIdentifier {
                return true
            }

            if let normalizedIPv4,
               let existingIPv4 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(existing.ipv4),
               existingIPv4 == normalizedIPv4 {
                return true
            }

            if let normalizedIPv6,
               let existingIPv6 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(existing.ipv6),
               existingIPv6 == normalizedIPv6 {
                return true
            }

            return false
        })
    }

    private nonisolated static func hasCompleteProtocolIdentity(
        deviceId: String?,
        pubKeyFP: String?
    ) -> Bool {
        guard let deviceId, !deviceId.isEmpty,
              let pubKeyFP, !pubKeyFP.isEmpty else {
            return false
        }
        return true
    }

    private nonisolated static func discoveredDevice(
        _ device: DiscoveredDevice,
        hasNormalizedBonjourIdentifier normalizedBonjourIdentifier: String
    ) -> Bool {
        for identifier in [device.uniqueIdentifier].compactMap({ $0 }) + device.routeIdentifiers {
            guard P2PDiscoveryBonjourPolicy.isRoutableBonjourIdentifier(identifier),
                  let existingIdentifier = P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(identifier),
                  existingIdentifier == normalizedBonjourIdentifier else {
                continue
            }
            return true
        }
        return false
    }

    nonisolated static func shouldProtectDiscoveryCapacityRecord(
        isLocalDevice: Bool,
        isTrusted: Bool,
        hasActiveConnection: Bool
    ) -> Bool {
        isLocalDevice || isTrusted || hasActiveConnection
    }

    nonisolated static func canAdmitHydrationTaskOwner(currentCount: Int, limit: Int) -> Bool {
        currentCount < max(1, limit)
    }

    nonisolated static func boundedRouteIdentifierMerge(
        existing: [String],
        incoming: String?,
        limit: Int
    ) -> BoundedRouteMergeResult {
        guard let incoming = incoming?.trimmingCharacters(in: .whitespacesAndNewlines),
              !incoming.isEmpty else {
            return BoundedRouteMergeResult(identifiers: existing, accepted: true)
        }
        let normalizedIncoming = incoming.lowercased()
        if existing.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedIncoming
        }) {
            return BoundedRouteMergeResult(identifiers: existing, accepted: true)
        }
        guard existing.count < max(1, limit) else {
            return BoundedRouteMergeResult(identifiers: existing, accepted: false)
        }
        return BoundedRouteMergeResult(identifiers: existing + [incoming], accepted: true)
    }

    private func isTrustedDiscoveryDevice(_ device: DiscoveredDevice) -> Bool {
        if let deviceID = device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !deviceID.isEmpty,
           TrustSyncService.shared.isTrusted(deviceId: deviceID) {
            return true
        }
        if let fingerprint = device.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !fingerprint.isEmpty,
           TrustSyncService.shared.isTrusted(pubKeyFP: fingerprint) {
            return true
        }
        return false
    }

    private func hasActiveDiscoveryConnection(_ device: DiscoveredDevice) -> Bool {
        let activeKeys = Set(connections.keys)
            .union(authenticatedConnections.keys)
            .union(outboundConnectionAttemptIds.keys)
        guard !activeKeys.isEmpty else { return false }

        let deviceAliases = Set(P2PDiscoveryKEMAliasRepairPolicy.aliasRepairCandidates(for: device))
        guard !deviceAliases.isEmpty else { return false }
        if !deviceAliases.isDisjoint(with: activeKeys) {
            return true
        }

        let normalizedAliases = Set(deviceAliases.map { $0.lowercased() })
        return activeKeys.contains { activeKey in
            !normalizedAliases.isDisjoint(
                with: Set(PeerTrustLookup.lookupCandidates(for: activeKey).map { $0.lowercased() })
            )
        }
    }

    private func isProtectedDiscoveryDevice(_ device: DiscoveredDevice) -> Bool {
        Self.shouldProtectDiscoveryCapacityRecord(
            isLocalDevice: device.isLocalDevice,
            isTrusted: isTrustedDiscoveryDevice(device),
            hasActiveConnection: hasActiveDiscoveryConnection(device)
        )
    }

    private nonisolated static func discoveryCapacityPriority(
        services: [String],
        isProtected: Bool
    ) -> DiscoveryCapacityPriority {
        if isProtected { return .protected }
        if services.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("_skybridge")
        }) {
            return .skyBridge
        }
        return .compatibility
    }

    private func reconcileDiscoveryCapacityState(at now: Date) {
        let validDeviceIDs = Set(discoveredDevices.map(\.id))
        discoveryCapacityState.retainOnly(deviceIDs: validDeviceIDs)
        for deviceID in validDeviceIDs where !discoveryCapacityState.isTracking(deviceID: deviceID) {
            discoveryCapacityState.recordActivity(for: deviceID, at: now)
        }
    }

    private func admitNewDiscoveredDevice(
        _ incoming: DiscoveredDevice,
        now: Date
    ) -> Bool {
        let incomingIsProtected = isProtectedDiscoveryDevice(incoming)
        if !incomingIsProtected,
           discoveredDevices.count >= Self.maximumDiscoveredDevices,
           let backoffUntil = unprotectedAdmissionBackoffUntil,
           now < backoffUntil {
            return false
        }
        reconcileDiscoveryCapacityState(at: now)
        let incomingPriority = Self.discoveryCapacityPriority(
            services: incoming.services,
            isProtected: incomingIsProtected
        )
        let records = discoveredDevices.map { device in
            let isProtected = isProtectedDiscoveryDevice(device)
            return DiscoveryCapacityRecord(
                id: device.id,
                priority: Self.discoveryCapacityPriority(
                    services: device.services,
                    isProtected: isProtected
                ),
                isProtected: isProtected
            )
        }
        let decision = discoveryCapacityState.admissionDecision(
            existing: records,
            incomingPriority: incomingPriority,
            incomingIsProtected: incomingIsProtected,
            limit: Self.maximumDiscoveredDevices,
            staleAfter: Self.staleDiscoveryEvictionAge,
            now: now
        )

        switch decision {
        case .admit:
            unprotectedAdmissionBackoffUntil = nil
            return true
        case .evict(let deviceID):
            guard let index = discoveredDevices.firstIndex(where: { $0.id == deviceID }) else {
                logDiscoveryCapacityRejectionIfNeeded(now: now)
                return false
            }
            removeDiscoveredDevice(at: index)
            unprotectedAdmissionBackoffUntil = nil
            logger.info(
                "🧹 Bonjour 容量回收瞬态设备: limit=\(Self.maximumDiscoveredDevices, privacy: .public) incomingPriority=\(incomingPriority.rawValue, privacy: .public)"
            )
            return true
        case .reject:
            if !incomingIsProtected {
                unprotectedAdmissionBackoffUntil = now.addingTimeInterval(
                    Self.unprotectedAdmissionBackoffSeconds
                )
            }
            logDiscoveryCapacityRejectionIfNeeded(now: now)
            return false
        }
    }

    private func logDiscoveryCapacityRejectionIfNeeded(now: Date) {
        guard lastDiscoveryCapacityLogAt.map({
            now.timeIntervalSince($0) >= Self.discoveryCapacityLogInterval
        }) ?? true else {
            return
        }
        lastDiscoveryCapacityLogAt = now
        logger.error(
            "❌ Bonjour 设备容量已满，拒绝新瞬态结果且保留可信/活跃设备: limit=\(Self.maximumDiscoveredDevices, privacy: .public)"
        )
    }

    private func logHydrationCapacityRejectionIfNeeded(now: Date) {
        guard lastHydrationCapacityLogAt.map({
            now.timeIntervalSince($0) >= Self.discoveryCapacityLogInterval
        }) ?? true else {
            return
        }
        lastHydrationCapacityLogAt = now
        logger.error(
            "❌ Bonjour 地址水合任务容量已满，拒绝创建新任务: limit=\(Self.maximumHydrationTaskOwners, privacy: .public)"
        )
    }

    private func logRouteCapacityRejectionIfNeeded(now: Date) {
        guard lastRouteCapacityLogAt.map({
            now.timeIntervalSince($0) >= Self.discoveryCapacityLogInterval
        }) ?? true else {
            return
        }
        lastRouteCapacityLogAt = now
        logger.error(
            "❌ Bonjour 设备路由标识容量已满，拒绝未绑定的新路由: limit=\(Self.maximumRouteIdentifiersPerDevice, privacy: .public)"
        )
    }

    private func resetDiscoveryCapacityState() {
        discoveryCapacityState.removeAll()
        lastDiscoveryCapacityLogAt = nil
        lastHydrationCapacityLogAt = nil
        lastRouteCapacityLogAt = nil
        unprotectedAdmissionBackoffUntil = nil
    }

    private func removeDiscoveredDevice(at index: Int) {
        guard discoveredDevices.indices.contains(index) else { return }
        let device = discoveredDevices[index]
        let preferredRoute = P2PDiscoveryBonjourPolicy.preferredRoutableBonjourIdentifier(for: device)
        let stableIdentity = Self.stableDiscoveryHydrationIdentity(
            for: device,
            bonjourIdentifier: preferredRoute
        )
        let normalizedRouteIdentifiers = Set(
            device.routeIdentifiers.compactMap {
                P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching($0)
            }
        )
        let routesToCancel = netServiceResolveTasks.compactMap { route, owner in
            let normalizedRoute = P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(
                Self.bonjourIdentifier(for: route)
            )
            if owner.ticket.stableDeviceIdentity == stableIdentity
                || normalizedRoute.map(normalizedRouteIdentifiers.contains) == true {
                return route
            }
            return nil
        }
        for route in routesToCancel {
            invalidateDiscoveryHydration(route: route, clearCooldown: true)
        }
        discoveredDevices.remove(at: index)
        discoveryCapacityState.remove(deviceID: device.id)
        unprotectedAdmissionBackoffUntil = nil
    }

    private func upsertDiscoveredDevice(
        from result: NWBrowser.Result,
        serviceType: String,
        replaceExistingHydration: Bool
    ) {
        let bonjourUniqueIdentifier = bonjourIdentifier(from: result.endpoint)
        let strongIdentity = extractStrongIdentity(from: result)
        let supportsSOA = extractSOAFlag(from: result)
        let networkLinkStatus = extractNetworkLinkStatus(from: result)
        let connectionTypes = Self.connectionTypes(
            from: networkLinkStatus,
            defaultTypes: [.wifi]
        )
        let advertisedPort = extractAdvertisedServicePort(from: result, serviceType: serviceType) ?? 0
        let deviceName = extractDeviceName(from: result)
        let (ipv4, ipv6) = Self.numericNetworkAddresses(from: result.endpoint)
        let activityDate = Date()
        var detectedDeviceType = ""
        if serviceType.contains("airplay") {
            if !deviceName.lowercased().contains("iphone"),
               !deviceName.lowercased().contains("ipad"),
               !deviceName.lowercased().contains("apple tv") {
                detectedDeviceType = " 📱"
            }
        } else if serviceType.contains("companion-link"),
                  !deviceName.lowercased().contains("apple") {
            detectedDeviceType = " 🍎"
        }

        let device = DiscoveredDevice(
            id: UUID(),
            name: deviceName + detectedDeviceType,
            ipv4: ipv4,
            ipv6: ipv6,
            services: supportsSOA ? [serviceType, "hs_soa"] : [serviceType],
            portMap: [serviceType: advertisedPort],
            connectionTypes: connectionTypes,
            uniqueIdentifier: P2PDiscoveryBonjourPolicy.preferredUniqueIdentifier(
                deviceId: strongIdentity.deviceId,
                pubKeyFP: strongIdentity.pubKeyFP,
                bonjourIdentifier: bonjourUniqueIdentifier,
                ipv4: ipv4,
                ipv6: ipv6
            ),
            routeIdentifiers: [bonjourUniqueIdentifier].compactMap { $0 },
            signalStrength: Self.signalPercentage(from: networkLinkStatus),
            networkLinkStatus: networkLinkStatus,
            isLocalDevice: isProbablyLocalDevice(name: deviceName, ipv4: ipv4, ipv6: ipv6),
            deviceId: strongIdentity.deviceId,
            pubKeyFP: strongIdentity.pubKeyFP
        )

        if let existingIndex = findDiscoveredDeviceIndex(
            name: deviceName,
            ipv4: ipv4,
            ipv6: ipv6,
            bonjourIdentifier: bonjourUniqueIdentifier,
            strongIdentity: strongIdentity
        ) {
            var existing = discoveredDevices[existingIndex]
            let previous = existing
            let routeMerge = Self.boundedRouteIdentifierMerge(
                existing: existing.routeIdentifiers,
                incoming: bonjourUniqueIdentifier,
                limit: Self.maximumRouteIdentifiersPerDevice
            )
            guard routeMerge.accepted else {
                invalidateDiscoveryHydration(for: result.endpoint)
                logRouteCapacityRejectionIfNeeded(now: activityDate)
                return
            }
            if !existing.services.contains(serviceType) {
                existing.services.append(serviceType)
                existing.portMap[serviceType] = advertisedPort
            } else if (existing.portMap[serviceType] ?? 0) <= 0, advertisedPort > 0 {
                existing.portMap[serviceType] = advertisedPort
            }
            if supportsSOA, !existing.services.contains("hs_soa") {
                existing.services.append("hs_soa")
            }
            existing.connectionTypes.formUnion(connectionTypes)
            existing.signalStrength = Self.signalPercentage(from: networkLinkStatus) ?? existing.signalStrength
            existing.networkLinkStatus = networkLinkStatus ?? existing.networkLinkStatus
            if let newDeviceId = strongIdentity.deviceId, !newDeviceId.isEmpty {
                existing.deviceId = newDeviceId
            }
            if let newPubKeyFP = strongIdentity.pubKeyFP, !newPubKeyFP.isEmpty {
                existing.pubKeyFP = newPubKeyFP
            }
            existing.routeIdentifiers = routeMerge.identifiers
            if let preferredIdentifier = P2PDiscoveryBonjourPolicy.preferredUniqueIdentifier(
                deviceId: existing.deviceId,
                pubKeyFP: existing.pubKeyFP,
                bonjourIdentifier: bonjourUniqueIdentifier,
                ipv4: existing.ipv4 ?? device.ipv4,
                ipv6: existing.ipv6 ?? device.ipv6
            ), !P2PDiscoveryBonjourPolicy.isStrongUniqueIdentifier(existing.uniqueIdentifier)
                || P2PDiscoveryBonjourPolicy.isStrongUniqueIdentifier(preferredIdentifier)
                || P2PDiscoveryBonjourPolicy.isBonjourIdentifier(preferredIdentifier) {
                existing.uniqueIdentifier = preferredIdentifier
            }
            if existing != previous {
                discoveredDevices[existingIndex] = existing
            }
            discoveryCapacityState.recordActivity(for: existing.id, at: activityDate)
            logger.debug("🔄 更新设备服务: \(device.name) - 新增服务: \(serviceType)")
            resolveViaNetServiceIfNeeded(
                result: result,
                deviceIndex: existingIndex,
                serviceType: serviceType,
                replaceExisting: replaceExistingHydration
            )
        } else {
            guard admitNewDiscoveredDevice(device, now: activityDate) else { return }
            discoveredDevices.append(device)
            discoveryCapacityState.recordActivity(for: device.id, at: activityDate)
            logger.info(
                "✅ 发现[\(serviceType)]: \(device.name) - IPv4: \(ipv4 ?? "无"), IPv6: \(ipv6 ?? "无"), 端口: \(advertisedPort)"
            )
            resolveViaNetServiceIfNeeded(
                result: result,
                deviceIndex: discoveredDevices.count - 1,
                serviceType: serviceType,
                replaceExisting: false
            )
        }
    }

    /// 移除设备
    private func removeDiscoveredDevice(from result: NWBrowser.Result, serviceType: String) {
        invalidateDiscoveryHydration(for: result.endpoint)
        let deviceName = extractDeviceName(from: result)
        let (ipv4, ipv6) = Self.numericNetworkAddresses(from: result.endpoint)
        let bonjourUniqueIdentifier = bonjourIdentifier(from: result.endpoint)
        let strongIdentity = extractStrongIdentity(from: result)

        guard let existingIndex = findDiscoveredDeviceIndex(
            name: deviceName,
            ipv4: ipv4,
            ipv6: ipv6,
            bonjourIdentifier: bonjourUniqueIdentifier,
            strongIdentity: strongIdentity
        ) else {
            logger.debug("ℹ️ 忽略离线事件：未匹配到设备 [\(serviceType)] name=\(deviceName, privacy: .public)")
            return
        }

        var existing = discoveredDevices[existingIndex]
        existing.services.removeAll { $0 == serviceType }
        existing.portMap.removeValue(forKey: serviceType)

        let remainingTransportServices = existing.services.filter { $0.hasPrefix("_") }
        if remainingTransportServices.isEmpty {
            removeDiscoveredDevice(at: existingIndex)
            logger.info("设备已离线: \(existing.name, privacy: .public) [\(serviceType, privacy: .public)]")
            return
        }

        if !remainingTransportServices.contains("_skybridge._tcp") {
            existing.services.removeAll { $0 == "hs_soa" }
        }

        discoveredDevices[existingIndex] = existing
        discoveryCapacityState.recordActivity(for: existing.id, at: Date())
        let remainingServiceSummary = remainingTransportServices.joined(separator: ",")
        logger.info(
            "🧹 设备服务下线: \(existing.name, privacy: .public) - 移除=\(serviceType, privacy: .public), 剩余=\(remainingServiceSummary, privacy: .public)"
        )
    }

 // MARK: - 监听器 / 连接状态

 /// 处理监听器状态更新
    private func handleListenerStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            isAdvertising = true
            logger.info("📡 监听器就绪")
        case .failed(let error):
            isAdvertising = false
            logger.error("❌ 监听器失败: \(error.localizedDescription)")
        case .cancelled:
            isAdvertising = false
            logger.info("⏹️ 监听器已取消")
        default:
            break
        }
    }

 /// 处理新连接（传入 TCP）
    private func handleNewConnection(_ connection: NWConnection) {
        guard acceptingInboundControlConnections else {
            logger.info("⏹️ 拒绝生命周期停止期间到达的 P2P 入站连接")
            connection.cancel()
            return
        }
        guard registerProvisionalInboundConnection(connection) else { return }
        logger.info("🔗 收到新连接")

 // 设置连接状态处理器
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let connection else { return }
                self?.handleIncomingConnectionStateUpdate(state, connection: connection)
            }
        }

 // 启动连接
        connection.start(queue: .global())
    }

 /// 处理主动发起的连接状态更新
    private func handleConnectionStateUpdate(
        _ state: NWConnection.State,
        for deviceId: String,
        connection: NWConnection
    ) {
        guard connections[deviceId] === connection else {
            return
        }
        switch state {
        case .ready:
            logger.info("✅ 连接传输层就绪: \(deviceId)")
            if connectionStatus == .disconnected || connectionStatus == .failed {
                connectionStatus = .connecting
            }
        case .failed(let error):
            logger.error("❌ 连接失败: \(deviceId), 错误: \(error.localizedDescription)")
            if let authenticated = authenticatedConnections.removeValue(forKey: deviceId) {
                authenticated.disconnect()
            }
            connections.removeValue(forKey: deviceId)
            connectionStatus = .failed
        case .cancelled:
            logger.info("⏹️ 连接已取消: \(deviceId)")
            if let authenticated = authenticatedConnections.removeValue(forKey: deviceId) {
                authenticated.disconnect()
            }
            connections.removeValue(forKey: deviceId)
            connectionStatus = connections.isEmpty ? .disconnected : connectionStatus
        default:
            break
        }
    }

 /// 处理传入连接状态更新
    private func handleIncomingConnectionStateUpdate(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            logger.info("✅ 传入连接就绪")
            connection.stateUpdateHandler = nil
            // 处理传入控制通道（握手/验签/能力协商）
            // 重要：P2PDiscoveryService 是 @MainActor；入站读取/握手必须放到后台，
            // 否则主线程繁忙时会导致对端握手超时并主动断开。
            let sessionId = UUID()
            registerInboundControlSession(
                id: sessionId,
                connection: connection
            )
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                await self.handleInboundControlChannel(
                    connection,
                    sessionId: sessionId
                )
            }
            attachInboundControlSessionTask(task, id: sessionId)
        case .failed(let error):
            finishProvisionalInboundConnection(connection)
            if case NWError.posix(let posixErr) = error, posixErr == .ECONNREFUSED || posixErr == .EADDRNOTAVAIL {
                logger.debug("传入连接失败(预期探测失败): \(posixErr.rawValue)")
            } else {
                logger.error("❌ 传入连接失败: \(error.localizedDescription)")
            }
            connection.stateUpdateHandler = nil
            connection.cancel()
        case .cancelled:
            finishProvisionalInboundConnection(connection)
            connection.stateUpdateHandler = nil
            logger.info("⏹️ 传入连接已取消")
        default:
            break
        }
    }

    private func resolveInboundPeerIdentifier(for endpoint: NWEndpoint) -> String {
        let fallback = Self.fallbackPeerIdentifier(for: endpoint)
        switch endpoint {
        case .hostPort(let host, _):
            let hostText = String(describing: host).lowercased()
            if let match = discoveredDevices.first(where: {
                ($0.ipv4?.lowercased() == hostText) || ($0.ipv6?.lowercased() == hostText)
            }) {
                if let deviceId = match.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceId.isEmpty {
                    return "id:\(deviceId)"
                }
                if let unique = match.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !unique.isEmpty {
                    return unique
                }
            }
            return fallback
        case .service(let name, _, let domain, _):
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedDomain = (domain.isEmpty ? "local." : domain).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let match = discoveredDevices.first(where: { device in
                let cleaned = device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return cleaned == normalizedName || cleaned.contains(normalizedName)
            }) {
                if let deviceId = match.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceId.isEmpty {
                    return "id:\(deviceId)"
                }
                if let unique = match.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !unique.isEmpty {
                    return unique
                }
            }
            return "bonjour:\(normalizedName)@\(normalizedDomain)"
        default:
            return fallback
        }
    }

    private nonisolated static func fallbackPeerIdentifier(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service(let name, _, let domain, _):
            let resolvedDomain = domain.isEmpty ? "local." : domain
            return "bonjour:\(name)@\(resolvedDomain)"
        case .hostPort(let host, _):
            return "host:\(host)"
        default:
            return endpoint.debugDescription
        }
    }

    private nonisolated static func canonicalSOAIdentityString(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") {
            normalized.removeFirst(3)
        }
        return normalized
    }

    private nonisolated static func soaPeerIdBytes(from raw: String) -> Data {
        let canonical = canonicalSOAIdentityString(raw)
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }

    @available(macOS 14.0, iOS 17.0, *)
    private nonisolated static func localSOAPeerIdBytes() async throws -> Data {
        let deviceId = try await SelfIdentityProvider.shared
            .protocolIdentityDeviceId(allowCreate: true)
        return soaPeerIdBytes(from: deviceId)
    }

    /// 入站控制通道处理（回退 HandshakeDriver，与 iOS 互通）
    nonisolated private func handleInboundControlChannel(
        _ connection: NWConnection,
        sessionId inboundControlSessionId: UUID
    ) async {
        let logger = Logger(subsystem: "com.skybridge.Compass", category: "P2PInboundHandshake")
        var didMarkEstablished = false
        var peerIdForPresence = Self.stableEndpointLabel(for: connection.endpoint)
        var declaredDeviceIdForVerification: String?
        let classicTransferSessionId = "p2p-discovery-inbound-\(UUID().uuidString.lowercased())"
        var inboundPairKey: Data?

        func runSession() async {

        func waitUntilReady(timeoutSeconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if connection.state == .ready { return true }
                if case .failed = connection.state { return false }
                if case .cancelled = connection.state { return false }
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return false
                }
            }
            return connection.state == .ready
        }

        if connection.state != .ready {
            _ = await waitUntilReady(timeoutSeconds: 3.0)
        }

        struct DirectHandshakeTransport: DiscoveryTransport {
            let connection: NWConnection
            func send(to peer: PeerIdentifier, data: Data) async throws {
                var framed = Data()
                var length = UInt32(data.count).bigEndian
                framed.append(Data(bytes: &length, count: 4))
                framed.append(data)
                try await P2PDiscoveryService.sendContent(framed, over: connection, timeoutSeconds: 5.0)
            }
        }

        func sendAck(_ code: UInt8) async throws {
            try await Self.sendContent(Data([code]), over: connection, timeoutSeconds: 5.0)
        }

        func sendFramed(_ data: Data) async throws {
            var framed = Data()
            var length = UInt32(data.count).bigEndian
            framed.append(Data(bytes: &length, count: 4))
            framed.append(data)
            try await Self.sendContent(framed, over: connection, timeoutSeconds: 5.0)
        }

        let transport = DirectHandshakeTransport(connection: connection)
        let resolvedPeerId = await MainActor.run { [weak self] in
            self?.resolveInboundPeerIdentifier(for: connection.endpoint) ?? Self.fallbackPeerIdentifier(for: connection.endpoint)
        }
        let localSOAPeerId: Data
        do {
            localSOAPeerId = try await Self.localSOAPeerIdBytes()
        } catch {
            logger.error(
                "❌ inbound control channel local identity unavailable: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
            connection.cancel()
            return
        }
        var expectedRemoteSOAPeerId: Data?
        // Protocol-grade gate:
        // Only .established promotes keys to the active business-traffic channel.
        // waitingFinished may derive candidate keys for verification UX, but must not
        // unlock app-message processing or shared connected state.
        var sessionKeys: SessionKeys?
        var previousSessionKeysBeforeRekey: SessionKeys?
        var lastPairingIdentityExchangeReply: PairingIdentityExchangeReplyThrottleState?
        var didSendPostAuthPairingIdentityExchange = false
        var authenticatedRemoteAuthority: AuthenticatedRemoteAuthority?
        var latestPeerFileTransferPort: UInt16?
        let peer = PeerIdentifier(deviceId: resolvedPeerId)
        var driver: HandshakeDriver?
        peerIdForPresence = peer.deviceId
	        let endpointDescriptionForPresence = Self.stableEndpointLabel(for: connection.endpoint)
	        let endpointHostOrIPForClassicTransfer = Self.endpointHostOrIP(for: connection.endpoint)
	        let peerDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(peer.deviceId)
	        let endpointDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(endpointDescriptionForPresence)
	        var latestPeerCapabilities: [String] = []

        func refreshInboundControlSessionAliases() async {
            await MainActor.run {
                self.upsertInboundControlSession(
                    id: inboundControlSessionId,
                    connection: connection,
                    aliases: [
                        declaredDeviceIdForVerification,
                        peerIdForPresence,
                        peer.deviceId,
                        endpointHostOrIPForClassicTransfer,
                        endpointDescriptionForPresence
                    ]
                )
            }
        }
        await refreshInboundControlSessionAliases()

        func trimmedIdentifier(_ raw: String?) -> String? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        func validatedPairingIdentityPayload(
            _ payload: AppMessage.PairingIdentityExchangePayload
        ) -> AppMessage.PairingIdentityExchangePayload? {
	            guard let normalized = payload.normalizedBootstrapPayload else {
	                logger.warning(
	                    "⚠️ ignoring pairingIdentityExchange with empty declaredDeviceId: peer=\(peerDiagnosticLabel, privacy: .public) endpoint=\(endpointDiagnosticLabel, privacy: .public)"
	                )
	                return nil
	            }
            return normalized
        }

        func isPairingIdentityBoundToAuthenticatedAuthority(
            _ payload: AppMessage.PairingIdentityExchangePayload
        ) -> Bool {
            guard let authority = authenticatedRemoteAuthority else { return false }
            return AuthenticatedProtocolIdentityBinding.matchingPublicKey(
                in: payload,
                authority: authority
            ) != nil
        }

        func cryptoKind(for suite: CryptoSuite) -> String {
            ConnectionCryptoPresentation.modeLabel(kind: nil, suite: suite.rawValue) ?? suite.rawValue
        }

        func displayNameFromPeerId(_ peerId: String) -> String? {
            if peerId.hasPrefix("bonjour:") {
                let rest = peerId.dropFirst("bonjour:".count)
                return LocalDevicePresentation.sanitizedDisplayNameCandidate(
                    rest.split(separator: "@", maxSplits: 1).first.map(String.init)
                )
            }
            return LocalDevicePresentation.sanitizedDisplayNameCandidate(peerId)
        }

        func resolvedDisplayName(
            raw: String?,
            model: String?,
            platform: String?,
            fallbackPeerId: String
        ) -> String {
            LocalDevicePresentation.displayDeviceName(
                rawDeviceName: raw ?? displayNameFromPeerId(fallbackPeerId),
                modelName: model,
                platformName: platform ?? ""
            ) ?? "P2P Peer"
        }

        func persistAuthenticatedRemoteAuthority(
            from payload: AppMessage.PairingIdentityExchangePayload,
            displayName: String
        ) async {
            guard let authority = authenticatedRemoteAuthority else {
                logger.warning(
                    "⚠️ inbound pairingIdentityExchange missing authenticated authority; skipping current-path trust bridge: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) declared=\(Self.protocolIdentityLogRedaction, privacy: .public)"
                )
                return
            }

            var knownDeviceIds: [String] = []
            var seenKnownDeviceIds = Set<String>()

            func appendKnownDeviceId(_ raw: String?) {
                guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty,
                      seenKnownDeviceIds.insert(raw).inserted else {
                    return
                }
                knownDeviceIds.append(raw)
            }

            appendKnownDeviceId(payload.deviceId)
            appendKnownDeviceId(peer.deviceId)
            appendKnownDeviceId(peerIdForPresence)

            let authenticatedProtocolPublicKey = AuthenticatedProtocolIdentityBinding.matchingPublicKey(
                in: payload,
                authority: authority
            ) ?? authority.protocolPublicKey

            do {
                let persisted = try await TrustSyncService.shared.recordAuthenticatedRemoteAuthority(
                    deviceId: payload.deviceId,
                    displayName: displayName,
                    preferredCurrentDeviceId: payload.deviceId,
                    knownDeviceIds: knownDeviceIds,
                    protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
                    protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint,
                    authenticatedProtocolPublicKey: authenticatedProtocolPublicKey
                )
                guard persisted else {
                    logger.warning(
                        "⚠️ inbound current-path trust bridge skipped: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) declared=\(Self.protocolIdentityLogRedaction, privacy: .public)"
                    )
                    return
                }
                logger.info(
                    "🔐 inbound current-path trust bridge persisted: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) current=\(Self.protocolIdentityLogRedaction, privacy: .public) alg=\(authority.protocolSigningAlgorithm.rawValue, privacy: .public) fp=\(Self.protocolIdentityLogRedaction, privacy: .public)"
                )
            } catch {
                logger.warning(
                    "⚠️ inbound current-path trust bridge failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }

        func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.sendKey)
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else {
                throw P2PDiscoveryError.connectionCancelled
            }
            return combined
        }

        func decryptAppPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.receiveKey)
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        }

        func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
            Self.isLikelyHandshakeControlFrame(data)
        }

        func publishInboundPresence(keys: SessionKeys) async -> Bool {
            let suite = keys.negotiatedSuite
            let kind = cryptoKind(for: suite)
            let peerId = trimmedIdentifier(declaredDeviceIdForVerification) ?? peerIdForPresence
            let advertisedTransferPort = latestPeerFileTransferPort.flatMap { port -> Int? in
                let value = Int(port)
                return (1...65535).contains(value) ? value : nil
            }

            return await MainActor.run {
                var resolved = Self.resolveInboundPresenceRoute(
                    peerId: peerId,
                    endpointLabel: endpointDescriptionForPresence,
                    discoveredDevices: self.discoveredDevices,
                    unifiedDevices: UnifiedOnlineDeviceManager.shared.onlineDevices
                )
                resolved.name = resolvedDisplayName(
                    raw: resolved.name,
                    model: nil,
                    platform: nil,
                    fallbackPeerId: peerId
                )

                guard let displayAddress = resolved.displayAddress?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !displayAddress.isEmpty,
                    (1...65535).contains(advertisedTransferPort ?? resolved.transferPort) else {
                    logger.error(
                        "❌ inbound establish route missing: peer=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(peerId), privacy: .public) endpoint=\(endpointDiagnosticLabel, privacy: .public)"
                    )
                    return false
                }
                let transferPort = advertisedTransferPort ?? resolved.transferPort

                let routeDescriptor = ConnectionPresenceService.PresenceRouteDescriptor(
                    peerId: peerId,
                    deviceName: resolved.name,
                    displayAddress: displayAddress,
                    transferAddress: displayAddress,
                    transferPort: transferPort,
                    routeSource: .inbound,
                    connectedAt: Date()
                )

                guard ConnectionPresenceService.shared.publishConnectedAtomically(
                    peerId: peerId,
                    displayName: resolved.name,
                    address: displayAddress,
                    cryptoKind: kind,
                    suite: suite.rawValue,
                    routeDescriptor: routeDescriptor
                ) else {
                    logger.error("❌ inbound establish contract incomplete: peer=\(peerId, privacy: .public)")
                    return false
                }

                ConnectionPresenceService.shared.clearRekeying(peerId: peerId)
                UnifiedOnlineDeviceManager.shared.markDeviceAsConnected(
                    peerId: peerId,
                    displayName: resolved.name,
                    cryptoKind: kind,
                    suite: suite.rawValue,
                    guardStatus: "守护中"
                )
                return true
            }
        }

        func normalizedIdentityCapabilities(
            from payload: AppMessage.PairingIdentityExchangePayload
        ) -> [String] {
            ClassicTransferCapability.normalizedRemoteCapabilities(
                payload.capabilities,
                fileTransferPort: payload.fileTransferPort,
                remoteControlPort: payload.remoteControlPort
            )
        }

        func recordRemoteControlSecurityIdentity(
            from payload: AppMessage.PairingIdentityExchangePayload
        ) {
            let identity = RemoteControlSecurityIdentity(
                accountDisplayName: payload.accountDisplayName,
                nebulaId: payload.nebulaId,
                deviceId: payload.deviceId,
                deviceName: LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName)
            )
            guard !identity.isEmpty else { return }
            RemoteControlSecurityPeerIdentityStore.record(
                identity: identity,
                aliases: [
                    payload.deviceId,
                    LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName),
                    peer.deviceId,
                    peerIdForPresence,
                    endpointHostOrIPForClassicTransfer,
                    endpointDescriptionForPresence
                ].compactMap { $0 }
            )
        }

        func recordRemoteControlSecurityIdentity(
            from payload: AppMessage.HeartbeatPayload
        ) {
            let identity = RemoteControlSecurityIdentity(
                accountDisplayName: payload.accountDisplayName,
                nebulaId: payload.nebulaId,
                deviceId: payload.deviceId,
                deviceName: LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName)
            )
            guard !identity.isEmpty else { return }
            RemoteControlSecurityPeerIdentityStore.record(
                identity: identity,
                aliases: [
                    payload.deviceId,
                    LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName),
                    peer.deviceId,
                    peerIdForPresence,
                    endpointHostOrIPForClassicTransfer,
                    endpointDescriptionForPresence
                ].compactMap { $0 }
            )
        }

        func makeLocalPairingIdentityExchangeMessage(
            reason: String
        ) async -> (
            message: AppMessage,
            kemKeyCount: Int,
            localId: String,
            fileTransferPort: UInt16?,
            remoteControlPort: UInt16?
        )? {
            let provider = CryptoProviderFactory.make(policy: .preferPQC)
            let km = DeviceIdentityKeyManager.shared
            let kemKeys: [KEMPublicKeyInfo]
            do {
                kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
                    try await km.pairingIdentityKEMPublicKeys(using: provider)
                )
            } catch {
                logger.warning(
                    "⚠️ 本机 KEM 公钥准备失败（\(reason, privacy: .public)）：\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
                return nil
            }
            guard !kemKeys.isEmpty else {
                logger.warning("⚠️ 跳过 pairingIdentityExchange \(reason, privacy: .public)：本机无有效 KEM 公钥")
                return nil
            }

            let localIdRaw: String
            do {
                localIdRaw = try await SelfIdentityProvider.shared
                    .protocolIdentityDeviceId(allowCreate: true)
            } catch {
                logger.error(
                    "❌ pairing identity exchange local authority unavailable (\(reason, privacy: .public)): \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
                return nil
            }
            let localId = localIdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !localId.isEmpty else {
                logger.warning("⚠️ 跳过 pairingIdentityExchange \(reason, privacy: .public)：本机 deviceId 为空")
                return nil
            }

            let endpoints = ServiceEndpointRegistry.shared.snapshot()
            let localIdentity = RemoteControlSecurityNoticeCenter.cachedLocalIdentitySnapshot()
            let localPresentation = LocalDevicePresentation.current()
            let protocolIdentityPublicKeys: [AppMessage.ProtocolIdentityPublicKeyInfo]
            do {
                protocolIdentityPublicKeys = try await Self.localProtocolIdentityPublicKeysForPairing()
            } catch {
                logger.error(
                    "❌ pairing identity exchange protocol authority unavailable (\(reason, privacy: .public)): \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
                return nil
            }
            let message = AppMessage.pairingIdentityExchange(.init(
                deviceId: localId,
                kemPublicKeys: kemKeys,
                protocolIdentityPublicKeys: protocolIdentityPublicKeys,
                deviceName: localPresentation.deviceName,
                modelName: localPresentation.modelName,
                platform: localPresentation.platformName,
                osVersion: localPresentation.osVersion,
                chip: nil,
                accountDisplayName: localIdentity?.accountDisplayName,
                nebulaId: localIdentity?.nebulaId,
                capabilities: ["clipboard_sync", "file_transfer", "remote_desktop", "remote_control"],
                fileTransferPort: endpoints.fileTransferPort,
                remoteControlPort: endpoints.remoteControlPort
            ))
            return (
                message: message,
                kemKeyCount: kemKeys.count,
                localId: localId,
                fileTransferPort: endpoints.fileTransferPort,
                remoteControlPort: endpoints.remoteControlPort
            )
        }

        func sendInboundPostAuthPairingIdentityExchange(keys: SessionKeys) async throws {
            guard !didSendPostAuthPairingIdentityExchange else { return }
            guard let localIdentity = await makeLocalPairingIdentityExchangeMessage(reason: "inbound post-auth") else {
                throw NSError(
                    domain: "SkyBridge.P2PDiscovery",
                    code: 1001,
                    userInfo: [
                        NSLocalizedDescriptionKey: "inbound_post_auth_pairing_identity_unavailable"
                    ]
                )
            }

            let outPlain = try JSONEncoder().encode(localIdentity.message)
            let outCipher = try encryptAppPayload(outPlain, with: keys)
            let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx")
            try await sendFramed(outPadded)
	            didSendPostAuthPairingIdentityExchange = true
	            let localDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(localIdentity.localId)
	            logger.info(
	                "🔑 inbound post-auth pairingIdentityExchange sent: peer=\(peerDiagnosticLabel, privacy: .public) local=\(localDiagnosticLabel, privacy: .public) keys=\(localIdentity.kemKeyCount, privacy: .public) fileTransferPort=\(localIdentity.fileTransferPort.map(String.init) ?? "-", privacy: .public) remoteControlPort=\(localIdentity.remoteControlPort.map(String.init) ?? "-", privacy: .public)"
	            )
	        }

        func refreshInboundRouteFromHeartbeat(
            _ payload: AppMessage.HeartbeatPayload,
            keys: SessionKeys
        ) async {
            if let deviceId = trimmedIdentifier(payload.deviceId) {
                declaredDeviceIdForVerification = deviceId
                await refreshInboundControlSessionAliases()
            }
            latestPeerCapabilities = ClassicTransferCapability.normalizedRemoteCapabilities(
                payload.capabilities ?? latestPeerCapabilities,
                fileTransferPort: payload.fileTransferPort ?? latestPeerFileTransferPort,
                remoteControlPort: payload.remoteControlPort
            )
            if let port = payload.fileTransferPort {
                latestPeerFileTransferPort = port
            }
            recordRemoteControlSecurityIdentity(from: payload)

            await publishInboundClassicTransferSession(keys: keys)
	            if await publishInboundPresence(keys: keys) {
	                let routeDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(declaredDeviceIdForVerification ?? peer.deviceId)
	                logger.debug(
	                    "📡 refreshed inbound file-transfer route from heartbeat: peer=\(routeDiagnosticLabel, privacy: .public) fileTransferPort=\(latestPeerFileTransferPort.map(String.init) ?? "-", privacy: .public)"
	                )
	            }
	        }

        func publishInboundClassicTransferSession(keys: SessionKeys) async {
            let declaredPeerId = trimmedIdentifier(declaredDeviceIdForVerification)
            let fallbackPeerId = trimmedIdentifier(peer.deviceId)
                ?? trimmedIdentifier(peerIdForPresence)
                ?? endpointDescriptionForPresence
            let primaryPeerId = declaredPeerId ?? fallbackPeerId
            let resolvedPeerDeviceId = PeerTrustLookup.persistentDeviceId(from: declaredPeerId)
                ?? PeerTrustLookup.persistentDeviceId(from: fallbackPeerId)
                ?? primaryPeerId
            let aliases = Self.normalizedClassicTransferSessionAliases([
                declaredDeviceIdForVerification,
                primaryPeerId,
                peer.deviceId,
                peerIdForPresence,
                endpointHostOrIPForClassicTransfer,
                endpointDescriptionForPresence
            ])
            let snapshot = ClassicTransferSessionSnapshot(
                sessionId: classicTransferSessionId,
                matchDeviceId: primaryPeerId,
                resolvedPeerDeviceId: resolvedPeerDeviceId,
                aliases: aliases,
                endpointHostOrIP: endpointHostOrIPForClassicTransfer,
                capabilities: latestPeerCapabilities,
                sessionKeys: keys
            )
            await ClassicTransferSessionRegistry.shared.upsert(session: snapshot)
        }

        logger.info("🤝 入站连接：启用 HandshakeDriver 兼容通道（iOS 互通） state=\(String(describing: connection.state), privacy: .public)")

        do {
            while true {
                if case .failed = connection.state { break }
                if case .cancelled = connection.state { break }
                let payload = try await Self.receiveBootstrapFrame(
                    over: connection,
                    timeoutSeconds: didMarkEstablished ? 45 : Self.provisionalInboundTimeoutSeconds
                )
                let frame = Self.normalizeInboundControlFrame(payload)

                if let plaintextControl = try? JSONDecoder().decode(AppMessage.self, from: frame),
                   let controlResponse = await Self.makeBootstrapControlResponse(for: plaintextControl) {
                    await MainActor.run {
                        self.finishProvisionalInboundConnection(connection)
                    }
                    let encoded = try JSONEncoder().encode(controlResponse.message)
                    try await sendFramed(encoded)
                    if let binding = controlResponse.protocolIdentityBindingPayload,
                       let code = controlResponse.protocolIdentityBindingCode {
                        await MainActor.run {
                            PairingTrustApprovalService.shared.showProtocolIdentityBindingCode(
                                peerEndpoint: endpointDescriptionForPresence,
                                declaredDeviceId: binding.deviceId,
                                displayName: resolvedDisplayName(
                                    raw: binding.deviceName,
                                    model: nil,
                                    platform: nil,
                                    fallbackPeerId: peer.deviceId
                                ),
                                model: nil,
                                platform: nil,
                                osVersion: nil,
                                verificationCode: code,
                                protocolIdentityFingerprint: binding.protocolIdentityFingerprint
                            )
                        }
                    }
                    if controlResponse.isFailure {
                        logger.error("\(controlResponse.statusLine, privacy: .public)")
                    } else {
                        logger.info("\(controlResponse.statusLine, privacy: .public)")
                    }
                    RemoteControlSmokeStatusWriter.append(controlResponse.statusLine)
                    connection.cancel()
                    return
                }

                if let currentDriver = driver,
                   let messageA = try? HandshakeMessageA.decode(from: frame) {
                    let driverState = await currentDriver.getCurrentState()
                    if Self.shouldRestartInboundHandshakeForRekey(state: driverState, frame: frame) {
                        let fromSuite = sessionKeys?.negotiatedSuite.rawValue ?? "?"
                        let fromKind = sessionKeys.map { cryptoKind(for: $0.negotiatedSuite) } ?? "?"
                        let toSuite = messageA.supportedSuites.first?.rawValue ?? "?"
                        let toKind = messageA.supportedSuites.first.map { cryptoKind(for: $0) } ?? "?"
                        let rekeyPeerId = peerIdForPresence

                        if let inboundPairKey {
                            logger.info("🧩 inbound rekey: releasing SOA established guard peer=\(peerIdForPresence, privacy: .public)")
                            await PeerSessionArbiter.shared.clearEstablished(pairKey: inboundPairKey)
                            await PeerSessionArbiter.shared.clearOutgoing(pairKey: inboundPairKey, attemptId: nil)
                        }

                        Task { @MainActor in
                            ConnectionPresenceService.shared.markRekeying(.init(
                                peerId: rekeyPeerId,
                                fromKind: fromKind,
                                fromSuite: fromSuite,
                                toKind: toKind,
                                toSuite: toSuite
                            ))
                        }
                        logger.info("🔁 入站 rekey：\(fromKind)·\(fromSuite) -> \(toKind)·\(toSuite) peer=\(peerIdForPresence, privacy: .public)")
                        previousSessionKeysBeforeRekey = sessionKeys
                        driver = nil
                        sessionKeys = nil
                    }
                }

                if let keys = sessionKeys, !isLikelyHandshakeControlPacket(frame) {
                    do {
                        let plaintext = try decryptAppPayload(frame, with: keys)
                        let msg = try JSONDecoder().decode(AppMessage.self, from: plaintext)
                        switch msg {
                            case .kemRefreshRequest, .signedKEMRefresh, .kemRefreshFailure,
                                 .protocolIdentityBindingRequest, .signedProtocolIdentityBinding,
                                 .protocolIdentityBindingConfirm, .signedProtocolIdentityBindingFinalAck:
                                break
                            case .pairingIdentityExchange(let payload):
                                guard let payload = validatedPairingIdentityPayload(payload) else {
                                    break
                                }
                                recordRemoteControlSecurityIdentity(from: payload)
                                declaredDeviceIdForVerification = payload.deviceId
                                await refreshInboundControlSessionAliases()
                                latestPeerCapabilities = normalizedIdentityCapabilities(from: payload)
                                latestPeerFileTransferPort = payload.fileTransferPort
                                let displayName = resolvedDisplayName(
                                    raw: payload.deviceName,
                                    model: payload.modelName,
                                    platform: payload.platform,
                                    fallbackPeerId: peer.deviceId
                                )

                                await MainActor.run {
                                    PairingTrustApprovalService.shared.updateVerificationCode(
                                        declaredDeviceId: payload.deviceId,
                                        sessionKeys: keys
                                    )
                                }

                                let policyBindingKey = authenticatedRemoteAuthority.flatMap { authority in
                                    PairingTrustApprovalService.policyBindingKey(
                                        declaredDeviceId: payload.deviceId,
                                        algorithmRawValue: authority.protocolSigningAlgorithm.rawValue,
                                        protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
                                    )
                                }
                                let request = PairingTrustApprovalService.Request(
                                    peerEndpoint: endpointDescriptionForPresence,
                                    declaredDeviceId: payload.deviceId,
                                    policyBindingKey: policyBindingKey,
                                    displayName: displayName,
                                    model: payload.modelName,
                                    platform: payload.platform,
                                    osVersion: payload.osVersion,
                                    kemKeyCount: payload.kemPublicKeys.count
                                )

	                                let decision: PairingTrustApprovalService.Decision
	                                let payloadDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(payload.deviceId)
	                                if isPairingIdentityBoundToAuthenticatedAuthority(payload) {
	                                    if let persistedDecision = await PairingTrustApprovalService.shared.persistedPolicyDecision(for: request) {
	                                        decision = persistedDecision
	                                        logger.info(
	                                            "🔐 pairingIdentityExchange resolved by persisted policy on authenticated protocol-identity channel: declared=\(payloadDiagnosticLabel, privacy: .public) decision=\(persistedDecision.rawValue, privacy: .public)"
	                                        )
	                                    } else {
	                                        decision = .allowOnce
	                                        logger.info(
	                                            "🔐 pairingIdentityExchange accepted on authenticated protocol-identity channel: declared=\(payloadDiagnosticLabel, privacy: .public)"
	                                        )
	                                    }
	                                } else {
	                                    decision = await PairingTrustApprovalService.shared.decide(for: request)
	                                }
	                                guard decision != PairingTrustApprovalService.Decision.reject else {
	                                    logger.info("🛑 Pairing/trust request rejected (no KEM reply): deviceId=\(payloadDiagnosticLabel, privacy: .public)")
	                                    break
	                                }

                                await PeerKEMBootstrapStore.shared.upsert(
                                    deviceIds: [payload.deviceId, peer.deviceId],
                                    kemPublicKeys: payload.kemPublicKeys,
                                    platform: payload.platform,
                                    osVersion: payload.osVersion
		                                )
	                                logger.info(
	                                    "🔑 已缓存对端 KEM 公钥（bootstrap）：declared=\(payloadDiagnosticLabel, privacy: .public) peer=\(peerDiagnosticLabel, privacy: .public) keys=\(payload.kemPublicKeys.count, privacy: .public)"
	                                )
	                                await publishInboundClassicTransferSession(keys: keys)
	                                if await publishInboundPresence(keys: keys) {
	                                    logger.info(
	                                        "📡 refreshed inbound file-transfer route from pairing identity: peer=\(payloadDiagnosticLabel, privacy: .public) fileTransferPort=\(payload.fileTransferPort.map(String.init) ?? "-", privacy: .public)"
	                                    )
	                                }

                                guard let localIdentity = await makeLocalPairingIdentityExchangeMessage(reason: "bootstrap reply") else {
                                    break
                                }
                                let outPlain = try JSONEncoder().encode(localIdentity.message)
                                let now = Date()
                                let requestKey = Self.pairingIdentityExchangeRequestKey(payload)
                                if Self.shouldSendPairingIdentityExchangeReply(
                                    lastReply: lastPairingIdentityExchangeReply,
                                    requestKey: requestKey,
                                    requestSentAt: payload.sentAt,
                                    now: now
                                ) {
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx")
                                    try await sendFramed(outPadded)
                                    lastPairingIdentityExchangeReply = PairingIdentityExchangeReplyThrottleState(
                                        requestKey: requestKey,
                                        requestSentAt: payload.sentAt,
                                        repliedAt: now
                                    )
                                    logger.info("🔑 已回传本机 KEM 公钥：count=\(localIdentity.kemKeyCount, privacy: .public) decision=\(decision.rawValue, privacy: .public)")
                                } else {
                                    logger.debug("ℹ️ pairingIdentityExchange reply rate-limited during bootstrap")
                                }

                                await persistAuthenticatedRemoteAuthority(
                                    from: payload,
                                    displayName: displayName
                                )

                            case .ping(let payload):
                                let reply = AppMessage.pong(.init(id: payload.id))
                                let outPlain = try JSONEncoder().encode(reply)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx")
                                try await sendFramed(outPadded)

                            case .peerDisconnecting(let payload):
                                let disconnectDisplayName = resolvedDisplayName(
                                    raw: payload.deviceName,
                                    model: nil,
                                    platform: nil,
                                    fallbackPeerId: peer.deviceId
                                )
                                let trimmedDisconnectPeerId =
                                    payload.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
                                let disconnectPeerId =
                                    (trimmedDisconnectPeerId?.isEmpty == false ? trimmedDisconnectPeerId : nil)
                                    ?? peerIdForPresence
                                let presenceDisconnectPeerIds = Self.normalizedClassicTransferSessionAliases([
                                    peerIdForPresence,
                                    declaredDeviceIdForVerification,
                                    disconnectPeerId
                                ])

                                await MainActor.run {
                                    for peerId in presenceDisconnectPeerIds {
                                        ConnectionPresenceService.shared.markDisconnected(peerId: peerId)
                                    }
                                    UnifiedOnlineDeviceManager.shared.markDeviceAsDisconnected(
                                        peerId: disconnectPeerId,
                                        displayName: disconnectDisplayName
                                    )
                                    if didMarkEstablished {
                                        self.activeInboundSessions = max(0, self.activeInboundSessions - 1)
                                        didMarkEstablished = false
                                    }
                                    if self.activeInboundSessions == 0, self.connections.isEmpty {
                                        self.connectionStatus = .disconnected
                                    }
                                }
                                connection.cancel()
                                return

                            case .heartbeat(let payload):
                                await refreshInboundRouteFromHeartbeat(payload, keys: keys)

                            case .authenticatedRouteBinding:
                                break

                            case .textMessage(let payload):
                                // 设备间文本消息：按发送者稳定公钥指纹归档（此入站会话路径同样可能收到）。
                                let senderDeviceId = declaredDeviceIdForVerification ?? peer.deviceId
                                if let record = await TrustSyncService.shared.getTrustRecord(deviceId: senderDeviceId),
                                   !record.pubKeyFP.isEmpty {
                                    await DeviceMessagingService.shared.handleIncoming(payload, fingerprint: record.pubKeyFP)
                                }

                            case .pong, .clipboard:
                                break
                        }
                    } catch {
                        logger.error("❌ 已认证 P2P 通道业务帧验证失败，终止会话：\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
                        RemoteControlSmokeStatusWriter.append(
                            "authenticated-channel-failed reason=invalid_app_frame"
                        )
                        connection.cancel()
                        return
                    }
                    continue
                }

                // 延迟初始化：必须先看到 MessageA 才知道对端 offeredSuites 分组，
                // 从而选择本机可用的 (sigAAlgorithm / provider / offeredSuites) 组合。
                if driver == nil {
                    if let messageA = try? HandshakeMessageA.decode(from: frame) {
                        await MainActor.run {
                            self.finishProvisionalInboundConnection(connection)
                        }
                        let soaBinding = InboundHandshakeAdapter.bindSOAState(
                            from: messageA,
                            localPeerId: localSOAPeerId
                        )
                        expectedRemoteSOAPeerId = soaBinding.expectedRemotePeerId
                        inboundPairKey = soaBinding.pairKey
                        if soaBinding.usedAuthenticatedInitiator {
                            logger.info("🧩 inboundSOA: binding to MessageA initiatorPeerId (endpointId=\(peerDiagnosticLabel, privacy: .public))")
                        }
                        let inboundProtocolIdentity: InboundProtocolIdentitySelection
                        do {
                            inboundProtocolIdentity = try await InboundProtocolIdentitySelectionPolicy.resolve(
                                messageA: messageA,
                                candidateDeviceIds: [peer.deviceId]
                            )
                        } catch {
                            logger.error(
                                "❌ 入站协议身份选择失败: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public). peer=\(peerDiagnosticLabel, privacy: .public)"
                            )
                            return
                        }
                        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
                        let policy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
                        let capability = CryptoProviderFactory.detectCapability()
                        let localPQCAvailable = capability.hasApplePQC || capability.hasLiboqs
                        if let rejection = StrictPQCAdmissionGate.inboundRejection(
                            policy: policy,
                            peerSupportedSuites: messageA.supportedSuites,
                            localPQCSuitesAvailable: localPQCAvailable
                        ), rejection == .peerOfferedClassicOnly {
                            logger.error(
                                "❌ \(rejection.diagnosticMessage, privacy: .public). peer=\(peerDiagnosticLabel, privacy: .public)"
                            )
                            return
                        }

                        // Pick provider first, then derive sigA/offeredSuites from what we can actually support.
                        var selection: CryptoProviderFactory.SelectionPolicy = .classicOnly
                        var cryptoProvider: any CryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
                        var sigAAlgorithm: ProtocolSigningAlgorithm = .ed25519
                        var offeredSuites: [CryptoSuite] = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
                        let effectivePolicy = policy

                        if inboundProtocolIdentity.algorithm != .ed25519 {
                            selection = policy.requirePQC ? .requirePQC : .preferPQC
                            cryptoProvider = CryptoProviderFactory.makeInboundPQCResponderProvider(
                                policy: selection,
                                peerSupportedSuites: messageA.supportedSuites
                            )
                            let localPQCSuites = CryptoProviderFactory.handshakeOfferedPQCSuites(using: cryptoProvider)
                            if let rejection = StrictPQCAdmissionGate.inboundRejection(
                                policy: policy,
                                peerSupportedSuites: messageA.supportedSuites,
                                localPQCSuitesAvailable: !localPQCSuites.isEmpty
                            ) {
                                logger.error(
                                    "❌ \(rejection.diagnosticMessage, privacy: .public). peer=\(peerDiagnosticLabel, privacy: .public)"
                                )
                                return
                            }

                            let compatibleSuites = InboundProtocolIdentitySelectionPolicy
                                .compatibleResponderPQCSuites(
                                    localPQCSuites,
                                    algorithm: inboundProtocolIdentity.algorithm
                                )
                            guard !compatibleSuites.isEmpty else {
                                logger.error(
                                    "❌ \(InboundProtocolIdentitySelectionError.noCompatibleResponderSuite(inboundProtocolIdentity.algorithm).localizedDescription, privacy: .public). peer=\(peerDiagnosticLabel, privacy: .public)"
                                )
                                return
                            }
                            sigAAlgorithm = inboundProtocolIdentity.algorithm
                            offeredSuites = compatibleSuites
                        } else {
                            // Peer is classic-only.
                            selection = .classicOnly
                            cryptoProvider = CryptoProviderFactory.make(policy: selection)
                            sigAAlgorithm = .ed25519
                            offeredSuites = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
                        }

                        let identityProvider = DeviceIdentityHandshakeProvider(
                            sigAAlgorithm: sigAAlgorithm,
                            protocolSigningKeyProtection: inboundProtocolIdentity.protection,
                            includeSecureEnclavePoP: policy.requireSecureEnclavePoP
                        )

                        do {
                            let cryptoPolicy = HandshakeCryptoPolicyResolver.policy(for: offeredSuites)
                            driver = try HandshakeDriver(
                                transport: transport,
                                cryptoProvider: cryptoProvider,
                                protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: sigAAlgorithm),
                                identityProvider: identityProvider,
                                sigAAlgorithm: sigAAlgorithm,
                                offeredSuites: offeredSuites,
                                policy: effectivePolicy,
                                cryptoPolicy: cryptoPolicy,
                                localSOAPeerId: localSOAPeerId,
                                expectedRemoteSOAPeerId: expectedRemoteSOAPeerId,
                                authenticatedIncomingEstablishedPolicy: effectivePolicy.requirePQC
                                    ? .replaceAuthenticated
                                    : .rejectDuplicate
                            )
                            logger.info("🤝 入站 HandshakeDriver 初始化完成: sigA=\(sigAAlgorithm.rawValue, privacy: .public) provider=\(String(describing: type(of: cryptoProvider)), privacy: .public)")
                        } catch {
                            logger.error("❌ 入站 HandshakeDriver 初始化失败: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
                            return
                        }
                    } else {
                        logger.debug("ℹ️ 入站首帧不是 MessageA（忽略，等待下一帧） size=\(frame.count, privacy: .public)")
                        continue
                    }
                }

                guard let activeDriver = driver else { continue }
                await activeDriver.handleMessage(frame, from: peer)
                let st = await activeDriver.getCurrentState()
                logger.debug("🤝 HandshakeDriver state: \(st.diagnosticSummary, privacy: .public)")

                if case .failed(let reason) = st {
                    if let previousKeys = previousSessionKeysBeforeRekey {
                        previousSessionKeysBeforeRekey = nil
                        sessionKeys = previousKeys
                        let restoredPeerId = peerIdForPresence
                        Task { @MainActor in
                            ConnectionPresenceService.shared.clearRekeying(peerId: restoredPeerId)
                            self.connectionStatus = .connected
                        }
                        logger.warning(
                            "⚠️ 入站 rekey 失败，已恢复旧会话: peer=\(peerDiagnosticLabel, privacy: .public) reason=\(reason.diagnosticReasonCode, privacy: .public) suite=\(previousKeys.negotiatedSuite.rawValue, privacy: .public)"
                        )
                        driver = nil
                        continue
                    }

                    logger.warning(
                        "⚠️ 入站握手失败，等待同连接重试: peer=\(peerDiagnosticLabel, privacy: .public) reason=\(reason.diagnosticReasonCode, privacy: .public)"
                    )
                    authenticatedRemoteAuthority = nil
                    driver = nil
                    continue
                }

                switch st {
                case .waitingFinished(_, let keys, _):
                    if let declaredDeviceIdForVerification {
                        await MainActor.run {
                            PairingTrustApprovalService.shared.updateVerificationCode(
                                declaredDeviceId: declaredDeviceIdForVerification,
                                sessionKeys: keys
                            )
                        }
                    }
                case .established(let keys):
                    authenticatedRemoteAuthority = await activeDriver.getAuthenticatedRemoteAuthority()
                    sessionKeys = keys
                    previousSessionKeysBeforeRekey = nil
                    do {
                        try await sendInboundPostAuthPairingIdentityExchange(keys: keys)
                    } catch {
                        logger.error(
                            "❌ inbound post-auth pairingIdentityExchange fail-fast: peer=\(peerDiagnosticLabel, privacy: .public) stage=pairing_identity_exchange reason=\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                        )
                        connection.cancel()
                        return
                    }
                    if let declaredDeviceIdForVerification {
                        await MainActor.run {
                            PairingTrustApprovalService.shared.updateVerificationCode(
                                declaredDeviceId: declaredDeviceIdForVerification,
                                sessionKeys: keys
                            )
                        }
                    }
                    await publishInboundClassicTransferSession(keys: keys)
                    let published = await publishInboundPresence(keys: keys)
                    if !published {
                        logger.warning(
                            "⚠️ inbound established before route metadata was complete; keeping control session alive while waiting for pairing identity or heartbeat metadata peer=\(peerDiagnosticLabel, privacy: .public)"
                        )
                    }

                    if !didMarkEstablished {
                        didMarkEstablished = true
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.activeInboundSessions += 1
                            self.connectionStatus = .connected
                        }
                    } else {
                        await MainActor.run { [weak self] in
                            self?.connectionStatus = .connected
                        }
                    }
                default:
                    break
                }
            }
        } catch {
            if let framedError = error as? FramedReaderError, framedError == .peerClosed {
                logger.debug("ℹ️ 入站控制通道结束（peer closed）")
            } else {
                logger.debug("ℹ️ 入站控制通道结束: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
            }
        }
        }

        await runSession()
        await ClassicTransferSessionRegistry.shared.remove(sessionId: classicTransferSessionId)
        if let pairKey = inboundPairKey {
            await PeerSessionArbiter.shared.clearEstablished(pairKey: pairKey)
            await PeerSessionArbiter.shared.clearOutgoing(pairKey: pairKey, attemptId: nil)
        }
        let disconnectedPeerIds = didMarkEstablished
            ? Self.normalizedClassicTransferSessionAliases([
                peerIdForPresence,
                declaredDeviceIdForVerification
            ])
            : []
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.finishProvisionalInboundConnection(connection)
            self.removeInboundControlSession(id: inboundControlSessionId)
            if didMarkEstablished {
                self.activeInboundSessions = max(0, self.activeInboundSessions - 1)
                for peerId in disconnectedPeerIds {
                    ConnectionPresenceService.shared.markDisconnected(peerId: peerId)
                }
                if self.activeInboundSessions == 0, self.connections.isEmpty {
                    self.connectionStatus = .disconnected
                }
            }
        }
    }

    private func normalizedHostNameToken(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func stableEndpointLabel(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service(let name, _, let domain, _):
            let resolvedDomain = domain.isEmpty ? "local." : domain.lowercased()
            return "bonjour:\(name)@\(resolvedDomain)"
        case .hostPort(let host, _):
            return "peer:\(normalizePeerHostToken(String(describing: host)))"
        default:
            return "peer:\(normalizePeerHostToken(endpoint.debugDescription))"
        }
    }


    private static func localProtocolIdentityPublicKeysForPairing() async throws -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        try await LocalProtocolIdentityAdvertisement.load()
    }

    nonisolated private static func endpointHostOrIP(for endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            return normalizePeerHostToken(String(describing: host))
        default:
            return nil
        }
    }

    nonisolated private static func normalizedClassicTransferSessionAliases(
        _ candidates: [String?]
    ) -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()

        for raw in candidates {
            guard let raw else { continue }
            for candidate in PeerTrustLookup.lookupCandidates(for: raw) {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let lowered = trimmed.lowercased()
                guard seen.insert(lowered).inserted else { continue }
                normalized.append(trimmed)
            }
        }

        return normalized
    }

    nonisolated private static func normalizePeerHostToken(_ raw: String) -> String {
        P2PPeerHostTokenNormalizer.normalize(raw)
    }

    private func localInterfaceCacheSnapshot(forceRefresh: Bool = false) -> LocalInterfaceCacheEntry {
        if !forceRefresh,
           let cached = localInterfaceCacheEntry,
           Date().timeIntervalSince(cached.updatedAt) < localInterfaceCacheTTL {
            return cached
        }

        var addresses: Set<String> = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            defer { freeifaddrs(ifaddr) }
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee, let sa = interface.ifa_addr else { continue }
                let family = sa.pointee.sa_family
                guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 else {
                    continue
                }

                let data = Data(bytes: buf, count: buf.count)
                let trimmed = data.prefix { $0 != 0 }
                let ip = String(decoding: trimmed, as: UTF8.self)
                if let normalized = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(ip) {
                    addresses.insert(normalized)
                }
            }
        }

        let snapshot = LocalInterfaceCacheEntry(
            addresses: addresses,
            normalizedHostName: normalizedHostNameToken(Host.current().localizedName ?? ""),
            updatedAt: Date()
        )
        localInterfaceCacheEntry = snapshot
        return snapshot
    }

 /// 判断给定 IPv4 地址是否属于本机，避免自连接导致路径冲突
    private func isLocalIPAddress(_ address: String) -> Bool {
        guard let normalizedAddress = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(address) else { return false }
        return localInterfaceCacheSnapshot().addresses.contains(normalizedAddress)
    }

 /// 判断是否为本机设备（严格匹配）
    private func isProbablyLocalDevice(name: String, ipv4: String?, ipv6: String?) -> Bool {
        let snapshot = localInterfaceCacheSnapshot()

        if let normalizedIPv4 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(ipv4), snapshot.addresses.contains(normalizedIPv4) {
            return true
        }
        if let normalizedIPv6 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(ipv6), snapshot.addresses.contains(normalizedIPv6) {
            return true
        }

        let normalizedLocalName = snapshot.normalizedHostName
        guard !normalizedLocalName.isEmpty else { return false }
        return normalizedHostNameToken(name) == normalizedLocalName
    }

    nonisolated static func smokeConnectionPathClassification(
        interfaceTypes: [String],
        interfaceNames: [String],
        pathDescription: String
    ) -> SmokeConnectionPathClassification {
        let normalizedTypes = Set(interfaceTypes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let normalizedNames = interfaceNames.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let description = pathDescription.lowercased()
        let hasWiFi = normalizedTypes.contains("wifi")
        let hasWiredEthernet = normalizedTypes.contains("wiredethernet")
        let hasAWDL = normalizedNames.contains { name in
            name.hasPrefix("awdl") || name.hasPrefix("llw")
        }
        let hasGenericAttachedInterface = normalizedNames.contains { name in
            guard name.hasPrefix("en") else { return false }
            let suffix = name.dropFirst(2)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        } && !hasWiFi
        let attached = hasWiredEthernet || hasGenericAttachedInterface
        let routeClass: String
        if attached {
            routeClass = "attached"
        } else if hasAWDL {
            routeClass = "awdl"
        } else if hasWiFi {
            routeClass = "wifi"
        } else {
            routeClass = "other"
        }
        let linkLocal = description.contains("169.254.")
            || (description.contains("fe80:") && routeClass != "awdl")
        return SmokeConnectionPathClassification(
            routeClass: routeClass,
            attached: attached,
            linkLocal: linkLocal
        )
    }

    private nonisolated static func smokeInterfaceTypeToken(
        _ type: NWInterface.InterfaceType
    ) -> String {
        switch type {
        case .wifi:
            return "wifi"
        case .wiredEthernet:
            return "wiredEthernet"
        case .cellular:
            return "cellular"
        case .loopback:
            return "loopback"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
        }
    }

    private nonisolated static func appendSmokeConnectionPathEvidence(
        connection: NWConnection,
        deviceId: String,
        endpoint: NWEndpoint
    ) {
        guard let path = connection.currentPath else {
            RemoteControlSmokeStatusWriter.append(
                "p2p-connection-ready-path deviceId=\(RemoteControlSmokeStatusWriter.fieldValue(deviceId)) endpointClass=\(smokeEndpointClass(endpoint)) pathStatus=missing usedInterfaceTypes=missing usedInterfaceNames=missing routeClass=other attached=0 linkLocal=0"
            )
            return
        }
        let knownTypes: [NWInterface.InterfaceType] = [
            .wifi,
            .wiredEthernet,
            .cellular,
            .loopback,
            .other,
        ]
        let usedTypes = knownTypes.filter { path.usesInterfaceType($0) }
        let usedTypeTokens = usedTypes.map(smokeInterfaceTypeToken)
        let usedTypeSet = Set(usedTypes)
        let usedInterfaceNames = path.availableInterfaces
            .filter { usedTypeSet.contains($0.type) }
            .map(\.name)
            .sorted()
        let classification = smokeConnectionPathClassification(
            interfaceTypes: usedTypeTokens,
            interfaceNames: usedInterfaceNames,
            pathDescription: String(describing: path)
        )
        RemoteControlSmokeStatusWriter.append(
            "p2p-connection-ready-path deviceId=\(RemoteControlSmokeStatusWriter.fieldValue(deviceId)) endpointClass=\(smokeEndpointClass(endpoint)) pathStatus=\(path.status == .satisfied ? "satisfied" : "unsatisfied") usedInterfaceTypes=\(RemoteControlSmokeStatusWriter.fieldValue(usedTypeTokens.joined(separator: ","))) usedInterfaceNames=\(RemoteControlSmokeStatusWriter.fieldValue(usedInterfaceNames.joined(separator: ","))) routeClass=\(classification.routeClass) attached=\(classification.attached ? 1 : 0) linkLocal=\(classification.linkLocal ? 1 : 0)"
        )
    }

    /// 等待连接建立（负责设置 stateUpdateHandler + 启动连接）
    private func waitForConnection(
        _ connection: NWConnection,
        deviceId: String,
        endpoint: NWEndpoint,
        timeoutSeconds: TimeInterval = 10
    ) async throws {
        let cancellationHandle = ConnectionWaitCancellationHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let context = WaitForConnectionContext(continuation: continuation)
                cancellationHandle.install(context, connection: connection)

                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let connection else {
                        context.complete(.failure(P2PDiscoveryError.connectionCancelled))
                        return
                    }
                    Task { @MainActor [weak self, weak connection] in
                        guard let self, let connection else { return }
                        self.handleConnectionStateUpdate(
                            state,
                            for: deviceId,
                            connection: connection
                        )
                    }

                    switch state {
                    case .ready:
                        Self.appendSmokeConnectionPathEvidence(
                            connection: connection,
                            deviceId: deviceId,
                            endpoint: endpoint
                        )
                        context.complete(.success(())) {
                            connection.stateUpdateHandler = { [weak self, weak connection] terminalState in
                                guard let connection else { return }
                                Task { @MainActor [weak self, weak connection] in
                                    guard let self, let connection else { return }
                                    self.handleConnectionStateUpdate(
                                        terminalState,
                                        for: deviceId,
                                        connection: connection
                                    )
                                }
                            }
                        }
                    case .failed(let error):
                        context.complete(.failure(error)) {
                            connection.stateUpdateHandler = nil
                        }
                    case .cancelled:
                        context.complete(.failure(P2PDiscoveryError.connectionCancelled)) {
                            connection.stateUpdateHandler = nil
                        }
                    default:
                        break
                    }
                }

                guard !Task.isCancelled else {
                    cancellationHandle.cancel(connection: connection)
                    return
                }
                connection.start(queue: outboundConnectionQueue)

                context.timeoutTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    context.complete(.failure(P2PDiscoveryError.timeout))
                }
            }
        } onCancel: {
            cancellationHandle.cancel(connection: connection)
        }
    }

 // MARK: - 辅助方法：名称 / 网络信息解析

 /// 获取本机设备名称
    private func getDeviceName() -> String {
        return Host.current().localizedName ?? "SkyBridge设备"
    }

 /// 从结果中提取设备名称 - 2025 增强版
    private func extractDeviceName(from result: NWBrowser.Result) -> String {
        var deviceName = "未知设备"

        if case .service(let name, _, _, _) = result.endpoint {
 // 使用服务名作为基础
            deviceName = name

 // 尝试从 result.metadata 获取 TXT 记录（使用统一解析器）
            let metadata = result.metadata
            if case .bonjour(let txtRecord) = metadata {
                let deviceInfo = BonjourTXTParser.extractDeviceInfo(txtRecord)
 // 优先使用设备名称
                if let friendlyName = deviceInfo.name ?? deviceInfo.hostname {
                    deviceName = friendlyName
                }

 // 添加设备类型信息
                if let deviceType = deviceInfo.type ?? deviceInfo.model {
                    deviceName += " (\(deviceType))"
                }
            }

 // 清理设备名称
            deviceName = cleanDeviceName(deviceName)

            if isProbablyLocalDevice(name: deviceName, ipv4: nil, ipv6: nil) {
                deviceName += " (本机)"
            }
        }

        logger.info("提取设备名称: \(deviceName)")
        return deviceName
    }

 /// 解析 TXT 记录（已废弃，请使用 BonjourTXTParser）
    @available(*, deprecated, message: "Use BonjourTXTParser.parse instead")
    private func parseTXTRecord(_ txtRecord: NWTXTRecord) -> [String: String]? {
        let dict = BonjourTXTParser.parse(txtRecord)
        return dict.isEmpty ? nil : dict
    }

 /// 清理设备名称
    private func cleanDeviceName(_ name: String) -> String {
        var cleaned = name

        cleaned = cleaned.replacingOccurrences(of: "._tcp", with: "")
        cleaned = cleaned.replacingOccurrences(of: "._udp", with: "")
        cleaned = cleaned.replacingOccurrences(of: ".local", with: "")

        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        if cleaned.count > 50 {
            cleaned = String(cleaned.prefix(47)) + "..."
        }

        return cleaned
    }

    private func resolveNetServiceEndpoint(
        domain: String,
        type: String,
        name: String,
        timeoutSeconds: TimeInterval
    ) async -> NetServiceResolvedEndpoint? {
        let resolved: NetServiceResolvedEndpoint?
        do {
            resolved = try await netServiceResolveLimiter.withPermit {
                try await Self.resolveNetServiceEndpointOnMain(
                    domain: domain,
                    type: type,
                    name: name,
                    timeoutSeconds: timeoutSeconds
                )
            }
        } catch is CancellationError {
            return nil
        } catch {
            logger.debug(
                "ℹ️ NetService 解析失败: name=<redacted> type=\(type, privacy: .public) errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
            )
            return nil
        }

        if resolved == nil {
            logger.debug("ℹ️ NetService 解析失败: name=<redacted> type=\(type, privacy: .public)")
        }
        return resolved
    }

    @MainActor
    private static func resolveNetServiceEndpointOnMain(
        domain: String,
        type: String,
        name: String,
        timeoutSeconds: TimeInterval
    ) async throws -> NetServiceResolvedEndpoint {
        let cancellationHandle = NetServiceResolveCancellationHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NetServiceResolvedEndpoint, Error>) in
                let service = NetService(
                    domain: domain.isEmpty ? "local." : domain,
                    type: type,
                    name: name
                )
                let context = NetServiceResolveContext(
                    service: service,
                    timeoutSeconds: timeoutSeconds,
                    continuation: continuation
                )
                guard cancellationHandle.install(context), !Task.isCancelled else {
                    cancellationHandle.cancel()
                    return
                }
                context.start()
            }
        } onCancel: {
            cancellationHandle.cancel()
        }
    }

    private func resolveViaNetServiceIfNeeded(
        result: NWBrowser.Result,
        deviceIndex: Int,
        serviceType: String,
        replaceExisting: Bool
    ) {
        guard deviceIndex >= 0 && deviceIndex < discoveredDevices.count else { return }
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return }
        let route = DiscoveryHydrationRoute(
            serviceName: name,
            serviceType: type,
            domain: domain
        )

        if replaceExisting {
            invalidateDiscoveryHydration(route: route, clearCooldown: true)
        }

        let d = discoveredDevices[deviceIndex]
        let hasPort = (d.portMap[serviceType] ?? 0) > 0
        let hasAddr = (d.ipv4 != nil) || (d.ipv6 != nil)
        guard !hasPort || !hasAddr else {
            invalidateDiscoveryHydration(route: route, clearCooldown: true)
            return
        }
        let routeIdentifier = Self.bonjourIdentifier(for: route)
        guard let stableDeviceIdentity = Self.stableDiscoveryHydrationIdentity(
            for: d,
            bonjourIdentifier: routeIdentifier
        ) else {
            return
        }

        if let owner = netServiceResolveTasks[route] {
            if !replaceExisting,
               owner.ticket.stableDeviceIdentity == stableDeviceIdentity,
               owner.ticket.serviceType == serviceType {
                return
            }
            invalidateDiscoveryHydration(route: route, clearCooldown: true)
        }
        let now = Date()
        guard Self.canAdmitHydrationTaskOwner(
            currentCount: netServiceResolveTasks.count,
            limit: Self.maximumHydrationTaskOwners
        ) else {
            logHydrationCapacityRejectionIfNeeded(now: now)
            return
        }
        pruneTXTResolveCooldown(now: now)
        if let last = txtResolveCooldown[route], now.timeIntervalSince(last) < 2.0 { return }
        txtResolveCooldown[route] = now

        let taskToken = UUID()
        let ticket = discoveryHydrationGenerationState.issue(
            route: route,
            stableDeviceIdentity: stableDeviceIdentity,
            serviceType: serviceType
        )

        let task = Task { @MainActor [weak self, domain, type, name, serviceType, route, ticket] in
            guard let self else { return }
            defer {
                self.finishNetServiceResolveTask(
                    route: route,
                    token: taskToken,
                    ticket: ticket
                )
            }
            guard let resolved = await self.resolveNetServiceEndpoint(
                domain: domain,
                type: type,
                name: name,
                timeoutSeconds: 1.2
            ) else {
                return
            }

            guard self.netServiceResolveTasks[route]?.token == taskToken,
                  let currentIndex = self.currentHydrationDeviceIndex(for: ticket) else {
                return
            }

            let dd = self.discoveredDevices[currentIndex]
            guard let currentStableIdentity = Self.stableDiscoveryHydrationIdentity(
                for: dd,
                bonjourIdentifier: Self.bonjourIdentifier(for: route)
            ), self.discoveryHydrationGenerationState.accepts(
                ticket,
                currentStableDeviceIdentity: currentStableIdentity,
                hasService: dd.services.contains(serviceType)
            ) else {
                return
            }
            var newPortMap = dd.portMap
            if (newPortMap[serviceType] ?? 0) == 0, resolved.port > 0 {
                newPortMap[serviceType] = resolved.port
            }

            let newIPv4 = dd.ipv4 ?? resolved.ipv4
            let newIPv6 = dd.ipv6 ?? resolved.ipv6
            let bonjourUniqueIdentifier = Self.bonjourIdentifier(for: route)
            let preferredIdentifier = P2PDiscoveryBonjourPolicy.preferredUniqueIdentifier(
                deviceId: dd.deviceId,
                pubKeyFP: dd.pubKeyFP,
                bonjourIdentifier: bonjourUniqueIdentifier,
                ipv4: newIPv4,
                ipv6: newIPv6
            )

            let updated = DiscoveredDevice(
                id: dd.id,
                name: dd.name,
                ipv4: newIPv4,
                ipv6: newIPv6,
                services: dd.services,
                portMap: newPortMap,
                connectionTypes: dd.connectionTypes,
                uniqueIdentifier: preferredIdentifier ?? dd.uniqueIdentifier,
                routeIdentifiers: DiscoveredDevice.mergedRouteIdentifiers(
                    dd.routeIdentifiers,
                    [bonjourUniqueIdentifier].compactMap { $0 }
                ),
                signalStrength: dd.signalStrength,
                networkLinkStatus: dd.networkLinkStatus,
                source: dd.source,
                isLocalDevice: dd.isLocalDevice,
                deviceId: dd.deviceId,
                pubKeyFP: dd.pubKeyFP,
                macSet: dd.macSet
            )
            self.discoveredDevices[currentIndex] = updated
            self.discoveryCapacityState.recordActivity(for: updated.id, at: Date())
        }
        netServiceResolveTasks[route] = NetServiceResolveTaskOwner(
            token: taskToken,
            ticket: ticket,
            task: task
        )
    }

    private func pruneTXTResolveCooldown(now: Date) {
        txtResolveCooldown = txtResolveCooldown.filter {
            now.timeIntervalSince($0.value) <= Self.txtResolveCooldownRetentionSeconds
        }
        let overflow = txtResolveCooldown.count - Self.maximumTXTResolveCooldownEntries + 1
        guard overflow > 0 else { return }
        for key in txtResolveCooldown
            .sorted(by: { $0.value < $1.value })
            .prefix(overflow)
            .map(\.key) {
            txtResolveCooldown.removeValue(forKey: key)
        }
    }

    private func finishNetServiceResolveTask(
        route: DiscoveryHydrationRoute,
        token: UUID,
        ticket: DiscoveryHydrationTicket
    ) {
        guard netServiceResolveTasks[route]?.token == token else { return }
        netServiceResolveTasks.removeValue(forKey: route)
        discoveryHydrationGenerationState.retire(ticket)
    }

    private func invalidateDiscoveryHydration(for endpoint: NWEndpoint) {
        guard case .service(let name, let type, let domain, _) = endpoint else { return }
        invalidateDiscoveryHydration(
            route: DiscoveryHydrationRoute(
                serviceName: name,
                serviceType: type,
                domain: domain
            ),
            clearCooldown: true
        )
    }

    private func invalidateDiscoveryHydration(
        route: DiscoveryHydrationRoute,
        clearCooldown: Bool
    ) {
        discoveryHydrationGenerationState.invalidate(route: route)
        netServiceResolveTasks.removeValue(forKey: route)?.task.cancel()
        if clearCooldown {
            txtResolveCooldown.removeValue(forKey: route)
        }
    }

    private func cancelNetServiceResolveTasks() {
        discoveryHydrationGenerationState.invalidateAll()
        let tasks = netServiceResolveTasks.values.map(\.task)
        netServiceResolveTasks.removeAll(keepingCapacity: false)
        lastHydrationCapacityLogAt = nil
        tasks.forEach { $0.cancel() }
    }
 /// 将网络发现的设备映射为 P2P 设备（供上层统一使用）
 /// Swift 6.2.1：公钥数据在发现阶段暂不可用，将在安全握手时获取
    private static func mapToP2PDevice(_ d: DiscoveredDevice) -> P2PDevice {
        let address = d.ipv4 ?? d.ipv6 ?? ""
        let portInt: Int = {
            if let port = d.portMap["_skybridge._tcp"], port > 0 { return port }
            if let port = d.portMap["_skybridge._udp"], port > 0 { return port }
            for (serviceType, port) in d.portMap where port > 0 {
                if serviceType.hasPrefix("_"), serviceType.hasSuffix("._tcp") || serviceType.hasSuffix("._udp") {
                    return port
                }
            }
            return 0
        }()
        let endpoints: [String] = portInt > 0 ? ["\(address):\(portInt)"] : (address.isEmpty ? [] : [address])
        let stableId: String = {
            if let persistent = d.deviceId, !persistent.isEmpty {
                return persistent
            }
            return d.id.uuidString
        }()
        return P2PDevice(
            id: stableId,
            name: d.name,
            type: .macOS,
            address: address,
            port: UInt16(portInt),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capabilities: Array(Set(d.services)).sorted(),
            publicKey: Data(), // 公钥在协议握手主路径中获取并完成绑定
            lastSeen: Date(),
            endpoints: endpoints,
            lastMessageTimestamp: nil,
            isVerified: false,
            verificationFailedReason: d.pubKeyFP == nil ? "等待公钥交换" : nil,
            persistentDeviceId: d.deviceId,
            pubKeyFingerprint: d.pubKeyFP,
            macAddresses: d.macSet.isEmpty ? nil : d.macSet
        )
    }
}

fileprivate func P2P_ExtractIPAddress(from data: Data) -> String {
    return data.withUnsafeBytes { bytes in
        guard bytes.count >= MemoryLayout<sockaddr>.size,
              let sockaddr = bytes.bindMemory(to: sockaddr.self).baseAddress else {
            return "未知地址"
        }
        switch Int32(sockaddr.pointee.sa_family) {
        case AF_INET:
            guard bytes.count >= MemoryLayout<sockaddr_in>.size,
                  let addr = bytes.bindMemory(to: sockaddr_in.self).baseAddress,
                  let cstr = inet_ntoa(addr.pointee.sin_addr) else {
                return "未知地址"
            }
            return String(cString: cstr)
        case AF_INET6:
            guard bytes.count >= MemoryLayout<sockaddr_in6>.size,
                  let addr = bytes.bindMemory(to: sockaddr_in6.self).baseAddress else {
                return "未知地址"
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var sin6_addr = addr.pointee.sin6_addr
            guard inet_ntop(AF_INET6, &sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return "未知地址"
            }
            let data = Data(bytes: buffer, count: Int(INET6_ADDRSTRLEN))
            let trimmed = data.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
        default:
            return "未知地址"
        }
    }
}
