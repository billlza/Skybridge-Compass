import Foundation

public protocol WeatherProviding {
    func fetchSnapshot(for location: WeatherLocation) async throws -> WeatherSnapshot
}

public struct WeatherLocation: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let query: String
    public let region: String

    public init(displayName: String, query: String, region: String) {
        self.displayName = displayName
        self.query = query
        self.region = region
        self.id = "\(query.lowercased())-\(region.lowercased())"
    }
}

public extension WeatherLocation {
    static let shanghai = WeatherLocation(displayName: "上海", query: "Shanghai", region: "中国 · CN")
    static let beijing = WeatherLocation(displayName: "北京", query: "Beijing", region: "中国 · CN")
    static let hangzhou = WeatherLocation(displayName: "杭州", query: "Hangzhou", region: "中国 · CN")
    static let tokyo = WeatherLocation(displayName: "东京", query: "Tokyo", region: "日本 · JP")
    static let sanFrancisco = WeatherLocation(displayName: "San Francisco", query: "San Francisco", region: "美国 · US")

    static let presets: [WeatherLocation] = [
        .shanghai,
        .beijing,
        .hangzhou,
        .tokyo,
        .sanFrancisco
    ]
}

public final class WeatherService: WeatherProviding {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let airQualityToken: String

    public init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        airQualityToken: String? = ProcessInfo.processInfo.environment["WAQI_TOKEN"]
    ) {
        self.session = session
        self.decoder = decoder
        self.airQualityToken = (airQualityToken?.isEmpty == false ? airQualityToken : nil) ?? "demo"
    }

    public func fetchSnapshot(for location: WeatherLocation) async throws -> WeatherSnapshot {
        async let weather = fetchWttr(for: location)
        async let airQuality = fetchAirQualityOptional(for: location)
        let condition = try await weather
        let aqi = await airQuality

        return WeatherSnapshot(
            city: condition.resolvedCity ?? location.displayName,
            condition: condition.description,
            temperature: "\(condition.temperatureRounded)°",
            humidity: "\(condition.humidity)%",
            visibility: "\(condition.visibility) km",
            wind: "\(condition.windDirection) \(condition.windSpeed) km/h",
            airQualityIndex: aqi ?? WeatherSnapshot.defaultAirQualityIndex
        )
    }

    private func fetchWttr(for location: WeatherLocation) async throws -> ParsedCondition {
        guard let encoded = location.query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw WeatherServiceError.invalidCity
        }
        guard var components = URLComponents(string: "https://wttr.in/\(encoded)") else {
            throw WeatherServiceError.invalidCity
        }
        components.queryItems = [URLQueryItem(name: "format", value: "j1")]
        guard let url = components.url else { throw WeatherServiceError.invalidCity }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WeatherServiceError.networkFailure
        }
        let payload = try decoder.decode(WttrResponse.self, from: data)
        guard let condition = payload.currentCondition.first else {
            throw WeatherServiceError.invalidResponse
        }
        let resolvedCity = payload.nearestArea?.first?.areaName?.first?.value
        let description = condition.weatherDesc?.first?.value ?? "晴"
        return ParsedCondition(
            temperatureRounded: Int(Double(condition.tempC) ?? Double(condition.feelsLikeC) ?? 0),
            humidity: Int(Double(condition.humidity) ?? 0),
            visibility: Int(Double(condition.visibility) ?? 0),
            windSpeed: Int(Double(condition.windspeedKmph) ?? 0),
            windDirection: condition.winddir16Point,
            description: description,
            resolvedCity: resolvedCity
        )
    }

    private func fetchAirQuality(for location: WeatherLocation) async throws -> Int? {
        guard let encoded = location.query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw WeatherServiceError.invalidCity
        }
        guard !airQualityToken.isEmpty else { return nil }
        guard let url = URL(string: "https://api.waqi.info/feed/\(encoded)/?token=\(airQualityToken)") else {
            throw WeatherServiceError.invalidCity
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WeatherServiceError.networkFailure
        }
        let payload = try decoder.decode(AqiResponse.self, from: data)
        guard payload.status == "ok" else { return nil }
        return payload.data.aqi
    }

    private func fetchAirQualityOptional(for location: WeatherLocation) async -> Int? {
        do {
            return try await fetchAirQuality(for: location)
        } catch {
            return nil
        }
    }
}

struct ParsedCondition: Sendable {
    let temperatureRounded: Int
    let humidity: Int
    let visibility: Int
    let windSpeed: Int
    let windDirection: String
    let description: String
    let resolvedCity: String?
}

private struct WttrResponse: Decodable {
    let currentCondition: [Condition]
    let nearestArea: [NearestArea]?

    enum CodingKeys: String, CodingKey {
        case currentCondition = "current_condition"
        case nearestArea = "nearest_area"
    }
}

private struct Condition: Decodable {
    let tempC: String
    let feelsLikeC: String
    let humidity: String
    let visibility: String
    let windspeedKmph: String
    let winddir16Point: String
    let weatherDesc: [WeatherValue]?

    enum CodingKeys: String, CodingKey {
        case tempC = "temp_C"
        case feelsLikeC = "FeelsLikeC"
        case humidity
        case visibility
        case windspeedKmph
        case winddir16Point
        case weatherDesc
    }
}

private struct WeatherValue: Decodable {
    let value: String
}

private struct NearestArea: Decodable {
    let areaName: [WeatherValue]?
}

private struct AqiResponse: Decodable {
    let status: String
    let data: AQIData
}

private struct AQIData: Decodable {
    let aqi: Int
}

public enum WeatherServiceError: Error {
    case invalidCity
    case networkFailure
    case invalidResponse
}

extension WeatherServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCity:
            return "无法识别的城市名称"
        case .networkFailure:
            return "天气服务连接失败"
        case .invalidResponse:
            return "天气数据暂不可用"
        }
    }
}
