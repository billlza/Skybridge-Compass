import Foundation
import AppKit
import os.log

/// 头像缓存管理器 - 负责头像的本地缓存和云端同步
/// 采用Apple推荐的缓存策略，支持内存和磁盘双重缓存
@MainActor
public final class AvatarCacheManager: ObservableObject, Sendable {
    
 // MARK: - 单例
    
    public static let shared = AvatarCacheManager()
    
 // MARK: - 发布属性
    
    @Published public var isStarted: Bool = false
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "AvatarCacheManager")
    private let fileManager = FileManager.default
    private let urlSession = URLSession.shared
    
 // 内存缓存
    private var memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 50 // 最多缓存50个头像
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB内存限制
        return cache
    }()
    
 // 缓存目录
    private lazy var cacheDirectory: URL = {
        let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let cacheDir = urls[0].appendingPathComponent("SkyBridge/Avatars")
        
 // 确保缓存目录存在
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        return cacheDir
    }()
    
 // MARK: - 初始化
    
    private init() {
        setupCacheConfiguration()
        setupMemoryWarningObserver()
    }
    
 // MARK: - 生命周期管理
    
 /// 启动头像缓存管理器
    public func start() async {
        guard !isStarted else { return }
        
        isStarted = true
        
 // 初始化缓存配置
        setupCacheConfiguration()
        setupMemoryWarningObserver()
        
        logger.info("头像缓存管理器启动成功")
    }
    
 /// 停止头像缓存管理器
    public func stop() async {
        guard isStarted else { return }
        
        isStarted = false
        
 // 移除通知观察者
        NotificationCenter.default.removeObserver(self)
        
        logger.info("头像缓存管理器已停止")
    }
    
 /// 清理头像缓存管理器资源
    public func cleanup() async {
        await stop()
        
 // 清理内存缓存
        memoryCache.removeAllObjects()
        
        logger.info("头像缓存管理器资源清理完成")
    }
    
 // MARK: - 公共方法
    
 /// 获取头像图片
 /// - Parameter userId: 用户ID
 /// - Returns: 头像图片，如果不存在则返回nil
    public func getAvatar(for userId: String) -> NSImage? {
        let cacheKey = NSString(string: userId)
        
 // 首先检查内存缓存
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            logger.debug("从内存缓存获取头像: \(userId)")
            return cachedImage
        }
        
 // 检查磁盘缓存
        let diskCacheURL = cacheDirectory.appendingPathComponent("\(userId).jpg")
        if fileManager.fileExists(atPath: diskCacheURL.path),
           let imageData = try? Data(contentsOf: diskCacheURL),
           let image = NSImage(data: imageData) {
            
 // 将图片加载到内存缓存
            memoryCache.setObject(image, forKey: cacheKey, cost: imageData.count)
            logger.debug("从磁盘缓存获取头像: \(userId)")
            return image
        }
        
        return nil
    }
    
 /// 缓存头像图片
 /// - Parameters:
 /// - image: 头像图片
 /// - userId: 用户ID
    public func cacheAvatar(_ image: NSImage, for userId: String) {
        let cacheKey = NSString(string: userId)
        
 // 保存到内存缓存
        if let imageData = image.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: imageData),
           let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            
            memoryCache.setObject(image, forKey: cacheKey, cost: jpegData.count)
            
 // 异步保存到磁盘缓存
            Task {
                await saveToDiskCache(jpegData, for: userId)
            }
            
            logger.debug("缓存头像到内存和磁盘: \(userId), 大小: \(jpegData.count) bytes")
        }
    }
    
 /// 从URL下载并缓存头像
 /// - Parameters:
 /// - url: 头像URL
 /// - userId: 用户ID
 /// - Returns: 下载的头像图片
    public func downloadAndCacheAvatar(from url: String, for userId: String) async throws -> NSImage {
        guard let avatarURL = URL(string: url) else {
            throw AvatarCacheError.invalidURL
        }
        
        logger.info("开始下载头像: \(userId), URL: \(url)")
        
        do {
            let (data, response) = try await urlSession.data(from: avatarURL)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw AvatarCacheError.downloadFailed
            }
            
            guard let image = NSImage(data: data) else {
                throw AvatarCacheError.invalidImageData
            }
            
 // 缓存下载的图片
            cacheAvatar(image, for: userId)
            
            logger.info("头像下载并缓存成功: \(userId), 大小: \(data.count) bytes")
            return image
            
        } catch {
            logger.error("头像下载失败: \(userId), 错误: \(error.localizedDescription)")
            throw AvatarCacheError.downloadFailed
        }
    }
    
 /// 清除指定用户的头像缓存
 /// - Parameter userId: 用户ID
    public func clearAvatar(for userId: String) {
        let cacheKey = NSString(string: userId)
        
 // 从内存缓存移除
        memoryCache.removeObject(forKey: cacheKey)
        
 // 从磁盘缓存移除
        let diskCacheURL = cacheDirectory.appendingPathComponent("\(userId).jpg")
        try? fileManager.removeItem(at: diskCacheURL)
        
        logger.debug("清除头像缓存: \(userId)")
    }
    
 /// 清除所有头像缓存
    public func clearAllAvatars() {
 // 清除内存缓存
        memoryCache.removeAllObjects()
        
 // 清除磁盘缓存
        do {
            let cacheFiles = try fileManager.contentsOfDirectory(at: cacheDirectory, 
                                                               includingPropertiesForKeys: nil)
            for file in cacheFiles {
                try fileManager.removeItem(at: file)
            }
            logger.info("清除所有头像缓存成功")
        } catch {
            logger.error("清除磁盘缓存失败: \(error.localizedDescription)")
        }
    }
    
 /// 获取缓存大小信息
 /// - Returns: 缓存大小（字节）
    public func getCacheSize() -> Int {
        var totalSize = 0
        
        do {
            let cacheFiles = try fileManager.contentsOfDirectory(at: cacheDirectory, 
                                                               includingPropertiesForKeys: [.fileSizeKey])
            for file in cacheFiles {
                let resourceValues = try file.resourceValues(forKeys: [.fileSizeKey])
                totalSize += resourceValues.fileSize ?? 0
            }
        } catch {
            logger.error("计算缓存大小失败: \(error.localizedDescription)")
        }
        
        return totalSize
    }
    
 // MARK: - 私有方法
    
 /// 设置缓存配置
    private func setupCacheConfiguration() {
 // 设置内存缓存的清理策略
        memoryCache.name = "AvatarMemoryCache"
        
        logger.debug("头像缓存管理器初始化完成")
        logger.debug("缓存目录: \(self.cacheDirectory.path)")
    }
    
 /// 设置内存警告观察者
    private func setupMemoryWarningObserver() {
 // 在macOS中使用内存压力通知
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSApplicationDidReceiveMemoryWarning"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMemoryWarning()
            }
        }
    }
    
 /// 处理内存警告
    private func handleMemoryWarning() {
        logger.warning("收到内存警告，清理头像内存缓存")
        memoryCache.removeAllObjects()
    }
    
 /// 保存到磁盘缓存
 /// - Parameters:
 /// - data: 图片数据
 /// - userId: 用户ID
    private func saveToDiskCache(_ data: Data, for userId: String) async {
        let diskCacheURL = cacheDirectory.appendingPathComponent("\(userId).jpg")
        
        do {
            try data.write(to: diskCacheURL)
            logger.debug("头像保存到磁盘缓存: \(userId)")
        } catch {
            logger.error("头像磁盘缓存保存失败: \(userId), 错误: \(error.localizedDescription)")
        }
    }
}

// MARK: - 错误定义

public enum AvatarCacheError: LocalizedError {
    case invalidURL
    case downloadFailed
    case invalidImageData
    case cacheWriteFailed
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的头像URL"
        case .downloadFailed:
            return "头像下载失败"
        case .invalidImageData:
            return "无效的图片数据"
        case .cacheWriteFailed:
            return "缓存写入失败"
        }
    }
}