# Vendored FreeRDP / WinPR headers (3.26.0)

These are the **public** C headers for FreeRDP and WinPR, pinned to **3.26.0** — the exact
version produced by `Scripts/build_freerdp_dylibs.sh` and shipped in
`Sources/Vendor/FreeRDPDylibs/`. They exist so `Sources/FreeRDPBridge` can be compiled
against the **real** FreeRDP types/structs/enums (struct offsets and setting-key values are
computed by the compiler) instead of opaque types + hardcoded pointer slots + fabricated
constants. The dylibs are still loaded at runtime via `dlopen`/`dlsym`; these headers add no
link-time dependency.

## Provenance / how to regenerate

```sh
git clone --depth 1 --branch 3.26.0 https://github.com/FreeRDP/FreeRDP.git <src>
cmake -S <src> -B <build> -G Ninja -DWITH_OPENSSL=ON -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
  -DWITH_CLIENT=ON -DWITH_SERVER=OFF -DWITH_X11=OFF -DWITH_SDL=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF
# then:
cp -R <src>/include/freerdp        include/freerdp
cp -R <src>/winpr/include/winpr     include/winpr
# overlay cmake-generated headers:
cp <build>/include/freerdp/{config.h,version.h,buildflags.h,build-config.h,settings_keys.h} include/freerdp/
cp <build>/winpr/include/winpr/{config.h,version.h,buildflags.h,build-config.h}             include/winpr/
```

Include root is `include/` (so `<freerdp/...>` and `<winpr/...>` resolve). Wired into the
`FreeRDPBridge` target's `cSettings` in `Package.swift` via `headerSearchPath`.

## Local patch (must re-apply if regenerated)

`include/winpr/wtypes.h` — winpr's `typedef IID* REFIID;` is guarded with `#ifndef __APPLE__`.
On Apple, CoreFoundation's `CFPlugInCOM.h` already defines `REFIID` as `CFUUIDBytes` (exported
through a clang module, so it can't be suppressed by a textual include guard), which otherwise
collides with winpr. winpr's RDP core path (connect / GDI / input / settings) never uses
`REFIID`, so deferring to the system definition on Apple is safe.

License: FreeRDP and WinPR are Apache-2.0 (see the upstream `LICENSE`).
