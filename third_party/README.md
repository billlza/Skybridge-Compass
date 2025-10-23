# Offline Dependencies

Place the pre-fetched Maven artifacts required by the Android Gradle Plugin and the application modules inside the `m2repository` directory. The offline build script and Gradle settings rely on this layout to resolve dependencies without network access. Bundled archives named `m2repository.zip`, `m2repository.tar`, `m2repository.tar.gz`, or `m2repository.tar.bz2` are automatically unpacked when `assemble-offline.sh` runs. The helper also scans `dist/` and the repository root for the same archive names, so caches can be shared without relocating the files manually.

If you received a pre-packaged Gradle distribution (e.g. `gradle-9.0.0-bin.zip`), drop it into this folder as well. `assemble-offline.sh` extracts the archive into `.gradle-offline/` on demand so the project can run with Gradle 9.0.0 even when the host machine does not have that version installed.
