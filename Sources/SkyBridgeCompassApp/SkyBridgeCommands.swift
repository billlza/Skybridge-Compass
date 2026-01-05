import SwiftUI

/// macOS 应用菜单命令结构 - 遵循 Apple 设计规范
struct SkyBridgeCommands: Commands {
    
    var body: some Commands {
 // 应用菜单 - 添加偏好设置命令
        CommandGroup(replacing: .appSettings) {
            Button("偏好设置...") {
 // 发送偏好设置通知
                NotificationCenter.default.post(name: .openPreferences, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        
 // 文件菜单
        CommandGroup(replacing: .newItem) {
            Button("新建连接...") {
 // 新建连接功能
                NotificationCenter.default.post(name: .newConnection, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            
            Button("打开连接历史...") {
 // 打开连接历史功能
                NotificationCenter.default.post(name: .openConnectionHistory, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
            
            Divider()
            
            Button("导出设置...") {
 // 导出设置功能
                NotificationCenter.default.post(name: .exportSettings, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            
            Button("导入设置...") {
 // 导入设置功能
                NotificationCenter.default.post(name: .importSettings, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        
 // 编辑菜单
        CommandGroup(after: .pasteboard) {
            Divider()
            
            Button("查找设备...") {
 // 查找设备功能
                NotificationCenter.default.post(name: .findDevice, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            
            Button("刷新设备列表") {
 // 刷新设备列表功能
                NotificationCenter.default.post(name: .refreshDevices, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        
 // 视图菜单
        CommandGroup(after: .toolbar) {
            Divider()
            
            Button("显示设备详情") {
 // 切换设备详情显示
                NotificationCenter.default.post(name: .toggleDeviceDetails, object: nil)
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            
            Button("紧凑模式") {
 // 切换紧凑模式
                NotificationCenter.default.post(name: .toggleCompactMode, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            
            Divider()
            
            Button("全屏") {
 // 全屏功能
                NotificationCenter.default.post(name: .toggleFullScreen, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        
 // 窗口菜单 - 标准的窗口管理功能
        CommandGroup(replacing: .windowArrangement) {
            Button("最小化") {
 // 最小化当前窗口
                NSApp.keyWindow?.miniaturize(nil)
            }
            .keyboardShortcut("m", modifiers: .command)
            
            Button("缩放") {
 // 缩放当前窗口
                NSApp.keyWindow?.zoom(nil)
            }
            
            Divider()
            
            Button("置于前台") {
 // 将应用置于前台
                NSApp.activate(ignoringOtherApps: true)
            }
            
            Button("隐藏其他应用") {
 // 隐藏其他应用
                NSApp.hideOtherApplications(nil)
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
            
            Button("显示所有应用") {
 // 显示所有应用
                NSApp.unhideAllApplications(nil)
            }
        }
        
 // 帮助菜单
        CommandGroup(replacing: .help) {
            Button("SkyBridge Compass 帮助") {
 // 打开帮助文档
                if let url = URL(string: "https://skybridge-compass.help") {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("?", modifiers: .command)
            
            Button("键盘快捷键") {
 // 显示键盘快捷键帮助
                NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
            }
            
            Divider()
            
            Button("报告问题...") {
 // 打开问题报告页面
                if let url = URL(string: "https://github.com/skybridge-compass/issues") {
                    NSWorkspace.shared.open(url)
                }
            }
            
            Button("发送反馈...") {
 // 打开反馈页面
                if let url = URL(string: "mailto:feedback@skybridge-compass.com") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - 通知名称扩展
extension Notification.Name {
 // 应用菜单通知
    static let openPreferences = Notification.Name("openPreferences")
    
 // 文件菜单通知
    static let newConnection = Notification.Name("newConnection")
    static let openConnectionHistory = Notification.Name("openConnectionHistory")
    static let exportSettings = Notification.Name("exportSettings")
    static let importSettings = Notification.Name("importSettings")
    
 // 编辑菜单通知
    static let findDevice = Notification.Name("findDevice")
    static let refreshDevices = Notification.Name("refreshDevices")
    
 // 视图菜单通知
    static let toggleDeviceDetails = Notification.Name("toggleDeviceDetails")
    static let toggleCompactMode = Notification.Name("toggleCompactMode")
    static let toggleFullScreen = Notification.Name("toggleFullScreen")
    
 // 帮助菜单通知
    static let showKeyboardShortcuts = Notification.Name("showKeyboardShortcuts")
}