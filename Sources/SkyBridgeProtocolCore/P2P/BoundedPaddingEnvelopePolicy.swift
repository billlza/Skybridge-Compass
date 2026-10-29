import Foundation

/// Shared allocation policy for SBP1/SBP2 envelopes. The policy computes and
/// validates the complete output size before a caller reserves or appends any
/// bytes, so persisted padding settings cannot become an unbounded allocation
/// request.
@available(macOS 14.0, iOS 17.0, *)
public enum BoundedPaddingEnvelopePolicy {
    public enum Target: Sendable, Equatable {
        case fixed(Int)
        case bucketed([Int])
    }

    public struct Plan: Sendable, Equatable {
        public let shouldWrap: Bool
        public let totalByteCount: Int

        public init(shouldWrap: Bool, totalByteCount: Int) {
            self.shouldWrap = shouldWrap
            self.totalByteCount = totalByteCount
        }
    }

    public static func plan(
        payloadByteCount: Int,
        headerByteCount: Int,
        enabled: Bool,
        target: Target,
        maximumOutputByteCount: Int,
        maximumPaddingTargetByteCount: Int? = nil
    ) throws -> Plan {
        guard payloadByteCount >= 0 else {
            throw BoundedPaddingEnvelopePolicyError.invalidPayloadByteCount(payloadByteCount)
        }
        guard headerByteCount > 0 else {
            throw BoundedPaddingEnvelopePolicyError.invalidHeaderByteCount(headerByteCount)
        }
        guard maximumOutputByteCount > 0,
              maximumOutputByteCount <= Int(UInt32.max) else {
            throw BoundedPaddingEnvelopePolicyError.invalidMaximumOutputByteCount(
                maximumOutputByteCount
            )
        }

        let paddingTargetCeiling: Int
        if let maximumPaddingTargetByteCount {
            guard maximumPaddingTargetByteCount > 0,
                  maximumPaddingTargetByteCount <= maximumOutputByteCount else {
                throw BoundedPaddingEnvelopePolicyError.invalidMaximumPaddingTargetByteCount(
                    actual: maximumPaddingTargetByteCount,
                    maximum: maximumOutputByteCount
                )
            }
            paddingTargetCeiling = maximumPaddingTargetByteCount
        } else {
            paddingTargetCeiling = maximumOutputByteCount
        }

        guard payloadByteCount <= maximumOutputByteCount else {
            throw BoundedPaddingEnvelopePolicyError.payloadExceedsMaximum(
                actual: payloadByteCount,
                maximum: maximumOutputByteCount
            )
        }
        guard enabled else {
            return Plan(shouldWrap: false, totalByteCount: payloadByteCount)
        }
        guard payloadByteCount <= Int(UInt32.max) else {
            throw BoundedPaddingEnvelopePolicyError.payloadLengthNotRepresentable(
                payloadByteCount
            )
        }

        let minimumResult = payloadByteCount.addingReportingOverflow(headerByteCount)
        guard !minimumResult.overflow else {
            throw BoundedPaddingEnvelopePolicyError.byteCountOverflow
        }
        let minimumByteCount = minimumResult.partialValue
        guard minimumByteCount <= maximumOutputByteCount else {
            throw BoundedPaddingEnvelopePolicyError.minimumEnvelopeExceedsMaximum(
                required: minimumByteCount,
                maximum: maximumOutputByteCount
            )
        }

        let totalByteCount: Int
        switch target {
        case .fixed(let configuredByteCount):
            guard configuredByteCount >= 0 else {
                throw BoundedPaddingEnvelopePolicyError.invalidPaddingTarget(
                    actual: configuredByteCount,
                    maximum: paddingTargetCeiling
                )
            }
            if configuredByteCount == 0 {
                totalByteCount = minimumByteCount
            } else {
                guard configuredByteCount <= paddingTargetCeiling else {
                    throw BoundedPaddingEnvelopePolicyError.invalidPaddingTarget(
                        actual: configuredByteCount,
                        maximum: paddingTargetCeiling
                    )
                }
                guard minimumByteCount <= configuredByteCount else {
                    throw BoundedPaddingEnvelopePolicyError.payloadExceedsFixedPaddingTarget(
                        required: minimumByteCount,
                        configured: configuredByteCount
                    )
                }
                totalByteCount = configuredByteCount
            }

        case .bucketed(let configuredByteCounts):
            for configuredByteCount in configuredByteCounts {
                guard configuredByteCount > 0,
                      configuredByteCount <= maximumOutputByteCount else {
                    throw BoundedPaddingEnvelopePolicyError.invalidPaddingTarget(
                        actual: configuredByteCount,
                        maximum: maximumOutputByteCount
                    )
                }
            }
            totalByteCount = configuredByteCounts.first(where: {
                $0 >= minimumByteCount && $0 <= paddingTargetCeiling
            }) ?? minimumByteCount
        }

        guard totalByteCount <= maximumOutputByteCount else {
            throw BoundedPaddingEnvelopePolicyError.minimumEnvelopeExceedsMaximum(
                required: totalByteCount,
                maximum: maximumOutputByteCount
            )
        }
        return Plan(shouldWrap: true, totalByteCount: totalByteCount)
    }
}

@available(macOS 14.0, iOS 17.0, *)
public enum BoundedPaddingEnvelopePolicyError: Error, Sendable, Equatable, LocalizedError {
    case invalidPayloadByteCount(Int)
    case invalidHeaderByteCount(Int)
    case invalidMaximumOutputByteCount(Int)
    case invalidMaximumPaddingTargetByteCount(actual: Int, maximum: Int)
    case payloadLengthNotRepresentable(Int)
    case payloadExceedsMaximum(actual: Int, maximum: Int)
    case minimumEnvelopeExceedsMaximum(required: Int, maximum: Int)
    case invalidPaddingTarget(actual: Int, maximum: Int)
    case payloadExceedsFixedPaddingTarget(required: Int, configured: Int)
    case byteCountOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidPayloadByteCount(let actual):
            return "Padding payload byte count must be non-negative (actual: \(actual))"
        case .invalidHeaderByteCount(let actual):
            return "Padding header byte count must be positive (actual: \(actual))"
        case .invalidMaximumOutputByteCount(let actual):
            return "Padding output limit must be within 1...UInt32.max (actual: \(actual))"
        case .invalidMaximumPaddingTargetByteCount(let actual, let maximum):
            return "Padding target ceiling \(actual) is outside 1...\(maximum) bytes"
        case .payloadLengthNotRepresentable(let actual):
            return "Padding payload length \(actual) is not representable on the wire"
        case .payloadExceedsMaximum(let actual, let maximum):
            return "Padding payload is \(actual) bytes, exceeding the \(maximum)-byte output limit"
        case .minimumEnvelopeExceedsMaximum(let required, let maximum):
            return "Padding envelope requires \(required) bytes, exceeding the \(maximum)-byte output limit"
        case .invalidPaddingTarget(let actual, let maximum):
            return "Padding target \(actual) is outside the permitted 1...\(maximum)-byte range"
        case .payloadExceedsFixedPaddingTarget(let required, let configured):
            return "Padding envelope requires \(required) bytes, exceeding fixed target \(configured)"
        case .byteCountOverflow:
            return "Padding byte-count arithmetic overflowed"
        }
    }
}
