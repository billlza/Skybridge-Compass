import SwiftUI
import SkyBridgeCore

/// 深空探索背景组件 (Enhanced Version)
/// 该壁纸以深空星云与多层视差星点为主，
/// 结合实时天气数据动态调整漂移速度、色彩冷暖与薄雾叠加强度。
/// 包含流星效果与动态星云。
struct DeepSpaceBackground: View {
 /// 实时天气信息，用于驱动背景交互参数
    let weather: WeatherInfo?

    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject var bgControl = BackgroundControlManager.shared

    @State private var time: TimeInterval = 0

 /// 风速影响漂移速度
    private var windSpeedFactor: Double {
        let wind = weather?.windSpeed ?? 5.0
        return max(0.2, min(wind / 10.0, 2.0))
    }

 /// 湿度影响雾气
    private var hazeOpacity: Double {
        let humidity = weather?.humidity ?? 50.0
        let base = (humidity / 100.0) * 0.2
        return min(0.4, base)
    }

    /// 仅在“雾/霾”天气下才叠加背景薄雾，否则会把整体背景压成灰败（用户反馈：多云不应变灰）
    private var shouldApplyWeatherHazeOverlay: Bool {
        guard let condition = weather?.condition else { return false }
        return condition.needsFogEffect
    }

    var body: some View {
        Group {
            if !bgControl.isPaused {
                TimelineView(.periodic(from: .now, by: 1.0 / bgControl.getEffectiveFPS(base: settingsManager.performanceMode.targetFPS))) { timeline in
                    ZStack {
 // 1. 基础深空背景 (增强渐变)
                        LinearGradient(
                            colors: themeConfiguration.currentTheme.backgroundGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

 // 2. 动态星云层 (升级为Canvas绘制)
                        DeepNebulaLayer(time: time, windFactor: windSpeedFactor)
                            .blendMode(.screen)
                            .opacity(0.7)

 // 3. 多层视差星空
 // 远景星空
                        StarFieldLayer(count: 200, baseSize: 0.8, speedFactor: 0.1 * windSpeedFactor, time: time)
                            .opacity(0.6)

 // 中景星空
                        StarFieldLayer(count: 100, baseSize: 1.8, speedFactor: 0.2 * windSpeedFactor, time: time)
                            .opacity(0.8)

 // 近景星空（更亮，移动更快）
                        StarFieldLayer(count: 40, baseSize: 2.5, speedFactor: 0.4 * windSpeedFactor, time: time)
                            .blendMode(.plusLighter)

 // 4. 流星层
                        ShootingStarLayer(time: time)
                            .blendMode(.plusLighter)

                        // 5. 天气叠加层 (雾气/光晕) - 仅在雾/霾启用，避免多云把底色整体染灰
                        if shouldApplyWeatherHazeOverlay && hazeOpacity > 0.05 {
                            Color.white
                                .opacity(hazeOpacity * 0.3)
                                .blendMode(.overlay)
                                .ignoresSafeArea()
                        }
                    }
                    .onChange(of: timeline.date) { oldDate, newDate in
                        let delta = newDate.timeIntervalSince(oldDate)
                        time += delta
                    }
                }
            } else {
 // 暂停时显示的静态占位
                LinearGradient(
                    colors: themeConfiguration.currentTheme.backgroundGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .opacity(bgControl.backgroundOpacity)
        .ignoresSafeArea()
    }
}

// MARK: - 动态星云组件 (Canvas Version)
private struct DeepNebulaLayer: View {
    let time: TimeInterval
    let windFactor: Double

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

 // 绘制几个缓慢移动的深空星云团
            let blobs = [
                (color: Color(red: 0.2, green: 0.0, blue: 0.4), x: 0.3, y: 0.4, r: 0.6, s: 0.03), // 深紫
                (color: Color(red: 0.0, green: 0.2, blue: 0.5), x: 0.7, y: 0.6, r: 0.7, s: 0.02), // 深蓝
                (color: Color(red: 0.0, green: 0.3, blue: 0.3), x: 0.5, y: 0.2, r: 0.5, s: 0.04), // 深青
                (color: Color(red: 0.3, green: 0.0, blue: 0.2), x: 0.2, y: 0.8, r: 0.5, s: 0.02)  // 暗红
            ]

            for (i, blob) in blobs.enumerated() {
 // 复杂的轨迹运动
                let t = time * blob.s * windFactor
                let angle = t + Double(i) * 2.0
                let offsetX = sin(angle) * w * 0.15
                let offsetY = cos(angle * 0.8) * h * 0.15

                let rect = CGRect(
                    x: (blob.x * w) + offsetX - (blob.r * w / 2),
                    y: (blob.y * h) + offsetY - (blob.r * w / 2),
                    width: blob.r * w,
                    height: blob.r * w
                )

 // 呼吸透明度
                let opacity = 0.4 + 0.2 * sin(time * 0.5 + Double(i))

                context.opacity = opacity
                var fillContext = context
                fillContext.blendMode = .plusLighter
                fillContext.fill(Path(ellipseIn: rect), with: .color(blob.color))
            }
        }
        .blur(radius: 80) // 强模糊
    }
}


// MARK: - 星空层组件 (Canvas)
private struct StarFieldLayer: View {
    let count: Int
    let baseSize: CGFloat
    let speedFactor: Double
    let time: TimeInterval

    var body: some View {
        Canvas { context, size in
            let timeOffset = time * speedFactor * 50.0

            for i in 0..<count {
                var rng = SeededRandom(seed: i)
                let x = rng.next() * size.width
                let y = rng.next() * size.height
                let starSize = rng.next(in: 0.5...1.5) * baseSize
                let brightness = rng.next(in: 0.3...1.0)
                let twinkleSpeed = rng.next(in: 1.0...5.0)

 // 视差移动
                let currentX = (x + timeOffset * rng.next(in: 0.8...1.2)).truncatingRemainder(dividingBy: size.width)
                let finalX = currentX < 0 ? currentX + size.width : currentX

 // 闪烁
                let alpha = brightness * (0.7 + 0.3 * sin(time * twinkleSpeed + Double(i)))

                let rect = CGRect(x: finalX, y: y, width: starSize, height: starSize)
                context.opacity = alpha
                context.fill(Path(ellipseIn: rect), with: .color(.white))
            }
        }
    }

 // 简单的伪随机数生成器
    struct SeededRandom {
        private var state: UInt64

        init(seed: Int) {
            state = UInt64(seed)
        }

        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1
            return Double(state) / Double(UInt64.max)
        }

        mutating func next(in range: ClosedRange<Double>) -> Double {
            return range.lowerBound + next() * (range.upperBound - range.lowerBound)
        }
    }
}

// MARK: - 流星层组件
private struct ShootingStarLayer: View {
    let time: TimeInterval

    var body: some View {
        Canvas { context, size in
 // 每隔几秒出现一个流星
 // 使用 time 来决定流星的位置和进度
            let cycleDuration: Double = 6.0
            let activeDuration: Double = 0.8

            let cycleTime = time.remainder(dividingBy: cycleDuration)

 // 只有在周期开始的一小段时间内显示流星
            if cycleTime < activeDuration && cycleTime > 0 {
                let progress = cycleTime / activeDuration

 // 使用整数时间作为种子，保证每次流星位置不同
                let seed = Int(time / cycleDuration)
                var rng = StarFieldLayer.SeededRandom(seed: seed)

                let startX = rng.next(in: 0.2...0.8) * size.width
                let startY = rng.next(in: 0.0...0.5) * size.height
                let angle = rng.next(in: 30...60) * .pi / 180.0
                let length = rng.next(in: 100...300)

                let dx = cos(angle) * length
                let dy = sin(angle) * length

                let currentX = startX + dx * progress
                let currentY = startY + dy * progress

 // 绘制流星头
                let headRect = CGRect(x: currentX, y: currentY, width: 2, height: 2)
                context.opacity = 1.0 - progress // 渐渐消失

 // 绘制拖尾
                var path = Path()
                path.move(to: CGPoint(x: currentX, y: currentY))
                path.addLine(to: CGPoint(x: currentX - dx * 0.1, y: currentY - dy * 0.1))

                context.stroke(path, with: .linearGradient(
                    Gradient(colors: [.white, .white.opacity(0)]),
                    startPoint: CGPoint(x: currentX, y: currentY),
                    endPoint: CGPoint(x: currentX - dx * 0.1, y: currentY - dy * 0.1)
                ), lineWidth: 1.5)

                context.fill(Path(ellipseIn: headRect), with: .color(.white))
            }
        }
    }
}
