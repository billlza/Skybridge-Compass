import Foundation
import AppKit
import OSLog

/// 可访问性管理器 - 提供无障碍功能支持
/// 遵循Apple无障碍最佳实践和WCAG 2.1 AA标准
@MainActor
public final class AccessibilityManager: BaseManager {
    
 // MARK: - 发布属性
    
    @Published public private(set) var isVoiceOverEnabled: Bool = false
    @Published public private(set) var isReduceMotionEnabled: Bool = false
    @Published public private(set) var isIncreaseContrastEnabled: Bool = false
    @Published public private(set) var isReduceTransparencyEnabled: Bool = false
    @Published public private(set) var isDifferentiateWithoutColorEnabled: Bool = false
    @Published public private(set) var currentColorScheme: AccessibilityColorScheme = .system
    @Published public private(set) var currentFontSize: AccessibilityFontSize = .medium
    
 // MARK: - 私有属性
    
    private var accessibilityObservers: [NSObjectProtocol] = []
    private let notificationCenter = NSWorkspace.shared.notificationCenter
    
 // 可访问性配置
    private var accessibilitySettings = AccessibilitySettings()
    
 // MARK: - 初始化
    
    public init() {
        super.init(category: "AccessibilityManager")
        logger.info("♿ 可访问性管理器初始化完成")
    }
    
 // MARK: - BaseManager重写方法
    
    override public func performInitialization() async {
        await super.performInitialization()
        setupAccessibilityMonitoring()
        updateAccessibilityStatus()
    }
    
    override public func performStart() async throws {
        try await super.performStart()
        startAccessibilityMonitoring()
    }
    
    override public func performStop() async {
        await super.performStop()
        stopAccessibilityMonitoring()
    }
    
    override public func cleanup() {
        super.cleanup()
        removeAccessibilityObservers()
    }
    
 // MARK: - 公共方法
    
 /// 配置视图的可访问性属性
 /// - Parameters:
 /// - view: 要配置的视图
 /// - label: 可访问性标签
 /// - hint: 可访问性提示
 /// - role: 可访问性角色
    public func configureAccessibility(
        for view: NSView,
        label: String,
        hint: String? = nil,
        role: NSAccessibility.Role? = nil
    ) {
        view.setAccessibilityLabel(label)
        
        if let hint = hint {
            view.setAccessibilityHelp(hint)
        }
        
        if let role = role {
            view.setAccessibilityRole(role)
        }
        
 // 确保视图可被辅助技术访问
        view.setAccessibilityElement(true)
        
        logger.debug("♿ 已配置视图可访问性: \(label)")
    }
    
 /// 配置按钮的可访问性
 /// - Parameters:
 /// - button: 要配置的按钮
 /// - label: 按钮标签
 /// - hint: 操作提示
    public func configureButtonAccessibility(
        for button: NSButton,
        label: String,
        hint: String? = nil
    ) {
        configureAccessibility(
            for: button,
            label: label,
            hint: hint ?? "双击执行操作",
            role: .button
        )
        
 // 设置按钮状态
        button.setAccessibilityEnabled(button.isEnabled)
    }
    
 /// 配置文本字段的可访问性
 /// - Parameters:
 /// - textField: 要配置的文本字段
 /// - label: 字段标签
 /// - placeholder: 占位符文本
    public func configureTextFieldAccessibility(
        for textField: NSTextField,
        label: String,
        placeholder: String? = nil
    ) {
 // 文本字段的占位符不应作为无障碍提示（hint）。
 // hint 应描述操作或用途，避免与占位内容混淆，因此此处不设置 hint。
        configureAccessibility(
            for: textField,
            label: label,
            hint: nil,
            role: .textField
        )
        
 // 设置占位符
        if let placeholder = placeholder {
            textField.placeholderString = placeholder
        }
    }
    
 /// 配置表格视图的可访问性
 /// - Parameters:
 /// - tableView: 要配置的表格视图
 /// - label: 表格标签
 /// - description: 表格描述
    public func configureTableViewAccessibility(
        for tableView: NSTableView,
        label: String,
        description: String? = nil
    ) {
        configureAccessibility(
            for: tableView,
            label: label,
            hint: description,
            role: .table
        )
        
 // 遍历表格列并设置无障碍标签
        for column in tableView.tableColumns {
            let headerCell = column.headerCell
            headerCell.setAccessibilityLabel(headerCell.stringValue)
        }
    }
    
 /// 获取适合当前可访问性设置的颜色
 /// - Parameters:
 /// - baseColor: 基础颜色
 /// - contrastColor: 高对比度颜色
 /// - Returns: 适合的颜色
    public func getAccessibleColor(
        baseColor: NSColor,
        contrastColor: NSColor? = nil
    ) -> NSColor {
        if isIncreaseContrastEnabled, let contrastColor = contrastColor {
            return contrastColor
        }
        
 // 根据色彩方案调整
        switch currentColorScheme {
        case .light:
            return baseColor
        case .dark:
            return baseColor.withSystemEffect(.deepPressed)
        case .system:
            return baseColor
        }
    }
    
 /// 获取适合当前可访问性设置的字体大小
 /// - Parameter baseSize: 基础字体大小
 /// - Returns: 调整后的字体大小
    public func getAccessibleFontSize(baseSize: CGFloat) -> CGFloat {
        let multiplier = currentFontSize.multiplier
        return baseSize * multiplier
    }
    
 /// 创建可访问的动画
 /// - Parameters:
 /// - duration: 动画时长
 /// - animations: 动画闭包
 /// - Returns: 调整后的动画时长
    public func createAccessibleAnimation(
        duration: TimeInterval,
        animations: @escaping () -> Void
    ) -> TimeInterval {
        let adjustedDuration = isReduceMotionEnabled ? 0.0 : duration
        
        if adjustedDuration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = adjustedDuration
                context.allowsImplicitAnimation = true
                animations()
            }
        } else {
 // 如果禁用动画，直接执行
            animations()
        }
        
        return adjustedDuration
    }
    
 /// 发布可访问性通知
 /// - Parameters:
 /// - notification: 通知类型
 /// - element: 相关元素
 /// - userInfo: 附加信息
    public func postAccessibilityNotification(
        _ notification: NSAccessibility.Notification,
        for element: Any? = nil,
        userInfo: [NSAccessibility.NotificationUserInfoKey: Any]? = nil
    ) {
        NSAccessibility.post(
            element: element ?? (NSApp as Any),
            notification: notification,
            userInfo: userInfo
        )
        
        logger.debug("♿ 已发布可访问性通知: \(notification.rawValue)")
    }
    
 /// 检查颜色对比度是否符合WCAG标准
 /// - Parameters:
 /// - foregroundColor: 前景色
 /// - backgroundColor: 背景色
 /// - Returns: 对比度比值
    public func calculateColorContrast(
        foregroundColor: NSColor,
        backgroundColor: NSColor
    ) -> Double {
        let foregroundLuminance = calculateRelativeLuminance(foregroundColor)
        let backgroundLuminance = calculateRelativeLuminance(backgroundColor)
        
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        
        return (lighter + 0.05) / (darker + 0.05)
    }
    
 /// 验证颜色对比度是否符合WCAG AA标准
 /// - Parameters:
 /// - foregroundColor: 前景色
 /// - backgroundColor: 背景色
 /// - isLargeText: 是否为大文本
 /// - Returns: 是否符合标准
    public func validateColorContrast(
        foregroundColor: NSColor,
        backgroundColor: NSColor,
        isLargeText: Bool = false
    ) -> Bool {
        let contrast = calculateColorContrast(
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor
        )
        
        let requiredContrast: Double = isLargeText ? 3.0 : 4.5
        return contrast >= requiredContrast
    }
    
 // MARK: - 私有方法
    
 /// 设置可访问性监控
    private func setupAccessibilityMonitoring() {
 // 监控VoiceOver状态变化
        let voiceOverObserver = notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateAccessibilityStatus()
            }
        }
        accessibilityObservers.append(voiceOverObserver)
        
        logger.debug("♿ 可访问性监控设置完成")
    }
    
 /// 开始可访问性监控
    private func startAccessibilityMonitoring() {
        updateAccessibilityStatus()
        logger.info("♿ 可访问性监控已启动")
    }
    
 /// 停止可访问性监控
    private func stopAccessibilityMonitoring() {
        removeAccessibilityObservers()
        logger.info("♿ 可访问性监控已停止")
    }
    
 /// 移除可访问性观察者
    private func removeAccessibilityObservers() {
        for observer in accessibilityObservers {
            notificationCenter.removeObserver(observer)
        }
        accessibilityObservers.removeAll()
    }
    
 /// 更新可访问性状态
    private func updateAccessibilityStatus() {
 // 检查VoiceOver状态
        isVoiceOverEnabled = NSWorkspace.shared.isVoiceOverEnabled
        
 // 检查减少动画设置
        isReduceMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        
 // 检查增强对比度设置
        isIncreaseContrastEnabled = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        
 // 检查减少透明度设置
        isReduceTransparencyEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        
 // 检查颜色区分设置
        isDifferentiateWithoutColorEnabled = NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        
 // 更新颜色方案
        updateColorScheme()
        
 // 更新字体大小
        updateFontSize()
        
        logger.debug("♿ 可访问性状态已更新")
    }
    
 /// 更新颜色方案
    private func updateColorScheme() {
        let appearance = NSApp.effectiveAppearance
        
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            currentColorScheme = .dark
        } else {
            currentColorScheme = .light
        }
    }
    
 /// 更新字体大小
    private func updateFontSize() {
 // 根据系统设置调整字体大小
 // 这里可以根据实际需求实现更复杂的逻辑
        currentFontSize = .medium
    }
    
 /// 计算相对亮度
 /// - Parameter color: 颜色
 /// - Returns: 相对亮度值
    private func calculateRelativeLuminance(_ color: NSColor) -> Double {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        
        let red = linearizeColorComponent(rgbColor.redComponent)
        let green = linearizeColorComponent(rgbColor.greenComponent)
        let blue = linearizeColorComponent(rgbColor.blueComponent)
        
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
    
 /// 线性化颜色分量
 /// - Parameter component: 颜色分量
 /// - Returns: 线性化后的值
    private func linearizeColorComponent(_ component: CGFloat) -> Double {
        let value = Double(component)
        
        if value <= 0.03928 {
            return value / 12.92
        } else {
            return pow((value + 0.055) / 1.055, 2.4)
        }
    }
}

// MARK: - 可访问性枚举和结构体

/// 可访问性颜色方案
public enum AccessibilityColorScheme: String, CaseIterable, Sendable {
    case light = "浅色"
    case dark = "深色"
    case system = "跟随系统"
}

/// 可访问性字体大小
public enum AccessibilityFontSize: String, CaseIterable, Sendable {
    case small = "小"
    case medium = "中"
    case large = "大"
    case extraLarge = "特大"
    
 /// 字体大小倍数
    var multiplier: CGFloat {
        switch self {
        case .small:
            return 0.85
        case .medium:
            return 1.0
        case .large:
            return 1.15
        case .extraLarge:
            return 1.3
        }
    }
}

/// 可访问性设置
public struct AccessibilitySettings: Sendable {
 /// 是否启用高对比度
    public var highContrastEnabled: Bool = false
    
 /// 是否启用大字体
    public var largeFontEnabled: Bool = false
    
 /// 是否启用减少动画
    public var reduceMotionEnabled: Bool = false
    
 /// 是否启用颜色区分
    public var differentiateWithoutColorEnabled: Bool = false
    
 /// 键盘导航延迟
    public var keyboardNavigationDelay: TimeInterval = 0.5
    
 /// 焦点指示器样式
    public var focusIndicatorStyle: FocusIndicatorStyle = .system
}

/// 焦点指示器样式
public enum FocusIndicatorStyle: String, CaseIterable, Sendable {
    case system = "系统默认"
    case highContrast = "高对比度"
    case colorful = "彩色"
    case minimal = "简约"
}