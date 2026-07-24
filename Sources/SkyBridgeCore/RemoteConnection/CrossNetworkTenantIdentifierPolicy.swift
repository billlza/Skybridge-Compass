import Foundation

@available(macOS 14.0, iOS 17.0, *)
enum CrossNetworkTenantIdentifierPolicy {
    struct AuthenticatedIdentity: Sendable, Equatable {
        let tenantID: String
        let userID: String
    }
    enum ResolutionError: LocalizedError, Equatable, Sendable {
        case invalidLocalIdentity
        case invalidJWTClaims
        case missingTenantClaim
        case conflictingTenantClaims
        case tenantIdentityMismatch
        case userIdentityMismatch

        var errorDescription: String? {
            switch self {
            case .invalidLocalIdentity:
                return "The local authentication identity is malformed."
            case .invalidJWTClaims:
                return "The authentication token contains malformed identity claims."
            case .missingTenantClaim:
                return "The authentication token has no signed tenant claim for the declared tenant."
            case .conflictingTenantClaims:
                return "The authentication token contains conflicting signed tenant claims."
            case .tenantIdentityMismatch:
                return "The authentication token and local tenant identity do not match."
            case .userIdentityMismatch:
                return "The authentication token and local user identity do not match."
            }
        }
    }

    private struct JWTIdentity: Sendable {
        let tenantID: String?
        let subject: String
    }

    static func resolve(
        accessToken: String?,
        explicitTenantID: String?,
        sessionTenantID: String?,
        sessionUserIdentifier: String?
    ) throws -> String {
        let explicitTenant = try normalizedLocalIdentity(explicitTenantID)
        let sessionTenant = try normalizedLocalIdentity(sessionTenantID)
        let sessionUser = try normalizedLocalIdentity(sessionUserIdentifier)
        if let explicitTenant, let sessionTenant, explicitTenant != sessionTenant {
            throw ResolutionError.tenantIdentityMismatch
        }

        let declaredTenant = explicitTenant ?? sessionTenant
        guard let token = try normalizedAccessToken(accessToken) else {
            if declaredTenant != nil {
                throw ResolutionError.missingTenantClaim
            }
            return ""
        }
        guard let jwtIdentity = try validatedJWTIdentity(accessToken: token) else {
            if declaredTenant != nil {
                throw ResolutionError.missingTenantClaim
            }
            return sessionUser ?? ""
        }

        if let sessionUser, sessionUser != jwtIdentity.subject {
            throw ResolutionError.userIdentityMismatch
        }

        if let declaredTenant {
            guard let tokenTenant = jwtIdentity.tenantID else {
                throw ResolutionError.missingTenantClaim
            }
            guard tokenTenant == declaredTenant else {
                throw ResolutionError.tenantIdentityMismatch
            }
            return tokenTenant
        }

        return jwtIdentity.tenantID ?? jwtIdentity.subject
    }

    static func resolveAuthenticatedIdentity(
        accessToken: String?,
        explicitTenantID: String?,
        sessionTenantID: String?,
        sessionUserIdentifier: String?
    ) throws -> AuthenticatedIdentity {
        guard let token = try normalizedAccessToken(accessToken),
              let jwtIdentity = try validatedJWTIdentity(accessToken: token) else {
            throw ResolutionError.invalidJWTClaims
        }
        let tenantID = try resolve(
            accessToken: token,
            explicitTenantID: explicitTenantID,
            sessionTenantID: sessionTenantID,
            sessionUserIdentifier: sessionUserIdentifier
        )
        guard !tenantID.isEmpty else {
            throw ResolutionError.missingTenantClaim
        }
        return AuthenticatedIdentity(
            tenantID: tenantID,
            userID: jwtIdentity.subject
        )
    }

    private static func normalizedAccessToken(_ rawValue: String?) throws -> String? {
        guard let rawValue else { return nil }
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 1_048_576,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ResolutionError.invalidJWTClaims
        }
        return rawValue
    }

    private static func normalizedLocalIdentity(_ rawValue: String?) throws -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ResolutionError.invalidLocalIdentity
        }
        return value.isEmpty ? nil : value
    }

    private static func validatedClaim(_ rawValue: Any?) throws -> String? {
        guard let rawValue else { return nil }
        guard let value = rawValue as? String,
              !value.isEmpty,
              value.utf8.count <= 256,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ResolutionError.invalidJWTClaims
        }
        return value
    }

    /// Returns nil only for an opaque legacy token. Three-segment JWT-shaped values must decode
    /// into a coherent subject and server-controlled tenant claim set.
    private static func validatedJWTIdentity(accessToken: String) throws -> JWTIdentity? {
        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolutionError.invalidJWTClaims
        }
        if claims["app_metadata"] != nil, !(claims["app_metadata"] is [String: Any]) {
            throw ResolutionError.invalidJWTClaims
        }
        let appMetadata = claims["app_metadata"] as? [String: Any]
        let tenantCandidates: [Any?] = [
            appMetadata?["tenant_id"],
            appMetadata?["tenantId"],
            appMetadata?["org_id"],
            appMetadata?["workspace_id"],
            claims["tenant_id"],
            claims["tenantId"],
            claims["org_id"],
            claims["workspace_id"]
        ]
        let tenantValues = try Set(tenantCandidates.compactMap(validatedClaim))
        guard tenantValues.count <= 1 else {
            throw ResolutionError.conflictingTenantClaims
        }
        guard let subject = try validatedClaim(claims["sub"]) else {
            throw ResolutionError.invalidJWTClaims
        }
        return JWTIdentity(tenantID: tenantValues.first, subject: subject)
    }
}
