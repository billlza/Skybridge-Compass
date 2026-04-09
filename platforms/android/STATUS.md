# Android Portability Status

## Snapshot

- Branch: `Bill/android-portability`
- Import scope: application modules, shared/native support, docs, scripts, Gradle wrapper
- Validation performed before import:
  - `./gradlew :app:assembleDebug --warning-mode all`

## Capability status

| Area | Status | Notes |
| --- | --- | --- |
| App build | Ready | Debug build succeeds on the imported branch snapshot. |
| Device discovery | Implemented | Dedicated `device-discovery` module and interop runbooks are present. |
| File transfer | Implemented | `file-transfer` module and protocol code are included. |
| Remote control | Implemented | `remote-control` and Android/macOS interop helpers are included. |
| Screen mirroring | Implemented | `screen-mirroring` module is included. |
| PQC / crypto | Implemented | Kotlin/native code and liboqs support are present. |
| Instrumentation / smoke | Available | Android/macOS/iOS smoke helpers and instrumentation tests are included. |
| Release hardening | Partial | Release configuration exists, but this branch is primarily a source backup / portability artifact. |

## De-localization work completed

- Removed workstation-specific JDK absolute paths from `gradle.properties`
- Replaced hard-coded `/Users/...` defaults in smoke scripts with repository-relative defaults
- Converted runbook path examples to `<repo-root>` placeholders
- Excluded local SDK, IDE, cache, artifact, and generated native-build directories from version control
