import WidgetKit
import SwiftUI

/// SkyBridge Compass Widget - 显示在线设备和连接状态
@available(iOS 17.0, *)
struct SkyBridgeWidget: Widget {
    let kind: String = "SkyBridgeWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SkyBridgeWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("SkyBridge 状态")
        .description("显示在线设备和连接状态")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), deviceCount: 2, isConnected: true)
    }
    
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        let entry = SimpleEntry(date: Date(), deviceCount: 2, isConnected: true)
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        var entries: [SimpleEntry] = []
        
        let currentDate = Date()
        for hourOffset in 0..<5 {
            let entryDate = Calendar.current.date(byAdding: .hour, value: hourOffset, to: currentDate)!
            let entry = SimpleEntry(date: entryDate, deviceCount: Int.random(in: 0...5), isConnected: Bool.random())
            entries.append(entry)
        }
        
        let timeline = Timeline(entries: entries, policy: .atEnd)
        completion(timeline)
    }
}

// MARK: - Timeline Entry

struct SimpleEntry: TimelineEntry {
    let date: Date
    let deviceCount: Int
    let isConnected: Bool
}

// MARK: - Widget View

@available(iOS 17.0, *)
struct SkyBridgeWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Small Widget

struct SmallWidgetView: View {
    let entry: SimpleEntry
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue.gradient)
            
            Text("\(entry.deviceCount)")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(.primary)
            
            Text("在线设备")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Medium Widget

struct MediumWidgetView: View {
    let entry: SimpleEntry
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "wifi.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue.gradient)
                    
                    Text("SkyBridge")
                        .font(.headline)
                }
                
                Spacer()
                
                HStack(spacing: 4) {
                    Text("\(entry.deviceCount)")
                        .font(.system(size: 32, weight: .bold))
                    
                    Text("设备在线")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(entry.isConnected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    
                    Text(entry.isConnected ? "已连接" : "未连接")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - Large Widget

struct LargeWidgetView: View {
    let entry: SimpleEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "wifi.circle.fill")
                    .font(.title)
                    .foregroundStyle(.blue.gradient)
                
                Text("SkyBridge Compass")
                    .font(.headline)
                
                Spacer()
            }
            
            Divider()
            
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("在线设备")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("\(entry.deviceCount)")
                        .font(.system(size: 36, weight: .bold))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接状态")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Circle()
                            .fill(entry.isConnected ? Color.green : Color.gray)
                            .frame(width: 12, height: 12)
                        
                        Text(entry.isConnected ? "已连接" : "未连接")
                            .font(.body.bold())
                    }
                }
            }
            
            Spacer()
            
            Text("点击打开应用查看详情")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    SkyBridgeWidget()
} timeline: {
    SimpleEntry(date: .now, deviceCount: 3, isConnected: true)
    SimpleEntry(date: .now, deviceCount: 1, isConnected: false)
}

#Preview(as: .systemMedium) {
    SkyBridgeWidget()
} timeline: {
    SimpleEntry(date: .now, deviceCount: 3, isConnected: true)
}

#Preview(as: .systemLarge) {
    SkyBridgeWidget()
} timeline: {
    SimpleEntry(date: .now, deviceCount: 5, isConnected: true)
}
