import SwiftUI
#if canImport(OrderedCollections)
import OrderedCollections
#endif

public struct MetricsTimelineView: View {
    let dataPoints: OrderedDictionary<Date, Double>

    public init(dataPoints: OrderedDictionary<Date, Double>) {
        self.dataPoints = dataPoints
    }

    public var body: some View {
        GeometryReader { geometry in
            let sorted = dataPoints.sorted(by: { $0.key < $1.key })
            Path { path in
                guard !sorted.isEmpty else { return }
                let width = geometry.size.width
                let height = geometry.size.height
                let times = sorted.map { $0.key.timeIntervalSince1970 }
                guard let minTime = times.min(), let maxTime = times.max(), let minValue = sorted.map({ $0.value }).min(), let maxValue = sorted.map({ $0.value }).max(), maxTime > minTime, maxValue > minValue else {
                    return
                }

                func position(for index: Int) -> CGPoint {
                    let timeRatio = (times[index] - minTime) / (maxTime - minTime)
                    let valueRatio = (sorted[index].value - minValue) / (maxValue - minValue)
                    let x = width * timeRatio
                    let y = height * (1 - valueRatio)
                    return CGPoint(x: x, y: y)
                }

                path.move(to: position(for: 0))
                for idx in sorted.indices {
                    path.addLine(to: position(for: idx))
                }
            }
            .stroke(Color.green, lineWidth: 2)
        }
    }
}

