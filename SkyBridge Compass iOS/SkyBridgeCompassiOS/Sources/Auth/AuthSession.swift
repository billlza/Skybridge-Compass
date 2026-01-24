import Foundation

/// 与 macOS 端一致的认证会话模型（用于 Supabase / Nebula / Apple 登录）
public struct AuthSession: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let userIdentifier: String
    public let displayName: String
    public let email: String?
    public let avatarURL: String?
    public let nebulaId: String?
    public let issuedAt: Date

    public init(
        accessToken: String,
        refreshToken: String?,
        userIdentifier: String,
        displayName: String,
        email: String? = nil,
        avatarURL: String? = nil,
        nebulaId: String? = nil,
        issuedAt: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userIdentifier = userIdentifier
        self.displayName = displayName
        self.email = email
        self.avatarURL = avatarURL
        self.nebulaId = nebulaId
        self.issuedAt = issuedAt
    }
}

