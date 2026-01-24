//
// CloudySkyEffectView.swift
// SkyBridgeCore
//
// 轻量级多云效果（Canvas 云团 + 渐变），用于替换占位 EmptyView
// Created: 2026-01-21
//

import SwiftUI

@available(macOS 14.0, *)
public struct CloudySkyEffectView: View {
    public let opacity: Double

    public init(opacity: Double = 1.0) {
        self.opacity = opacity
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate

                // 1) 冷色渐变（透明叠加）
                let gradient = Gradient(colors: [
                    Color(red: 0.35, green: 0.45, blue: 0.55).opacity(0.20),
                    Color(red: 0.30, green: 0.40, blue: 0.50).opacity(0.18),
                    Color.clear
                ])
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
                )

                // 2) 云团（多层模糊椭圆，轻微漂移）
                context.addFilter(.blur(radius: 22))
                let layerCount = 3
                for layer in 0..<layerCount {
                    let depth = CGFloat(layer) / CGFloat(max(1, layerCount - 1))
                    let baseY = (0.15 + 0.18 * depth) * size.height
                    let speed = 8.0 * (1.0 - Double(depth) * 0.55)
                    let xOffset = CGFloat((t * speed).truncatingRemainder(dividingBy: Double(size.width + 600))) - 300
                    let alpha = 0.10 + 0.06 * (1.0 - Double(depth))

                    for i in 0..<4 {
                        let local = CGFloat(i) * (size.width + 600) / 4.0
                        let cx = xOffset + local
                        let cy = baseY + CGFloat(sin(t * 0.25 + Double(i) * 1.1 + Double(layer))) * 18
                        let w = (420 + 120 * depth) * (0.9 + 0.2 * CGFloat(i % 2))
                        let h = (140 + 40 * depth)

                        context.fill(
                            Path(ellipseIn: CGRect(x: cx, y: cy, width: w, height: h)),
                            with: .color(Color.white.opacity(alpha))
                        )
                    }
                }
            }
        }
        .opacity(opacity)
        .ignoresSafeArea()
    }
}


