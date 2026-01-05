//
// CoordinateConverter.swift
// SkyBridgeCore
//
// 坐标转换工具
// 实现屏幕坐标与归一化坐标之间的转换
//
// Requirements: 11.5, 11.6
//

import Foundation

// MARK: - Coordinate Converter

/// 坐标转换工具
public enum CoordinateConverter {
    
 /// 将屏幕坐标转换为归一化坐标
 /// - Parameters:
 /// - x: 屏幕 X 坐标
 /// - y: 屏幕 Y 坐标
 /// - screenWidth: 屏幕宽度
 /// - screenHeight: 屏幕高度
 /// - Returns: 归一化坐标 (x, y)，范围 [0.0, 1.0]
    public static func normalize(
        x: Double,
        y: Double,
        screenWidth: Int,
        screenHeight: Int
    ) -> (x: Double, y: Double) {
        guard screenWidth > 0, screenHeight > 0 else {
            return (0.0, 0.0)
        }
        
        let normalizedX = max(0.0, min(1.0, x / Double(screenWidth)))
        let normalizedY = max(0.0, min(1.0, y / Double(screenHeight)))
        
        return (normalizedX, normalizedY)
    }
    
 /// 将归一化坐标转换为屏幕坐标
 /// - Parameters:
 /// - x: 归一化 X 坐标 (0.0-1.0)
 /// - y: 归一化 Y 坐标 (0.0-1.0)
 /// - screenWidth: 屏幕宽度
 /// - screenHeight: 屏幕高度
 /// - Returns: 屏幕坐标 (x, y)
    public static func denormalize(
        x: Double,
        y: Double,
        screenWidth: Int,
        screenHeight: Int
    ) -> (x: Double, y: Double) {
        guard screenWidth > 0, screenHeight > 0 else {
            return (0.0, 0.0)
        }
        
 // 确保输入在有效范围内
        let clampedX = max(0.0, min(1.0, x))
        let clampedY = max(0.0, min(1.0, y))
        
        let screenX = clampedX * Double(screenWidth)
        let screenY = clampedY * Double(screenHeight)
        
        return (screenX, screenY)
    }
    
 /// 将 CGPoint 转换为归一化坐标
 /// - Parameters:
 /// - point: 屏幕坐标点
 /// - screenSize: 屏幕尺寸
 /// - Returns: 归一化坐标点
    public static func normalize(
        point: CGPoint,
        screenSize: CGSize
    ) -> CGPoint {
        let (x, y) = normalize(
            x: Double(point.x),
            y: Double(point.y),
            screenWidth: Int(screenSize.width),
            screenHeight: Int(screenSize.height)
        )
        return CGPoint(x: x, y: y)
    }
    
 /// 将归一化坐标转换为 CGPoint
 /// - Parameters:
 /// - normalizedPoint: 归一化坐标点
 /// - screenSize: 屏幕尺寸
 /// - Returns: 屏幕坐标点
    public static func denormalize(
        normalizedPoint: CGPoint,
        screenSize: CGSize
    ) -> CGPoint {
        let (x, y) = denormalize(
            x: Double(normalizedPoint.x),
            y: Double(normalizedPoint.y),
            screenWidth: Int(screenSize.width),
            screenHeight: Int(screenSize.height)
        )
        return CGPoint(x: x, y: y)
    }
    
 /// 验证归一化坐标是否在有效范围内
 /// - Parameters:
 /// - x: 归一化 X 坐标
 /// - y: 归一化 Y 坐标
 /// - Returns: 是否在有效范围 [0.0, 1.0] 内
    public static func isValidNormalizedCoordinate(x: Double, y: Double) -> Bool {
        x >= 0.0 && x <= 1.0 && y >= 0.0 && y <= 1.0
    }
}
