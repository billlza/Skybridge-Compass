import SwiftUI

/// 性能指标显示行（用于CPU/GPU）
public struct PerformanceMetricRow: View {
    let title: String
    let value: String
    let temperature: String
    let color: Color
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    
    public init(title: String, value: String, temperature: String, color: Color) {
        self.title = title
        self.value = value
        self.temperature = temperature
        self.color = color
    }
    
    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(themeConfiguration.secondaryTextColor)
                HStack(spacing: 8) {
                    Text(value)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(color)
                    Text("·")
                        .foregroundColor(themeConfiguration.secondaryTextColor)
                    Text(temperature)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(color.opacity(0.8))
                }
            }
            
            Spacer()
            
            Image(systemName: title == "CPU" ? "cpu.fill" : "square.stack.3d.up.fill")
                .font(.title2)
                .foregroundColor(color)
        }
    }
}

