import SwiftUI
import Charts

/// 性能图表卡片 - 显示系统性能趋势图表
/// 符合macOS设计规范，提供直观的数据可视化
public struct PerformanceChartCard: View {
    
 // MARK: - 属性
    
    let title: String
    let data: [ChartDataPoint]
    let color: Color
    let unit: String
    let maxValue: Double?
    let showGrid: Bool
    
 // MARK: - 初始化
    
    public init(
        title: String,
        data: [ChartDataPoint],
        color: Color = .blue,
        unit: String = "%",
        maxValue: Double? = nil,
        showGrid: Bool = true
    ) {
        self.title = title
        self.data = data
        self.color = color
        self.unit = unit
        self.maxValue = maxValue
        self.showGrid = showGrid
    }
    
 // MARK: - 视图主体
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
 // 标题和当前值
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if let currentValue = data.last?.value {
                    Text("\(currentValue, specifier: "%.1f")\(unit)")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(color)
                        .contentTransition(.numericText())
                }
            }
            
 // 图表
            if data.isEmpty {
 // 空状态
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    
                    Text(LocalizationManager.shared.localizedString("monitor.noData"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
            } else {
                Chart(data) { dataPoint in
                    LineMark(
                        x: .value(LocalizationManager.shared.localizedString("monitor.axis.time"), dataPoint.timestamp),
                        y: .value(LocalizationManager.shared.localizedString("monitor.axis.value"), dataPoint.value)
                    )
                    .foregroundStyle(color.gradient)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    
                    AreaMark(
                        x: .value(LocalizationManager.shared.localizedString("monitor.axis.time"), dataPoint.timestamp),
                        y: .value(LocalizationManager.shared.localizedString("monitor.axis.value"), dataPoint.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.3), color.opacity(0.1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.separator.opacity(showGrid ? 1 : 0))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.separator)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.separator.opacity(showGrid ? 1 : 0))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.separator)
                        AxisValueLabel {
                            if let doubleValue = value.as(Double.self) {
                                Text("\(doubleValue, specifier: "%.0f")\(unit)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...(maxValue ?? (data.map { $0.value }.max() ?? 100)))
                .frame(height: 120)
                .animation(.easeInOut(duration: 0.5), value: data.count)
            }
            
 // 统计信息
            statisticsView
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
    }
    
 // MARK: - 统计信息视图
    
    private var statisticsView: some View {
        HStack(spacing: 24) {
 // 平均值
            StatisticItem(
                title: LocalizationManager.shared.localizedString("monitor.stats.avg"),
                value: averageValue,
                unit: unit,
                color: .secondary
            )
            
 // 最大值
            StatisticItem(
                title: LocalizationManager.shared.localizedString("monitor.stats.max"),
                value: maxValueInData,
                unit: unit,
                color: Color.orange
            )
            
 // 最小值
            StatisticItem(
                title: LocalizationManager.shared.localizedString("monitor.stats.min"),
                value: minValueInData,
                unit: unit,
                color: Color.green
            )
            
            Spacer()
        }
    }
    
 // MARK: - 计算属性
    
    private var averageValue: Double {
        guard !data.isEmpty else { return 0 }
        return data.map { $0.value }.reduce(0, +) / Double(data.count)
    }
    
    private var maxValueInData: Double {
        data.map { $0.value }.max() ?? 0
    }
    
    private var minValueInData: Double {
        data.map { $0.value }.min() ?? 0
    }
}

// MARK: - 统计项组件

private struct StatisticItem: View {
    let title: String
    let value: Double
    let unit: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Text("\(value, specifier: "%.1f")\(unit)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(color)
        }
    }
}

// MARK: - 图表数据点

public struct ChartDataPoint: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let value: Double
    
    public init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}

// MARK: - 预览

struct PerformanceChartCard_Previews: PreviewProvider {
    static var previews: some View {
 // CPU使用率图表
        let sampleData1 = (0..<60).map { index in
            ChartDataPoint(
                timestamp: Date().addingTimeInterval(TimeInterval(-60 + index)),
                value: Double.random(in: 20...80)
            )
        }
        
        PerformanceChartCard(
            title: "CPU使用率",
            data: sampleData1,
            color: Color.blue,
            unit: "%",
            maxValue: 100
        )
        .frame(width: 400, height: 250)
        .padding()
        .previewDisplayName("CPU使用率图表")

 // 内存使用图表
        let sampleData2 = (0..<60).map { index in
            ChartDataPoint(
                timestamp: Date().addingTimeInterval(TimeInterval(-60 + index)),
                value: Double.random(in: 40...90)
            )
        }
        
        PerformanceChartCard(
            title: "内存使用率",
            data: sampleData2,
            color: Color.green,
            unit: "%",
            maxValue: 100
        )
        .frame(width: 400, height: 250)
        .padding()
        .previewDisplayName("内存使用图表")

 // 空数据状态
        PerformanceChartCard(
            title: "网络使用率",
            data: [],
            color: Color.orange,
            unit: "MB/s"
        )
        .frame(width: 400, height: 250)
        .padding()
        .previewDisplayName("空数据状态")
    }
}
