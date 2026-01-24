//
// QRCodeManager.swift
// SkyBridgeCompassiOS
//
// 二维码管理器 - 生成和扫描二维码
// 用于快速配对和分享连接信息
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - QR Code Data

/// 二维码数据类型
public enum QRCodeDataType: String, Codable, Sendable {
    case devicePairing = "device_pairing"
    case connectionLink = "connection_link"
    case fileTransfer = "file_transfer"
    case custom = "custom"
}

/// 二维码数据
public struct QRCodeData: Codable, Sendable {
    public let type: QRCodeDataType
    public let deviceId: String
    public let deviceName: String
    public let ipAddress: String?
    public let port: UInt16?
    public let publicKey: String?
    public let timestamp: TimeInterval
    public let expiresAt: TimeInterval?
    public let signature: String?
    public let payload: [String: String]?
    
    public init(
        type: QRCodeDataType,
        deviceId: String,
        deviceName: String,
        ipAddress: String? = nil,
        port: UInt16? = nil,
        publicKey: String? = nil,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        expiresAt: TimeInterval? = nil,
        signature: String? = nil,
        payload: [String: String]? = nil
    ) {
        self.type = type
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.ipAddress = ipAddress
        self.port = port
        self.publicKey = publicKey
        self.timestamp = timestamp
        self.expiresAt = expiresAt
        self.signature = signature
        self.payload = payload
    }
    
    /// 是否已过期
    public var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date().timeIntervalSince1970 > expiresAt
    }
    
    /// 编码为 JSON 字符串
    public func toJSONString() -> String? {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
    
    /// 从 JSON 字符串解码
    public static func from(jsonString: String) -> QRCodeData? {
        guard let data = jsonString.data(using: .utf8),
              let qrData = try? JSONDecoder().decode(QRCodeData.self, from: data) else {
            return nil
        }
        return qrData
    }
}

// MARK: - QR Code Generator

/// 二维码生成器
@available(iOS 17.0, *)
public class QRCodeGenerator {
    
    public static let shared = QRCodeGenerator()
    
    private let context = CIContext()
    
    private init() {}
    
    /// 生成二维码图像
    /// - Parameters:
    ///   - data: 二维码数据
    ///   - size: 图像大小
    ///   - foregroundColor: 前景色
    ///   - backgroundColor: 背景色
    /// - Returns: 生成的二维码图像
    #if canImport(UIKit)
    public func generateQRCode(
        from data: QRCodeData,
        size: CGSize = CGSize(width: 300, height: 300),
        foregroundColor: UIColor = .black,
        backgroundColor: UIColor = .white
    ) -> UIImage? {
        guard let jsonString = data.toJSONString() else {
            return nil
        }
        
        return generateQRCode(
            from: jsonString,
            size: size,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor
        )
    }
    
    /// 从字符串生成二维码
    public func generateQRCode(
        from string: String,
        size: CGSize = CGSize(width: 300, height: 300),
        foregroundColor: UIColor = .black,
        backgroundColor: UIColor = .white
    ) -> UIImage? {
        guard let data = string.data(using: .utf8) else {
            return nil
        }
        
        // 创建 QR 码滤镜
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "H" // 最高容错级别
        
        guard let outputImage = filter.outputImage else {
            return nil
        }
        
        // 应用颜色
        let colorFilter = CIFilter.falseColor()
        colorFilter.inputImage = outputImage
        colorFilter.color0 = CIColor(color: backgroundColor)
        colorFilter.color1 = CIColor(color: foregroundColor)
        
        guard let coloredImage = colorFilter.outputImage else {
            return nil
        }
        
        // 缩放到目标大小
        let scaleX = size.width / coloredImage.extent.width
        let scaleY = size.height / coloredImage.extent.height
        let scaledImage = coloredImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // 转换为 UIImage
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    /// 生成带 Logo 的二维码
    public func generateQRCodeWithLogo(
        from data: QRCodeData,
        size: CGSize = CGSize(width: 300, height: 300),
        logo: UIImage?,
        logoSize: CGSize = CGSize(width: 60, height: 60)
    ) -> UIImage? {
        guard let qrImage = generateQRCode(from: data, size: size) else {
            return nil
        }
        
        guard let logo = logo else {
            return qrImage
        }
        
        // 在中心绘制 Logo
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }
        
        qrImage.draw(in: CGRect(origin: .zero, size: size))
        
        let logoOrigin = CGPoint(
            x: (size.width - logoSize.width) / 2,
            y: (size.height - logoSize.height) / 2
        )
        
        // 绘制白色背景
        let backgroundRect = CGRect(origin: logoOrigin, size: logoSize).insetBy(dx: -5, dy: -5)
        UIColor.white.setFill()
        UIBezierPath(roundedRect: backgroundRect, cornerRadius: 8).fill()
        
        // 绘制 Logo
        logo.draw(in: CGRect(origin: logoOrigin, size: logoSize))
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    #endif
    
    /// 生成设备配对二维码数据
    public func createPairingData(
        deviceId: String,
        deviceName: String,
        ipAddress: String,
        port: UInt16,
        publicKey: String? = nil,
        expiresInSeconds: TimeInterval = 300
    ) -> QRCodeData {
        let now = Date().timeIntervalSince1970
        
        return QRCodeData(
            type: .devicePairing,
            deviceId: deviceId,
            deviceName: deviceName,
            ipAddress: ipAddress,
            port: port,
            publicKey: publicKey,
            timestamp: now,
            expiresAt: now + expiresInSeconds
        )
    }
}

// MARK: - QR Code Scanner

#if canImport(UIKit)
/// 二维码扫描器代理
@available(iOS 17.0, *)
public protocol QRCodeScannerDelegate: AnyObject {
    func scanner(_ scanner: QRCodeScanner, didScanCode code: String)
    func scanner(_ scanner: QRCodeScanner, didScanQRData data: QRCodeData)
    func scanner(_ scanner: QRCodeScanner, didFailWithError error: Error)
}

/// 二维码扫描器
@available(iOS 17.0, *)
public class QRCodeScanner: NSObject {
    
    public weak var delegate: QRCodeScannerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isScanning = false
    
    public override init() {
        super.init()
    }
    
    /// 检查相机权限
    public func checkCameraPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
    
    /// 设置扫描器
    /// - Parameter previewView: 预览视图
    public func setup(in previewView: UIView) throws {
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw QRCodeScannerError.cameraNotAvailable
        }
        
        let input = try AVCaptureDeviceInput(device: device)
        
        let output = AVCaptureMetadataOutput()
        
        let session = AVCaptureSession()
        session.sessionPreset = .high
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = previewView.bounds
        previewLayer.videoGravity = .resizeAspectFill
        previewView.layer.addSublayer(previewLayer)
        
        self.captureSession = session
        self.previewLayer = previewLayer
    }
    
    /// 开始扫描
    public func startScanning() {
        guard !isScanning else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
            DispatchQueue.main.async {
                self?.isScanning = true
            }
        }
    }
    
    /// 停止扫描
    public func stopScanning() {
        guard isScanning else { return }
        
        captureSession?.stopRunning()
        isScanning = false
    }
    
    /// 更新预览层大小
    public func updatePreviewFrame(_ frame: CGRect) {
        previewLayer?.frame = frame
    }
    
    /// 切换闪光灯
    public func toggleFlashlight() throws {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else {
            throw QRCodeScannerError.flashlightNotAvailable
        }
        
        try device.lockForConfiguration()
        device.torchMode = device.torchMode == .on ? .off : .on
        device.unlockForConfiguration()
    }
    
    /// 解析二维码字符串
    private func parseQRCode(_ string: String) {
        // 尝试解析为 QRCodeData
        if let data = QRCodeData.from(jsonString: string) {
            if data.isExpired {
                delegate?.scanner(self, didFailWithError: QRCodeScannerError.qrCodeExpired)
            } else {
                delegate?.scanner(self, didScanQRData: data)
            }
            return
        }

        // 兼容 macOS / 旧版本：skybridge://pair?v=...&id=...&name=...&addr=...&port=...&t=...
        if let pairing = QRCodeData.fromSkybridgePairURLString(string) {
            if pairing.isExpired {
                delegate?.scanner(self, didFailWithError: QRCodeScannerError.qrCodeExpired)
        } else {
                delegate?.scanner(self, didScanQRData: pairing)
            }
            return
        }

            // 作为普通字符串返回
            delegate?.scanner(self, didScanCode: string)
        }
}

// MARK: - Interop: skybridge://pair (macOS 旧/兼容格式)

public extension QRCodeData {
    /// 解析 `skybridge://pair?...`（用于与 macOS 端 P2P Pairing 二维码互通）
    static func fromSkybridgePairURLString(_ string: String) -> QRCodeData? {
        guard let url = URL(string: string),
              url.scheme == "skybridge",
              url.host == "pair" else {
            return nil
        }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []

        func item(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        // v=1 只包含 id/t（旧占位），无法直接连接；仍然解析出来以便 UI 给提示。
        let deviceId = item("id") ?? UUID().uuidString
        let deviceName = item("name") ?? "SkyBridge Device"
        let ip = item("addr")
        let port = UInt16(item("port") ?? "")

        let ts = TimeInterval(item("t") ?? "") ?? Date().timeIntervalSince1970
        let expiresIn = TimeInterval(item("exp") ?? "") // seconds
        let expiresAt = expiresIn.map { ts + $0 }

        return QRCodeData(
            type: .devicePairing,
            deviceId: deviceId,
            deviceName: deviceName,
            ipAddress: ip,
            port: port,
            publicKey: item("pk"),
            timestamp: ts,
            expiresAt: expiresAt
        )
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

@available(iOS 17.0, *)
extension QRCodeScanner: AVCaptureMetadataOutputObjectsDelegate {
    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue else {
            return
        }
        
        // 停止扫描（避免重复回调）
        stopScanning()
        
        // 震动反馈
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        // 解析二维码
        parseQRCode(stringValue)
    }
}

// MARK: - QR Code Scanner Error

/// 二维码扫描器错误
public enum QRCodeScannerError: Error, LocalizedError {
    case cameraNotAvailable
    case permissionDenied
    case flashlightNotAvailable
    case qrCodeExpired
    case invalidQRCode
    
    public var errorDescription: String? {
        switch self {
        case .cameraNotAvailable: return "相机不可用"
        case .permissionDenied: return "相机权限被拒绝"
        case .flashlightNotAvailable: return "闪光灯不可用"
        case .qrCodeExpired: return "二维码已过期"
        case .invalidQRCode: return "无效的二维码"
        }
    }
}
#endif

// MARK: - QR Code Scanner View

#if canImport(UIKit)
import SwiftUI

/// 二维码扫描视图
@available(iOS 17.0, *)
public struct QRCodeScannerView: UIViewControllerRepresentable {
    
    public var onScan: ((QRCodeData) -> Void)?
    public var onScanString: ((String) -> Void)?
    public var onError: ((Error) -> Void)?
    
    public init(
        onScan: ((QRCodeData) -> Void)? = nil,
        onScanString: ((String) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        self.onScan = onScan
        self.onScanString = onScanString
        self.onError = onError
    }
    
    public func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    public func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public class Coordinator: NSObject, QRCodeScannerDelegate {
        let parent: QRCodeScannerView
        
        init(_ parent: QRCodeScannerView) {
            self.parent = parent
        }
        
        public func scanner(_ scanner: QRCodeScanner, didScanCode code: String) {
            parent.onScanString?(code)
        }
        
        public func scanner(_ scanner: QRCodeScanner, didScanQRData data: QRCodeData) {
            parent.onScan?(data)
        }
        
        public func scanner(_ scanner: QRCodeScanner, didFailWithError error: Error) {
            parent.onError?(error)
        }
    }
}

/// 二维码扫描视图控制器
@available(iOS 17.0, *)
public class QRCodeScannerViewController: UIViewController {
    
    weak var delegate: QRCodeScannerDelegate?
    
    private let scanner = QRCodeScanner()
    private var previewView: UIView!
    private var didStart = false
    private var startTask: Task<Void, Never>?
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        previewView = UIView(frame: view.bounds)
        previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(previewView)
        
        scanner.delegate = self
        // Intentionally do NOT start camera capture here.
        // SwiftUI sheets may prebuild view controllers off-screen; starting capture in viewDidLoad can
        // trigger FigCaptureSourceRemote/XPC errors at app launch even without user interaction.
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startIfNeeded()
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        startTask?.cancel()
        startTask = nil
        scanner.stopScanning()
        didStart = false
    }
    
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scanner.updatePreviewFrame(previewView.bounds)
    }

    deinit {
        startTask?.cancel()
        scanner.stopScanning()
    }

    private func startIfNeeded() {
        guard !didStart else { return }
        didStart = true

        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            let hasPermission = await self.scanner.checkCameraPermission()
            guard !Task.isCancelled else { return }

            if hasPermission {
                do {
                    try self.scanner.setup(in: self.previewView)
                    self.scanner.startScanning()
                } catch {
                    self.delegate?.scanner(self.scanner, didFailWithError: error)
                }
            } else {
                self.delegate?.scanner(self.scanner, didFailWithError: QRCodeScannerError.permissionDenied)
            }
        }
    }
}

extension QRCodeScannerViewController: QRCodeScannerDelegate {
    public func scanner(_ scanner: QRCodeScanner, didScanCode code: String) {
        delegate?.scanner(scanner, didScanCode: code)
    }
    
    public func scanner(_ scanner: QRCodeScanner, didScanQRData data: QRCodeData) {
        delegate?.scanner(scanner, didScanQRData: data)
    }
    
    public func scanner(_ scanner: QRCodeScanner, didFailWithError error: Error) {
        delegate?.scanner(scanner, didFailWithError: error)
    }
}
#endif

