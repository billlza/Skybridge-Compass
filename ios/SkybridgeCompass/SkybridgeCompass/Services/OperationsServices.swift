import Foundation

actor RemoteDesktopService {
    static let shared = RemoteDesktopService()

    private let api: CompassAPIClient

    init(api: CompassAPIClient = .shared) {
        self.api = api
    }

    func fetchEndpoints() async throws -> [RemoteDesktopEndpoint] {
        struct Response: Decodable { let endpoints: [RemoteDesktopEndpoint] }
        let response: Response = try await api.get("/api/v1/desktops")
        return response.endpoints
    }

    func startSession(endpointID: UUID, quality: RemoteDesktopSession.StreamQuality) async throws -> RemoteDesktopSession {
        struct Payload: Encodable {
            let quality: RemoteDesktopSession.StreamQuality
        }
        struct Response: Decodable { let session: RemoteDesktopSession }
        let path = "/api/v1/desktops/\(endpointID.uuidString)/session"
        let response: Response = try await api.post(path, body: Payload(quality: quality))
        return response.session
    }

    func fetchSession(sessionID: UUID) async throws -> RemoteDesktopSession {
        struct Response: Decodable { let session: RemoteDesktopSession }
        let path = "/api/v1/desktops/sessions/\(sessionID.uuidString)"
        let response: Response = try await api.get(path)
        return response.session
    }

    func stopSession(sessionID: UUID) async throws {
        let path = "/api/v1/desktops/sessions/\(sessionID.uuidString)"
        try await api.delete(path)
    }

    func fetchPreview(sessionID: UUID) async throws -> RemoteDesktopFrame {
        struct Response: Decodable { let frame: RemoteDesktopFrame }
        let path = "/api/v1/desktops/sessions/\(sessionID.uuidString)/preview"
        let response: Response = try await api.get(path)
        return response.frame
    }
}

actor FileTransferService {
    static let shared = FileTransferService()

    private let api: CompassAPIClient

    init(api: CompassAPIClient = .shared) {
        self.api = api
    }

    func listDirectory(at path: String) async throws -> [FileTransferItem] {
        struct Response: Decodable { let items: [FileTransferItem] }
        let response: Response = try await api.get("/api/v1/storage", query: [URLQueryItem(name: "path", value: path)])
        return response.items
    }

    func upload(data: Data, fileName: String, destinationPath: String) async throws -> FileTransferJob {
        struct Payload: Encodable {
            let fileName: String
            let destinationPath: String
            let contentBase64: String
        }
        struct Response: Decodable { let job: FileTransferJob }
        let payload = Payload(
            fileName: fileName,
            destinationPath: destinationPath,
            contentBase64: data.base64EncodedString()
        )
        let response: Response = try await api.post("/api/v1/storage/upload", body: payload)
        return response.job
    }

    func download(itemID: UUID, destinationPath: String) async throws -> FileTransferJob {
        struct Payload: Encodable {
            let itemID: UUID
            let destinationPath: String
        }
        struct Response: Decodable { let job: FileTransferJob }
        let response: Response = try await api.post("/api/v1/storage/download", body: Payload(itemID: itemID, destinationPath: destinationPath))
        return response.job
    }

    func fetchJobs() async throws -> [FileTransferJob] {
        struct Response: Decodable { let jobs: [FileTransferJob] }
        let response: Response = try await api.get("/api/v1/storage/jobs")
        return response.jobs
    }
}

actor SystemSettingsService {
    static let shared = SystemSettingsService()

    private let api: CompassAPIClient

    init(api: CompassAPIClient = .shared) {
        self.api = api
    }

    func fetchSettings() async throws -> [SystemSetting] {
        struct Response: Decodable { let settings: [SystemSetting] }
        let response: Response = try await api.get("/api/v1/system/settings")
        return response.settings
    }

    func update(setting: SystemSetting) async throws -> SystemSetting {
        struct Payload: Encodable {
            let boolValue: Bool?
            let selectedOption: String?
            let doubleValue: Double?
        }
        struct Response: Decodable { let setting: SystemSetting }
        let payload = Payload(boolValue: setting.boolValue, selectedOption: setting.selectedOption, doubleValue: setting.doubleValue)
        let path = "/api/v1/system/settings/\(setting.id.uuidString)"
        let response: Response = try await api.patch(path, body: payload)
        return response.setting
    }

    func fetchProfile() async throws -> SystemSettingsProfile? {
        struct Response: Decodable { let profile: SystemSettingsProfile? }
        let response: Response = try await api.get("/api/v1/system/profile")
        return response.profile
    }
}
