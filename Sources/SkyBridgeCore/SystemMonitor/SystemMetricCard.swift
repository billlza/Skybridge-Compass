import SwiftUI

/// 系统指标卡片 - 显示单个系统指标的通用组件
/// 符合macOS设计规范，提供一致的视觉体验
public struct SystemMetricCard: View {
    
 // MARK: - 属性
    
    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let color: Color
    let trend: TrendDirection?
    let isLoading: Bool
    
 // MARK: - 初始化
    
    public init(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        color: Color = Color.blue,
        trend: TrendDirection? = nil,
        isLoading: Bool = false
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.trend = trend
        self.isLoading = isLoading
    }
    
 // MARK: - 视图主体
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
 // 标题和图标
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title2)
                
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
 // 趋势指示器
                if let trend = trend {
                    HStack(spacing: 4) {
                        Image(systemName: trend.iconName)
                            .font(.caption)
                            .foregroundColor(trend.color)
                    }
                }
            }
            
 // 主要数值
            HStack(alignment: .firstTextBaseline) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(height: 32)
                } else {
                    Text(value)
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .contentTransition(.numericText())
                }
                
                Spacer()
            }
            
 // 副标题
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
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
        .animation(.easeInOut(duration: 0.3), value: isLoading)
        .animation(.easeInOut(duration: 0.3), value: value)
    }
}

// MARK: - 预览

struct SystemMetricCard_Previews: PreviewProvider {
    static var previews: some View {
 // CPU使用率
        SystemMetricCard(
            title: "CPU使用率",
            value: "45.2%",
            subtitle: "8核心处理器",
            icon: "cpu",
            color: Color.blue,
            trend: TrendDirection.up
        )
        .frame(width: 200, height: 120)
        .padding()
        .previewDisplayName("CPU使用率")

 // 内存使用
        SystemMetricCard(
            title: "内存使用",
            value: "12.4 GB",
            subtitle: "共16 GB",
            icon: "memorychip",
            color: Color.green,
            trend: TrendDirection.stable
        )
        .frame(width: 200, height: 120)
        .padding()
        .previewDisplayName("内存使用")

 // 网络上传
        SystemMetricCard(
            title: "网络上传",
            value: "2.1 MB/s",
            subtitle: "峰值: 5.2 MB/s",
            icon: "arrow.up.circle",
            color: Color.orange,
            trend: TrendDirection.down
        )
        .frame(width: 200, height: 120)
        .padding()
        .previewDisplayName("网络上传")

 // 加载状态
        SystemMetricCard(
            title: "系统负载",
            value: "0.0",
            subtitle: "1分钟平均",
            icon: "gauge",
            color: Color.purple,
            isLoading: true
        )
        .frame(width: 200, height: 120)
        .padding()
        .previewDisplayName("加载状态")
    }
}
