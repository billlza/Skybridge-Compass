import Combine
import Darwin
import Foundation
import SystemConfiguration

public enum TopBarNetworkProbeStatus: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

public struct TopBarNetworkLocationStatus: Equatable, Sendable {
    public var status: TopBarNetworkProbeStatus
    public var publicIPAddress: String?
    public var city: String?
    public var countryCode: String?
    public var isSystemProxyEnabled: Bool

    public static let idle = TopBarNetworkLocationStatus(
        status: .idle,
        publicIPAddress: nil,
        city: nil,
        countryCode: nil,
        isSystemProxyEnabled: false
    )
}

public struct TopBarNetworkSpeedStatus: Equatable, Sendable {
    public var status: TopBarNetworkProbeStatus
    public var inboundBytesPerSecond: UInt64?
    public var outboundBytesPerSecond: UInt64?

    public static let idle = TopBarNetworkSpeedStatus(
        status: .idle,
        inboundBytesPerSecond: nil,
        outboundBytesPerSecond: nil
    )
}

public struct TopBarNetworkLatencyStatus: Equatable, Sendable {
    public var status: TopBarNetworkProbeStatus
    public var milliseconds: Int?

    public static let idle = TopBarNetworkLatencyStatus(
        status: .idle,
        milliseconds: nil
    )
}

public struct TopBarNetworkStatusSnapshot: Equatable, Sendable {
    public var location: TopBarNetworkLocationStatus
    public var speed: TopBarNetworkSpeedStatus
    public var latency: TopBarNetworkLatencyStatus

    public static let idle = TopBarNetworkStatusSnapshot(
        location: .idle,
        speed: .idle,
        latency: .idle
    )
}

@available(macOS 14.0, *)
@MainActor
public final class TopBarNetworkStatusService: ObservableObject {
    public static let shared = TopBarNetworkStatusService()

    @Published public private(set) var snapshot: TopBarNetworkStatusSnapshot = .idle

    private struct InterfaceCounters: Sendable {
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    private struct IPGeolocationResponse: Decodable {
        let ip: String?
        let city: String?
        let countryCode: String?

        enum CodingKeys: String, CodingKey {
            case ip
            case city
            case countryCode = "country_code"
        }
    }

    private let locationURL = URL(string: "https://ipapi.co/json/")!
    private let latencyURL = URL(string: "https://skybridge-compass.vercel.app")!
    private let urlSession: URLSession
    private static let speedSamplingInterval: TimeInterval = 5.0
    private static let legacyConsumerID = UUID()
    private var timer: Timer?
    private var activeConsumers: Set<UUID> = []
    private var probeGeneration: UInt64 = 0
    private var previousCounters: InterfaceCounters?
    private var previousCounterDate: Date?
    private var speedTask: Task<Void, Never>?
    private var locationTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var lastLocationRefresh: Date?
    private var lastLatencyRefresh: Date?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        self.urlSession = URLSession(configuration: configuration)
    }

    public func start() {
        activateConsumer(Self.legacyConsumerID)
    }

    public func stop() {
        deactivateConsumer(Self.legacyConsumerID)
    }

    public func activateConsumer(_ consumerID: UUID) {
        activeConsumers.insert(consumerID)
        startMonitoringIfNeeded()
    }

    public func deactivateConsumer(_ consumerID: UUID) {
        activeConsumers.remove(consumerID)
        guard activeConsumers.isEmpty else { return }
        stopMonitoring()
    }

    private func startMonitoringIfNeeded() {
        guard timer == nil else { return }

        probeGeneration &+= 1

        var updated = snapshot
        if updated.location.status == .idle {
            updated.location.status = .loading
        }
        if updated.speed.status == .idle {
            updated.speed.status = .loading
        }
        if updated.latency.status == .idle {
            updated.latency.status = .loading
        }
        snapshot = updated

        primeSpeedBaseline()
        refreshLocationIfNeeded(force: true)
        refreshLatencyIfNeeded(force: true)

        timer = Timer.scheduledTimer(withTimeInterval: Self.speedSamplingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func stopMonitoring() {
        probeGeneration &+= 1
        timer?.invalidate()
        timer = nil
        speedTask?.cancel()
        speedTask = nil
        locationTask?.cancel()
        locationTask = nil
        latencyTask?.cancel()
        latencyTask = nil
        previousCounters = nil
        previousCounterDate = nil
    }

    public func refreshNow() {
        if previousCounters == nil {
            primeSpeedBaseline()
        } else {
            sampleSpeed()
        }
        refreshLocationIfNeeded(force: true)
        refreshLatencyIfNeeded(force: true)
    }

    private func tick() {
        sampleSpeed()
        refreshLocationIfNeeded(force: false)
        refreshLatencyIfNeeded(force: false)
    }

    private func primeSpeedBaseline() {
        guard speedTask == nil else { return }
        let generation = probeGeneration

        speedTask = Task { [weak self] in
            let baseline = await Task.detached(priority: .utility) {
                (counters: Self.currentInterfaceCounters(), sampledAt: Date())
            }.value

            guard let self else { return }
            defer {
                if self.isCurrentProbeGeneration(generation) {
                    self.speedTask = nil
                }
            }

            guard self.isCurrentProbeGeneration(generation), !Task.isCancelled else { return }
            self.previousCounters = baseline.counters
            self.previousCounterDate = baseline.sampledAt

            var updated = self.snapshot
            updated.speed = TopBarNetworkSpeedStatus(
                status: .loading,
                inboundBytesPerSecond: nil,
                outboundBytesPerSecond: nil
            )
            self.snapshot = updated
        }
    }

    private func sampleSpeed() {
        guard speedTask == nil else { return }
        let previousCounters = previousCounters
        let previousCounterDate = previousCounterDate
        let generation = probeGeneration

        speedTask = Task { [weak self] in
            let sample = await Task.detached(priority: .utility) {
                (counters: Self.currentInterfaceCounters(), sampledAt: Date())
            }.value

            guard let self else { return }
            defer {
                if self.isCurrentProbeGeneration(generation) {
                    self.speedTask = nil
                }
            }

            guard self.isCurrentProbeGeneration(generation), !Task.isCancelled else { return }

            let counters = sample.counters
            let now = sample.sampledAt
            defer {
                self.previousCounters = counters
                self.previousCounterDate = now
            }

            guard let previousCounters, let previousCounterDate else {
                var updated = self.snapshot
                updated.speed = TopBarNetworkSpeedStatus(
                    status: .loading,
                    inboundBytesPerSecond: nil,
                    outboundBytesPerSecond: nil
                )
                self.snapshot = updated
                return
            }

            let elapsed = now.timeIntervalSince(previousCounterDate)
            guard elapsed > 0 else { return }

            let inboundDelta = counters.bytesIn >= previousCounters.bytesIn
                ? counters.bytesIn - previousCounters.bytesIn
                : 0
            let outboundDelta = counters.bytesOut >= previousCounters.bytesOut
                ? counters.bytesOut - previousCounters.bytesOut
                : 0

            var updated = self.snapshot
            updated.speed = TopBarNetworkSpeedStatus(
                status: .ready,
                inboundBytesPerSecond: UInt64(Double(inboundDelta) / elapsed),
                outboundBytesPerSecond: UInt64(Double(outboundDelta) / elapsed)
            )
            self.snapshot = updated
        }
    }

    private func refreshLocationIfNeeded(force: Bool) {
        if !force,
           let lastLocationRefresh,
           Date().timeIntervalSince(lastLocationRefresh) < 300 {
            return
        }
        guard locationTask == nil else { return }

        var updated = snapshot
        updated.location.status = .loading
        updated.location.isSystemProxyEnabled = Self.isSystemProxyEnabled()
        snapshot = updated

        let generation = probeGeneration
        locationTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshLocation(generation: generation)
        }
    }

    private func refreshLatencyIfNeeded(force: Bool) {
        if !force,
           let lastLatencyRefresh,
           Date().timeIntervalSince(lastLatencyRefresh) < 15 {
            return
        }
        guard latencyTask == nil else { return }

        var updated = snapshot
        updated.latency.status = .loading
        snapshot = updated

        let generation = probeGeneration
        latencyTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshLatency(generation: generation)
        }
    }

    private func refreshLocation(generation: UInt64) async {
        defer {
            if isCurrentProbeGeneration(generation) {
                lastLocationRefresh = Date()
                locationTask = nil
            }
        }

        do {
            var request = URLRequest(url: locationURL)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 6

            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let payload = try JSONDecoder().decode(IPGeolocationResponse.self, from: data)
            guard let publicIP = payload.ip?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !publicIP.isEmpty else {
                throw URLError(.cannotParseResponse)
            }

            guard isCurrentProbeGeneration(generation), !Task.isCancelled else {
                return
            }

            var updated = snapshot
            updated.location = TopBarNetworkLocationStatus(
                status: .ready,
                publicIPAddress: publicIP,
                city: payload.city?.trimmingCharacters(in: .whitespacesAndNewlines),
                countryCode: payload.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines),
                isSystemProxyEnabled: Self.isSystemProxyEnabled()
            )
            snapshot = updated
        } catch {
            guard !Self.isCancellationError(error),
                  isCurrentProbeGeneration(generation),
                  !Task.isCancelled else {
                return
            }

            var updated = snapshot
            updated.location = TopBarNetworkLocationStatus(
                status: .failed(error.localizedDescription),
                publicIPAddress: nil,
                city: nil,
                countryCode: nil,
                isSystemProxyEnabled: Self.isSystemProxyEnabled()
            )
            snapshot = updated
        }
    }

    private func refreshLatency(generation: UInt64) async {
        defer {
            if isCurrentProbeGeneration(generation) {
                lastLatencyRefresh = Date()
                latencyTask = nil
            }
        }

        do {
            var request = URLRequest(url: latencyURL)
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 5

            let start = ProcessInfo.processInfo.systemUptime
            let (_, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<600).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start

            guard isCurrentProbeGeneration(generation), !Task.isCancelled else {
                return
            }

            var updated = snapshot
            updated.latency = TopBarNetworkLatencyStatus(
                status: .ready,
                milliseconds: max(1, Int((elapsed * 1_000).rounded()))
            )
            snapshot = updated
        } catch {
            guard !Self.isCancellationError(error),
                  isCurrentProbeGeneration(generation),
                  !Task.isCancelled else {
                return
            }

            var updated = snapshot
            updated.latency = TopBarNetworkLatencyStatus(
                status: .failed(error.localizedDescription),
                milliseconds: nil
            )
            snapshot = updated
        }
    }

    private func isCurrentProbeGeneration(_ generation: UInt64) -> Bool {
        generation == probeGeneration
    }

    nonisolated private static func currentInterfaceCounters() -> InterfaceCounters {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return InterfaceCounters(bytesIn: 0, bytesOut: 0)
        }
        defer { freeifaddrs(firstInterface) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let pointer = current {
            let interface = pointer.pointee
            current = interface.ifa_next

            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.ifa_data else {
                continue
            }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0 else {
                continue
            }

            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            bytesIn += UInt64(counters.ifi_ibytes)
            bytesOut += UInt64(counters.ifi_obytes)
        }

        return InterfaceCounters(bytesIn: bytesIn, bytesOut: bytesOut)
    }

    private static func isSystemProxyEnabled() -> Bool {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return false
        }

        let enabledKeys = [
            kSCPropNetProxiesHTTPEnable,
            kSCPropNetProxiesHTTPSEnable,
            kSCPropNetProxiesSOCKSEnable,
            kSCPropNetProxiesProxyAutoConfigEnable,
            kSCPropNetProxiesProxyAutoDiscoveryEnable
        ].map { $0 as String }

        return enabledKeys.contains { key in
            guard let number = proxies[key] as? NSNumber else { return false }
            return number.intValue != 0
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        guard let urlError = error as? URLError else {
            return false
        }
        return urlError.code == .cancelled
    }
}
