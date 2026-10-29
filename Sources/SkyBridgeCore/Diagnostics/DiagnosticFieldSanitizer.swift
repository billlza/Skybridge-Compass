import Foundation

/// Sanitizes free-form values before they are embedded into structured
/// diagnostic evidence records.
///
/// Diagnostic records are whitespace-delimited `key=value` pairs. A raw value
/// carrying whitespace, newlines or delimiter characters would let remote- or
/// user-controlled input forge additional fields inside a record, so every
/// interpolated value has to pass through this sanitizer first. Any scalar
/// outside `CharacterSet.alphanumerics` plus `.`, `:`, `-` and `_` collapses
/// into `_`. Note that `alphanumerics` is Unicode-wide, so letters and digits
/// from any script survive unchanged; the guarantee is that no whitespace,
/// newline or `=` can reach a record, not that the output is ASCII. Absent or
/// fully-collapsed input reports ``missingValuePlaceholder`` so a record always
/// carries exactly the fields its emitter declared.
///
/// This is a general-purpose sanitizer, not a test hook, so it is deliberately
/// not compiled out of Release builds. Its current callers are diagnostic
/// evidence emitters whose sink, `RemoteControlSmokeStatusWriter.append(_:)`,
/// is itself gated to test builds. Keeping the sanitizer outside that
/// smoke-named type is what matters for shipping: the macOS release binary
/// surface gate rejects any `*SmokeStatusWriter` symbol in the shipped binary,
/// and a pure string sanitizer is not a test-activation surface.
enum DiagnosticFieldSanitizer {
    /// Reported when the input is `nil`, empty, or collapses to nothing.
    static let missingValuePlaceholder = "missing"

    private static let allowedScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: ".:-_"))

    /// Returns a record-safe rendering of `raw`.
    ///
    /// - Parameter raw: The untrusted value to embed in a diagnostic record.
    /// - Returns: `raw` trimmed and reduced to the allowlist, or
    ///   ``missingValuePlaceholder`` when nothing printable remains.
    static func fieldValue(_ raw: String?) -> String {
        guard let raw else { return missingValuePlaceholder }
        let sanitized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { allowedScalars.contains($0) ? $0.description : "_" }
            .joined()
        return sanitized.isEmpty ? missingValuePlaceholder : sanitized
    }
}
