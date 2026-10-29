import Foundation

/// One ordered terminal output batch. Batches are deliberately small so observers never need to
/// receive or copy the complete retained transcript on the hot path.
public struct SSHTerminalOutputBatch: Equatable, Sendable {
    public let generation: UInt64
    public let sequence: UInt64
    public let text: String

    public init(generation: UInt64, sequence: UInt64, text: String) {
        self.generation = generation
        self.sequence = sequence
        self.text = text
    }
}

/// A bounded, chunked replay for a newly attached terminal surface.
public struct SSHTerminalOutputReplay: Equatable, Sendable {
    public let batches: [SSHTerminalOutputBatch]
    public let didTruncateEarlierOutput: Bool

    public init(
        batches: [SSHTerminalOutputBatch],
        didTruncateEarlierOutput: Bool
    ) {
        self.batches = batches
        self.didTruncateEarlierOutput = didTruncateEarlierOutput
    }
}

/// Chunked transcript retention used for late observers and explicit snapshots.
///
/// Adjacent small batches are coalesced only up to `coalescedChunkByteLimit`. This keeps the
/// number of chunks bounded without reintroducing an O(total transcript) concatenation per batch.
struct SSHTerminalOutputHistory: Sendable {
    private let maximumBytes: Int
    private let retainedBytesAfterTrim: Int
    private let coalescedChunkByteLimit: Int
    private let maximumChunkCount: Int
    private(set) var batches: [SSHTerminalOutputBatch] = []
    private(set) var byteCount = 0
    private(set) var didTruncateEarlierOutput = false

    init(
        maximumBytes: Int = SSHOutputRetentionPolicy.maximumBytes,
        retainedBytesAfterTrim: Int = SSHOutputRetentionPolicy.retainedBytesAfterTrim,
        coalescedChunkByteLimit: Int = 16_384,
        maximumChunkCount: Int = 256
    ) {
        precondition(maximumBytes > 0)
        precondition(retainedBytesAfterTrim > 0)
        precondition(retainedBytesAfterTrim <= maximumBytes)
        precondition(coalescedChunkByteLimit > 0)
        precondition(maximumChunkCount > 0)
        self.maximumBytes = maximumBytes
        self.retainedBytesAfterTrim = retainedBytesAfterTrim
        self.coalescedChunkByteLimit = coalescedChunkByteLimit
        self.maximumChunkCount = maximumChunkCount
    }

    mutating func append(_ batch: SSHTerminalOutputBatch) {
        guard !batch.text.isEmpty else { return }

        let normalizedBatch: SSHTerminalOutputBatch
        let incomingByteCount = batch.text.utf8.count
        if incomingByteCount > maximumBytes {
            normalizedBatch = SSHTerminalOutputBatch(
                generation: batch.generation,
                sequence: batch.sequence,
                text: Self.utf8SafeSuffix(batch.text, maximumBytes: retainedBytesAfterTrim)
            )
            batches.removeAll(keepingCapacity: true)
            byteCount = 0
            didTruncateEarlierOutput = true
        } else {
            normalizedBatch = batch
        }

        let normalizedByteCount = normalizedBatch.text.utf8.count
        if let last = batches.last,
           last.generation == normalizedBatch.generation,
           last.text.utf8.count + normalizedByteCount <= coalescedChunkByteLimit {
            batches[batches.count - 1] = SSHTerminalOutputBatch(
                generation: normalizedBatch.generation,
                sequence: normalizedBatch.sequence,
                text: last.text + normalizedBatch.text
            )
        } else {
            batches.append(normalizedBatch)
        }
        byteCount += normalizedByteCount

        while batches.count > maximumChunkCount {
            byteCount -= batches.removeFirst().text.utf8.count
            didTruncateEarlierOutput = true
        }

        guard byteCount > maximumBytes else { return }
        didTruncateEarlierOutput = true
        while batches.count > 1, byteCount > retainedBytesAfterTrim {
            byteCount -= batches.removeFirst().text.utf8.count
        }
    }

    mutating func reset() {
        batches.removeAll(keepingCapacity: true)
        byteCount = 0
        didTruncateEarlierOutput = false
    }

    var replay: SSHTerminalOutputReplay {
        SSHTerminalOutputReplay(
            batches: batches,
            didTruncateEarlierOutput: didTruncateEarlierOutput
        )
    }

    func snapshot() -> String {
        var result = ""
        result.reserveCapacity(byteCount)
        for batch in batches {
            result.append(batch.text)
        }
        return result
    }

    private static func utf8SafeSuffix(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var utf8Start = text.utf8.index(text.utf8.endIndex, offsetBy: -maximumBytes)
        while utf8Start < text.utf8.endIndex {
            if let stringStart = String.Index(utf8Start, within: text) {
                return String(text[stringStart...])
            }
            text.utf8.formIndex(after: &utf8Start)
        }
        return ""
    }
}

public enum SSHTerminalANSIColor: Int, Equatable, Sendable {
    case black
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white
    case brightBlack
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightMagenta
    case brightCyan
    case brightWhite
}

public struct SSHTerminalTextStyle: Equatable, Sendable {
    public var foregroundColor: SSHTerminalANSIColor?
    public var isBold: Bool
    public var isUnderlined: Bool

    public init(
        foregroundColor: SSHTerminalANSIColor? = nil,
        isBold: Bool = false,
        isUnderlined: Bool = false
    ) {
        self.foregroundColor = foregroundColor
        self.isBold = isBold
        self.isUnderlined = isUnderlined
    }
}

public struct SSHTerminalStyledRun: Equatable, Sendable {
    public let text: String
    public let style: SSHTerminalTextStyle

    public init(text: String, style: SSHTerminalTextStyle) {
        self.text = text
        self.style = style
    }
}

public enum SSHTerminalRenderOperation: Equatable, Sendable {
    case append(SSHTerminalStyledRun)
    case erasePreviousCharacter
}

/// One canonical, already-parsed terminal presentation batch.
///
/// Raw SSH bytes remain available through `SSHTerminalOutputBatch` for source compatibility, but
/// terminal surfaces consume this type. Keeping ANSI parsing in Core means a late observer never
/// has to restart a parser in the middle of a retained OSC/CSI payload.
public struct SSHTerminalPresentationBatch: Equatable, Sendable {
    public let generation: UInt64
    public let sequence: UInt64
    public let operations: [SSHTerminalRenderOperation]

    public init(
        generation: UInt64,
        sequence: UInt64,
        operations: [SSHTerminalRenderOperation]
    ) {
        self.generation = generation
        self.sequence = sequence
        self.operations = operations
    }
}

/// Bounded replay of canonical presentation operations for a newly attached terminal surface.
public struct SSHTerminalPresentationReplay: Equatable, Sendable {
    public let batches: [SSHTerminalPresentationBatch]
    public let didTruncateEarlierOutput: Bool

    public init(
        batches: [SSHTerminalPresentationBatch],
        didTruncateEarlierOutput: Bool
    ) {
        self.batches = batches
        self.didTruncateEarlierOutput = didTruncateEarlierOutput
    }
}

/// Incremental ANSI parser for the append-only terminal transcript.
///
/// Supported controls are deliberately explicit: common SGR foreground colors, bold and
/// underline. CR/CRLF are normalized to one transcript newline, while backspace emits an explicit
/// suffix-erasure operation. Other CSI/OSC controls are consumed as terminal controls instead of
/// being rendered as spoofable text. Parser state is retained across network batches and every
/// control buffer is strictly bounded.
public struct SSHTerminalANSIStreamParser: Sendable {
    public static let maximumRenderOperationsPerBatch = 512
    public static let renderOperationTruncationMarker =
        "\n[terminal render operations truncated]\n"
    private static let maximumCSIBytes = 64
    private static let maximumOSCScalars = 4_096

    private enum ParseState: Sendable {
        case text
        case escape
        case csi([UInt8])
        case discardingCSI
        case operatingSystemCommand(previousWasEscape: Bool, scalarCount: Int)
        case discardingOperatingSystemCommand(previousWasEscape: Bool)
    }

    private var parseState: ParseState = .text
    private var style = SSHTerminalTextStyle()
    private var previousVisibleControlWasCarriageReturn = false

    public init() {}

    public mutating func reset() {
        parseState = .text
        style = SSHTerminalTextStyle()
        previousVisibleControlWasCarriageReturn = false
    }

    public mutating func consume(_ text: String) -> [SSHTerminalRenderOperation] {
        var operations: [SSHTerminalRenderOperation] = []
        var pendingText = ""
        var didTruncateRenderOperations = false
        pendingText.reserveCapacity(text.utf8.count)

        func flushPendingText() {
            guard !pendingText.isEmpty else { return }
            if !didTruncateRenderOperations,
               operations.count < Self.maximumRenderOperationsPerBatch - 1 {
                operations.append(
                    .append(SSHTerminalStyledRun(text: pendingText, style: style))
                )
            } else {
                didTruncateRenderOperations = true
            }
            pendingText.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch parseState {
            case .text:
                if value == 0x1B {
                    flushPendingText()
                    parseState = .escape
                } else if value == 0x0D {
                    // This view is an append-only transcript, not a VT cursor grid. Normalize a
                    // carriage return to one line boundary; a following LF is suppressed even if
                    // the CR/LF pair is split across network batches.
                    pendingText.append("\n")
                    previousVisibleControlWasCarriageReturn = true
                } else if value == 0x0A, previousVisibleControlWasCarriageReturn {
                    previousVisibleControlWasCarriageReturn = false
                } else if value == 0x08 {
                    flushPendingText()
                    if !didTruncateRenderOperations,
                       operations.count < Self.maximumRenderOperationsPerBatch - 1 {
                        operations.append(.erasePreviousCharacter)
                    } else {
                        didTruncateRenderOperations = true
                    }
                    previousVisibleControlWasCarriageReturn = false
                } else if Self.isUnsupportedVisibleControl(value)
                    || Self.isBidirectionalFormattingControl(value) {
                    // Terminal output is untrusted display input. Unsupported control bytes and
                    // bidi overrides/isolation markers are not transcript content and could make
                    // copied commands visually disagree with their logical order.
                    continue
                } else {
                    pendingText.unicodeScalars.append(scalar)
                    previousVisibleControlWasCarriageReturn = false
                }

            case .escape:
                switch value {
                case 0x1B:
                    parseState = .escape
                case 0x5B:
                    parseState = .csi([])
                case 0x5D:
                    parseState = .operatingSystemCommand(
                        previousWasEscape: false,
                        scalarCount: 0
                    )
                default:
                    // A non-CSI two-byte escape is a terminal control, not visible transcript.
                    parseState = .text
                }

            case .csi(var bytes):
                if value == 0x1B {
                    parseState = .escape
                } else if (0x40...0x7E).contains(value) {
                    if value == 0x6D {
                        applySGR(bytes)
                    }
                    parseState = .text
                } else if (0x20...0x3F).contains(value), bytes.count < Self.maximumCSIBytes {
                    bytes.append(UInt8(value))
                    parseState = .csi(bytes)
                } else {
                    parseState = .discardingCSI
                }

            case .discardingCSI:
                if value == 0x1B {
                    parseState = .escape
                } else if (0x40...0x7E).contains(value) {
                    parseState = .text
                }

            case .operatingSystemCommand(let previousWasEscape, let scalarCount):
                if value == 0x07 || (previousWasEscape && value == 0x5C) {
                    parseState = .text
                } else if scalarCount >= Self.maximumOSCScalars {
                    parseState = .discardingOperatingSystemCommand(
                        previousWasEscape: value == 0x1B
                    )
                } else {
                    parseState = .operatingSystemCommand(
                        previousWasEscape: value == 0x1B,
                        scalarCount: scalarCount + 1
                    )
                }

            case .discardingOperatingSystemCommand(let previousWasEscape):
                if value == 0x07 || (previousWasEscape && value == 0x5C) {
                    parseState = .text
                } else {
                    parseState = .discardingOperatingSystemCommand(
                        previousWasEscape: value == 0x1B
                    )
                }
            }
        }
        flushPendingText()
        if didTruncateRenderOperations {
            operations.append(
                .append(
                    SSHTerminalStyledRun(
                        text: Self.renderOperationTruncationMarker,
                        style: SSHTerminalTextStyle(
                            foregroundColor: .brightYellow,
                            isBold: false,
                            isUnderlined: false
                        )
                    )
                )
            )
        }
        return operations
    }

    private mutating func applySGR(_ bytes: [UInt8]) {
        guard bytes.allSatisfy({ $0 == 0x3B || (0x30...0x39).contains($0) }) else {
            return
        }

        let parameterText = String(decoding: bytes, as: UTF8.self)
        let parameters = parameterText.isEmpty
            ? [0]
            : parameterText.split(separator: ";", omittingEmptySubsequences: false).compactMap {
                $0.isEmpty ? 0 : Int($0)
            }

        for parameter in parameters {
            switch parameter {
            case 0:
                style = SSHTerminalTextStyle()
            case 1:
                style.isBold = true
            case 4:
                style.isUnderlined = true
            case 22:
                style.isBold = false
            case 24:
                style.isUnderlined = false
            case 30...37:
                style.foregroundColor = SSHTerminalANSIColor(rawValue: parameter - 30)
            case 39:
                style.foregroundColor = nil
            case 90...97:
                style.foregroundColor = SSHTerminalANSIColor(rawValue: parameter - 82)
            default:
                break
            }
        }
    }

    private static func isUnsupportedVisibleControl(_ value: UInt32) -> Bool {
        (value <= 0x1F && value != 0x09 && value != 0x0A && value != 0x0D)
            || value == 0x7F
            || (0x80...0x9F).contains(value)
    }

    private static func isBidirectionalFormattingControl(_ value: UInt32) -> Bool {
        value == 0x061C
            || value == 0x200E
            || value == 0x200F
            || (0x202A...0x202E).contains(value)
            || (0x2066...0x206F).contains(value)
    }
}

/// Serializes the single authoritative ANSI parser away from the MainActor.
///
/// The output delivery path admits only one batch at a time, while the lock also makes generation
/// resets deterministic when a disconnect races an in-flight parse. A stale generation is rejected
/// rather than contaminating the parser state of a newer transport.
final class SSHTerminalPresentationPipeline: @unchecked Sendable {
    static let desynchronizationMarker =
        "\n[terminal presentation desynchronized; reconnect required]\n"

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var parser = SSHTerminalANSIStreamParser()
    private var isInputSynchronized = true

    func reset(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.generation = generation
        parser.reset()
        isInputSynchronized = true
    }

    func consume(
        _ text: String,
        generation: UInt64,
        inputPrefixWasDropped: Bool = false
    ) -> [SSHTerminalRenderOperation]? {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return nil }
        guard isInputSynchronized else { return [] }
        if inputPrefixWasDropped {
            // Once raw bytes have been dropped there is no standards-compliant heuristic for
            // deciding whether the retained suffix is OSC/CSI payload. Fail closed for this
            // transport generation instead of rendering attacker-controlled control payload.
            parser.reset()
            isInputSynchronized = false
            return Self.desynchronizationOperations
        }
        return parser.consume(text)
    }

    /// Returns the status that must survive a user-visible history clear. A synchronized parser
    /// has no persistent status. A desynchronized parser keeps exposing exactly the reconnect
    /// requirement while continuing to reject every subsequent payload until `reset` installs a
    /// new transport generation.
    func persistentStatusOperations() -> [SSHTerminalRenderOperation] {
        lock.lock()
        defer { lock.unlock() }
        return isInputSynchronized ? [] : Self.desynchronizationOperations
    }

    private static var desynchronizationOperations: [SSHTerminalRenderOperation] {
        [
            .append(
                SSHTerminalStyledRun(
                    text: desynchronizationMarker,
                    style: SSHTerminalTextStyle(foregroundColor: .brightYellow)
                )
            )
        ]
    }
}

/// Whole-batch retention for canonical presentation operations.
///
/// Every append run carries its complete style, so removing an earlier batch cannot expose an ANSI
/// payload or require parser reconstruction. Erase operations at the new beginning are safe no-ops.
struct SSHTerminalPresentationHistory: Sendable {
    private static let estimatedOperationOverheadBytes = 64

    private let maximumEstimatedBytes: Int
    private let retainedEstimatedBytesAfterTrim: Int
    private let maximumBatchCount: Int
    private(set) var batches: [SSHTerminalPresentationBatch] = []
    private(set) var estimatedByteCount = 0
    private(set) var didTruncateEarlierOutput = false

    init(
        maximumEstimatedBytes: Int = SSHOutputRetentionPolicy.maximumBytes,
        retainedEstimatedBytesAfterTrim: Int = SSHOutputRetentionPolicy.retainedBytesAfterTrim,
        maximumBatchCount: Int = 256
    ) {
        precondition(maximumEstimatedBytes > 0)
        precondition(retainedEstimatedBytesAfterTrim > 0)
        precondition(retainedEstimatedBytesAfterTrim <= maximumEstimatedBytes)
        precondition(maximumBatchCount > 0)
        self.maximumEstimatedBytes = maximumEstimatedBytes
        self.retainedEstimatedBytesAfterTrim = retainedEstimatedBytesAfterTrim
        self.maximumBatchCount = maximumBatchCount
    }

    mutating func append(_ batch: SSHTerminalPresentationBatch) {
        guard !batch.operations.isEmpty else { return }
        let batchCost = Self.estimatedByteCost(of: batch)

        // The parser caps operations and the NIO buffer caps source bytes, so production batches
        // are far below this limit. Still fail closed for an independently constructed oversized
        // batch instead of letting one public value defeat the history bound.
        if batchCost > maximumEstimatedBytes {
            batches = [Self.oversizedBatchMarker(replacing: batch)]
            estimatedByteCount = Self.estimatedByteCost(of: batches[0])
            didTruncateEarlierOutput = true
            return
        }

        batches.append(batch)
        estimatedByteCount += batchCost

        while batches.count > maximumBatchCount {
            estimatedByteCount -= Self.estimatedByteCost(of: batches.removeFirst())
            didTruncateEarlierOutput = true
        }

        guard estimatedByteCount > maximumEstimatedBytes else { return }
        didTruncateEarlierOutput = true
        while batches.count > 1,
              estimatedByteCount > retainedEstimatedBytesAfterTrim {
            estimatedByteCount -= Self.estimatedByteCost(of: batches.removeFirst())
        }
    }

    mutating func reset() {
        batches.removeAll(keepingCapacity: true)
        estimatedByteCount = 0
        didTruncateEarlierOutput = false
    }

    var replay: SSHTerminalPresentationReplay {
        SSHTerminalPresentationReplay(
            batches: batches,
            didTruncateEarlierOutput: didTruncateEarlierOutput
        )
    }

    private static func estimatedByteCost(of batch: SSHTerminalPresentationBatch) -> Int {
        batch.operations.reduce(into: batch.operations.count * estimatedOperationOverheadBytes) {
            partialResult, operation in
            guard case .append(let run) = operation else { return }
            partialResult += run.text.utf8.count
        }
    }

    private static func oversizedBatchMarker(
        replacing batch: SSHTerminalPresentationBatch
    ) -> SSHTerminalPresentationBatch {
        SSHTerminalPresentationBatch(
            generation: batch.generation,
            sequence: batch.sequence,
            operations: [
                .append(
                    SSHTerminalStyledRun(
                        text: "\n[oversized terminal presentation batch discarded]\n",
                        style: SSHTerminalTextStyle(foregroundColor: .brightYellow)
                    )
                )
            ]
        )
    }
}

public struct SSHTerminalHistoryRetentionPolicy: Equatable, Sendable {
    public static let standard = SSHTerminalHistoryRetentionPolicy(
        maximumUTF8Bytes: SSHOutputRetentionPolicy.maximumBytes,
        retainedUTF8BytesAfterTrim: SSHOutputRetentionPolicy.retainedBytesAfterTrim,
        maximumLineCount: 2_000,
        retainedLineCountAfterTrim: 1_500,
        byteBoundaryGranularity: 4_096
    )

    public let maximumUTF8Bytes: Int
    public let retainedUTF8BytesAfterTrim: Int
    public let maximumLineCount: Int
    public let retainedLineCountAfterTrim: Int
    public let byteBoundaryGranularity: Int

    public init(
        maximumUTF8Bytes: Int,
        retainedUTF8BytesAfterTrim: Int,
        maximumLineCount: Int,
        retainedLineCountAfterTrim: Int,
        byteBoundaryGranularity: Int
    ) {
        precondition(maximumUTF8Bytes > 0)
        precondition(retainedUTF8BytesAfterTrim > 0)
        precondition(retainedUTF8BytesAfterTrim <= maximumUTF8Bytes)
        precondition(maximumLineCount > 0)
        precondition(retainedLineCountAfterTrim > 0)
        precondition(retainedLineCountAfterTrim <= maximumLineCount)
        precondition(byteBoundaryGranularity > 0)
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.retainedUTF8BytesAfterTrim = retainedUTF8BytesAfterTrim
        self.maximumLineCount = maximumLineCount
        self.retainedLineCountAfterTrim = retainedLineCountAfterTrim
        self.byteBoundaryGranularity = byteBoundaryGranularity
    }
}

public struct SSHTerminalHistoryMutation: Equatable, Sendable {
    public let prefixUTF16UnitsToRemove: Int
    public let didTruncate: Bool

    public init(prefixUTF16UnitsToRemove: Int, didTruncate: Bool) {
        self.prefixUTF16UnitsToRemove = prefixUTF16UnitsToRemove
        self.didTruncate = didTruncate
    }
}

/// Incremental index for bounding an attributed terminal transcript without rescanning it.
public struct SSHTerminalHistoryIndex: Sendable {
    private struct Position: Equatable, Sendable {
        var utf8: Int
        var utf16: Int
    }

    private let policy: SSHTerminalHistoryRetentionPolicy
    private var utf8Count = 0
    private var utf16Count = 0
    private var lineBreakEnds: [Position] = []
    private var byteTrimBoundaries: [Position] = []

    var retainedUTF8ByteCount: Int { utf8Count }
    var retainedUTF16UnitCount: Int { utf16Count }
    var retainedLineCount: Int { lineBreakEnds.count + 1 }

    public init(policy: SSHTerminalHistoryRetentionPolicy = .standard) {
        self.policy = policy
    }

    public mutating func reset() {
        utf8Count = 0
        utf16Count = 0
        lineBreakEnds.removeAll(keepingCapacity: true)
        byteTrimBoundaries.removeAll(keepingCapacity: true)
    }

    public mutating func append(_ text: String) -> SSHTerminalHistoryMutation {
        guard !text.isEmpty else {
            return SSHTerminalHistoryMutation(
                prefixUTF16UnitsToRemove: 0,
                didTruncate: false
            )
        }

        var lastByteBoundary = byteTrimBoundaries.last?.utf8 ?? 0
        for scalar in text.unicodeScalars {
            utf8Count += Self.utf8Length(of: scalar)
            utf16Count += scalar.value > 0xFFFF ? 2 : 1
            let position = Position(utf8: utf8Count, utf16: utf16Count)
            if scalar.value == 0x0A {
                lineBreakEnds.append(position)
            }
            if utf8Count - lastByteBoundary >= policy.byteBoundaryGranularity {
                byteTrimBoundaries.append(position)
                lastByteBoundary = utf8Count
            }
        }

        var removalPosition: Position?
        if utf8Count > policy.maximumUTF8Bytes {
            let requiredBytes = utf8Count - policy.retainedUTF8BytesAfterTrim
            removalPosition = byteTrimBoundaries.first(where: { $0.utf8 >= requiredBytes })
                ?? Position(utf8: utf8Count, utf16: utf16Count)
        }

        let currentLineCount = lineBreakEnds.count + 1
        if currentLineCount > policy.maximumLineCount {
            let linesToDrop = currentLineCount - policy.retainedLineCountAfterTrim
            let lineRemoval = lineBreakEnds[linesToDrop - 1]
            if removalPosition == nil || lineRemoval.utf16 > removalPosition!.utf16 {
                removalPosition = lineRemoval
            }
        }

        guard let removalPosition else {
            return SSHTerminalHistoryMutation(
                prefixUTF16UnitsToRemove: 0,
                didTruncate: false
            )
        }

        utf8Count -= removalPosition.utf8
        utf16Count -= removalPosition.utf16
        lineBreakEnds = Self.rebased(lineBreakEnds, afterRemoving: removalPosition)
        byteTrimBoundaries = Self.rebased(byteTrimBoundaries, afterRemoving: removalPosition)
        return SSHTerminalHistoryMutation(
            prefixUTF16UnitsToRemove: removalPosition.utf16,
            didTruncate: true
        )
    }

    /// Mirrors an incremental suffix deletion performed by the terminal surface for backspace.
    public mutating func removeSuffix(_ text: String) {
        guard !text.isEmpty else { return }
        let removedUTF8Count = text.utf8.count
        let removedUTF16Count = text.utf16.count
        precondition(removedUTF8Count <= utf8Count)
        precondition(removedUTF16Count <= utf16Count)
        utf8Count -= removedUTF8Count
        utf16Count -= removedUTF16Count
        while let last = lineBreakEnds.last, last.utf16 > utf16Count {
            lineBreakEnds.removeLast()
        }
        while let last = byteTrimBoundaries.last, last.utf16 > utf16Count {
            byteTrimBoundaries.removeLast()
        }
    }

    private static func rebased(
        _ positions: [Position],
        afterRemoving removal: Position
    ) -> [Position] {
        positions.compactMap { position in
            guard position.utf16 > removal.utf16 else { return nil }
            return Position(
                utf8: position.utf8 - removal.utf8,
                utf16: position.utf16 - removal.utf16
            )
        }
    }

    private static func utf8Length(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0...0x7F: 1
        case 0x80...0x7FF: 2
        case 0x800...0xFFFF: 3
        default: 4
        }
    }
}
