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
        
 // 设置图标：菜单栏也必须使用 bundled AppIcon.icns 作为唯一品牌真源。
 // Requirements: 6.1, 6.2
        guard let icon = createMenuBarIcon() else {
            logger.error("菜单栏图标真源 AppIcon.icns 不可用，跳过状态栏设置")
            statusItem = nil
            return
        }
        button.image = icon
        
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
            button.image = createMenuBarIcon()
            
        case .transferring(let progress):
            button.image = createProgressMenuBarIcon(progress: progress)
            
        case .error:
            button.image = createErrorMenuBarIcon()
            
        case .scanning:
            button.image = createScanningMenuBarIcon()
        }

        if button.image == nil {
            logger.error("菜单栏图标状态更新失败：AppIcon.icns 真源不可用")
        }
    }
    
    private func createScanningMenuBarIcon() -> NSImage? {
        renderCanonicalMenuBarIcon { rect in
            let dotDiameter: CGFloat = 4
            let dotRect = NSRect(
                x: rect.maxX - dotDiameter - 1,
                y: rect.maxY - dotDiameter - 1,
                width: dotDiameter,
                height: dotDiameter
            )
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    private func createProgressMenuBarIcon(progress: Double) -> NSImage? {
        renderCanonicalMenuBarIcon { rect in
            let clampedProgress = min(max(progress, 0), 1)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - 1.5
            let progressPath = NSBezierPath()
            progressPath.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - CGFloat(clampedProgress * 360),
                clockwise: true
            )
            NSColor.systemBlue.setStroke()
            progressPath.lineWidth = 1.5
            progressPath.lineCapStyle = .round
            progressPath.stroke()
        }
    }

    private func createErrorMenuBarIcon() -> NSImage? {
        renderCanonicalMenuBarIcon { rect in
            let dotDiameter: CGFloat = 5
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
    
 /// 创建菜单栏图标。
    private func createMenuBarIcon() -> NSImage? {
        renderCanonicalMenuBarIcon()
    }

    private func renderCanonicalMenuBarIcon(
        overlay: ((NSRect) -> Void)? = nil
    ) -> NSImage? {
        guard let source = MenuBarCanonicalAppIconLoader.load() else {
            return nil
        }

        let size = NSSize(width: 18, height: 18)
        let rect = NSRect(origin: .zero, size: size)
        let image = NSImage(size: size)
        image.lockFocus()
        source.draw(in: rect)
        overlay?(rect)
        image.unlockFocus()
        image.isTemplate = false
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

private enum MenuBarCanonicalAppIconLoader {
    static func load() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url),
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        return image
    }
}
