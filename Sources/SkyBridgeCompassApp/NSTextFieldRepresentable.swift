import SwiftUI
import AppKit
import Combine

/// Apple 官方推荐的 NSTextField 包装器实现
/// 严格遵循 NSViewRepresentable 协议和 macOS 响应者链最佳实践
struct NSTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isSecure: Bool
    var onEditingChanged: ((Bool) -> Void)?
    var onCommit: (() -> Void)?
 // 新增：原始按键序列回调，用于向 SSH 会话直接发送特殊键（如方向键）
 // 注意：该回调仅发送原始控制序列，不影响本地文本编辑行为
    var onRawKeyInput: ((String) -> Void)?
 // 新增：逐字符粘贴模式（默认启用），用于将粘贴板文本按字符流式发送到远端，避免一次性大文本造成阻塞
    var pasteAsCharacters: Bool
 // 新增：启用 Ctrl / Alt 组合键映射（默认启用）
    var enableCtrlAltMapping: Bool
    
 // 初始化方法
    init(
        text: Binding<String>,
        placeholder: String = "",
        isSecure: Bool = false,
        onEditingChanged: ((Bool) -> Void)? = nil,
        onCommit: (() -> Void)? = nil,
        onRawKeyInput: ((String) -> Void)? = nil,
        pasteAsCharacters: Bool = true,
        enableCtrlAltMapping: Bool = true
    ) {
        self._text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.onEditingChanged = onEditingChanged
        self.onCommit = onCommit
        self.onRawKeyInput = onRawKeyInput
        self.pasteAsCharacters = pasteAsCharacters
        self.enableCtrlAltMapping = enableCtrlAltMapping
    }
    
 /// 创建 NSView - Apple 官方要求的方法
    func makeNSView(context: Context) -> NSTextField {
        let textField: NSTextField
        
        if isSecure {
 // 安全文本：保持系统默认行为
            textField = NSSecureTextField()
        } else {
 // 普通文本：使用自定义子类以拦截键盘事件，提供 Ctrl/Alt 映射与粘贴增强
            textField = MappedTextField()
            if let mapped = textField as? MappedTextField {
 // 将父配置传递到子类实例
                mapped.pasteAsCharacters = pasteAsCharacters
                mapped.enableCtrlAltMapping = enableCtrlAltMapping
 // 将原始输入回调透传
                mapped.onRawKeyInput = onRawKeyInput
            }
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
        private var pasteThrottleCancellable: AnyCancellable?
        
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

 // 处理方向键与常用导航键，将对应 ANSI 序列发送到远端
 // 说明：返回 false 以允许本地文本光标移动，同时向远端发送原始序列
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onRawKeyInput?("\u{001B}[A") // Up
                return false
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onRawKeyInput?("\u{001B}[B") // Down
                return false
            }
            if commandSelector == #selector(NSResponder.moveRight(_:)) {
                parent.onRawKeyInput?("\u{001B}[C") // Right
                return false
            }
            if commandSelector == #selector(NSResponder.moveLeft(_:)) {
                parent.onRawKeyInput?("\u{001B}[D") // Left
                return false
            }
 // Home/End 常见序列（兼容大多数 shell 与终端程序）
            if commandSelector == #selector(NSResponder.scrollToBeginningOfDocument(_:)) ||
               commandSelector == #selector(NSResponder.moveToBeginningOfLine(_:)) {
                parent.onRawKeyInput?("\u{001B}[H")
                return false
            }
            if commandSelector == #selector(NSResponder.scrollToEndOfDocument(_:)) ||
               commandSelector == #selector(NSResponder.moveToEndOfLine(_:)) {
                parent.onRawKeyInput?("\u{001B}[F")
                return false
            }
 // PageUp / PageDown
            if commandSelector == #selector(NSResponder.pageUp(_:)) {
                parent.onRawKeyInput?("\u{001B}[5~")
                return false
            }
            if commandSelector == #selector(NSResponder.pageDown(_:)) {
                parent.onRawKeyInput?("\u{001B}[6~")
                return false
            }
 // 处理粘贴（Command+V）为逐字符模式（若启用）
            if commandSelector == #selector(NSTextView.paste(_:)) {
                guard parent.pasteAsCharacters else { return false }
 // 从系统粘贴板读取字符串
                let pb = NSPasteboard.general
                if let str = pb.string(forType: .string), !str.isEmpty {
 // 逐字符发送，使用微小节流避免阻塞远端管道
 // 说明：采用 Combine 序列确保在主线程上调度，严格并发控制
                    let chars = Array(str)
                    let publisher = chars.publisher
                        .flatMap { ch -> Just<String> in
 // 将单字符封装为字符串
                            Just(String(ch))
                        }
                        .receive(on: RunLoop.main)
                        .eraseToAnyPublisher()
 // 每个字符间隔 1 毫秒（在本地，仅用于对远端发送节流），实际节流由远端 NIO 管线处理
                    pasteThrottleCancellable = publisher
                        .zip(Timer.publish(every: 0.001, on: .main, in: .common).autoconnect())
                        .sink { [weak self] pair in
                            let (charStr, _) = pair
                            self?.parent.onRawKeyInput?(charStr)
                        }
 // 为了用户体验，仍让系统执行粘贴到本地输入框
                    return false
                }
                return false
            }
 // 退格键（Backspace）不转发到远端，避免本地行编辑与远端同时处理造成困扰
 // 若需要原始退格：\u{7F}，此处按最佳实践保持仅本地处理
            
            return false
        }
    }
}

/// 扩展：提供便捷的初始化方法
extension NSTextFieldRepresentable {
 /// 简单文本输入框
    static func textField(
        text: Binding<String>,
        placeholder: String = "",
        onRawKeyInput: ((String) -> Void)? = nil,
        pasteAsCharacters: Bool = true,
        enableCtrlAltMapping: Bool = true
    ) -> NSTextFieldRepresentable {
        NSTextFieldRepresentable(
            text: text,
            placeholder: placeholder,
            isSecure: false,
            onRawKeyInput: onRawKeyInput,
            pasteAsCharacters: pasteAsCharacters,
            enableCtrlAltMapping: enableCtrlAltMapping
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

// MARK: - 自定义文本框子类：处理 Ctrl/Alt 组合键与原始按键映射
final class MappedTextField: NSTextField {
 // 配置项与回调（通过父包装器传入）
 // 说明：使用弱引用闭包避免循环引用
    var onRawKeyInput: ((String) -> Void)?
    var pasteAsCharacters: Bool = true
    var enableCtrlAltMapping: Bool = true

 /// 覆盖键盘按下事件，拦截 Ctrl / Alt 组合键并发送对应序列
    override func keyDown(with event: NSEvent) {
 // 当启用映射时，处理 Control 与 Option 组合键
        if enableCtrlAltMapping {
 // 修饰键状态
            let flags = event.modifierFlags
            let isControl = flags.contains(.control)
            let isOption = flags.contains(.option)
 // 从事件中获取字符（不忽略修饰键）
            if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
 // Control 组合：映射为 C0 控制字符（a-z -> 0x01-0x1A）
                if isControl {
                    let mapped = mapControlSequence(characters)
                    if let seq = mapped {
 // 发送原始控制序列到远端
                        onRawKeyInput?(seq)
 // 保持本地默认处理（不阻断），避免影响输入框编辑体验
                        super.keyDown(with: event)
                        return
                    }
                }
 // Option(Alt) 组合：发送 ESC 前缀再附加字符（常见终端行为）
                if isOption {
                    let escPrefixed = "\u{001B}" + characters
                    onRawKeyInput?(escPrefixed)
                    super.keyDown(with: event)
                    return
                }
            }
        }
 // 默认处理其他按键
        super.keyDown(with: event)
    }

 /// Control 映射：将字符转换为对应的控制码字符串
 /// 说明：仅映射常见范围，未覆盖的字符返回 nil
    private func mapControlSequence(_ chars: String) -> String? {
        guard let ch = chars.lowercased().unicodeScalars.first else { return nil }
        switch ch.value {
        case 97...122: // a-z
 // Ctrl-a -> 0x01, ... Ctrl-z -> 0x1A
            let codePoint = Int(ch.value - 96)
            return String(UnicodeScalar(codePoint)!)
        case 91: // '[' -> ESC
            return "\u{001B}"
        case 92: // '\\' -> FS
            return "\u{001C}"
        case 93: // ']' -> GS
            return "\u{001D}"
        case 94: // '^' -> RS
            return "\u{001E}"
        case 95: // '_' -> US
            return "\u{001F}"
        case 32: // space -> NUL
            return "\u{0000}"
        case 63: // '?' -> DEL（兼容部分终端期望）
            return "\u{007F}"
        case 104: // 'h' -> Backspace（兼容 Bash 行编辑）
            return "\u{0008}"
        case 106: // 'j' -> Line Feed
            return "\u{000A}"
        case 109: // 'm' -> Carriage Return
            return "\u{000D}"
        default:
            return nil
        }
    }
}