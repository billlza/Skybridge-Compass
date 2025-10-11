import WidgetKit
import SwiftUI
import Combine
import SkyBridgeCore

// 在 Swift 6 并发严格发送性检查下，使用 @unchecked Sendable 封装闭包，
// 以安全地在并发任务中调用来自同步 API 的 completion 闭包。
private struct SendableClosure<T>: @unchecked Sendable {
    let call: (T) -> Void
    init(_ call: @escaping (T) -> Void) { self.call = call }
}

struct CompassWidgetEntry: TimelineEntry {
    let date: Date
    let deviceCount: Int
    let sessionCount: Int
    let transferCount: Int
    let status: String
}

/// SkyBridge Compass Widget提供器
/// 为macOS 14.0+系统提供小组件功能，展示设备发现和连接状态
@available(macOS 14.0, *)
struct CompassWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CompassWidgetEntry {
        CompassWidgetEntry(date: Date(), deviceCount: 0, sessionCount: 0, transferCount: 0, status: "扫描中")
    }

    func getSnapshot(in context: Context, completion: @escaping (CompassWidgetEntry) -> Void) {
        let complete = SendableClosure<CompassWidgetEntry>(completion)
        Task { @MainActor in
            let entry = await loadEntry()
            complete.call(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CompassWidgetEntry>) -> Void) {
        let complete = SendableClosure<Timeline<CompassWidgetEntry>>(completion)
        Task { @MainActor in
            let entry = await loadEntry()
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            complete.call(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func loadEntry() async -> CompassWidgetEntry {
        let discovery = DeviceDiscoveryService()
        await discovery.start()

        var latest = DiscoveryState(devices: [], statusDescription: "扫描中")
        var cancellable: AnyCancellable?

        cancellable = discovery.discoveryState
            .receive(on: DispatchQueue.global())
            .sink { state in
                latest = state
            }

        // 等待最多 3 秒以获取一次设备发现结果，避免在异步上下文中使用信号量。
        try? await Task.sleep(nanoseconds: 3_000_000_000)
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

/// SkyBridge Compass Widget视图
/// 为macOS 14.0+系统优化的小组件界面
@available(macOS 14.0, *)
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
@available(macOS 14.0, *)
struct SkyBridgeCompassWidgetBundle: WidgetBundle {
    var body: some Widget {
        SkyBridgeCompassWidget()
    }
}

@available(macOS 14.0, *)
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
