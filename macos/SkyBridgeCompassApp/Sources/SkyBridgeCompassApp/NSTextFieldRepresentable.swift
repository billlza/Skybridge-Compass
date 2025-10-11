import SwiftUI
import AppKit

/// Apple 官方推荐的 NSTextField 包装器实现
/// 严格遵循 NSViewRepresentable 协议和 macOS 响应者链最佳实践
struct NSTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isSecure: Bool
    var onEditingChanged: ((Bool) -> Void)?
    var onCommit: (() -> Void)?
    
    // 初始化方法
    init(
        text: Binding<String>,
        placeholder: String = "",
        isSecure: Bool = false,
        onEditingChanged: ((Bool) -> Void)? = nil,
        onCommit: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.onEditingChanged = onEditingChanged
        self.onCommit = onCommit
    }
    
    /// 创建 NSView - Apple 官方要求的方法
    func makeNSView(context: Context) -> NSTextField {
        let textField: NSTextField
        
        if isSecure {
            textField = NSSecureTextField()
        } else {
            textField = NSTextField()
        }
        
        // 设置基本属性
        textField.stringValue = text
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        
        // 关键：设置文本字段属性以确保能接收键盘输入
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        
        // 设置字体和外观
        textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textField.focusRingType = .default
        
        // 确保文本字段可以成为第一响应者
        textField.refusesFirstResponder = false
        
        return textField
    }
    
    /// 更新 NSView - Apple 官方要求的方法
    func updateNSView(_ nsView: NSTextField, context: Context) {
        // 只在文本不同时更新，避免无限循环
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        
        // 更新占位符
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
    }
    
    /// 创建协调器 - Apple 官方推荐的代理模式
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    /// 协调器类 - 处理 NSTextField 代理事件
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NSTextFieldRepresentable
        
        init(_ parent: NSTextFieldRepresentable) {
            self.parent = parent
        }
        
        /// 文本开始编辑时调用
        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onEditingChanged?(true)
        }
        
        /// 文本结束编辑时调用
        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onEditingChanged?(false)
            parent.onCommit?()
        }
        
        /// 文本内容改变时调用
        @MainActor
        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            
            // 直接更新绑定的文本值，不使用 DispatchQueue
            parent.text = textField.stringValue
        }
        
        /// 处理特殊键盘事件
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // 处理回车键
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit?()
                return true
            }
            
            // 处理 Tab 键 - 让系统处理焦点切换
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return false // 让系统处理
            }
            
            return false
        }
    }
}

/// 扩展：提供便捷的初始化方法
extension NSTextFieldRepresentable {
    /// 简单文本输入框
    static func textField(
        text: Binding<String>,
        placeholder: String = ""
    ) -> NSTextFieldRepresentable {
        NSTextFieldRepresentable(
            text: text,
            placeholder: placeholder,
            isSecure: false
        )
    }
    
    /// 安全文本输入框（密码框）
    static func secureField(
        text: Binding<String>,
        placeholder: String = ""
    ) -> NSTextFieldRepresentable {
        NSTextFieldRepresentable(
            text: text,
            placeholder: placeholder,
            isSecure: true
        )
    }
}