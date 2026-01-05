// MARK: - Widget Data Reader
// Widget Extension 数据读取服务
// Requirements: 5.2, 5.4

import Foundation

/// Widget 数据读取服务
/// 负责从 App Groups 共享容器读取数据
public final class WidgetDataReader: @unchecked Sendable {
    
 // MARK: - Singleton
    
    public static let shared = WidgetDataReader()
    
 // MARK: - Dependencies
    
    private let fileSystem: WidgetFileSystem
    private let decoder: JSONDecoder
    private let containerURL: URL?
    
 // MARK: - Last Good Data Cache (per file)
    
    private var lastGoodDevicesData: WidgetDevicesData?
    private var lastGoodMetricsData: WidgetMetricsData?
    private var lastGoodTransfersData: WidgetTransfersData?
    
    private let lock = NSLock()
    
 // MARK: - Initialization
    
    public init(fileSystem: WidgetFileSystem = RealFileSystem(), containerURL: URL? = nil) {
        self.fileSystem = fileSystem
        self.containerURL = containerURL ?? widgetContainerURL()
        
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }
    
 // MARK: - Public API
    
 /// 读取设备状态数据
 /// - Returns: 设备数据，如果读取失败则返回上次成功的缓存
    public func loadDevicesData() -> WidgetDevicesData? {
        loadData(
            fileName: WidgetDataLimits.devicesFileName,
            type: WidgetDevicesData.self,
            lastGood: { self.lastGoodDevicesData },
            setLastGood: { self.lastGoodDevicesData = $0 }
        )
    }
    
 /// 读取系统指标数据
    public func loadMetricsData() -> WidgetMetricsData? {
        loadData(
            fileName: WidgetDataLimits.metricsFileName,
            type: WidgetMetricsData.self,
            lastGood: { self.lastGoodMetricsData },
            setLastGood: { self.lastGoodMetricsData = $0 }
        )
    }
    
 /// 读取文件传输数据
    public func loadTransfersData() -> WidgetTransfersData? {
        loadData(
            fileName: WidgetDataLimits.transfersFileName,
            type: WidgetTransfersData.self,
            lastGood: { self.lastGoodTransfersData },
            setLastGood: { self.lastGoodTransfersData = $0 }
        )
    }
    
 // MARK: - Private Methods
    
    private func loadData<T: Decodable>(
        fileName: String,
        type: T.Type,
        lastGood: () -> T?,
        setLastGood: (T) -> Void
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let containerURL else {
 // Container unavailable, return last good data
            return lastGood()
        }
        
        let fileURL = containerURL.appendingPathComponent(fileName)
        
        guard fileSystem.fileExists(at: fileURL) else {
 // File doesn't exist, return last good data
            return lastGood()
        }
        
        do {
            let data = try fileSystem.read(from: fileURL)
            let decoded = try decoder.decode(type, from: data)
            setLastGood(decoded)
            return decoded
        } catch {
 // Decode failed, return last good data (fault tolerance)
 // This ensures widget doesn't show blank screen on corrupted data
            return lastGood()
        }
    }
    
 // MARK: - Testing Support
    
 /// 清除所有缓存（测试用）
    public func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        
        lastGoodDevicesData = nil
        lastGoodMetricsData = nil
        lastGoodTransfersData = nil
    }
    
 /// 预设缓存数据（测试用）
    public func setLastGoodDevicesData(_ data: WidgetDevicesData) {
        lock.lock()
        defer { lock.unlock() }
        lastGoodDevicesData = data
    }
    
    public func setLastGoodMetricsData(_ data: WidgetMetricsData) {
        lock.lock()
        defer { lock.unlock() }
        lastGoodMetricsData = data
    }
    
    public func setLastGoodTransfersData(_ data: WidgetTransfersData) {
        lock.lock()
        defer { lock.unlock() }
        lastGoodTransfersData = data
    }
}
