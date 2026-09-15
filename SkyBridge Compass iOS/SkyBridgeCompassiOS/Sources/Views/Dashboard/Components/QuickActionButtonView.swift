//
// QuickActionButtonView.swift
// SkyBridgeCompassiOS
//
// 快捷操作按钮组件 - Quantum Glass 风格
//

import SwiftUI

/// 快捷操作按钮视图
@available(iOS 17.0, *)
public struct QuickActionButtonView: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    public init(title: String, icon: String, color: Color, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.color = color
        self.action = action
    }
    
    public var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color.gradient)
                    .symbolRenderingMode(.multicolor)
                
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .liquidGlassCapsule(paddingH: 20, paddingV: 14)
        }
        .buttonStyle(.plain)
    }
}
