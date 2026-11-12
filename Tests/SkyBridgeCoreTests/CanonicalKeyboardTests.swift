import XCTest
import SkyBridgeProtocolCore
#if os(macOS)
import Carbon
#endif

final class CanonicalKeyboardTests: XCTestCase {
    func testNativeCodesAndWireUsagesHaveDifferentMeanings() {
        XCTAssertEqual(CanonicalKeyboard.hidUsage(macVirtualKey: 0), 0x04)
        XCTAssertEqual(CanonicalKeyboard.macVirtualKey(hidUsage: 0x04), 0)
        XCTAssertNil(CanonicalKeyboard.macVirtualKey(hidUsage: 0))
        XCTAssertEqual(CanonicalKeyboard.namespace, "usb-hid-keyboard-v1")
    }

    func testUnsupportedValuesNeverWrapIntoNativeKeys() {
        for code in [-1, 63, 72, 256, 65_536, Int.max] {
            XCTAssertNil(CanonicalKeyboard.hidUsage(macVirtualKey: code))
        }
        for usage: UInt16 in [0, 1, 2, 3, 0x32, 0x46, 0x47, 0x48, 0x66, 0x70, .max] {
            XCTAssertNil(CanonicalKeyboard.macVirtualKey(hidUsage: usage))
        }
    }

    func testPressedKeysHaveUniqueRoundTrips() {
        var nativeKeys: Set<Int> = []
        for usage: UInt16 in 0...255 {
            guard let native = CanonicalKeyboard.macVirtualKey(hidUsage: usage) else { continue }
            XCTAssertTrue(nativeKeys.insert(native).inserted)
            XCTAssertEqual(CanonicalKeyboard.hidUsage(macVirtualKey: native), usage)
        }
        XCTAssertGreaterThan(nativeKeys.count, 100)
    }

    #if os(macOS)
    func testPhysicalMappingsMatchTheNativeSDK() {
        let examples: [(Int, UInt16)] = [
            (kVK_ANSI_A, 0x04), (kVK_ANSI_Q, 0x14), (kVK_ANSI_5, 0x22),
            (kVK_ANSI_6, 0x23), (kVK_Return, 0x28), (kVK_Escape, 0x29),
            (kVK_ANSI_KeypadEnter, 0x58), (kVK_ForwardDelete, 0x4c),
            (kVK_LeftArrow, 0x50), (kVK_RightArrow, 0x4f), (kVK_F13, 0x68),
            (kVK_F20, 0x6f), (kVK_Control, 0xe0), (kVK_Shift, 0xe1),
            (kVK_Option, 0xe2), (kVK_Command, 0xe3), (kVK_RightControl, 0xe4),
            (kVK_RightShift, 0xe5), (kVK_RightOption, 0xe6), (kVK_RightCommand, 0xe7),
        ]
        for (native, usage) in examples {
            XCTAssertEqual(CanonicalKeyboard.hidUsage(macVirtualKey: native), usage)
            XCTAssertEqual(CanonicalKeyboard.macVirtualKey(hidUsage: usage), native)
        }
    }
    #endif
}
