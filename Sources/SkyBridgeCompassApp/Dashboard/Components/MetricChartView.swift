import SwiftUI
import Charts

/// 指标图表组件
public struct MetricChartView: View {
    let title: String
    let value: Double
    let color: Color
    let timeline: [Date: Double]
    let unit: String
    
    public init(title: String, value: Double, color: Color, timeline: [Date: Double], unit: String = "%") {
        self.title = title
        self.value = value
        self.color = color
        self.timeline = timeline
        self.unit = unit
    }
    
    public var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("\(value * (unit == "%" ? 100 : 1), specifier: "%.1f")\(unit)")
                    .font(.title3.bold())
                    .foregroundColor(color)
            }
            
            Spacer()
            
 // 简化的图表显示
            Chart {
                let sortedData = timeline.sorted(by: { $0.key < $1.key })
                ForEach(Array(sortedData.enumerated()), id: \.offset) { index, point in
                    LineMark(
                        x: .value("Time", index),
                        y: .value("Value", point.value * (unit == "%" ? 100 : 1))
                    )
                    .foregroundStyle(color)
                }
            }
            .frame(width: 120, height: 40)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }
}

