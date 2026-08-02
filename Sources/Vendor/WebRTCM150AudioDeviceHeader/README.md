# WebRTC M150 macOS audio-device header overlay

The reviewed M150 macOS framework omits `RTCAudioDevice.h`, although the
binary exports the custom audio-device API used by `WebRTCAudioDeviceBridge`.
This single header is copied byte-for-byte from the iOS slice of the same
`WebRTC-M150.xcframework.zip` release asset. Its SHA-256 is
`8b4bdd60ab38c0a092da4b1ad6064946a77b0ffe95c2e116a1643c8d8ca3d83d`.

Only the Objective-C audio bridge receives this include path. Other WebRTC
consumers use the macOS framework headers directly, so this does not create a
second general WebRTC header surface.
