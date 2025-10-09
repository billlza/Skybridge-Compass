import Foundation
import Observation

@Observable
@MainActor
final class DashboardViewModel {
    var status: DeviceStatus = .placeholder
    var lastUpdated: Date = .now
    var remoteShell: RemoteShellSession = .init(endpoint: nil, isConnected: false, latency: nil, messages: [])
    var isActivityRunning: Bool = false
    var monitoringInterval: Duration = .seconds(3)

    private let statusService: DeviceStatusService
    private let shellService: RemoteShellService
    private let activityManager: DeviceStatusActivityManager
    private var monitoringTask: Task<Void, Never>?
    private var shellStreamTask: Task<Void, Never>?

    init(
        statusService: DeviceStatusService = .shared,
        shellService: RemoteShellService = .shared,
        activityManager: DeviceStatusActivityManager = .init()
    ) {
        self.statusService = statusService
        self.shellService = shellService
        self.activityManager = activityManager
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.statusService.statusStream(interval: monitoringInterval) {
                await MainActor.run {
                    self.status = status
                    self.lastUpdated = status.timestamp
                }
                await self.activityManager.startOrUpdate(with: status)
                await MainActor.run {
                    self.isActivityRunning = self.activityManager.isActive
                }
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func connectShell(endpoint: URL, token: String? = nil) async {
        do {
            let connection = try await shellService.connect(to: endpoint, token: token)
            remoteShell = connection.session
            shellStreamTask?.cancel()
            shellStreamTask = Task { [weak self] in
                guard let self else { return }
                for await message in connection.messages {
                    await MainActor.run {
                        self.remoteShell.messages.append(message)
                    }
                }
            }
        } catch {
            var messages = remoteShell.messages
            messages.append(.init(id: UUID(), role: .system, text: "连接失败: \(error.localizedDescription)", timestamp: .now))
            remoteShell = .init(endpoint: endpoint, isConnected: false, latency: nil, messages: messages)
        }
    }

    func disconnectShell() async {
        await shellService.disconnect()
        remoteShell = .init(endpoint: remoteShell.endpoint, isConnected: false, latency: nil, messages: remoteShell.messages)
        shellStreamTask?.cancel()
        shellStreamTask = nil
    }

    func sendCommand(_ command: String) async {
        guard !command.isEmpty else { return }
        remoteShell.messages.append(.init(id: UUID(), role: .user, text: command, timestamp: .now))
        do {
            try await shellService.send(command)
        } catch {
            remoteShell.messages.append(.init(id: UUID(), role: .system, text: "发送失败: \(error.localizedDescription)", timestamp: .now))
        }
    }

    func refreshOnce() async {
        let status = await statusService.captureStatus()
        self.status = status
        self.lastUpdated = status.timestamp
        await activityManager.startOrUpdate(with: status)
        self.isActivityRunning = activityManager.isActive
    }

    func stopActivity() async {
        await activityManager.end()
        isActivityRunning = false
    }

    func updateMonitoringInterval(seconds: Double) {
        monitoringInterval = .seconds(seconds)
        stopMonitoring()
        startMonitoring()
    }
}
