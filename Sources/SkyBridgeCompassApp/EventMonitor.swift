import SwiftUI
import AppKit

/// 事件监控器 - 按照 Apple 官方最佳实践
/// 负责监控系统级键盘和鼠标事件
@MainActor
class EventMonitor: ObservableObject {
    @Published var eventLogs: [String] = []
    @Published var isMonitoring = false
    
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let maxLogCount = 100
    
 /// 开始监控事件
    func startMonitoring() {
        guard !isMonitoring else { return }
        
 // 本地事件监控（应用内）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.logEvent(event, source: "本地")
            return event
        }
        
 // 全局事件监控（系统级）
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.logEvent(event, source: "全局")
        }
        
        isMonitoring = true
        addLog("✅ 事件监控已启动")
    }
    
 /// 停止监控事件
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        
        isMonitoring = false
        addLog("⏹ 事件监控已停止")
    }
    
 /// 记录事件
    private func logEvent(_ event: NSEvent, source: String) {
        let timestamp = DateFormatter.timeFormatter.string(from: Date())
        let eventType = event.type.description
        let keyCode = event.keyCode
        let characters = event.characters ?? ""
        
        let logMessage = "[\(timestamp)] \(source) - \(eventType) | 键码: \(keyCode) | 字符: '\(characters)'"
        addLog(logMessage)
    }
    
 /// 添加日志
    public func addLog(_ message: String) {
        eventLogs.append(message)
        
 // 限制日志数量
        if eventLogs.count > maxLogCount {
            eventLogs.removeFirst(eventLogs.count - maxLogCount)
        }
    }
    
 /// 清空日志
    func clearLogs() {
        eventLogs.removeAll()
        addLog("🗑 日志已清空")
    }
    
 /// 析构函数
    deinit {
 // 系统会自动清理，无需手动处理
    }
}

/// 扩展：NSEvent.EventType 描述
extension NSEvent.EventType {
    var description: String {
        switch self {
        case .keyDown: return "按键按下"
        case .keyUp: return "按键释放"
        case .flagsChanged: return "修饰键变化"
        case .leftMouseDown: return "左键按下"
        case .leftMouseUp: return "左键释放"
        case .rightMouseDown: return "右键按下"
        case .rightMouseUp: return "右键释放"
        case .mouseMoved: return "鼠标移动"
        case .leftMouseDragged: return "左键拖拽"
        case .rightMouseDragged: return "右键拖拽"
        case .scrollWheel: return "滚轮滚动"
        default: return "其他事件(\(self.rawValue))"
        }
    }
}

/// 扩展：时间格式化器
extension DateFormatter {
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}