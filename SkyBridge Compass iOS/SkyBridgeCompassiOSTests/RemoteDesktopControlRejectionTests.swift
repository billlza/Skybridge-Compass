import Foundation
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCompass_iOS
final class RemoteDesktopControlRejectionTests: XCTestCase {
 func testExistingHostRejectionDecodesWithoutLosingExactTransaction() throws {
  let rejection = try RemoteDesktopStreamConfigurationRejection(transaction: .init(),code:"configuration-unsupported",message:"Requested configuration is unavailable")
  let packet = try JSONSerialization.data(withJSONObject:["type":"streamConfigurationRejected","payload":JSONEncoder().encode(rejection).base64EncodedString()])
  let message = try JSONDecoder().decode(RemoteMessage.self,from:packet)
  XCTAssertEqual(message.type.rawValue,"streamConfigurationRejected")
  XCTAssertEqual(try JSONDecoder().decode(RemoteDesktopStreamConfigurationRejection.self,from:message.payload),rejection)
 }
 func testUnknownTypeStillFails() throws {
  let packet = try JSONSerialization.data(withJSONObject:["type":"unknown-control","payload":""])
  XCTAssertThrowsError(try JSONDecoder().decode(RemoteMessage.self,from:packet))
 }
 func testMalformedAuthenticatedRejectionStillFails() throws {
  let data = try JSONSerialization.data(withJSONObject:["transaction":["id":UUID().uuidString],"code":"bad\ncode","message":"not allowed"])
  XCTAssertThrowsError(try JSONDecoder().decode(RemoteDesktopStreamConfigurationRejection.self,from:data))
 }
}
