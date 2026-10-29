import Foundation

public struct AIAdvisoryFactDTO: Codable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum AIAdvisoryInputValidationError: Error, Equatable, Sendable {
    case emptyFacts
    case duplicateFactName
    case unsupportedFactName
    case unsafeFactValue
}

public struct AIAdvisoryInputDTO: Codable, Equatable, Sendable {
    public enum Subject: String, Codable, Equatable, Sendable {
        case anomalyExplanation = "anomaly_explanation"
        case policyDecisionExplanation = "policy_decision_explanation"
    }

    public let subject: Subject
    public let facts: [AIAdvisoryFactDTO]
    public let sensitiveInputsRedacted: Bool
    public let rawLogsIncluded: Bool
    public let advisoryOnly: Bool

    public init(
        subject: Subject,
        facts: [AIAdvisoryFactDTO]
    ) throws {
        try AIAdvisoryFactValidation.validate(subject: subject, facts: facts)
        self.subject = subject
        self.facts = facts
        self.sensitiveInputsRedacted = true
        self.rawLogsIncluded = false
        self.advisoryOnly = true
    }

    private enum CodingKeys: String, CodingKey {
        case subject
        case facts
        case sensitiveInputsRedacted
        case rawLogsIncluded
        case advisoryOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let subject = try container.decode(Subject.self, forKey: .subject)
        let facts = try container.decode([AIAdvisoryFactDTO].self, forKey: .facts)
        let sensitiveInputsRedacted = try container.decode(Bool.self, forKey: .sensitiveInputsRedacted)
        let rawLogsIncluded = try container.decode(Bool.self, forKey: .rawLogsIncluded)
        let advisoryOnly = try container.decode(Bool.self, forKey: .advisoryOnly)

        guard sensitiveInputsRedacted, !rawLogsIncluded, advisoryOnly else {
            throw DecodingError.dataCorruptedError(
                forKey: .advisoryOnly,
                in: container,
                debugDescription: "AI advisory input must be redacted, raw-log-free, and advisory-only."
            )
        }

        try self.init(subject: subject, facts: facts)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subject, forKey: .subject)
        try container.encode(facts, forKey: .facts)
        try container.encode(true, forKey: .sensitiveInputsRedacted)
        try container.encode(false, forKey: .rawLogsIncluded)
        try container.encode(true, forKey: .advisoryOnly)
    }
}

public struct AIAdvisoryOutputDTO: Codable, Equatable, Sendable {
    public enum Authority: String, Codable, Equatable, Sendable {
        case advisoryOnly = "advisory_only"
    }

    public enum ConfidenceBand: String, Codable, Equatable, Sendable, CaseIterable {
        case low
        case medium
        case high
        case unknown
    }

    public let authority: Authority
    public let summary: String
    public let confidenceBand: ConfidenceBand
    public let evidenceLabels: [String]

    public init(
        summary: String,
        confidenceBand: ConfidenceBand,
        evidenceLabels: [String] = []
    ) {
        self.authority = .advisoryOnly
        self.summary = summary
        self.confidenceBand = confidenceBand
        self.evidenceLabels = evidenceLabels.sorted()
    }
}

public protocol AIAdvisoryEngine: Sendable {
    func advisory(for input: AIAdvisoryInputDTO) async throws -> AIAdvisoryOutputDTO
}

public enum AIAdvisoryRedactor {
    public static func input(from anomaly: DetectedAnomaly) throws -> AIAdvisoryInputDTO {
        let contextCategories = Set(anomaly.context.keys.map(contextCategory(for:))).sorted()
        let sourcePresence = anomaly.sourceDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        return try AIAdvisoryInputDTO(
            subject: .anomalyExplanation,
            facts: [
                AIAdvisoryFactDTO(name: "anomaly_type", value: anomaly.type.rawValue),
                AIAdvisoryFactDTO(name: "severity", value: anomaly.severity.displayName),
                AIAdvisoryFactDTO(name: "confidence_band", value: confidenceBand(for: anomaly.confidence).rawValue),
                AIAdvisoryFactDTO(name: "source_identifier", value: sourcePresence ? "present_redacted" : "absent"),
                AIAdvisoryFactDTO(name: "context_categories", value: contextCategories.joined(separator: ","))
            ]
        )
    }

    public static func input(from snapshot: PolicyDecisionSnapshot) throws -> AIAdvisoryInputDTO {
        try AIAdvisoryInputDTO(
            subject: .policyDecisionExplanation,
            facts: [
                AIAdvisoryFactDTO(
                    name: "policy",
                    value: allowedValue(snapshot.policy, allowed: ["classic", "prefer", "strict"])
                ),
                AIAdvisoryFactDTO(
                    name: "selected_tier",
                    value: allowedValue(snapshot.selected_tier, allowed: ["classic", "nativePQC", "liboqsPQC", "qperiaptPQC"])
                ),
                AIAdvisoryFactDTO(name: "selected_suite_wire_id", value: String(snapshot.selected_suite_wire_id)),
                AIAdvisoryFactDTO(name: "fallback_allowed", value: snapshot.fallback_allowed ? "true" : "false"),
                AIAdvisoryFactDTO(
                    name: "event_code",
                    value: allowedValue(snapshot.event_code, allowed: Set(PolicyDecisionEventCode.allCases.map(\.rawValue)))
                ),
                AIAdvisoryFactDTO(
                    name: "ui_error_category",
                    value: allowedValue(snapshot.ui_error_category, allowed: Set(PolicyDecisionUIErrorCategory.allCases.map(\.rawValue)))
                )
            ]
        )
    }

    private static func confidenceBand(for confidence: Double) -> AIAdvisoryOutputDTO.ConfidenceBand {
        switch confidence {
        case ..<0.34:
            return .low
        case ..<0.67:
            return .medium
        case ...1.0:
            return .high
        default:
            return .unknown
        }
    }

    private static func contextCategory(for key: String) -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("device") {
            return "device_metadata"
        }
        if normalized.contains("file") || normalized.contains("path") || normalized.contains("name") {
            return "file_metadata"
        }
        if normalized.contains("session") || normalized.contains("token") || normalized.contains("challenge") {
            return "session_metadata"
        }
        if normalized.contains("fingerprint") || normalized.contains("key") || normalized.contains("transcript") {
            return "crypto_metadata"
        }
        if normalized.contains("host") || normalized.contains("ip") || normalized.contains("port") || normalized.contains("endpoint") {
            return "network_metadata"
        }
        if normalized.contains("hour") || normalized.contains("time") {
            return "time_metadata"
        }
        if normalized.contains("ratio") || normalized.contains("count") || normalized.contains("volume") {
            return "aggregate_metric"
        }
        return "other_metadata"
    }

    private static func allowedValue(_ value: String, allowed: Set<String>) -> String {
        allowed.contains(value) ? value : "unknown"
    }
}

private enum AIAdvisoryFactValidation {
    private static let allowedContextCategories: Set<String> = [
        "aggregate_metric",
        "crypto_metadata",
        "device_metadata",
        "file_metadata",
        "network_metadata",
        "other_metadata",
        "session_metadata",
        "time_metadata"
    ]

    static func validate(
        subject: AIAdvisoryInputDTO.Subject,
        facts: [AIAdvisoryFactDTO]
    ) throws {
        guard !facts.isEmpty else {
            throw AIAdvisoryInputValidationError.emptyFacts
        }

        var seenNames = Set<String>()
        for fact in facts {
            guard isSafeFactName(fact.name) else {
                throw AIAdvisoryInputValidationError.unsupportedFactName
            }
            guard seenNames.insert(fact.name).inserted else {
                throw AIAdvisoryInputValidationError.duplicateFactName
            }

            guard validate(fact: fact, subject: subject) else {
                throw AIAdvisoryInputValidationError.unsafeFactValue
            }
        }
    }

    private static func validate(
        fact: AIAdvisoryFactDTO,
        subject: AIAdvisoryInputDTO.Subject
    ) -> Bool {
        switch subject {
        case .anomalyExplanation:
            return validateAnomalyFact(fact)
        case .policyDecisionExplanation:
            return validatePolicyDecisionFact(fact)
        }
    }

    private static func validateAnomalyFact(_ fact: AIAdvisoryFactDTO) -> Bool {
        switch fact.name {
        case "anomaly_type":
            return Set(AnomalyType.allCases.map(\.rawValue)).contains(fact.value)
        case "severity":
            return ["低", "中", "高", "严重"].contains(fact.value)
        case "confidence_band":
            return Set(AIAdvisoryOutputDTO.ConfidenceBand.allCases.map(\.rawValue)).contains(fact.value)
        case "source_identifier":
            return ["present_redacted", "absent"].contains(fact.value)
        case "context_categories":
            return fact.value
                .split(separator: ",", omittingEmptySubsequences: false)
                .allSatisfy { allowedContextCategories.contains(String($0)) || $0.isEmpty }
        default:
            return false
        }
    }

    private static func validatePolicyDecisionFact(_ fact: AIAdvisoryFactDTO) -> Bool {
        switch fact.name {
        case "policy":
            return ["classic", "prefer", "strict", "unknown"].contains(fact.value)
        case "selected_tier":
            return ["classic", "nativePQC", "liboqsPQC", "qperiaptPQC", "unknown"].contains(fact.value)
        case "selected_suite_wire_id":
            return UInt32(fact.value) != nil
        case "fallback_allowed":
            return ["true", "false"].contains(fact.value)
        case "event_code":
            return Set(PolicyDecisionEventCode.allCases.map(\.rawValue)).union(["unknown"]).contains(fact.value)
        case "ui_error_category":
            return Set(PolicyDecisionUIErrorCategory.allCases.map(\.rawValue)).union(["unknown"]).contains(fact.value)
        default:
            return false
        }
    }

    private static func isSafeFactName(_ name: String) -> Bool {
        guard !name.isEmpty else {
            return false
        }
        let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        return name.unicodeScalars.allSatisfy { allowedScalars.contains($0) }
    }
}
