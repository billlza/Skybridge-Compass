import SwiftUI

/// 连接方式标签组件
///
/// 用于显示设备的连接方式（Wi-Fi、有线、USB等）
/// 支持单个或多个连接方式的显示
@available(macOS 14.0, *)
public struct ConnectionTypeBadge: View {
    let connectionType: DeviceConnectionType
    let size: BadgeSize
    
    public enum BadgeSize {
        case small
        case medium
        case large
        
        var fontSize: CGFloat {
            switch self {
            case .small: return 10
            case .medium: return 12
            case .large: return 14
            }
        }
        
        var iconSize: CGFloat {
            switch self {
            case .small: return 10
            case .medium: return 12
            case .large: return 14
            }
        }
        
        var padding: EdgeInsets {
            switch self {
            case .small:
                return EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
            case .medium:
                return EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)
            case .large:
                return EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            }
        }
    }
    
    public init(connectionType: DeviceConnectionType, size: BadgeSize = .medium) {
        self.connectionType = connectionType
        self.size = size
    }
    
    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: connectionType.iconName)
                .font(.system(size: size.iconSize))
            
            Text(connectionType.rawValue)
                .font(.system(size: size.fontSize, weight: .medium))
        }
        .foregroundColor(badgeColor)
        .padding(size.padding)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(badgeColor.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(badgeColor.opacity(0.3), lineWidth: 0.5)
        )
    }
    
    private var badgeColor: Color {
        switch connectionType {
        case .wifi:
            return .blue
        case .ethernet:
            return .orange
        case .usb:
            return .green
        case .thunderbolt:
            return .purple
        case .bluetooth:
            return .cyan
        case .unknown:
            return .gray
        }
    }
}

/// 多连接方式标签组件
@available(macOS 14.0, *)
public struct MultiConnectionTypeBadge: View {
    let connectionTypes: Set<DeviceConnectionType>
    let size: ConnectionTypeBadge.BadgeSize
    let maxDisplay: Int
    
    public init(
        connectionTypes: Set<DeviceConnectionType>,
        size: ConnectionTypeBadge.BadgeSize = .medium,
        maxDisplay: Int = 3
    ) {
        self.connectionTypes = connectionTypes
        self.size = size
        self.maxDisplay = maxDisplay
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(sortedConnectionTypes.prefix(maxDisplay)), id: \.self) { type in
                ConnectionTypeBadge(connectionType: type, size: size)
            }
            
 // 如果连接方式超过显示上限，显示 "+N"
            if connectionTypes.count > maxDisplay {
                Text("+\(connectionTypes.count - maxDisplay)")
                    .font(.system(size: size.fontSize, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(size.padding)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.1))
                    )
            }
        }
    }
    
 /// 排序后的连接方式（按优先级）
    private var sortedConnectionTypes: [DeviceConnectionType] {
        let priority: [DeviceConnectionType] = [
            .thunderbolt,
            .ethernet,
            .usb,
            .wifi,
            .bluetooth,
            .unknown
        ]
        
        return connectionTypes.sorted { lhs, rhs in
            let lhsIndex = priority.firstIndex(of: lhs) ?? priority.count
            let rhsIndex = priority.firstIndex(of: rhs) ?? priority.count
            return lhsIndex < rhsIndex
        }
    }
}

/// 连接方式指示器（简洁版，只显示图标）
@available(macOS 14.0, *)
public struct ConnectionTypeIndicator: View {
    let connectionType: DeviceConnectionType
    let showLabel: Bool
    
    public init(connectionType: DeviceConnectionType, showLabel: Bool = false) {
        self.connectionType = connectionType
        self.showLabel = showLabel
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: connectionType.iconName)
                .font(.system(size: 12))
                .foregroundColor(indicatorColor)
            
            if showLabel {
                Text(connectionType.rawValue)
                    .font(.caption2)
                    .foregroundColor(indicatorColor)
            }
        }
    }
    
    private var indicatorColor: Color {
        switch connectionType {
        case .wifi:
            return .blue
        case .ethernet:
            return .orange
        case .usb:
            return .green
        case .thunderbolt:
            return .purple
        case .bluetooth:
            return .cyan
        case .unknown:
            return .gray
        }
    }
}

// MARK: - 预览

#if DEBUG
@available(macOS 14.0, *)
struct ConnectionTypeBadge_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
 // 单个连接方式
            VStack(alignment: .leading, spacing: 8) {
                Text("单个连接方式")
                    .font(.headline)
                
                HStack(spacing: 8) {
                    ConnectionTypeBadge(connectionType: .wifi, size: .small)
                    ConnectionTypeBadge(connectionType: .ethernet, size: .medium)
                    ConnectionTypeBadge(connectionType: .usb, size: .large)
                }
            }
            
            Divider()
            
 // 多种连接方式
            VStack(alignment: .leading, spacing: 8) {
                Text("多种连接方式")
                    .font(.headline)
                
                MultiConnectionTypeBadge(
                    connectionTypes: [.wifi, .usb, .bluetooth],
                    size: .medium
                )
                
                MultiConnectionTypeBadge(
                    connectionTypes: [.thunderbolt, .ethernet, .usb, .wifi],
                    size: .medium,
                    maxDisplay: 3
                )
            }
            
            Divider()
            
 // 连接方式指示器
            VStack(alignment: .leading, spacing: 8) {
                Text("连接方式指示器")
                    .font(.headline)
                
                HStack(spacing: 12) {
                    ConnectionTypeIndicator(connectionType: .wifi, showLabel: false)
                    ConnectionTypeIndicator(connectionType: .usb, showLabel: true)
                    ConnectionTypeIndicator(connectionType: .thunderbolt, showLabel: true)
                }
            }
        }
        .padding()
        .frame(width: 600)
    }
}
#endif

