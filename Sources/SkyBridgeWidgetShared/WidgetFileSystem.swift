// MARK: - Widget File System
// 文件系统抽象协议，用于依赖注入
// Requirements: 5.1, 5.2

import Foundation

/// 文件系统协议，用于依赖注入
/// 生产环境使用 RealFileSystem，测试使用 InMemoryFileSystem
public protocol WidgetFileSystem: Sendable {
 /// 写入数据到指定 URL
    func write(_ data: Data, to url: URL) throws
    
 /// 从指定 URL 读取数据
    func read(from url: URL) throws -> Data
    
 /// 检查文件是否存在
    func fileExists(at url: URL) -> Bool
}

// MARK: - Real File System

/// 生产环境实现 - 使用真实文件系统
public struct RealFileSystem: WidgetFileSystem {
    public init() {}
    
    public func write(_ data: Data, to url: URL) throws {
 // 确保目录存在
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        
 // 使用 atomic 写入，保证要么旧文件，要么新文件，不会半截
        try data.write(to: url, options: .atomic)
    }
    
    public func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
    
    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - In-Memory File System

/// 测试用内存文件系统
/// 线程安全，支持并发读写
public final class InMemoryFileSystem: WidgetFileSystem, @unchecked Sendable {
    private var storage: [URL: Data] = [:]
    private let lock = NSLock()
    
    public init() {}
    
    public func write(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[url] = data
    }
    
    public func read(from url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data = storage[url] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }
    
    public func fileExists(at url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[url] != nil
    }
    
 /// 清空所有存储（测试用）
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
    
 /// 获取存储的文件数量（测试用）
    public var fileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
    
 /// 模拟写入损坏数据（故障注入测试用）
    public func writeCorrupted(to url: URL) throws {
        let corruptedData = Data("{ \"invalid\": ".utf8)  // 不完整 JSON
        try write(corruptedData, to: url)
    }
}

// MARK: - Container URL Helper

/// 获取 App Groups 共享容器 URL
public func widgetContainerURL() -> URL? {
    FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: WidgetDataLimits.appGroupIdentifier
    )
}

/// 获取指定文件的完整 URL
public func widgetFileURL(for fileName: String, containerURL: URL? = nil) -> URL? {
    guard let container = containerURL ?? widgetContainerURL() else { return nil }
    return container.appendingPathComponent(fileName)
}
