import Foundation

@available(macOS 14.0, iOS 17.0, *)
enum CrossNetworkTenantIdentifierPolicy {
    private static let explicitTenantEnvironmentKey = "SKYBRIDGE_TENANT_ID"

    static func derive(
        accessToken: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let explicit = environment[explicitTenantEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty {
            return explicit
        }
        guard let accessToken, !accessToken.isEmpty else {
            return ""
        }
        guard let payload = accessToken.split(separator: ".").dropFirst().first else {
            return ""
        }
        var base64 = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        let appMetadata = object["app_metadata"] as? [String: Any]
        let userMetadata = object["user_metadata"] as? [String: Any]
        let candidates: [Any?] = [
            appMetadata?["tenant_id"],
            appMetadata?["tenantId"],
            appMetadata?["org_id"],
            appMetadata?["workspace_id"],
            userMetadata?["tenant_id"],
            userMetadata?["tenantId"],
            userMetadata?["org_id"],
            userMetadata?["workspace_id"],
            object["tenant_id"],
            object["tenantId"],
            object["sub"]
        ]
        for candidate in candidates {
            let value = String(describing: candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != "nil" {
                return value
            }
        }
        return ""
    }
}
