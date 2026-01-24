import SwiftUI
import Combine

/// 统一设备列表视图
///
/// 功能：
/// 1. 显示所有发现的设备（网络 + USB）
/// 2. 智能合并同一设备的多种连接方式
/// 3. 显示连接方式标签
/// 4. 支持设备筛选和搜索
@available(macOS 14.0, *)
public struct UnifiedDeviceListView: View {

 // MARK: - 状态管理

    @StateObject private var discoveryManager = UnifiedDeviceDiscoveryManager()
    @State private var searchText = ""
    @State private var selectedDevice: UnifiedDevice?
    @State private var showingDeviceDetail = false
    @State private var filterConnectionType: DeviceConnectionType? = nil

    public init() {}

 // MARK: - 视图主体

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
 // 顶部工具栏
                topToolbar

                Divider()

 // 连接方式过滤器
                connectionTypeFilter

 // 设备列表
                deviceList
            }
            .navigationTitle("设备发现")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    toolbarButtons
                }
            }
        }
        .onAppear {
            discoveryManager.startScanning()
        }
        // UX fix: keep discovery running; stopping on view transitions causes disruptive stop/start loops
        // and can break ongoing handshakes/transfers.
        .sheet(isPresented: $showingDeviceDetail) {
            if let device = selectedDevice {
                UnifiedDeviceDetailView(device: device)
            }
        }
    }

 // MARK: - 子视图

 /// 顶部工具栏
    private var topToolbar: some View {
        HStack {
 // 扫描状态
            HStack(spacing: 8) {
                if discoveryManager.isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Text(discoveryManager.scanProgress.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("就绪")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

 // 设备统计
            HStack(spacing: 16) {
                statisticsBadge(
                    title: "总设备",
                    count: filteredDevices.count,
                    color: .blue
                )

                statisticsBadge(
                    title: "多连接",
                    count: filteredDevices.filter { $0.hasMultipleConnections }.count,
                    color: .purple
                )
            }

            Spacer()

 // 搜索框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索设备...", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 200)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

 /// 连接方式过滤器
    private var connectionTypeFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
 // "全部" 按钮
                FilterButton(
                    title: "全部",
                    icon: "circle.grid.2x2",
                    count: discoveryManager.unifiedDevices.count,
                    isSelected: filterConnectionType == nil,
                    action: {
                        filterConnectionType = nil
                    }
                )

 // 各种连接方式过滤
                ForEach(DeviceConnectionType.allCases.filter { $0 != .unknown }, id: \.self) { type in
                    let count = devicesCount(for: type)
                    if count > 0 {
                        FilterButton(
                            title: type.rawValue,
                            icon: type.iconName,
                            count: count,
                            isSelected: filterConnectionType == type,
                            action: {
                                filterConnectionType = type
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

 /// 设备列表
    private var deviceList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if filteredDevices.isEmpty {
                    emptyStateView
                } else {
                    ForEach(filteredDevices) { device in
                        UnifiedDeviceCard(device: device) {
                            selectedDevice = device
                            showingDeviceDetail = true
                        }
                    }
                }
            }
            .padding(20)
        }
    }

 /// 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: discoveryManager.isScanning ? "wifi.router" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(discoveryManager.isScanning ? "正在扫描..." : "未发现设备")
                .font(.title2)
                .fontWeight(.medium)

            if !discoveryManager.isScanning {
                Button("开始扫描") {
                    discoveryManager.startScanning()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

 /// 工具栏按钮
    private var toolbarButtons: some View {
        Group {
            Button(action: {
                discoveryManager.refreshDevices()
            }) {
                Label("刷新", systemImage: "arrow.clockwise")
            }

            if discoveryManager.isScanning {
                Button(action: {
                    discoveryManager.stopScanning()
                }) {
                    Label("停止", systemImage: "stop.circle")
                }
            } else {
                Button(action: {
                    discoveryManager.startScanning()
                }) {
                    Label("扫描", systemImage: "play.circle")
                }
            }
        }
    }

 // MARK: - 辅助方法

 /// 过滤后的设备列表
    private var filteredDevices: [UnifiedDevice] {
        var devices = discoveryManager.unifiedDevices

 // 按连接方式过滤
        if let filterType = filterConnectionType {
            devices = devices.filter { $0.connectionTypes.contains(filterType) }
        }

 // 按搜索文本过滤
        if !searchText.isEmpty {
            devices = devices.filter { device in
                device.name.localizedCaseInsensitiveContains(searchText) ||
                device.ipv4?.contains(searchText) == true ||
                device.serialNumber?.localizedCaseInsensitiveContains(searchText) == true
            }
        }

        return devices
    }

 /// 统计指定连接方式的设备数量
    private func devicesCount(for type: DeviceConnectionType) -> Int {
        return discoveryManager.unifiedDevices.filter { $0.connectionTypes.contains(type) }.count
    }

 /// 统计标签
    private func statisticsBadge(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("\(count)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15))
                .cornerRadius(4)
        }
    }
}

/// 过滤按钮
@available(macOS 14.0, *)
struct FilterButton: View {
    let title: String
    let icon: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))

                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)

                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.3))
                        .cornerRadius(3)
                }
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.blue : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 统一设备卡片
@available(macOS 14.0, *)
struct UnifiedDeviceCard: View {
    let device: UnifiedDevice
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
 // 设备图标
                deviceIcon

 // 设备信息
                VStack(alignment: .leading, spacing: 6) {
 // 设备名称
                    Text(device.name)
                        .font(.headline)
                        .foregroundColor(.primary)

 // IP地址和序列号
                    HStack(spacing: 8) {
                        if let ipv4 = device.ipv4 {
                            Label(ipv4, systemImage: "network")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let serial = device.serialNumber {
                            Label(serial, systemImage: "number")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

 // 连接方式标签
                    MultiConnectionTypeBadge(
                        connectionTypes: device.connectionTypes,
                        size: .small,
                        maxDisplay: 3
                    )
                }

                Spacer()

 // 设备类型和状态
                VStack(alignment: .trailing, spacing: 6) {
 // 设备类型标签
                    if device.deviceType != .unknown {
                        Text(deviceTypeDisplayName(device.deviceType))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(deviceTypeColor(device.deviceType).opacity(0.15))
                            .foregroundColor(deviceTypeColor(device.deviceType))
                            .cornerRadius(4)
                    }

 // 多连接标识
                    if device.hasMultipleConnections {
                        HStack(spacing: 4) {
                            Image(systemName: "link.circle.fill")
                                .font(.caption2)
                            Text("多连接")
                                .font(.caption2)
                        }
                        .foregroundColor(.purple)
                    }

 // 最后发现时间
                    Text(timeAgoText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

 // MARK: - 私有属性

    private var deviceIcon: some View {
        Image(systemName: device.deviceType.icon)
            .font(.system(size: 28))
            .foregroundColor(deviceTypeColor(device.deviceType))
            .frame(width: 50, height: 50)
            .background(deviceTypeColor(device.deviceType).opacity(0.1))
            .cornerRadius(10)
    }

    private var timeAgoText: String {
        let interval = Date().timeIntervalSince(device.lastSeen)
        if interval < 5 {
            return "刚刚"
        } else if interval < 60 {
            return "\(Int(interval))秒前"
        } else if interval < 3600 {
            return "\(Int(interval / 60))分钟前"
        } else {
            return "\(Int(interval / 3600))小时前"
        }
    }

    private func deviceTypeDisplayName(_ type: DeviceClassifier.DeviceType) -> String {
        switch type {
        case .computer: return "计算机"
        case .camera: return "摄像头"
        case .router: return "路由器"
        case .printer: return "打印机"
        case .speaker: return "音响"
        case .tv: return "电视"
        case .nas: return "存储"
        case .iot: return "物联网"
        case .unknown: return "未知"
        }
    }

    private func deviceTypeColor(_ type: DeviceClassifier.DeviceType) -> Color {
        switch type {
        case .computer: return .blue
        case .camera: return .red
        case .router: return .orange
        case .printer: return .purple
        case .speaker: return .green
        case .tv: return .indigo
        case .nas: return .cyan
        case .iot: return .yellow
        case .unknown: return .gray
        }
    }
}

/// 统一设备详情视图
@available(macOS 14.0, *)
struct UnifiedDeviceDetailView: View {
    let device: UnifiedDevice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
 // 设备基本信息
                    deviceBasicInfo

                    Divider()

 // 连接方式详情
                    connectionTypesSection

                    Divider()

 // 网络信息
                    networkInfoSection

                    Divider()

 // 可用服务
                    if !device.services.isEmpty {
                        servicesSection
                    }
                }
                .padding(24)
            }
            .navigationTitle("设备详情")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var deviceBasicInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("基本信息")
                .font(.title3)
                .fontWeight(.semibold)

            infoRow(label: "设备名称", value: device.name)
            infoRow(label: "设备类型", value: deviceTypeDisplayName(device.deviceType))

            if let serial = device.serialNumber {
                infoRow(label: "序列号", value: serial)
            }

            infoRow(label: "发现时间", value: formatDate(device.discoveredAt))
            infoRow(label: "最后发现", value: formatDate(device.lastSeen))
        }
    }

    private var connectionTypesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接方式")
                .font(.title3)
                .fontWeight(.semibold)

            FlowLayout(spacing: 8) {
                ForEach(Array(device.connectionTypes), id: \.self) { type in
                    ConnectionTypeBadge(connectionType: type, size: .large)
                }
            }

            if device.hasMultipleConnections {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("此设备支持多种连接方式，可根据场景选择最佳连接")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }

    private var networkInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("网络信息")
                .font(.title3)
                .fontWeight(.semibold)

            if let ipv4 = device.ipv4 {
                infoRow(label: "IPv4 地址", value: ipv4)
            }

            if let ipv6 = device.ipv6 {
                infoRow(label: "IPv6 地址", value: ipv6)
            }

            if device.ipv4 == nil && device.ipv6 == nil {
                Text("无网络地址信息")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("可用服务")
                .font(.title3)
                .fontWeight(.semibold)

            ForEach(device.services, id: \.self) { service in
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundColor(.green)

                    Text(service)
                        .font(.body)

                    Spacer()

                    if let port = device.portMap[service] {
                        Text(":\(port)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label + ":")
                .font(.body)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func deviceTypeDisplayName(_ type: DeviceClassifier.DeviceType) -> String {
        switch type {
        case .computer: return "计算机"
        case .camera: return "摄像头"
        case .router: return "路由器"
        case .printer: return "打印机"
        case .speaker: return "音响"
        case .tv: return "电视"
        case .nas: return "存储设备"
        case .iot: return "物联网设备"
        case .unknown: return "未知设备"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// 流式布局（用于自适应排列标签）
@available(macOS 14.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for size in sizes {
            if lineWidth + size.width > proposal.width ?? 0 {
                totalHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }

            totalWidth = max(totalWidth, lineWidth)
        }

        totalHeight += lineHeight

        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        var lineX = bounds.minX
        var lineY = bounds.minY
        var lineHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]

            if lineX + size.width > bounds.maxX {
                lineY += lineHeight + spacing
                lineHeight = 0
                lineX = bounds.minX
            }

            subview.place(
                at: CGPoint(x: lineX, y: lineY),
                proposal: ProposedViewSize(size)
            )

            lineHeight = max(lineHeight, size.height)
            lineX += size.width + spacing
        }
    }
}

// MARK: - 预览

#if DEBUG
@available(macOS 14.0, *)
struct UnifiedDeviceListView_Previews: PreviewProvider {
    static var previews: some View {
        UnifiedDeviceListView()
            .frame(width: 800, height: 600)
    }
}
#endif

