//
// PlatformAdapterTests.swift
// SkyBridgeCoreTests
//
// Platform Adapter 单元测试和属性测试
// 测试坐标归一化、坐标转换可逆性
//
// Requirements: 11.3, 11.5, 11.6
//

import Testing
import Foundation
@testable import SkyBridgeCore

// MARK: - Coordinate Normalization Tests

@Suite("Coordinate Normalization Tests")
struct CoordinateNormalizationTests {
    
 // **Feature: web-agent-integration, Property 5: 坐标归一化范围**
 // **Validates: Requirements 11.3**
    @Test("归一化坐标应在 [0.0, 1.0] 范围内")
    func testNormalizedCoordinateRange() {
 // 属性测试：对于任意屏幕坐标，归一化后应在 [0.0, 1.0] 范围内
        for _ in 0..<100 {
            let screenWidth = Int.random(in: 100...4096)
            let screenHeight = Int.random(in: 100...4096)
            let x = Double.random(in: -100...Double(screenWidth + 100))
            let y = Double.random(in: -100...Double(screenHeight + 100))
            
            let (normalizedX, normalizedY) = CoordinateConverter.normalize(
                x: x,
                y: y,
                screenWidth: screenWidth,
                screenHeight: screenHeight
            )
            
            #expect(normalizedX >= 0.0 && normalizedX <= 1.0,
                   "归一化 X 坐标应在 [0.0, 1.0] 范围内，实际值: \(normalizedX)")
            #expect(normalizedY >= 0.0 && normalizedY <= 1.0,
                   "归一化 Y 坐标应在 [0.0, 1.0] 范围内，实际值: \(normalizedY)")
        }
    }
    
    @Test("SBRemoteMouseEvent 坐标应自动裁剪到有效范围")
    func testRemoteMouseEventCoordinateClamping() {
 // 测试超出范围的坐标会被裁剪
        let event1 = SBRemoteMouseEvent(type: .move, x: -0.5, y: 1.5)
        #expect(event1.x == 0.0)
        #expect(event1.y == 1.0)
        #expect(event1.isValidCoordinate)
        
        let event2 = SBRemoteMouseEvent(type: .click, x: 2.0, y: -1.0)
        #expect(event2.x == 1.0)
        #expect(event2.y == 0.0)
        #expect(event2.isValidCoordinate)
        
 // 测试有效范围内的坐标保持不变
        let event3 = SBRemoteMouseEvent(type: .move, x: 0.5, y: 0.5)
        #expect(event3.x == 0.5)
        #expect(event3.y == 0.5)
        #expect(event3.isValidCoordinate)
    }
    
    @Test("边界坐标应正确归一化")
    func testBoundaryCoordinates() {
        let screenWidth = 1920
        let screenHeight = 1080
        
 // 左上角
        let (x1, y1) = CoordinateConverter.normalize(x: 0, y: 0, screenWidth: screenWidth, screenHeight: screenHeight)
        #expect(x1 == 0.0)
        #expect(y1 == 0.0)
        
 // 右下角
        let (x2, y2) = CoordinateConverter.normalize(x: Double(screenWidth), y: Double(screenHeight), screenWidth: screenWidth, screenHeight: screenHeight)
        #expect(x2 == 1.0)
        #expect(y2 == 1.0)
        
 // 中心点
        let (x3, y3) = CoordinateConverter.normalize(x: Double(screenWidth) / 2, y: Double(screenHeight) / 2, screenWidth: screenWidth, screenHeight: screenHeight)
        #expect(abs(x3 - 0.5) < 0.001)
        #expect(abs(y3 - 0.5) < 0.001)
    }
}

// MARK: - Coordinate Conversion Reversibility Tests

@Suite("Coordinate Conversion Reversibility Tests")
struct CoordinateConversionReversibilityTests {
    
 // **Feature: web-agent-integration, Property 6: 坐标转换可逆性**
 // **Validates: Requirements 11.5, 11.6**
    @Test("坐标转换应可逆（在浮点精度范围内）")
    func testCoordinateConversionReversibility() {
 // 属性测试：对于任意有效屏幕坐标，normalize -> denormalize 应得到原始坐标
        for _ in 0..<100 {
            let screenWidth = Int.random(in: 100...4096)
            let screenHeight = Int.random(in: 100...4096)
            let originalX = Double.random(in: 0...Double(screenWidth))
            let originalY = Double.random(in: 0...Double(screenHeight))
            
 // 归一化
            let (normalizedX, normalizedY) = CoordinateConverter.normalize(
                x: originalX,
                y: originalY,
                screenWidth: screenWidth,
                screenHeight: screenHeight
            )
            
 // 反归一化
            let (restoredX, restoredY) = CoordinateConverter.denormalize(
                x: normalizedX,
                y: normalizedY,
                screenWidth: screenWidth,
                screenHeight: screenHeight
            )
            
 // 验证可逆性（允许浮点误差）
            let tolerance = 0.001
            #expect(abs(restoredX - originalX) < tolerance,
                   "X 坐标转换不可逆: 原始=\(originalX), 恢复=\(restoredX)")
            #expect(abs(restoredY - originalY) < tolerance,
                   "Y 坐标转换不可逆: 原始=\(originalY), 恢复=\(restoredY)")
        }
    }
    
    @Test("CGPoint 坐标转换应可逆")
    func testCGPointConversionReversibility() {
        let screenSize = CGSize(width: 2560, height: 1440)
        
        for _ in 0..<100 {
            let originalPoint = CGPoint(
                x: CGFloat.random(in: 0...screenSize.width),
                y: CGFloat.random(in: 0...screenSize.height)
            )
            
            let normalized = CoordinateConverter.normalize(point: originalPoint, screenSize: screenSize)
            let restored = CoordinateConverter.denormalize(normalizedPoint: normalized, screenSize: screenSize)
            
            let tolerance: CGFloat = 0.001
            #expect(abs(restored.x - originalPoint.x) < tolerance)
            #expect(abs(restored.y - originalPoint.y) < tolerance)
        }
    }
    
    @Test("零尺寸屏幕应返回零坐标")
    func testZeroScreenSize() {
        let (x1, y1) = CoordinateConverter.normalize(x: 100, y: 100, screenWidth: 0, screenHeight: 0)
        #expect(x1 == 0.0)
        #expect(y1 == 0.0)
        
        let (x2, y2) = CoordinateConverter.denormalize(x: 0.5, y: 0.5, screenWidth: 0, screenHeight: 0)
        #expect(x2 == 0.0)
        #expect(y2 == 0.0)
    }
}

// MARK: - Remote Input Event Tests

@Suite("Remote Input Event Tests")
struct RemoteInputEventTests {
    
    @Test("SBRemoteMouseEvent 序列化 Round-Trip")
    func testRemoteMouseEventRoundTrip() throws {
        let original = SBRemoteMouseEvent(
            type: .click,
            x: 0.5,
            y: 0.75,
            button: .left,
            deltaX: nil,
            deltaY: nil,
            modifiers: SBKeyModifiers(ctrl: true, alt: false, shift: true, meta: false),
            timestamp: 1234567890.0
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SBRemoteMouseEvent.self, from: data)
        
        #expect(decoded == original)
    }
    
    @Test("SBRemoteKeyboardEvent 序列化 Round-Trip")
    func testRemoteKeyboardEventRoundTrip() throws {
        let original = SBRemoteKeyboardEvent(
            type: .down,
            keyCode: 36,
            key: "Return",
            modifiers: SBKeyModifiers(ctrl: false, alt: false, shift: false, meta: true),
            timestamp: 1234567890.0
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SBRemoteKeyboardEvent.self, from: data)
        
        #expect(decoded == original)
    }
    
    @Test("SBRemoteScrollEvent 序列化 Round-Trip")
    func testRemoteScrollEventRoundTrip() throws {
        let original = SBRemoteScrollEvent(
            deltaX: 10.5,
            deltaY: -20.0,
            modifiers: .none,
            timestamp: 1234567890.0
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SBRemoteScrollEvent.self, from: data)
        
        #expect(decoded == original)
    }
    
    @Test("SBKeyModifiers 应正确检测修饰键状态")
    func testKeyModifiersHasAnyModifier() {
        #expect(!SBKeyModifiers.none.hasAnyModifier)
        #expect(SBKeyModifiers(ctrl: true).hasAnyModifier)
        #expect(SBKeyModifiers(alt: true).hasAnyModifier)
        #expect(SBKeyModifiers(shift: true).hasAnyModifier)
        #expect(SBKeyModifiers(meta: true).hasAnyModifier)
        #expect(SBKeyModifiers(ctrl: true, alt: true, shift: true, meta: true).hasAnyModifier)
    }
}

// MARK: - Screen Capture Config Tests

@Suite("Screen Capture Config Tests")
struct ScreenCaptureConfigTests {
    
    @Test("默认配置应有正确的值")
    func testDefaultConfig() {
        let config = ScreenCaptureConfig.default
        
        #expect(config.width == nil)
        #expect(config.height == nil)
        #expect(config.frameRate == 60)
        #expect(config.pixelFormat == .bgra)
        #expect(config.showsCursor == true)
    }
    
    @Test("ScreenCaptureConfig 序列化 Round-Trip")
    func testScreenCaptureConfigRoundTrip() throws {
        let original = ScreenCaptureConfig(
            width: 1920,
            height: 1080,
            frameRate: 30,
            pixelFormat: .nv12,
            showsCursor: false
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ScreenCaptureConfig.self, from: data)
        
        #expect(decoded == original)
    }
}

// MARK: - Permission Type Tests

@Suite("Permission Type Tests")
struct PermissionTypeTests {
    
    @Test("SBPermissionType 应有正确的 rawValue")
    func testPermissionTypeRawValues() {
        #expect(SBPermissionType.screenRecording.rawValue == "screen_recording")
        #expect(SBPermissionType.accessibility.rawValue == "accessibility")
        #expect(SBPermissionType.localNetwork.rawValue == "local_network")
        #expect(SBPermissionType.camera.rawValue == "camera")
        #expect(SBPermissionType.microphone.rawValue == "microphone")
    }
    
    @Test("SBPermissionStatus 应有正确的 rawValue")
    func testPermissionStatusRawValues() {
        #expect(SBPermissionStatus.notDetermined.rawValue == "not_determined")
        #expect(SBPermissionStatus.authorized.rawValue == "authorized")
        #expect(SBPermissionStatus.denied.rawValue == "denied")
        #expect(SBPermissionStatus.restricted.rawValue == "restricted")
    }
}

// MARK: - Platform Adapter Error Tests

@Suite("Platform Adapter Error Tests")
struct PlatformAdapterErrorTests {
    
    @Test("PlatformAdapterError 应有正确的描述")
    func testPlatformAdapterErrorDescriptions() {
        let errors: [PlatformAdapterError] = [
            .noDisplayAvailable,
            .permissionDenied(SBPermissionType.screenRecording),
            .captureNotStarted,
            .inputInjectionFailed("test reason"),
            .discoveryFailed("test reason"),
            .unsupportedOperation("test operation")
        ]
        
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
}
