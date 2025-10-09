import Foundation
import Combine
import AppKit
import Network
import os.log
import OrderedCollections
import FreeRDPBridge
import IOKit

public enum RemoteDesktopError: Error, LocalizedError {
    case missingAddress(DiscoveredDevice)
    case missingPort(DiscoveredDevice)
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAddress(let device):
            return "设备 \(device.name) 缺少有效的网络地址"
        case .missingPort(let device):
            return "设备 \(device.name) 未公开可用的远程桌面端口"
        case .connectionFailed(let message):
            return "远程桌面连接失败: \(message)"
        }
    }
}

@available(macOSApplicationExtension, unavailable)
public final class RemoteDesktopManager {
    private let sessionsSubject = CurrentValueSubject<[RemoteSessionSummary], Never>([])
    private let metricsSubject = CurrentValueSubject<RemoteMetricsSnapshot, Never>(.init(onlineDevices: 0, activeSessions: 0, transferCount: 0, alertCount: 0, cpuTimeline: [:]))
    private let log = Logger(subsystem: "com.skybridge.compass", category: "RemoteDesktop")
    private var monitoringTimer: Timer?
    private var cpuTimeline = OrderedDictionary<Date, Double>()
    private var activeSessions: [UUID: RemoteDesktopSession] = [:]
    private let sessionQueue = DispatchQueue(label: "com.skybridge.compass.remote.sessions", attributes: .concurrent)
    private let tenantController = TenantAccessController.shared

    public init() {}

    public var sessions: AnyPublisher<[RemoteSessionSummary], Never> { sessionsSubject.eraseToAnyPublisher() }
    public var metrics: AnyPublisher<RemoteMetricsSnapshot, Never> { metricsSubject.eraseToAnyPublisher() }

    public func bootstrap() {
        startResourceMonitoring()
    }

    public func shutdown() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        sessionQueue.async(flags: .barrier) {
            self.activeSessions.values.forEach { $0.stop() }
            self.activeSessions.removeAll()
        }
        cpuTimeline.removeAll()
        sessionsSubject.send([])
        metricsSubject.send(.init(onlineDevices: 0, activeSessions: 0, transferCount: 0, alertCount: 0, cpuTimeline: [:]))
    }

    public func connect(to device: DiscoveredDevice, tenant: TenantDescriptor) async throws {
        let credentials = try tenantController.credentials(for: tenant.id)
        guard let host = device.ipv4 ?? device.ipv6 else {
            throw RemoteDesktopError.missingAddress(device)
        }
        guard let port = resolvePort(for: device), port <= Int(UInt16.max) else {
            throw RemoteDesktopError.missingPort(device)
        }

        let session = RemoteDesktopSession(device: device, tenant: tenant, credentials: credentials, host: host, port: port, renderer: RemoteFrameRenderer()) { [weak self] in
            self?.updateSessionsSnapshot()
        } stateChanged: { [weak self] in
            self?.refreshMetrics()
        }

        sessionQueue.async(flags: .barrier) {
            self.activeSessions[session.id] = session
        }
        updateSessionsSnapshot()

        do {
            try await session.start()
            refreshMetrics()
        } catch {
            sessionQueue.async(flags: .barrier) {
                self.activeSessions.removeValue(forKey: session.id)
            }
            updateSessionsSnapshot()
            throw error
        }
    }

    @available(*, deprecated, message: "Use tenant-specific connect")
    public func connect(to device: DiscoveredDevice) async throws {
        let tenant = try tenantController.requirePermission(.remoteDesktop)
        try await connect(to: device, tenant: tenant)
    }

    public func focus(on sessionID: UUID) {
        sessionQueue.async {
            self.activeSessions[sessionID]?.focus()
        }
    }

    public func terminate(sessionID: UUID) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async(flags: .barrier) {
                if let session = self.activeSessions.removeValue(forKey: sessionID) {
                    session.stop()
                }
                DispatchQueue.main.async {
                    self.updateSessionsSnapshot()
                    self.refreshMetrics()
                    continuation.resume()
                }
            }
        }
    }

    private func updateSessionsSnapshot() {
        let summaries = sessionQueue.sync { Array(self.activeSessions.values.map { $0.summary }) }
        sessionsSubject.send(summaries)
    }

    private func refreshMetrics(cpuLoad: Double? = nil) {
        if let cpuLoad {
            cpuTimeline[Date()] = cpuLoad
            while cpuTimeline.count > 30 {
                cpuTimeline.removeFirst()
            }
        }
        let sessionStates = sessionQueue.sync { Array(self.activeSessions.values) }
        let activeCount = sessionStates.filter { $0.clientState == .connected }.count
        let alertCount = sessionStates.filter { $0.clientState == .failed }.count
        let snapshot = RemoteMetricsSnapshot(
            onlineDevices: sessionStates.count,
            activeSessions: activeCount,
            transferCount: 0,
            alertCount: alertCount,
            cpuTimeline: cpuTimeline
        )
        metricsSubject.send(snapshot)
    }

    private func startResourceMonitoring() {
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let cpuLoad = self.fetchCpuLoad()
            self.refreshMetrics(cpuLoad: cpuLoad)
        }
    }

    private func fetchCpuLoad() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: load) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let totalTicks = Double(load.cpu_ticks.0 + load.cpu_ticks.1 + load.cpu_ticks.2 + load.cpu_ticks.3)
        let idleTicks = Double(load.cpu_ticks.2)
        let usage = (totalTicks - idleTicks) / totalTicks
        return max(0, min(1, usage))
    }

    private func resolvePort(for device: DiscoveredDevice) -> Int? {
        if let rdp = device.portMap["_rdp._tcp."] { return rdp }
        if let vnc = device.portMap["_rfb._tcp."] { return vnc }
        return device.portMap.values.first
    }
}

private final class RemoteDesktopSession {
    let id = UUID()
    let device: DiscoveredDevice
    let tenant: TenantDescriptor
    private let credentials: TenantCredential
    private let renderer: RemoteFrameRenderer
    private let client: CBFreeRDPClient
    private let log = Logger(subsystem: "com.skybridge.compass", category: "RemoteSession")
    private let summaryChanged: () -> Void
    private let stateChanged: () -> Void

    private(set) var summary: RemoteSessionSummary
    private(set) var clientState: CBFreeRDPClientState = .idle

    init(device: DiscoveredDevice,
         tenant: TenantDescriptor,
         credentials: TenantCredential,
         host: String,
         port: Int,
         renderer: RemoteFrameRenderer,
         summaryChanged: @escaping () -> Void,
         stateChanged: @escaping () -> Void) {
        self.device = device
        self.tenant = tenant
        self.credentials = credentials
        self.renderer = renderer
        self.summaryChanged = summaryChanged
        self.stateChanged = stateChanged
        self.summary = RemoteSessionSummary(
            id: id,
            targetName: device.name,
            protocolDescription: device.services.first ?? "RDP",
            bandwidthMbps: 0,
            frameLatencyMilliseconds: 0
        )
        self.client = CBFreeRDPClient(
            host: host,
            port: UInt16(port),
            username: credentials.username,
            password: credentials.password,
            domain: credentials.domain
        )
        configureCallbacks()
    }

    func start() async throws {
        clientState = .connecting
        stateChanged()
        try await withCheckedThrowingContinuation { continuation in
            var error: NSError?
            if self.client.connectWithError(&error) {
                continuation.resume(returning: ())
            } else {
                self.clientState = .failed
                self.stateChanged()
                continuation.resume(throwing: error ?? RemoteDesktopError.connectionFailed("libfreerdp2.dylib 未连接"))
            }
        }
    }

    func stop() {
        renderer.teardown()
        client.disconnect()
    }

    func focus() {
        log.info("Focus requested for session %{public}@", device.name)
        CGDisplayMoveCursorToPoint(CGMainDisplayID(), CGPoint(x: 0, y: 0))
    }

    private func configureCallbacks() {
        client.frameCallback = { [weak self] data, width, height, stride, frameType in
            guard let self else { return }
            let metrics = self.renderer.processFrame(
                data: data as Data,
                width: Int(width),
                height: Int(height),
                stride: Int(stride),
                type: RemoteFrameType(rawValue: frameType.rawValue) ?? .bgra
            )
            self.summary = RemoteSessionSummary(
                id: self.summary.id,
                targetName: self.summary.targetName,
                protocolDescription: self.summary.protocolDescription,
                bandwidthMbps: metrics.bandwidthMbps,
                frameLatencyMilliseconds: metrics.latencyMilliseconds
            )
            self.summaryChanged()
        }

        client.stateCallback = { [weak self] description in
            guard let self else { return }
            self.log.info("Session state updated %{public}@", description)
            self.clientState = self.client.state
            self.stateChanged()
        }
    }
}
