import SwiftUI
import SkyBridgeCore

/// 天气测试视图 - 用于测试不同天气效果
struct WeatherTestView: View {
    @EnvironmentObject private var weatherService: WeatherDataService
    @EnvironmentObject private var wallpaperManager: DynamicWallpaperManager
    
    @State private var selectedWeatherType: WeatherDataService.WeatherType = .clear
    @State private var selectedIntensity: WeatherDataService.WeatherIntensity = .moderate
    @State private var visibility: Double = 10.0
    @State private var temperature: Double = 20.0
    @State private var humidity: Double = 60.0
    
    var body: some View {
        VStack(spacing: 20) {
            // 标题
            Text("天气效果测试")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.top)
            
            // 天气类型选择
            VStack(alignment: .leading, spacing: 10) {
                Text("天气类型")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Picker("天气类型", selection: $selectedWeatherType) {
                    ForEach(WeatherDataService.WeatherType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            .padding(.horizontal)
            
            // 强度选择
            VStack(alignment: .leading, spacing: 10) {
                Text("天气强度")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Picker("强度", selection: $selectedIntensity) {
                    ForEach(WeatherDataService.WeatherIntensity.allCases, id: \.self) { intensity in
                        Text(intensity.displayName).tag(intensity)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            .padding(.horizontal)
            
            // 参数调节
            VStack(spacing: 15) {
                // 能见度
                VStack(alignment: .leading) {
                    HStack {
                        Text("能见度")
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(visibility, specifier: "%.1f") km")
                            .foregroundColor(.gray)
                    }
                    Slider(value: $visibility, in: 0.5...20.0, step: 0.5)
                        .accentColor(.blue)
                }
                
                // 温度
                VStack(alignment: .leading) {
                    HStack {
                        Text("温度")
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(temperature, specifier: "%.0f")°C")
                            .foregroundColor(.gray)
                    }
                    Slider(value: $temperature, in: -20...50, step: 1)
                        .accentColor(.orange)
                }
                
                // 湿度
                VStack(alignment: .leading) {
                    HStack {
                        Text("湿度")
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(humidity, specifier: "%.0f")%")
                            .foregroundColor(.gray)
                    }
                    Slider(value: $humidity, in: 0...100, step: 5)
                        .accentColor(.cyan)
                }
            }
            .padding(.horizontal)
            
            // 应用按钮
            Button(action: applyWeatherSettings) {
                HStack {
                    Image(systemName: "cloud.fill")
                    Text("应用天气效果")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(0.8))
                )
            }
            .padding(.horizontal)
            
            // 雾霾测试快捷按钮
            Button(action: applyHazeWeather) {
                HStack {
                    Image(systemName: "cloud.fog.fill")
                    Text("测试雾霾效果")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.brown.opacity(0.8))
                )
            }
            .padding(.horizontal)
            
            // 重置按钮
            Button(action: resetToRealWeather) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("恢复真实天气")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.6))
                )
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .background(Color.black.opacity(0.3))
        .onAppear {
            // 设置默认为雾霾天气进行测试
            selectedWeatherType = .haze
            visibility = 2.0
            humidity = 80.0
            temperature = 25.0
        }
    }
    
    // MARK: - 私有方法
    
    /// 应用天气设置
    private func applyWeatherSettings() {
        weatherService.setSimulatedWeather(
            weatherType: selectedWeatherType,
            intensity: selectedIntensity,
            temperature: temperature,
            humidity: humidity,
            visibility: visibility
        )
        
        // 触发壁纸管理器更新
        Task {
            await wallpaperManager.refreshWeatherData()
        }
    }
    
    /// 应用雾霾天气效果
    private func applyHazeWeather() {
        selectedWeatherType = .haze
        selectedIntensity = .heavy
        visibility = 2.0
        humidity = 80.0
        temperature = 25.0
        
        applyWeatherSettings()
    }
    
    /// 重置到真实天气
    private func resetToRealWeather() {
        Task {
            await wallpaperManager.refreshWeatherData()
        }
    }
}

#Preview {
    do {
        return WeatherTestView()
            .environmentObject(WeatherDataService())
            .environmentObject(try DynamicWallpaperManager())
    } catch {
        return Text("预览初始化失败: \(error.localizedDescription)")
            .foregroundColor(.red)
    }
}