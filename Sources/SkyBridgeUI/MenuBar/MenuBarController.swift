//
// MenuBarController.swift
// SkyBridgeUI
//
// Menu Bar App - Controller for NSStatusItem and NSPopover
// Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 4.1, 4.4, 6.1, 6.2
//

import AppKit
import SwiftUI
import Combine
import os.log

/// 菜单栏控制器 - 管理 NSStatusItem 和 NSPopover 的生命周期
/// Requirements: 1.1, 1.2, 1.3, 1.4, 1.5
@available(macOS 14.0, *)
@MainActor
public final class MenuBarController: NSObject, ObservableObject {
    
 // MARK: - Properties
    
 /// 状态栏项
    private var statusItem: NSStatusItem?
    
 /// 弹出面板
    private var popover: NSPopover?
    
 /// 右键菜单
    private var contextMenu: NSMenu?
    
 /// 视图模型
    @Published public var viewModel: MenuBarViewModel
    
 /// 配置
    private var configuration: MenuBarConfiguration
    
 /// 事件监视器（用于点击外部关闭 popover）
    private var eventMonitor: Any?
    
 /// 日志
    private let logger = Logger(subsystem: "com.skybridge.ui", category: "MenuBarController")
    
 /// Combine 订阅
    private var cancellables = Set<AnyCancellable>()
    
 /// 单例实例
    public static let shared = MenuBarController()
    
 // MARK: - Initialization
    
    private override init() {
        self.viewModel = MenuBarViewModel()
        self.configuration = MenuBarConfiguration.default
        super.init()
    }
    
 // MARK: - Public Methods
    
 /// 初始化并设置菜单栏图标
 /// Requirements: 1.1
    public func setup() {
        guard configuration.enabled else {
            logger.info("菜单栏图标已禁用，跳过设置")
            return
        }
        
 // 创建状态栏项
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        guard let button = statusItem?.button else {
            logger.error("无法创建状态栏按钮")
            return
        }
        
 // 设置图标（使用模板图像以支持深色/浅色模式自动切换）
 // Requirements: 6.1, 6.2
        if let icon = createMenuBarIcon() {
            icon.isTemplate = true
            button.image = icon
        } else {
 // 回退到 SF Symbol
            button.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "SkyBridge")
            button.image?.isTemplate = true
        }
        
        button.toolTip = "SkyBridge Compass"
        
 // 设置点击动作
        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        
 // 创建弹出面板
        setupPopover()
        
 // 创建右键菜单
        setupContextMenu()
        
 // 订阅图标状态变化
        setupIconStateBinding()
        
        logger.info("✅ 菜单栏图标设置完成")
    }
    
 /// 显示/隐藏弹出面板
 /// Requirements: 1.2
    public func togglePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }
        
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            setupEventMonitor()
        }
    }
    
 /// 关闭弹出面板
 /// Requirements: 1.3
    public func closePopover() {
        popover?.performClose(nil)
        removeEventMonitor()
    }
    
 /// 更新图标状态
 /// Requirements: 4.1, 4.4
    public func updateIconState(_ state: MenuBarIconState) {
        guard let button = statusItem?.button else { return }
        
        switch state {
        case .normal:
 // 使用司南图标
            let icon = createCompassMenuBarIcon()
            icon.isTemplate = true
            button.image = icon
            
        case .transferring(let progress):
 // 创建带进度的司南图标
            button.image = createProgressCompassIcon(progress: progress)
            button.image?.isTemplate = false
            
        case .error:
 // 创建带错误标记的司南图标
            button.image = createErrorCompassIcon()
            button.image?.isTemplate = false
            
        case .scanning:
 // 使用带动画效果的司南图标
            let icon = createScanningCompassIcon()
            icon.isTemplate = true
            button.image = icon
        }
    }
    
 /// 创建扫描中的司南图标（带圆点动画效果）
    private func createScanningCompassIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        
        image.lockFocus()
        
        let center = NSPoint(x: 9, y: 9)
        let radius: CGFloat = 7.5
        
 // 外圈（虚线表示扫描中）
        let circlePath = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        NSColor.labelColor.setStroke()
        circlePath.lineWidth = 1.2
        let pattern: [CGFloat] = [2, 2]
        circlePath.setLineDash(pattern, count: 2, phase: 0)
        circlePath.stroke()
        
 // 北指针
        let northPath = NSBezierPath()
        northPath.move(to: NSPoint(x: center.x, y: center.y + radius * 0.75))
        northPath.line(to: NSPoint(x: center.x - 2.5, y: center.y))
        northPath.line(to: NSPoint(x: center.x + 2.5, y: center.y))
        northPath.close()
        NSColor.labelColor.setFill()
        northPath.fill()
        
 // 南指针
        let southPath = NSBezierPath()
        southPath.move(to: NSPoint(x: center.x, y: center.y - radius * 0.75))
        southPath.line(to: NSPoint(x: center.x - 2.5, y: center.y))
        southPath.line(to: NSPoint(x: center.x + 2.5, y: center.y))
        southPath.close()
        southPath.lineWidth = 0.8
        NSColor.labelColor.setStroke()
        southPath.stroke()
        
 // 中心点
        let centerDot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
        NSColor.labelColor.setFill()
        centerDot.fill()
        
        image.unlockFocus()
        return image
    }
    
 /// 创建带进度的司南图标
    private func createProgressCompassIcon(progress: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        
        image.lockFocus()
        
        let center = NSPoint(x: 9, y: 9)
        let radius: CGFloat = 7.5
        
 // 背景圆环
        let bgPath = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        NSColor.systemGray.withAlphaComponent(0.3).setStroke()
        bgPath.lineWidth = 1.5
        bgPath.stroke()
        
 // 进度圆弧
        let progressPath = NSBezierPath()
        progressPath.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - CGFloat(progress * 360),
            clockwise: true
        )
        NSColor.systemBlue.setStroke()
        progressPath.lineWidth = 1.5
        progressPath.stroke()
        
 // 北指针（蓝色）
        let northPath = NSBezierPath()
        northPath.move(to: NSPoint(x: center.x, y: center.y + radius * 0.6))
        northPath.line(to: NSPoint(x: center.x - 2, y: center.y))
        northPath.line(to: NSPoint(x: center.x + 2, y: center.y))
        northPath.close()
        NSColor.systemBlue.setFill()
        northPath.fill()
        
 // 南指针
        let southPath = NSBezierPath()
        southPath.move(to: NSPoint(x: center.x, y: center.y - radius * 0.6))
        southPath.line(to: NSPoint(x: center.x - 2, y: center.y))
        southPath.line(to: NSPoint(x: center.x + 2, y: center.y))
        southPath.close()
        NSColor.systemGray.setFill()
        southPath.fill()
        
        image.unlockFocus()
        return image
    }
    
 /// 创建带错误标记的司南图标
    private func createErrorCompassIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        
        image.lockFocus()
        
        let center = NSPoint(x: 9, y: 9)
        let radius: CGFloat = 7.5
        
 // 外圈（红色）
        let circlePath = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        NSColor.systemRed.withAlphaComponent(0.8).setStroke()
        circlePath.lineWidth = 1.2
        circlePath.stroke()
        
 // 北指针
        let northPath = NSBezierPath()
        northPath.move(to: NSPoint(x: center.x, y: center.y + radius * 0.75))
        northPath.line(to: NSPoint(x: center.x - 2.5, y: center.y))
        northPath.line(to: NSPoint(x: center.x + 2.5, y: center.y))
        northPath.close()
        NSColor.systemRed.setFill()
        northPath.fill()
        
 // 南指针
        let southPath = NSBezierPath()
        southPath.move(to: NSPoint(x: center.x, y: center.y - radius * 0.75))
        southPath.line(to: NSPoint(x: center.x - 2.5, y: center.y))
        southPath.line(to: NSPoint(x: center.x + 2.5, y: center.y))
        southPath.close()
        NSColor.systemGray.setStroke()
        southPath.lineWidth = 0.8
        southPath.stroke()
        
 // 错误红点
        let errorDot = NSBezierPath(ovalIn: NSRect(x: 12, y: 0, width: 5, height: 5))
        NSColor.systemRed.setFill()
        errorDot.fill()
        
        image.unlockFocus()
        return image
    }
    
 /// 清理资源
    public func cleanup() {
        removeEventMonitor()
        popover?.close()
        statusItem = nil
        popover = nil
        contextMenu = nil
        cancellables.removeAll()
        logger.info("🗑 菜单栏控制器资源已清理")
    }
    
 // MARK: - Private Methods
    
 /// 设置弹出面板
 /// Requirements: 1.2, 1.3
    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(
            width: configuration.popoverWidth,
            height: configuration.popoverHeight
        )
        popover?.behavior = .transient // 点击外部自动关闭
        popover?.animates = true
        
 // 设置 SwiftUI 内容视图
        let contentView = MenuBarPopoverView(viewModel: viewModel)
        popover?.contentViewController = NSHostingController(rootView: contentView)
    }
    
 /// 设置右键菜单
 /// Requirements: 1.5
    private func setupContextMenu() {
        contextMenu = NSMenu()
        
 // 打开主窗口
        let openItem = NSMenuItem(
            title: "打开主窗口",
            action: #selector(openMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        contextMenu?.addItem(openItem)
        
 // 偏好设置
        let prefsItem = NSMenuItem(
            title: "偏好设置...",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        contextMenu?.addItem(prefsItem)
        
        contextMenu?.addItem(NSMenuItem.separator())
        
 // 退出
        let quitItem = NSMenuItem(
            title: "退出 SkyBridge",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        contextMenu?.addItem(quitItem)
    }
    
 /// 设置图标状态绑定
    private func setupIconStateBinding() {
        viewModel.$iconState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIconState(state)
            }
            .store(in: &cancellables)
    }
    
 /// 设置事件监视器（点击外部关闭 popover）
    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            if self?.popover?.isShown == true {
                self?.closePopover()
            }
        }
    }
    
 /// 移除事件监视器
    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
 /// 创建菜单栏图标 - 司南风格
    private func createMenuBarIcon() -> NSImage? {
 // 尝试从 bundle 加载图标
        if let icon = NSImage(named: "MenuBarIcon") {
            return icon
        }
        
 // 生成司南风格图标
        return createCompassMenuBarIcon()
    }
    
 /// 生成司南/指南针风格的菜单栏图标
    private func createCompassMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        
        image.lockFocus()
        
        let rect = NSRect(origin: .zero, size: size)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 7.5
        
 // 外圈
        let circlePath = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        NSColor.labelColor.setStroke()
        circlePath.lineWidth = 1.2
        circlePath.stroke()
        
 // 北指针（向上的三角形）
        let northPath = NSBezierPath()
        northPath.move(to: NSPoint(x: center.x, y: center.y + radius * 0.75)) // 顶点
        northPath.line(to: NSPoint(x: center.x - 2.5, y: center.y))
        northPath.line(to: NSPoint(x: center.x + 2.5, y: center.y))
        northPath.close()
        NSColor.labelColor.setFill()
        northPath.fill()
        
 // 南指针（向下的三角形，空心）
        let southPath = NSBezierPath()
        southPath.move(to: NSPoint(x: center.x, y: center.y - radius * 0.75)) // 底点
        southPath.line(to: NSPoint(x: center.x - 2.5, y: center.y))
        southPath.line(to: NSPoint(x: center.x + 2.5, y: center.y))
        southPath.close()
        NSColor.labelColor.setStroke()
        southPath.lineWidth = 0.8
        southPath.stroke()
        
 // 中心点
        let centerDot = NSBezierPath(ovalIn: NSRect(
            x: center.x - 1.5,
            y: center.y - 1.5,
            width: 3,
            height: 3
        ))
        NSColor.labelColor.setFill()
        centerDot.fill()
        
        image.unlockFocus()
        
        return image
    }
    
 // MARK: - Actions
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp {
 // 右键显示菜单
            if let menu = contextMenu {
                statusItem?.menu = menu
                statusItem?.button?.performClick(nil)
                statusItem?.menu = nil
            }
        } else {
 // 左键切换 popover
            togglePopover()
        }
    }
    
    @objc private func openMainWindow() {
        closePopover()
        NotificationCenter.default.post(name: .menuBarOpenMainWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func openPreferences() {
        closePopover()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
