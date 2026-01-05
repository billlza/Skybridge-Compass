import SwiftUI
import SkyBridgeCore

/// 极光幻境背景组件
/// 使用 Canvas 绘制多条柔性极光带，基于实时天气风速与湿度动态调整
/// 极光摆动频率与亮度，晴朗/寒冷环境下更鲜艳，雨雾环境下更柔和以与天气效果层融合。
struct AuroraBackground: View {
    let weather: WeatherInfo?
    
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    
    @State private var phase: Double = 0
    
 /// 风速影响极光摆动速度（范围保护）
    private var waveSpeed: Double {
        let wind = weather?.windSpeed ?? 6.0
        let base = wind / 18.0
        return max(0.04, min(base, 0.22))
    }
    
 /// 湿度影响极光模糊与透明度（雨/雾更柔和）
    private var softness: Double {
        let humidity = weather?.humidity ?? 60.0
        let condition = weather?.condition
        let base = (humidity / 100.0) * 0.35
        let condBoost = (condition == .rainy || condition == .foggy || condition == .haze) ? 0.15 : 0.05
        return min(0.6, base + condBoost)
    }
    
 /// 根据天气状况调节极光亮度
    private var brightness: Double {
        switch weather?.condition {
        case .clear: return 1.0
        case .snowy: return 0.95
        case .cloudy: return 0.75
        case .rainy: return 0.65
        case .foggy, .haze: return 0.6
        case .stormy: return 0.7
        default: return 0.8
        }
    }
    
    var body: some View {
        TimelineView(.animation) { timeline in
            ZStack {
 // 主题渐变底色（极光效果更依赖叠加层，底色不宜过强）
                LinearGradient(
                    colors: themeConfiguration.currentTheme.backgroundGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
 // 多条极光带
                Canvas { context, size in
                    let bands = 3
                    for i in 0..<bands {
                        let baseY = size.height * (0.25 + Double(i) * 0.18)
                        let path = auroraPath(in: size, baseY: baseY, phase: phase + Double(i) * 0.8)
                        
 // 渐变色：绿-青-紫，根据亮度调节
                        let gradient = Gradient(colors: [
                            Color.green.opacity(0.28 * brightness),
                            Color.cyan.opacity(0.24 * brightness),
                            Color.purple.opacity(0.20 * brightness)
                        ])
                        
                        context.blendMode = .screen
 // Canvas 的线性渐变需传入三个参数（梯度、起点、终点），
 // 不能使用嵌套的 .init(...) 作为单一参数，否则会触发“缺少 startPoint/endPoint”错误。
                        context.fill(
                            path,
                            with: .linearGradient(
                                gradient,
                                startPoint: CGPoint(x: 0, y: baseY - 80),
                                endPoint: CGPoint(x: size.width, y: baseY + 80)
                            )
                        )
                    }
                }
                .blur(radius: softness * 22)
                .opacity(0.9)
            }
 // 采用 macOS 14+ 推荐的两参数 onChange API，并关闭 initial 触发，按帧推进相位
            .onChange(of: timeline.date, initial: false) { _, _ in
                withAnimation(.linear(duration: 0.016)) {
                    phase += waveSpeed
                    if phase > 10_000 { phase = 0 }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
    
 /// 生成单条极光带路径（正弦叠加形成柔性波纹）
    private func auroraPath(in size: CGSize, baseY: Double, phase: Double) -> Path {
        var path = Path()
        let amplitude = 28.0 + 24.0 * sin(phase * 0.09)
        let thickness = 70.0
        let steps = 48
        
        var pointsTop: [CGPoint] = []
        var pointsBottom: [CGPoint] = []
        for s in 0...steps {
            let t = Double(s) / Double(steps)
            let x = t * size.width
            let yWave = sin(t * 6.0 + phase * 0.12) + 0.5 * sin(t * 3.0 + phase * 0.07)
            let y = baseY + yWave * amplitude
            pointsTop.append(CGPoint(x: x, y: y - thickness * 0.5))
            pointsBottom.append(CGPoint(x: x, y: y + thickness * 0.5))
        }
        
        if let first = pointsTop.first {
            path.move(to: first)
        }
        for p in pointsTop.dropFirst() { path.addLine(to: p) }
        for p in pointsBottom.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }
}