// SPDX-License-Identifier: MIT
// SkyBridge Compass - Artifact Date Helper
//
// Many paper artifacts are written to `Artifacts/<prefix>_<YYYY-MM-DD>.csv`.
// To avoid mixing datasets across runs, we allow callers to pin the date
// suffix via environment variables.

import Foundation

enum ArtifactDate {
    /// Return the date suffix used for artifact filenames.
    ///
    /// Priority:
    /// - `ARTIFACT_DATE` (preferred)
    /// - `SKYBRIDGE_ARTIFACT_DATE` (compat)
    /// - today's date (local time)
    static func current() -> String {
        let env = ProcessInfo.processInfo.environment
        if let v = env["ARTIFACT_DATE"], !v.isEmpty { return v }
        if let v = env["SKYBRIDGE_ARTIFACT_DATE"], !v.isEmpty { return v }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date())
    }
}


