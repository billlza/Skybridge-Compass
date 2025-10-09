import SwiftUI
import WidgetKit
import UIKit

struct DeviceStatusProvider: TimelineProvider {
    let store = DeviceStatusStore()

    func placeholder(in context: Context) -> DeviceStatusSnapshot {
        DeviceStatusSnapshot(date: .now, status: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (DeviceStatusSnapshot) -> Void) {
        completion(store.latestSnapshot())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DeviceStatusSnapshot>) -> Void) {
        let entry = store.latestSnapshot()
        let nextUpdate = Date.now.addingTimeInterval(60)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

struct DeviceStatusWidgetEntryView: View {
    var entry: DeviceStatusProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("云桥司南")
                .font(.headline)
            Text(entry.status.summary.deviceName)
                .font(.subheadline)
            HStack {
                VStack(alignment: .leading) {
                    Label("CPU", systemImage: "cpu")
                    Text("\(Int(entry.status.cpu.usage * 100))% · \(entry.status.cpu.formattedFrequency)")
                        .font(.caption)
                }
                Spacer()
                VStack(alignment: .leading) {
                    Label("内存", systemImage: "memorychip")
                    Text("\(Int(entry.status.memory.usageFraction * 100))%")
                        .font(.caption)
                }
            }
            HStack {
                Label("电量 \(Int(entry.status.battery.level * 100))%", systemImage: "battery.100")
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .containerBackground(for: .widget) {
            if #available(iOS 18.0, *) {
                Color.clear
                    .glassBackgroundEffect()
            } else {
                Color(UIColor.secondarySystemBackground)
            }
        }
    }
}

struct DeviceStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SkybridgeCompassWidget", provider: DeviceStatusProvider()) { entry in
            DeviceStatusWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Skybridge Compass")
        .description("实时掌握 CPU、内存和电池指标。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
