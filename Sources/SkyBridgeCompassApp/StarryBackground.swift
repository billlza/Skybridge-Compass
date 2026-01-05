import SwiftUI
import SkyBridgeCore

/// 星空夜晚背景组件 (Enhanced Canvas Version)
/// 升级版星空背景，包含多层视差星星、动态呼吸星云以及优化的流星效果。
/// 旨在创造一个深邃、宁静且富有生机的夜空体验。
struct StarryBackground: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject var bgControl = BackgroundControlManager.shared
    @State private var time: TimeInterval = 0
    
    var body: some View {
 // 性能优化：根据设置动态调整帧率
 // 当处于暂停状态时，不进行重绘以节省资源
        Group {
            if !bgControl.isPaused {
                TimelineView(.periodic(from: .now, by: 1.0 / bgControl.getEffectiveFPS(base: settingsManager.performanceMode.targetFPS))) { timeline in
                    ZStack {
 // 1. 基础夜空背景 (更丰富的渐变 - 动态微调)
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.01, green: 0.01, blue: 0.08), // 极深邃黑蓝
                                Color(red: 0.03, green: 0.03, blue: 0.15), // 深午夜蓝
                                Color(red: 0.08, green: 0.06, blue: 0.25), // 深紫
                                Color(red: 0.12, green: 0.10, blue: 0.30)  // 亮紫微光
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        
 // 2. 银河光辉层 (新增 - 增加画面中心深度)
                        GalaxyGlowLayer(time: time)
                            .blendMode(.screen)
                            .opacity(0.4)
                        
 // 3. 动态呼吸星云
                        NebulaLayer(time: time)
                            .blendMode(.screen)
                            .opacity(0.5)
                        
 // 4. 多层视差星空
 // 远景层
                        StarLayer(count: 350, baseSize: 0.8, speed: 0.3, twinkleSpeed: 0.8, time: time, colorTint: .blue)
                            .opacity(0.6)
                        
 // 中景层
                        StarLayer(count: 120, baseSize: 1.5, speed: 0.8, twinkleSpeed: 1.5, time: time, colorTint: .white)
                            .opacity(0.8)
                        
 // 近景层
                        StarLayer(count: 40, baseSize: 2.8, speed: 1.2, twinkleSpeed: 2.5, time: time, colorTint: .white)
                            .blendMode(.plusLighter)
                        
 // 5. 优化的流星层
                        EnhancedMeteorLayer(time: time)
                    }
                    .onChange(of: timeline.date) { oldDate, newDate in
                        let delta = newDate.timeIntervalSince(oldDate)
                        time += delta
                    }
                }
            } else {
 // 暂停时显示最后一帧或静态背景（此处显示静态背景底色以避免黑屏，但通常 opacity 为 0）
                Color(red: 0.01, green: 0.01, blue: 0.08)
            }
        }
        .opacity(bgControl.backgroundOpacity)
        .ignoresSafeArea()
    }
    
 // 随机数生成器
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

// MARK: - 银河光辉层
private struct GalaxyGlowLayer: View {
    let time: TimeInterval
    
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            
 // 绘制银河中心的辉光
 // 使用椭圆模拟银河带
            let centerRect = CGRect(
                x: -w * 0.2,
                y: h * 0.3,
                width: w * 1.4,
                height: h * 0.8
            )
            
 // 旋转银河
            context.translateBy(x: w/2, y: h/2)
            context.rotate(by: .degrees(-25))
            context.translateBy(x: -w/2, y: -h/2)
            
 // 动态透明度
            let opacity = 0.3 + 0.1 * sin(time * 0.3)
            context.opacity = opacity
            
            var glowContext = context
            glowContext.blendMode = .screen
            
 // 渐变填充
            let gradient = Gradient(stops: [
                .init(color: Color(red: 0.3, green: 0.1, blue: 0.5), location: 0),
                .init(color: Color(red: 0.1, green: 0.1, blue: 0.4), location: 0.5),
                .init(color: .clear, location: 1.0)
            ])
            
            glowContext.fill(
                Path(ellipseIn: centerRect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: w/2, y: h/2),
                    startRadius: 0,
                    endRadius: w * 0.8
                )
            )
        }
        .blur(radius: 60)
    }
}

// MARK: - 动态星云层
private struct NebulaLayer: View {
    let time: TimeInterval
    
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            
 // 绘制几个缓慢移动的大柔光团
            let blobs = [
                (color: Color.purple, x: 0.2, y: 0.3, r: 0.4, s: 0.05),
                (color: Color.blue,   x: 0.8, y: 0.7, r: 0.5, s: 0.04),
                (color: Color.cyan,   x: 0.5, y: 0.5, r: 0.3, s: 0.06),
                (color: Color.indigo, x: 0.1, y: 0.8, r: 0.4, s: 0.03)
            ]
            
            for (i, blob) in blobs.enumerated() {
 // 简单的圆周运动
                let angle = time * blob.s + Double(i) * 2.0
                let offsetX = sin(angle) * w * 0.1
                let offsetY = cos(angle * 0.7) * h * 0.1
                
                let rect = CGRect(
                    x: (blob.x * w) + offsetX - (blob.r * w / 2),
                    y: (blob.y * h) + offsetY - (blob.r * w / 2),
                    width: blob.r * w,
                    height: blob.r * w
                )
                
 // 呼吸透明度
                let opacity = 0.3 + 0.2 * sin(time * 0.5 + Double(i))
                
                context.opacity = opacity
                var fillContext = context
                fillContext.blendMode = .plusLighter
                fillContext.fill(Path(ellipseIn: rect), with: .color(blob.color))
            }
        }
        .blur(radius: 80) // 强模糊融合
    }
}

// MARK: - 通用星星层
private struct StarLayer: View {
    let count: Int
    let baseSize: CGFloat
    let speed: Double
    let twinkleSpeed: Double
    let time: TimeInterval
    let colorTint: Color
    
    var body: some View {
        Canvas { context, size in
            let timeOffset = time * speed * 5.0 // 基础移动速度
            
            for i in 0..<count {
                var rng = StarryBackground.SeededRandom(seed: i * 100) // 独立的种子
                
                let x = rng.next() * size.width
                let y = rng.next() * size.height
                let sizeVar = rng.next(in: 0.7...1.3) * baseSize
                
 // 视差移动
 // x 随时间偏移，实现旋转或平移效果
 // 这里模拟简单的水平漂移
                let currentX = (x + timeOffset * rng.next(in: 0.8...1.2)).truncatingRemainder(dividingBy: size.width)
                let finalX = currentX < 0 ? currentX + size.width : currentX
                
 // 闪烁逻辑
                let individualTwinkleSpeed = rng.next(in: 0.5...1.5) * twinkleSpeed
                let phase = rng.next(in: 0...Double.pi * 2)
                let brightness = 0.5 + 0.5 * sin(time * individualTwinkleSpeed + phase)
                
 // 颜色微调
                let color: Color
                if colorTint == .white {
 // 随机微调白色，带一点点冷暖色
                    let tint = rng.next()
                    if tint < 0.2 { color = .blue.opacity(0.8) }
                    else if tint < 0.4 { color = .purple.opacity(0.8) }
                    else { color = .white }
                } else {
                    color = colorTint
                }
                
                let rect = CGRect(x: finalX, y: y, width: sizeVar, height: sizeVar)
                
                context.opacity = brightness
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
    }
}

// MARK: - 增强版流星层
private struct EnhancedMeteorLayer: View {
    let time: TimeInterval
    
    var body: some View {
        Canvas { context, size in
 // 定义流星出现的频率
            let cycle = 7.0
            let activeTime = 0.8 // 流星存活时间
            let t = time.remainder(dividingBy: cycle)
            
            if t < activeTime {
                let progress = t / activeTime
                let seed = Int(time / cycle)
                var rng = StarryBackground.SeededRandom(seed: seed)
                
 // 随机起始位置 (主要在右上方)
                let startX = rng.next(in: 0.4...0.9) * size.width
                let startY = rng.next(in: 0.0...0.5) * size.height
                
 // 随机角度 (向左下飞)
                let angle = rng.next(in: 110...160) * .pi / 180.0
                let length = rng.next(in: 200...400)
                
                let dx = cos(angle) * length
                let dy = sin(angle) * length
                
 // 当前头部位置
                let headX = startX + dx * progress
                let headY = startY + dy * progress
                
 // 拖尾路径
                var path = Path()
                path.move(to: CGPoint(x: headX, y: headY))
                path.addLine(to: CGPoint(x: headX - dx * 0.15, y: headY - dy * 0.15)) // 拖尾长度
                
 // 渐变拖尾
                let gradient = Gradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .blue.opacity(0.5), location: 0.4),
                    .init(color: .clear, location: 1.0)
                ])
                
                context.stroke(path, with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: headX, y: headY),
                    endPoint: CGPoint(x: headX - dx * 0.15, y: headY - dy * 0.15)
                ), lineWidth: 2.0)
                
 // 头部亮光
                let headRect = CGRect(x: headX - 1.5, y: headY - 1.5, width: 3, height: 3)
                
 // 头部光晕
                let glowRect = CGRect(x: headX - 4, y: headY - 4, width: 8, height: 8)
                context.opacity = 1.0 - progress // 整体淡出
                
                context.fill(Path(ellipseIn: glowRect), with: .color(.white.opacity(0.5)))
                context.fill(Path(ellipseIn: headRect), with: .color(.white))
            }
        }
    }
}
