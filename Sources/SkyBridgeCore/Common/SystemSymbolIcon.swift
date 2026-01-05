import SwiftUI
import AppKit
import os.log

/// 通用系统符号视图：在 macOS 14+ 上优先显示目标 SF Symbol，
/// 若符号在当前系统不可用则回退到更通用的替代符号，避免出现图标缺失。
/// - 说明：为解决蓝牙图标在部分页面不显示的问题而设计，
/// 保持一致的图标呈现并减少 UI 不一致。
@available(macOS 14.0, *)
public struct SystemSymbolIcon: View {
 /// 目标符号名称（例如："bluetooth"、"wifi"）
    public let name: String
 /// 可选颜色（不传则跟随环境）
    public var color: Color?
 /// 可选尺寸设置（不传则跟随环境字体与布局）
    public var size: CGFloat?
 /// 可选字体粗细，用于保持与既有 UI 一致的视觉权重
    public var weight: Font.Weight?
 /// 日志记录器（用于诊断符号解析问题）
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SystemSymbolIcon")

 /// 初始化方法
 /// - Parameters:
 /// - name: 目标符号名称
 /// - color: 颜色（可选）
 /// - size: 字体大小（可选），用于统一控制图标大小
 /// - weight: 字体粗细（可选），用于保持图标视觉权重一致
    public init(name: String, color: Color? = nil, size: CGFloat? = nil, weight: Font.Weight? = nil) {
        self.name = name
        self.color = color
        self.size = size
        self.weight = weight
    }

    public var body: some View {
 // 说明：避免 ResultBuilder 推断歧义，将视图以 AnyView 形式汇总返回，
 // 规避在 TableColumnBuilder 等场景中的泛型推断问题。
        let baseView: AnyView

        if name.hasPrefix("bluetooth") &&
            NSImage(systemSymbolName: "bluetooth", accessibilityDescription: nil) == nil &&
            NSImage(systemSymbolName: "bluetooth.circle", accessibilityDescription: nil) == nil &&
            NSImage(systemSymbolName: "bluetooth.circle.fill", accessibilityDescription: nil) == nil {
 // 优先尝试使用 AppKit 的蓝牙模板图标（受苹果支持的系统资源）
 // 注意：`NSImage.Name.bluetoothTemplate` 在当前 SDK 不存在，使用旧常量名称确保兼容性
            if let legacyBT = NSImage(named: NSImage.bluetoothTemplateName) {
                baseView = AnyView(
                    Image(nsImage: legacyBT)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size ?? 16, height: size ?? 16)
                        .onAppear {
                            logger.error("SF Symbols 中的蓝牙符号不可用，使用 AppKit 蓝牙模板图标回退（NSImage.bluetoothTemplateName）")
                        }
                )
            } else if let legacyBT2 = NSImage(named: NSImage.Name("NSBluetoothTemplate")) { // 兼容字符串名称
                baseView = AnyView(
                    Image(nsImage: legacyBT2)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size ?? 16, height: size ?? 16)
                        .onAppear {
                            logger.error("旧常量 NSImageNameBluetoothTemplate 不可用，尝试字符串名称 NSBluetoothTemplate 回退")
                        }
                )
            } else {
                logger.fault("蓝牙图标所有回退均失败，回退至 questionmark.circle 占位符")
                baseView = AnyView(
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: size ?? 16, weight: weight ?? .regular))
                )
            }
        } else {
 // 常规路径：解析 SF Symbols 名称，使用同族回退保障显示
            let resolved = resolvedSymbolName(for: name)
            baseView = AnyView(Image(systemName: resolved))
        }

        return baseView
            .foregroundColor(color)
 // 使用可选的字体大小与粗细，保证与既有界面风格一致
            .font(size.map { .system(size: $0, weight: weight ?? .regular) })
            .accessibilityLabel(Text(name))
    }

 /// 根据目标符号名称进行可用性检测与回退映射
 /// - 注意：仅使用 Apple 发布且在 macOS 14+ 上广泛可用的替代符号，避免不兼容。
    private func resolvedSymbolName(for original: String) -> String {
 // 若系统存在该符号则直接使用
        if NSImage(systemSymbolName: original, accessibilityDescription: nil) != nil {
 // 记录蓝牙符号的直接解析成功，便于定位环境问题
            if original == "bluetooth" {
                logger.debug("蓝牙符号已由系统直接解析为 bluetooth")
            }
            return original
        }

 // 按类别提供稳健回退，保证功能语义接近
        switch original {
        case "bluetooth":
 // 蓝牙符号在极少数环境下可能因 SF Symbols 索引异常导致不可用，
 // 此处提供仅限“蓝牙家族”的回退，避免误用 Wi‑Fi/电波图标：
            if NSImage(systemSymbolName: "bluetooth.circle", accessibilityDescription: nil) != nil {
                logger.debug("蓝牙符号不可用，回退至 bluetooth.circle")
                return "bluetooth.circle"
            }
            if NSImage(systemSymbolName: "bluetooth.circle.fill", accessibilityDescription: nil) != nil {
                logger.debug("蓝牙符号不可用，回退至 bluetooth.circle.fill")
                return "bluetooth.circle.fill"
            }
 // 最终占位，提示符号缺失（不再使用电波类图标）
            logger.error("蓝牙符号不可用，回退至 questionmark.circle")
            return "questionmark.circle"
        case "wifi":
            return "wifi"
        case "location":
            return "location"
        case "network":
 // 若不存在 "network"，回退到链路连接图标以表达网络配置含义
            return "point.topleft.down.curvedto.point.bottomright.up"
        case "gearshape":
            return "gearshape"
        default:
 // 最后兜底，避免出现空白图标
            return "questionmark.circle"
        }
    }
}