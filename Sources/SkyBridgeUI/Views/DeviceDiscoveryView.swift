import SwiftUI
import Foundation
import OSLog
import SkyBridgeCore

public struct DeviceDiscoveryView: View {
    @ObservedObject private var service = DeviceDiscoveryService.shared
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
 // 扫描控制区域
            scanControlSection
            
 // 设备列表区域
            deviceListSection
            
            Spacer()
        }
        .padding()
        .navigationTitle("设备发现")
    }
    
 // MARK: - 视图组件
    
    private var scanControlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设备扫描")
                .font(.headline)
            
            HStack {
                Button(service.isScanning ? "停止扫描" : "开始扫描") {
                    toggleScanning()
                }
                .buttonStyle(.borderedProminent)
                
                if service.isScanning {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.leading, 10)
                }
                
                Spacer()
            }
            
            Text("已发现 \(service.discoveredDevices.count) 台设备")
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var deviceListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发现的设备")
                .font(.headline)
            
            if service.discoveredDevices.isEmpty {
                Text("暂无发现的设备")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ForEach(service.discoveredDevices) { device in
                    deviceRow(device)
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)
                
                if let ipv4 = device.ipv4 {
                    Text("IPv4: \(ipv4)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !device.services.isEmpty {
                    Text("服务: \(device.services.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button("连接") {
                connectToDevice(device)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
    
 // MARK: - 操作方法
    
    private func toggleScanning() {
        if service.isScanning {
            service.stop()
        } else {
 // 手动触发扫描，强制绕过冷却
            Task {
                await service.start(force: true)
            }
        }
    }
    
    private func connectToDevice(_ device: DiscoveredDevice) {
 // 连接设备逻辑
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "SkyBridgeCompassApp", category: "ui").debug("尝试连接到设备: \(device.name)")
    }
}
