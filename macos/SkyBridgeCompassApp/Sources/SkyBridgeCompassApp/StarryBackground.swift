import SwiftUI

/// 美丽的星空背景组件
/// 使用SwiftUI的最新特性创建动态星空效果
struct StarryBackground: View {
    @State private var animationOffset: CGFloat = 0
    @State private var twinklePhase: Double = 0
    
    var body: some View {
        ZStack {
            // 深空渐变背景
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.15),  // 深蓝紫色
                    Color(red: 0.1, green: 0.05, blue: 0.2),    // 深紫色
                    Color(red: 0.15, green: 0.1, blue: 0.25),   // 紫色
                    Color(red: 0.08, green: 0.08, blue: 0.18)   // 深蓝色
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // 星云效果层
            RadialGradient(
                gradient: Gradient(colors: [
                    Color.purple.opacity(0.3),
                    Color.blue.opacity(0.2),
                    Color.clear
                ]),
                center: UnitPoint(x: 0.3, y: 0.2),
                startRadius: 50,
                endRadius: 300
            )
            .offset(x: animationOffset * 0.5, y: animationOffset * 0.3)
            
            // 另一个星云效果
            RadialGradient(
                gradient: Gradient(colors: [
                    Color.cyan.opacity(0.2),
                    Color.indigo.opacity(0.15),
                    Color.clear
                ]),
                center: UnitPoint(x: 0.7, y: 0.8),
                startRadius: 80,
                endRadius: 400
            )
            .offset(x: -animationOffset * 0.3, y: -animationOffset * 0.4)
            
            // 星星层
            ForEach(0..<150, id: \.self) { index in
                StarView(
                    position: generateStarPosition(for: index),
                    size: generateStarSize(for: index),
                    brightness: generateStarBrightness(for: index),
                    twinklePhase: twinklePhase
                )
            }
            
            // 流星效果
            ForEach(0..<3, id: \.self) { index in
                ShootingStarView(
                    startPosition: generateShootingStarStart(for: index),
                    endPosition: generateShootingStarEnd(for: index),
                    animationOffset: animationOffset
                )
            }
        }
        .ignoresSafeArea(.all)
        .onAppear {
            // 启动动画
            withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) {
                animationOffset = 100
            }
            
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                twinklePhase = 1.0
            }
        }
    }
    
    // 生成星星位置
    private func generateStarPosition(for index: Int) -> CGPoint {
        let seed = Double(index * 12345)
        let x = (seed.truncatingRemainder(dividingBy: 1000)) / 1000
        let y = ((seed * 1.618).truncatingRemainder(dividingBy: 1000)) / 1000
        return CGPoint(x: x, y: y)
    }
    
    // 生成星星大小
    private func generateStarSize(for index: Int) -> CGFloat {
        let seed = Double(index * 54321)
        let size = (seed.truncatingRemainder(dividingBy: 100)) / 100
        return CGFloat(0.5 + size * 2.5) // 0.5 到 3.0
    }
    
    // 生成星星亮度
    private func generateStarBrightness(for index: Int) -> Double {
        let seed = Double(index * 98765)
        let brightness = (seed.truncatingRemainder(dividingBy: 100)) / 100
        return 0.3 + brightness * 0.7 // 0.3 到 1.0
    }
    
    // 生成流星起始位置
    private func generateShootingStarStart(for index: Int) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: -50, y: 100)
        case 1: return CGPoint(x: -30, y: 300)
        default: return CGPoint(x: -70, y: 200)
        }
    }
    
    // 生成流星结束位置
    private func generateShootingStarEnd(for index: Int) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: 400, y: 250)
        case 1: return CGPoint(x: 450, y: 450)
        default: return CGPoint(x: 380, y: 350)
        }
    }
}

/// 星星视图
struct StarView: View {
    let position: CGPoint
    let size: CGFloat
    let brightness: Double
    let twinklePhase: Double
    
    var body: some View {
        GeometryReader { geometry in
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(brightness),
                            Color.blue.opacity(brightness * 0.8),
                            Color.clear
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: size
                    )
                )
                .frame(width: size, height: size)
                .opacity(brightness * (0.7 + 0.3 * sin(twinklePhase * .pi * 2 + Double(position.x * 10))))
                .position(
                    x: position.x * geometry.size.width,
                    y: position.y * geometry.size.height
                )
        }
    }
}

/// 流星视图
struct ShootingStarView: View {
    let startPosition: CGPoint
    let endPosition: CGPoint
    let animationOffset: CGFloat
    
    @State private var isVisible = false
    @State private var currentPosition: CGPoint = .zero
    
    var body: some View {
        if isVisible {
            Path { path in
                path.move(to: currentPosition)
                let tailLength: CGFloat = 30
                let direction = CGPoint(
                    x: endPosition.x - startPosition.x,
                    y: endPosition.y - startPosition.y
                )
                let length = sqrt(direction.x * direction.x + direction.y * direction.y)
                let normalizedDirection = CGPoint(
                    x: direction.x / length,
                    y: direction.y / length
                )
                let tailEnd = CGPoint(
                    x: currentPosition.x - normalizedDirection.x * tailLength,
                    y: currentPosition.y - normalizedDirection.y * tailLength
                )
                path.addLine(to: tailEnd)
            }
            .stroke(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0.9),
                        Color.cyan.opacity(0.6),
                        Color.clear
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 2
            )
            .shadow(color: .white, radius: 3)
        }
    }
    
    private func startShootingStarAnimation() {
        currentPosition = startPosition
        isVisible = true
        
        withAnimation(.easeOut(duration: 2.5)) {
            currentPosition = endPosition
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            isVisible = false
            // 随机延迟后重新开始
            let delay = Double.random(in: 5...15)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                startShootingStarAnimation()
            }
        }
    }
}

#Preview {
    StarryBackground()
}