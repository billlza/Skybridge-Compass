//
// QuickActionButtonView.swift
// SkyBridgeCompassiOS
//
// 快捷操作按钮组件
//

import SwiftUI

/// 快捷操作按钮视图
@available(iOS 17.0, *)
public struct QuickActionButtonView: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    @State private var isPressed = false
    
    public init(title: String, icon: String, color: Color, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.color = color
        self.action = action
    }
    
    public var body: some View {
        Button(action: {
            // 触感反馈
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            action()
        }) {
            VStack(spacing: 8) {
                // 图标容器
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.3), color.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(color)
                }
                
                // 标题
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(isPressed ? 0.1 : 0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Preview
#if DEBUG
@available(iOS 17.0, *)
struct QuickActionButtonView_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            QuickActionButtonView(
                title: "扫描",
                icon: "magnifyingglass",
                color: .blue
            ) {}
            
            QuickActionButtonView(
                title: "传输",
                icon: "arrow.up.arrow.down",
                color: .orange
            ) {}
            
            QuickActionButtonView(
                title: "远程",
                icon: "display",
                color: .cyan
            ) {}
            
            QuickActionButtonView(
                title: "二维码",
                icon: "qrcode",
                color: .purple
            ) {}
        }
        .padding()
        .background(Color.black)
    }
}
#endif
