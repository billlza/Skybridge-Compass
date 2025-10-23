# Building Skybridge Compass Offline

This repository now supports an offline command-line build flow that relies on
pre-fetched Maven artifacts. The automated environment used to validate these
changes has no outbound network access, so it cannot download dependencies or
reconfigure toolchains once the offline window begins. All build assets must be
prepared ahead of time. Follow the steps below to assemble an APK without
network access:

> **Note:** The repository snapshot running in the automated QA environment
> does not include any cached Maven artifacts or Gradle distributions. Provide
> the bundles described below (for example, by unpacking the archives attached
> to commit `6d31ee07`) before invoking the build scripts locally.

1. Populate `third_party/m2repository` with the required artifacts, including
   the Android Gradle Plugin (`com/android/tools/build/gradle/8.7.3`) and the
   libraries referenced by `app/build.gradle.kts`. The directory structure
   should mirror a standard Maven repository. If you have the cache bundled as
   `m2repository.zip` (or `.tar[.gz|.bz2]`) or a bundle whose name contains
   `m2repository` or `offline-maven`, place the archive anywhere under
   `third_party/`, `dist/`, or the repository root—the build scripts
   automatically unpack the first match on their initial run. When no archive
   is discovered the helper now prints the directories it searched, making it
   easier to confirm the cache is staged in one of the supported locations. If
   your organization hosts a shared Maven cache elsewhere, export
   `OFFLINE_M2_PATH=/path/to/cache` before invoking the helper to reuse that
   directory without copying artifacts into the repository checkout.
2. Place the Gradle 9.0.0 distribution archive (for example,
   `gradle-9.0.0-bin.zip`) in any of those locations (`third_party/`, `dist/`,
   or the project root). The build helper unpacks it into `.gradle-offline/`
   automatically; if the archive is missing, the script falls back to any
   `gradle` binary already on the PATH.
3. Ensure the Android SDK and build tools referenced by the project are
   available on the host machine.
4. Execute `./assemble-offline.sh`. The script validates the presence of the
   critical artifacts, confirms that any bundled archives were unpacked, and
   then invokes Gradle in offline mode using the prepared cache.
5. CodeX automation hosts automatically adopt the provisioned JDK at
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

## Troubleshooting cache detection

If `./assemble-offline.sh` exits immediately with
`Offline Maven repository ... is empty`, confirm that
`third_party/m2repository` contains the unpacked artifacts and that your cache
archive uses one of the supported file names. The helper prints the directories
it searched when no cache is found; after placing an archive in one of those
locations, rerun the script so it can unpack the bundle before invoking Gradle.
