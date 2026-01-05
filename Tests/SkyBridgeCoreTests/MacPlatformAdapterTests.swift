//
// MacPlatformAdapterTests.swift
// SkyBridgeCoreTests
//
// MacPlatformAdapter 单元测试
// 测试输入注入事件生成
//
// Requirements: 5.1, 5.2, 5.4, 5.5
//

import Testing
import Foundation
import CoreGraphics
@testable import SkyBridgeCore

// MARK: - Mac Platform Adapter Tests

@Suite("MacPlatformAdapter Tests")
struct MacPlatformAdapterTests {
    
    @Test("MacPlatformAdapter 应正确初始化")
    func testInitialization() {
        if #available(macOS 14.0, *) {
            let adapter = MacPlatformAdapter()
 // 验证适配器可以正常创建
            _ = adapter  // 使用变量避免警告
        }
    }
    
    @Test("权限类型应正确映射")
    func testPermissionTypeMapping() {
        #expect(SBPermissionType.screenRecording.rawValue == "screen_recording")
        #expect(SBPermissionType.accessibility.rawValue == "accessibility")
        #expect(SBPermissionType.localNetwork.rawValue == "local_network")
    }
}

// MARK: - Input Event Generation Tests

@Suite("Input Event Generation Tests")
struct InputEventGenerationTests {
    
    @Test("鼠标移动事件应正确生成")
    func testMouseMoveEventGeneration() {
        let event = SBRemoteMouseEvent(
            type: .move,
            x: 0.5,
            y: 0.5,
            button: nil,
            modifiers: .none
        )
        
        #expect(event.type == .move)
        #expect(event.x == 0.5)
        #expect(event.y == 0.5)
        #expect(event.button == nil)
        #expect(event.isValidCoordinate)
    }
    
    @Test("鼠标点击事件应正确生成")
    func testMouseClickEventGeneration() {
        let event = SBRemoteMouseEvent(
            type: .click,
            x: 0.25,
            y: 0.75,
            button: .left,
            modifiers: SBKeyModifiers(ctrl: true)
        )
        
        #expect(event.type == .click)
        #expect(event.x == 0.25)
        #expect(event.y == 0.75)
        #expect(event.button == .left)
        #expect(event.modifiers.ctrl == true)
        #expect(event.modifiers.alt == false)
    }
    
    @Test("鼠标右键点击事件应正确生成")
    func testMouseRightClickEventGeneration() {
        let event = SBRemoteMouseEvent(
            type: .click,
            x: 0.5,
            y: 0.5,
            button: .right,
            modifiers: .none
        )
        
        #expect(event.button == .right)
    }
    
    @Test("鼠标中键点击事件应正确生成")
    func testMouseMiddleClickEventGeneration() {
        let event = SBRemoteMouseEvent(
            type: .click,
            x: 0.5,
            y: 0.5,
            button: .middle,
            modifiers: .none
        )
        
        #expect(event.button == .middle)
    }
    
    @Test("鼠标双击事件应正确生成")
    func testMouseDoubleClickEventGeneration() {
        let event = SBRemoteMouseEvent(
            type: .doubleClick,
            x: 0.5,
            y: 0.5,
            button: .left,
            modifiers: .none
        )
        
        #expect(event.type == .doubleClick)
    }
    
    @Test("键盘按下事件应正确生成")
    func testKeyboardDownEventGeneration() {
        let event = SBRemoteKeyboardEvent(
            type: .down,
            keyCode: 36,  // Return key
            key: "Return",
            modifiers: .none
        )
        
        #expect(event.type == .down)
        #expect(event.keyCode == 36)
        #expect(event.key == "Return")
    }
    
    @Test("键盘释放事件应正确生成")
    func testKeyboardUpEventGeneration() {
        let event = SBRemoteKeyboardEvent(
            type: .up,
            keyCode: 36,
            key: "Return",
            modifiers: .none
        )
        
        #expect(event.type == .up)
    }
    
    @Test("带修饰键的键盘事件应正确生成")
    func testKeyboardEventWithModifiers() {
        let event = SBRemoteKeyboardEvent(
            type: .down,
            keyCode: 0,  // A key
            key: "a",
            modifiers: SBKeyModifiers(ctrl: false, alt: false, shift: false, meta: true)
        )
        
        #expect(event.modifiers.meta == true)
        #expect(event.modifiers.ctrl == false)
    }
    
    @Test("滚动事件应正确生成")
    func testScrollEventGeneration() {
        let event = SBRemoteScrollEvent(
            deltaX: 10.0,
            deltaY: -20.0,
            modifiers: .none
        )
        
        #expect(event.deltaX == 10.0)
        #expect(event.deltaY == -20.0)
    }
    
    @Test("带修饰键的滚动事件应正确生成")
    func testScrollEventWithModifiers() {
        let event = SBRemoteScrollEvent(
            deltaX: 0,
            deltaY: -100,
            modifiers: SBKeyModifiers(shift: true)
        )
        
        #expect(event.modifiers.shift == true)
    }
}

// MARK: - Coordinate Conversion Integration Tests

@Suite("Coordinate Conversion Integration Tests")
struct CoordinateConversionIntegrationTests {
    
    @Test("鼠标事件坐标应正确转换为屏幕坐标")
    func testMouseEventCoordinateConversion() {
        let screenWidth = 1920
        let screenHeight = 1080
        
        let event = SBRemoteMouseEvent(
            type: .click,
            x: 0.5,
            y: 0.5,
            button: .left,
            modifiers: .none
        )
        
        let (screenX, screenY) = CoordinateConverter.denormalize(
            x: event.x,
            y: event.y,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )
        
        #expect(abs(screenX - 960.0) < 0.001)
        #expect(abs(screenY - 540.0) < 0.001)
    }
    
    @Test("边界坐标应正确转换")
    func testBoundaryCoordinateConversion() {
        let screenWidth = 2560
        let screenHeight = 1440
        
 // 左上角
        let event1 = SBRemoteMouseEvent(type: .move, x: 0.0, y: 0.0)
        let (x1, y1) = CoordinateConverter.denormalize(x: event1.x, y: event1.y, screenWidth: screenWidth, screenHeight: screenHeight)
        #expect(x1 == 0.0)
        #expect(y1 == 0.0)
        
 // 右下角
        let event2 = SBRemoteMouseEvent(type: .move, x: 1.0, y: 1.0)
        let (x2, y2) = CoordinateConverter.denormalize(x: event2.x, y: event2.y, screenWidth: screenWidth, screenHeight: screenHeight)
        #expect(x2 == Double(screenWidth))
        #expect(y2 == Double(screenHeight))
    }
}

// MARK: - Permission Status Tests

@Suite("Permission Status Tests")
struct PermissionStatusTests {
    
    @Test("本地网络权限应始终返回已授权")
    @MainActor
    func testLocalNetworkPermissionAlwaysAuthorized() async {
        if #available(macOS 14.0, *) {
            let adapter = MacPlatformAdapter()
            let status = await adapter.checkPermission(.localNetwork)
            #expect(status == .authorized)
        }
    }
}
