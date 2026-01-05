import WidgetKit
import SwiftUI
import SkyBridgeWidgetShared

// MARK: - Timeline Entry

struct CompassWidgetEntry: TimelineEntry {
    let date: Date
    let devicesData: WidgetDevicesData?
    let isPlaceholder: Bool
    
    static var placeholder: CompassWidgetEntry {
        CompassWidgetEntry(
            date: Date(),
            devicesData: nil,
            isPlaceholder: true
        )
    }
}

// MARK: - Timeline Provider

@available(macOS 14.0, *)
struct CompassWidgetProvider: TimelineProvider {
    private let reader = WidgetDataReaderService()
    
    func placeholder(in context: Context) -> CompassWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (CompassWidgetEntry) -> Void) {
        let entry = loadCurrentEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CompassWidgetEntry>) -> Void) {
        let entry = loadCurrentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    private func loadCurrentEntry() -> CompassWidgetEntry {
        let devicesData = reader.loadDevicesData()
        return CompassWidgetEntry(
            date: Date(),
            devicesData: devicesData,
            isPlaceholder: false
        )
    }
}

// MARK: - Widget Data Reader Service

final class WidgetDataReaderService {
    private let fileSystem: WidgetFileSystem
    private let decoder: JSONDecoder
    
 // 上次成功解码的缓存（decode 失败时返回）
    private var lastGoodDevicesData: WidgetDevicesData?
    
    init(fileSystem: WidgetFileSystem = RealFileSystem()) {
        self.fileSystem = fileSystem
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }
    
    func loadDevicesData() -> WidgetDevicesData? {
        guard let fileURL = widgetFileURL(for: WidgetDataLimits.devicesFileName) else {
            return lastGoodDevicesData
        }
        
        guard fileSystem.fileExists(at: fileURL) else {
            return lastGoodDevicesData
        }
        
        do {
            let data = try fileSystem.read(from: fileURL)
            let decoded = try decoder.decode(WidgetDevicesData.self, from: data)
            lastGoodDevicesData = decoded
            return decoded
        } catch {
 // decode 失败时返回上次成功的缓存
            return lastGoodDevicesData
        }
    }
}

// MARK: - Widget View

@available(macOS 14.0, *)
struct CompassWidgetView: View {
    var entry: CompassWidgetProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if entry.isPlaceholder {
            placeholderView
        } else if let data = entry.devicesData {
            contentView(data: data)
        } else {
            emptyStateView
        }
    }
    
    private var placeholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "network")
                .font(.largeTitle)
                .foregroundStyle(.blue)
            Text("--")
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("设备在线")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .redacted(reason: .placeholder)
    }
    
    private func contentView(data: WidgetDevicesData) -> some View {
        Group {
            switch family {
            case .systemSmall:
                smallDeviceContentView(data: data)
            case .systemMedium:
                mediumDeviceContentView(data: data)
            case .systemLarge:
                largeDeviceContentView(data: data)
            default:
                smallDeviceContentView(data: data)
            }
        }
    }
    
    private func smallDeviceContentView(data: WidgetDevicesData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("云桥司南")
                    .font(.title3.weight(.bold))
                Spacer()
                if data.isStale() {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            
            HStack {
                widgetMetric(
                    title: "设备",
                    value: data.devices.count,
                    icon: "desktopcomputer"
                )
                widgetMetric(
                    title: "在线",
                    value: data.onlineCount,
                    icon: "wifi",
                    color: .green
                )
            }
            
            if let truncation = data.truncationInfo, truncation.devicesOmitted > 0 {
                Text("+\(truncation.devicesOmitted) 更多")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://devices"))
    }
    
    private func mediumDeviceContentView(data: WidgetDevicesData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("云桥司南")
                    .font(.title3.weight(.bold))
                Spacer()
                if data.isStale() {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            
            HStack(spacing: 12) {
                widgetMetric(
                    title: "设备",
                    value: data.devices.count,
                    icon: "desktopcomputer"
                )
                widgetMetric(
                    title: "在线",
                    value: data.onlineCount,
                    icon: "wifi",
                    color: .green
                )
                
 // 快速操作按钮 (v2: AppIntent)
                Button(intent: ScanDevicesIntent()) {
                    VStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("扫描")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            
            if let truncation = data.truncationInfo, truncation.devicesOmitted > 0 {
                Text("+\(truncation.devicesOmitted) 更多")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://devices"))
    }
    
    private func largeDeviceContentView(data: WidgetDevicesData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("云桥司南")
                    .font(.title2.weight(.bold))
                Spacer()
                if data.isStale() {
                    Label("数据可能过期", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            
            HStack(spacing: 12) {
                widgetMetric(
                    title: "设备",
                    value: data.devices.count,
                    icon: "desktopcomputer"
                )
                widgetMetric(
                    title: "在线",
                    value: data.onlineCount,
                    icon: "wifi",
                    color: .green
                )
            }
            
            Divider()
            
 // 设备列表
            VStack(alignment: .leading, spacing: 8) {
                Text("设备列表")
                    .font(.headline)
                
                ForEach(data.devices.prefix(4)) { device in
                    deviceRowView(device: device)
                }
                
                if data.devices.count > 4 {
                    Text("+\(data.devices.count - 4) 更多")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
 // 快速操作按钮 (v2: AppIntent)
            HStack(spacing: 12) {
                ScanDevicesButton()
                OpenAppButton()
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://devices"))
    }
    
    private func deviceRowView(device: WidgetDeviceInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: deviceIcon(for: device.deviceType))
                .foregroundStyle(device.isOnline ? .green : .secondary)
            
            Text(device.name)
                .font(.subheadline)
                .lineLimit(1)
            
            Spacer()
            
            Circle()
                .fill(device.isOnline ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    private func deviceIcon(for type: WidgetDeviceType) -> String {
        switch type {
        case .mac: return "desktopcomputer"
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .windows: return "pc"
        case .android: return "smartphone"
        case .linux: return "server.rack"
        case .unknown: return "questionmark.circle"
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("无数据")
                .font(.headline)
            Text("打开应用以同步")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://"))
    }

    private func widgetMetric(title: String, value: Int, icon: String, color: Color = .primary) -> some View {
        VStack {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text("\(value)")
                    .font(.title2.monospacedDigit().weight(.semibold))
            }
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Widget Bundle

@main
@available(macOS 14.0, *)
struct SkyBridgeCompassWidgetBundle: WidgetBundle {
    var body: some Widget {
        SkyBridgeCompassWidget()
        SystemMonitorWidget()
        FileTransferWidget()
    }
}

@available(macOS 14.0, *)
struct SkyBridgeCompassWidget: Widget {
    let kind: String = "DeviceStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CompassWidgetProvider()) { entry in
            CompassWidgetView(entry: entry)
        }
        .configurationDisplayName("设备状态")
        .description("查看已连接设备的状态")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - System Monitor Widget

// MARK: Timeline Entry

struct SystemMonitorEntry: TimelineEntry {
    let date: Date
    let metricsData: WidgetMetricsData?
    let isPlaceholder: Bool
    
    static var placeholder: SystemMonitorEntry {
        SystemMonitorEntry(
            date: Date(),
            metricsData: nil,
            isPlaceholder: true
        )
    }
}

// MARK: Timeline Provider

@available(macOS 14.0, *)
struct SystemMonitorProvider: TimelineProvider {
    private let reader = WidgetDataReader.shared
    
    func placeholder(in context: Context) -> SystemMonitorEntry {
        .placeholder
    }
    
    func getSnapshot(in context: Context, completion: @escaping (SystemMonitorEntry) -> Void) {
        let entry = loadCurrentEntry()
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemMonitorEntry>) -> Void) {
        let entry = loadCurrentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    private func loadCurrentEntry() -> SystemMonitorEntry {
        let metricsData = reader.loadMetricsData()
        return SystemMonitorEntry(
            date: Date(),
            metricsData: metricsData,
            isPlaceholder: false
        )
    }
}

// MARK: Widget View

@available(macOS 14.0, *)
struct SystemMonitorWidgetView: View {
    var entry: SystemMonitorProvider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        if entry.isPlaceholder {
            placeholderView
        } else if let data = entry.metricsData {
            contentView(data: data)
        } else {
            emptyStateView
        }
    }
    
    private var placeholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.largeTitle)
                .foregroundStyle(.blue)
            Text("--")
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("系统监控")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .redacted(reason: .placeholder)
    }
    
    private func contentView(data: WidgetMetricsData) -> some View {
        Group {
            switch family {
            case .systemSmall:
                smallContentView(data: data)
            case .systemMedium:
                mediumContentView(data: data)
            case .systemLarge:
                largeContentView(data: data)
            default:
                smallContentView(data: data)
            }
        }
    }
    
    private func smallContentView(data: WidgetMetricsData) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("系统监控")
                    .font(.caption.weight(.semibold))
                Spacer()
                if data.isStale() {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                }
            }
            
            Spacer()
            
            VStack(spacing: 4) {
                metricsGauge(
                    value: data.metrics.cpuUsage,
                    label: "CPU",
                    icon: "cpu"
                )
                metricsGauge(
                    value: data.metrics.memoryUsage,
                    label: "内存",
                    icon: "memorychip"
                )
            }
            
            Spacer()
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://monitor"))
    }
    
    private func mediumContentView(data: WidgetMetricsData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("系统监控")
                    .font(.title3.weight(.bold))
                Spacer()
                if data.isStale() {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            
            HStack(spacing: 12) {
                metricsCard(
                    value: data.metrics.cpuUsage,
                    label: "CPU",
                    icon: "cpu"
                )
                metricsCard(
                    value: data.metrics.memoryUsage,
                    label: "内存",
                    icon: "memorychip"
                )
                networkCard(
                    upload: data.metrics.networkUpload,
                    download: data.metrics.networkDownload
                )
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://monitor"))
    }
    
    private func largeContentView(data: WidgetMetricsData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("系统监控")
                    .font(.title2.weight(.bold))
                Spacer()
                if data.isStale() {
                    Label("数据可能过期", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            
            HStack(spacing: 16) {
                largeMetricsCard(
                    value: data.metrics.cpuUsage,
                    label: "CPU 使用率",
                    icon: "cpu"
                )
                largeMetricsCard(
                    value: data.metrics.memoryUsage,
                    label: "内存使用率",
                    icon: "memorychip"
                )
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("网络流量")
                    .font(.headline)
                
                HStack(spacing: 16) {
                    networkStatView(
                        value: data.metrics.networkUpload,
                        label: "上传",
                        icon: "arrow.up.circle.fill",
                        color: .blue
                    )
                    networkStatView(
                        value: data.metrics.networkDownload,
                        label: "下载",
                        icon: "arrow.down.circle.fill",
                        color: .green
                    )
                }
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://monitor"))
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("无数据")
                .font(.headline)
            Text("打开应用以同步")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://monitor"))
    }
    
 // MARK: - Helper Views
    
    private func metricsGauge(value: Double, label: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(gaugeColor(for: value))
                .frame(width: 16)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(formatPercentage(value))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(gaugeColor(for: value))
        }
    }
    
    private func metricsCard(value: Double, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(gaugeColor(for: value))
            
            Text(formatPercentage(value))
                .font(.title3.monospacedDigit().weight(.bold))
            
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private func networkCard(upload: Double, download: Double) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "network")
                .font(.title2)
                .foregroundStyle(.blue)
            
            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(.caption2)
                Text(formatBytesPerSecond(upload))
                    .font(.caption2.monospacedDigit())
            }
            
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.caption2)
                Text(formatBytesPerSecond(download))
                    .font(.caption2.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private func largeMetricsCard(value: Double, label: String, icon: String) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(gaugeColor(for: value))
                Text(label)
                    .font(.subheadline)
                Spacer()
            }
            
            HStack {
                Text(formatPercentage(value))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(gaugeColor(for: value))
                Spacer()
            }
            
            ProgressView(value: value, total: 100)
                .tint(gaugeColor(for: value))
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    private func networkStatView(value: Double, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatBytesPerSecond(value))
                    .font(.headline.monospacedDigit())
            }
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
 // MARK: - Formatting Helpers
    
    private func formatPercentage(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
    
    private func formatBytesPerSecond(_ bytes: Double) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB/s", bytes / 1_000_000_000)
        } else if bytes >= 1_000_000 {
            return String(format: "%.1f MB/s", bytes / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.1f KB/s", bytes / 1_000)
        } else {
            return String(format: "%.0f B/s", bytes)
        }
    }
    
    private func gaugeColor(for value: Double) -> Color {
        if value >= 90 {
            return .red
        } else if value >= 70 {
            return .yellow
        } else {
            return .green
        }
    }
}

// MARK: Widget Configuration

@available(macOS 14.0, *)
struct SystemMonitorWidget: Widget {
    let kind: String = "SystemMonitorWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SystemMonitorProvider()) { entry in
            SystemMonitorWidgetView(entry: entry)
        }
        .configurationDisplayName("系统监控")
        .description("查看 CPU、内存和网络使用情况")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}


// MARK: - File Transfer Widget

// MARK: Timeline Entry

struct FileTransferEntry: TimelineEntry {
    let date: Date
    let transfersData: WidgetTransfersData?
    let isPlaceholder: Bool
    
    static var placeholder: FileTransferEntry {
        FileTransferEntry(
            date: Date(),
            transfersData: nil,
            isPlaceholder: true
        )
    }
}

// MARK: Timeline Provider

@available(macOS 14.0, *)
struct FileTransferProvider: TimelineProvider {
    private let reader = WidgetDataReader.shared
    
    func placeholder(in context: Context) -> FileTransferEntry {
        .placeholder
    }
    
    func getSnapshot(in context: Context, completion: @escaping (FileTransferEntry) -> Void) {
        let entry = loadCurrentEntry()
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<FileTransferEntry>) -> Void) {
        let entry = loadCurrentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    private func loadCurrentEntry() -> FileTransferEntry {
        let transfersData = reader.loadTransfersData()
        return FileTransferEntry(
            date: Date(),
            transfersData: transfersData,
            isPlaceholder: false
        )
    }
}

// MARK: Widget View

@available(macOS 14.0, *)
struct FileTransferWidgetView: View {
    var entry: FileTransferProvider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        if entry.isPlaceholder {
            placeholderView
        } else if let data = entry.transfersData, !data.transfers.isEmpty {
            contentView(data: data)
        } else {
            emptyStateView
        }
    }
    
    private var placeholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.largeTitle)
                .foregroundStyle(.blue)
            Text("--")
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("文件传输")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .redacted(reason: .placeholder)
    }
    
    private func contentView(data: WidgetTransfersData) -> some View {
        Group {
            switch family {
            case .systemSmall:
                smallContentView(data: data)
            case .systemMedium:
                mediumContentView(data: data)
            case .systemLarge:
                largeContentView(data: data)
            default:
                smallContentView(data: data)
            }
        }
    }
    
    private func smallContentView(data: WidgetTransfersData) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("文件传输")
                    .font(.caption.weight(.semibold))
                Spacer()
                if data.isStale() {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                }
            }
            
            Spacer()
            
            VStack(spacing: 4) {
                Text("\(data.activeCount)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(data.activeCount > 0 ? .blue : .secondary)
                
                Text("进行中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if data.activeCount > 0 {
                    ProgressView(value: data.aggregateProgress)
                        .tint(.blue)
                }
            }
            
            Spacer()
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://transfers"))
    }
    
    private func mediumContentView(data: WidgetTransfersData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文件传输")
                    .font(.title3.weight(.bold))
                Spacer()
                if data.isStale() {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            
            if data.activeCount > 0 {
                HStack(spacing: 12) {
                    transferSummaryCard(data: data)
                    
                    if let firstTransfer = data.transfers.first(where: { $0.isActive }) {
                        transferItemCard(transfer: firstTransfer)
                    }
                }
            } else {
                idleStateView(data: data)
            }
            
            if let truncation = data.truncationInfo, truncation.transfersOmitted > 0 {
                Text("+\(truncation.transfersOmitted) 更多")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://transfers"))
    }
    
    private func largeContentView(data: WidgetTransfersData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("文件传输")
                    .font(.title2.weight(.bold))
                Spacer()
                if data.isStale() {
                    Label("数据可能过期", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            
            if data.activeCount > 0 {
 // Summary
                HStack(spacing: 16) {
                    largeSummaryCard(
                        title: "进行中",
                        value: "\(data.activeCount)",
                        icon: "arrow.left.arrow.right.circle.fill",
                        color: .blue
                    )
                    largeSummaryCard(
                        title: "总进度",
                        value: String(format: "%.0f%%", data.aggregateProgress * 100),
                        icon: "chart.pie.fill",
                        color: .green
                    )
                }
                
                Divider()
                
 // Transfer list
                VStack(alignment: .leading, spacing: 8) {
                    Text("传输列表")
                        .font(.headline)
                    
                    ForEach(data.transfers.prefix(3)) { transfer in
                        transferRowView(transfer: transfer)
                    }
                    
                    if data.transfers.count > 3 {
                        Text("+\(data.transfers.count - 3) 更多")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                largeIdleStateView(data: data)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://transfers"))
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("无传输")
                .font(.headline)
            Text("暂无活跃传输")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "skybridge://transfers"))
    }
    
 // MARK: - Helper Views
    
    private func transferSummaryCard(data: WidgetTransfersData) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            
            Text("\(data.activeCount)")
                .font(.title3.monospacedDigit().weight(.bold))
            
            Text("进行中")
                .font(.caption2)
                .foregroundStyle(.secondary)
            
            ProgressView(value: data.aggregateProgress)
                .tint(.blue)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private func transferItemCard(transfer: WidgetTransferInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: transfer.isUpload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(transfer.isUpload ? .orange : .green)
                Text(transfer.fileName)
                    .font(.caption)
                    .lineLimit(1)
            }
            
            ProgressView(value: transfer.progress)
                .tint(transfer.isUpload ? .orange : .green)
            
            HStack {
                Text(transfer.deviceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.0f%%", transfer.progress * 100))
                    .font(.caption2.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private func idleStateView(data: WidgetTransfersData) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("无活跃传输")
                    .font(.subheadline.weight(.medium))
                Text("共 \(data.transfers.count) 个传输记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private func largeSummaryCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline)
                Spacer()
            }
            
            HStack {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Spacer()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    private func transferRowView(transfer: WidgetTransferInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(transfer.isUpload ? .orange : .green)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                
                HStack {
                    Text(transfer.deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("•")
                        .foregroundStyle(.secondary)
                    
                    Text(MetricsFormatter.formatBytes(Double(transfer.totalBytes)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f%%", transfer.progress * 100))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                
                if transfer.isActive {
                    ProgressView(value: transfer.progress)
                        .frame(width: 50)
                        .tint(transfer.isUpload ? .orange : .green)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private func largeIdleStateView(data: WidgetTransfersData) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            
            Text("无活跃传输")
                .font(.title3.weight(.medium))
            
            Text("共 \(data.transfers.count) 个传输记录")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: Widget Configuration

@available(macOS 14.0, *)
struct FileTransferWidget: Widget {
    let kind: String = "FileTransferWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FileTransferProvider()) { entry in
            FileTransferWidgetView(entry: entry)
        }
        .configurationDisplayName("文件传输")
        .description("查看文件传输进度")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
