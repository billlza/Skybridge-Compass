//
// String+UTF8Data.swift
// SkyBridgeCore
//
// Small helper to avoid force-unwrapping UTF-8 conversions.
//

import Foundation

public extension String {
 /// UTF-8 data without optionality.
    var utf8Data: Data {
        Data(utf8)
    }
}
