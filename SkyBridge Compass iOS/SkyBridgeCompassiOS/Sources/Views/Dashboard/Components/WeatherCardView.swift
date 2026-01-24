//
// WeatherCardView.swift
// SkyBridgeCompassiOS
//
// iOS 天气卡片组件 - 轻量级设计
// 控制动画和渲染开销，适合移动设备
//

import SwiftUI

/// iOS 天气卡片
@available(iOS 17.0, *)
public struct WeatherCardView: View {
    
    @StateObject private var weatherManager = WeatherManager.shared
    @StateObject private var settingsManager = SettingsManager.instance
    @State private var isRefreshing = false
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            if !settingsManager.enableRealTimeWeather {
                disabledView
            } else if let weather = weatherManager.currentWeather {
                weatherContent(weather: weather)
            } else if let error = weatherManager.error {
                errorView(message: error)
            } else {
                loadingView
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(weatherBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 4)
        .task {
            if settingsManager.enableRealTimeWeather, !weatherManager.isInitialized {
                await weatherManager.start()
            } else if !settingsManager.enableRealTimeWeather {
                await weatherManager.setEnabled(false)
            }
        }
        .onChange(of: settingsManager.enableRealTimeWeather) { _, enabled in
            Task { @MainActor in
                await weatherManager.setEnabled(enabled)
            }
        }
    }
    
    // MARK: - Background
    
    private var weatherBackground: some View {
        ZStack {
            // 自适应“玻璃底色”（在浅色背景下不会导致文字隐身）
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)

            if let weather = weatherManager.currentWeather {
                LinearGradient(
                    colors: gradientColors(for: weather.condition),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(0.22)
            }
        }
    }
    
    private func gradientColors(for condition: WeatherCondition) -> [Color] {
        switch condition {
        case .clear:
            return [Color.orange.opacity(0.6), Color.yellow.opacity(0.4)]
        case .cloudy:
            return [Color.gray.opacity(0.5), Color.gray.opacity(0.3)]
        case .rainy:
            return [Color.blue.opacity(0.5), Color.cyan.opacity(0.3)]
        case .snowy:
            return [Color.cyan.opacity(0.4), Color.white.opacity(0.3)]
        case .foggy, .haze:
            return [Color.gray.opacity(0.4), Color.gray.opacity(0.2)]
        case .stormy:
            return [Color.purple.opacity(0.5), Color.blue.opacity(0.4)]
        case .unknown:
            return [Color.gray.opacity(0.3), Color.gray.opacity(0.2)]
        }
    }
    
    // MARK: - Weather Content
    
    @ViewBuilder
    private func weatherContent(weather: WeatherInfo) -> some View {
        HStack(spacing: 16) {
            // 左侧：温度和图标
            VStack(spacing: 6) {
                // 天气图标
                ZStack {
                    Circle()
                        .fill(iconBackgroundColor(for: weather.condition).opacity(0.2))
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: weather.condition.iconName)
                        .font(.system(size: 28))
                        .foregroundStyle(iconColor(for: weather.condition))
                }
                
                // 温度
                Text("\(Int(weather.temperature))°")
                    .font(.system(size: 32, weight: .thin, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .frame(width: 80)
            
            // 右侧：详细信息
            VStack(alignment: .leading, spacing: 8) {
                // 位置和刷新按钮
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text(weather.location)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    // 刷新按钮
                    Button {
                        refreshWeather()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 28, height: 28)
                            
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary.opacity(isRefreshing ? 0.5 : 0.9))
                                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                                .animation(
                                    isRefreshing ?
                                        .linear(duration: 1.0).repeatForever(autoreverses: false) :
                                        .default,
                                    value: isRefreshing
                                )
                        }
                    }
                    .disabled(isRefreshing)
                }
                
                // 天气描述
                Text(weather.condition.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                // 详细指标
                HStack(spacing: 12) {
                    WeatherMetricBadge(icon: "humidity.fill", value: "\(Int(weather.humidity))%", color: .cyan)
                    WeatherMetricBadge(icon: "wind", value: "\(Int(weather.windSpeed))km/h", color: .mint)
                    
                    if let aqi = weather.aqi {
                        WeatherMetricBadge(icon: "aqi.medium", value: "\(aqi)", color: aqiColor(aqi: aqi))
                    }
                }
                
                // 更新时间
                HStack {
                    Text(weather.source)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.8))
                    
                    Spacer()
                    
                    Text(timeAgo(from: weather.timestamp))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            }
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("正在获取天气...")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                
                Text("请确保已授权位置权限")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .frame(height: 80)
    }

    private var disabledView: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud.slash")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("实时天气已关闭")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text("可在 设置 → 高级 打开实时天气（API）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(height: 80)
    }
    
    // MARK: - Error View
    
    private func errorView(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("天气获取失败")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Button {
                Task {
                    await weatherManager.start()
                }
            } label: {
                Text("重试")
                    .font(.caption.bold())
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .frame(height: 80)
    }
    
    // MARK: - Helper Methods
    
    private func refreshWeather() {
        isRefreshing = true
        Task {
            await weatherManager.refresh()
            isRefreshing = false
        }
    }
    
    private func iconColor(for condition: WeatherCondition) -> Color {
        switch condition {
        case .clear: return .yellow
        case .cloudy: return .gray
        case .rainy: return .blue
        case .snowy: return .cyan
        case .foggy, .haze: return .gray
        case .stormy: return .purple
        case .unknown: return .gray
        }
    }
    
    private func iconBackgroundColor(for condition: WeatherCondition) -> Color {
        iconColor(for: condition)
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
            return "刚刚更新"
        } else if interval < 3600 {
            return "\(Int(interval / 60))分钟前"
        } else {
            return "\(Int(interval / 3600))小时前"
        }
    }
}

// MARK: - Weather Metric Badge

/// 天气指标徽章
@available(iOS 17.0, *)
struct WeatherMetricBadge: View {
    let icon: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - Preview
#if DEBUG
@available(iOS 17.0, *)
struct WeatherCardView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            WeatherCardView()
        }
        .padding()
        .background(Color.black)
    }
}
#endif
