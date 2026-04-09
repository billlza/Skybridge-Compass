# Android Build Guide

This branch stores the Android portability snapshot under `platforms/android`.

## Supported baseline

- Branch: `Bill/android-portability`
- Primary app module: `:app`
- Preferred validation command:

```bash
cd platforms/android
./gradlew :app:assembleDebug --warning-mode all
```

## Prerequisites

- Android Studio or a compatible Android SDK installation
- JDK 21 recommended
- `ANDROID_HOME`/`ANDROID_SDK_ROOT` or a developer-local `local.properties`

`local.properties` is intentionally excluded from version control. Use it only for
developer-local SDK paths and local service credentials.

## Optional checks

```bash
cd platforms/android
./gradlew test
./gradlew connectedDebugAndroidTest
```

Interop helpers live under `platforms/android/scripts/`.

## Version-control exclusions

The portability branch intentionally excludes:

- `.gradle`, `.idea`, `.kotlin`
- all `build/` outputs
- `.cxx` / `.externalNativeBuild`
- `local.properties`
- packaged artifacts such as `.apk` and `.aab`
- generated `shared/scripts/build_liboqs/build-*` directories
