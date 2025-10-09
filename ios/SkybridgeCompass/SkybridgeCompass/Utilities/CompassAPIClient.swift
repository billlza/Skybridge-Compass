import Foundation

struct CompassAPIClient {
    struct APIError: LocalizedError {
        let statusCode: Int
        let message: String

        var errorDescription: String? {
            "服务异常 (\(statusCode)): \(message)"
        }
    }

    static let shared = CompassAPIClient()

    let baseURL: URL
    let session: URLSession
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    init(baseURL: URL = URL(string: "https://api.skybridge.example")!, session: URLSession = .shared) {
        var decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        self.baseURL = baseURL
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem]? = nil) async throws -> T {
        let request = makeRequest(path: path, method: "GET", query: query)
        return try await send(request: request)
    }

    func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, query: [URLQueryItem]? = nil) async throws -> T {
        var request = makeRequest(path: path, method: "POST", query: query)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await send(request: request)
    }

    func post<T: Decodable>(_ path: String, data: Data, contentType: String, query: [URLQueryItem]? = nil) async throws -> T {
        var request = makeRequest(path: path, method: "POST", query: query)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try await send(request: request)
    }

    func patch<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = makeRequest(path: path, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await send(request: request)
    }

    func delete(_ path: String) async throws {
        let request = makeRequest(path: path, method: "DELETE")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "请求失败")
        }
    }

    private func send<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(statusCode: -1, message: "无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message: String
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = json["message"] as? String ?? json["error"] as? String {
                message = detail
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                message = text
            } else {
                message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            }
            throw APIError(statusCode: http.statusCode, message: message)
        }
        if data.isEmpty, let empty = EmptyCodable() as? T {
            return empty
        }
        return try decoder.decode(T.self, from: data)
    }

    private func makeRequest(path: String, method: String, query: [URLQueryItem]? = nil, body: Data? = nil, headers: [String: String] = [:]) -> URLRequest {
        let url = resolvedURL(for: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func resolvedURL(for path: String, query: [URLQueryItem]? = nil) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let relativeURL = URL(string: trimmed, relativeTo: baseURL) ?? baseURL
        guard var components = URLComponents(url: relativeURL, resolvingAgainstBaseURL: true) else {
            return relativeURL
        }
        if let query, !query.isEmpty {
            components.queryItems = query
        }
        return components.url ?? relativeURL
    }
}

private struct EmptyCodable: Codable {}
