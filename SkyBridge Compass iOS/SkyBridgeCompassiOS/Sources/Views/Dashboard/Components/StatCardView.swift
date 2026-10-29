//
// StatCardView.swift
// SkyBridgeCompassiOS
//
// 统计卡片组件 - 显示数值统计信息 - Quantum Glass 风格
//

import SwiftUI

/// 统计卡片视图
@available(iOS 17.0, *)
public struct StatCardView: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    public init(title: String, value: String, icon: String, color: Color) {
        self.title = title
        self.value = value
        self.icon = icon
        self.color = color
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color.gradient)
                    .symbolRenderingMode(.multicolor)
                Spacer()
            }
            
            Spacer(minLength: 8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .liquidGlassCard(cornerRadius: 24, padding: 0)
    }
}
