import Foundation
import AppKit
import OSLog

/// 键盘导航管理器 - 优化键盘操作体验
/// 提供全面的键盘导航支持和快捷键管理
@MainActor
public final class KeyboardNavigationManager: BaseManager {
    
 // MARK: - 发布属性
    
    @Published public private(set) var isKeyboardNavigationEnabled: Bool = true
    @Published public private(set) var currentFocusedElement: NSView?
    @Published public private(set) var focusRing: FocusRingStyle = .system
    @Published public private(set) var tabOrder: [NSView] = []
    
 // MARK: - 私有属性
    
    private var keyboardShortcuts: [KeyboardShortcut] = []
    private var focusableElements: [WeakViewReference] = []
    private var currentFocusIndex: Int = 0
    
 // 键盘事件监控
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    
 // 焦点环配置
    private var focusRingConfiguration = FocusRingConfiguration()
    
 // MARK: - 初始化
    
    public init() {
        super.init(category: "KeyboardNavigationManager")
        logger.info("⌨️ 键盘导航管理器初始化完成")
    }
    
 // MARK: - BaseManager重写方法
    
    override public func performInitialization() async {
        await super.performInitialization()
        setupKeyboardNavigation()
        setupDefaultShortcuts()
    }
    
    override public func performStart() async throws {
        try await super.performStart()
        startKeyboardMonitoring()
    }
    
    override public func performStop() async {
        await super.performStop()
        stopKeyboardMonitoring()
    }
    
    override public func cleanup() {
        super.cleanup()
        removeKeyboardMonitors()
        clearFocusableElements()
    }
    
 // MARK: - 公共方法
    
 /// 注册可聚焦元素
 /// - Parameters:
 /// - view: 要注册的视图
 /// - priority: 焦点优先级
 /// - customTabOrder: 自定义Tab顺序
    public func registerFocusableElement(
        _ view: NSView,
        priority: FocusPriority = .normal,
        customTabOrder: Int? = nil
    ) {
        let reference = WeakViewReference(
            view: view,
            priority: priority,
            customTabOrder: customTabOrder
        )
        
        focusableElements.append(reference)
        updateTabOrder()
        
 // 配置视图的键盘导航属性
        configureViewForKeyboardNavigation(view)
        
        logger.debug("⌨️ 已注册可聚焦元素: \(view.className)")
    }
    
 /// 注销可聚焦元素
 /// - Parameter view: 要注销的视图
    public func unregisterFocusableElement(_ view: NSView) {
        focusableElements.removeAll { $0.view === view }
        updateTabOrder()
        
        logger.debug("⌨️ 已注销可聚焦元素: \(view.className)")
    }
    
 /// 注册键盘快捷键
 /// - Parameter shortcut: 键盘快捷键
    public func registerKeyboardShortcut(_ shortcut: KeyboardShortcut) {
        keyboardShortcuts.append(shortcut)
        logger.debug("⌨️ 已注册键盘快捷键: \(shortcut.description)")
    }
    
 /// 注销键盘快捷键
 /// - Parameter identifier: 快捷键标识符
    public func unregisterKeyboardShortcut(identifier: String) {
        keyboardShortcuts.removeAll { $0.identifier == identifier }
        logger.debug("⌨️ 已注销键盘快捷键: \(identifier)")
    }
    
 /// 移动焦点到下一个元素
    public func focusNextElement() {
        guard !tabOrder.isEmpty else { return }
        
        currentFocusIndex = (currentFocusIndex + 1) % tabOrder.count
        let nextView = tabOrder[currentFocusIndex]
        
        setFocus(to: nextView)
    }
    
 /// 移动焦点到上一个元素
    public func focusPreviousElement() {
        guard !tabOrder.isEmpty else { return }
        
        currentFocusIndex = currentFocusIndex > 0 ? currentFocusIndex - 1 : tabOrder.count - 1
        let previousView = tabOrder[currentFocusIndex]
        
        setFocus(to: previousView)
    }
    
 /// 设置焦点到指定视图
 /// - Parameter view: 目标视图
    public func setFocus(to view: NSView) {
 // 移除当前焦点
        if let currentFocus = currentFocusedElement {
            removeFocusRing(from: currentFocus)
        }
        
 // 设置新焦点
        view.window?.makeFirstResponder(view)
        currentFocusedElement = view
        
 // 添加焦点环
        addFocusRing(to: view)
        
 // 确保视图可见
        scrollToVisible(view)
        
        logger.debug("⌨️ 焦点已设置到: \(view.className)")
    }
    
 /// 清除当前焦点
    public func clearFocus() {
        if let currentFocus = currentFocusedElement {
            removeFocusRing(from: currentFocus)
            currentFocusedElement = nil
        }
    }
    
 /// 配置焦点环样式
 /// - Parameter style: 焦点环样式
    public func configureFocusRing(_ style: FocusRingStyle) {
        focusRing = style
        updateFocusRingConfiguration()
        
 // 如果当前有焦点元素，更新其焦点环
        if let currentFocus = currentFocusedElement {
            removeFocusRing(from: currentFocus)
            addFocusRing(to: currentFocus)
        }
    }
    
 /// 启用/禁用键盘导航
 /// - Parameter enabled: 是否启用
    public func setKeyboardNavigationEnabled(_ enabled: Bool) {
        isKeyboardNavigationEnabled = enabled
        
        if enabled {
            startKeyboardMonitoring()
        } else {
            stopKeyboardMonitoring()
            clearFocus()
        }
        
        logger.info("⌨️ 键盘导航已\(enabled ? "启用" : "禁用")")
    }
    
 /// 执行键盘快捷键
 /// - Parameter event: 键盘事件
 /// - Returns: 是否处理了事件
    @discardableResult
    public func handleKeyboardShortcut(_ event: NSEvent) -> Bool {
        guard isKeyboardNavigationEnabled else { return false }
        
        for shortcut in keyboardShortcuts {
            if shortcut.matches(event) {
                shortcut.action()
                logger.debug("⌨️ 执行键盘快捷键: \(shortcut.description)")
                return true
            }
        }
        
        return false
    }
    
 /// 处理Tab键导航
 /// - Parameter event: 键盘事件
 /// - Returns: 是否处理了事件
    public func handleTabNavigation(_ event: NSEvent) -> Bool {
        guard isKeyboardNavigationEnabled else { return false }
        guard event.keyCode == 48 else { return false } // Tab键
        
        if event.modifierFlags.contains(.shift) {
            focusPreviousElement()
        } else {
            focusNextElement()
        }
        
        return true
    }
    
 /// 获取当前焦点路径
 /// - Returns: 焦点路径描述
    public func getCurrentFocusPath() -> String {
        guard let currentFocus = currentFocusedElement else {
            return "无焦点"
        }
        
        var path: [String] = []
        var view: NSView? = currentFocus
        
        while let currentView = view {
            if let identifier = currentView.identifier?.rawValue {
                path.append(identifier)
            } else {
                path.append(currentView.className)
            }
            view = currentView.superview
        }
        
        return path.reversed().joined(separator: " > ")
    }
    
 // MARK: - 私有方法
    
 /// 设置键盘导航
    private func setupKeyboardNavigation() {
        updateFocusRingConfiguration()
        logger.debug("⌨️ 键盘导航设置完成")
    }
    
 /// 设置默认快捷键
    private func setupDefaultShortcuts() {
 // Tab导航
        let tabShortcut = KeyboardShortcut(
            identifier: "tab_navigation",
            keyCode: 48, // Tab
            modifierFlags: [],
            description: "Tab导航"
        ) { [weak self] in
            self?.focusNextElement()
        }
        keyboardShortcuts.append(tabShortcut)
        
 // Shift+Tab导航
        let shiftTabShortcut = KeyboardShortcut(
            identifier: "shift_tab_navigation",
            keyCode: 48, // Tab
            modifierFlags: [.shift],
            description: "Shift+Tab导航"
        ) { [weak self] in
            self?.focusPreviousElement()
        }
        keyboardShortcuts.append(shiftTabShortcut)
        
 // Escape清除焦点
        let escapeShortcut = KeyboardShortcut(
            identifier: "escape_clear_focus",
            keyCode: 53, // Escape
            modifierFlags: [],
            description: "Escape清除焦点"
        ) { [weak self] in
            self?.clearFocus()
        }
        keyboardShortcuts.append(escapeShortcut)
        
        logger.debug("⌨️ 默认快捷键设置完成")
    }
    
 /// 开始键盘监控
    private func startKeyboardMonitoring() {
        guard isKeyboardNavigationEnabled else { return }
        
 // 本地事件监控
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            
 // 处理Tab导航
            if self.handleTabNavigation(event) {
                return nil
            }
            
 // 处理快捷键
            if self.handleKeyboardShortcut(event) {
                return nil
            }
            
            return event
        }
        
 // 全局事件监控（用于某些特殊情况）
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyboardShortcut(event)
        }
        
        logger.info("⌨️ 键盘监控已启动")
    }
    
 /// 停止键盘监控
    private func stopKeyboardMonitoring() {
        removeKeyboardMonitors()
        logger.info("⌨️ 键盘监控已停止")
    }
    
 /// 移除键盘监控器
    private func removeKeyboardMonitors() {
        if let localMonitor = localEventMonitor {
            NSEvent.removeMonitor(localMonitor)
            localEventMonitor = nil
        }
        
        if let globalMonitor = globalEventMonitor {
            NSEvent.removeMonitor(globalMonitor)
            globalEventMonitor = nil
        }
    }
    
 /// 更新Tab顺序
    private func updateTabOrder() {
 // 清理无效引用
        focusableElements.removeAll { $0.view == nil }
        
 // 按优先级和自定义顺序排序
        let sortedElements = focusableElements.sorted { first, second in
 // 首先按自定义Tab顺序排序
            if let firstOrder = first.customTabOrder,
               let secondOrder = second.customTabOrder {
                return firstOrder < secondOrder
            }
            
            if first.customTabOrder != nil && second.customTabOrder == nil {
                return true
            }
            
            if first.customTabOrder == nil && second.customTabOrder != nil {
                return false
            }
            
 // 然后按优先级排序
            return first.priority.rawValue < second.priority.rawValue
        }
        
        tabOrder = sortedElements.compactMap { $0.view }
        
        logger.debug("⌨️ Tab顺序已更新，共\(self.tabOrder.count)个元素")
    }
    
 /// 配置视图的键盘导航属性
 /// - Parameter view: 要配置的视图
    private func configureViewForKeyboardNavigation(_ view: NSView) {
 // 确保视图可以接收键盘焦点
 // 注意：canBecomeKeyView是只读属性，需要在子类中重写
        
 // 设置下一个键盘视图（如果需要）
        if getNextViewInTabOrder(after: view) != nil {
 // nextKeyView也是只读属性，需要在子类中重写
            logger.debug("⌨️ 为视图设置下一个键盘视图")
        }
        
 // 设置上一个键盘视图（如果需要）
        if getPreviousViewInTabOrder(before: view) != nil {
 // previousKeyView也是只读属性，需要在子类中重写
            logger.debug("⌨️ 为视图设置上一个键盘视图")
        }
    }
    
 /// 获取Tab顺序中的下一个视图
 /// - Parameter view: 当前视图
 /// - Returns: 下一个视图
    private func getNextViewInTabOrder(after view: NSView) -> NSView? {
        guard let currentIndex = tabOrder.firstIndex(of: view) else { return nil }
        let nextIndex = (currentIndex + 1) % tabOrder.count
        return tabOrder[nextIndex]
    }
    
 /// 获取Tab顺序中的上一个视图
 /// - Parameter view: 当前视图
 /// - Returns: 上一个视图
    private func getPreviousViewInTabOrder(before view: NSView) -> NSView? {
        guard let currentIndex = tabOrder.firstIndex(of: view) else { return nil }
        let previousIndex = currentIndex > 0 ? currentIndex - 1 : tabOrder.count - 1
        return tabOrder[previousIndex]
    }
    
 /// 添加焦点环
 /// - Parameter view: 目标视图
    private func addFocusRing(to view: NSView) {
        switch focusRing {
        case .system:
            view.focusRingType = .default
        case .none:
            view.focusRingType = .none
        case .custom:
            addCustomFocusRing(to: view)
        }
        
        view.needsDisplay = true
    }
    
 /// 移除焦点环
 /// - Parameter view: 目标视图
    private func removeFocusRing(from view: NSView) {
        view.focusRingType = .none
        removeCustomFocusRing(from: view)
        view.needsDisplay = true
    }
    
 /// 添加自定义焦点环
 /// - Parameter view: 目标视图
    private func addCustomFocusRing(to view: NSView) {
 // 创建自定义焦点环层
        let focusLayer = CALayer()
        focusLayer.name = "CustomFocusRing"
        focusLayer.frame = view.bounds.insetBy(dx: -2, dy: -2)
        focusLayer.borderWidth = focusRingConfiguration.borderWidth
        focusLayer.borderColor = focusRingConfiguration.borderColor.cgColor
        focusLayer.cornerRadius = focusRingConfiguration.cornerRadius
        focusLayer.backgroundColor = NSColor.clear.cgColor
        
 // 添加动画效果
        if focusRingConfiguration.animated {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.0
            animation.toValue = 1.0
            animation.duration = 0.2
            focusLayer.add(animation, forKey: "fadeIn")
        }
        
        view.layer?.addSublayer(focusLayer)
    }
    
 /// 移除自定义焦点环
 /// - Parameter view: 目标视图
    private func removeCustomFocusRing(from view: NSView) {
        view.layer?.sublayers?.removeAll { $0.name == "CustomFocusRing" }
    }
    
 /// 更新焦点环配置
    private func updateFocusRingConfiguration() {
        switch focusRing {
        case .system:
            focusRingConfiguration = FocusRingConfiguration()
        case .none:
            break
        case .custom:
            focusRingConfiguration = FocusRingConfiguration(
                borderWidth: 2.0,
                borderColor: .systemBlue,
                cornerRadius: 4.0,
                animated: true
            )
        }
    }
    
 /// 滚动到可见区域
 /// - Parameter view: 目标视图
    private func scrollToVisible(_ view: NSView) {
        if let scrollView = view.enclosingScrollView {
            scrollView.scrollToVisible(view.frame)
        }
    }
    
 /// 清理可聚焦元素
    private func clearFocusableElements() {
        focusableElements.removeAll()
        tabOrder.removeAll()
        currentFocusIndex = 0
    }
}

// MARK: - 辅助结构和枚举

/// 焦点环样式
public enum FocusRingStyle: String, CaseIterable, Sendable {
    case system = "系统默认"
    case none = "无"
    case custom = "自定义"
}

/// 焦点优先级
public enum FocusPriority: Int, CaseIterable, Sendable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3
}

/// 弱视图引用
private class WeakViewReference {
    weak var view: NSView?
    let priority: FocusPriority
    let customTabOrder: Int?
    
    init(view: NSView, priority: FocusPriority, customTabOrder: Int?) {
        self.view = view
        self.priority = priority
        self.customTabOrder = customTabOrder
    }
}

/// 键盘快捷键
public struct KeyboardShortcut {
    let identifier: String
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let description: String
    let action: () -> Void
    
 /// 检查事件是否匹配此快捷键
 /// - Parameter event: 键盘事件
 /// - Returns: 是否匹配
    func matches(_ event: NSEvent) -> Bool {
        return event.keyCode == keyCode && 
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifierFlags
    }
}

/// 焦点环配置
private struct FocusRingConfiguration {
    var borderWidth: CGFloat = 1.0
    var borderColor: NSColor = .controlAccentColor
    var cornerRadius: CGFloat = 2.0
    var animated: Bool = false
}