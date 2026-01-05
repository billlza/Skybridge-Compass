import SwiftUI
import SkyBridgeCore

/// 极光幻境背景组件 (Canvas Version)
/// 使用高性能 Canvas 绘制动态极光效果，替代不稳定的 Metal 实现。
/// 通过多层正弦波叠加与模糊处理，模拟极光的流动感与光影变化。
struct AuroraBackgroundV2: View {
    let weather: WeatherInfo?
    
    @State private var time: TimeInterval = 0
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject var bgControl = BackgroundControlManager.shared
    
 // 风速影响极光流动速度
    private var flowSpeed: Double {
        let wind = weather?.windSpeed ?? 10.0
        return max(0.5, min(wind / 15.0, 2.5))
    }
    
    var body: some View {
        Group {
            if !bgControl.isPaused {
                TimelineView(.periodic(from: .now, by: 1.0 / settingsManager.performanceMode.targetFPS)) { timeline in
                    ZStack {
 // 1. 深邃夜空背景
                        LinearGradient(
                            colors: themeConfiguration.currentTheme.backgroundGradient,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        
 // 2. 极光层 (多层叠加 - 增强版)
 // 绿色主极光 (增加窗帘效果)
                        AuroraCurtainLayer(
                            time: time,
                            speed: 0.5 * flowSpeed,
                            amplitude: 180,
                            frequency: 0.002,
                            baseY: 0.3,
                            color: .green,
                            seed: 1
                        )
                        .blendMode(.screen)
                        .opacity(0.7)
                        
 // 紫色/粉色次极光
                        AuroraCurtainLayer(
                            time: time,
                            speed: 0.3 * flowSpeed,
                            amplitude: 140,
                            frequency: 0.003,
                            baseY: 0.45,
                            color: .purple,
                            seed: 2
                        )
                        .blendMode(.screen)
                        .opacity(0.5)
                        
 // 青色/蓝色深层极光
                        AuroraCurtainLayer(
                            time: time,
                            speed: 0.2 * flowSpeed,
                            amplitude: 100,
                            frequency: 0.0015,
                            baseY: 0.2,
                            color: .cyan,
                            seed: 3
                        )
                        .blendMode(.plusLighter)
                        .opacity(0.4)
                        
 // 3. 星空点缀 (复用深空背景的星空逻辑，但更稀疏)
                        StarDots(time: time)
                            .opacity(0.7)
                    }
                    .onChange(of: timeline.date) { oldDate, newDate in
                        let delta = newDate.timeIntervalSince(oldDate)
                        time += delta
                    }
                }
            } else {
 // 暂停时显示静态背景
                LinearGradient(
                    colors: themeConfiguration.currentTheme.backgroundGradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .opacity(bgControl.backgroundOpacity)
        .ignoresSafeArea()
    }
}

// MARK: - 极光窗帘层组件
private struct AuroraCurtainLayer: View {
    let time: TimeInterval
    let speed: Double
    let amplitude: CGFloat
    let frequency: CGFloat
    let baseY: CGFloat // 0.0 - 1.0
    let color: Color
    let seed: Int
    
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let baseH = h * baseY
            
            var path = Path()
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: 0, y: baseH))
            
 // 增加采样点以获得更平滑的曲线
            let step: CGFloat = 10
            let t = time * speed
            let s = Double(seed)
            let freq = Double(frequency)
            
            for x in stride(from: 0, to: w + step, by: step) {
                let relX = x / w
                let dx = Double(x)
                
 // 主波
                let y1 = sin(dx * freq + t + s)
 // 次波 (高频)
                let y2 = sin(dx * freq * 2.5 + t * 1.5 + s * 2.0)
 // 扰动波
                let y3 = sin(dx * freq * 0.5 + t * 0.2)
                
                let combined = y1 + y2 * 0.4 + y3 * 0.2
                
 // 边缘衰减
                let attenuation = sin(relX * .pi) // 中间高，两边低
                
                let yOffset = CGFloat(combined) * amplitude * CGFloat(attenuation)
                
                path.addLine(to: CGPoint(x: x, y: baseH + yOffset))
            }
            
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
            
 // 垂直渐变模拟极光窗帘
            let stops: [Gradient.Stop] = [
                .init(color: color.opacity(0), location: 0.0),
                .init(color: color.opacity(0.8), location: 0.2),
                .init(color: color.opacity(0.3), location: 0.6),
                .init(color: color.opacity(0.0), location: 1.0)
            ]
            let gradient = Gradient(stops: stops)
            let shading = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: baseH - amplitude),
                endPoint: CGPoint(x: 0, y: h)
            )
            
            context.fill(path, with: shading)
            
 // 添加垂直光柱 (Magnetic Field Lines)
            let lineCount = 5
            var rng = StarDots.SeededRandom(seed: seed + Int(time))
            
            for _ in 0..<lineCount {
                let lineX = rng.next() * w
                let lineWidth = rng.next(in: 20...60)
                let lineAlpha = rng.next(in: 0.1...0.3)
                
                let lineRect = CGRect(x: lineX, y: baseH - amplitude, width: lineWidth, height: h * 0.6)
                
                let linePath = Path(ellipseIn: lineRect)
                context.opacity = lineAlpha
                
                let lineGradient = Gradient(colors: [color.opacity(0), color, color.opacity(0)])
                let lineShading = GraphicsContext.Shading.linearGradient(
                    lineGradient,
                    startPoint: CGPoint(x: lineX, y: baseH - amplitude),
                    endPoint: CGPoint(x: lineX, y: baseH + h * 0.4)
                )
                
                context.fill(linePath, with: lineShading)
            }
        }
        .blur(radius: 30) // 保持柔和
    }
}


// MARK: - 简单星点组件
private struct StarDots: View {
    let time: TimeInterval
    
    var body: some View {
        Canvas { context, size in
            let count = 50
            for i in 0..<count {
                var rng = SeededRandom(seed: i * 100)
                let x = rng.next() * size.width
                let y = rng.next() * size.height * 0.6 // 只在上方显示
                let r = rng.next(in: 1...2)
                let opacity = rng.next(in: 0.3...0.8) + 0.2 * sin(time * rng.next(in: 1...3) + Double(i))
                
                context.opacity = opacity
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white))
            }
        }
    }
    
    struct SeededRandom {
        private var state: UInt64
        init(seed: Int) { state = UInt64(seed) }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1
            return Double(state) / Double(UInt64.max)
        }
        mutating func next(in range: ClosedRange<Double>) -> Double {
            return range.lowerBound + next() * (range.upperBound - range.lowerBound)
        }
    }
}
