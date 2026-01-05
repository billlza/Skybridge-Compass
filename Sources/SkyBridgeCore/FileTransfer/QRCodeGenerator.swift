@preconcurrency import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Combine

/// 二维码生成器 - 负责生成文件传输链接的二维码
/// 采用Swift 6.2最佳实践和Apple Silicon优化
@MainActor
public final class QRCodeGenerator: ObservableObject {
    
 // MARK: - 发布属性
    
    @Published public var generatedQRCode: NSImage?
    @Published public var isGenerating = false
    @Published public var errorMessage: String?
    @Published public var transferLink: String?
    
 // MARK: - 私有属性
    
    private let context = CIContext()
    private var cancellables = Set<AnyCancellable>()
    
 // MARK: - 单例
    
    public static let shared = QRCodeGenerator()
    
    private init() {
        setupNotifications()
    }
    
 // MARK: - 公共方法
    
 /// 为文件传输生成二维码
 /// - Parameters:
 /// - files: 要传输的文件路径数组
 /// - size: 二维码尺寸（默认200x200）
 /// - Returns: 生成的二维码图像
    public func generateQRCodeForFileTransfer(files: [URL], size: CGSize = CGSize(width: 200, height: 200)) async -> NSImage? {
        isGenerating = true
        errorMessage = nil
        
        do {
 // 创建传输链接
            let linkManager = TransferLinkManager.shared
            let link = try await linkManager.createTransferLink(for: files)
            
            let linkUrl = link.shareUrl
            transferLink = linkUrl
            
 // 生成二维码
            let qrImage = await generateQRCode(from: linkUrl, size: size)
            
            generatedQRCode = qrImage
            isGenerating = false
            
            SkyBridgeLogger.ui.debugOnly("✅ 二维码生成成功，链接: \(linkUrl)")
            return qrImage
            
        } catch {
            errorMessage = "生成二维码失败: \(error.localizedDescription)"
            isGenerating = false
            return nil
        }
    }
    
 /// 为P2P连接生成二维码
 /// - Parameters:
 /// - connectionInfo: 连接信息（IP地址、端口等）
 /// - size: 二维码尺寸
 /// - Returns: 生成的二维码图像
    public func generateQRCodeForP2PConnection(connectionInfo: String, size: CGSize = CGSize(width: 200, height: 200)) async -> NSImage? {
        isGenerating = true
        errorMessage = nil
        
        let qrImage = await generateQRCode(from: connectionInfo, size: size)
        
        generatedQRCode = qrImage
        isGenerating = false
        
        if qrImage != nil {
            SkyBridgeLogger.ui.debugOnly("✅ P2P连接二维码生成成功")
        } else {
            errorMessage = "生成P2P连接二维码失败"
        }
        
        return qrImage
    }
    
 /// 清除当前生成的二维码
    public func clearQRCode() {
        generatedQRCode = nil
        transferLink = nil
        errorMessage = nil
    }
    
 // MARK: - 私有方法
    
 /// 生成二维码图像
 /// - Parameters:
 /// - string: 要编码的字符串
 /// - size: 二维码尺寸
 /// - Returns: 生成的二维码图像
    private func generateQRCode(from string: String, size: CGSize) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                
 // 创建二维码滤镜
                let filter = CIFilter.qrCodeGenerator()
                filter.message = Data(string.utf8)
                
 // 设置纠错级别为高
                filter.correctionLevel = "H"
                
                guard let outputImage = filter.outputImage else {
                    continuation.resume(returning: nil)
                    return
                }
                
 // 计算缩放比例以适应目标尺寸
                let scaleX = size.width / outputImage.extent.width
                let scaleY = size.height / outputImage.extent.height
                let scale = min(scaleX, scaleY)
                
 // 应用变换以获得清晰的像素化效果
                let transform = CGAffineTransform(scaleX: scale, y: scale)
                let scaledImage = outputImage.transformed(by: transform)
                
 // 渲染为CGImage
                guard let cgImage = self.context.createCGImage(scaledImage, from: scaledImage.extent) else {
                    continuation.resume(returning: nil)
                    return
                }
                
 // 转换为NSImage
                let nsImage = NSImage(cgImage: cgImage, size: size)
                continuation.resume(returning: nsImage)
            }
        }
    }
    
 /// 设置通知监听
    private func setupNotifications() {
 // 监听传输链接过期通知
        NotificationCenter.default.publisher(for: .transferLinkExpired)
            .sink { [weak self] notification in
                Task { @MainActor in
                    self?.handleLinkExpired(notification)
                }
            }
            .store(in: &cancellables)
    }
    
 /// 处理链接过期
    private func handleLinkExpired(_ notification: Notification) {
        if let expiredLinkId = notification.userInfo?["linkId"] as? String,
           let currentLink = transferLink,
           currentLink.contains(expiredLinkId) {
            errorMessage = "传输链接已过期，请重新生成二维码"
            clearQRCode()
        }
    }
}

// MARK: - 通知扩展

extension Notification.Name {
    static let transferLinkExpired = Notification.Name("transferLinkExpired")
}

// MARK: - SwiftUI集成

/// 二维码显示视图
public struct QRCodeDisplayView: View {
    @ObservedObject private var generator = QRCodeGenerator.shared
    let files: [URL]
    let onDismiss: () -> Void
    
    public init(files: [URL], onDismiss: @escaping () -> Void) {
        self.files = files
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        VStack(spacing: 20) {
 // 标题
            Text(LocalizationManager.shared.localizedString("qrcode.title"))
                .font(.title2)
                .fontWeight(.semibold)
            
 // 二维码显示区域
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white)
                    .frame(width: 240, height: 240)
                    .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
                
                if generator.isGenerating {
                    ProgressView()
                        .scaleEffect(1.5)
                } else if let qrImage = generator.generatedQRCode {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 200, height: 200)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        
                        Text(LocalizationManager.shared.localizedString("qrcode.generateFailed"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
 // 错误信息
            if let errorMessage = generator.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            
 // 说明文字
            VStack(spacing: 8) {
                Text(LocalizationManager.shared.localizedString("qrcode.instruction.title"))
                    .font(.headline)
                
                Text(LocalizationManager.shared.localizedString("qrcode.instruction.subtitle"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
 // 操作按钮
            HStack(spacing: 16) {
                Button(LocalizationManager.shared.localizedString("qrcode.regenerate")) {
                    Task {
                        let _ = await generator.generateQRCodeForFileTransfer(files: files)
                    }
                }
                .buttonStyle(.bordered)
                
                Button(LocalizationManager.shared.localizedString("action.close")) {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
        .cornerRadius(20)
        .task {
 // 自动生成二维码
            let _ = await generator.generateQRCodeForFileTransfer(files: files)
        }
    }
}

// MARK: - 预览

#if DEBUG
struct QRCodeDisplayView_Previews: PreviewProvider {
    static var previews: some View {
        QRCodeDisplayView(files: [URL(fileURLWithPath: "/tmp/test.txt")]) {
 // 预览用空闭包
        }
        .frame(width: 400, height: 500)
    }
}
#endif
