import CoreGraphics
import Foundation

final class CoarseDisplayDamageTracker: @unchecked Sendable {
    private let maxGridColumns: Int
    private let minGridRows: Int
    private let lumaThreshold: Int
    private let fullFrameThreshold: Double
    private var previousFingerprint: Fingerprint?

    private struct Fingerprint: Sendable {
        let columns: Int
        let rows: Int
        let luma: [UInt8]
    }

    init(
        maxGridColumns: Int = 28,
        minGridRows: Int = 10,
        lumaThreshold: Int = 10,
        fullFrameThreshold: Double = 0.55
    ) {
        self.maxGridColumns = max(8, maxGridColumns)
        self.minGridRows = max(6, minGridRows)
        self.lumaThreshold = max(1, lumaThreshold)
        self.fullFrameThreshold = min(max(fullFrameThreshold, 0.15), 0.95)
    }

    func reset() {
        previousFingerprint = nil
    }

    func analyze(image: CGImage) -> RemoteDesktopDamageReport? {
        guard let current = makeFingerprint(for: image) else {
            return fallbackReport(width: image.width, height: image.height)
        }
        defer { previousFingerprint = current }

        guard let previous = previousFingerprint,
              previous.columns == current.columns,
              previous.rows == current.rows,
              previous.luma.count == current.luma.count else {
            return fallbackReport(width: image.width, height: image.height)
        }

        let changedCells = changedCellIndices(previous: previous, current: current)
        guard !changedCells.isEmpty else { return nil }

        let changedRatio = Double(changedCells.count) / Double(max(current.luma.count, 1))
        if changedRatio >= fullFrameThreshold {
            return fallbackReport(width: image.width, height: image.height)
        }

        let rects = mergedRects(
            from: changedCells,
            columns: current.columns,
            rows: current.rows,
            imageWidth: image.width,
            imageHeight: image.height
        )
        guard !rects.isEmpty else {
            return fallbackReport(width: image.width, height: image.height)
        }
        return RemoteDesktopDamageReport(rects: rects)
    }

    private func makeFingerprint(for image: CGImage) -> Fingerprint? {
        let columns = min(maxGridColumns, max(8, image.width / 80))
        let aspectRatio = Double(max(image.height, 1)) / Double(max(image.width, 1))
        let rows = max(minGridRows, Int((Double(columns) * aspectRatio).rounded()))
        var buffer = [UInt8](repeating: 0, count: columns * rows)

        guard let context = CGContext(
            data: &buffer,
            width: columns,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: columns,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        return Fingerprint(columns: columns, rows: rows, luma: buffer)
    }

    private func changedCellIndices(previous: Fingerprint, current: Fingerprint) -> [Int] {
        var indices: [Int] = []
        indices.reserveCapacity(current.luma.count / 8)

        for index in 0..<current.luma.count {
            let delta = abs(Int(current.luma[index]) - Int(previous.luma[index]))
            if delta >= lumaThreshold {
                indices.append(index)
            }
        }

        return indices
    }

    private func mergedRects(
        from changedIndices: [Int],
        columns: Int,
        rows: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> [RemoteDesktopDamageRect] {
        let changedSet = Set(changedIndices)
        let cellWidth = Double(imageWidth) / Double(columns)
        let cellHeight = Double(imageHeight) / Double(rows)

        var rowRects: [CGRect] = []
        rowRects.reserveCapacity(rows)

        for row in 0..<rows {
            var startColumn: Int?
            for column in 0..<columns {
                let index = row * columns + column
                let isChanged = changedSet.contains(index)
                if isChanged {
                    if startColumn == nil {
                        startColumn = column
                    }
                } else if let start = startColumn {
                    rowRects.append(
                        CGRect(
                            x: Double(start) * cellWidth,
                            y: Double(row) * cellHeight,
                            width: Double(column - start) * cellWidth,
                            height: cellHeight
                        ).integral
                    )
                    startColumn = nil
                }
            }
            if let start = startColumn {
                rowRects.append(
                    CGRect(
                        x: Double(start) * cellWidth,
                        y: Double(row) * cellHeight,
                        width: Double(columns - start) * cellWidth,
                        height: cellHeight
                    ).integral
                )
            }
        }

        var merged: [CGRect] = []
        for rect in rowRects {
            if let last = merged.last,
               abs(last.minX - rect.minX) < 0.5,
               abs(last.width - rect.width) < 0.5,
               abs(last.maxY - rect.minY) < 0.5 {
                merged[merged.count - 1] = last.union(rect)
            } else {
                merged.append(rect)
            }
        }

        if merged.count > 12, let first = merged.first {
            let unionRect = merged.dropFirst().reduce(first) { $0.union($1) }
            merged = [unionRect]
        }

        return merged.map {
            RemoteDesktopDamageRect(
                x: $0.origin.x,
                y: $0.origin.y,
                width: $0.width,
                height: $0.height
            )
        }
    }

    private func fallbackReport(width: Int, height: Int) -> RemoteDesktopDamageReport {
        RemoteDesktopDamageReport(
            rects: [
                RemoteDesktopDamageRect(
                    x: 0,
                    y: 0,
                    width: Double(width),
                    height: Double(height)
                )
            ],
            fullFrameFallback: true
        )
    }
}
