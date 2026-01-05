import SwiftUI

public struct MetricView: View {
    let title: String
    let value: Int

    public init(title: String, value: Int) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.bold())
                .foregroundStyle(.white)
        }
    }
}

