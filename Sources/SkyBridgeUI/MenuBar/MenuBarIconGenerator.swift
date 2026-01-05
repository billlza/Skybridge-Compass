//
// MenuBarIconGenerator.swift
// SkyBridgeUI
//
// Menu Bar App - Icon Generator for Template Images
// Requirements: 6.1, 6.2, 9.1
//

import AppKit
import Foundation

/// 菜单栏图标生成器 - 生成模板图标
/// Requirements: 6.1, 6.2
@available(macOS 14.0, *)
public struct MenuBarIconGenerator {
    
 // MARK: - Icon Sizes
    
 /// 标准菜单栏图标尺寸
    public enum IconSize: CaseIterable {
        case small      // 16x16
        case medium     // 18x18
        case large      // 22x22
        
        var size: NSSize {
            switch self {
            case .small: return NSSize(width: 16, height: 16)
            case .medium: return NSSize(width: 18, height: 18)
            case .large: return NSSize(width: 22, height: 22)
            }
        }
        
        var lineWidth: CGFloat {
            switch self {
            case .small: return 1.0
            case .medium: return 1.2
            case .large: return 1.5
            }
        }
    }
    
 // MARK: - Public Methods
    
 /// 生成菜单栏图标（天线信号样式）
 /// Requirements: 6.1, 6.2
    public static func generateMenuBarIcon(size: IconSize = .medium) -> NSImage {
        let imageSize = size.size
        let image = NSImage(size: imageSize)
        
        image.lockFocus()
        
 // 使用黑色绘制（模板图像会自动适应深色/浅色模式）
        NSColor.black.setStroke()
        NSColor.black.setFill()
        
        let centerX = imageSize.width / 2
        let centerY = imageSize.height / 2
        let lineWidth = size.lineWidth
        
 // 绘制中心点
        let dotRadius: CGFloat = lineWidth * 1.2
        let dotRect = NSRect(
            x: centerX - dotRadius,
            y: centerY - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        let dotPath = NSBezierPath(ovalIn: dotRect)
        dotPath.fill()
        
 // 绘制信号波纹（3层）
        for i in 1...3 {
            let radius = CGFloat(i) * (imageSize.width / 8)
            let arcPath = NSBezierPath()
            
 // 左侧弧线
            arcPath.appendArc(
                withCenter: NSPoint(x: centerX, y: centerY),
                radius: radius,
                startAngle: 135,
                endAngle: 225,
                clockwise: false
            )
            
            arcPath.lineWidth = lineWidth
            arcPath.lineCapStyle = .round
            arcPath.stroke()
            
 // 右侧弧线
            let rightArcPath = NSBezierPath()
            rightArcPath.appendArc(
                withCenter: NSPoint(x: centerX, y: centerY),
                radius: radius,
                startAngle: -45,
                endAngle: 45,
                clockwise: false
            )
            
            rightArcPath.lineWidth = lineWidth
            rightArcPath.lineCapStyle = .round
            rightArcPath.stroke()
        }
        
        image.unlockFocus()
        
 // 设置为模板图像
        image.isTemplate = true
        
        return image
    }
    
 /// 生成带进度的图标
    public static func generateProgressIcon(progress: Double, size: IconSize = .medium) -> NSImage {
        let imageSize = size.size
        let image = NSImage(size: imageSize)
        
        image.lockFocus()
        
        let centerX = imageSize.width / 2
        let centerY = imageSize.height / 2
        let radius = min(imageSize.width, imageSize.height) / 2 - 2
        let lineWidth = size.lineWidth * 1.5
        
 // 绘制背景圆环
        let backgroundPath = NSBezierPath(
            ovalIn: NSRect(
                x: centerX - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        NSColor.systemGray.withAlphaComponent(0.3).setStroke()
        backgroundPath.lineWidth = lineWidth
        backgroundPath.stroke()
        
 // 绘制进度圆弧
        let progressPath = NSBezierPath()
        let startAngle: CGFloat = 90
        let endAngle: CGFloat = 90 - CGFloat(progress * 360)
        
        progressPath.appendArc(
            withCenter: NSPoint(x: centerX, y: centerY),
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        
        NSColor.systemBlue.setStroke()
        progressPath.lineWidth = lineWidth
        progressPath.lineCapStyle = .round
        progressPath.stroke()
        
        image.unlockFocus()
        
 // 进度图标不使用模板模式，保持彩色
        image.isTemplate = false
        
        return image
    }
    
 /// 生成错误状态图标
    public static func generateErrorIcon(size: IconSize = .medium) -> NSImage {
        let imageSize = size.size
        let image = NSImage(size: imageSize)
        
        image.lockFocus()
        
 // 绘制基础图标
        let baseIcon = generateMenuBarIcon(size: size)
        baseIcon.draw(in: NSRect(origin: .zero, size: imageSize))
        
 // 绘制红色错误点
        let dotRadius: CGFloat = imageSize.width / 5
        let dotRect = NSRect(
            x: imageSize.width - dotRadius * 1.5,
            y: 0,
            width: dotRadius * 1.5,
            height: dotRadius * 1.5
        )
        
        NSColor.systemRed.setFill()
        let dotPath = NSBezierPath(ovalIn: dotRect)
        dotPath.fill()
        
        image.unlockFocus()
        
 // 错误图标不使用模板模式
        image.isTemplate = false
        
        return image
    }
    
 /// 生成扫描中图标（带动画效果的基础）
    public static func generateScanningIcon(size: IconSize = .medium, phase: Int = 0) -> NSImage {
        let imageSize = size.size
        let image = NSImage(size: imageSize)
        
        image.lockFocus()
        
        NSColor.black.setStroke()
        NSColor.black.setFill()
        
        let centerX = imageSize.width / 2
        let centerY = imageSize.height / 2
        let lineWidth = size.lineWidth
        
 // 绘制中心点
        let dotRadius: CGFloat = lineWidth * 1.2
        let dotRect = NSRect(
            x: centerX - dotRadius,
            y: centerY - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        let dotPath = NSBezierPath(ovalIn: dotRect)
        dotPath.fill()
        
 // 绘制旋转的信号波纹
        let rotationAngle = CGFloat(phase) * 30 // 每个相位旋转30度
        
        for i in 1...3 {
            let radius = CGFloat(i) * (imageSize.width / 8)
            let alpha = CGFloat(4 - i) / 4.0 // 外层更透明
            
            NSColor.black.withAlphaComponent(alpha).setStroke()
            
 // 旋转的弧线
            let arcPath = NSBezierPath()
            arcPath.appendArc(
                withCenter: NSPoint(x: centerX, y: centerY),
                radius: radius,
                startAngle: 135 + rotationAngle,
                endAngle: 225 + rotationAngle,
                clockwise: false
            )
            
            arcPath.lineWidth = lineWidth
            arcPath.lineCapStyle = .round
            arcPath.stroke()
            
            let rightArcPath = NSBezierPath()
            rightArcPath.appendArc(
                withCenter: NSPoint(x: centerX, y: centerY),
                radius: radius,
                startAngle: -45 + rotationAngle,
                endAngle: 45 + rotationAngle,
                clockwise: false
            )
            
            rightArcPath.lineWidth = lineWidth
            rightArcPath.lineCapStyle = .round
            rightArcPath.stroke()
        }
        
        image.unlockFocus()
        
        image.isTemplate = true
        
        return image
    }
}
