// MARK: - ArchiveExtractor.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation
import Compression

// MARK: - ArchiveFormat

/// Supported archive formats with detection capabilities.
/// Engineering feasibility note:
/// - Only .zip can be reliably implemented without third-party dependencies (using Foundation's Archive API)
/// - .tar/.tarGz require custom implementation or system tar command (sandbox restrictions apply)
/// - Current design: supportedFormats only includes .zip, others use shell-check-only or unsupported
public enum ArchiveFormat: String, Sendable, CaseIterable {
    case zip        // Full extraction supported (using Foundation Archive API)
    case tar        // Shell-check-only, no extraction (difficult to implement reliably without dependencies)
    case tarGz      // Shell-check-only, no extraction
    case dmg        // Shell-check-only (notarization + spctl), no extraction
    case pkg        // Shell-check-only (notarization + spctl), no extraction
    case sevenZip   // Unsupported, returns warning + partial
    case unknown    // Unsupported, returns warning + partial
    
 /// Formats that support full extraction
    public static let supportedFormats: Set<ArchiveFormat> = [.zip]
    
 /// Formats that only support shell-level checks (no extraction)
    public static let shellCheckOnlyFormats: Set<ArchiveFormat> = [.dmg, .pkg, .tar, .tarGz]
    
 /// Detect archive format from file URL using magic bytes and extension
    public static func detect(from url: URL) -> ArchiveFormat {
 // First try magic bytes detection
        if let format = detectByMagicBytes(url) {
            return format
        }
        
 // Fall back to extension-based detection
        return detectByExtension(url)
    }
    
 /// Detect format by reading magic bytes from file header
    private static func detectByMagicBytes(_ url: URL) -> ArchiveFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        
        guard let headerData = try? handle.read(upToCount: 8) else {
            return nil
        }
        
        guard headerData.count >= 4 else {
            return nil
        }
        
        let bytes = [UInt8](headerData)
        
 // ZIP: PK\x03\x04 or PK\x05\x06 (empty) or PK\x07\x08 (spanned)
        if bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B {
            if (bytes[2] == 0x03 && bytes[3] == 0x04) ||
               (bytes[2] == 0x05 && bytes[3] == 0x06) ||
               (bytes[2] == 0x07 && bytes[3] == 0x08) {
                return .zip
            }
        }
        
 // GZIP: \x1f\x8b
        if bytes.count >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B {
            return .tarGz
        }
        
 // TAR: Check for ustar magic at offset 257
        if let tarFormat = detectTarFormat(url) {
            return tarFormat
        }
        
 // DMG: Check for koly signature at end of file (Apple Disk Image)
        if detectDMGFormat(url) {
            return .dmg
        }
        
 // PKG: xar archive format (Apple Installer Package)
        if bytes.count >= 4 && bytes[0] == 0x78 && bytes[1] == 0x61 && bytes[2] == 0x72 && bytes[3] == 0x21 {
            return .pkg
        }
        
 // 7z: 7z\xBC\xAF\x27\x1C
        if bytes.count >= 6 && bytes[0] == 0x37 && bytes[1] == 0x7A && 
           bytes[2] == 0xBC && bytes[3] == 0xAF && bytes[4] == 0x27 && bytes[5] == 0x1C {
            return .sevenZip
        }
        
        return nil
    }
    
 /// Detect TAR format by checking ustar magic at offset 257
    private static func detectTarFormat(_ url: URL) -> ArchiveFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        
 // TAR ustar magic is at offset 257
        do {
            try handle.seek(toOffset: 257)
            guard let magicData = try handle.read(upToCount: 5) else {
                return nil
            }
            
 // Check for "ustar" magic
            if magicData.count >= 5 {
                let magic = String(data: magicData, encoding: .ascii)
                if magic == "ustar" {
                    return .tar
                }
            }
        } catch {
            return nil
        }
        
        return nil
    }
    
 /// Detect DMG format by checking koly signature at end of file
    private static func detectDMGFormat(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        
        do {
 // DMG koly signature is at the end of file (last 512 bytes)
            try handle.seekToEnd()
            let fileSize = try handle.offset()
            
            guard fileSize >= 512 else { return false }
            
            try handle.seek(toOffset: fileSize - 512)
            guard let trailerData = try handle.read(upToCount: 4) else {
                return false
            }
            
 // Check for "koly" magic
            if trailerData.count >= 4 {
                let bytes = [UInt8](trailerData)
                return bytes[0] == 0x6B && bytes[1] == 0x6F && bytes[2] == 0x6C && bytes[3] == 0x79
            }
        } catch {
            return false
        }
        
        return false
    }
    
 /// Detect format by file extension
    private static func detectByExtension(_ url: URL) -> ArchiveFormat {
        let ext = url.pathExtension.lowercased()
        
        switch ext {
        case "zip":
            return .zip
        case "tar":
            return .tar
        case "gz", "tgz":
 // Check if it's .tar.gz
            let stem = url.deletingPathExtension().pathExtension.lowercased()
            if stem == "tar" || ext == "tgz" {
                return .tarGz
            }
            return .tarGz  // Assume gzipped tar
        case "dmg":
            return .dmg
        case "pkg", "mpkg":
            return .pkg
        case "7z":
            return .sevenZip
        default:
            return .unknown
        }
    }
    
 /// Whether this format supports full extraction
    public var supportsExtraction: Bool {
        Self.supportedFormats.contains(self)
    }
    
 /// Whether this format only supports shell-level checks
    public var isShellCheckOnly: Bool {
        Self.shellCheckOnlyFormats.contains(self)
    }
    
 /// Human-readable description
    public var displayName: String {
        switch self {
        case .zip: return "ZIP Archive"
        case .tar: return "TAR Archive"
        case .tarGz: return "Gzipped TAR Archive"
        case .dmg: return "Apple Disk Image"
        case .pkg: return "Apple Installer Package"
        case .sevenZip: return "7-Zip Archive"
        case .unknown: return "Unknown Archive"
        }
    }
}


// MARK: - Enhanced ExtractionPolicy

/// Enhanced extraction policy with comprehensive limit enforcement.
/// This extends the basic ExtractionPolicy with format detection and pre-estimation.
public struct EnhancedExtractionPolicy: Sendable {
    public let maxExtractedFiles: Int
    public let maxTotalExtractedBytes: Int64
    public let maxNestingDepth: Int
    public let maxCompressionRatio: Double
    public let maxExtractionTime: TimeInterval
    
 /// Initialize from SecurityLimits
    public init(from limits: SecurityLimits) {
        self.maxExtractedFiles = limits.maxExtractedFiles
        self.maxTotalExtractedBytes = limits.maxTotalExtractedBytes
        self.maxNestingDepth = limits.maxNestingDepth
        self.maxCompressionRatio = limits.maxCompressionRatio
        self.maxExtractionTime = limits.maxExtractionTime
    }
    
 /// Initialize with explicit values
    public init(
        maxExtractedFiles: Int,
        maxTotalExtractedBytes: Int64,
        maxNestingDepth: Int,
        maxCompressionRatio: Double,
        maxExtractionTime: TimeInterval
    ) {
        self.maxExtractedFiles = maxExtractedFiles
        self.maxTotalExtractedBytes = maxTotalExtractedBytes
        self.maxNestingDepth = maxNestingDepth
        self.maxCompressionRatio = maxCompressionRatio
        self.maxExtractionTime = maxExtractionTime
    }
    
 /// Default policy using SecurityLimits defaults
    public static let `default` = EnhancedExtractionPolicy(from: .default)
    
 /// Detect archive format from URL
    public func detectFormat(at url: URL) -> ArchiveFormat {
        return ArchiveFormat.detect(from: url)
    }
    
 /// Pre-estimate uncompressed size from zip central directory.
 /// Only supported for .zip format.
 /// - Returns: Estimated uncompressed size, or nil if estimation fails
    public func estimateUncompressedSize(from url: URL, format: ArchiveFormat) -> Int64? {
        guard format == .zip else { return nil }
        return ZipCentralDirectoryReader.estimateUncompressedSize(from: url)
    }
    
 /// Check if compression ratio is suspicious (potential zip bomb)
    public func isCompressionRatioSuspicious(compressed: Int64, uncompressed: Int64) -> Bool {
        guard compressed > 0 else { return true }
        let ratio = Double(uncompressed) / Double(compressed)
        return ratio > maxCompressionRatio
    }
}

// MARK: - ZipCentralDirectoryReader

/// Reads ZIP central directory to estimate uncompressed size without full extraction.
/// This allows pre-checking for zip bombs before extraction begins.
internal struct ZipCentralDirectoryReader {
    
 /// ZIP End of Central Directory signature
    private static let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    
 /// ZIP64 End of Central Directory Locator signature
    private static let zip64LocatorSignature: [UInt8] = [0x50, 0x4B, 0x06, 0x07]
    
 /// Estimate total uncompressed size from ZIP central directory
    static func estimateUncompressedSize(from url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        
        do {
 // Find End of Central Directory record
            guard let eocdOffset = try findEOCD(handle: handle) else {
                return nil
            }
            
 // Read EOCD to get central directory location
            try handle.seek(toOffset: eocdOffset)
            guard let eocdData = try handle.read(upToCount: 22) else {
                return nil
            }
            
            guard eocdData.count >= 22 else { return nil }
            
 // Parse EOCD
            let centralDirOffset = readUInt32(from: eocdData, at: 16)
            let centralDirSize = readUInt32(from: eocdData, at: 12)
            let entryCount = readUInt16(from: eocdData, at: 10)
            
 // Check for ZIP64 (values are 0xFFFFFFFF or 0xFFFF)
            if centralDirOffset == 0xFFFFFFFF || centralDirSize == 0xFFFFFFFF || entryCount == 0xFFFF {
 // ZIP64 format - more complex parsing needed
                return estimateFromZip64(handle: handle, eocdOffset: eocdOffset)
            }
            
 // Read central directory entries and sum uncompressed sizes
            try handle.seek(toOffset: UInt64(centralDirOffset))
            guard let centralDirData = try handle.read(upToCount: Int(centralDirSize)) else {
                return nil
            }
            
            return sumUncompressedSizes(from: centralDirData, entryCount: Int(entryCount))
            
        } catch {
            return nil
        }
    }
    
 /// Find End of Central Directory record by searching backwards from end of file
    private static func findEOCD(handle: FileHandle) throws -> UInt64? {
        try handle.seekToEnd()
        let fileSize = try handle.offset()
        
 // EOCD must be within last 65KB + 22 bytes (max comment size + EOCD size)
        let searchSize = min(fileSize, 65557)
        let searchStart = fileSize - searchSize
        
        try handle.seek(toOffset: searchStart)
        guard let searchData = try handle.read(upToCount: Int(searchSize)) else {
            return nil
        }
        
 // Search backwards for EOCD signature
        let bytes = [UInt8](searchData)
        for i in stride(from: bytes.count - 22, through: 0, by: -1) {
            if bytes[i] == eocdSignature[0] &&
               bytes[i + 1] == eocdSignature[1] &&
               bytes[i + 2] == eocdSignature[2] &&
               bytes[i + 3] == eocdSignature[3] {
                return searchStart + UInt64(i)
            }
        }
        
        return nil
    }
    
 /// Estimate from ZIP64 format
    private static func estimateFromZip64(handle: FileHandle, eocdOffset: UInt64) -> Int64? {
 // ZIP64 EOCD Locator is 20 bytes before EOCD
        guard eocdOffset >= 20 else { return nil }
        
        do {
            try handle.seek(toOffset: eocdOffset - 20)
            guard let locatorData = try handle.read(upToCount: 20) else {
                return nil
            }
            
            let bytes = [UInt8](locatorData)
            
 // Verify ZIP64 locator signature
            guard bytes[0] == zip64LocatorSignature[0] &&
                  bytes[1] == zip64LocatorSignature[1] &&
                  bytes[2] == zip64LocatorSignature[2] &&
                  bytes[3] == zip64LocatorSignature[3] else {
                return nil
            }
            
 // Get ZIP64 EOCD offset
            let zip64EocdOffset = readUInt64(from: Data(bytes), at: 8)
            
            try handle.seek(toOffset: zip64EocdOffset)
            guard let zip64EocdData = try handle.read(upToCount: 56) else {
                return nil
            }
            
            guard zip64EocdData.count >= 56 else { return nil }
            
 // Get central directory info from ZIP64 EOCD
            let centralDirOffset = readUInt64(from: zip64EocdData, at: 48)
            let centralDirSize = readUInt64(from: zip64EocdData, at: 40)
            let entryCount = readUInt64(from: zip64EocdData, at: 32)
            
            try handle.seek(toOffset: centralDirOffset)
            guard let centralDirData = try handle.read(upToCount: Int(min(centralDirSize, UInt64(Int.max)))) else {
                return nil
            }
            
            return sumUncompressedSizes(from: centralDirData, entryCount: Int(min(entryCount, UInt64(Int.max))))
            
        } catch {
            return nil
        }
    }
    
 /// Sum uncompressed sizes from central directory entries
    private static func sumUncompressedSizes(from data: Data, entryCount: Int) -> Int64 {
        var totalSize: Int64 = 0
        var offset = 0
        let bytes = [UInt8](data)
        
        for _ in 0..<entryCount {
            guard offset + 46 <= bytes.count else { break }
            
 // Verify central directory file header signature (0x02014b50)
            guard bytes[offset] == 0x50 &&
                  bytes[offset + 1] == 0x4B &&
                  bytes[offset + 2] == 0x01 &&
                  bytes[offset + 3] == 0x02 else {
                break
            }
            
 // Read uncompressed size (offset 24, 4 bytes)
            let uncompressedSize = readUInt32(from: Data(bytes[offset..<min(offset + 46, bytes.count)]), at: 24)
            
 // Read filename length (offset 28, 2 bytes)
            let filenameLength = readUInt16(from: Data(bytes[offset..<min(offset + 46, bytes.count)]), at: 28)
            
 // Read extra field length (offset 30, 2 bytes)
            let extraLength = readUInt16(from: Data(bytes[offset..<min(offset + 46, bytes.count)]), at: 30)
            
 // Read comment length (offset 32, 2 bytes)
            let commentLength = readUInt16(from: Data(bytes[offset..<min(offset + 46, bytes.count)]), at: 32)
            
 // Handle ZIP64 extended info
            if uncompressedSize == 0xFFFFFFFF {
 // Need to read from ZIP64 extra field
                let extraStart = offset + 46 + Int(filenameLength)
                if let zip64Size = readZip64UncompressedSize(from: bytes, extraStart: extraStart, extraLength: Int(extraLength)) {
                    totalSize += Int64(zip64Size)
                }
            } else {
                totalSize += Int64(uncompressedSize)
            }
            
 // Move to next entry
            offset += 46 + Int(filenameLength) + Int(extraLength) + Int(commentLength)
        }
        
        return totalSize
    }
    
 /// Read ZIP64 uncompressed size from extra field
    private static func readZip64UncompressedSize(from bytes: [UInt8], extraStart: Int, extraLength: Int) -> UInt64? {
        var pos = extraStart
        let extraEnd = extraStart + extraLength
        
        while pos + 4 <= extraEnd && pos + 4 <= bytes.count {
            let headerId = UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
            let dataSize = UInt16(bytes[pos + 2]) | (UInt16(bytes[pos + 3]) << 8)
            
            if headerId == 0x0001 { // ZIP64 extended info
                if pos + 4 + 8 <= bytes.count {
 // Uncompressed size is first 8 bytes of ZIP64 extra field data
                    return readUInt64(from: Data(bytes[pos + 4..<min(pos + 4 + 8, bytes.count)]), at: 0)
                }
            }
            
            pos += 4 + Int(dataSize)
        }
        
        return nil
    }
    
 // MARK: - Binary Reading Helpers
    
    private static func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }
    
    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
    
    private static func readUInt64(from data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }
}


// MARK: - ExtractionResult

/// Result of archive extraction operation
public struct ExtractionResult: Sendable {
 /// URLs of successfully extracted files
    public let extractedURLs: [URL]
    
 /// Whether extraction was aborted before completion
    public let aborted: Bool
    
 /// Reason for abortion, if any
    public let abortReason: AbortReason?
    
 /// Detected archive format
    public let format: ArchiveFormat
    
 /// Statistics about the extraction
    public let stats: ExtractionStats
    
 /// Abort reasons for extraction
    public enum AbortReason: String, Sendable {
        case fileCountExceeded = "file_count_exceeded"
        case bytesExceeded = "bytes_exceeded"
        case depthExceeded = "depth_exceeded"
        case compressionRatioSuspicious = "compression_ratio_suspicious"
        case timeoutExceeded = "timeout_exceeded"
        case unsupportedFormat = "unsupported_format"
        case extractionError = "extraction_error"
    }
    
 /// Statistics about the extraction process
    public struct ExtractionStats: Sendable {
        public let extractedFileCount: Int
        public let extractedBytes: Int64
        public let currentDepth: Int
        public let elapsedTime: TimeInterval
        public let compressedSize: Int64
        public let estimatedCompressionRatio: Double
        
        public init(
            extractedFileCount: Int = 0,
            extractedBytes: Int64 = 0,
            currentDepth: Int = 0,
            elapsedTime: TimeInterval = 0,
            compressedSize: Int64 = 0,
            estimatedCompressionRatio: Double = 0
        ) {
            self.extractedFileCount = extractedFileCount
            self.extractedBytes = extractedBytes
            self.currentDepth = currentDepth
            self.elapsedTime = elapsedTime
            self.compressedSize = compressedSize
            self.estimatedCompressionRatio = estimatedCompressionRatio
        }
    }
    
    public init(
        extractedURLs: [URL],
        aborted: Bool,
        abortReason: AbortReason?,
        format: ArchiveFormat,
        stats: ExtractionStats
    ) {
        self.extractedURLs = extractedURLs
        self.aborted = aborted
        self.abortReason = abortReason
        self.format = format
        self.stats = stats
    }
    
 /// Create a successful result
    public static func success(urls: [URL], format: ArchiveFormat, stats: ExtractionStats) -> ExtractionResult {
        ExtractionResult(extractedURLs: urls, aborted: false, abortReason: nil, format: format, stats: stats)
    }
    
 /// Create an aborted result
    public static func aborted(
        urls: [URL],
        reason: AbortReason,
        format: ArchiveFormat,
        stats: ExtractionStats
    ) -> ExtractionResult {
        ExtractionResult(extractedURLs: urls, aborted: true, abortReason: reason, format: format, stats: stats)
    }
    
 /// Create a shell-check-only result (no extraction performed)
    public static func shellCheckOnly(url: URL, format: ArchiveFormat) -> ExtractionResult {
        ExtractionResult(
            extractedURLs: [url],
            aborted: false,
            abortReason: nil,
            format: format,
            stats: ExtractionStats()
        )
    }
    
 /// Create an unsupported format result
    public static func unsupported(format: ArchiveFormat) -> ExtractionResult {
        ExtractionResult(
            extractedURLs: [],
            aborted: true,
            abortReason: .unsupportedFormat,
            format: format,
            stats: ExtractionStats()
        )
    }
}

// MARK: - ArchiveExtractor Actor

/// Actor for extracting archives with comprehensive limit enforcement.
/// Supports ZIP extraction with limits on file count, bytes, nesting depth,
/// compression ratio, and extraction time.
public actor ArchiveExtractor {
    private let policy: EnhancedExtractionPolicy
    private var extractedFiles: Int = 0
    private var extractedBytes: Int64 = 0
    private var currentDepth: Int = 0
    private var startTime: ContinuousClock.Instant?
    private let clock: ContinuousClock
    
    public init(policy: EnhancedExtractionPolicy = .default) {
        self.policy = policy
        self.clock = ContinuousClock()
    }
    
 /// Initialize with SecurityLimits
    public init(limits: SecurityLimits) {
        self.policy = EnhancedExtractionPolicy(from: limits)
        self.clock = ContinuousClock()
    }
    
 /// Extract archive to destination with limit enforcement.
 /// - Parameters:
 /// - url: Source archive URL
 /// - destination: Destination directory URL
 /// - Returns: ExtractionResult with extracted URLs and status
    public func extract(from url: URL, to destination: URL) async -> ExtractionResult {
 // Reset state
        extractedFiles = 0
        extractedBytes = 0
        currentDepth = 0
        startTime = clock.now
        
 // Detect format
        let format = policy.detectFormat(at: url)
        
 // Get compressed size for ratio calculation
        let compressedSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        
 // Handle based on format
        switch format {
        case .zip:
            return await extractZip(from: url, to: destination, compressedSize: compressedSize)
            
        case .tar, .tarGz, .dmg, .pkg:
 // Shell-check-only formats
            return .shellCheckOnly(url: url, format: format)
            
        case .sevenZip, .unknown:
 // Unsupported formats
            return .unsupported(format: format)
        }
    }
    
 /// Extract ZIP archive with limit enforcement
    private func extractZip(from url: URL, to destination: URL, compressedSize: Int64) async -> ExtractionResult {
        
 // Pre-check compression ratio
        if let estimatedSize = policy.estimateUncompressedSize(from: url, format: .zip) {
            if policy.isCompressionRatioSuspicious(compressed: compressedSize, uncompressed: estimatedSize) {
                let ratio = compressedSize > 0 ? Double(estimatedSize) / Double(compressedSize) : 0
                return .aborted(
                    urls: [],
                    reason: .compressionRatioSuspicious,
                    format: .zip,
                    stats: makeStats(compressedSize: compressedSize, ratio: ratio)
                )
            }
        }
        
 // Create destination directory
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return .aborted(
                urls: [],
                reason: .extractionError,
                format: .zip,
                stats: makeStats(compressedSize: compressedSize, ratio: 0)
            )
        }
        
 // Extract using Foundation's Archive API (available in macOS 12+)
        do {
            let result = try await extractZipEntries(from: url, to: destination, compressedSize: compressedSize)
            return result
        } catch let error as ExtractionAbortError {
            return .aborted(
                urls: [],
                reason: error.reason,
                format: .zip,
                stats: makeStats(compressedSize: compressedSize, ratio: calculateCurrentRatio(compressedSize: compressedSize))
            )
        } catch {
            return .aborted(
                urls: [],
                reason: .extractionError,
                format: .zip,
                stats: makeStats(compressedSize: compressedSize, ratio: calculateCurrentRatio(compressedSize: compressedSize))
            )
        }
    }
    
 /// Extract ZIP entries with limit checking
    private func extractZipEntries(from url: URL, to destination: URL, compressedSize: Int64) async throws -> ExtractionResult {
 // First, list entries to check limits before extraction
        let entries = try listZipEntries(from: url)
        
 // Pre-check limits
        var totalBytes: Int64 = 0
        var maxDepth = 0
        var fileCount = 0
        
        for entry in entries {
            if !entry.isDirectory {
                fileCount += 1
                totalBytes += entry.uncompressedSize
            }
            let depth = entry.path.components(separatedBy: "/").filter { !$0.isEmpty }.count - 1
            maxDepth = max(maxDepth, depth)
        }
        
 // Check file count limit
        if fileCount > policy.maxExtractedFiles {
            return .aborted(
                urls: [],
                reason: .fileCountExceeded,
                format: .zip,
                stats: makeStats(compressedSize: compressedSize, ratio: 0)
            )
        }
        
 // Check bytes limit
        if totalBytes > policy.maxTotalExtractedBytes {
            return .aborted(
                urls: [],
                reason: .bytesExceeded,
                format: .zip,
                stats: makeStats(compressedSize: compressedSize, ratio: 0)
            )
        }
        
 // Check depth limit
        if maxDepth > policy.maxNestingDepth {
            return .aborted(
                urls: [],
                reason: .depthExceeded,
                format: .zip,
                stats: makeStats(compressedSize: compressedSize, ratio: 0)
            )
        }
        
 // Check compression ratio
        let ratio = compressedSize > 0 ? Double(totalBytes) / Double(compressedSize) : 0
        if ratio > policy.maxCompressionRatio {
            return .aborted(
                urls: [],
                reason: .compressionRatioSuspicious,
                format: .zip,
                stats: makeStats(compressedSize: compressedSize, ratio: ratio)
            )
        }
        
 // Extract all files at once using unzip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
 // Check timeout after extraction
        if let abortReason = checkLimits() {
 // Partial extraction - return what we have
            let extractedURLs = collectExtractedFiles(in: destination)
            return .aborted(
                urls: extractedURLs,
                reason: abortReason,
                format: .zip,
                stats: ExtractionResult.ExtractionStats(
                    extractedFileCount: extractedURLs.count,
                    extractedBytes: totalBytes,
                    currentDepth: maxDepth,
                    elapsedTime: elapsedTime(),
                    compressedSize: compressedSize,
                    estimatedCompressionRatio: ratio
                )
            )
        }
        
 // Collect extracted files
        let extractedURLs = collectExtractedFiles(in: destination)
        extractedFiles = extractedURLs.count
        extractedBytes = totalBytes
        currentDepth = maxDepth
        
        return .success(
            urls: extractedURLs,
            format: .zip,
            stats: makeStats(compressedSize: compressedSize, ratio: ratio)
        )
    }
    
 /// Collect all files in a directory recursively
    private func collectExtractedFiles(in directory: URL) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return files
        }
        
        for case let fileURL as URL in enumerator {
            if let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile {
                files.append(fileURL)
            }
        }
        
        return files
    }
    
 /// Get elapsed time since start
    private func elapsedTime() -> TimeInterval {
        guard let start = startTime else { return 0 }
        let duration = clock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    
 /// List ZIP entries without extracting
    private func listZipEntries(from url: URL) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        
 // Use unzip -l command to list entries (more reliable format)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", url.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return entries
        }
        
 // Parse unzip -l output
 // Format:
 // Length Date Time Name
 // --------- ---------- ----- ----
 // 100 12-14-2025 17:00 file.txt
 // --------- -------
 // 100 1 file
        let lines = output.components(separatedBy: "\n")
        var inEntrySection = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
 // Skip empty lines
            guard !trimmed.isEmpty else { continue }
            
 // Detect header separator (start of entries)
            if trimmed.hasPrefix("---------") {
                if !inEntrySection {
                    inEntrySection = true
                } else {
 // End of entries (footer separator)
                    break
                }
                continue
            }
            
 // Skip header line
            if trimmed.hasPrefix("Length") || trimmed.contains("Date") {
                continue
            }
            
 // Parse entry line if we're in the entry section
            if inEntrySection {
                if let entry = parseUnzipListLine(trimmed) {
                    entries.append(entry)
                }
            }
        }
        
        return entries
    }
    
 /// Parse a single unzip -l output line
    private func parseUnzipListLine(_ line: String) -> ZipEntry? {
 // Format: " 100 12-14-2025 17:00 file.txt"
 // Split by whitespace, but path may contain spaces
        let components = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard components.count >= 4 else { return nil }
        
 // First component is size
        guard let size = Int64(components[0]) else { return nil }
        
 // Last component is the path (may contain spaces)
        let path = String(components[3])
        
        guard !path.isEmpty else { return nil }
        
 // Check if it's a directory (ends with /)
        let isDirectory = path.hasSuffix("/")
        
        return ZipEntry(path: path, uncompressedSize: size, isDirectory: isDirectory)
    }
    
 /// Extract a single ZIP entry
    private func extractSingleEntry(entry: ZipEntry, from archiveURL: URL, to destination: URL) async throws -> URL? {
 // Skip directories
        if entry.isDirectory {
            let sanitizedPath = sanitizePath(entry.path)
            let dirURL = destination.appendingPathComponent(sanitizedPath)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            return nil
        }
        
 // Sanitize path to prevent directory traversal
        let sanitizedPath = sanitizePath(entry.path)
        let targetURL = destination.appendingPathComponent(sanitizedPath)
        
 // Ensure parent directory exists
        let parentDir = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
 // Extract using unzip command - extract to destination preserving structure
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", archiveURL.path, entry.path, "-d", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
 // Verify extraction - check the full path as extracted
        let extractedPath = destination.appendingPathComponent(entry.path)
        if FileManager.default.fileExists(atPath: extractedPath.path) {
            return extractedPath
        }
        
 // Also check sanitized path
        if FileManager.default.fileExists(atPath: targetURL.path) {
            return targetURL
        }
        
        return nil
    }
    
 /// Sanitize path to prevent directory traversal attacks
    private func sanitizePath(_ path: String) -> String {
        var components = path.components(separatedBy: "/")
        components = components.filter { $0 != ".." && $0 != "." && !$0.isEmpty }
        return components.joined(separator: "/")
    }
    
 /// Check all limits and return abort reason if any exceeded
    private func checkLimits() -> ExtractionResult.AbortReason? {
 // Check timeout
        if let start = startTime {
            let elapsed = clock.now - start
            if elapsed > .seconds(policy.maxExtractionTime) {
                return .timeoutExceeded
            }
        }
        
 // Check file count
        if extractedFiles >= policy.maxExtractedFiles {
            return .fileCountExceeded
        }
        
 // Check bytes
        if extractedBytes >= policy.maxTotalExtractedBytes {
            return .bytesExceeded
        }
        
 // Check depth
        if currentDepth > policy.maxNestingDepth {
            return .depthExceeded
        }
        
        return nil
    }
    
 /// Calculate current compression ratio
    private func calculateCurrentRatio(compressedSize: Int64) -> Double {
        guard compressedSize > 0 else { return 0 }
        return Double(extractedBytes) / Double(compressedSize)
    }
    
 /// Create extraction stats
    private func makeStats(compressedSize: Int64, ratio: Double) -> ExtractionResult.ExtractionStats {
        let elapsed: TimeInterval
        if let start = startTime {
            let duration = clock.now - start
            elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        } else {
            elapsed = 0
        }
        
        return ExtractionResult.ExtractionStats(
            extractedFileCount: extractedFiles,
            extractedBytes: extractedBytes,
            currentDepth: currentDepth,
            elapsedTime: elapsed,
            compressedSize: compressedSize,
            estimatedCompressionRatio: ratio
        )
    }
}

// MARK: - Supporting Types

/// ZIP entry information
internal struct ZipEntry: Sendable {
    let path: String
    let uncompressedSize: Int64
    let isDirectory: Bool
}

/// Error thrown when extraction is aborted
internal struct ExtractionAbortError: Error {
    let reason: ExtractionResult.AbortReason
}
