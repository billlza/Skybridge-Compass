import SwiftUI
import SkyBridgeCore

/// 经典模式背景组件 (Enhanced Canvas Version)
/// 采用 Canvas 渲染的动态流体渐变风格，支持性能模式调节与交互控制。
/// 使用多个高斯模糊的圆形光斑在背景中缓慢游动，创造出深邃且富有质感的专业背景。
struct ClassicBackgroundV2: View {
    let weather: WeatherInfo?
    
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject var bgControl = BackgroundControlManager.shared
    
    @State private var time: TimeInterval = 0
    
    var body: some View {
        Group {
            if !bgControl.isPaused {
                TimelineView(.periodic(from: .now, by: 1.0 / settingsManager.performanceMode.targetFPS)) { timeline in
                    ZStack {
 // 1. 深色底色
                        Color(red: 0.05, green: 0.08, blue: 0.15)
                            .ignoresSafeArea()
                        
 // 2. 动态光斑层 (Canvas渲染)
                        FluidGradientLayer(time: time)
                            .blendMode(.screen)
                            .opacity(0.8)
                        
 // 3. 磨砂玻璃质感叠加
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .opacity(0.3)
                            .blendMode(.overlay)
                            .ignoresSafeArea()
                        
 // 4. 微弱的网格纹理 (增加科技感)
                        GridPattern()
                            .stroke(Color.white.opacity(0.03), lineWidth: 1)
                            .ignoresSafeArea()
                    }
                    .onChange(of: timeline.date) { oldDate, newDate in
                        let delta = newDate.timeIntervalSince(oldDate)
                        time += delta
                    }
                }
            } else {
 // 暂停时显示静态背景
                ZStack {
                    Color(red: 0.05, green: 0.08, blue: 0.15)
                        .ignoresSafeArea()
                    
                    FluidGradientLayer(time: time)
                        .blendMode(.screen)
                        .opacity(0.8)
                    
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.3)
                        .blendMode(.overlay)
                        .ignoresSafeArea()
                    
                    GridPattern()
                        .stroke(Color.white.opacity(0.03), lineWidth: 1)
                        .ignoresSafeArea()
                }
            }
        }
        .opacity(bgControl.backgroundOpacity)
        .ignoresSafeArea()
    }
}

// MARK: - 动态流体渐变层 (Canvas)
struct FluidGradientLayer: View {
    let time: TimeInterval
    
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let minDim = min(width, height)
            
 // 定义光斑参数
            struct Blob {
                let color: Color
                let xSeed: Double
                let ySeed: Double
                let sizeScale: Double
                let speed: Double
            }
            
            let blobs = [
                Blob(color: Color(red: 0.1, green: 0.3, blue: 0.8), xSeed: 123.4, ySeed: 567.8, sizeScale: 0.8, speed: 0.2),
                Blob(color: Color(red: 0.4, green: 0.1, blue: 0.7), xSeed: 234.5, ySeed: 678.9, sizeScale: 0.7, speed: 0.15),
                Blob(color: Color(red: 0.1, green: 0.5, blue: 0.6), xSeed: 345.6, ySeed: 789.0, sizeScale: 0.6, speed: 0.25),
                Blob(color: Color(red: 0.8, green: 0.2, blue: 0.5), xSeed: 456.7, ySeed: 890.1, sizeScale: 0.5, speed: 0.18) // 新增一个洋红色光斑
            ]
            
            for blob in blobs {
 // 计算位置 (0...1)
                let xProgress = (sin(time * blob.speed + blob.xSeed) + 1) / 2
                let yProgress = (cos(time * blob.speed * 0.8 + blob.ySeed) + 1) / 2
                
 // 映射到屏幕坐标 (考虑边缘留白，避免光斑完全跑出去)
                let x = width * 0.1 + xProgress * width * 0.8
                let y = height * 0.1 + yProgress * height * 0.8
                
                let blobSize = minDim * blob.sizeScale
                
 // 绘制
                var path = Path()
                path.addEllipse(in: CGRect(x: x - blobSize/2, y: y - blobSize/2, width: blobSize, height: blobSize))
                
                context.fill(path, with: .color(blob.color))
            }
            
 // 全局模糊处理 - 在Canvas内部无法直接应用全局模糊滤镜到已绘制内容，
 // 但我们可以绘制模糊的形状。
 // 为了获得更好的流体融合效果，我们可以在View层级应用blur，或者在这里使用大量重叠的半透明圆。
 // 鉴于Canvas的性能，我们可以依靠SwiftUI的 .blur() 修饰符在View层级处理融合，
 // 或者使用 graphicsContext.addFilter(.blur(...)) 如果支持 (SwiftUI Canvas Context filters support is limited).
 // context.addFilter(.blur(radius: 80)) // SwiftUI 3.0+ 支持
            
        }
        .blur(radius: 80) // 在 View 层级应用强模糊以融合光斑
    }
}

// MARK: - 网格纹理
private struct GridPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 40
        
        for x in stride(from: 0, to: rect.width, by: spacing) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: rect.height))
        }
        
        for y in stride(from: 0, to: rect.height, by: spacing) {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
        }
        
        return path
    }
}
