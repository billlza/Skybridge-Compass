import Foundation

/// Sanitizes free-form values before they are embedded into structured
/// diagnostic evidence records.
///
/// Diagnostic records are whitespace-delimited `key=value` pairs. A raw value
/// carrying whitespace, newlines or delimiter characters would let remote- or
/// user-controlled input forge additional fields inside a record, so every
/// interpolated value has to pass through this sanitizer first. Characters
/// outside the `[A-Za-z0-9.:-_]` allowlist collapse into `_`, and absent or
/// fully-collapsed input reports a stable placeholder so a record always
/// carries exactly the fields its emitter declared.
///
/// This is production log hygiene rather than a test hook: it stays compiled
/// into release builds because release code paths emit structured diagnostics.
/// It deliberately lives outside any smoke/test-only type so that the release
/// binary carries no test-activation surface in its symbol table.
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
