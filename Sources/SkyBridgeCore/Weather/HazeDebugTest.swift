import Foundation
import SwiftUI
import MetalKit

/// 简化的雾霾测试视图，用于诊断问题
@MainActor
public struct HazeDebugTestView: View {
    @State private var testMessage = "Haze Debug Test - Initializing..."
    @State private var mousePosition = CGPoint.zero
    @State private var clickCount = 0
    
    public init() {}
    
    public var body: some View {
        ZStack {
 // 背景色
            Color.blue.opacity(0.3)
            
            VStack(spacing: 20) {
                Text(testMessage)
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                
                Text("Mouse: (\(Int(mousePosition.x)), \(Int(mousePosition.y)))")
                    .font(.body)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                
                Text("Clicks: \(clickCount)")
                    .font(.body)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                
                Button("Test Metal") {
                    testMetal()
                }
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
        }
        .onAppear {
            testMessage = "✅ Haze Debug Test - View Loaded"
            SkyBridgeLogger.ui.debugOnly("🧪 HazeDebugTestView appeared")
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    mousePosition = value.location
                    SkyBridgeLogger.ui.debugOnly("🖱️ Mouse drag at: \(String(describing: value.location))")
                }
        )
        .onTapGesture {
            clickCount += 1
            SkyBridgeLogger.ui.debugOnly("👆 Tap gesture detected, count: \(clickCount)")
        }
    }
    
    private func testMetal() {
        SkyBridgeLogger.metal.debugOnly("🔧 Testing Metal availability...")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            testMessage = "❌ Metal device not available"
            SkyBridgeLogger.metal.error("❌ Metal device not available")
            return
        }
        
        SkyBridgeLogger.metal.debugOnly("✅ Metal device available: \(device.name)")
        
        guard let library = device.makeDefaultLibrary() else {
            testMessage = "❌ Metal library not available"
            SkyBridgeLogger.metal.error("❌ Metal library not available")
            return
        }
        
        SkyBridgeLogger.metal.debugOnly("✅ Metal library loaded")
        
        let hazeVertexFunction = library.makeFunction(name: "hazeVertex")
        let hazeFragmentFunction = library.makeFunction(name: "hazeFragment")
        
        if hazeVertexFunction != nil && hazeFragmentFunction != nil {
            testMessage = "✅ Metal + Haze Shaders OK"
            SkyBridgeLogger.metal.debugOnly("✅ Haze shader functions loaded successfully")
        } else {
            testMessage = "❌ Haze shader functions missing"
            SkyBridgeLogger.metal.error("❌ Haze shader functions not found - vertex: \(hazeVertexFunction != nil) fragment: \(hazeFragmentFunction != nil)")
        }
    }
}

struct HazeDebugTestView_Previews: PreviewProvider {
    static var previews: some View {
        HazeDebugTestView()
    }
}
