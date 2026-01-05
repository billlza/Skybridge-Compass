//
// WeatherDashboardCard.swift
// SkyBridgeCompassApp
//
// 天气信息卡片组件
// Created: 2025-10-19
//

import SwiftUI
import SkyBridgeCore

/// 天气仪表板卡片 - 液态玻璃样式（SwiftUI 2025特性）
@available(macOS 14.0, *)
@MainActor
public struct WeatherDashboardCard: View {
    @ObservedObject var weatherManager = WeatherIntegrationManager.shared
    
    @State private var refreshFlash: Bool = false
    @State private var isHovering: Bool = false
    
    public var body: some View {
        VStack(spacing: 0) {
 // 天气内容
            if let weather = weatherManager.currentWeather {
                weatherContent(weather: weather)
            } else if let error = weatherManager.error {
                errorView(message: error)
            } else {
                loadingView
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
 // 🔮 液态玻璃效果核心 - SwiftUI 2025
        .background(
            ZStack {
 // 基础磨砂玻璃层
                Color.white.opacity(0.04)
                
 // 渐变光泽层
                LinearGradient(
                    colors: [
                        Color.white.opacity(isHovering ? 0.08 : 0.03),
                        Color.white.opacity(0.01)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovering ? 0.15 : 0.08),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        )
 // 动态阴影效果
        .shadow(
            color: weatherColor.opacity(refreshFlash ? 0.3 : 0.1),
            radius: refreshFlash ? 20 : 8,
            x: 0,
            y: refreshFlash ? 8 : 4
        )
 // 悬停缩放效果
        .scaleEffect(isHovering ? 1.005 : 1.0)
 // 液态动画
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isHovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: refreshFlash)
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: weatherManager.currentWeather?.timestamp) { _, _ in
 // 天气数据时间戳变化时触发刷新闪光效果
            refreshFlash = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                refreshFlash = false
            }
        }
        .task {
            if !weatherManager.isInitialized {
                await weatherManager.start()
            }
        }
    }
    
 /// 根据天气状态返回主题颜色
    private var weatherColor: Color {
        guard let weather = weatherManager.currentWeather else { return .blue }
        return iconColor(for: weather.condition)
    }
    
    @ViewBuilder
    private func weatherContent(weather: WeatherInfo) -> some View {
        HStack(spacing: 20) {
 // 左侧：温度和天气图标
            VStack(spacing: 8) {
 // 大号天气图标（带光晕效果）
                ZStack {
 // 光晕
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    iconColor(for: weather.condition).opacity(0.3),
                                    iconColor(for: weather.condition).opacity(0)
                                ],
                                center: .center,
                                startRadius: 8,
                                endRadius: 40
                            )
                        )
                        .frame(width: 80, height: 80)
                    
 // 图标
                    Image(systemName: weather.condition.iconName)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    iconColor(for: weather.condition),
                                    iconColor(for: weather.condition).opacity(0.7)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                
 // 温度显示
                Text("\(Int(weather.temperature))°")
                    .font(.system(size: 40, weight: .thin, design: .rounded))
                    .foregroundColor(.white)
            }
            .frame(width: 110)
            
 // 右侧：详细信息
            VStack(alignment: .leading, spacing: 12) {
 // 位置信息（标题）
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.callout)
                        .foregroundColor(.cyan)
                    
                    Text(weather.location)
                        .font(.title3.bold())
                        .foregroundColor(.white)
                    
                    Spacer()
                    
 // 刷新按钮（增强版）
                    Button(action: {
                        Task {
                            await weatherManager.refresh()
                        }
                    }) {
                        ZStack {
 // 背景圆形
                            Circle()
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 32, height: 32)
                            
 // 刷新图标
                            Image(systemName: weatherManager.isLoading ? "arrow.clockwise" : "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(weatherManager.isLoading ? 0.5 : 0.9))
                                .rotationEffect(.degrees(weatherManager.isLoading ? 360 : 0))
                                .animation(
                                    weatherManager.isLoading ? 
                                    .linear(duration: 1.0).repeatForever(autoreverses: false) : 
                                    .default,
                                    value: weatherManager.isLoading
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .help("刷新天气数据")
                    .disabled(weatherManager.isLoading)
                }
                
 // 天气状态
                Text(weather.condition.rawValue)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.white.opacity(0.9))
                
                Divider()
                    .overlay(Color.white.opacity(0.1))
                
 // 详细参数网格
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 10) {
                    WeatherMetric(
                        icon: "humidity.fill",
                        label: LocalizationManager.shared.localizedString("weather.metric.humidity"),
                        value: "\(Int(weather.humidity))%",
                        color: .cyan
                    )
                    
                    WeatherMetric(
                        icon: "wind",
                        label: LocalizationManager.shared.localizedString("weather.metric.windSpeed"),
                        value: "\(Int(weather.windSpeed))km/h",
                        color: .mint
                    )
                    
                    if let visibility = weather.visibility {
                        WeatherMetric(
                            icon: "eye.fill",
                            label: LocalizationManager.shared.localizedString("weather.metric.visibility"),
                            value: "\(Int(visibility))km",
                            color: .blue
                        )
                    }
                    
                    if let aqi = weather.aqi {
                        WeatherMetric(
                            icon: "aqi.medium",
                            label: LocalizationManager.shared.localizedString("weather.metric.aqi"),
                            value: "\(aqi)",
                            color: aqiColor(aqi: aqi)
                        )
                    }
                }
                
 // 底部元数据
                HStack(spacing: 16) {
                    Label(weather.source, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                    
                    Spacer()
                    
                    Text(timeAgo(from: weather.timestamp))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
    }
    
 // MARK: - 天气指标组件
    
    struct WeatherMetric: View {
        let icon: String
        let label: String
        let value: String
        let color: Color
        
        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                    .frame(width: 16)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                    
                    Text(value)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                }
            }
        }
    }
    
    private var loadingView: some View {
        HStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizationManager.shared.localizedString("weather.status.loading"))
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(LocalizationManager.shared.localizedString("weather.status.loadingHint"))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            
            Spacer()
        }
        .frame(height: 120)
    }
    
    private func errorView(message: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizationManager.shared.localizedString("weather.status.error"))
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(message)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                
                Button {
                    Task {
                        await weatherManager.start()
                    }
                } label: {
                    Label(LocalizationManager.shared.localizedString("weather.action.retry"), systemImage: "arrow.clockwise")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            
            Spacer()
        }
        .frame(height: 120)
    }
    
 // MARK: - Helper Methods
    
    private func iconColor(for condition: WeatherCondition) -> Color {
        switch condition {
        case .clear: return .yellow
        case .cloudy: return .gray
        case .rainy: return .blue
        case .snowy: return .cyan
        case .foggy, .haze: return .gray.opacity(0.7)
        case .stormy: return .purple
        case .unknown: return .gray
        }
    }
    
    private func aqiColor(aqi: Int) -> Color {
        switch aqi {
        case 0..<50: return .green
        case 50..<100: return .yellow
        case 100..<150: return .orange
        case 150..<200: return .red
        case 200..<300: return .purple
        default: return .brown
        }
    }
    
    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        
        if interval < 60 {
            return LocalizationManager.shared.localizedString("weather.time.justNow")
        } else if interval < 3600 {
            return String(format: LocalizationManager.shared.localizedString("weather.time.minutesAgo"), Int(interval / 60))
        } else {
            return String(format: LocalizationManager.shared.localizedString("weather.time.hoursAgo"), Int(interval / 3600))
        }
    }
}

struct WeatherDashboardCard_Previews: PreviewProvider {
    static var previews: some View {
        if #available(macOS 14.0, *) {
            WeatherDashboardCard()
                .frame(width: 400, height: 250)
                .padding()
        }
    }
}
