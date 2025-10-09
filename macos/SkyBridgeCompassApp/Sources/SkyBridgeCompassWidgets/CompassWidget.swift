import WidgetKit
import SwiftUI
import Combine
import SkyBridgeCore

struct CompassWidgetEntry: TimelineEntry {
    let date: Date
    let deviceCount: Int
    let sessionCount: Int
    let transferCount: Int
    let status: String
}

struct CompassWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CompassWidgetEntry {
        CompassWidgetEntry(date: Date(), deviceCount: 0, sessionCount: 0, transferCount: 0, status: "扫描中")
    }

    func getSnapshot(in context: Context, completion: @escaping (CompassWidgetEntry) -> Void) {
        Task {
            let entry = await loadEntry()
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CompassWidgetEntry>) -> Void) {
        Task {
            let entry = await loadEntry()
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func loadEntry() async -> CompassWidgetEntry {
        let discovery = DeviceDiscoveryService()
        await discovery.start()

        var latest = DiscoveryState(devices: [], statusDescription: "扫描中")
        var cancellable: AnyCancellable?
        let semaphore = DispatchSemaphore(value: 0)

        cancellable = discovery.discoveryState
            .receive(on: DispatchQueue.global())
            .sink { state in
                latest = state
                if !state.devices.isEmpty {
                    semaphore.signal()
                }
            }

        _ = semaphore.wait(timeout: .now() + 3)
        cancellable?.cancel()
        discovery.stop()

        let sessionCount = latest.devices.filter { device in
            device.services.contains { $0.localizedCaseInsensitiveContains("rdp") || $0.localizedCaseInsensitiveContains("rfb") }
        }.count

        let transferCount = latest.devices.filter { device in
            device.services.contains { $0.localizedCaseInsensitiveContains("skybridge") }
        }.count

        return CompassWidgetEntry(
            date: Date(),
            deviceCount: latest.devices.count,
            sessionCount: sessionCount,
            transferCount: transferCount,
            status: latest.statusDescription
        )
    }
}

struct CompassWidgetView: View {
    var entry: CompassWidgetProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("云桥司南")
                .font(.title3.weight(.bold))
            Text(entry.status)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                widgetMetric(title: "设备", value: entry.deviceCount)
                widgetMetric(title: "会话", value: entry.sessionCount)
                widgetMetric(title: "传输", value: entry.transferCount)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func widgetMetric(title: String, value: Int) -> some View {
        VStack {
            Text("\(value)")
                .font(.title2.monospacedDigit())
            Text(title)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

@main
struct SkyBridgeCompassWidgetBundle: WidgetBundle {
    var body: some Widget {
        SkyBridgeCompassWidget()
    }
}

struct SkyBridgeCompassWidget: Widget {
    let kind: String = "SkyBridgeCompassWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CompassWidgetProvider()) { entry in
            CompassWidgetView(entry: entry)
        }
        .configurationDisplayName("云桥司南状态")
        .description("快速查看真实设备和远程会话摘要")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
