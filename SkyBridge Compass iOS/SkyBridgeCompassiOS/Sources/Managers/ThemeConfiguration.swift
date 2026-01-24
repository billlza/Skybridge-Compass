import Foundation
import SwiftUI

/// 主题配置管理器
@MainActor
public class ThemeConfiguration: ObservableObject {
    public static let instance = ThemeConfiguration()
    
    private enum Keys {
        static let darkMode = "theme_dark_mode"
        static let accentColor = "theme_accent_color"
    }
    
    @Published public var isDarkMode: Bool = true {
        didSet {
            UserDefaults.standard.set(isDarkMode, forKey: Keys.darkMode)
        }
    }
    
    @Published public var accentColor: Color = .blue {
        didSet {
            saveAccentColor()
        }
    }
    
    private init() {
        isDarkMode = UserDefaults.standard.bool(forKey: Keys.darkMode)
        loadAccentColor()
    }
    
    private func saveAccentColor() {
        // iOS 26.2 上 UIColor(Color) 可能触发 “out of range” 警告；这里完全避开 UIKit bridge。
        // 使用 SwiftUI 的 resolve(in:) 得到稳定的 0...1 RGBA。
        let resolved = accentColor.resolve(in: EnvironmentValues())
        let r = Double(Self.clamp01(CGFloat(resolved.red)))
        let g = Double(Self.clamp01(CGFloat(resolved.green)))
        let b = Double(Self.clamp01(CGFloat(resolved.blue)))
        let a = Double(Self.clamp01(CGFloat(resolved.opacity)))
        UserDefaults.standard.set([r, g, b, a], forKey: Keys.accentColor)
    }
    
    private func loadAccentColor() {
        guard let anyArray = UserDefaults.standard.array(forKey: Keys.accentColor) else {
            return
        }
        
        // UserDefaults 数字通常是 Double/NSNumber，不能直接 cast 到 CGFloat。
        var raw: [Double] = []
        raw.reserveCapacity(anyArray.count)
        for v in anyArray {
            if let d = v as? Double {
                raw.append(d)
            } else if let n = v as? NSNumber {
                raw.append(n.doubleValue)
            }
        }
        guard !raw.isEmpty else { return }

        // 兼容旧格式（RGB）与新格式（RGBA）
        var r = raw[safe: 0] ?? 0.0
        var g = raw[safe: 1] ?? 0.48
        var b = raw[safe: 2] ?? 1.0
        var a = raw[safe: 3] ?? 1.0

        // 兼容迁移：如果曾经错误地以 0...255 保存，自动归一化到 0...1
        if max(r, g, b, a) > 1.01, max(r, g, b, a) <= 255.0 {
            r /= 255.0
            g /= 255.0
            b /= 255.0
            a /= 255.0
        }

        let rr = Self.clamp01(CGFloat(r))
        let gg = Self.clamp01(CGFloat(g))
        let bb = Self.clamp01(CGFloat(b))
        let aa = Self.clamp01(CGFloat(a))

        accentColor = Color(.sRGB, red: rr, green: gg, blue: bb, opacity: aa)
    }

    private static func clamp01(_ x: CGFloat) -> CGFloat {
        if x.isNaN || x.isInfinite { return 0 }
        return min(1, max(0, x))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
