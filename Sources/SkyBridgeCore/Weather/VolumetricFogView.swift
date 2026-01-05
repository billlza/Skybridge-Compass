//
// VolumetricFogView.swift
// SkyBridgeCore
//
// 体积雾效果 - 参考UE5体积雾渲染
// 使用多层Perlin噪声模拟真实雾气
// Created: 2025-10-19
//

import SwiftUI
import Accelerate

/// 体积雾视图 - UE风格真实雾效
@available(macOS 14.0, *)
public struct VolumetricFogView: View {
    let config: PerformanceConfiguration
    let intensity: Double
    let clearZones: [ClearZone]
    
    @State private var noiseOffset: Double = 0
    
    public init(config: PerformanceConfiguration, intensity: Double = 0.5, clearZones: [ClearZone] = []) {
        self.config = config
        self.intensity = intensity
        self.clearZones = clearZones
    }
    
    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                
 // 多层体积雾（3-5层）
                let layerCount = max(3, config.shadowQuality + 2)
                
                for layer in 0..<layerCount {
                    drawVolumetricLayer(
                        context: context,
                        size: size,
                        time: time,
                        layer: layer,
                        totalLayers: layerCount
                    )
                }
            }
        }
    }
    
    private func drawVolumetricLayer(context: GraphicsContext, size: CGSize, time: Double, layer: Int, totalLayers: Int) {
        let depth = Double(layer) / Double(totalLayers)
        
 // 每层不同的滚动速度（parallax）
        let scrollSpeed = 5.0 + depth * 10.0
        let offset = (time * scrollSpeed).truncatingRemainder(dividingBy: Double(size.width))
        
 // Perlin噪声参数
        let noiseScale = 0.003 - depth * 0.001 // 远处雾气更大尺度
        let noiseSpeed = 0.1 + depth * 0.2
        
 // 雾气密度（基于深度）
        let baseDensity = intensity * (0.4 - depth * 0.15)
        
 // 使用小方块采样模拟体积雾
 // 根据渲染配置自适应采样步长，既保真又降算力
        let baseGrid: CGFloat
        switch config.postProcessingLevel {
        case 2: baseGrid = 20  // 极致
        case 1: baseGrid = 24  // 平衡
        default: baseGrid = 32 // 节能
        }
        var gridSize: CGFloat = baseGrid
 // 低帧率目标或GPU频率较低时，进一步稀疏采样
        if config.targetFrameRate <= 30 || config.gpuFrequencyHint < 0.6 {
            gridSize += 4
        }
        
        for x in stride(from: 0, to: size.width, by: gridSize) {
            for y in stride(from: 0, to: size.height, by: gridSize) {
 // Perlin噪声采样
                let noiseX = (Double(x) + offset) * noiseScale
                let noiseY = Double(y) * noiseScale
                let noiseT = time * noiseSpeed + Double(layer) * 0.5
                
                let noiseValue = perlinNoise3D(x: noiseX, y: noiseY, z: noiseT)
                
 // 雾气密度（0-1）
                var density = baseDensity * (0.5 + noiseValue * 0.5)
                
 // 检查清除区域（屏幕像素坐标）
 // 非命中不做 sqrt，命中后再计算，显著降低计算量
                for zone in clearZones {
                    let dx: CGFloat = x - zone.center.x
                    let dy: CGFloat = y - zone.center.y
                    let safeRadius: CGFloat = max(CGFloat(zone.currentRadius), 12)
                    let r2: CGFloat = safeRadius * safeRadius
                    let d2: CGFloat = dx * dx + dy * dy
                    if d2 < r2 {
                        let dist: CGFloat = sqrt(d2)
                        let fadeOut: Double = Double(dist / safeRadius)
                        density *= fadeOut
                    }
                }
                
 // 垂直渐变（雾气在地面更浓）
                let verticalFade = 1.0 - (Double(y) / Double(size.height)) * 0.3
                density *= verticalFade
                
 // 绘制雾气块
                if density > 0.05 {
                    let rect = CGRect(x: x, y: y, width: gridSize, height: gridSize)
                    
 // 雾气颜色（带轻微蓝灰色调）
                    let fogColor = Color(
                        red: 0.75 + depth * 0.1,
                        green: 0.78 + depth * 0.08,
                        blue: 0.82 + depth * 0.05
                    ).opacity(density)
                    
                    context.fill(Path(rect), with: .color(fogColor))
                }
            }
        }
    }
    
 /// 简化的3D Perlin噪声
    private func perlinNoise3D(x: Double, y: Double, z: Double) -> Double {
 // 使用正弦函数组合模拟Perlin噪声
        let n1 = sin(x * 1.0 + z * 0.5) * cos(y * 1.0 + z * 0.3)
        let n2 = sin(x * 2.3 - z * 0.7) * cos(y * 1.7 - z * 0.5)
        let n3 = sin(x * 4.1 + z * 1.1) * cos(y * 3.9 + z * 0.9)
        
 // 多频率叠加
        return (n1 + n2 * 0.5 + n3 * 0.25) / 1.75
    }
}
