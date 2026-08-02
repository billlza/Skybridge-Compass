#if os(macOS)
import Foundation
import Network
import OSLog

/// Reports whether this Mac can realistically be discovered and woken while asleep.
///
/// Wake on Demand has no opt-in API: macOS registers the app's already-published Bonjour service
/// with a Sleep Proxy Server on the network shortly before sleeping, and the proxy then answers
/// mDNS queries and wakes the host when a connection arrives. So the app cannot "enable" it — it
/// can only avoid breaking the preconditions and tell the user whether they hold.
///
/// Preconditions and who owns them:
/// 1. The service must be published through mDNSResponder and still registered at sleep time.
///    Owned by `P2PDiscoveryService`; withdrawing the advertisement on `willSleepNotification`
///    would defeat Wake on Demand entirely, which is why no such teardown exists.
/// 2. A Sleep Proxy Server must exist on the link. **Detectable** — it advertises
///    `_sleep-proxy._udp`, which is what this type browses for.
/// 3. "Wake for network access" must be enabled in system settings. **Not detectable through
///    public API** in the current SDK, so it is reported as unknown rather than guessed.
@available(macOS 14.0, *)
@MainActor
public final class MacWakeOnDemandReadiness: ObservableObject {
    public static let shared = MacWakeOnDemandReadiness()

    /// Bonjour service type advertised by Sleep Proxy Servers (AirPort/Apple TV/HomePod and
    /// compatible implementations).
    public nonisolated static let sleepProxyServiceType = "_sleep-proxy._udp"

    /// How long a probe waits for a proxy to answer before reporting "none found".
    /// Sleep proxies answer from cache almost immediately; this only bounds the failure case.
    public nonisolated static let probeTimeoutSeconds: TimeInterval = 5

    public enum SleepProxyAvailability: Equatable, Sendable {
        /// Not probed yet. Must not be read as "absent".
        case unprobed
        case present(proxyCount: Int)
        case absent
        /// The browse itself failed (for example local-network permission or an interface with no
        /// link). Distinct from `absent`, because "we could not look" is not "there is none".
        case probeFailed(reason: String)
    }

    /// Whether "Wake for network access" is on.
    ///
    /// The current macOS SDK exposes no public API for this preference, so it is deliberately
    /// modelled as a three-state value instead of a fabricated boolean. `undetermined` means the
    /// user must be asked to check it, not that it is off.
    public enum WakeForNetworkAccessSetting: Equatable, Sendable {
        case undetermined
    }

    @Published public private(set) var sleepProxyAvailability: SleepProxyAvailability = .unprobed
    @Published public private(set) var lastProbedAt: Date?

    public nonisolated var wakeForNetworkAccessSetting: WakeForNetworkAccessSetting {
        .undetermined
    }

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "WakeOnDemand")
    private var probeTask: Task<SleepProxyAvailability, Never>?

    init() {}

    /// Overall assessment, phrased so that "unknown" can never be mistaken for "ready".
    public enum Assessment: Equatable, Sendable {
        /// A proxy exists; whether the system setting is on still cannot be verified in-process.
        case proxyAvailableSettingUnverifiable(proxyCount: Int)
        /// No proxy on this link: the Mac will simply disappear from discovery once it sleeps.
        case noProxyOnLink
        case notAssessed(reason: String)
    }

    public var assessment: Assessment {
        switch sleepProxyAvailability {
        case .present(let proxyCount):
            .proxyAvailableSettingUnverifiable(proxyCount: proxyCount)
        case .absent:
            .noProxyOnLink
        case .unprobed:
            .notAssessed(reason: "尚未探测")
        case .probeFailed(let reason):
            .notAssessed(reason: reason)
        }
    }

    /// Probes the link for Sleep Proxy Servers. Concurrent callers share one probe.
    @discardableResult
    public func probeSleepProxyAvailability() async -> SleepProxyAvailability {
        if let probeTask {
            return await probeTask.value
        }

        let task = Task<SleepProxyAvailability, Never> { [weak self] in
            let result = await Self.browseForSleepProxies(
                timeoutSeconds: Self.probeTimeoutSeconds
            )
            await MainActor.run {
                self?.apply(result)
            }
            return result
        }
        probeTask = task
        defer { probeTask = nil }
        return await task.value
    }

    private func apply(_ result: SleepProxyAvailability) {
        sleepProxyAvailability = result
        lastProbedAt = Date()

        switch result {
        case .present(let proxyCount):
            logger.info(
                """
                ✅ 链路上存在 Sleep Proxy（\(proxyCount, privacy: .public) 个）：休眠后本机仍可被发现并被唤醒，\
                前提是系统设置中的「唤醒以供网络访问」已开启（无公开 API 可验证）
                """
            )
        case .absent:
            logger.warning(
                "⚠️ 链路上未发现 Sleep Proxy：本机休眠后会从设备发现中消失，直到被手动唤醒"
            )
        case .probeFailed(let reason):
            logger.error("❌ Sleep Proxy 探测失败（不代表不存在）: \(reason, privacy: .public)")
        case .unprobed:
            break
        }
    }

    /// Browses `_sleep-proxy._udp` for a bounded window.
    ///
    /// `nonisolated` and self-contained so the browse runs off the main actor; only the published
    /// result is applied back on it.
    private nonisolated static func browseForSleepProxies(
        timeoutSeconds: TimeInterval
    ) async -> SleepProxyAvailability {
        final class ProbeState: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false

            func finishOnce(
                _ continuation: CheckedContinuation<SleepProxyAvailability, Never>,
                with value: SleepProxyAvailability
            ) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return false }
                finished = true
                continuation.resume(returning: value)
                return true
            }
        }

        let state = ProbeState()
        let queue = DispatchQueue(label: "com.skybridge.wake-on-demand.probe")
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: sleepProxyServiceType, domain: nil),
            using: parameters
        )

        return await withTaskGroup(of: SleepProxyAvailability?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    browser.browseResultsChangedHandler = { results, _ in
                        guard !results.isEmpty else { return }
                        _ = state.finishOnce(
                            continuation,
                            with: .present(proxyCount: results.count)
                        )
                    }
                    browser.stateUpdateHandler = { browserState in
                        switch browserState {
                        case .failed(let error):
                            _ = state.finishOnce(
                                continuation,
                                with: .probeFailed(reason: error.localizedDescription)
                            )
                        case .cancelled:
                            // Cancellation is driven by the timeout branch, which supplies the
                            // real verdict; only resume here if it has not already.
                            _ = state.finishOnce(continuation, with: .absent)
                        default:
                            break
                        }
                    }
                    browser.start(queue: queue)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }

            let first = await group.next()
            browser.cancel()
            group.cancelAll()

            // `nil` means the timeout won: no proxy answered within the window.
            return first.flatMap { $0 } ?? .absent
        }
    }
}
#endif
