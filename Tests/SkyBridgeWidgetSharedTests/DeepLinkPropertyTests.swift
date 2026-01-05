// MARK: - Deep Link Property Tests
// **Feature: macos-widgets, Property 3: Deep Link URL Generation**
// **Validates: Requirements 1.4, 2.4, 2.5**

import Testing
import Foundation
@testable import SkyBridgeWidgetShared

@Suite("Deep Link Property Tests")
struct DeepLinkPropertyTests {
    
 // MARK: - Property 3: Deep Link URL Generation
    
    @Test("Device detail URL contains device ID", arguments: 0..<100)
    func testDeviceDetailURLContainsId(iteration: Int) {
        let deviceId = WidgetTestGenerators.deviceId()
        
        guard let url = WidgetURLBuilder.deviceDetailURL(deviceId: deviceId) else {
            Issue.record("Failed to generate URL for device ID: \(deviceId)")
            return
        }
        
        #expect(url.absoluteString.contains(deviceId), """
            URL should contain device ID
            Device ID: \(deviceId)
            URL: \(url.absoluteString)
            """)
    }
    
    @Test("All URLs conform to skybridge:// scheme", arguments: 0..<50)
    func testURLScheme(iteration: Int) {
        let deviceId = WidgetTestGenerators.deviceId()
        
        let urls: [URL?] = [
            WidgetURLBuilder.devicesURL(),
            WidgetURLBuilder.deviceDetailURL(deviceId: deviceId),
            WidgetURLBuilder.monitorURL(),
            WidgetURLBuilder.transfersURL(),
            WidgetURLBuilder.scanURL(),
            WidgetURLBuilder.homeURL()
        ]
        
        for url in urls.compactMap({ $0 }) {
            #expect(url.scheme == "skybridge", """
                URL should have skybridge scheme
                URL: \(url.absoluteString)
                Scheme: \(url.scheme ?? "nil")
                """)
        }
    }
    
    @Test("Device detail URL has correct host")
    func testDeviceDetailURLHost() {
        let url = WidgetURLBuilder.deviceDetailURL(deviceId: "test-id")!
        
        #expect(url.host == "devices")
    }
    
    @Test("Device detail URL has device ID in path")
    func testDeviceDetailURLPath() {
        let deviceId = "test-device-123"
        let url = WidgetURLBuilder.deviceDetailURL(deviceId: deviceId)!
        
        #expect(url.pathComponents.contains(deviceId))
    }
    
    @Test("Empty device ID returns nil")
    func testEmptyDeviceIdReturnsNil() {
        let url = WidgetURLBuilder.deviceDetailURL(deviceId: "")
        #expect(url == nil)
    }
    
    @Test("Static URLs are valid")
    func testStaticURLsValid() {
        #expect(WidgetURLBuilder.devicesURL().absoluteString == "skybridge://devices")
        #expect(WidgetURLBuilder.monitorURL().absoluteString == "skybridge://monitor")
        #expect(WidgetURLBuilder.transfersURL().absoluteString == "skybridge://transfers")
        #expect(WidgetURLBuilder.scanURL().absoluteString == "skybridge://scan")
        #expect(WidgetURLBuilder.homeURL().absoluteString == "skybridge://")
    }
    
 // MARK: - URL Parsing Tests
    
    @Test("Generated URLs can be parsed back")
    func testURLParsing() {
        let deviceId = "device-abc-123"
        let url = WidgetURLBuilder.deviceDetailURL(deviceId: deviceId)!
        
 // Parse the URL
        #expect(url.scheme == "skybridge")
        #expect(url.host == "devices")
        
 // Extract device ID from path
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        #expect(pathComponents.contains(deviceId))
    }
}
