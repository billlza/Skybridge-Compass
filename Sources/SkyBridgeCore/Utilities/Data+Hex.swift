import Foundation

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            s.removeFirst(2)
        }

        // Allow common separators/formatting, but reject unexpected characters.
        var hex = String()
        hex.reserveCapacity(s.count)
        for ch in s {
            if ch.isHexDigit {
                hex.append(ch)
            } else if ch.isWhitespace || ch == ":" || ch == "-" {
                continue
            } else {
                return nil
            }
        }
        s = hex

        guard !s.isEmpty, s.count.isMultiple(of: 2) else { return nil }

        var out = Data()
        out.reserveCapacity(s.count / 2)

        var index = s.startIndex
        for _ in 0..<(s.count / 2) {
            let next = s.index(index, offsetBy: 2)
            let byteString = s[index..<next]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}
