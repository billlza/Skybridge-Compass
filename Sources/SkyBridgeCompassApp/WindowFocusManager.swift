import SwiftUI
import AppKit
import SkyBridgeCore

/// 窗口焦点管理器 - 按照 Apple 官方最佳实践
/// 负责管理 macOS 应用的窗口焦点和第一响应者
@MainActor
class WindowFocusManager: BaseManager {
    static let shared = WindowFocusManager()
    
    private init() {
        super.init(category: "WindowFocusManager")
    }
    
 /// 获取当前主窗口
    var keyWindow: NSWindow? {
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
    }
    
 /// 强制应用获取焦点 - Apple 推荐的方式
    func forceApplicationFocus() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        if let window = keyWindow {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
    
 /// 设置指定视图为第一响应者
    func makeFirstResponder(_ view: NSView?) {
        guard let window = keyWindow else { return }
        
        Task { @MainActor in
            window.makeFirstResponder(view)
        }
    }
    
 /// 重置第一响应者为窗口
    func resetFirstResponder() {
        guard let window = keyWindow else { return }
        
        Task { @MainActor in
            window.makeFirstResponder(window)
        }
    }
    
 /// 查找窗口中的第一个文本字段并设置为第一响应者
    func focusFirstTextField() {
        guard let window = keyWindow else { return }
        
        Task { @MainActor in
 // 递归查找第一个 NSTextField
            if let textField = self.findFirstTextField(in: window.contentView) {
                window.makeFirstResponder(textField)
            }
        }
    }
    
 /// 递归查找视图层次结构中的第一个 NSTextField
    private func findFirstTextField(in view: NSView?) -> NSTextField? {
        guard let view = view else { return nil }
        
 // 如果当前视图是 NSTextField，返回它
        if let textField = view as? NSTextField, textField.isEditable {
            return textField
        }
        
 // 递归搜索子视图
        for subview in view.subviews {
            if let textField = findFirstTextField(in: subview) {
                return textField
            }
        }
        
        return nil
    }
    
 /// 获取当前第一响应者
    var currentFirstResponder: NSResponder? {
        return keyWindow?.firstResponder
    }
    
 /// 检查指定视图是否是第一响应者
    func isFirstResponder(_ view: NSView) -> Bool {
        return keyWindow?.firstResponder == view
    }
    
 /// 获取窗口状态信息
    func getWindowStatus() -> String {
        guard let window = keyWindow else {
            return "❌ 无主窗口"
        }
        
        var status = "🪟 窗口状态:\n"
        status += "  - 标题: \(window.title)\n"
        status += "  - 是否为主窗口: \(window.isMainWindow ? "是" : "否")\n"
        status += "  - 是否为关键窗口: \(window.isKeyWindow ? "是" : "否")\n"
        status += "  - 是否可见: \(window.isVisible ? "是" : "否")\n"
        
        if let firstResponder = window.firstResponder {
            status += "  - 第一响应者: \(type(of: firstResponder))\n"
            
            if let textField = firstResponder as? NSTextField {
                status += "    - 可编辑: \(textField.isEditable ? "是" : "否")\n"
                status += "    - 可选择: \(textField.isSelectable ? "是" : "否")\n"
                status += "    - 当前文本: '\(textField.stringValue)'\n"
            }
        } else {
            status += "  - 第一响应者: 无\n"
        }
        
        return status
    }
}

/// SwiftUI 视图修饰符，用于自动管理焦点
struct AutoFocus: ViewModifier {
    let delay: Double
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    Task { @MainActor in
                        WindowFocusManager.shared.focusFirstTextField()
                    }
                }
            }
    }
}

extension View {
 /// 自动聚焦到第一个文本字段
    func autoFocus(delay: Double = 0.1) -> some View {
        modifier(AutoFocus(delay: delay))
    }
}