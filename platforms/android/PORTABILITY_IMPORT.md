Android portability snapshot imported into `Bill/android-portability`.

Source:
- External Android workspace snapshot imported into the repository under `platforms/android`

Included:
- app/client modules, shared/native support, docs, scripts, Gradle wrapper/config

Excluded:
- `.gradle`, `.idea`, `.kotlin`
- `build/` outputs and `.cxx`
- `local.properties`
- packaged artifacts such as `.apk` / `.aab`

Validated before import:
- `./gradlew assembleDebug --warning-mode all`

Notes:
- `gradle.properties` was sanitized to remove workstation-specific JDK paths.
- generated `shared/scripts/build_liboqs/build-*` directories are intentionally excluded.
