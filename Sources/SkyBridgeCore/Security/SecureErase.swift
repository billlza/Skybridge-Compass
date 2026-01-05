import Foundation

public func secureErase(_ data: inout Data) {
    data.withUnsafeMutableBytes { buf in
        guard let base = buf.baseAddress else { return }
        memset(base, 0, buf.count)
    }
}

public extension Data {
    mutating func secureErase() {
        SkyBridgeCore.secureErase(&self)
    }
}
