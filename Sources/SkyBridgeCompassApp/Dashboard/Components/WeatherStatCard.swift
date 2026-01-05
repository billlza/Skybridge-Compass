import SwiftUI
import SkyBridgeCore

/// 天气统计卡片视图，用于显示当前天气信息
/// 集成WeatherDataService和WeatherLocationService，实时显示天气状况
@available(macOS 14.0, *)
public struct WeatherStatCard: View {
    @ObservedObject var weatherService: WeatherDataService
    @ObservedObject var locationService: WeatherLocationService
 // 接入实时天气服务状态
    @StateObject private var realTimeWeatherService = RealTimeWeatherService.shared

 // 细粒度动画状态
    @State private var isFetchingAnimated: Bool = false
    @State private var statusShake: Bool = false
 // 数据刷新轻微反馈
    @State private var refreshFlash: Bool = false
    
    public init(weatherService: WeatherDataService, locationService: WeatherLocationService) {
        self._weatherService = ObservedObject(wrappedValue: weatherService)
        self._locationService = ObservedObject(wrappedValue: locationService)
    }
    
    public var body: some View {
        VStack(spacing: 12) {
            headerRow
            infoSection
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .scaleEffect(refreshFlash ? 1.02 : 1.0)
        .shadow(color: weatherColor.opacity(refreshFlash ? 0.20 : 0.0), radius: refreshFlash ? 8 : 0, x: 0, y: refreshFlash ? 2 : 0)
        .animation(.snappy(duration: 0.35, extraBounce: 0.08), value: realTimeWeatherService.serviceStatus)
        .animation(.snappy(duration: 0.35, extraBounce: 0.08), value: weatherService.currentWeather?.currentWeather.temperature.value)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: refreshFlash)
 // 🔧 优化：添加节流，减少频繁的天气更新导致的UI刷新
        .onReceive(weatherService.$currentWeather
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)  // 500ms节流
        ) { _ in
 // 将状态修改延迟到下一次主线程事件循环，避免与视图更新周期冲突。
            Task { @MainActor in
                refreshFlash = true
 // 使用异步任务在短暂延迟后复位动画标志，确保线程安全与主线程执行。
                try? await Task.sleep(nanoseconds: 300_000_000)
                refreshFlash = false
            }
        }
 // 🔧 优化：只在状态真正改变时更新，减少不必要的UI刷新
        .onChange(of: realTimeWeatherService.serviceStatus) { oldStatus, newStatus in
 // 只在状态真正改变时更新，避免重复更新
            guard oldStatus != newStatus else { return }
 // 将所有状态更新调度到主线程的下一次事件循环，避免在视图渲染期间修改状态。
            Task { @MainActor in
                switch newStatus {
                case .requestingLocation, .fetchingWeather:
                    isFetchingAnimated = true
                case .completed:
                    isFetchingAnimated = false
                    if let loc = locationService.currentLocation ?? realTimeWeatherService.currentLocation {
                        Task { @MainActor in
                            await weatherService.fetchWeather(for: loc)
                        }
                    }
                case .error:
                    isFetchingAnimated = false
                    statusShake.toggle()
                case .idle:
                    isFetchingAnimated = false
                }
            }
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack {
            Image(systemName: weatherIcon)
                .font(.title2)
                .foregroundColor(weatherColor)
                .symbolEffect(.pulse, value: isInProgress || refreshFlash)
                .symbolEffect(.bounce, value: realTimeWeatherService.serviceStatus == .completed)
            
            if isInProgress {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(weatherColor)
                    .transition(.opacity)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizationManager.shared.localizedString("weather.status.title"))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 4) {
                Text(weatherDescription)
                    .font(.title3.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                
                if let currentWeather = weatherService.currentWeather {
                    Text("\(Int(currentWeather.currentWeather.temperature.value))°")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                }
            }
            HStack {
                Text(LocalizationManager.shared.localizedString("weather.service.status"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(realTimeWeatherService.serviceStatus.displayName)
                    .font(.caption)
                    .foregroundColor(serviceStatusColor)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let error = realTimeWeatherService.lastError {
                Text(error.localizedDescription)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: statusShake ? 4 : 0)
                    .animation(.spring(response: 0.4, dampingFraction: 0.5), value: statusShake)
            }
        }
    }
    
 /// 是否处于进行中状态（用于驱动动画）
    private var isInProgress: Bool {
        switch realTimeWeatherService.serviceStatus {
        case .requestingLocation, .fetchingWeather:
            return true
        default:
            return false
        }
    }
    
    private var serviceStatusColor: Color {
        switch realTimeWeatherService.serviceStatus {
        case .completed:
            return .green
        case .requestingLocation, .fetchingWeather:
            return .orange
        case .error:
            return .red
        case .idle:
            return .secondary
        }
    }
    
 /// 获取天气描述文本
    private var weatherDescription: String {
        guard weatherService.currentWeather != nil else {
            return locationService.isLocationAuthorized ? 
                LocalizationManager.shared.localizedString("weather.status.fetching") : 
                LocalizationManager.shared.localizedString("weather.status.unauthorized")
        }
        
 // 根据天气条件返回中文描述
        let weatherType = weatherService.getCurrentWeatherType()
        switch weatherType {
        case .clear:
            return LocalizationManager.shared.localizedString("weather.condition.clear")
        case .partlyCloudy:
            return LocalizationManager.shared.localizedString("weather.condition.partlyCloudy")
        case .cloudy:
            return LocalizationManager.shared.localizedString("weather.condition.cloudy")
        case .fog:
            return LocalizationManager.shared.localizedString("weather.condition.fog")
        case .rain:
            return LocalizationManager.shared.localizedString("weather.condition.rain")
        case .heavyRain:
            return LocalizationManager.shared.localizedString("weather.condition.heavyRain")
        case .snow:
            return LocalizationManager.shared.localizedString("weather.condition.snow")
        case .heavySnow:
            return LocalizationManager.shared.localizedString("weather.condition.heavySnow")
        case .hail:
            return LocalizationManager.shared.localizedString("weather.condition.hail")
        case .thunderstorm:
            return LocalizationManager.shared.localizedString("weather.condition.thunderstorm")
        case .haze:
            return LocalizationManager.shared.localizedString("weather.condition.haze")
        case .wind:
            return LocalizationManager.shared.localizedString("weather.condition.wind")
        case .unknown:
            return LocalizationManager.shared.localizedString("weather.condition.unknown")
        }
    }
    
 /// 获取天气图标
    private var weatherIcon: String {
        guard weatherService.currentWeather != nil else {
            return locationService.isLocationAuthorized ? "cloud.fill" : "location.slash"
        }
        
 // 使用WeatherDataService的方法获取天气类型
        let weatherType = weatherService.getCurrentWeatherType()
        
 // 根据天气类型返回对应的SF Symbol图标
        switch weatherType {
        case .clear:
            return "sun.max.fill"
        case .partlyCloudy:
            return "cloud.sun.fill"
        case .cloudy:
            return "cloud.fill"
        case .fog:
            return "cloud.fog.fill"
        case .rain:
            return "cloud.rain.fill"
        case .heavyRain:
            return "cloud.heavyrain.fill"
        case .snow:
            return "cloud.snow.fill"
        case .heavySnow:
            return "cloud.snow.fill"
        case .hail:
            return "cloud.hail.fill"
        case .thunderstorm:
            return "cloud.bolt.fill"
        case .haze:
            return "cloud.fog.fill"
        case .wind:
            return "wind"
        case .unknown:
            return "cloud.fill"
        }
    }
    
 /// 获取天气颜色
    private var weatherColor: Color {
        guard weatherService.currentWeather != nil else {
            return locationService.isLocationAuthorized ? .gray : .red
        }
        
 // 使用WeatherDataService的方法获取天气类型
        let weatherType = weatherService.getCurrentWeatherType()
        
 // 根据天气类型返回对应的颜色
        switch weatherType {
        case .clear:
            return .yellow
        case .partlyCloudy:
            return .orange
        case .cloudy:
            return .gray
        case .fog:
            return .brown
        case .rain:
            return .blue
        case .heavyRain:
            return .indigo
        case .snow, .heavySnow, .hail:
            return .cyan
        case .thunderstorm:
            return .purple
        case .haze:
            return .brown
        case .wind:
            return .mint
        case .unknown:
            return .secondary
        }
    }
}

