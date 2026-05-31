//
// MenuBarIconGenerator.swift
// SkyBridgeUI
//
// Menu Bar App - Icon Generator for AppIcon-derived status images
// Requirements: 6.1, 6.2, 9.1
//

import AppKit
import Foundation

/// 菜单栏图标生成器 - 只从 bundled AppIcon.icns 渲染状态版本。
/// Requirements: 6.1, 6.2
@available(macOS 14.0, *)
public struct MenuBarIconGenerator {

    // MARK: - Icon Sizes

    /// 标准菜单栏图标尺寸
    public enum IconSize: CaseIterable {
        case small
        case medium
        case large

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

    /// 生成菜单栏图标。
    /// Requirements: 6.1, 6.2
    public static func generateMenuBarIcon(size: IconSize = .medium) -> NSImage {
        renderCanonicalAppIcon(size: size)
    }

    /// 生成带进度的图标。
    public static func generateProgressIcon(progress: Double, size: IconSize = .medium) -> NSImage {
        renderCanonicalAppIcon(size: size) { rect in
            let clampedProgress = min(max(progress, 0), 1)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - 2
            let lineWidth = size.lineWidth * 1.5

            let backgroundPath = NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            NSColor.systemGray.withAlphaComponent(0.3).setStroke()
            backgroundPath.lineWidth = lineWidth
            backgroundPath.stroke()

            let progressPath = NSBezierPath()
            progressPath.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - CGFloat(clampedProgress * 360),
                clockwise: true
            )

            NSColor.systemBlue.setStroke()
            progressPath.lineWidth = lineWidth
            progressPath.lineCapStyle = .round
            progressPath.stroke()
        }
    }

    /// 生成错误状态图标。
    public static func generateErrorIcon(size: IconSize = .medium) -> NSImage {
        renderCanonicalAppIcon(size: size) { rect in
            let dotDiameter: CGFloat = rect.width / 3.6
            let dotRect = NSRect(
                x: rect.maxX - dotDiameter,
                y: rect.minY,
                width: dotDiameter,
                height: dotDiameter
            )

            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    /// 生成扫描中图标。
    public static func generateScanningIcon(size: IconSize = .medium, phase: Int = 0) -> NSImage {
        renderCanonicalAppIcon(size: size) { rect in
            let dotDiameter: CGFloat = rect.width / 4.8
            let radians = CGFloat(phase % 12) * CGFloat.pi / 6
            let radius = min(rect.width, rect.height) / 2 - dotDiameter / 2
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let dotCenter = NSPoint(
                x: center.x + cos(radians) * radius,
                y: center.y + sin(radians) * radius
            )
            let dotRect = NSRect(
                x: dotCenter.x - dotDiameter / 2,
                y: dotCenter.y - dotDiameter / 2,
                width: dotDiameter,
                height: dotDiameter
            )

            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    private static func renderCanonicalAppIcon(
        size: IconSize,
        overlay: ((NSRect) -> Void)? = nil
    ) -> NSImage {
        guard let source = loadCanonicalAppIcon() else {
            preconditionFailure("Bundled AppIcon.icns is required for menu bar icon rendering")
        }

        let imageSize = size.size
        let rect = NSRect(origin: .zero, size: imageSize)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        source.draw(in: rect)
        overlay?(rect)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func loadCanonicalAppIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url),
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }

        return image
    }
}
