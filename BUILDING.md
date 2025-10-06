# Building Skybridge Compass Offline

This repository now supports an offline command-line build flow that relies on
pre-fetched Maven artifacts. The automated environment used to validate these
changes has no outbound network access, so it cannot download dependencies or
reconfigure toolchains once the offline window begins. All build assets must be
prepared ahead of time. Follow the steps below to assemble an APK without
network access:

1. Populate `third_party/m2repository` with the required artifacts, including
   the Android Gradle Plugin (`com/android/tools/build/gradle/8.6.1`) and the
   libraries referenced by `app/build.gradle.kts`. The directory structure
   should mirror a standard Maven repository. If you have the cache bundled as
   `third_party/m2repository.zip` (or `.tar[.gz|.bz2]`), the build scripts
   automatically unpack it on first run.
2. Ensure the Android SDK and build tools referenced by the project are
   available on the host machine.
3. Execute `./assemble-offline.sh`. The script validates the presence of the
   critical artifacts, confirms that any bundled archives were unpacked, and
   then invokes `gradle --offline assembleRelease` using a repository
   configuration that favors the bundled cache.
4. CodeX automation hosts automatically adopt the provisioned JDK at
   `/root/.local/share/mise/installs/java/21.0.2`. Other environments can export
   `CODEX_JAVA_HOME` to point Gradle at a different installation before running
   the build scripts.

## CodeX automation shortcut

Automation jobs that run on CodeX infrastructure should call
`./codex-build-ultimate.sh`. The helper discovers a usable Java 21 runtime by
checking `CODEX_JAVA_HOME`, `JAVA_HOME`, the default Mise-managed toolchain, and
any `java` available on the PATH. After exporting the detected location, it
delegates to `assemble-offline.sh`, ensuring the Gradle invocation inherits the
correct `org.gradle.java.home` configuration without additional setup.

Developers can still open the project in Android Studio Iguana (or newer). When
doing so, point Studio at the same offline Maven cache to keep Gradle sync
requests self-contained.
