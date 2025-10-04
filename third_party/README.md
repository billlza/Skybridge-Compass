# Offline Dependencies

Place the pre-fetched Maven artifacts required by the Android Gradle Plugin and the application modules inside the `m2repository` directory. The offline build script and Gradle settings rely on this layout to resolve dependencies without network access. Bundled archives named `m2repository.zip`, `m2repository.tar`, `m2repository.tar.gz`, or `m2repository.tar.bz2` are automatically unpacked when `assemble-offline.sh` runs.
