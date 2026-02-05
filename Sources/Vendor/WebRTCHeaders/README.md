# WebRTCHeaders (SwiftPM header overlay)

This directory is a **build-time header overlay** used when compiling the macOS SwiftPM targets
that import `stasel/WebRTC` (binary `WebRTC.xcframework`).

## Why it exists

At the time of this artifact, the `WebRTC-M141.xcframework.zip` distribution’s **macOS slice**
may ship with an incomplete `WebRTC.framework/Headers/` set (only `WebRTC.h`), while the umbrella
header still references many public headers such as:

- `<WebRTC/RTCAudioSource.h>`
- `<WebRTC/RTCPeerConnection.h>`
- `<WebRTC/RTCMTLNSVideoView.h>`

SwiftPM’s Clang importer requires those headers to exist to build the Objective‑C module.
To keep `swift test` / CI builds reproducible, we provide the missing header paths here and
add them via `-Xcc -I Sources/Vendor/WebRTCHeaders` for macOS builds in `Package.swift`.

## What is included

- `WebRTC/*.h`: a header set copied from the same WebRTC release (M141) to satisfy the umbrella imports.
- `sdk/objc/base/RTCMacros.h`: a thin shim so includes of `"sdk/objc/base/RTCMacros.h"` resolve.
- `WebRTC/RTCMTLNSVideoView.h`: a minimal shim used when the macOS slice omits this header.

If the upstream binary distribution is fixed in a future update, this overlay can be removed.

## License

These headers correspond to the WebRTC project and are covered by the license in `LICENSE`.

