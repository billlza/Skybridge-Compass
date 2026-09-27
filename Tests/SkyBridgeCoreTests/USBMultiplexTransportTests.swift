import Foundation
import XCTest
@testable import SkyBridgeCore

final class USBMultiplexTransportTests: XCTestCase {
    private let udid = "00008140-000E788401C0801C"

    private func row(id: UInt32, type: String = "USB") -> [String: Any] {
        ["DeviceID": id, "Properties": ["DeviceID": id, "SerialNumber": udid,
            "ConnectionType": type, "ProductID": UInt32(4776)]]
    }

    func testNetworkTwinIsNeverSelectedAsUSB() throws {
        let result = try USBMultiplexTransport.decodeDevices([
            "DeviceList": [row(id: 10, type: "Network"), row(id: 11)]
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.deviceID, 11)
        XCTAssertEqual(result.first?.udid, udid)
        XCTAssertEqual(result.first?.connectionType, "USB")
        XCTAssertTrue(try USBMultiplexTransport.decodeDevices([
            "DeviceList": [row(id: 10, type: "Network")]
        ]).isEmpty)
    }

    func testDuplicateOrMisboundDeviceIsRejected() throws {
        XCTAssertThrowsError(try USBMultiplexTransport.decodeDevices([
            "DeviceList": [row(id: 10), row(id: 11)]
        ]))
        var mismatched = row(id: 10)
        mismatched["DeviceID"] = UInt32(11)
        XCTAssertThrowsError(try USBMultiplexTransport.decodeDevices(["DeviceList": [mismatched]]))
        for invalid: Any in [true, -1, 1.5, UInt64(UInt32.max) + 1] {
            let record: [String: Any] = ["DeviceID": invalid, "Properties": [
                "DeviceID": invalid, "SerialNumber": udid, "ConnectionType": "USB", "ProductID": 4776
            ]]
            XCTAssertThrowsError(try USBMultiplexTransport.decodeDevices(["DeviceList": [record]]))
        }
        XCTAssertThrowsError(try USBMultiplexTransport.decodeDevices(["Result": 0]))
        XCTAssertThrowsError(try USBMultiplexTransport.decodeDevices(["DeviceList": [row(id: 10, type: "Other")]]))
    }

    func testFramingEnforcesVersionTypeTransactionAndBounds() throws {
        let packet = try USBMultiplexTransport.packet(Data([1, 2, 3]), tag: 0x01020304)
        XCTAssertEqual(Array(packet.prefix(16)), [19, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 4, 3, 2, 1])
        XCTAssertEqual(try USBMultiplexTransport.payloadLength(header: Data(packet.prefix(16)), tag: 0x01020304), 3)
        XCTAssertThrowsError(try USBMultiplexTransport.payloadLength(header: Data(packet.prefix(16)), tag: 5))
        for offset in [0, 4, 8, 12] {
            var bad = Data(packet.prefix(16)); bad[offset] = 0
            XCTAssertThrowsError(try USBMultiplexTransport.payloadLength(header: bad, tag: 0x01020304))
        }
        XCTAssertThrowsError(try USBMultiplexTransport.payloadLength(header: Data(packet.prefix(15)), tag: 0x01020304))
        XCTAssertThrowsError(try USBMultiplexTransport.packet(Data(), tag: 1))
        XCTAssertThrowsError(try USBMultiplexTransport.packet(Data(count: USBMultiplexTransport.maximumPacketBytes), tag: 1))
    }
}
