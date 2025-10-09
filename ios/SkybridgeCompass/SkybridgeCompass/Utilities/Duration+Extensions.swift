import Foundation

extension Duration {
    var secondsDouble: Double {
        let components = self.components
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000.0
        return Double(components.seconds) + attoseconds
    }
}
