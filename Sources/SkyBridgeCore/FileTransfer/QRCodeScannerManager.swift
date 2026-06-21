@preconcurrency import AVFoundation
import SwiftUI
import Vision
import Combine

/// 二维码扫描管理器 - 负责摄像头访问、二维码识别和传输链接解析
/// 采用Swift 6.2最佳实践和Apple Silicon优化
@MainActor
public final class QRCodeScannerManager: NSObject, ObservableObject, Sendable {
    
 // MARK: - 发布属性
    
    @Published public var isScanning = false
    @Published public var hasPermission = false
    @Published public var scanResult: String?
    @Published public var errorMessage: String?
    @Published public var isProcessing = false
    @Published public private(set) var scanSessionID = UUID()
    @Published public private(set) var deliveryEventID: UUID?
    
 // MARK: - 私有属性
    
    private var captureSession: AVCaptureSession?
    private var videoPreviewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "qr.scanner.session", qos: .userInitiated)
    private var qrScannerCancellables = Set<AnyCancellable>()
    private var deliveredTerminalEvent = false
    
 // MARK: - 单例
    
    public static let shared = QRCodeScannerManager()
    
    private override init() {
        super.init()
        setupNotifications()
    }
    
 // MARK: - 生命周期管理
    
 /// 启动二维码扫描管理器
    public func start() async {
 // 初始化摄像头权限检查
        _ = await requestCameraPermission()
    }
    
 /// 停止二维码扫描管理器
    public func stop() {
        stopScanning()
        cleanup()
    }
    
 /// 清理资源
    public func cleanup() {
        qrScannerCancellables.removeAll()
        releaseCaptureResources()
        resetTransientState(startNewSession: true)
        setupNotifications()
    }
    
 // MARK: - 公共方法
    
 /// 请求摄像头权限
    public func requestCameraPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch status {
        case .authorized:
            hasPermission = true
            return true
            
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            hasPermission = granted
            if !granted {
                errorMessage = "需要摄像头权限才能扫描二维码"
            }
            return granted
            
        case .denied, .restricted:
            hasPermission = false
            errorMessage = "摄像头权限被拒绝，请在系统设置中允许访问"
            return false
            
        @unknown default:
            hasPermission = false
            errorMessage = "未知的摄像头权限状态"
            return false
        }
    }
    
 /// 开始扫描
    public func startScanning() async throws {
        if !hasPermission {
            let granted = await requestCameraPermission()
            if !granted {
                throw QRScannerError.cameraPermissionDenied
            }
        }

        releaseCaptureResources()
        resetTransientState(startNewSession: true)
        try await setupCaptureSession()
        
        isScanning = true
        
 // 使用nonisolated方式访问captureSession，避免并发警告
        let session = captureSession
        sessionQueue.async {
            session?.startRunning()
        }
        
        SkyBridgeLogger.ui.debugOnly("📱 二维码扫描已启动")
    }
    
 /// 停止扫描
    public func stopScanning() {
 // 使用nonisolated方式访问captureSession，避免并发警告
        let session = captureSession
        sessionQueue.async {
            session?.stopRunning()
        }
        
        isScanning = false
        isProcessing = false
        SkyBridgeLogger.ui.debugOnly("📱 二维码扫描已停止")
    }

    public func prepareForPresentation() {
        releaseCaptureResources()
        resetTransientState(startNewSession: true)
    }
    
 /// 获取预览图层
    public func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        return videoPreviewLayer
    }
    
 /// 处理扫描到的传输链接
    public func handleTransferLink(_ linkUrl: String) async -> Bool {
        isProcessing = true

        guard let components = URLComponents(string: linkUrl),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              components.path.contains("/link/") else {
            errorMessage = "无效的传输链接格式"
            isProcessing = false
            return false
        }

        let isValid = await probeTransferLink(linkUrl)

        if isValid {
            SkyBridgeLogger.ui.debugOnly("✅ 传输链接验证成功: \(linkUrl)")
        } else {
            publishError("传输链接已过期或无效")
        }
        isProcessing = false
        
        return isValid
    }

    private func probeTransferLink(_ linkUrl: String) async -> Bool {
        guard let url = URL(string: linkUrl) else { return false }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            guard httpResponse.statusCode == 200 else {
                return false
            }
            let marker = httpResponse.value(forHTTPHeaderField: "X-SkyBridge-Transfer")
            let pageType = httpResponse.value(forHTTPHeaderField: "X-SkyBridge-Transfer-Page")
            return marker == "v1" && (pageType == "preview" || pageType == "unlock")
        } catch {
            return false
        }
    }
    
 // MARK: - 私有方法
    
 /// 设置捕获会话
    private func setupCaptureSession() async throws {
        let session = AVCaptureSession()
        
 // 配置输入设备
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            throw QRScannerError.cameraNotAvailable
        }
        
        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            throw QRScannerError.cameraSetupFailed
        }
        
        guard session.canAddInput(videoInput) else {
            throw QRScannerError.cameraSetupFailed
        }
        session.addInput(videoInput)
        
 // 配置元数据输出（使用AVCaptureMetadataOutput替代VideoDataOutput以简化并发处理）
        let metadataOutput = AVCaptureMetadataOutput()
        
        guard session.canAddOutput(metadataOutput) else {
            throw QRScannerError.cameraSetupFailed
        }
        session.addOutput(metadataOutput)
        
 // 设置代理和队列
        metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
        metadataOutput.metadataObjectTypes = [.qr]
        
 // Apple Silicon优化：设置最佳会话预设
        if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }
        
 // 创建预览图层
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        
        self.captureSession = session
        self.videoPreviewLayer = previewLayer
    }

    private func releaseCaptureResources() {
        captureSession?.stopRunning()
        captureSession = nil
        videoPreviewLayer?.removeFromSuperlayer()
        videoPreviewLayer = nil
    }

    private func resetTransientState(startNewSession: Bool) {
        if startNewSession {
            scanSessionID = UUID()
        }
        isScanning = false
        isProcessing = false
        scanResult = nil
        errorMessage = nil
        deliveryEventID = nil
        deliveredTerminalEvent = false
    }

    private func publishResult(_ value: String) {
        guard !deliveredTerminalEvent else { return }
        deliveredTerminalEvent = true
        scanResult = value
        errorMessage = nil
        deliveryEventID = UUID()
    }

    private func publishError(_ value: String) {
        guard !deliveredTerminalEvent else { return }
        deliveredTerminalEvent = true
        errorMessage = value
        scanResult = nil
        deliveryEventID = UUID()
    }
    
 /// 设置通知监听
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .AVCaptureSessionRuntimeError)
 // AVFoundation 在自己的后台队列派发该通知;本类 @MainActor、sink 闭包按 MainActor 隔离编译,
 // Swift 6/macOS 27 会在闭包入口断言执行器==MainActor(早于内部 Task),后台直调即崩。先切回主队列。
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                Task { @MainActor in
                    self?.handleSessionError(notification)
                }
            }
            .store(in: &qrScannerCancellables)
    }
    
 /// 处理会话错误
    private func handleSessionError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            return
        }
        
        publishError("摄像头会话错误: \(error.localizedDescription)")
        stopScanning()
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension QRCodeScannerManager: AVCaptureMetadataOutputObjectsDelegate {
    
 /// 处理二维码扫描结果 - 使用nonisolated确保Swift 6.2并发安全
    nonisolated public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        
        guard let metadataObject = metadataObjects.first,
              let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
              let stringValue = readableObject.stringValue else {
            return
        }
        
 // 使用Task在MainActor上下文中安全处理扫描结果
        Task { @MainActor in
 // 避免重复处理
            guard !self.isProcessing, !self.deliveredTerminalEvent else { return }
            
            self.isProcessing = true
            
            if stringValue.contains("/link/") {
                let success = await self.handleTransferLink(stringValue)
                if success {
                    self.stopScanning()
                    self.publishResult(stringValue)
                } else {
                    self.publishError("无法处理传输链接")
                }
            } else if stringValue.hasPrefix("skybridge://connect/") {
 // 动态连接二维码，直接将结果交由上层逻辑处理
                self.stopScanning()
                self.publishResult(stringValue)
            } else {
 // 既不是传输链接也不是连接二维码
                self.publishError("未识别的二维码内容")
            }
            
            self.isProcessing = false
        }
    }
}

// MARK: - 二维码扫描器错误

public enum QRScannerError: Error, LocalizedError {
    case cameraPermissionDenied
    case cameraNotAvailable
    case cameraSetupFailed
    case scanningFailed
    
    public var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied:
            return "摄像头权限被拒绝"
        case .cameraNotAvailable:
            return "摄像头不可用"
        case .cameraSetupFailed:
            return "摄像头设置失败"
        case .scanningFailed:
            return "扫描失败"
        }
    }
}

// MARK: - SwiftUI集成

/// 二维码扫描器视图
public struct QRCodeScannerView: NSViewRepresentable {
    @ObservedObject private var scannerManager = QRCodeScannerManager.shared
    let onResult: (String) -> Void
    let onError: (String) -> Void

    public final class Coordinator {
        var handledSessionID: UUID?
        var handledEventID: UUID?
    }
    
    public init(onResult: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onResult = onResult
        self.onError = onError
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        scannerManager.prepareForPresentation()
        
 // 在Task外部捕获错误处理闭包，避免Sendable闭包警告
        let errorHandler = onError
        
 // 启动扫描
        Task { @MainActor in
            do {
                try await scannerManager.startScanning()
                
 // 添加预览图层
                if let previewLayer = scannerManager.getPreviewLayer() {
                    previewLayer.frame = view.bounds
                    view.layer?.sublayers?.removeAll()
                    view.layer?.addSublayer(previewLayer)
                }
            } catch {
                errorHandler(error.localizedDescription)
            }
        }
        
        return view
    }
    
    public func updateNSView(_ nsView: NSView, context: Context) {
        if context.coordinator.handledSessionID != scannerManager.scanSessionID {
            context.coordinator.handledSessionID = scannerManager.scanSessionID
            context.coordinator.handledEventID = nil
        }

 // 在Task外部捕获闭包，避免Sendable闭包警告
        let resultHandler = onResult
        let errorHandler = onError

        if let previewLayer = scannerManager.getPreviewLayer() {
            previewLayer.frame = nsView.bounds
            if previewLayer.superlayer !== nsView.layer {
                nsView.layer?.sublayers?.removeAll()
                nsView.layer?.addSublayer(previewLayer)
            }
        }

        guard let eventID = scannerManager.deliveryEventID,
              context.coordinator.handledEventID != eventID else {
            return
        }

        context.coordinator.handledEventID = eventID

        if let result = scannerManager.scanResult {
            resultHandler(result)
        } else if let error = scannerManager.errorMessage {
            errorHandler(error)
        }
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        Task { @MainActor in
            QRCodeScannerManager.shared.cleanup()
        }
    }
}
