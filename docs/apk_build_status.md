# Offline APK Build Status

The automated QA environment does not contain the cached Maven repository artifacts or Gradle 9.0.0 distribution that the offline build scripts expect. Running `./assemble-offline.sh` exits immediately with:

```
Offline Maven repository at /workspace/Skybridge-Compass/third_party/m2repository is empty.
No m2repository archives were found under third_party/, dist/, or the repo root.
```

To produce an APK offline, stage the pre-downloaded Android Gradle Plugin (8.7.3) and dependency artifacts under `third_party/m2repository` or provide an archive named `m2repository*.{zip,tar,tar.gz,tar.bz2}` before invoking the helper script. Once populated, `./assemble-offline.sh` will unpack the Gradle 9.0.0 distribution if necessary and run `gradle --offline assembleRelease`. The fully cached baseline referenced by commit `56aafae2` already contains the required artifacts—use that revision when mirroring the build locally.

## Latest QA Attempt

Commit `56aafae2` is not available in this sandbox snapshot; the current tree still lacks the staged caches. Executing either `./assemble-offline.sh` or `./codex-build-ultimate.sh` therefore reports the same missing repository message and stops before Gradle launches. Provide the cached `m2repository` archive in this checkout (or set `OFFLINE_M2_PATH`) to allow the scripts to proceed.
