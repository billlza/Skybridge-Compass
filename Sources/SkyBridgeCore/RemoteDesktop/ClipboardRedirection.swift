//
// ClipboardRedirection.swift
// SkyBridge Compass Pro
//
// 剪贴板重定向功能 - 支持 RDP 和 UltraStream
// 符合 Swift 6.2.1 和 macOS 26.x 最佳实践
//

import Foundation
import AppKit
import OSLog
import Combine

/// 剪贴板重定向管理器
/// 支持双向同步：本地剪贴板 <-> 远程剪贴板
@MainActor
public final class ClipboardRedirectionManager: ObservableObject, @unchecked Sendable {
    
    public static let shared = ClipboardRedirectionManager()
    
    private let log = Logger(subsystem: "com.skybridge.compass", category: "ClipboardRedirection")
    
 /// 是否启用剪贴板同步
    @Published public var isEnabled: Bool = false
    
 /// 当前会话 ID（用于多会话场景）
    private var activeSessionId: UUID?
    
 /// 剪贴板变化观察者
    private var pasteboardChangeObserver: NSObjectProtocol?
    
 /// 远程剪贴板数据缓存（避免循环同步）
    private var lastRemoteClipboardHash: String?
    
 /// 同步队列（避免并发问题）
    private let syncQueue = DispatchQueue(label: "com.skybridge.clipboard.sync", attributes: .concurrent)
    
 /// 剪贴板数据回调（发送到远程）
    public var onLocalClipboardChanged: ((Data, String) -> Void)? // (data, mimeType)
    
 /// 远程剪贴板数据接收回调
    public var onRemoteClipboardReceived: ((Data, String) -> Void)? // (data, mimeType)
    
    private init() {
 // 私有初始化
    }
    
 /// 启用剪贴板重定向
 /// - Parameter sessionId: 会话 ID
    public func enable(for sessionId: UUID) {
        guard !isEnabled || activeSessionId != sessionId else { return }
        
        isEnabled = true
        activeSessionId = sessionId
        
 // 监听本地剪贴板变化
        startMonitoringLocalClipboard()
        
        log.info("✅ 剪贴板重定向已启用: sessionId=\(sessionId.uuidString)")
    }
    
 /// 禁用剪贴板重定向
    public func disable() {
        guard isEnabled else { return }
        
        isEnabled = false
        stopMonitoringLocalClipboard()
        activeSessionId = nil
        lastRemoteClipboardHash = nil
        
        log.info("🛑 剪贴板重定向已禁用")
    }
    
 /// 开始监听本地剪贴板变化
    private func startMonitoringLocalClipboard() {
        stopMonitoringLocalClipboard()
        
        let pasteboard = NSPasteboard.general
        var changeCount = pasteboard.changeCount
        
 // 使用定时器轮询（macOS 26.x 推荐方式）
        pasteboardChangeObserver = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                let pasteboard = NSPasteboard.general
                let currentChangeCount = pasteboard.changeCount
                if currentChangeCount != changeCount {
                    changeCount = currentChangeCount
                    self.handleLocalClipboardChange()
                }
            }
        }
    }
    
 /// 停止监听本地剪贴板变化
    private func stopMonitoringLocalClipboard() {
        if let observer = pasteboardChangeObserver as? Timer {
            observer.invalidate()
        }
        pasteboardChangeObserver = nil
    }
    
 /// 处理本地剪贴板变化
    private func handleLocalClipboardChange() {
        let pasteboard = NSPasteboard.general
        
 // 优先获取文本
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let data = text.data(using: .utf8) ?? Data()
            let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            
 // 避免重复同步
            guard hash != lastRemoteClipboardHash else { return }
            lastRemoteClipboardHash = hash
            
            Task { @MainActor [weak self] in
                self?.onLocalClipboardChanged?(data, "text/plain")
            }
            
            log.debug("📋 本地剪贴板文本变化: \(text.prefix(50))")
            return
        }
        
 // 尝试获取图片
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            guard let tiffData = image.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                return
            }
            
            let hash = SHA256.hash(data: pngData).compactMap { String(format: "%02x", $0) }.joined()
            guard hash != lastRemoteClipboardHash else { return }
            lastRemoteClipboardHash = hash
            
            Task { @MainActor [weak self] in
                self?.onLocalClipboardChanged?(pngData, "image/png")
            }
            
            log.debug("📋 本地剪贴板图片变化")
            return
        }
        
 // 尝试获取文件 URL
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let firstURL = fileURLs.first {
 // 对于文件，只发送路径信息（实际文件传输通过文件传输通道）
            let pathData = firstURL.path.data(using: .utf8) ?? Data()
            let hash = SHA256.hash(data: pathData).compactMap { String(format: "%02x", $0) }.joined()
            guard hash != lastRemoteClipboardHash else { return }
            lastRemoteClipboardHash = hash
            
            Task { @MainActor [weak self] in
                self?.onLocalClipboardChanged?(pathData, "text/uri-list")
            }
            
            log.debug("📋 本地剪贴板文件路径变化: \(firstURL.path)")
        }
    }
    
 /// 设置远程剪贴板内容
 /// - Parameters:
 /// - data: 剪贴板数据
 /// - mimeType: MIME 类型
    public func setRemoteClipboard(data: Data, mimeType: String) {
        guard isEnabled else { return }
        
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        guard hash != lastRemoteClipboardHash else { return }
        lastRemoteClipboardHash = hash
        
        Task { @MainActor in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            
            switch mimeType {
            case "text/plain", "text/plain;charset=utf-8":
                if let text = String(data: data, encoding: .utf8) {
                    pasteboard.setString(text, forType: .string)
                    log.debug("📋 远程剪贴板文本已设置: \(text.prefix(50))")
                }
                
            case "image/png", "image/jpeg", "image/tiff":
                if let image = NSImage(data: data) {
                    pasteboard.writeObjects([image])
                    log.debug("📋 远程剪贴板图片已设置")
                }
                
            case "text/uri-list":
                if let path = String(data: data, encoding: .utf8) {
                    pasteboard.clearContents()
                    pasteboard.setString(path, forType: .string)
                    log.debug("📋 远程剪贴板文件路径已设置: \(path)")
                }
                
            default:
                log.warning("⚠️ 不支持的剪贴板 MIME 类型: \(mimeType)")
            }
        }
    }
}

// MARK: - 导入 CryptoKit 用于哈希计算

import CryptoKit

