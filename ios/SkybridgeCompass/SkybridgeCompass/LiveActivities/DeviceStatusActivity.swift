import ActivityKit
import Foundation
import os.log

struct DeviceStatusActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        var deviceName: String
        var cpuUsage: Double
        var memoryUsage: Double
        var batteryLevel: Double
        var statusText: String
    }

    var systemName: String
}

@MainActor
final class DeviceStatusActivityManager: Sendable {
    private var activity: Activity<DeviceStatusActivityAttributes>?

    var isActive: Bool {
        activity != nil
    }

    func startOrUpdate(with status: DeviceStatus) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let contentState = DeviceStatusActivityAttributes.ContentState(
            deviceName: status.summary.deviceName,
            cpuUsage: status.cpu.usage,
            memoryUsage: status.memory.usageFraction,
            batteryLevel: status.battery.level,
            statusText: "CPU \(Int(status.cpu.usage * 100))% | 内存 \(Int(status.memory.usageFraction * 100))% | 电量 \(Int(status.battery.level * 100))%"
        )
        if let activity {
            await activity.update(ActivityContent(state: contentState, staleDate: .now.advanced(by: 60)))
        } else {
            let attributes = DeviceStatusActivityAttributes(systemName: status.summary.systemName)
            do {
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: contentState, staleDate: .now.advanced(by: 60)),
                    pushType: nil
                )
            } catch {
                os_log("Unable to start activity: %{public}@", log: .default, type: .error, error.localizedDescription)
            }
        }
    }

    func end() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
