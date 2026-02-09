//
// MacPlatformAdapter.swift
// SkyBridgeCore
//
// Mac 平台适配器 - 实现 macOS 特定功能
// 使用 ScreenCaptureKit 进行屏幕捕获，CGEvent 进行输入注入
//
// Requirements: 10.5, 10.6, 4.1, 4.2, 4.3, 4.4, 5.1, 5.2, 5.3, 5.4, 5.5
//

import Foundation
import OSLog
import ScreenCaptureKit
import CoreGraphics
import AppKit

// MARK: - Mac Platform Adapter

/// Mac 平台适配器 - 实现 macOS 特定功能
@available(macOS 14.0, *)
public final class MacPlatformAdapter: @unchecked Sendable {
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "MacPlatformAdapter")
    
 // MARK: - Screen Capture State
    
    private var screenCaptureStream: SCStream?
    private var captureDelegate: ScreenCaptureStreamDelegate?
    private var currentFrame: ScreenFrame?
    private let frameLock = NSLock()
    
 // MARK: - Initialization
    
    public init() {}
    
    deinit {
        screenCaptureStream?.stopCapture()
    }
}

// MARK: - PlatformAdapter Conformance

@available(macOS 14.0, *)
extension MacPlatformAdapter: PlatformAdapter {
    
 // MARK: - Screen Capture
    
    public func startScreenCapture(config: ScreenCaptureConfig) async throws {
 // 检查屏幕录制权限
        let permissionStatus = await checkPermission(.screenRecording)
        guard permissionStatus == .authorized else {
            throw PlatformAdapterError.permissionDenied(.screenRecording)
        }
        
 // 获取可共享内容
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw PlatformAdapterError.noDisplayAvailable
        }
        
 // 配置流
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = config.width ?? Int(display.width)
        streamConfig.height = config.height ?? Int(display.height)
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = config.showsCursor
        
 // 创建过滤器和流
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        
 // 设置输出代理
        let delegate = ScreenCaptureStreamDelegate { [weak self] frame in
            self?.setCurrentFrame(frame)
        }
        captureDelegate = delegate
        
        try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.skybridge.screencapture"))
        try await stream.startCapture()
        
        screenCaptureStream = stream
        logger.info("🎥 屏幕捕获已启动: \(streamConfig.width)x\(streamConfig.height)@\(config.frameRate)fps")
    }
    
    public func stopScreenCapture() async {
        do {
            try await screenCaptureStream?.stopCapture()
        } catch {
            logger.warning("停止屏幕捕获时出错: \(error.localizedDescription)")
        }
        screenCaptureStream = nil
        captureDelegate = nil
        
        setCurrentFrame(nil)
        
        logger.info("🛑 屏幕捕获已停止")
    }
    
    public func getScreenFrame() async -> ScreenFrame? {
        return getCurrentFrame()
    }
    
 // MARK: - Thread-Safe Frame Access
    
    private func setCurrentFrame(_ frame: ScreenFrame?) {
        frameLock.withLock {
            currentFrame = frame
        }
    }
    
    private func getCurrentFrame() -> ScreenFrame? {
        frameLock.withLock {
            currentFrame
        }
    }
    
 // MARK: - Input Injection
    
    public func injectMouseEvent(_ event: SBRemoteMouseEvent) async throws {
 // 检查辅助功能权限
        let permissionStatus = await checkPermission(.accessibility)
        guard permissionStatus == .authorized else {
            throw PlatformAdapterError.permissionDenied(.accessibility)
        }
        
        guard let screenSize = await MainActor.run(body: { NSScreen.main?.frame.size }) else {
            throw PlatformAdapterError.noDisplayAvailable
        }
        
 // 将归一化坐标转换为屏幕坐标
        let (screenX, screenY) = CoordinateConverter.denormalize(
            x: event.x,
            y: event.y,
            screenWidth: Int(screenSize.width),
            screenHeight: Int(screenSize.height)
        )
        let point = CGPoint(x: screenX, y: screenY)
        
        switch event.type {
        case .move:
            try injectMouseMove(to: point, modifiers: event.modifiers)
            
        case .click:
            try injectMouseClick(at: point, button: event.button ?? .left, modifiers: event.modifiers)
            
        case .doubleClick:
            try injectMouseDoubleClick(at: point, modifiers: event.modifiers)
            
        case .down:
            try injectMouseDown(at: point, button: event.button ?? .left, modifiers: event.modifiers)
            
        case .up:
            try injectMouseUp(at: point, button: event.button ?? .left, modifiers: event.modifiers)
            
        case .scroll:
 // 滚动事件通过 injectScrollEvent 处理
            break
        }
    }
    
    public func injectKeyboardEvent(_ event: SBRemoteKeyboardEvent) async throws {
 // 检查辅助功能权限
        let permissionStatus = await checkPermission(.accessibility)
        guard permissionStatus == .authorized else {
            throw PlatformAdapterError.permissionDenied(.accessibility)
        }
        
        let keyDown = event.type == .down
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(event.keyCode), keyDown: keyDown) else {
            throw PlatformAdapterError.inputInjectionFailed("无法创建键盘事件")
        }
        
        applyModifiers(to: cgEvent, modifiers: event.modifiers)
        cgEvent.post(tap: .cghidEventTap)
    }
    
    public func injectScrollEvent(_ event: SBRemoteScrollEvent) async throws {
 // 检查辅助功能权限
        let permissionStatus = await checkPermission(.accessibility)
        guard permissionStatus == .authorized else {
            throw PlatformAdapterError.permissionDenied(.accessibility)
        }
        
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-event.deltaY),
            wheel2: Int32(-event.deltaX),
            wheel3: 0
        ) else {
            throw PlatformAdapterError.inputInjectionFailed("无法创建滚动事件")
        }
        
        applyModifiers(to: cgEvent, modifiers: event.modifiers)
        cgEvent.post(tap: .cghidEventTap)
    }
    
 // MARK: - Permission Management
    
    public func checkPermission(_ type: SBPermissionType) async -> SBPermissionStatus {
        switch type {
        case .screenRecording:
            return await checkScreenRecordingPermission()
        case .accessibility:
            return checkAccessibilityPermission()
        case .localNetwork:
            return .authorized  // macOS 不需要显式授权本地网络
        case .camera, .microphone:
            return .notDetermined  // 暂不实现
        }
    }
    
    public func requestPermission(_ type: SBPermissionType) async -> Bool {
        switch type {
        case .accessibility:
            return requestAccessibilityPermission()
        case .screenRecording:
            if await checkScreenRecordingPermission() == .authorized {
                return true
            }
            let granted = await MainActor.run { CGRequestScreenCaptureAccess() }
            if !granted {
                openPermissionSettings(.screenRecording)
            }
            return granted
        default:
            return false
        }
    }
    
 /// 请求辅助功能权限（同步方法，避免并发问题）
    private nonisolated func requestAccessibilityPermission() -> Bool {
 // 使用字符串常量避免并发安全问题
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    public func openPermissionSettings(_ type: SBPermissionType) {
        let urlString: String
        switch type {
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        default:
            urlString = "x-apple.systempreferences:com.apple.preference.security"
        }
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Private Helpers

@available(macOS 14.0, *)
private extension MacPlatformAdapter {
    
 // MARK: - Permission Checks
    
    func checkScreenRecordingPermission() async -> SBPermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return .authorized
        } catch {
            return .denied
        }
    }
    
    func checkAccessibilityPermission() -> SBPermissionStatus {
        return AXIsProcessTrusted() ? .authorized : .denied
    }
    
 // MARK: - Mouse Event Helpers
    
    func injectMouseMove(to point: CGPoint, modifiers: SBKeyModifiers) throws {
        guard let cgEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw PlatformAdapterError.inputInjectionFailed("无法创建鼠标移动事件")
        }
        applyModifiers(to: cgEvent, modifiers: modifiers)
        cgEvent.post(tap: .cghidEventTap)
    }
    
    func injectMouseClick(at point: CGPoint, button: SBMouseButton, modifiers: SBKeyModifiers) throws {
        try injectMouseDown(at: point, button: button, modifiers: modifiers)
        try injectMouseUp(at: point, button: button, modifiers: modifiers)
    }
    
    func injectMouseDoubleClick(at point: CGPoint, modifiers: SBKeyModifiers) throws {
        for _ in 0..<2 {
            guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) else {
                throw PlatformAdapterError.inputInjectionFailed("无法创建鼠标按下事件")
            }
            downEvent.setIntegerValueField(.mouseEventClickState, value: 2)
            applyModifiers(to: downEvent, modifiers: modifiers)
            downEvent.post(tap: .cghidEventTap)
            
            guard let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
                throw PlatformAdapterError.inputInjectionFailed("无法创建鼠标释放事件")
            }
            upEvent.setIntegerValueField(.mouseEventClickState, value: 2)
            applyModifiers(to: upEvent, modifiers: modifiers)
            upEvent.post(tap: .cghidEventTap)
        }
    }
    
    func injectMouseDown(at point: CGPoint, button: SBMouseButton, modifiers: SBKeyModifiers) throws {
        let mouseType: CGEventType
        let mouseButton: CGMouseButton
        
        switch button {
        case .left:
            mouseType = .leftMouseDown
            mouseButton = .left
        case .right:
            mouseType = .rightMouseDown
            mouseButton = .right
        case .middle:
            mouseType = .otherMouseDown
            mouseButton = .center
        }
        
        guard let cgEvent = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            throw PlatformAdapterError.inputInjectionFailed("无法创建鼠标按下事件")
        }
        applyModifiers(to: cgEvent, modifiers: modifiers)
        cgEvent.post(tap: .cghidEventTap)
    }
    
    func injectMouseUp(at point: CGPoint, button: SBMouseButton, modifiers: SBKeyModifiers) throws {
        let mouseType: CGEventType
        let mouseButton: CGMouseButton
        
        switch button {
        case .left:
            mouseType = .leftMouseUp
            mouseButton = .left
        case .right:
            mouseType = .rightMouseUp
            mouseButton = .right
        case .middle:
            mouseType = .otherMouseUp
            mouseButton = .center
        }
        
        guard let cgEvent = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else {
            throw PlatformAdapterError.inputInjectionFailed("无法创建鼠标释放事件")
        }
        applyModifiers(to: cgEvent, modifiers: modifiers)
        cgEvent.post(tap: .cghidEventTap)
    }
    
 // MARK: - Modifier Helpers
    
    func applyModifiers(to event: CGEvent, modifiers: SBKeyModifiers) {
        var flags: CGEventFlags = []
        if modifiers.ctrl { flags.insert(.maskControl) }
        if modifiers.alt { flags.insert(.maskAlternate) }
        if modifiers.shift { flags.insert(.maskShift) }
        if modifiers.meta { flags.insert(.maskCommand) }
        event.flags = flags
    }
}

// MARK: - Screen Capture Stream Delegate

@available(macOS 14.0, *)
private final class ScreenCaptureStreamDelegate: NSObject, SCStreamOutput {
    
    private let onFrame: (ScreenFrame) -> Void
    
    init(onFrame: @escaping (ScreenFrame) -> Void) {
        self.onFrame = onFrame
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else { return }
        
        let dataSize = bytesPerRow * height
        let data = Data(bytes: baseAddress, count: dataSize)
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        
        let frame = ScreenFrame(
            width: width,
            height: height,
            format: .bgra,
            data: data,
            timestamp: timestamp,
            isKeyFrame: true  // 原始帧都是关键帧
        )
        
        onFrame(frame)
    }
}
