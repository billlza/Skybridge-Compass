import SwiftUI

/// 磁盘使用卡片 - 显示磁盘空间使用情况
/// 符合macOS设计规范，提供清晰的磁盘使用可视化
public struct DiskUsageCard: View {
    
 // MARK: - 属性
    
    let diskUsages: [DiskUsage]
    
 // 状态管理
    @State private var selectedDisk: DiskUsage?
    @State private var animateProgress = false
    
 // MARK: - 初始化
    
    public init(diskUsages: [DiskUsage]) {
        self.diskUsages = diskUsages
    }
    
 // MARK: - 视图主体
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
 // 标题
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundColor(.purple)
                    .font(.title2)
                
                Text(LocalizationManager.shared.localizedString("monitor.disk.title"))
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if diskUsages.count > 1 {
                    Text(String(format: LocalizationManager.shared.localizedString("monitor.disk.count"), diskUsages.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if diskUsages.isEmpty {
 // 空状态
                emptyStateView
            } else {
 // 磁盘列表
                VStack(spacing: 12) {
                    ForEach(diskUsages) { disk in
                        DiskUsageRow(
                            disk: disk,
                            isSelected: selectedDisk?.id == disk.id,
                            animateProgress: animateProgress
                        )
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                selectedDisk = selectedDisk?.id == disk.id ? nil : disk
                            }
                        }
                    }
                }
                
 // 详细信息
                if let selectedDisk = selectedDisk {
                    diskDetailsView(for: selectedDisk)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 0.5)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0)) {
                animateProgress = true
            }
        }
    }
    
 // MARK: - 空状态视图
    
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            
            Text(LocalizationManager.shared.localizedString("monitor.disk.empty"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(height: 80)
        .frame(maxWidth: .infinity)
    }
    
 // MARK: - 磁盘详细信息视图
    
    private func diskDetailsView(for disk: DiskUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            
            Text(String(format: LocalizationManager.shared.localizedString("monitor.disk.details"), disk.name))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            VStack(spacing: 8) {
 // 总容量
                HStack {
                    Text(LocalizationManager.shared.localizedString("monitor.disk.total"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(formatBytes(disk.totalSpace))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
                
 // 已使用
                HStack {
                    Text(LocalizationManager.shared.localizedString("monitor.disk.used"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(formatBytes(disk.usedSpace))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(usageColor(for: disk.usagePercentage))
                }
                
 // 可用空间
                HStack {
                    Text(LocalizationManager.shared.localizedString("monitor.disk.free"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(formatBytes(disk.freeSpace))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                }
                
 // 使用率
                HStack {
                    Text(LocalizationManager.shared.localizedString("monitor.disk.usage"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(disk.usagePercentage, specifier: "%.1f")%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(usageColor(for: disk.usagePercentage))
                }
            }
        }
        .padding(.top, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    
 // MARK: - 私有方法
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        
        return formatter.string(fromByteCount: bytes)
    }
    
    private func usageColor(for percentage: Double) -> Color {
        if percentage >= 90 {
            return .red
        } else if percentage >= 80 {
            return .orange
        } else if percentage >= 70 {
            return .yellow
        } else {
            return .green
        }
    }
}

// MARK: - 磁盘使用行组件

private struct DiskUsageRow: View {
    let disk: DiskUsage
    let isSelected: Bool
    let animateProgress: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
 // 磁盘名称和使用率
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: diskIcon)
                        .foregroundColor(.purple)
                        .font(.subheadline)
                    
                    Text(disk.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                Text("\(disk.usagePercentage, specifier: "%.1f")%")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(usageColor)
            }
            
 // 进度条
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
 // 背景
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(height: 6)
                    
 // 进度
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [usageColor.opacity(0.8), usageColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: animateProgress ? geometry.size.width * (disk.usagePercentage / 100.0) : 0,
                            height: 6
                        )
                        .animation(.easeInOut(duration: 1.0).delay(0.2), value: animateProgress)
                }
            }
            .frame(height: 6)
            
 // 空间信息
            HStack {
                Text(formatBytes(disk.usedSpace))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("已使用")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(formatBytes(disk.freeSpace))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("可用")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
        )
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
    
    private var diskIcon: String {
        if disk.name.lowercased().contains("macintosh") || disk.name.lowercased().contains("system") {
            return "internaldrive"
        } else if disk.name.lowercased().contains("external") || disk.name.lowercased().contains("usb") {
            return "externaldrive"
        } else {
            return "internaldrive"
        }
    }
    
    private var usageColor: Color {
        if disk.usagePercentage >= 90 {
            return .red
        } else if disk.usagePercentage >= 80 {
            return .orange
        } else if disk.usagePercentage >= 70 {
            return .yellow
        } else {
            return .green
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - 磁盘使用情况结构（本地定义）

// 注意：此结构已被移除，现在使用 SystemMonitorManager.DiskUsage

// MARK: - 预览

struct DiskUsageCard_Previews: PreviewProvider {
    static var previews: some View {
 // 多个磁盘
        let sampleDisks = [
            DiskUsage(
                name: "Macintosh HD",
                totalSpace: 1024 * 1024 * 1024 * 500, // 500 GB
                usedSpace: 1024 * 1024 * 1024 * 350, // 350 GB
                freeSpace: 1024 * 1024 * 1024 * 150, // 150 GB
                usagePercentage: 70.0
            ),
            DiskUsage(
                name: "External Drive",
                totalSpace: 1024 * 1024 * 1024 * 1000, // 1 TB
                usedSpace: 1024 * 1024 * 1024 * 900, // 900 GB
                freeSpace: 1024 * 1024 * 1024 * 100, // 100 GB
                usagePercentage: 90.0
            )
        ]
        
        DiskUsageCard(diskUsages: sampleDisks)
            .frame(width: 400, height: 350)
            .padding()
            .previewDisplayName("多个磁盘")

 // 单个磁盘
        let singleDisk = [
            DiskUsage(
                name: "Macintosh HD",
                totalSpace: 1024 * 1024 * 1024 * 256, // 256 GB
                usedSpace: 1024 * 1024 * 1024 * 128, // 128 GB
                freeSpace: 1024 * 1024 * 1024 * 128, // 128 GB
                usagePercentage: 50.0
            )
        ]
        
        DiskUsageCard(diskUsages: singleDisk)
            .frame(width: 400, height: 250)
            .padding()
            .previewDisplayName("单个磁盘")

 // 空状态
        DiskUsageCard(diskUsages: [])
            .frame(width: 400, height: 200)
            .padding()
            .previewDisplayName("空状态")
    }
}
