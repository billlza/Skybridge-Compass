//
// StatCardView.swift
// SkyBridgeCompassiOS
//
// 统计卡片组件 - 显示数值统计信息
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
            // 图标
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                Spacer()
            }
            
            Spacer()
            
            // 数值
            Text(value)
                .font(.title2.bold())
                .foregroundColor(.white)
            
            // 标题
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(height: 110)
        .background(
            LinearGradient(
                colors: [
                    color.opacity(0.15),
                    color.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Preview
#if DEBUG
@available(iOS 17.0, *)
struct StatCardView_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            StatCardView(
                title: "在线设备",
                value: "5",
                icon: "laptopcomputer",
                color: .blue
            )
            
            StatCardView(
                title: "活跃会话",
                value: "2",
                icon: "display",
                color: .green
            )
        }
        .padding()
        .background(Color.black)
    }
}
#endif
