//
// SkyBridgeLiveActivity.swift
// SkyBridge Compass iOS
//
// Dynamic Island 灵动岛支持
// - 已连接：显示设备名称和连接状态/传输进度
// - 未连接：左侧天气图标，右侧温度
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Live Activity Widget

@available(iOS 16.2, *)
struct SkyBridgeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SkyBridgeActivityAttributes.self) { context in
            // Lock Screen / Banner 视图
            LockScreenView(state: context.state)
                .activityBackgroundTint(.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开视图 (长按灵动岛)
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    ExpandedCenterView(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(state: context.state)
                }
            } compactLeading: {
                // 紧凑模式 - 左侧
                CompactLeadingView(state: context.state)
            } compactTrailing: {
                // 紧凑模式 - 右侧
                CompactTrailingView(state: context.state)
            } minimal: {
                // 最小模式（与其他 Live Activity 共存时）
                MinimalView(state: context.state)
            }
        }
    }
}

// MARK: - Compact Views (灵动岛紧凑模式)

/// 紧凑模式 - 左侧视图
@available(iOS 16.2, *)
struct CompactLeadingView: View {
    let state: SkyBridgeActivityAttributes.ContentState
    
    var body: some View {
        if state.isConnected {
            // 已连接：显示连接图标
            if state.isTransferring {
                Image(systemName: state.transferDirection.iconName)
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Image(systemName: "link.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            // 未连接：显示天气图标
            Image(systemName: state.weatherCondition)
                .foregroundStyle(weatherIconColor(for: state.weatherCondition))
        }
    }
    
    private func weatherIconColor(for icon: String) -> Color {
        switch icon {
        case "sun.max.fill": return .yellow
        case "cloud.fill": return .gray
        case "cloud.rain.fill": return .blue
        case "cloud.snow.fill": return .cyan
        case "cloud.fog.fill": return .gray.opacity(0.7)
        case "cloud.bolt.rain.fill": return .purple
        default: return .white
        }
    }
}

/// 紧凑模式 - 右侧视图
@available(iOS 16.2, *)
struct CompactTrailingView: View {
    let state: SkyBridgeActivityAttributes.ContentState
    
    var body: some View {
        if state.isConnected {
            // 已连接：显示设备名或传输进度
            if state.isTransferring {
                Text("\(Int(state.transferProgress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
            } else {
                Text(truncatedDeviceName)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.green)
            }
        } else {
            // 未连接：显示温度
            Text("\(state.temperature)°")
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.white)
        }
    }
    
    private var truncatedDeviceName: String {
        let name = state.connectedDeviceName ?? "设备"
        return name.count > 6 ? String(name.prefix(5)) + "…" : name
    }
}

// MARK: - Minimal View (最小模式)

@available(iOS 16.2, *)
struct MinimalView: View {
    let state: SkyBridgeActivityAttributes.ContentState
    
    var body: some View {
        if state.isConnected {
            if state.isTransferring {
                // 传输中：显示进度环
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: state.transferProgress)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: state.transferDirection.iconName)
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
            } else {
                Image(systemName: "link.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            Image(systemName: state.weatherCondition)
                .foregroundStyle(.yellow)
        }
    }
}

// MARK: - Expanded Views (展开模式)

@available(iOS 16.2, *)
struct ExpandedLeadingView: View {
    let state: SkyBridgeActivityAttributes.ContentState
    
    var body: some View {
        if state.isConnected {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: "link.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text("已连接")
                    .font(.caption2)
                    .foregroundStyle(.green.opacity(0.8))
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: state.weatherCondition)
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(state.weatherDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@available(iOS 16.2, *)
struct ExpandedTrailingView: View {
    let state: SkyBridgeActivityAttributes.ContentState
    
    var body: some View {
        if state.isConnected {
            VStack(alignment: .trailing, spacing: 2) {
                if let suite = state.cryptoSuite {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield.fill")
                            .font(.caption)
                        Text(suite)
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(.cyan)
                }
                Text("守护中")
                    .font(.caption2)
                    .foregroundStyle(.green.opacity(0.8))
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(state.temperature)°C")
                    .font(.title2.monospacedDigit().bold())
                    .foregroundStyle(.white)
            }
        }
    }
}

@available(iOS 16.2, *)
struct ExpandedCenterView: View {
    let state: SkyBridgeActivityAttributes.ContentState
    
    var body: some View {
        if state.isConnected {
            VStack(spacing: 2) {
                Text(state.connectedDeviceName ?? "已连接设备")
                    .font(.headline)
                    .lineLimit(1)
                if state.isTransferring, let fileName = state.transferFileName {
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text("SkyBridge")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

@available(iOS 16.2, *)
struct ExpandedBottomView: View {
    let state: SkyBridgeActivityAttributes.ContentState
    
    var body: some View {
        if state.isConnected && state.isTransferring {
            VStack(spacing: 6) {
                // 传输进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.2))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [.green, .cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * state.transferProgress)
                    }
                }
                .frame(height: 6)
                
                HStack {
                    Text("\(Int(state.transferProgress * 100))%")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    if let speed = state.transferSpeed {
                        Text(speed)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if state.isConnected {
            HStack {
                Label("安全连接", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Text("点击查看详情")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Text("未连接设备")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("点击开始发现")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
    }
}

// MARK: - Lock Screen View

@available(iOS 16.2, *)
struct LockScreenView: View {
    let state: SkyBridgeActivityAttributes.ContentState
    
    var body: some View {
        HStack(spacing: 12) {
            // 左侧图标
            ZStack {
                Circle()
                    .fill(iconBackgroundColor)
                    .frame(width: 44, height: 44)
                
                if state.isConnected && state.isTransferring {
                    // 传输进度环
                    Circle()
                        .trim(from: 0, to: state.transferProgress)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                }
                
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(iconColor)
            }
            
            // 中间内容
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // 右侧
            VStack(alignment: .trailing, spacing: 2) {
                Text(trailingTopText)
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(trailingColor)
                if let bottomText = trailingBottomText {
                    Text(bottomText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
    
    private var iconName: String {
        if state.isConnected {
            return state.isTransferring ? state.transferDirection.iconName : "link.circle.fill"
        } else {
            return state.weatherCondition
        }
    }
    
    private var iconColor: Color {
        if state.isConnected {
            return .green
        } else {
            return .yellow
        }
    }
    
    private var iconBackgroundColor: Color {
        if state.isConnected {
            return .green.opacity(0.2)
        } else {
            return .yellow.opacity(0.2)
        }
    }
    
    private var titleText: String {
        if state.isConnected {
            return state.connectedDeviceName ?? "已连接设备"
        } else {
            return "SkyBridge Compass"
        }
    }
    
    private var subtitleText: String {
        if state.isConnected {
            if state.isTransferring, let fileName = state.transferFileName {
                return "传输中: \(fileName)"
            }
            return state.cryptoSuite ?? "安全连接"
        } else {
            return state.weatherDescription
        }
    }
    
    private var trailingTopText: String {
        if state.isConnected && state.isTransferring {
            return "\(Int(state.transferProgress * 100))%"
        } else if state.isConnected {
            return "守护中"
        } else {
            return "\(state.temperature)°"
        }
    }
    
    private var trailingBottomText: String? {
        if state.isConnected && state.isTransferring {
            return state.transferSpeed
        }
        return nil
    }
    
    private var trailingColor: Color {
        if state.isConnected {
            return .green
        } else {
            return .white
        }
    }
}

// MARK: - Preview

@available(iOS 16.2, *)
#Preview("Connected", as: .dynamicIsland(.compact), using: SkyBridgeActivityAttributes()) {
    SkyBridgeLiveActivity()
} contentStates: {
    SkyBridgeActivityAttributes.ContentState(
        isConnected: true,
        connectedDeviceName: "iPhone 16 Pro",
        cryptoSuite: "ML-KEM-768"
    )
}

@available(iOS 16.2, *)
#Preview("Transferring", as: .dynamicIsland(.expanded), using: SkyBridgeActivityAttributes()) {
    SkyBridgeLiveActivity()
} contentStates: {
    SkyBridgeActivityAttributes.ContentState(
        isConnected: true,
        connectedDeviceName: "MacBook Pro",
        cryptoSuite: "ML-KEM-768",
        isTransferring: true,
        transferFileName: "Project.zip",
        transferProgress: 0.65,
        transferDirection: .upload,
        transferSpeed: "12.5 MB/s"
    )
}

@available(iOS 16.2, *)
#Preview("Weather", as: .dynamicIsland(.compact), using: SkyBridgeActivityAttributes()) {
    SkyBridgeLiveActivity()
} contentStates: {
    SkyBridgeActivityAttributes.ContentState(
        isConnected: false,
        weatherCondition: "sun.max.fill",
        temperature: 23,
        weatherDescription: "晴朗"
    )
}

