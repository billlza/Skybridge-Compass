# Android liboqs source dependency

The Android JNI bridge builds the reviewed liboqs `0.15.0-rc2` source snapshot
in this directory as part of the same Gradle external-native-build transaction.
It must not link a developer-local archive from `shared/libs/`.

The only local source adjustment is an explicit `unsigned char` conversion for
the byte-wise Keccak complement operations. C integer promotion makes `~byte`
an `int`; converting the intended low byte explicitly preserves the algorithm
while keeping the Android Clang build free of precision-loss warnings. The
Android CMake boundary promotes that warning class to an error so an upstream
refresh cannot silently reintroduce it.

The product build enables only ML-KEM-768 and ML-DSA-65 and uses the portable,
OpenSSL-independent liboqs implementation. Any source refresh must rerun the
full Android zero-warning matrix and the physical native-runtime smoke on both
the supported 4 KiB and 16 KiB page-size environments.
